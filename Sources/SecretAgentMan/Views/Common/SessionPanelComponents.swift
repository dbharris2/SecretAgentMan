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

    let kind: TranscriptItemKind
    let label: String
    let text: String
    let fontScale: Double
    var images: [Data] = []
    @Environment(\.appTheme) private var theme

    private var isUser: Bool {
        kind == .userMessage
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

                VStack(alignment: .trailing, spacing: Spacing.lg) {
                    if !images.isEmpty {
                        HStack(spacing: Spacing.md) {
                            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                                if let nsImage = NSImage(data: data) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(maxWidth: 200, maxHeight: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .onTapGesture { openImageData(data) }
                                }
                            }
                        }
                    }

                    SessionMarkdownText(text: text, fontScale: fontScale)
                }
                .padding(Spacing.xxl)
                .background(SessionPanelTheme.backgroundColor(for: kind, in: theme))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            // Assistant/system messages: no bubble, just text
            VStack(alignment: .leading, spacing: Spacing.md) {
                SessionMarkdownText(text: text, fontScale: fontScale)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openImageData(_ data: Data) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sam-\(UUID().uuidString).png")
        try? data.write(to: tmp)
        NSWorkspace.shared.open(tmp)
    }
}

struct SessionTodoCard: View {
    let text: String
    let fontScale: Double
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            Image(systemName: "checklist")
                .foregroundStyle(theme.accent)

            SessionMarkdownText(text: text, fontScale: fontScale)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accent.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.accent.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    var onApproveAndSwitchMode: ((String) -> Void)?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text(title)
                .scaledFont(size: 12, weight: .semibold)

            if !detail.isEmpty {
                Text(detail)
                    .scaledFont(size: 12)
                    .textSelection(.enabled)
            }

            if supportsDecisions {
                HStack(spacing: Spacing.lg) {
                    Button(declineTitle, action: onDecline)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(theme.red)

                    Button(approveTitle, action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    if let onApproveAndSwitchMode {
                        Button("Accept Edits") {
                            onApproveAndSwitchMode("acceptEdits")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Auto") {
                            onApproveAndSwitchMode("auto")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            } else {
                Text(unsupportedText)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SessionLiveToolCard: View {
    let title: String
    let detail: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack(spacing: Spacing.lg) {
                Text("Live")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(theme.blue)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 3)
                    .background(theme.blue.opacity(0.12))
                    .clipShape(Capsule())

                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
            }

            ScrollView {
                Text(detail)
                    .scaledFont(size: 12)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .padding(Spacing.lg)
            .background(theme.background.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SessionElicitationCard: View {
    let message: String
    var options: [PromptOption] = []
    var onSelectOption: ((String) -> Void)?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.md) {
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

            if options.isEmpty {
                Text("Type your answer in the composer below.")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: Spacing.lg) {
                    ForEach(options) { option in
                        Button(option.label) {
                            onSelectOption?(option.label)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help(option.description ?? "")
                    }
                }

                Text("Or type a custom answer in the composer below.")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SessionQuestionCard: View {
    let title: String
    let detail: String
    let options: [PromptOption]
    let onSelect: (PromptOption) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            if !title.isEmpty {
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
            }

            if !detail.isEmpty {
                Text(detail)
                    .scaledFont(size: 12)
                    .textSelection(.enabled)
            }

            HStack(spacing: Spacing.lg) {
                ForEach(options) { option in
                    Button(option.label) {
                        onSelect(option)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(option.description ?? "")
                }
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
    let mediaType: String

    var nsImage: NSImage? {
        NSImage(data: data)
    }

    func openInPreview() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sam-\(id.uuidString).png")
        try? data.write(to: tmp)
        NSWorkspace.shared.open(tmp)
    }
}

struct SessionComposer<Suggestions: View, TrailingControls: View>: View {
    @Binding var draft: String
    @Binding var pendingImages: [PendingImage]
    var composerFocused: FocusState<Bool>.Binding
    let fontScale: Double
    let statusText: String
    let statusColor: Color
    let onSend: () -> Void
    let onKeyPress: (KeyPress) -> KeyPress.Result
    let onDraftChange: () -> Void
    @ViewBuilder let suggestions: () -> Suggestions
    @ViewBuilder let trailingControls: () -> TrailingControls
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            suggestions()

            VStack(alignment: .leading, spacing: Spacing.lg) {
                TextEditor(text: $draft)
                    .focused(composerFocused)
                    .font(.system(size: 13 * fontScale, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 140)
                    .padding(Spacing.lg)
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.lg) {
                            ForEach(pendingImages) { img in
                                pendingImageThumbnail(img)
                            }
                        }
                        .padding(.horizontal, Spacing.lg)
                    }
                }

                HStack {
                    Text(statusText)
                        .scaledFont(size: 11)
                        .foregroundStyle(statusColor)

                    Spacer()

                    trailingControls()
                }
            }
            .padding(Spacing.xxl)
            .background(theme.surface)
        }
    }

    private func pendingImageThumbnail(_ img: PendingImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = img.nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.foreground.opacity(0.15), lineWidth: 1)
            )
            .onTapGesture { img.openInPreview() }

            Button {
                pendingImages.removeAll { $0.id == img.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
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
        return true
    }
}

enum SessionPanelTheme {
    static func backgroundColor(for kind: TranscriptItemKind, in theme: AppTheme) -> Color {
        switch kind {
        case .userMessage:
            theme.accent.opacity(0.08)
        case .assistantMessage:
            theme.foreground.opacity(0.04)
        case .systemMessage, .toolActivity, .plan, .diffSummary, .error, .thought:
            theme.yellow.opacity(0.08)
        }
    }

    static func label(for kind: TranscriptItemKind, providerName: String) -> String {
        switch kind {
        case .userMessage: "You"
        case .assistantMessage: providerName
        case .systemMessage, .toolActivity, .plan, .diffSummary, .error, .thought: "System"
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
        HStack(spacing: Spacing.lg) {
            ProgressView()
                .controlSize(.small)

            Text(label)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
        }
    }
}
