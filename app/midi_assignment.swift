import SwiftUI

struct MIDIAssignment: Equatable {
    enum Kind: Int, CaseIterable {
        case note, cc, programChange

        var title: String {
            switch self {
            case .note: "Note"
            case .cc: "Control Change (CC)"
            case .programChange: "Program Change"
            }
        }
    }

    var source: String?
    var channel: Int?
    var kind: Kind
    var number: Int
}

struct MIDIAssignmentEditor: View {
    let sources: [String]
    let onApply: (MIDIAssignment) -> Void

    @State private var source: String
    @State private var channel: Int?
    @State private var kind: MIDIAssignment.Kind
    @State private var number: String

    init(mapping: Mapping, sources: [String], onApply: @escaping (MIDIAssignment) -> Void) {
        self.sources = Array(Set(sources)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.onApply = onApply
        _source = State(initialValue: mapping.source ?? "")
        _channel = State(initialValue: mapping.channel)
        if let note = mapping.note {
            _kind = State(initialValue: .note)
            _number = State(initialValue: String(note))
        } else if let cc = mapping.cc {
            _kind = State(initialValue: .cc)
            _number = State(initialValue: String(cc))
        } else if let program = mapping.programChange {
            _kind = State(initialValue: .programChange)
            _number = State(initialValue: String(program))
        } else {
            _kind = State(initialValue: mapping.action == "brightness" ? .cc : .note)
            _number = State(initialValue: "")
        }
    }

    private var assignment: MIDIAssignment? {
        guard let number = Int(number.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...127).contains(number) else { return nil }
        if let channel, !(1...16).contains(channel) { return nil }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return MIDIAssignment(source: source.isEmpty ? nil : source, channel: channel, kind: kind, number: number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MIDI Assignment").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Source")
                    HStack {
                        TextField("Any source", text: $source)
                            .accessibilityLabel("MIDI source")
                        Menu("Choose") {
                            Button("Any source") { source = "" }
                            ForEach(sources, id: \.self) { name in Button(name) { source = name } }
                        }
                        .accessibilityLabel("Choose MIDI source")
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("Channel")
                    Picker("MIDI channel", selection: $channel) {
                        Text("Any channel").tag(Int?.none)
                        ForEach(1...16, id: \.self) { value in Text(String(value)).tag(Int?.some(value)) }
                        if let channel, !(1...16).contains(channel) {
                            Text("Invalid channel (\(channel))").tag(Int?.some(channel))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Trigger")
                    Picker("MIDI trigger", selection: $kind) {
                        ForEach(MIDIAssignment.Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Number")
                    TextField("0–127", text: $number)
                        .accessibilityLabel("MIDI number, 0 to 127")
                }
            }
            HStack {
                Spacer()
                Button("Apply") {
                    guard let assignment else { return }
                    onApply(assignment)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(assignment == nil)
            }
        }
        .padding()
        .frame(width: 350)
    }
}
