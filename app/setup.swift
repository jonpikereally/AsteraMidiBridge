import SwiftUI

struct ConnectionSetup: Equatable {
    var inputs = ["*"]
    var excludedInputs: [String] = []
    var virtualPort = ""
    var asteraHost = "127.0.0.1"
    var asteraPort = "8080"

    init() {}

    init(config: Config) {
        inputs = config.inputs
        excludedInputs = config.exclude
        virtualPort = config.virtualPort ?? ""
        asteraHost = config.host
        asteraPort = String(config.port)
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
            asteraConnection
            HStack {
                if let error {
                    Text(error).foregroundColor(.red)
                } else if draft != b.connectionSetup {
                    Text("Applying changes can affect MIDI routing and the AsteraApp connection.")
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

    private var asteraConnection: some View {
        GroupBox("AsteraApp connection") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Host") {
                    TextField("AsteraApp host", text: $draft.asteraHost)
                }
                LabeledContent("Port") {
                    TextField("AsteraApp port", text: $draft.asteraPort)
                }
            }.padding(4)
        }
    }

    private func lines(_ items: Binding<[String]>) -> Binding<String> {
        Binding {
            items.wrappedValue.joined(separator: "\n")
        } set: { text in
            items.wrappedValue = text.components(separatedBy: "\n")
        }
    }

    private func reset() {
        draft = b.connectionSetup
        error = nil
    }
}
