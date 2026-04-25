import Foundation

/// Pure, deterministic reducer for normalized session events.
///
/// Keep this type free of provider-specific logic: it must not branch on
/// `TranscriptItemMetadata.providerItemType` or otherwise switch on provider.
/// Any provider quirks belong inside the monitors' normalization step.
enum AgentSessionReducer {
    static func reduce(
        _ snapshot: AgentSessionSnapshot,
        event: SessionEvent
    ) -> AgentSessionSnapshot {
        var next = snapshot
        apply(event, to: &next)
        return next
    }

    private static func apply(_ event: SessionEvent, to snapshot: inout AgentSessionSnapshot) {
        switch event {
        case let .sessionReady(sessionId):
            applySessionReady(sessionId: sessionId, to: &snapshot)
        case let .runStateChanged(state):
            snapshot.runState = state
        case let .transcriptUpsert(item):
            applyTranscriptUpsert(item, to: &snapshot)
        case let .transcriptDelta(id, appended):
            applyTranscriptDelta(id: id, appended: appended, to: &snapshot)
        case let .transcriptFinished(id):
            applyTranscriptFinished(id: id, to: &snapshot)
        case let .promptPresented(prompt):
            applyPromptPresented(prompt, to: &snapshot)
        case let .promptResolved(id):
            applyPromptResolved(id: id, to: &snapshot)
        case let .metadataUpdated(update):
            applyMetadataUpdate(update, to: &snapshot.metadata)
        case let .turnCompleted(completion):
            applyTurnCompleted(completion, to: &snapshot)
        }
    }

    private static func applySessionReady(
        sessionId: String,
        to snapshot: inout AgentSessionSnapshot
    ) {
        if snapshot.metadata.sessionId == sessionId {
            return
        }
        // Only clear session-scoped state when transitioning between two
        // distinct known sessions. A first `sessionReady` (metadata.sessionId
        // was nil) is initial session bootstrap and may arrive *after* the
        // user has already sent a message — clearing in that case wipes
        // legitimate transcript items.
        let isReplacement = snapshot.metadata.sessionId != nil
        if isReplacement {
            snapshot.runState = .idle
            snapshot.transcript = []
            snapshot.activePrompt = nil
            snapshot.queuedPrompts = []
            snapshot.hasUnread = false
            snapshot.metadata.activeToolName = nil
        }
        snapshot.metadata.sessionId = sessionId
    }

    private static func applyTranscriptUpsert(
        _ item: SessionTranscriptItem,
        to snapshot: inout AgentSessionSnapshot
    ) {
        if let index = snapshot.transcript.firstIndex(where: { $0.id == item.id }) {
            let existing = snapshot.transcript[index]
            // Preserve earliest non-nil createdAt so a later upsert without a timestamp
            // doesn't erase hydration data.
            let preservedCreatedAt = earliestCreatedAt(existing.createdAt, item.createdAt)
            // transcriptFinished is the authoritative way to end streaming. An upsert
            // on an already-streaming item keeps it streaming even if the incoming flag
            // is false.
            let mergedIsStreaming = existing.isStreaming || item.isStreaming
            snapshot.transcript[index] = SessionTranscriptItem(
                id: item.id,
                kind: item.kind,
                text: item.text,
                isStreaming: mergedIsStreaming,
                createdAt: preservedCreatedAt,
                imageData: item.imageData,
                metadata: item.metadata
            )
        } else {
            snapshot.transcript.append(item)
        }
    }

    private static func applyTranscriptDelta(
        id: String,
        appended: String,
        to snapshot: inout AgentSessionSnapshot
    ) {
        guard let index = snapshot.transcript.firstIndex(where: { $0.id == id }) else {
            assertionFailure("transcriptDelta for unknown id \(id) — monitor must emit transcriptUpsert first")
            return
        }
        let existing = snapshot.transcript[index]
        guard existing.isStreaming else {
            assertionFailure("transcriptDelta for non-streaming id \(id) — use transcriptUpsert instead")
            return
        }
        snapshot.transcript[index] = SessionTranscriptItem(
            id: existing.id,
            kind: existing.kind,
            text: existing.text + appended,
            isStreaming: true,
            createdAt: existing.createdAt,
            imageData: existing.imageData,
            metadata: existing.metadata
        )
    }

    private static func applyTranscriptFinished(
        id: String,
        to snapshot: inout AgentSessionSnapshot
    ) {
        guard let index = snapshot.transcript.firstIndex(where: { $0.id == id }) else { return }
        let existing = snapshot.transcript[index]
        guard existing.isStreaming else { return }
        snapshot.transcript[index] = SessionTranscriptItem(
            id: existing.id,
            kind: existing.kind,
            text: existing.text,
            isStreaming: false,
            createdAt: existing.createdAt,
            imageData: existing.imageData,
            metadata: existing.metadata
        )
    }

    private static func applyPromptPresented(
        _ prompt: SessionPromptRequest,
        to snapshot: inout AgentSessionSnapshot
    ) {
        if snapshot.activePrompt == nil {
            snapshot.activePrompt = prompt
        } else {
            snapshot.queuedPrompts.append(prompt)
        }
    }

    private static func applyPromptResolved(
        id: String,
        to snapshot: inout AgentSessionSnapshot
    ) {
        if snapshot.activePrompt?.id == id {
            if snapshot.queuedPrompts.isEmpty {
                snapshot.activePrompt = nil
            } else {
                snapshot.activePrompt = snapshot.queuedPrompts.removeFirst()
            }
            return
        }
        if let index = snapshot.queuedPrompts.firstIndex(where: { $0.id == id }) {
            snapshot.queuedPrompts.remove(at: index)
        }
    }

    private static func applyMetadataUpdate(
        _ update: SessionMetadataUpdate,
        to metadata: inout SessionMetadataSnapshot
    ) {
        apply(update.displayModelName, to: &metadata.displayModelName)
        apply(update.rawModelName, to: &metadata.rawModelName)
        apply(update.contextPercentUsed, to: &metadata.contextPercentUsed)
        apply(update.permissionMode, to: &metadata.permissionMode)
        apply(update.collaborationMode, to: &metadata.collaborationMode)
        apply(update.activeToolName, to: &metadata.activeToolName)
        apply(update.slashCommands, to: &metadata.slashCommands)
        apply(update.availableModes, to: &metadata.availableModes)
        apply(update.currentModeId, to: &metadata.currentModeId)
        apply(update.availableModels, to: &metadata.availableModels)
        apply(update.currentModelId, to: &metadata.currentModelId)
    }

    private static func applyTurnCompleted(
        _ completion: SessionTurnCompletion,
        to snapshot: inout AgentSessionSnapshot
    ) {
        switch completion.stopReason {
        case .endTurn, .maxTokens, .maxTurnRequests, .cancelled:
            snapshot.runState = .idle
        case .refusal:
            snapshot.runState = .error(message: "Model declined to respond.")
        case .unknown:
            // Conservative default: treat a future unrecognized stopReason as
            // end-of-turn idle rather than wedging the session.
            snapshot.runState = .idle
        }
    }

    private static func apply<Value: Equatable>(
        _ update: MetadataFieldUpdate<Value>,
        to field: inout Value?
    ) {
        switch update {
        case .unchanged:
            break
        case let .set(value):
            field = value
        case .clear:
            field = nil
        }
    }

    private static func earliestCreatedAt(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?): min(l, r)
        case let (l?, nil): l
        case let (nil, r?): r
        case (nil, nil): nil
        }
    }
}
