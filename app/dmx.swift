// DMX output for Astera MIDI Bridge.
//
// Drives fixtures in "DIM RGBW" mode (5 channels: dimmer, red, green, blue, white) through an
// Enttec Open DMX USB or any compatible FTDI serial interface. The interface has no timing of its
// own, so this file generates every DMX frame: a break, then a start code and 512 channel values.

import Foundation
import Darwin

struct DMXFixture: Identifiable, Equatable {
    var name: String
    var address: Int      // 1-based DMX start address
    var group: String     // "stage" or "front"
    var id: String { "\(address)-\(name)" }
}

struct DMXLook: Identifiable, Equatable {
    var uuid: String      // the scene it stands in for (program uuid from the mappings)
    var name: String
    var color: [Double]   // r, g, b, w in 0...1
    var pulse: Bool       // false = steady colour, true = brightness wave moving across the stage tubes
    var id: String { uuid }
}

final class DMXEngine {
    private var crossfadeSeconds = 0.4
    private var pulseSeconds = 1.0
    private var portSetting = "auto"

    /// Called on a background thread with (status text, connected).
    var onStatus: ((String, Bool) -> Void)?

    private let lock = NSLock()
    private var fixtures: [DMXFixture] = []
    private var stageCount = 0
    private var frontColor: [Double] = [0, 0, 0, 1]
    private var from: [Double] = [0, 0, 0, 1]
    private var to: [Double] = [0, 0, 0, 1]
    private var pulseFrom = 0.0
    private var pulseTo = 0.0
    private var fadeStart = 0.0
    private var fadeDur = 0.0
    private var levels: [String: Double] = ["stage": 0, "front": 0]
    private var master = 1.0
    private var blackout = false

    private var thread: Thread?
    private var running = false

    // MARK: state

    func configure(fixtures: [DMXFixture], frontColor: [Double], crossfadeSeconds: Double,
                   pulseSeconds: Double, port: String) {
        lock.lock(); defer { lock.unlock() }
        self.fixtures = fixtures
        self.stageCount = fixtures.filter { $0.group != "front" }.count
        if frontColor.count == 4 { self.frontColor = frontColor }
        self.crossfadeSeconds = crossfadeSeconds
        self.pulseSeconds = pulseSeconds
        portSetting = port
    }

    private func progress(_ now: Double) -> Double {
        fadeDur <= 0 ? 1 : min(1, max(0, (now - fadeStart) / fadeDur))
    }

    /// Crossfade the stage to a look.
    func setLook(_ look: DMXLook) {
        guard look.color.count == 4 else { return }
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        let p = progress(now)
        from = (0..<4).map { from[$0] + (to[$0] - from[$0]) * p }
        pulseFrom = pulseFrom + (pulseTo - pulseFrom) * p
        to = look.color
        pulseTo = look.pulse ? 1 : 0
        fadeStart = now
        fadeDur = crossfadeSeconds
    }

    /// Brightness of a group, 0...1.
    func setLevel(group: String, _ value: Double) {
        lock.lock(); levels[group] = min(1, max(0, value)); lock.unlock()
    }

    func setMaster(_ value: Double) {
        lock.lock(); master = min(1, max(0, value)); lock.unlock()
    }

    func setBlackout(_ on: Bool) {
        lock.lock(); blackout = on; lock.unlock()
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }

