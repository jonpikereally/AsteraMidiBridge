// Astera MIDI Bridge - native macOS app (window + menu bar).
// Listens to MIDI sources and drives AsteraApp's Remote Control HTTP API.
// Uses the same config.json format as astera_midi.py.

import SwiftUI
import CoreMIDI
import Combine
import UniformTypeIdentifiers
import SQLite3

// MARK: - Config

struct Mapping: Identifiable, Equatable {
    var id = UUID()
    var label = ""
    var source: String?
    var channel: Int?
    var note: Int?
    var cc: Int?
    var programChange: Int?
    var action = ""
    var program: [String: String] = [:]
    var target: String?
    var value = "toggle"
    var lo = 0.0
    var hi = 100.0
    var relative = false
    var step = 1.0

    var triggerText: String {
        let what: String
        if let n = note { what = "Note \(n)" }
        else if let c = cc { what = "CC \(c)" }
        else if let p = programChange { what = "Program Change \(p)" }
        else { return "Not set – click Learn" }
        return "\(source ?? "Any source") · \(what)"
    }

    func toJSON() -> [String: Any] {
        var d: [String: Any] = ["label": label, "action": action]
        if let s = source { d["source"] = s }
        if let c = channel { d["channel"] = c }
        if let n = note { d["note"] = n }
        if let c = cc { d["cc"] = c }
        if let p = programChange { d["program_change"] = p }
        if action == "launch" {
            var prog: [String: Any] = [:]
            for (k, v) in program { prog[k] = Int(v).map { $0 as Any } ?? v }
            d["program"] = prog
        }
        if let t = target, action == "brightness" || action == "select_target" {
            d["target"] = Int(t).map { $0 as Any } ?? t
        }
        if action == "power" { d["value"] = value }
        if action == "brightness" {
            if lo != 0 || hi != 100 { d["range"] = [lo, hi] }
            if relative { d["mode"] = "relative"; d["step"] = step }
        }
        return d
    }
}

struct LearnConflict {
    var mappingID: UUID
    var source: String
    var kind: Int
    var number: Int
    var others: [UUID]
    var text: String
}

struct AsteraProgram: Identifiable, Equatable {
    var uuid: String
    var name: String
    var title: String
    var id: String { uuid }
}

struct AsteraTarget: Identifiable, Equatable {
    var id: String
    var title: String
}

struct Config {
    var host = "127.0.0.1"
    var port = 8080
    var inputs = ["*"]
    var exclude: [String] = []
    var virtualPort: String? = "Astera Bridge"
    var mappings: [Mapping] = []
    var root: [String: Any] = [:]
    var fadeFollow = true
    var dbPath: String?

    static func load(_ url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "config", code: 1, userInfo: [NSLocalizedDescriptionKey: "config.json is not a JSON object"])
        }
        var c = Config()
        c.root = root
        if let a = root["astera"] as? [String: Any] {
            c.host = a["host"] as? String ?? c.host
            c.port = a["port"] as? Int ?? c.port
        }
        if let i = root["midi_inputs"] as? [String] { c.inputs = i }
        else if let i = root["midi_input"] as? String { c.inputs = [i] }
        c.exclude = root["exclude_inputs"] as? [String] ?? []
        c.virtualPort = root["virtual_port"] as? String
        c.fadeFollow = root["scene_fade_follow_astera"] as? Bool ?? true
        c.dbPath = root["astera_db"] as? String
        for d in root["mappings"] as? [[String: Any]] ?? [] {
            var m = Mapping()
            m.action = d["action"] as? String ?? ""
            m.label = d["label"] as? String ?? m.action
            m.source = d["source"] as? String
            m.channel = d["channel"] as? Int
            m.note = d["note"] as? Int
            m.cc = d["cc"] as? Int
            m.programChange = d["program_change"] as? Int
            if let p = d["program"] as? [String: Any] { m.program = p.mapValues { "\($0)" } }
            if let t = d["target"] { m.target = "\(t)" }
            m.value = d["value"] as? String ?? "toggle"
            if let r = d["range"] as? [Double], r.count == 2 { m.lo = r[0]; m.hi = r[1] }
            m.relative = (d["mode"] as? String) == "relative"
            m.step = d["step"] as? Double ?? 1
            c.mappings.append(m)
        }
        return c
    }
}

// MARK: - Bridge

final class Bridge: ObservableObject {
    @Published var enabled = true { didSet { let v = enabled; work.async { self.wEnabled = v } } }
    @Published var monitor = false { didSet { let v = monitor; work.async { self.wMonitor = v } } }
    @Published var monitorFilter = "MPK" { didSet { let v = monitorFilter.lowercased(); work.async { self.wFilter = v } } }
    @Published var asteraOnline = false
    @Published var asteraInfo = "Checking AsteraApp…"
    @Published var sources: [String] = []
    @Published var mappings: [Mapping] = []
    @Published var programs: [AsteraProgram] = []
    @Published var targets: [AsteraTarget] = []
    @Published var learningID: UUID? {
        didSet {
            let id = learningID
            work.async {
                let now = Date().timeIntervalSince1970
                // controls that were already sending right before Learn (e.g. DJ decks) are ignored
                self.wNoisy = Set(self.lastSeen.filter { now - $0.value < 2 }.keys)
                self.wLearning = id
            }
        }
    }
    @Published var conflict: LearnConflict?
    /// Fade scene changes using each effect's own Crossfade setting from AsteraApp.
    @Published var fadeFollow = true {
        didSet {
            let v = fadeFollow
            work.async { self.wFadeOn = v }
            if !loadingConfig && v != oldValue { config.root["scene_fade_follow_astera"] = v; writeConfig() }
        }
    }
    @Published var crossfades: [String: Double] = [:]   // seconds per program uuid, read from AsteraApp's database
    @Published var dbConnected = false
    private var dbRunningUUID: String?
    private let dbQueue = DispatchQueue(label: "bridge.db")
    private var dbPath: String?
    private var dbMTime: Date?
    private var dbWarned = false
    private var dbTimer: DispatchSourceTimer?
    private var loadingConfig = false
    @Published var nowPlaying: AsteraProgram?      // last scene launched through the bridge
    @Published var tiles: [String: NSImage] = [:]  // AsteraApp's own tile artwork, by program uuid
    @Published var tileColors: [String: Color] = [:]
    private var lastSaved: [Mapping] = []
    @Published var log: [String] = []

