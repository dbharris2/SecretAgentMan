import SwiftUI

struct CodexSessionPanelView: View {
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

    private var pendingInput: UserInputPrompt? {
        snapshot?.userInputPrompt
    }

    private var pendingApproval: ApprovalPrompt? {
        snapshot?.approvalPrompt
    }

    private var debugMessage: String? {
        coordinator.codexMonitor.debugMessages[agent.id]
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

    private var currentModelName: String {
        let name = snapshot?.metadata.displayModelName
        return (name?.isEmpty == false ? name : nil) ?? "Codex"
    }

    private var currentCollaborationMode: CodexCollaborationMode {
        let raw = snapshot?.metadata.collaborationMode
        return raw.flatMap(CodexCollaborationMode.init(rawValue:)) ?? .default
    }

    var body: some View {
        SessionPanelShell(agent: agent, composerFocused: $composerFocused) {
            SessionChatView(
                providerName: "Codex",
                transcript: transcript,
                streaming: streamingText,
                isThinking: isThinking,
                activeTool: activeTool,
                hasPendingCard: pendingInput != nil || pendingApproval != nil,
                fontScale: fontScale,
                emptyStateText: "Codex session is ready. Send a message to start.",
                groupsToolActivity: false
            ) {
                AnyView(Group {
                    if let debugMessage, pendingInput == nil {
                        Text(debugMessage)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.yellow)
                            .textSelection(.enabled)
                            .padding(Spacing.xxl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.yellow.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if let pendingInput {
                        inputCard(pendingInput)
                    }

                    if let pendingApproval {
                        approvalCard(pendingApproval)
                    }
                })
            }
        } composer: {
            CodexComposerView(
                agent: agent,
                skills: MCPConfigLoader.loadSkills(in: agent.folder, provider: .codex),
                currentModelName: currentModelName,
                currentCollaborationMode: currentCollaborationMode,
                composerFocused: $composerFocused
            )
        }
    }

    private func approvalCard(_ prompt: ApprovalPrompt) -> some View {
        SessionApprovalCard(
            title: prompt.title,
            detail: prompt.message,
            approveTitle: "Approve",
            declineTitle: "Decline",
            supportsDecisions: prompt.supportsDecisions,
            unsupportedText: "This permission request is not supported by the current UI yet.",
            onApprove: {
                coordinator.answerCodexApproval(for: agent.id, accept: true)
            },
            onDecline: {
                coordinator.answerCodexApproval(for: agent.id, accept: false)
            },
            modeButtons: CodexApprovalPolicy.allCases
                .filter { $0 != .untrusted }
                .map { ApprovalModeButton(id: $0.rawValue, label: $0.label) },
            onApproveAndSwitchMode: { mode in
                guard let policy = CodexApprovalPolicy(rawValue: mode) else { return }
                coordinator.setCodexApprovalPolicy(for: agent.id, policy: policy)
                coordinator.answerCodexApproval(for: agent.id, accept: true)
            }
        )
    }

    private func inputCard(_ prompt: UserInputPrompt) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            ForEach(prompt.questions) { question in
                SessionQuestionCard(
                    title: question.header,
                    detail: question.question,
                    options: question.options
                ) { option in
                    coordinator.answerCodexUserInput(
                        for: agent.id,
                        answers: [question.id: [option.label]]
                    )
                }
            }
        }
    }
}

