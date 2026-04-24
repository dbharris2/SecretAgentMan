import Foundation

/// Normalized `SessionEvent` emission for Phase 1 dual-emit migration.
/// Kept in a separate file so these additions don't push the main monitor
/// type over SwiftLint's type_body_length threshold.
extension ClaudeStreamMonitor {
    func emit(_ event: SessionEvent, for agentId: UUID) {
        onSessionEvent?(agentId, event)
    }

    func emitRunStateChanged(_ agentId: UUID, state: AgentState) {
        // Claude terminal state is non-authoritative. Suppress `.finished`
        // whenever more-specific state (pending prompt or active stream) exists.
        if state == .finished {
            let hasPendingPrompt = pendingApprovalRequests[agentId] != nil
                || pendingElicitations[agentId] != nil
            let hasActiveStream = activeStreamingId[agentId] != nil
            guard !hasPendingPrompt, !hasActiveStream else { return }
        }
        emit(.runStateChanged(Self.mapRunState(state)), for: agentId)
    }

    func emitTranscriptItem(_ agentId: UUID, item: CodexTranscriptItem) {
        var normalized = Self.mapTranscriptItem(item)
        // Reconcile streaming placeholder: the first assistant text block to
        // arrive after finalizeStreaming reuses the stream id so the placeholder
        // is replaced instead of duplicated.
        if normalized.kind == .assistantMessage,
           let streamId = lastFinalizedStreamId[agentId] {
            normalized = SessionTranscriptItem(
                id: streamId,
                kind: normalized.kind,
                text: normalized.text,
                isStreaming: false,
                createdAt: normalized.createdAt,
                imageReferences: normalized.imageReferences,
                metadata: normalized.metadata
            )
            lastFinalizedStreamId.removeValue(forKey: agentId)
        }
        emit(.transcriptUpsert(normalized), for: agentId)
    }

    func emitStreamingText(_ text: String, for agentId: UUID) {
        if let streamId = activeStreamingId[agentId] {
            let previous = lastStreamingText[agentId] ?? ""
            guard text.hasPrefix(previous), text.count > previous.count else { return }
            let delta = String(text.dropFirst(previous.count))
            lastStreamingText[agentId] = text
            emit(.transcriptDelta(id: streamId, appendedText: delta), for: agentId)
        } else {
            guard !text.isEmpty else { return }
            let streamId = "claude-stream-\(UUID().uuidString)"
            activeStreamingId[agentId] = streamId
            lastStreamingText[agentId] = text
            emit(.transcriptUpsert(SessionTranscriptItem(
                id: streamId,
                kind: .assistantMessage,
                text: text,
                isStreaming: true
            )), for: agentId)
        }
    }

    func emitStreamingFinalize(for agentId: UUID) {
        guard let streamId = activeStreamingId[agentId] else { return }
        emit(.transcriptFinished(id: streamId), for: agentId)
        lastFinalizedStreamId[agentId] = streamId
        activeStreamingId.removeValue(forKey: agentId)
        lastStreamingText.removeValue(forKey: agentId)
    }

    static func mapRunState(_ state: AgentState) -> SessionRunState {
        switch state {
        case .idle: .idle
        case .active: .running
        case .needsPermission: .needsPermission
        // Claude `.awaitingInput` = "turn complete, user's turn" → normalized `.idle`.
        case .awaitingInput: .idle
        // Claude `.awaitingResponse` = elicitation / AskUserQuestion → normalized `.needsInput`.
        case .awaitingResponse: .needsInput
        case .finished: .finished
        case .error: .error(message: nil)
        }
    }

    static func mapTranscriptItem(_ item: CodexTranscriptItem) -> SessionTranscriptItem {
        let kind: TranscriptItemKind = if item.toolName != nil, item.role == .system {
            .toolActivity
        } else {
            switch item.role {
            case .user: .userMessage
            case .assistant: .assistantMessage
            case .system: .systemMessage
            }
        }
        let metadata = TranscriptItemMetadata(toolName: item.toolName)
        return SessionTranscriptItem(
            id: item.id,
            kind: kind,
            text: item.displayText,
            metadata: metadata
        )
    }

    static func mapApprovalPrompt(_ request: ClaudeApprovalRequest) -> ApprovalPrompt {
        ApprovalPrompt(
            id: request.requestId,
            title: request.displayName,
            message: request.inputDescription,
            options: ["allow", "deny"]
        )
    }

    static func mapElicitationPrompt(_ request: ClaudeElicitationRequest) -> UserInputPrompt {
        let question = PromptQuestion(
            id: request.requestId,
            header: "Claude asks",
            question: request.message,
            allowsOther: request.options.isEmpty,
            options: request.options.map {
                PromptOption(
                    label: $0.label,
                    description: $0.description.isEmpty ? nil : $0.description
                )
            }
        )
        return UserInputPrompt(
            id: request.requestId,
            title: "Input Requested",
            message: request.message,
            questions: [question]
        )
    }
}
