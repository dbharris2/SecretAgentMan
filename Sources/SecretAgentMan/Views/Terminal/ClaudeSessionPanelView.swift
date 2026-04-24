import SwiftUI

struct ClaudeSessionPanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme

    let agent: Agent

    @State private var draft = ""
    @State private var slashSelectionIndex = 0
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

    private var pendingElicitation: UserInputPrompt? {
        snapshot?.userInputPrompt
    }

    private var streaming: String? {
        snapshot?.streamingAssistantText
    }

    private var activeTool: String? {
        snapshot?.metadata.activeToolName
    }

    private var isThinking: Bool {
        agent.state == .active && streaming == nil
    }

    private var slashSuggestions: [SessionSlashCommand] {
        let stripped = draft.replacingOccurrences(of: "\n", with: "")
        guard stripped.hasPrefix("/"), !stripped.contains(" ") else { return [] }
        let query = String(stripped.dropFirst()).lowercased()
        let commands = snapshot?.metadata.slashCommands ?? []
        if query.isEmpty { return commands }
        return commands.filter { $0.name.lowercased().hasPrefix(query) }
    }

    var body: some View {
        SessionPanelShell(agent: agent, composerFocused: $composerFocused) {
            SessionChatView(
                providerName: "Claude",
                transcript: transcript,
                streaming: streaming,
                isThinking: isThinking,
                activeTool: activeTool,
                hasPendingCard: pendingApproval != nil || pendingElicitation != nil,
                fontScale: fontScale,
                emptyStateText: "Claude session is ready. Send a message to start."
            ) {
                AnyView(Group {
                    if let pendingElicitation {
                        SessionElicitationCard(
                            message: pendingElicitation.message,
                            options: pendingElicitation.questions.first?.options ?? []
                        ) { label in
                            coordinator.answerClaudeElicitation(for: agent.id, answer: label)
                            draft = ""
                        }
                    }

                    if let pendingApproval {
                        approvalCard(pendingApproval)
                    }
                })
            }
        } composer: {
            composer
        }
        .onChange(of: coordinator.composerInsert) { _, text in
            if let text {
                draft = text
                coordinator.composerInsert = nil
            }
        }
    }

    // MARK: - Slash Command Suggestions

    private var slashCommandList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(slashSuggestions.enumerated()), id: \.element.name) { index, command in
                        Button {
                            draft = "/\(command.name) "
                            slashSelectionIndex = 0
                        } label: {
                            HStack(alignment: .top, spacing: Spacing.lg) {
                                Text("/\(command.name)")
                                    .scaledFont(size: 13, weight: .medium, design: .monospaced)
                                    .frame(width: 140, alignment: .leading)

                                if !command.description.isEmpty {
                                    Text(command.description)
                                        .scaledFont(size: 11)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.xxl)
                            .padding(.vertical, Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(index == slashSelectionIndex ? theme.accent.opacity(0.2) : .clear)
                        .id(command.name)
                    }
                }
            }
            .onChange(of: slashSelectionIndex) { _, idx in
                if idx < slashSuggestions.count {
                    proxy.scrollTo(slashSuggestions[idx].name, anchor: .center)
                }
            }
        }
        .frame(maxHeight: 200)
        .background(theme.surface)
    }

    // MARK: - Composer

    private var composer: some View {
        SessionComposer(
            draft: $draft,
            pendingImages: $pendingImages,
            composerFocused: $composerFocused,
            fontScale: fontScale,
            statusText: pendingElicitation != nil ? "Answering question..." : "",
            statusColor: pendingElicitation != nil ? theme.yellow : .secondary,
            onSend: sendDraft,
            onKeyPress: handleComposerKeyPress,
            onDraftChange: { slashSelectionIndex = 0 }
        ) {
            if !slashSuggestions.isEmpty {
                slashCommandList
            }
        } trailingControls: {
            HStack(spacing: 6) {
                ComposerPill(
                    text: snapshot?.metadata.displayModelName ?? "Claude"
                )
                ComposerModePickerButton(
                    title: "Mode",
                    modes: ClaudeStreamMonitor.permissionModes,
                    currentMode: snapshot?.metadata.permissionMode
                        ?? ClaudeStreamMonitor.defaultPermissionMode,
                    label: { $0 },
                    shortcutKey: "m",
                    shortcutModifiers: [.command, .shift],
                    shortcutLabel: "⌘⇧M"
                ) { mode in
                    coordinator.claudeMonitor.setPermissionMode(for: agent.id, mode: mode)
                }
            }
        }
    }

    private func handleComposerKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let suggestions = slashSuggestions
        if !suggestions.isEmpty {
            if keyPress.key == .downArrow {
                slashSelectionIndex = min(slashSelectionIndex + 1, suggestions.count - 1)
                return .handled
            }
            if keyPress.key == .upArrow {
                slashSelectionIndex = max(slashSelectionIndex - 1, 0)
                return .handled
            }
            if keyPress.key == .return, !keyPress.modifiers.contains(.shift) {
                let selected = suggestions[slashSelectionIndex]
                draft = "/\(selected.name) "
                slashSelectionIndex = 0
                return .handled
            }
            if keyPress.key == .escape {
                draft = ""
                return .handled
            }
        }
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
        if pendingElicitation != nil {
            coordinator.answerClaudeElicitation(for: agent.id, answer: text)
        } else {
            let images = pendingImages
            coordinator.sendClaudeMessage(for: agent.id, text: text.isEmpty ? "[Image]" : text, images: images.map { ($0.data, $0.mediaType) })
        }
        draft = ""
        pendingImages.removeAll()
    }

    private func approvalCard(_ prompt: ApprovalPrompt) -> some View {
        SessionApprovalCard(
            title: "Tool Approval: \(prompt.title)",
            detail: prompt.message,
            approveTitle: "Allow",
            declineTitle: "Deny",
            supportsDecisions: true,
            unsupportedText: "",
            onApprove: {
                coordinator.answerClaudeApproval(for: agent.id, accept: true)
            },
            onDecline: {
                coordinator.answerClaudeApproval(for: agent.id, accept: false)
            },
            onApproveAndSwitchMode: { mode in
                coordinator.answerClaudeApproval(for: agent.id, accept: true)
                coordinator.claudeMonitor.setPermissionMode(for: agent.id, mode: mode)
            }
        )
    }
}