    let configURL: URL
    private var config = Config()
    private let work = DispatchQueue(label: "bridge.work")

    // work-queue state
    private var wEnabled = true
    private var wMonitor = false
    private var wFilter = "mpk"
    private var wMappings: [Mapping] = []
    private var wLearning: UUID?
    private var wFadeOn = true
    private var wCrossfade: [String: Double] = [:]
    private var wMasterID: String?
    private var fadeGen = 0
    private var fadeTarget: Double?     // brightness to return to; non-nil while a fade is running
    private var fadeCurrent = 0.0
    private var wNoisy = Set<String>()
    private var lastSeen: [String: Double] = [:]
    private var levels: [String: Double] = [:]
    private var ccLast: [String: UInt8] = [:]
    private var powerOn = true
    private var pendingBrightness: [String: Int] = [:]
    private var flushTimer: DispatchSourceTimer?

    // MIDI
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var virtDest = MIDIEndpointRef()
    private var connected: [MIDIEndpointRef: Int] = [:]
    private var nextTag = 0
    private var tagNames: [Int: String] = [:]
    private let tagLock = NSLock()
    private var statusTimer: Timer?

    init() {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["ASTERA_BRIDGE_CONFIG"] {
            configURL = URL(fileURLWithPath: override)
        } else {
            let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AsteraMidiBridge")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            configURL = dir.appendingPathComponent("config.json")
            if !fm.fileExists(atPath: configURL.path),
               let bundled = Bundle.main.url(forResource: "config", withExtension: "json") {
                try? fm.copyItem(at: bundled, to: configURL)
            }
        }
        loadConfig()
        startMIDI()
        startFlushTimer()
        startDBTimer()
        checkStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkStatus() }
        if ProcessInfo.processInfo.environment["ASTERA_BRIDGE_TEST_AUTOUPDATE"] != nil {  // test hook
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.checkForUpdates() }
        }
        if let io = ProcessInfo.processInfo.environment["ASTERA_BRIDGE_TEST_IMPORT_EXPORT"] {  // test hook: "in.json:out.json"
            let parts = io.split(separator: ":").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.importSettings(from: URL(fileURLWithPath: parts[0]))
                self.exportSettings(to: URL(fileURLWithPath: parts[1]))
            }
        }
        if ProcessInfo.processInfo.environment["ASTERA_BRIDGE_AUTOLEARN"] != nil {  // test hook
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.addMapping("launch") }
        }
    }

    // MARK: logging

    func addLog(_ s: String) {
        print(s)
        fflush(stdout)
        DispatchQueue.main.async {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            self.log.append("\(f.string(from: Date()))  \(s)")
            if self.log.count > 200 { self.log.removeFirst(self.log.count - 200) }
        }
    }

    // MARK: config

    func loadConfig() {
        do {
            let c = try Config.load(configURL)
            config = c
            mappings = c.mappings
            lastSaved = c.mappings
            loadingConfig = true
            fadeFollow = c.fadeFollow
            loadingConfig = false
            work.async { self.wMappings = c.mappings }
            addLog("Loaded \(c.mappings.count) mappings")
        } catch {
            addLog("Config error: \(error.localizedDescription)")
        }
    }

    func reloadConfig() {
        loadConfig()
        rescan()
        checkStatus()
        fetchLevels()
    }

    // MARK: mapping editor

    func targetName(_ id: String?) -> String {
        guard let id = id else { return "?" }
        return targets.first { $0.id == id }?.title ?? "Target \(id)"
    }

    func actionText(_ m: Mapping) -> String {
        switch m.action {
        case "launch":
            if let u = m.program["uuid"], let p = programs.first(where: { $0.uuid == u }) { return p.title }
            return m.program["name"] ?? "Scene"
        case "brightness": return "\(targetName(m.target)) brightness"
        case "select_target": return "Select \(targetName(m.target))"
        case "power": return "Power \(m.value)"
        default: return m.action
        }
    }

    /// Called whenever the mapping list changes in the UI: relabel, apply, write config.json.
    func save() {
        guard mappings != lastSaved else { return }
        for i in mappings.indices {
            mappings[i].label = "\(mappings[i].triggerText) → \(actionText(mappings[i]))"
        }
        lastSaved = mappings
        let ms = mappings
        work.async { self.wMappings = ms }
        writeConfig()
    }

    private func writeConfig() {
        guard let data = currentConfigData() else { return }
        do { try data.write(to: configURL) } catch { addLog("Could not save config: \(error.localizedDescription)") }
    }

    func addMapping(_ action: String) {
        var m = Mapping()
        m.action = action
        if action == "launch", let p = programs.first { m.program = ["uuid": p.uuid] }
        if action == "brightness" { m.target = targets.first?.id ?? "1" }
        mappings.append(m)
        learningID = m.id
    }

    func removeMapping(_ id: UUID) {
        if learningID == id { learningID = nil }
        DispatchQueue.main.async { self.mappings.removeAll { $0.id == id } }
    }

    private func finishLearn(_ id: UUID, source: String, kind: Int, number: Int) {
        learningID = nil
        guard mappings.contains(where: { $0.id == id }) else { return }
        let src = source.lowercased()
        let others = mappings.filter { o in
            guard o.id != id else { return false }
            let same = (kind == 0 && o.note == number) || (kind == 1 && o.cc == number) || (kind == 2 && o.programChange == number)
            guard same else { return false }
            guard let os = o.source?.lowercased() else { return true }
            return src.contains(os) || os.contains(src)
        }
        if others.isEmpty {
            applyLearn(id, source: source, kind: kind, number: number)
            return
        }
        let what = ["Note", "CC", "Program Change"][kind] + " \(number)"
        let names = others.map { "• " + actionText($0) }.joined(separator: "\n")
        conflict = LearnConflict(mappingID: id, source: source, kind: kind, number: number,
                                 others: others.map { $0.id },
                                 text: "\(what) from \(source) is already assigned to:\n\(names)\n\nReassign it to this mapping only, or keep both so it triggers all of them?")
        NSApp.activate(ignoringOtherApps: true)
        if let auto = ProcessInfo.processInfo.environment["ASTERA_BRIDGE_AUTOLEARN"], auto == "reassign" || auto == "both" {  // test hook
            resolveConflict(reassign: auto == "reassign")
        }
    }

    private func applyLearn(_ id: UUID, source: String, kind: Int, number: Int) {
        guard let i = mappings.firstIndex(where: { $0.id == id }) else { return }
        mappings[i].source = source
        mappings[i].channel = nil
        mappings[i].note = kind == 0 ? number : nil
        mappings[i].cc = kind == 1 ? number : nil
        mappings[i].programChange = kind == 2 ? number : nil
        addLog("Learned: \(mappings[i].triggerText)")
    }

    /// reassign = true: the other mappings lose this trigger. false: all mappings keep it.
    func resolveConflict(reassign: Bool) {
        guard let c = conflict else { return }
        conflict = nil
        if reassign {
            for i in mappings.indices where c.others.contains(mappings[i].id) {
                addLog("Unassigned: \(actionText(mappings[i]))")
                mappings[i].note = nil; mappings[i].cc = nil; mappings[i].programChange = nil
            }
        }
        applyLearn(c.mappingID, source: c.source, kind: c.kind, number: c.number)
    }

    // MARK: now playing + tile artwork

    private func fetchTile(_ uuid: String) {
        get("/api/program_tile", [("uuid", uuid), ("size", "128")], quiet: true) { data in
            guard let data = data, let img = NSImage(data: data) else { return }
            var color: Color?
            if let rep = NSBitmapImageRep(data: data),
               let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 8)?.usingColorSpace(.sRGB),
               c.alphaComponent > 0.5 {
                color = Color(nsColor: c)
            }
            DispatchQueue.main.async {
                self.tiles[uuid] = img
                if let color = color { self.tileColors[uuid] = color }
            }
        }
    }

    private func noteLaunched(_ spec: [String: String]) {
        var prog: AsteraProgram?
        if let u = spec["uuid"] { prog = programs.first { $0.uuid == u } }
        else if let n = spec["name"] { prog = programs.first { $0.name == n } }
        if prog == nil {
            let label = spec["name"] ?? spec["uuid"].map { _ in "Unknown scene" }
                ?? "Page \(spec["page"] ?? "?"), tile \(spec["tile"] ?? "?")"
            prog = AsteraProgram(uuid: spec["uuid"] ?? "", name: label, title: label)
        }
        nowPlaying = prog
        addLog("Now playing: \(prog?.name ?? "?")")
    }

    var menuBarIcon: NSImage { Bridge.asteraStyleIcon(dimmed: !enabled) }

    /// Two-peak mark in purple and orange, drawn in the style of the Astera logo.
    static func asteraStyleIcon(size: CGFloat = 18, dimmed: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let k = size / 18
            func shape(_ pts: [(CGFloat, CGFloat)], _ color: NSColor) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: pts[0].0 * k, y: pts[0].1 * k))
                for p in pts.dropFirst() { path.line(to: NSPoint(x: p.0 * k, y: p.1 * k)) }
                path.close()
                path.lineJoinStyle = .round
                path.lineWidth = 1.6 * k
                color.setFill(); color.setStroke()
                path.fill(); path.stroke()
            }
            let alpha: CGFloat = dimmed ? 0.35 : 1
            shape([(2, 3), (8.2, 15), (10.8, 15), (9.6, 9.5), (6.6, 3)],
                  NSColor(srgbRed: 0.44, green: 0.22, blue: 0.72, alpha: alpha))
            shape([(7.2, 3), (16, 3), (11.6, 10.4)],
                  NSColor(srgbRed: 0.96, green: 0.62, blue: 0.13, alpha: alpha))
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: updates from GitHub

    static let updateInfoURL = "https://raw.githubusercontent.com/jonpikereally/AsteraMidiBridge/main/version.json"
    static let trustedPrefixes = ["https://raw.githubusercontent.com/jonpikereally/AsteraMidiBridge/",
                                  "https://github.com/jonpikereally/AsteraMidiBridge/"]

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func info(_ title: String, _ text: String) {
        addLog("\(title): \(text)")
        if ProcessInfo.processInfo.environment["ASTERA_BRIDGE_TEST_AUTOUPDATE"] != nil { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func checkForUpdates() {
        let env = ProcessInfo.processInfo.environment
        let override = env["ASTERA_BRIDGE_UPDATE_URL"]          // test hook
        let auto = env["ASTERA_BRIDGE_TEST_AUTOUPDATE"] != nil  // test hook
        guard let url = URL(string: override ?? Bridge.updateInfoURL) else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        addLog("Checking for updates…")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let latest = j["version"] as? String, let zip = j["zip"] as? String,
                      let zipURL = URL(string: zip) else {
                    self.info("Couldn't check for updates", err?.localizedDescription ?? "No update information was found on GitHub.")
                    return
                }
                let current = self.currentVersion
                guard Bridge.isNewer(latest, than: current) else {
                    self.info("You're up to date", "Version \(current) is the latest version.")
                    return
                }
                guard override != nil || Bridge.trustedPrefixes.contains(where: { zip.hasPrefix($0) }) else {
                    self.info("Update blocked", "The download link doesn't point to the AsteraMidiBridge GitHub repo.")
                    return
                }
                if auto { self.installUpdate(zipURL); return }
                let a = NSAlert()
                a.messageText = "Version \(latest) is available"
                a.informativeText = "You have version \(current).\n\n\(j["notes"] as? String ?? "")\n\nThe app will download the update, replace itself and reopen. Your settings are kept."
                a.addButton(withTitle: "Update Now")
                a.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { self.installUpdate(zipURL) }
            }
        }.resume()
    }

    private func installUpdate(_ zip: URL) {
        let dest = Bundle.main.bundlePath
        guard dest.hasSuffix(".app") else { info("Can't update", "The app isn't running from an app bundle."); return }
        addLog("Downloading update…")
        URLSession.shared.downloadTask(with: zip) { tmp, resp, err in
            func fail(_ why: String) { DispatchQueue.main.async { self.info("Update failed", why) } }
            guard let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                fail(err?.localizedDescription ?? "The download failed."); return
            }
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("AsteraMidiBridgeUpdate-\(UUID().uuidString)")
            let zipPath = dir.appendingPathComponent("update.zip")
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.moveItem(at: tmp, to: zipPath)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zipPath.path, dir.path]
                try unzip.run(); unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { fail("The download couldn't be unpacked."); return }
                guard let appName = try fm.contentsOfDirectory(atPath: dir.path).first(where: { $0.hasSuffix(".app") }) else {
                    fail("The download doesn't contain the app."); return
                }
                let newApp = dir.appendingPathComponent(appName)
                let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
                guard plist?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                      let exe = plist?["CFBundleExecutable"] as? String,
                      fm.isExecutableFile(atPath: newApp.appendingPathComponent("Contents/MacOS/\(exe)").path) else {
                    fail("The download isn't a valid copy of this app."); return
                }
                // Swap the bundle after this app quits, then reopen it. The old copy is restored if the swap fails.
                let script = """
                while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
                rm -rf "$DEST.old"
                if mv "$DEST" "$DEST.old" && /usr/bin/ditto "$NEW" "$DEST"; then rm -rf "$DEST.old"; else rm -rf "$DEST"; mv "$DEST.old" "$DEST"; fi
                /usr/bin/open "$DEST"
                rm -rf "$WORK"
                """
                let sh = Process()
                sh.executableURL = URL(fileURLWithPath: "/bin/sh")
                sh.arguments = ["-c", script]
                sh.environment = ["PID": "\(ProcessInfo.processInfo.processIdentifier)", "DEST": dest,
                                  "NEW": newApp.path, "WORK": dir.path, "PATH": "/usr/bin:/bin"]
                try sh.run()
                DispatchQueue.main.async {
                    self.addLog("Installing update and restarting…")
                    NSApp.terminate(nil)
                }
            } catch {
                fail(error.localizedDescription)
            }
        }.resume()
    }

    // MARK: save / load settings files

    private func currentConfigData() -> Data? {
        var root = config.root
        root["mappings"] = mappings.map { $0.toJSON() }
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    func saveSettingsToFile() {
        let panel = NSSavePanel()
        panel.title = "Save Settings"
        panel.nameFieldStringValue = "Astera MIDI Bridge Settings.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportSettings(to: url)
    }

    func exportSettings(to url: URL) {
        guard let data = currentConfigData() else { return }
        do { try data.write(to: url); addLog("Saved settings to \(url.path)") }
        catch { addLog("Could not save settings: \(error.localizedDescription)") }
    }

    func loadSettingsFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Load Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSettings(from: url)
    }

    /// Replaces the current settings with the file's. The previous settings are kept as config.backup.json.
    func importSettings(from url: URL) {
        do {
            let c = try Config.load(url)
            guard c.root["mappings"] is [[String: Any]] else {
                throw NSError(domain: "config", code: 2, userInfo: [NSLocalizedDescriptionKey: "this file has no mappings – it doesn't look like a settings file"])
            }
            let data = try Data(contentsOf: url)
            let backup = configURL.deletingLastPathComponent().appendingPathComponent("config.backup.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: configURL, to: backup)
            try data.write(to: configURL)
            learningID = nil
            reloadConfig()
            addLog("Loaded settings from \(url.lastPathComponent) (\(c.mappings.count) mappings)")
        } catch {
            addLog("Could not load settings: \(error.localizedDescription)")
        }
    }

    func openConfig() {
        NSWorkspace.shared.open(configURL)
    }

    // MARK: Astera HTTP

    private func get(_ path: String, _ params: [(String, String)] = [], quiet: Bool = false,
                     completion: ((Data?) -> Void)? = nil) {
        var comps = URLComponents()
        comps.scheme = "http"; comps.host = config.host; comps.port = config.port; comps.path = path
        if !params.isEmpty { comps.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = comps.url else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if !quiet {
                let q = params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
                if let err = err { self.addLog("  !! \(path)?\(q) failed: \(err.localizedDescription)") }
                else { self.addLog("  -> \(path)?\(q)") }
            }
            completion?(err == nil ? data : nil)
        }.resume()
    }

    func checkStatus() {
        get("/api/status", quiet: true) { data in
            var info = "AsteraApp not reachable – turn on Remote Control"
            var online = false
            if let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                online = true
                let b = j["Bridge"] as? [String: Any]
                let name = b?["Name"] as? String ?? "no bridge"
                let batt = (b?["Battery"] as? Int).map { " (\($0)%)" } ?? ""
                info = "AsteraApp connected · \(name)\(batt)"
            }
            DispatchQueue.main.async {
                let cameOnline = online && !self.asteraOnline
                self.asteraOnline = online; self.asteraInfo = info
                if cameOnline { self.fetchLevels() }
            }
        }
    }

    private func fetchLevels() {
        get("/api/targets", quiet: true) { data in
            guard let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            self.work.async {
                for t in arr {
                    if let id = t["Id"], let b = t["Brightness"] as? Double { self.levels["\(id)"] = b }
                }
            }
            let ts: [AsteraTarget] = arr.compactMap { t in
                guard let id = t["Id"] else { return nil }
                let name = t["NameLocalized"] as? String ?? "Target \(id)"
                let master = (t["Name"] as? String) == "target_all_lights"
                return AsteraTarget(id: "\(id)", title: master ? "\(name) (master)" : name)
            }
            let master = arr.first { ($0["Name"] as? String) == "target_all_lights" }.flatMap { $0["Id"] }.map { "\($0)" }
            self.work.async { self.wMasterID = master ?? self.wMasterID }
            DispatchQueue.main.async { self.targets = ts }
        }
        get("/api/programs", quiet: true) { data in
            guard let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let ps: [AsteraProgram] = arr.compactMap { p in
                guard let uuid = p["UniqueId"] as? String else { return nil }
                let pos = p["Position"] as? Int ?? 0
                let name = (p["NameLocalized"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(unnamed, slot \((pos & 0xFFFF) + 1))"
                return AsteraProgram(uuid: uuid, name: name, title: "Page \((pos >> 16) + 1) · \(name)")
            }
            DispatchQueue.main.async {
                self.programs = ps
                self.applyRunning(force: false)
                for p in ps where self.tiles[p.uuid] == nil { self.fetchTile(p.uuid) }
            }
        }
    }

    // MARK: MIDI setup

    private func startMIDI() {
        MIDIClientCreateWithBlock("AsteraMidiBridge" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.rescan() }
            }
        }
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &inPort) { [weak self] list, refCon in
            self?.receive(list, tag: Int(bitPattern: refCon))
        }
        if let name = config.virtualPort {
            tagLock.lock(); tagNames[0] = name; tagLock.unlock()
            let st = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &virtDest) { [weak self] list, _ in
                self?.receive(list, tag: 0)
            }
            addLog(st == noErr ? "Virtual MIDI port '\(name)' created" : "Could not create virtual port (\(st))")
        }
        rescan()
    }

    private func displayName(_ ep: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf)
        return (cf?.takeRetainedValue() as String?) ?? "Unknown"
    }

    private func wanted(_ name: String) -> Bool {
        let low = name.lowercased()
        if config.exclude.contains(where: { low.contains($0.lowercased()) }) { return false }
        return config.inputs.contains { $0 == "*" || low.contains($0.lowercased()) }
    }

    func rescan() {
        var names: [String] = []
        var seen = Set<MIDIEndpointRef>()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            let name = displayName(src)
            seen.insert(src)
            if !wanted(name) {
                if connected[src] != nil { MIDIPortDisconnectSource(inPort, src); connected[src] = nil }
                continue
            }
            if connected[src] == nil {
                nextTag += 1
                tagLock.lock(); tagNames[nextTag] = name; tagLock.unlock()
                MIDIPortConnectSource(inPort, src, UnsafeMutableRawPointer(bitPattern: nextTag))
                connected[src] = nextTag
                addLog("+ listening to: \(name)")
            }
            names.append(name)
        }
        for (src, tag) in Array(connected) where !seen.contains(src) {
            connected[src] = nil
            tagLock.lock(); let n = tagNames[tag] ?? "?"; tagLock.unlock()
            addLog("- disconnected: \(n)")
        }
        if let v = config.virtualPort { names.append("\(v) (virtual – other apps send here)") }
        sources = names
    }

    // MARK: MIDI receive (CoreMIDI thread)

    private func receive(_ list: UnsafePointer<MIDIEventList>, tag: Int) {
        var msgs: [(UInt8, UInt8, UInt8, UInt8)] = []
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        for p in list.unsafeSequence() {
            let n = Int(p.pointee.wordCount)
            let raw = UnsafeRawPointer(p).advanced(by: wordsOffset)
            var i = 0
            while i < n {
                let w = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                let mt = w >> 28
                if mt == 2 {
                    msgs.append((UInt8((w >> 16) & 0xF0), UInt8((w >> 16) & 0x0F), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F)))
                }
                i += (mt == 3 || mt == 4) ? 2 : (mt == 5 ? 4 : 1)
            }
        }
        if msgs.isEmpty { return }
        work.async { for m in msgs { self.handle(tag: tag, status: m.0, channel: m.1, d1: m.2, d2: m.3) } }
    }

    // MARK: mapping logic (work queue)

    private func handle(tag: Int, status: UInt8, channel: UInt8, d1: UInt8, d2: UInt8) {
        tagLock.lock(); let source = tagNames[tag] ?? "?"; tagLock.unlock()
        let isNote = status == 0x90 || status == 0x80
        let isCC = status == 0xB0
        let isPC = status == 0xC0
        guard isNote || isCC || isPC else { return }

        if wMonitor && (wFilter.isEmpty || source.lowercased().contains(wFilter)) {
            let ch = Int(channel) + 1
            if isNote { addLog("[\(source)] \(status == 0x90 && d2 > 0 ? "note_on " : "note_off") channel=\(ch) note=\(d1) velocity=\(d2)") }
            else if isCC { addLog("[\(source)] cc channel=\(ch) cc=\(d1) value=\(d2)") }
            else { addLog("[\(source)] program_change channel=\(ch) program=\(d1)") }
        }

        let key = "\(tag)-\(isNote ? 0x90 : status)-\(d1)"
        if let lid = wLearning {
            let usable = (status == 0x90 && d2 > 0) || isCC || isPC
            if usable && !wNoisy.contains(key) {
                wLearning = nil
                let kind = isNote ? 0 : (isCC ? 1 : 2)
                let num = Int(d1)
                DispatchQueue.main.async { self.finishLearn(lid, source: source, kind: kind, number: num) }
            }
            return
        }
        lastSeen[key] = Date().timeIntervalSince1970
        guard wEnabled else { return }

        for m in wMappings {
            if let s = m.source, !source.lowercased().contains(s.lowercased()) { continue }
            if let c = m.channel, Int(channel) != c - 1 { continue }
            let hit: Bool
            if let n = m.note { hit = isNote && Int(d1) == n }
            else if let c = m.cc { hit = isCC && Int(d1) == c }
            else if let p = m.programChange { hit = isPC && Int(d1) == p }
            else { hit = false }
            if !hit { continue }

            if m.action == "brightness" {
                guard let tid = m.target else { continue }
                var cur: Double
                if m.relative && isCC {
                    let delta = (d2 == 0 || d2 == 64) ? 0 : (d2 < 64 ? Int(d2) : Int(d2) - 128)
                    cur = (levels[tid] ?? 50) + Double(delta) * m.step
                } else {
                    cur = m.lo + (m.hi - m.lo) * Double(d2) / 127
                }
                cur = max(m.lo, min(m.hi, cur.rounded()))
                levels[tid] = cur
                if fadeTarget != nil && tid == wMasterID {
                    fadeTarget = cur   // a fade is running: it will finish at the new level
                } else {
                    pendingBrightness[tid] = Int(cur)
                }
            } else if status == 0x90 && d2 > 0 {
                fire(m, source)
            } else if isPC {
                fire(m, source)
            } else if isCC {
                let key = "\(tag)-\(channel)-\(d1)"
                let was = ccLast[key] ?? 0
                ccLast[key] = d2
                if was < 64 && d2 >= 64 { fire(m, source) }
            }
        }
    }

    private func fire(_ m: Mapping, _ source: String) {
        addLog("[\(source)] => \(m.label)")
        switch m.action {
        case "launch":
            launchWithFade(m.program)
        case "select_target":
            if let t = m.target { selectOnly(t) }
        case "power":
            powerOn = m.value == "toggle" ? !powerOn : (m.value == "on")
            get("/api/set_power", [("value", powerOn ? "1" : "0")])
        default:
            break
        }
    }

    /// AsteraApp's select_target toggles a target and adds it to the selection, so a plain call
    /// can leave several targets selected. Make it exclusive: read the selection, switch the
    /// others off, then switch this one on. (Selecting any target clears "All Lights" by itself.)
    private func selectOnly(_ target: String) {
        get("/api/targets", quiet: true) { data in
            guard let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                self.get("/api/select_target", [("id", target)]); return
            }
            func isAll(_ t: [String: Any]) -> Bool { (t["Name"] as? String) == "target_all_lights" }
            let wantAll = arr.contains { "\($0["Id"] ?? "")" == target && isAll($0) }
            var calls: [String] = []
            var already = false
            for t in arr where (t["IsSelected"] as? Bool) == true {
                let id = "\(t["Id"] ?? "")"
                if id == target { already = true }
                else if !isAll(t) && !wantAll { calls.append(id) }   // toggle the others off
            }
            if !already { calls.append(target) }
            func step(_ i: Int) {
                guard i < calls.count else { return }
                self.get("/api/select_target", [("id", calls[i])]) { _ in step(i + 1) }
            }
            step(0)
        }
    }

    private func launchNow(_ spec: [String: String]) {
        get("/api/launch", spec.map { ($0.key, $0.value) })
        DispatchQueue.main.async { self.noteLaunched(spec) }
    }

    /// AsteraApp's remote API can only cut to a scene, so the fade is done here:
    /// dim the master brightness to 0, switch scene, then bring it back up.
    private func launchWithFade(_ spec: [String: String]) {
        let dur = wFadeOn ? min(5, spec["uuid"].flatMap { wCrossfade[$0] } ?? 0) : 0
        guard dur >= 0.1, let master = wMasterID else {
            if fadeTarget == nil { launchNow(spec); return }
            // an instant-cut effect arrived mid-fade: cut now and snap brightness back
            fadeGen += 1
            let target = fadeTarget!
            fadeTarget = nil
            launchNow(spec)
            if let master = wMasterID {
                levels[master] = target
                get("/api/set_brightness", [("id", master), ("brightness", "\(Int(target.rounded()))")], quiet: true)
            }
            return
        }
        fadeGen += 1
        let gen = fadeGen
        if fadeTarget != nil {              // already mid-fade: continue from where it is
            runFade(spec, master: master, gen: gen, duration: dur)
            return
        }
        fadeTarget = levels[master] ?? 100  // provisional, so knob moves are captured meanwhile
        fadeCurrent = fadeTarget!
        // ask AsteraApp for the real current level (it may have been changed in the app)
        get("/api/targets", quiet: true) { data in
            var level: Double?
            if let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                level = arr.first { "\($0["Id"] ?? "")" == master }?["Brightness"] as? Double
            }
            self.work.async {
                guard gen == self.fadeGen else { return }
                if let level = level { self.fadeTarget = level; self.fadeCurrent = level }
                self.runFade(spec, master: master, gen: gen, duration: dur)
            }
        }
    }

    /// Time-based ramp: quick ease down, switch scene at black, slower ease up.
    /// Values follow a squared curve so steps are finest at the dark end, where jumps show most,
    /// and are paced at ~12 per second so AsteraApp's Bluetooth relay can deliver them evenly.
    private func runFade(_ spec: [String: String], master: String, gen: Int, duration: Double) {
        let down = max(0.15, duration * 0.4)
        let up = max(0.25, duration * 0.6)
        let from = fadeCurrent
        let start = DispatchTime.now().uptimeNanoseconds
        var launched = false
        var lastSent = -1
        func send(_ v: Double) {
            fadeCurrent = v
            let iv = Int(v.rounded())
            guard iv != lastSent else { return }
            lastSent = iv
            get("/api/set_brightness", [("id", master), ("brightness", "\(iv)")], quiet: true)
        }
        func tick() {
            guard gen == self.fadeGen else { return }
            let t = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if t < down {
                let x = 1 - t / down
                send(from * x * x)
            } else {
                if !launched { launched = true; send(0); self.launchNow(spec) }
                guard let target = self.fadeTarget else { return }
                let x = min(1, (t - down) / up)
                send(target * x * x)
                if x >= 1 { self.levels[master] = target; self.fadeTarget = nil; return }
            }
            self.work.asyncAfter(deadline: .now() + 0.08) { tick() }
        }
        tick()
    }

    // MARK: AsteraApp database (read-only): per-effect crossfade + what is running

    private func findDB() -> String? {
        if let p = config.dbPath { return p }
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers")
        guard let dirs = try? fm.contentsOfDirectory(atPath: base.path) else { return nil }
        for d in dirs {
            let p = base.appendingPathComponent(d).appendingPathComponent("Data/Library/astera-led").path
            if fm.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private func startDBTimer() {
        let t = DispatchSource.makeTimerSource(queue: dbQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.pollDB() }
        t.resume()
        dbTimer = t
    }

    private func dbFailed(_ why: String) {
        if !dbWarned { dbWarned = true; addLog("Can't read AsteraApp's data (\(why)) – scene changes will cut instantly") }
        DispatchQueue.main.async { self.dbConnected = false }
    }

    private func pollDB() {
        if dbPath == nil { dbPath = findDB() }
        guard let path = dbPath else { dbFailed("not found, or access not allowed"); return }
        guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            dbFailed("access not allowed"); return
        }
        if m == dbMTime { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); dbFailed("could not open"); return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)

        func rows(_ sql: String, _ each: (OpaquePointer) -> Void) -> Bool {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let stmt = st else { return false }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
            return true
        }
        var fades: [String: Double] = [:]
        let ok = rows("select unique_id, crossfade_time from programs") { st in
            guard let c = sqlite3_column_text(st, 0) else { return }
            fades[String(cString: c)] = Double(sqlite3_column_int(st, 1)) / 100.0   // stored in 1/100 s
        }
        guard ok else { dbFailed("unexpected format"); return }   // retried next second (mtime not stored)
        var running: String?
        _ = rows("select unique_id from last_programs order by rowid desc limit 1") { st in
            if let c = sqlite3_column_text(st, 0) { running = String(cString: c) }
        }
        dbMTime = m
        work.async { self.wCrossfade = fades }
        DispatchQueue.main.async {
            if !self.dbConnected { self.addLog("Reading effect settings from AsteraApp (\(fades.count) effects)") }
            self.dbConnected = true
            self.crossfades = fades
            if running != self.dbRunningUUID {
                self.dbRunningUUID = running
                self.applyRunning(force: true)
            }
        }
    }

    /// Show the effect AsteraApp says is running (covers scenes started inside AsteraApp too).
    private func applyRunning(force: Bool) {
        guard force || nowPlaying == nil, let u = dbRunningUUID, let p = programs.first(where: { $0.uuid == u }) else { return }
        if nowPlaying?.uuid != p.uuid { nowPlaying = p }
    }

    private func startFlushTimer() {
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self = self, !self.pendingBrightness.isEmpty else { return }
            let items = self.pendingBrightness
            self.pendingBrightness = [:]
            for (tid, v) in items { self.get("/api/set_brightness", [("id", tid), ("brightness", "\(v)")]) }
        }
        t.resume()
        flushTimer = t
    }
}