    /// The 512 channel values for this instant.
    func render() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var out = [UInt8](repeating: 0, count: 512)
        let now = CFAbsoluteTimeGetCurrent()
        let p = progress(now)
        let stageColor = (0..<4).map { from[$0] + (to[$0] - from[$0]) * p }
        let pulseAmount = pulseFrom + (pulseTo - pulseFrom) * p
        var stageIndex = 0
        for f in fixtures {
            guard (1...508).contains(f.address) else { continue }
            let isFront = f.group == "front"
            var level = blackout ? 0 : (levels[f.group] ?? 0) * master
            let color = isFront ? frontColor : stageColor
            if !isFront {
                if pulseAmount > 0.001 {
                    let phase = stageCount > 0 ? Double(stageIndex) / Double(stageCount) : 0
                    let wave = 0.5 + 0.5 * sin(2 * Double.pi * (now / max(0.1, pulseSeconds) - phase))
                    level *= 1 - pulseAmount * (1 - (0.30 + 0.70 * wave))
                }
                stageIndex += 1
            }
            let a = f.address - 1
            out[a] = DMXEngine.byte(level)
            out[a + 1] = DMXEngine.byte(color[0])
            out[a + 2] = DMXEngine.byte(color[1])
            out[a + 3] = DMXEngine.byte(color[2])
            out[a + 4] = DMXEngine.byte(color[3])
        }
        return out
    }

    // MARK: serial output

    static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbserial") }.sorted().map { "/dev/" + $0 }
    }

    private func resolvePort(_ setting: String) -> String? {
        if setting != "auto" && !setting.isEmpty { return setting }
        return DMXEngine.availablePorts().first
    }

    private static let TIOCMBIC_: UInt = 0x8004_746B

    private func openPort(_ path: String) -> Int32 {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return -1 }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD | CS8 | CSTOPB)           // 8 data bits, 2 stop bits
        t.c_cflag &= ~tcflag_t(PARENB | CCTS_OFLOW | CRTS_IFLOW)        // no parity, no flow control
        cfsetspeed(&t, speed_t(B38400))
        tcsetattr(fd, TCSANOW, &t)
        // The Open DMX USB only transmits with RTS (and DTR) de-asserted.
        var bits: Int32 = 0x004 | 0x002   // TIOCM_RTS | TIOCM_DTR
        _ = withUnsafeMutablePointer(to: &bits) { ioctl(fd, DMXEngine.TIOCMBIC_, $0) }
        return fd
    }

    private func setBaud(_ fd: Int32, _ baud: Int) -> Bool {
        var s = speed_t(baud)
        // IOSSIOSPEED = _IOW('T', 2, speed_t)
        let request: UInt = 0x8000_0000 | (UInt(MemoryLayout<speed_t>.size) << 16) | (UInt(UInt8(ascii: "T")) << 8) | 2
        return withUnsafeMutablePointer(to: &s) { ioctl(fd, request, $0) } == 0
    }

    private func sendFrame(_ fd: Int32, _ channels: [UInt8]) -> Bool {
        // Break + mark: one zero byte at a slow baud rate holds the line low for about 156 us.
        guard setBaud(fd, 57600) else { return false }
        var zero: UInt8 = 0
        guard write(fd, &zero, 1) == 1 else { return false }
        usleep(3000)
        guard setBaud(fd, 250_000) else { return false }
        let data = [UInt8(0)] + channels          // start code 0 + 512 channels
        guard write(fd, data, data.count) == data.count else { return false }
        usleep(25_000)                             // 513 bytes take 22.6 ms to leave at 250 kbaud
        return true
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        running = true
        startThreadIfNeeded()
    }

    /// The caller holds the lock.
    private func startThreadIfNeeded() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.loop() }
        t.name = "DMX output"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops sending. The last frames are a blackout, so the lights don't hold a look.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        running = false
    }

    private func closePort(_ fd: Int32) {
        guard fd >= 0 else { return }
        let dark = [UInt8](repeating: 0, count: 512)
        for _ in 0..<4 { _ = sendFrame(fd, dark) }
        close(fd)
    }

    private func loop() {
        var fd: Int32 = -1
        var reportedMissing = false
        var lastSetting: String?
        while true {
            lock.lock()
            let enabled = running
            let setting = portSetting
            lock.unlock()
            guard enabled else { break }
            if setting != lastSetting {
                closePort(fd)
                fd = -1
                lastSetting = setting
                reportedMissing = false
            }
            if fd < 0 {
                guard let path = resolvePort(setting) else {
                    if !reportedMissing { reportedMissing = true; onStatus?("No DMX interface found", false) }
                    sleep(1)
                    continue
                }
                fd = openPort(path)
                if fd < 0 {
                    if !reportedMissing { reportedMissing = true; onStatus?("Can't open \(path)", false) }
                    sleep(1)
                    continue
                }
                reportedMissing = false
                onStatus?("Sending DMX to \((path as NSString).lastPathComponent)", true)
            }
            if !sendFrame(fd, render()) {
                close(fd)
                fd = -1
                onStatus?("DMX interface disconnected", false)
                sleep(1)
            }
        }
        closePort(fd)
        onStatus?("DMX output off", false)
        lock.lock()
        thread = nil
        if running { startThreadIfNeeded() }
        lock.unlock()
    }
}
