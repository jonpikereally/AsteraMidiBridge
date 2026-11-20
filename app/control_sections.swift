import SwiftUI

enum ControlSection: String, CaseIterable, Identifiable {
    case nowPlaying
    case scenes
    case brightness
    case targetsAndPower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .scenes: "Scenes"
        case .brightness: "Brightness"
        case .targetsAndPower: "Targets and power"
        }
    }

    static func ordered(from stored: String) -> [ControlSection] {
        var remaining = Set(allCases)
        let saved = stored.split(separator: ",")
            .compactMap { ControlSection(rawValue: String($0)) }
            .filter { remaining.remove($0) != nil }
        return saved + allCases.filter { remaining.contains($0) }
    }
}

struct ControlSectionOrderEditor: View {
    @Binding var order: String

    var body: some View {
        let sections = ControlSection.ordered(from: order)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sections) { section in
                HStack {
                    Text(section.title)
                    Spacer()
                    Button {
                        move(section, by: -1)
                    } label: {
                        Label("Move \(section.title) up", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(section == sections.first)

                    Button {
                        move(section, by: 1)
                    } label: {
                        Label("Move \(section.title) down", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(section == sections.last)
                }
            }
        }
        .padding()
        .frame(minWidth: 240)
    }

    private func move(_ section: ControlSection, by offset: Int) {
        var sections = ControlSection.ordered(from: order)
        guard let index = sections.firstIndex(of: section),
              sections.indices.contains(index + offset) else { return }
        sections.swapAt(index, index + offset)
        order = sections.map(\.rawValue).joined(separator: ",")
    }
}