// MARK: - UI

struct MainView: View {
    @ObservedObject var b: Bridge

    private var conflictShown: Binding<Bool> {
        Binding(get: { b.conflict != nil }, set: { if !$0 { b.conflict = nil } })
    }

    var body: some View {
        content
            .padding()
            .frame(minWidth: 960, minHeight: 760)
            .onChange(of: b.mappings) { _ in b.save() }
            .alert("Already assigned", isPresented: conflictShown) {
                Button("Reassign") { b.resolveConflict(reassign: true) }
                Button("Keep Both") { b.resolveConflict(reassign: false) }
                Button("Cancel", role: .cancel) { b.conflict = nil }
            } message: {
                Text(b.conflict?.text ?? "")
            }
    }

    private var nowPlayingBanner: some View {
        let p = b.nowPlaying
        let color = p.flatMap { b.tileColors[$0.uuid] } ?? Color.gray
        return HStack(spacing: 12) {
            if let p = p, let img = b.tiles[p.uuid] {
                Image(nsImage: img).resizable().frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.4)).frame(width: 52, height: 52)
                    .overlay(Image(systemName: "sparkles").foregroundColor(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW PLAYING").font(.caption2).foregroundColor(.secondary)
                Text(p?.name ?? "Nothing launched yet").font(.title2).bold()
                Text(b.dbConnected ? "Last effect AsteraApp recorded as started" : "Last scene launched through this bridge")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(p == nil ? 0.08 : 0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(p == nil ? 0.2 : 0.9), lineWidth: 1.5))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            nowPlayingBanner
            HStack {
                Circle().fill(b.asteraOnline ? Color.green : Color.red).frame(width: 10, height: 10)
                Text(b.asteraInfo)
                Spacer()
                Toggle("Bridge enabled", isOn: $b.enabled).toggleStyle(.switch)
            }
            GroupBox("MIDI sources") {
                VStack(alignment: .leading, spacing: 4) {
                    if b.sources.isEmpty { Text("No MIDI sources").foregroundColor(.secondary) }
                    ForEach(b.sources, id: \.self) { s in
                        Label(s, systemImage: "pianokeys")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("Mappings (\(b.mappings.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach($b.mappings) { $m in MappingRow(m: $m, b: b) }
                        }.padding(4)
                    }.frame(minHeight: 220)
                    HStack {
                        Toggle("Fade scene changes using each effect's Crossfade setting from AsteraApp", isOn: $b.fadeFollow)
                        if !b.dbConnected {
                            Text("(can't read AsteraApp's settings)").font(.caption).foregroundColor(.orange)
                        }
                        Spacer()
                    }
                    HStack {
                        Button("+ Scene mapping") { b.addMapping("launch") }
                        Button("+ Brightness mapping") { b.addMapping("brightness") }
                        Spacer()
                        Text("Click Learn, then press a pad or turn a knob.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }.padding(4)
            }
            GroupBox("Activity") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("Show incoming MIDI from sources containing:", isOn: $b.monitor)
                        TextField("any", text: $b.monitorFilter).frame(width: 110)
                        Spacer()
                        Button("Clear") { b.log.removeAll() }
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(b.log.joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .onChange(of: b.log.count) { _ in proxy.scrollTo("end") }
                    }.frame(height: 110)
                }.padding(4)
            }
            HStack {
                Button("Save Settings…") { b.saveSettingsToFile() }
                Button("Load Settings…") { b.loadSettingsFromFile() }
                Button("Edit Config…") { b.openConfig() }
                Button("Reload Config") { b.reloadConfig() }
                Spacer()
                Text("v\(b.currentVersion)").font(.caption).foregroundColor(.secondary)
                Button("Check for Updates…") { b.checkForUpdates() }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
    }
}

struct MappingRow: View {
    @Binding var m: Mapping
    @ObservedObject var b: Bridge

    private var actionBinding: Binding<String> {
        Binding(get: { m.action }, set: { new in
            m.action = new
            if new == "launch", m.program.isEmpty, let p = b.programs.first { m.program = ["uuid": p.uuid] }
            if (new == "brightness" || new == "select_target"), m.target == nil { m.target = b.targets.first?.id ?? "1" }
        })
    }
    private var programBinding: Binding<String> {
        Binding(get: { m.program["uuid"] ?? "custom" }, set: { if $0 != "custom" { m.program = ["uuid": $0] } })
    }
    private var targetBinding: Binding<String> {
        Binding(get: { m.target ?? "" }, set: { m.target = $0 })
    }

    var body: some View {
        let learning = b.learningID == m.id
        HStack(spacing: 8) {
            Text(m.triggerText).font(.callout).lineLimit(1).truncationMode(.middle)
                .frame(width: 230, alignment: .leading)
                .foregroundColor(m.note == nil && m.cc == nil && m.programChange == nil ? .secondary : .primary)
            Button(learning ? "Waiting… (cancel)" : "Learn") { b.learningID = learning ? nil : m.id }
                .frame(width: 130)
                .tint(learning ? .orange : nil)
            Picker("", selection: actionBinding) {
                Text("Scene").tag("launch")
                Text("Brightness").tag("brightness")
                Text("Power on/off").tag("power")
                Text("Select target").tag("select_target")
            }.labelsHidden().frame(width: 125)
            if m.action == "launch" {
                if let u = m.program["uuid"], let img = b.tiles[u] {
                    Image(nsImage: img).resizable().frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Picker("", selection: programBinding) {
                    if m.program["uuid"] == nil { Text(m.program["name"] ?? "Custom (from config file)").tag("custom") }
                    else if !b.programs.contains(where: { $0.uuid == m.program["uuid"] }) { Text("Unknown scene").tag(m.program["uuid"]!) }
                    ForEach(b.programs) { p in Text(p.title).tag(p.uuid) }
                }.labelsHidden()
                if let u = m.program["uuid"], let f = b.crossfades[u] {
                    Text(f >= 0.1 ? String(format: "fade %.1fs", f) : "cut")
                        .font(.caption).foregroundColor(.secondary).frame(width: 58, alignment: .leading)
                }
            } else if m.action == "brightness" || m.action == "select_target" {
                Picker("", selection: targetBinding) {
                    if !b.targets.contains(where: { $0.id == m.target }) { Text(b.targetName(m.target)).tag(m.target ?? "") }
                    ForEach(b.targets) { t in Text(t.title).tag(t.id) }
                }.labelsHidden()
                if m.action == "brightness" {
                    Toggle("Relative knob", isOn: $m.relative).toggleStyle(.checkbox)
                        .help("Turn on if the knob is an endless encoder set to Rel mode")
                    Text("Max").font(.caption).foregroundColor(.secondary)
                    Slider(value: $m.hi, in: 5...100, step: 5).frame(width: 90)
                        .help("Highest brightness this control can reach. Everything it sends is scaled below this.")
                    Text("\(Int(m.hi))%").font(.caption).monospacedDigit().frame(width: 38, alignment: .trailing)
                }
            } else {
                Spacer()
            }
            Button { b.removeMapping(m.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var b: Bridge
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(b.asteraInfo)
        Text("Now playing: \(b.nowPlaying?.name ?? "–")")
        Toggle("Bridge enabled", isOn: $b.enabled)
        Divider()
        Button("Show Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Save Settings…") { b.saveSettingsToFile() }
        Button("Load Settings…") { b.loadSettingsFromFile() }
        Button("Reload Config") { b.reloadConfig() }
        Button("Check for Updates…") { b.checkForUpdates() }
        Divider()
        Button("Quit Astera MIDI Bridge") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AsteraMidiBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var bridge = Bridge()

    var body: some Scene {
        Window("Astera MIDI Bridge", id: "main") {
            MainView(b: bridge)
        }
        MenuBarExtra {
            MenuContent(b: bridge)
        } label: {
            Image(nsImage: bridge.menuBarIcon)
        }
    }
}
