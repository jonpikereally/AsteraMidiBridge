import SwiftUI

struct ConnectionSetup: Equatable {
    struct Fixture: Identifiable, Equatable {
        var id = UUID()
        var originalIndex: Int?
        var name: String
        var address: String
        var group: String
    }

    var inputs = ["*"]
    var excludedInputs: [String] = []
    var virtualPort = ""
    var outputMode = "bluetooth"
    var asteraHost = "127.0.0.1"
    var asteraPort = "8080"
    var dmxPort = "auto"
    var fixtures: [Fixture] = []

    init() {}

    init(config: Config) {
        inputs = config.inputs
        excludedInputs = config.exclude
        virtualPort = config.virtualPort ?? ""
        outputMode = config.outputMode
        asteraHost = config.host
        asteraPort = String(config.port)
        let dmx = config.root["dmx"] as? [String: Any] ?? [:]
        dmxPort = dmx["port"] as? String ?? "auto"
        let rawFixtures = dmx["fixtures"] as? [Any] ?? []
        fixtures = rawFixtures.enumerated().compactMap { index, item in
            guard let raw = item as? [String: Any], let address = raw["address"] as? Int else { return nil }
            return Fixture(originalIndex: index, name: raw["name"] as? String ?? "Tube \(address)",
                           address: String(address), group: raw["group"] as? String ?? "stage")
        }
    }

