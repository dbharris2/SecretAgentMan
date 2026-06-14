import MarkdownUI
import SwiftUI

struct SessionMarkdownText: View {
    let text: String
    let fontScale: Double
    var allowsExpansion: Bool = false

    private static let collapsedMaxHeight: CGFloat = 320
    private static let expansionLineThreshold = 18
    private static let expansionCharacterThreshold = 1600

    private var shouldOfferExpansion: Bool {
        guard allowsExpansion else { return false }

        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if lineCount > Self.expansionLineThreshold { return true }
        if text.count > Self.expansionCharacterThreshold { return true }
        return text.contains("```") && lineCount > 10
    }

    private var markdownBody: some View {
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

    var body: some View {
        if shouldOfferExpansion {
            ExpandableMarkdownText(
                collapsedMaxHeight: Self.collapsedMaxHeight,
                content: { markdownBody }
            )
        } else {
            markdownBody
        }
    }
}

private struct ExpandableMarkdownText<Content: View>: View {
    let collapsedMaxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: isExpanded ? nil : collapsedMaxHeight, alignment: .topLeading)
                .clipped()

            Button(isExpanded ? "Show less" : "Show more") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }
            .buttonStyle(.link)
        }
    }
}

struct SessionTranscriptBubble: View {
    let kind: TranscriptItemKind
    let text: String
    let fontScale: Double
    var images: [Data] = []
    @Environment(\.appTheme) private var theme
    @State private var isContextActive = false

    private var isUser: Bool {
        kind == .userMessage
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

                    SessionMarkdownText(text: text, fontScale: fontScale, allowsExpansion: true)
                }
                .padding(Spacing.xxl)
                .background(SessionPanelTheme.backgroundColor(for: kind, in: theme))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.accent.opacity(isContextActive ? 0.7 : 0), lineWidth: 1.5)
                )
                .overlay(rightClickCatcher)
                .animation(.easeOut(duration: 0.18), value: isContextActive)
            }
        } else {
            // Assistant/system messages: no bubble, just text
            VStack(alignment: .leading, spacing: Spacing.md) {
                SessionMarkdownText(text: text, fontScale: fontScale, allowsExpansion: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accent.opacity(isContextActive ? 0.12 : 0))
            )
            .overlay(rightClickCatcher)
            .animation(.easeOut(duration: 0.18), value: isContextActive)
        }
    }

    private var rightClickCatcher: some View {
        RightClickContextMenu(
            menuTitle: "Copy message",
            onOpen: { isContextActive = true },
            onClose: { isContextActive = false },
            onSelect: performCopy
        )
    }

    private func performCopy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openImageData(_ data: Data) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sam-\(UUID().uuidString).png")
        try? data.write(to: tmp)
        NSWorkspace.shared.open(tmp)
    }
}

/// Transparent AppKit overlay that catches right-clicks and shows a single-item
/// context menu, while passing every other event through to the SwiftUI content
/// beneath it so text selection still works.
private struct RightClickContextMenu: NSViewRepresentable {
    let menuTitle: String
    let onOpen: () -> Void
    let onClose: () -> Void
    let onSelect: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.menuTitle = menuTitle
        view.onOpen = onOpen
        view.onClose = onClose
        view.onSelect = onSelect
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CatcherView else { return }
        view.menuTitle = menuTitle
        view.onOpen = onOpen
        view.onClose = onClose
        view.onSelect = onSelect
    }

    private final class CatcherView: NSView, NSMenuDelegate {
        var menuTitle: String = ""
        var onOpen: (() -> Void)?
        var onClose: (() -> Void)?
        var onSelect: (() -> Void)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.delegate = self
            let item = NSMenuItem(
                title: menuTitle,
                action: #selector(triggerSelect),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            return menu
        }

        func menuWillOpen(_: NSMenu) {
            onOpen?()
        }

        func menuDidClose(_: NSMenu) {
            onClose?()
        }

        @objc private func triggerSelect() {
            onSelect?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let current = NSApp.currentEvent else { return nil }
            switch current.type {
            case .rightMouseDown, .rightMouseUp:
                return bounds.contains(point) ? self : nil
            default:
                return nil
            }
        }
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

            SessionMarkdownText(text: text, fontScale: fontScale, allowsExpansion: true)
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

struct ApprovalModeButton: Identifiable {
    let id: String
    let label: String
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
    var modeButtons: [ApprovalModeButton] = []
    var onApproveAndSwitchMode: ((String) -> Void)?
    var actions: [ApprovalAction] = []
    var onSelectAction: ((ApprovalAction) -> Void)?
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

            if !actions.isEmpty, let onSelectAction {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(actions) { action in
                        if action.isDestructive {
                            Button {
                                onSelectAction(action)
                            } label: {
                                actionLabel(action.label)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(theme.red)
                        } else {
                            Button {
                                onSelectAction(action)
                            } label: {
                                actionLabel(action.label)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            } else if supportsDecisions {
                HStack(spacing: Spacing.lg) {
                    Button(action: onDecline) {
                        actionLabel(declineTitle)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.red)

                    Button(action: onApprove) {
                        actionLabel(approveTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    if let onApproveAndSwitchMode {
                        ForEach(modeButtons) { button in
                            Button {
                                onApproveAndSwitchMode(button.id)
                            } label: {
                                actionLabel(button.label)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
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

    private func actionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12, weight: .medium)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
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
                        Button {
                            onSelectOption?(option.label)
                        } label: {
                            promptButtonLabel(option.label)
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

    private func promptButtonLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12, weight: .medium)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
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
                    Button {
                        onSelect(option)
                    } label: {
                        promptButtonLabel(option.label)
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

    private func promptButtonLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12, weight: .medium)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
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

/// Standard "Return sends, Shift-Return inserts newline" key handling for
/// composer text editors. Use as the entire `onKeyPress` for simple composers,
/// or as a fall-through after handling provider-specific keys (slash menus,
/// etc.).
func handleComposerSubmitKeyPress(_ keyPress: KeyPress, send: () -> Void) -> KeyPress.Result {
    guard keyPress.key == .return else { return .ignored }
    if keyPress.modifiers.contains(.shift) { return .ignored }
    send()
    return .handled
}

struct SessionComposer<Suggestions: View, TrailingControls: View>: View {
    @Binding var draft: String
    @Binding var pendingImages: [PendingImage]
    var composerFocused: FocusState<Bool>.Binding
    let fontScale: Double
    let statusText: String
    let statusColor: Color
    let onKeyPress: (KeyPress) -> KeyPress.Result
    let onDraftChange: () -> Void
    @ViewBuilder let suggestions: () -> Suggestions
    @ViewBuilder let trailingControls: () -> TrailingControls
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            suggestions()

            VStack(alignment: .leading, spacing: Spacing.lg) {
                GrowingTextEditor(
                    text: $draft,
                    fontSize: 13 * fontScale,
                    fontDesign: .monospaced,
                    lineLimit: 1 ... 12,
                    focused: composerFocused,
                    focusOn: .focusComposer
                )
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
}

struct SessionStreamingBubble: View {
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
