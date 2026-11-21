import SwiftUI
import UniformTypeIdentifiers

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

    static func moving(_ section: ControlSection, to destination: ControlSection, in stored: String) -> String {
        var sections = ordered(from: stored)
        guard section != destination,
              let sourceIndex = sections.firstIndex(of: section),
              let destinationIndex = sections.firstIndex(of: destination) else { return stored }
        sections.remove(at: sourceIndex)
        sections.insert(section, at: destinationIndex)
        return sections.map(\.rawValue).joined(separator: ",")
    }

    static let dragType = UTType(exportedAs: "com.jonpike.asteramidibridge.control-section")
}

struct ControlSectionDragHandle: View {
    let section: ControlSection
    @Binding var order: String

    var body: some View {
        let sections = ControlSection.ordered(from: order)

        Image(systemName: "line.3.horizontal")
            .font(.body.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
            .help("Drag to reorder \(section.title)")
            .accessibilityLabel("Reorder \(section.title)")
            .accessibilityAdjustableAction { direction in
                guard let index = sections.firstIndex(of: section) else { return }
                let next = direction == .increment ? index + 1 : index - 1
                guard sections.indices.contains(next) else { return }
                order = ControlSection.moving(section, to: sections[next], in: order)
            }
            .onDrag {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: ControlSection.dragType.identifier,
                                                    visibility: .ownProcess) { completion in
                    completion(Data(section.rawValue.utf8), nil)
                    return nil
                }
                return provider
            }
    }
}

struct ControlSectionDropTarget: ViewModifier {
    let section: ControlSection
    @Binding var order: String
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrop(of: [ControlSection.dragType], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(forTypeIdentifier: ControlSection.dragType.identifier) { data, _ in
                    guard let data, let id = String(data: data, encoding: .utf8),
                          let dragged = ControlSection(rawValue: id), dragged != section else { return }
                    DispatchQueue.main.async {
                        order = ControlSection.moving(dragged, to: section, in: order)
                    }
                }
                return true
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}
