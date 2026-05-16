import SwiftUI

struct ClaudeSessionPanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme

    let agent: Agent

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
                            // Clear any half-typed custom answer in the composer.
                            coordinator.composerInsert = ""
                        }
                    }

                    if let pendingApproval {
                        approvalCard(pendingApproval)
                    }
                })
            }
        } composer: {
            ClaudeComposerView(
                agent: agent,
                slashCommands: snapshot?.metadata.slashCommands ?? [],
                displayModelName: snapshot?.metadata.displayModelName ?? "Claude",
                permissionMode: snapshot?.metadata.permissionMode
                    ?? ClaudeStreamMonitor.defaultPermissionMode,
                pendingElicitation: pendingElicitation,
                composerFocused: $composerFocused
            )
        }
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
            modeButtons: [
                ApprovalModeButton(id: "acceptEdits", label: "Accept Edits"),
                ApprovalModeButton(id: "auto", label: "Auto"),
            ],
            onApproveAndSwitchMode: { mode in
                coordinator.answerClaudeApproval(for: agent.id, accept: true)
                coordinator.claudeMonitor.setPermissionMode(for: agent.id, mode: mode)
            }
        )
    }
}

/// Owns the per-keystroke draft state so typing only invalidates the composer
/// subtree — the panel body (which renders the full transcript via MarkdownUI)
/// stays put.
private struct ClaudeComposerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme

    let agent: Agent
    let slashCommands: [SessionSlashCommand]
    let displayModelName: String
    let permissionMode: String
    let pendingElicitation: UserInputPrompt?
    var composerFocused: FocusState<Bool>.Binding

    @State private var draft = ""
    @State private var pendingImages: [PendingImage] = []
    @State private var slashSelectionIndex = 0

    private var slashSuggestions: [SessionSlashCommand] {
        let stripped = draft.replacingOccurrences(of: "\n", with: "")
        guard stripped.hasPrefix("/"), !stripped.contains(" ") else { return [] }
        let query = String(stripped.dropFirst()).lowercased()
        if query.isEmpty { return slashCommands }
        return slashCommands.filter { $0.name.lowercased().hasPrefix(query) }
    }

    var body: some View {
        SessionComposer(
            draft: $draft,
            pendingImages: $pendingImages,
            composerFocused: composerFocused,
            fontScale: fontScale,
            statusText: pendingElicitation != nil ? "Answering question..." : "",
            statusColor: pendingElicitation != nil ? theme.yellow : .secondary,
            onKeyPress: handleComposerKeyPress,
            onDraftChange: { slashSelectionIndex = 0 }
        ) {
            if !slashSuggestions.isEmpty {
                slashCommandList
            }
        } trailingControls: {
            HStack(spacing: 6) {
                ComposerPill(text: displayModelName)
                ComposerModePickerButton(
                    title: "Mode",
                    modes: ClaudeStreamMonitor.permissionModes,
                    currentMode: permissionMode,
                    label: { $0 },
                    shortcutKey: "m",
                    shortcutModifiers: [.command, .shift],
                    shortcutLabel: "⌘⇧M"
                ) { mode in
                    coordinator.claudeMonitor.setPermissionMode(for: agent.id, mode: mode)
                }
            }
        }
        .onChange(of: coordinator.composerInsert) { _, text in
            if let text {
                draft = text
                coordinator.composerInsert = nil
            }
        }
    }

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
        return handleComposerSubmitKeyPress(keyPress, send: sendDraft)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        if pendingElicitation != nil {
            coordinator.answerClaudeElicitation(for: agent.id, answer: text)
        } else {
            let images = pendingImages
            coordinator.sendClaudeMessage(
                for: agent.id,
                text: text.isEmpty ? "[Image]" : text,
                images: images.map { ($0.data, $0.mediaType) }
            )
        }
        draft = ""
        pendingImages.removeAll()
    }
}
