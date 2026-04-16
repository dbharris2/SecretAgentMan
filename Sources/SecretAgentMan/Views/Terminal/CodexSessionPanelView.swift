import SwiftUI

struct CodexSessionPanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme

    let agent: Agent

    @State private var draft = ""
    @State private var pendingImages: [PendingImage] = []
    @FocusState private var composerFocused: Bool

    private var transcript: [CodexTranscriptItem] {
        coordinator.codexMonitor.transcriptItems[agent.id] ?? []
    }

    private var pendingInput: CodexUserInputRequest? {
        coordinator.codexMonitor.pendingUserInputRequests[agent.id]
    }

    private var pendingApproval: CodexApprovalRequest? {
        coordinator.codexMonitor.pendingApprovalRequests[agent.id]
    }

    private var debugMessage: String? {
        coordinator.codexMonitor.debugMessages[agent.id]
    }

    private var streamingText: String? {
        coordinator.codexMonitor.streamingText[agent.id]
    }

    private var isThinking: Bool {
        agent.state == .active && streamingText == nil
    }

    private var composerStatusText: String {
        let monitor = coordinator.codexMonitor
        let model = monitor.modelNames[agent.id].flatMap { $0.isEmpty ? nil : $0 } ?? "Codex"
        let pct = monitor.contextPercentUsedByAgent[agent.id] ?? 0
        let mode = monitor.collaborationModes[agent.id]?.label ?? CodexCollaborationMode.default.label
        var parts = [model]
        if pct > 0 {
            parts.append("\(Int(pct))% ctx")
        }
        parts.append("\(mode) (ctrl+m)")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionChatView(
                providerName: "Codex",
                transcript: transcript,
                streaming: streamingText,
                isThinking: isThinking,
                activeTool: nil,
                hasPendingCard: pendingInput != nil || pendingApproval != nil,
                fontScale: fontScale,
                emptyStateText: "Codex session is ready. Send a message to start."
            ) {
                AnyView(Group {
                    if let debugMessage, pendingInput == nil {
                        Text(debugMessage)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.yellow)
                            .textSelection(.enabled)
                            .padding(12)
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

            Divider()

            composer
        }
        .background(theme.background)
        .id(agent.id)
        .onKeyPress(phases: .down) { keyPress in
            if keyPress.key == .init("c"), keyPress.modifiers.contains(.control) {
                coordinator.interruptAgent(for: agent.id)
                return .handled
            }
            return .ignored
        }
        .onAppear {
            coordinator.ensureCodexSession(for: agent.id)
        }
        .onChange(of: agent.id) { _, newId in
            coordinator.ensureCodexSession(for: newId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { _ in
            composerFocused = true
        }
    }

    private var composer: some View {
        SessionComposer(
            draft: $draft,
            pendingImages: $pendingImages,
            composerFocused: $composerFocused,
            fontScale: fontScale,
            statusText: composerStatusText,
            statusColor: .secondary,
            sendDisabled: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty,
            onSend: sendDraft,
            onKeyPress: handleComposerKeyPress,
            onDraftChange: {}
        ) {
            EmptyView()
        } trailingControls: {
            EmptyView()
        }
    }

    private func handleComposerKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == .init("m"), keyPress.modifiers.contains(.control) {
            cycleCollaborationMode()
            return .handled
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

    private func cycleCollaborationMode() {
        let modes = CodexCollaborationMode.allCases
        let current = coordinator.codexMonitor.collaborationModes[agent.id] ?? .default
        let idx = modes.firstIndex(of: current) ?? 0
        let next = modes[(idx + 1) % modes.count]
        coordinator.setCodexCollaborationMode(for: agent.id, mode: next)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        let imagePaths = pendingImages.compactMap { img -> String? in
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-image-\(UUID().uuidString).png").path
            return FileManager.default.createFile(atPath: path, contents: img.data) ? path : nil
        }
        coordinator.sendCodexMessage(for: agent.id, text: text.isEmpty ? "[Image]" : text, imagePaths: imagePaths)
        draft = ""
        pendingImages.removeAll()
    }

    private func approvalCard(_ request: CodexApprovalRequest) -> some View {
        SessionApprovalCard(
            title: request.kind.title,
            detail: request.kind.detail,
            approveTitle: "Approve",
            declineTitle: "Decline",
            supportsDecisions: request.kind.supportsDecisions,
            unsupportedText: "This permission request is not supported by the current UI yet."
        ) {
            coordinator.answerCodexApproval(for: agent.id, accept: true)
        } onDecline: {
            coordinator.answerCodexApproval(for: agent.id, accept: false)
        } onApproveAndSwitchMode: { mode in
            let policy: CodexApprovalPolicy = switch mode {
            case "acceptEdits":
                .onRequest
            case "auto":
                .never
            default:
                .untrusted
            }
            coordinator.setCodexApprovalPolicy(for: agent.id, policy: policy)
            coordinator.answerCodexApproval(for: agent.id, accept: true)
        }
    }

    private func inputCard(_ request: CodexUserInputRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(request.questions) { question in
                SessionQuestionCard(
                    title: question.header,
                    detail: question.prompt,
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
