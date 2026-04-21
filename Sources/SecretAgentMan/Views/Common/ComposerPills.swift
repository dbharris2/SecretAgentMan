import SwiftUI

struct ComposerPill: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(text)
            .scaledFont(size: 11)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.foreground.opacity(0.12), lineWidth: 1)
            )
    }
}

struct ComposerModePickerButton<Mode: Hashable>: View {
    let title: String
    let modes: [Mode]
    let currentMode: Mode
    let label: (Mode) -> String
    let shortcutKey: KeyEquivalent
    let shortcutModifiers: EventModifiers
    let shortcutLabel: String
    let onSelect: (Mode) -> Void

    @State private var isPresented = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text(label(currentMode))
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .hoverHighlight()
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.foreground.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcutKey, modifiers: shortcutModifiers)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ComposerModeList(
                title: title,
                shortcutLabel: shortcutLabel,
                modes: modes,
                currentMode: currentMode,
                label: label
            ) { mode in
                onSelect(mode)
                isPresented = false
            }
        }
    }
}

private struct ComposerModeList<Mode: Hashable>: View {
    let title: String
    let shortcutLabel: String
    let modes: [Mode]
    let currentMode: Mode
    let label: (Mode) -> String
    let onSelect: (Mode) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(shortcutLabel)
                    .scaledFont(size: 9, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(theme.foreground.opacity(0.08))
                    )
            }

            ForEach(modes, id: \.self) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    HStack {
                        Text(label(mode)).scaledFont(size: 12)
                        Spacer()
                        if currentMode == mode {
                            Image(systemName: "checkmark")
                                .scaledFont(size: 10)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .hoverHighlight()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(minWidth: 180, maxWidth: 220)
    }
}
