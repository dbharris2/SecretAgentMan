import MarkdownUI
import SwiftUI

struct SessionMarkdownText: View {
    let text: String
    let fontScale: Double

    var body: some View {
        Markdown(text)
            .markdownTextStyle {
                FontSize(13 * fontScale)
            }
            .markdownTextStyle(\.code) {
                FontSize(12 * fontScale)
                FontFamilyVariant(.monospaced)
            }
            .markdownTheme(.docC)
            .textSelection(.enabled)
    }
}

struct SessionTranscriptBubble: View {
    private static let maxBubbleWidth: CGFloat = 720

    let role: CodexTranscriptRole
    let label: String
    let text: String
    let fontScale: Double
    @Environment(\.appTheme) private var theme

    private var isUser: Bool {
        role == .user
    }

    private var contentAlignment: HorizontalAlignment {
        isUser ? .leading : .trailing
    }

    private var frameAlignment: Alignment {
        isUser ? .leading : .trailing
    }

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 40)

                SessionMarkdownText(text: text, fontScale: fontScale)
                    .padding(12)
                    .background(SessionPanelTheme.backgroundColor(for: role, in: theme))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            // Assistant/system messages: no bubble, just text
            VStack(alignment: .leading, spacing: 6) {
                SessionMarkdownText(text: text, fontScale: fontScale)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SessionApprovalCard: View {
    let title: String
    let detail: String
    let approveTitle: String
    let declineTitle: String
    let supportsDecisions: Bool
    let unsupportedText: String
    let onApprove: () -> Void
    let onDecline: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(size: 12, weight: .semibold)

            if !detail.isEmpty {
                Text(detail)
                    .scaledFont(size: 12)
                    .textSelection(.enabled)
            }

            if supportsDecisions {
                HStack(spacing: 8) {
                    Button(declineTitle, action: onDecline)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button(approveTitle, action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else {
                Text(unsupportedText)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SessionElicitationCard: View {
    let message: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(theme.blue)
                Text("Response Required")
                    .scaledFont(size: 12, weight: .semibold)
            }

            if !message.isEmpty {
                Text(message)
                    .scaledFont(size: 12)
                    .textSelection(.enabled)
            }

            Text("Type your answer in the composer below.")
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SessionQuestionCard: View {
    let title: String
    let detail: String
    let options: [CodexUserInputOption]
    let onSelect: (CodexUserInputOption) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty {
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
            }

            if !detail.isEmpty {
                Text(detail)
                    .scaledFont(size: 12)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                ForEach(options) { option in
                    Button(option.label) {
                        onSelect(option)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(option.description)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PendingImage {
    let data: Data
    let mediaType: String
}

struct SessionComposer<Suggestions: View, TrailingControls: View>: View {
    @Binding var draft: String
    @Binding var pendingImages: [PendingImage]
    let fontScale: Double
    let statusText: String
    let statusColor: Color
    let sendDisabled: Bool
    let onSend: () -> Void
    let onKeyPress: (KeyPress) -> KeyPress.Result
    let onDraftChange: () -> Void
    @ViewBuilder let suggestions: () -> Suggestions
    @ViewBuilder let trailingControls: () -> TrailingControls
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            suggestions()

            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(size: 13 * fontScale, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 140)
                    .padding(8)
                    .background(theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onKeyPress(phases: .down) { keyPress in
                        if keyPress.key == .init("v"), keyPress.modifiers.contains(.command),
                           pasteImageFromClipboard() {
                            return .handled
                        }
                        return onKeyPress(keyPress)
                    }
                    .onChange(of: draft) { _, _ in
                        onDraftChange()
                    }

                if !pendingImages.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                            .scaledFont(size: 11)
                        Text("\(pendingImages.count) image\(pendingImages.count == 1 ? "" : "s") attached")
                            .scaledFont(size: 11)
                        Button {
                            pendingImages.removeAll()
                            draft = draft.replacingOccurrences(of: " [Image]", with: "")
                                .replacingOccurrences(of: "[Image]", with: "")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .scaledFont(size: 11)
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }

                HStack {
                    Text(statusText)
                        .scaledFont(size: 11)
                        .foregroundStyle(statusColor)

                    Spacer()

                    trailingControls()

                    Button("Send") {
                        onSend()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(sendDisabled)
                }
            }
            .padding(12)
            .background(theme.surface)
        }
    }

    private func pasteImageFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        guard pb.canReadItem(withDataConformingToTypes: [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
        ]) else { return false }

        guard let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return false }

        pendingImages.append(PendingImage(data: png, mediaType: "image/png"))
        draft += draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "[Image]" : " [Image]"
        return true
    }
}

enum SessionPanelTheme {
    static func backgroundColor(for role: CodexTranscriptRole, in theme: AppTheme) -> Color {
        switch role {
        case .user:
            theme.accent.opacity(0.08)
        case .assistant:
            theme.foreground.opacity(0.04)
        case .system:
            theme.yellow.opacity(0.08)
        }
    }

    static func label(for role: CodexTranscriptRole, providerName: String) -> String {
        switch role {
        case .user: "You"
        case .assistant: providerName
        case .system: "System"
        }
    }
}

struct SessionStreamingBubble: View {
    let providerName: String
    let text: String
    let fontScale: Double

    var body: some View {
        SessionMarkdownText(text: text, fontScale: fontScale)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionThinkingBubble: View {
    let providerName: String
    var activeTool: String?

    private var label: String {
        if let activeTool {
            return "Running \(activeTool)…"
        }
        return "\(providerName) is thinking…"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text(label)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
        }
    }
}
