import SwiftUI

struct GeminiSessionPanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme

    let agent: Agent

    @State private var draft = ""
    @State private var pendingImages: [PendingImage] = []
    @FocusState private var composerFocused: Bool

    private var snapshot: AgentSessionSnapshot? {
        coordinator.agentSessions.snapshots[agent.id]
    }

    private var transcript: [SessionTranscriptItem] {
        snapshot?.finalizedTranscript ?? []
    }

    private var pendingApproval: ApprovalPrompt? {
        snapshot?.approvalPrompt
    }

    private var streamingText: String? {
        snapshot?.streamingAssistantText
    }

    private var isThinking: Bool {
        agent.state == .active && streamingText == nil
    }

    private var activeTool: String? {
        snapshot?.metadata.activeToolName
    }

    private var availableModes: [SessionModeInfo] {
        snapshot?.metadata.availableModes ?? []
    }

    private var currentModeId: String? {
        snapshot?.metadata.currentModeId
    }

    private var availableModels: [SessionModelInfo] {
        snapshot?.metadata.availableModels ?? []
    }

    private var currentModelName: String {
        if let id = snapshot?.metadata.currentModelId,
           let model = availableModels.first(where: { $0.id == id }) {
            return model.name
        }
        if let name = snapshot?.metadata.displayModelName, !name.isEmpty {
            return name
        }
        return "Gemini"
    }

    var body: some View {
        SessionPanelShell(agent: agent, composerFocused: $composerFocused) {
            SessionChatView(
                providerName: "Gemini",
                transcript: transcript,
                streaming: streamingText,
                isThinking: isThinking,
                activeTool: activeTool,
                hasPendingCard: pendingApproval != nil,
                fontScale: fontScale,
                emptyStateText: "Gemini session is starting. Send a message to begin."
            ) {
                AnyView(Group {
                    if let pendingApproval {
                        approvalCard(pendingApproval)
                    }
                })
            }
        } composer: {
            composer
        }
    }

    private var composer: some View {
        SessionComposer(
            draft: $draft,
            pendingImages: $pendingImages,
            composerFocused: $composerFocused,
            fontScale: fontScale,
            statusText: "",
            statusColor: .secondary,
            onSend: sendDraft,
            onKeyPress: handleComposerKeyPress,
            onDraftChange: {}
        ) {
            EmptyView()
        } trailingControls: {
            HStack(spacing: 6) {
                ComposerPill(text: currentModelName)
                if !availableModes.isEmpty {
                    Menu {
                        ForEach(availableModes) { mode in
                            Button {
                                coordinator.setGeminiMode(for: agent.id, modeId: mode.id)
                            } label: {
                                if mode.id == currentModeId {
                                    Label(mode.name, systemImage: "checkmark")
                                } else {
                                    Text(mode.name)
                                }
                            }
                        }
                    } label: {
                        ComposerPill(text: currentModeId.flatMap { id in
                            availableModes.first(where: { $0.id == id })?.name
                        } ?? "Mode")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
    }

    private func handleComposerKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == .return {
            if keyPress.modifiers.contains(.shift) {
                return .ignored
            }
            sendDraft()
            return .handled
        }
        return .ignored
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        let sendText = text.isEmpty ? "[Image]" : text
        let imageData = pendingImages.map(\.data)
        coordinator.sendGeminiMessage(for: agent.id, text: sendText, imageData: imageData)
        draft = ""
        pendingImages.removeAll()
    }

    /// Renders Gemini's typed approval actions directly. Allow_once is the
    /// primary button; reject_once is the destructive button; everything
    /// else (allow_always, reject_always, plus any future kinds the agent
    /// adds) appears as a bordered secondary action. Avoids reusing the
    /// Codex-shaped `SessionApprovalCard` which hardcodes "Accept Edits" /
    /// "Auto" mode buttons that don't apply to Gemini.
    private func approvalCard(_ prompt: ApprovalPrompt) -> some View {
        let primary = prompt.actions.first { $0.kind == .allowOnce }
            ?? prompt.actions.first { !$0.isDestructive }
        let destructive = prompt.actions.first { $0.kind == .rejectOnce }
            ?? prompt.actions.first { $0.isDestructive }
        let secondary = prompt.actions.filter { action in
            action.id != primary?.id && action.id != destructive?.id
        }

        return VStack(alignment: .leading, spacing: Spacing.xl) {
            Text(prompt.title)
                .scaledFont(size: 12, weight: .semibold)
            if !prompt.message.isEmpty {
                Text(prompt.message)
                    .scaledFont(size: 12)
                    .textSelection(.enabled)
            }

            FlowLayout(spacing: Spacing.lg) {
                if let destructive {
                    Button(destructive.label) {
                        coordinator.answerGeminiApproval(for: agent.id, optionId: destructive.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.red)
                }
                if let primary {
                    Button(primary.label) {
                        coordinator.answerGeminiApproval(for: agent.id, optionId: primary.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                ForEach(secondary) { action in
                    Button(action.label) {
                        coordinator.answerGeminiApproval(for: agent.id, optionId: action.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Simple flow layout that wraps action buttons to a new row when the
/// container is narrower than their combined intrinsic width.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let needed = (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            if rowWidth + needed > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([size])
                rowWidth = size.width
            } else {
                rows[rows.count - 1].append(size)
                rowWidth += needed
            }
        }
        let totalWidth = rows.map { row in
            row.reduce(0) { $0 + $1.width } + max(0, CGFloat(row.count - 1)) * spacing
        }.max() ?? 0
        let totalHeight = rows.reduce(0) { acc, row in
            acc + (row.map(\.height).max() ?? 0)
        } + max(0, CGFloat(rows.count - 1)) * spacing
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            // `.topLeading` so the (x, y) we computed is the actual upper-left
            // origin. The default `.center` would offset every subview by half
            // its own size, making the visible button clip out of its real
            // hit-test region — which is what was eating click events.
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