/// Owns the per-keystroke draft state so typing only invalidates the composer
/// subtree — the panel body (which renders the full transcript via MarkdownUI)
/// stays put.
private struct CodexComposerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme

    let agent: Agent
    let skills: [SkillInfo]
    let currentModelName: String
    let currentCollaborationMode: CodexCollaborationMode
    var composerFocused: FocusState<Bool>.Binding

    @State private var draft = ""
    @State private var pendingImages: [PendingImage] = []
    @State private var showingUsagePopover = false
    @State private var skillSelectionIndex = 0
    @AppStorage(UserDefaultsKeys.codexApprovalPolicy) private var rawApprovalPolicy: String?
    @AppStorage(UserDefaultsKeys.codexSandboxMode) private var rawSandboxMode: String?
    @State private var configDefaults = CodexConfigLoader.loadDefaults()

    private var currentApprovalPolicy: CodexApprovalPolicy {
        if let rawApprovalPolicy,
           let policy = CodexApprovalPolicy(rawValue: rawApprovalPolicy) {
            return policy
        }
        return configDefaults.approvalPolicy ?? .onRequest
    }

    private var currentSandboxMode: CodexSandboxMode {
        if let rawSandboxMode,
           let mode = CodexSandboxMode(rawValue: rawSandboxMode) {
            return mode
        }
        return configDefaults.sandboxMode ?? .workspaceWrite
    }

    private var skillSuggestions: [SkillInfo] {
        let stripped = draft.replacingOccurrences(of: "\n", with: "")
        guard stripped.hasPrefix("$"), !stripped.contains(" ") else { return [] }
        let query = String(stripped.dropFirst()).lowercased()
        if query.isEmpty { return skills }
        return skills.filter { $0.name.lowercased().hasPrefix(query) }
    }

    var body: some View {
        SessionComposer(
            draft: $draft,
            pendingImages: $pendingImages,
            composerFocused: composerFocused,
            fontScale: fontScale,
            statusText: "",
            statusColor: .secondary,
            onKeyPress: handleComposerKeyPress,
            onDraftChange: { skillSelectionIndex = 0 }
        ) {
            if !skillSuggestions.isEmpty {
                skillCommandList
            }
        } trailingControls: {
            HStack(spacing: 6) {
                ComposerPill(text: currentModelName)
                ComposerModePickerButton(
                    title: "Mode",
                    modes: CodexCollaborationMode.allCases,
                    currentMode: currentCollaborationMode,
                    label: { $0.label },
                    shortcutKey: "m",
                    shortcutModifiers: [.command, .shift],
                    shortcutLabel: "⌘⇧M"
                ) { mode in
                    coordinator.setCodexCollaborationMode(for: agent.id, mode: mode)
                }
                ComposerModePickerButton(
                    title: "Approval",
                    modes: CodexApprovalPolicy.allCases,
                    currentMode: currentApprovalPolicy,
                    label: { $0.label },
                    shortcutKey: "a",
                    shortcutModifiers: [.command, .shift],
                    shortcutLabel: "⌘⇧A"
                ) { policy in
                    coordinator.setCodexApprovalPolicy(for: agent.id, policy: policy)
                }
                ComposerModePickerButton(
                    title: "Sandbox",
                    modes: CodexSandboxMode.allCases,
                    currentMode: currentSandboxMode,
                    label: { $0.label },
                    shortcutKey: "b",
                    shortcutModifiers: [.command, .shift],
                    shortcutLabel: "⌘⇧B"
                ) { mode in
                    coordinator.setCodexSandboxMode(for: agent.id, mode: mode)
                }
                if let limits = coordinator.usageMonitor.rateLimits[.codex] {
                    usageRingButton(limits: limits)
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

    private var skillCommandList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(skillSuggestions.enumerated()), id: \.element.id) { index, skill in
                        Button {
                            draft = "$\(skill.name) "
                            skillSelectionIndex = 0
                        } label: {
                            HStack(alignment: .top, spacing: Spacing.lg) {
                                Text("$\(skill.name)")
                                    .scaledFont(size: 13, weight: .medium, design: .monospaced)
                                    .frame(width: 140, alignment: .leading)

                                if !skill.description.isEmpty {
                                    Text(skill.description)
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
                        .background(index == skillSelectionIndex ? theme.accent.opacity(0.2) : .clear)
                        .id(skill.id)
                    }
                }
            }
            .onChange(of: skillSelectionIndex) { _, idx in
                if idx < skillSuggestions.count {
                    proxy.scrollTo(skillSuggestions[idx].id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: 200)
        .background(theme.surface)
    }

    private func handleComposerKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let suggestions = skillSuggestions
        if !suggestions.isEmpty {
            if keyPress.key == .downArrow {
                skillSelectionIndex = min(skillSelectionIndex + 1, suggestions.count - 1)
                return .handled
            }
            if keyPress.key == .upArrow {
                skillSelectionIndex = max(skillSelectionIndex - 1, 0)
                return .handled
            }
            if keyPress.key == .return, !keyPress.modifiers.contains(.shift) {
                let selected = suggestions[skillSelectionIndex]
                draft = "$\(selected.name) "
                skillSelectionIndex = 0
                return .handled
            }
            if keyPress.key == .escape {
                draft = ""
                return .handled
            }
        }
        return handleComposerSubmitKeyPress(keyPress, send: sendDraft)
    }

    private func usageRingButton(limits: AgentRateLimits) -> some View {
        Button {
            showingUsagePopover.toggle()
        } label: {
            UsageRing(percent: limits.shortWindow.usedPercent)
        }
        .buttonStyle(.plain)
        .help("API Usage")
        .popover(isPresented: $showingUsagePopover) {
            UsagePopover(limits: limits, provider: .codex)
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        let imageData = pendingImages.map(\.data)
        let imagePaths = pendingImages.compactMap { img -> String? in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-image-\(UUID().uuidString).png")
            return (try? img.data.write(to: url)) != nil ? url.path : nil
        }
        let sendText = text.isEmpty ? "[Image]" : text
        coordinator.codexMonitor.recordSentUserMessage(
            for: agent.id,
            text: sendText,
            imageData: imageData
        )
        coordinator.sendCodexMessage(for: agent.id, text: sendText, imagePaths: imagePaths)
        draft = ""
        pendingImages.removeAll()
    }
}
