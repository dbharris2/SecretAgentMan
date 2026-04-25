import Foundation

/// Normalized `SessionEvent` emission for Phase 1 dual-emit migration.
/// Kept in a separate file so these additions don't push the main monitor
/// type over SwiftLint's type_body_length threshold.
extension CodexAppServerMonitor {
    func emit(_ event: SessionEvent, for agentId: UUID) {
        onSessionEvent?(agentId, event)
    }

    func emitTranscriptUpsert(_ agentId: UUID, item: CodexTranscriptItem, canonicalId: String) {
        let normalized = Self.mapTranscriptItem(item, overrideId: canonicalId)
        emit(.transcriptUpsert(normalized), for: agentId)
    }

    func emitStreamDelta(id: UUID, itemId: String, delta: String) {
        var tracked = streamingItemIds[id, default: []]
        if tracked.contains(itemId) {
            emit(.transcriptDelta(id: itemId, appendedText: delta), for: id)
        } else {
            tracked.insert(itemId)
            streamingItemIds[id] = tracked
            emit(.transcriptUpsert(SessionTranscriptItem(
                id: itemId,
                kind: .assistantMessage,
                text: delta,
                isStreaming: true
            )), for: id)
        }
    }

    func emitStreamFinalize(id: UUID, itemId: String) {
        guard var tracked = streamingItemIds[id], tracked.contains(itemId) else { return }
        emit(.transcriptFinished(id: itemId), for: id)
        tracked.remove(itemId)
        streamingItemIds[id] = tracked.isEmpty ? nil : tracked
    }

    static func mapRunState(_ state: AgentState) -> SessionRunState {
        switch state {
        case .idle: .idle
        case .active: .running
        case .needsPermission: .needsPermission
        // Codex `.awaitingInput` = "turn complete" → normalized `.idle`.
        case .awaitingInput: .idle
        // Codex `.awaitingResponse` = waiting on user input → `.needsInput`.
        case .awaitingResponse: .needsInput
        case .finished: .finished
        case .error: .error(message: nil)
        }
    }

    static func mapTranscriptItem(_ item: CodexTranscriptItem, overrideId: String? = nil) -> SessionTranscriptItem {
        let id = overrideId ?? item.id
        let kind = Self.transcriptItemKind(for: item)
        let toolName = item.toolName ?? Self.inferToolName(item.tool)
        let metadata = (toolName != nil) ? TranscriptItemMetadata(toolName: toolName) : nil
        return SessionTranscriptItem(
            id: id,
            kind: kind,
            text: item.displayText,
            imageData: item.images,
            metadata: metadata
        )
    }

    private static func transcriptItemKind(for item: CodexTranscriptItem) -> TranscriptItemKind {
        if item.tool != nil {
            return .toolActivity
        }
        if item.toolName != nil, item.role == .system {
            return .toolActivity
        }
        switch item.role {
        case .user: return .userMessage
        case .assistant: return .assistantMessage
        case .system: return .systemMessage
        }
    }

    private static func inferToolName(_ tool: CodexToolDetail?) -> String? {
        switch tool {
        case .command: "command"
        case .fileChange: "fileChange"
        case .none: nil
        }
    }

    static func mapApprovalPrompt(_ request: CodexApprovalRequest) -> ApprovalPrompt {
        let actions: [ApprovalAction] = request.kind.supportsDecisions
            ? [
                ApprovalAction(id: "allow", label: "Allow"),
                ApprovalAction(id: "deny", label: "Deny", isDestructive: true),
            ]
            : [ApprovalAction(id: "dismiss", label: "Dismiss")]
        return ApprovalPrompt(
            id: request.itemId,
            title: request.kind.title,
            message: request.kind.detail,
            actions: actions
        )
    }

    static func mapUserInputPrompt(_ request: CodexUserInputRequest) -> UserInputPrompt {
        let questions = request.questions.map { question in
            PromptQuestion(
                id: question.id,
                header: question.header,
                question: question.prompt,
                allowsOther: question.allowsOther,
                options: question.options.map {
                    PromptOption(
                        label: $0.label,
                        description: $0.description.isEmpty ? nil : $0.description
                    )
                }
            )
        }
        return UserInputPrompt(
            id: request.itemId,
            title: "Input Requested",
            message: request.questions.first?.prompt ?? "",
            questions: questions
        )
    }
}