    func replacing(_ previous: ConnectionSetup, in root: [String: Any]) throws -> [String: Any] {
        var result = root
        if inputs != previous.inputs {
            result["midi_input"] = nil
            result["midi_inputs"] = inputs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        if excludedInputs != previous.excludedInputs {
            result["exclude_inputs"] = excludedInputs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        if virtualPort != previous.virtualPort {
            let name = virtualPort.trimmingCharacters(in: .whitespacesAndNewlines)
            result["virtual_port"] = name.isEmpty ? nil : name
            if !name.isEmpty, !previous.virtualPort.isEmpty,
               var mappings = result["mappings"] as? [[String: Any]] {
                for index in mappings.indices {
                    guard let source = mappings[index]["source"] as? String,
                          source.caseInsensitiveCompare(previous.virtualPort) == .orderedSame else { continue }
                    mappings[index]["source"] = name
                }
                result["mappings"] = mappings
            }
        }
        if outputMode != previous.outputMode { result["output_mode"] = outputMode }
        if asteraHost != previous.asteraHost || asteraPort != previous.asteraPort {
            let host = asteraHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let portText = asteraPort.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let port = Int(portText), (1...65535).contains(port) else {
                throw SetupError("Enter an AsteraApp port from 1 to 65535.")
            }
            var address = URLComponents()
            address.scheme = "http"
            address.host = host
            address.port = port
            guard !host.isEmpty, address.url != nil else { throw SetupError("Enter a valid AsteraApp host.") }
            var astera = result["astera"] as? [String: Any] ?? [:]
            astera["host"] = host
            astera["port"] = port
            result["astera"] = astera
        }
        if dmxPort != previous.dmxPort || fixtures != previous.fixtures {
            var dmx = result["dmx"] as? [String: Any] ?? [:]
            if dmxPort != previous.dmxPort {
                let port = dmxPort.trimmingCharacters(in: .whitespacesAndNewlines)
                dmx["port"] = port.isEmpty ? "auto" : port
            }
            if fixtures != previous.fixtures {
                let original = dmx["fixtures"] as? [Any] ?? []
                var occupied = Set<Int>()
                var updated: [Any] = try fixtures.map { fixture in
                    let name = fixture.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let address = Int(fixture.address), (1...508).contains(address) else {
                        throw SetupError("Enter a start address from 1 to 508 for every fixture.")
                    }
                    for channel in address...address + 4 {
                        guard occupied.insert(channel).inserted else {
                            throw SetupError("Fixtures overlap on DMX channel \(channel). Each fixture uses five channels.")
                        }
                    }
                    var entry: [String: Any] = [:]
                    if let index = fixture.originalIndex, original.indices.contains(index) {
                        entry = original[index] as? [String: Any] ?? [:]
                    }
                    entry["name"] = name.isEmpty ? "Tube \(address)" : name
                    entry["address"] = address
                    entry["group"] = fixture.group
                    return entry
                }
                let editableIndices = Set(previous.fixtures.compactMap(\.originalIndex))
                updated.append(contentsOf: original.enumerated().filter { !editableIndices.contains($0.offset) }.map(\.element))
                dmx["fixtures"] = updated
            }
            result["dmx"] = dmx
        }
        return result
    }
}

private struct SetupError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

struct ConnectionSetupView: View {
    @ObservedObject var b: Bridge
    @State private var draft = ConnectionSetup()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            midi
            output
            fixtures
            HStack {
                if let error {
                    Text(error).foregroundColor(.red)
                } else if draft != b.connectionSetup {
                    Text("Applying changes can affect MIDI routing and DMX output.")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Revert") { reset() }
                Button("Apply Setup") {
                    do {
                        try b.applyConnectionSetup(draft)
                        reset()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }.buttonStyle(.borderedProminent)
            }
            .disabled(draft == b.connectionSetup)
        }
        .onAppear { reset() }
        .onChange(of: b.connectionSetup) { _ in reset() }
    }

    private var midi: some View {
        GroupBox("MIDI inputs") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Include") {
                    TextField("One device name or pattern per line", text: lines($draft.inputs), axis: .vertical)
                        .lineLimit(1...4)
                    Menu("Add Source") {
                        ForEach(b.availableMIDISources, id: \.self) { name in
                            Button(name) {
                                draft.inputs.removeAll { $0 == "*" }
                                if !draft.inputs.contains(name) { draft.inputs.append(name) }
                            }
                        }
                    }
                    .disabled(b.availableMIDISources.isEmpty)
                }
                LabeledContent("Exclude") {
                    TextField("One device name or pattern per line", text: lines($draft.excludedInputs), axis: .vertical)
                        .lineLimit(1...4)
                }
                LabeledContent("Virtual input") {
                    TextField("Name (blank disables the port)", text: $draft.virtualPort)
                }
                Text("Use * to include all sources. Exclusions take priority. Other apps send MIDI to the virtual input.")
                    .font(.caption).foregroundColor(.secondary)
            }.padding(4)
        }
    }

    private var output: some View {
        GroupBox("Output protocol") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Send lights through", selection: $draft.outputMode) {
                    Text("Bluetooth (AsteraApp)").tag("bluetooth")
                    Text("DMX").tag("dmx")
                    Text("Both").tag("both")
                }.pickerStyle(.segmented)
                HStack {
                    TextField("AsteraApp host", text: $draft.asteraHost)
                    TextField("Port", text: $draft.asteraPort).frame(width: 104)
                }
                HStack {
                    TextField("DMX interface path (or auto)", text: $draft.dmxPort)
                    Menu("Choose Interface") {
                        Button("Automatic") { draft.dmxPort = "auto" }
                        ForEach(DMXEngine.availablePorts(), id: \.self) { path in
                            Button(path) { draft.dmxPort = path }
                        }
                    }
                }
            }.padding(4)
        }
    }

    private var fixtures: some View {
        GroupBox("DMX fixtures") {
            VStack(alignment: .leading, spacing: 8) {
                Text("DIM RGBW · five channels per fixture")
                    .font(.caption).foregroundColor(.secondary)
                if !draft.fixtures.isEmpty {
                    HStack {
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Start address").frame(width: 96, alignment: .leading)
                        Text("Group").frame(width: 120, alignment: .leading)
                        Color.clear.frame(width: 20, height: 1)
                    }.font(.caption).foregroundColor(.secondary)
                }
                ForEach($draft.fixtures) { $fixture in
                    HStack {
                        TextField("Name", text: $fixture.name)
                        TextField("Address", text: $fixture.address).frame(width: 96)
                        Picker("Group", selection: $fixture.group) {
                            Text("Stage").tag("stage")
                            Text("Front").tag("front")
                            if fixture.group != "stage" && fixture.group != "front" {
                                Text(fixture.group).tag(fixture.group)
                            }
                        }.labelsHidden().frame(width: 120)
                        Button {
                            let id = fixture.id
                            draft.fixtures.removeAll { $0.id == id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(fixture.name)")
                        .frame(width: 20)
                    }
                }
                Button("Add Fixture") { addFixture() }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lines(_ items: Binding<[String]>) -> Binding<String> {
        Binding {
            items.wrappedValue.joined(separator: "\n")
        } set: { text in
            items.wrappedValue = text.components(separatedBy: "\n")
        }
    }

    private func addFixture() {
        let addresses = draft.fixtures.compactMap { Int($0.address) }.filter { (1...508).contains($0) }
        let available = (1...508).first { start in addresses.allSatisfy { abs($0 - start) >= 5 } }
        let address = available.map(String.init) ?? ""
        let name = available.map { "Tube \($0)" } ?? ""
        draft.fixtures.append(.init(name: name, address: address, group: "stage"))
    }

    private func reset() {
        draft = b.connectionSetup
        error = nil
    }
}
