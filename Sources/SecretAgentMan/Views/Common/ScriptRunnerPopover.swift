import SwiftUI

struct ScriptRunnerPopover: View {
    let scripts: [ProjectScript]
    let onRun: (ProjectScript) -> Void

    private var grouped: [(source: ProjectScript.ScriptSource, scripts: [ProjectScript])] {
        let dict = Dictionary(grouping: scripts) { $0.source }
        return ProjectScript.ScriptSource.allCases.compactMap { source in
            guard let items = dict[source], !items.isEmpty else { return nil }
            return (source: source, scripts: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scripts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Divider()

            if scripts.isEmpty {
                Text("No scripts detected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(grouped, id: \.source) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: group.source.icon)
                                        .font(.system(size: 9))
                                    Text(group.source.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)

                                ForEach(group.scripts) { script in
                                    ScriptRow(script: script, onRun: onRun)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(10)
        .frame(minWidth: 200)
    }
}

private struct ScriptRow: View {
    let script: ProjectScript
    let onRun: (ProjectScript) -> Void

    var body: some View {
        Button {
            onRun(script)
        } label: {
            HStack {
                Text(script.name)
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}

struct HoverHighlight: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(isHovered ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View {
        modifier(HoverHighlight())
    }
}
