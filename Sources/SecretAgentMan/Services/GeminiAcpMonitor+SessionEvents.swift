import Foundation

/// Maps incoming Gemini ACP protocol payloads to normalized `SessionEvent`s.
/// Tests drive these `apply*` entry points directly without spawning a
/// process; the production Observer (in `GeminiAcpMonitor.swift`) calls them
/// after decoding incoming JSON-RPC frames.
extension GeminiAcpMonitor {
    // MARK: - session/new + session/load responses

    /// Emit `sessionReady` and any initial mode/model state from a `session/new`
    /// response.
    func applyNewSessionResponse(
        _ response: GeminiAcpProtocol.NewSessionResponse,
        for agentId: UUID
    ) {
        onSessionReady?(agentId, response.sessionId)
        emit(.sessionReady(sessionId: response.sessionId), for: agentId)
        emitInitialModeModelMetadata(
            modes: response.modes,
            models: response.models,
            for: agentId
        )
    }

    /// `session/load` does not return the session id (the client provided it).
    /// Caller passes the stored id explicitly so `sessionReady` is consistent.
    func applyLoadSessionResponse(
        _ response: GeminiAcpProtocol.LoadSessionResponse,
        sessionId: String,
        for agentId: UUID
    ) {
        onSessionReady?(agentId, sessionId)
        emit(.sessionReady(sessionId: sessionId), for: agentId)
        emitInitialModeModelMetadata(
            modes: response.modes,
            models: response.models,
            for: agentId
        )
    }

    private func emitInitialModeModelMetadata(
        modes: GeminiAcpProtocol.SessionModeState?,
        models: GeminiAcpProtocol.SessionModelState?,
        for agentId: UUID
    ) {
        var update = SessionMetadataUpdate()
        if let modes {
            update.availableModes = .set(modes.availableModes.map(Self.mapMode))
            update.currentModeId = .set(modes.currentModeId)
        }
        if let models {
            update.availableModels = .set(models.availableModels.map(Self.mapModel))
            update.currentModelId = .set(models.currentModelId)
            if let current = models.availableModels.first(where: { $0.modelId == models.currentModelId }) {
                update.displayModelName = .set(current.name)
                update.rawModelName = .set(current.modelId)
            }
        }
        emit(.metadataUpdated(update), for: agentId)
    }

    // MARK: - session/update notifications

    /// Top-level dispatch for incoming `session/update` notifications. Each
    /// sub-handler emits the normalized events for that variant.
    func applySessionUpdate(
        _ update: GeminiAcpProtocol.SessionUpdate,
        sessionId _: String,
        for agentId: UUID
    ) {
        switch update {
        case let .userMessageChunk(chunk):
            handleUserMessageChunk(chunk, for: agentId)
        case let .agentMessageChunk(chunk):
            handleAgentMessageChunk(chunk, for: agentId)
        case let .agentThoughtChunk(chunk):
            handleAgentThoughtChunk(chunk, for: agentId)
        case let .toolCall(call):
            handleToolCall(call, for: agentId)
        case let .toolCallUpdate(update):
            handleToolCallUpdate(update, for: agentId)
        case let .plan(plan):
            handlePlan(plan, for: agentId)
        case let .availableCommandsUpdate(payload):
            handleAvailableCommandsUpdate(payload, for: agentId)
        case let .currentModeUpdate(payload):
            handleCurrentModeUpdate(payload, for: agentId)
        case .sessionInfoUpdate, .usageUpdate, .unknown:
            // Not surfaced in V1: session_info_update (title only),
            // usage_update (consumed by UsageMonitor separately), and unknown
            // forward-compat variants.
            break
        }
    }

    // MARK: - User / agent / thought chunks

    private func handleUserMessageChunk(
        _ chunk: GeminiAcpProtocol.ContentChunk,
        for agentId: UUID
    ) {
        // Loaded-history user messages. Reconcile against a local-user-* id
        // when the text matches a pending local prompt; otherwise treat as
        // historical and emit a fresh transcript item.
        let text = Self.extractText(chunk.content)
        if let pending = popPendingLocalUserMessage(for: agentId, matching: text) {
            emit(
                .transcriptUpsert(SessionTranscriptItem(
                    id: pending.id,
                    kind: .userMessage,
                    text: text,
                    createdAt: Date(),
                    imageData: pending.imageData
                )),
                for: agentId
            )
            return
        }
        let id = "gemini-user-\(chunk.messageId ?? UUID().uuidString)"
        emit(
            .transcriptUpsert(SessionTranscriptItem(
                id: id,
                kind: .userMessage,
                text: text,
                createdAt: Date()
            )),
            for: agentId
        )
    }

    private func handleAgentMessageChunk(
        _ chunk: GeminiAcpProtocol.ContentChunk,
        for agentId: UUID
    ) {
        let text = Self.extractText(chunk.content)
        let stream = ensureAssistantStreamId(for: agentId)
        if stream.isNew {
            emit(
                .transcriptUpsert(SessionTranscriptItem(
                    id: stream.id,
                    kind: .assistantMessage,
                    text: text,
                    isStreaming: true,
                    createdAt: Date()
                )),
                for: agentId
            )
        } else {
            emit(.transcriptDelta(id: stream.id, appendedText: text), for: agentId)
        }
    }

    private func handleAgentThoughtChunk(
        _ chunk: GeminiAcpProtocol.ContentChunk,
        for agentId: UUID
    ) {
        let text = Self.extractText(chunk.content)
        let stream = ensureThoughtStreamId(for: agentId)
        if stream.isNew {
            emit(
                .transcriptUpsert(SessionTranscriptItem(
                    id: stream.id,
                    kind: .thought,
                    text: text,
                    isStreaming: true,
                    createdAt: Date()
                )),
                for: agentId
            )
        } else {
            emit(.transcriptDelta(id: stream.id, appendedText: text), for: agentId)
        }
    }

    // MARK: - Tool calls

    private func handleToolCall(
        _ call: GeminiAcpProtocol.ToolCall,
        for agentId: UUID
    ) {
        let snapshot = ToolCallSnapshot(
            toolCallId: call.toolCallId,
            title: call.title,
            kind: call.kind,
            status: call.status,
            locations: call.locations ?? [],
            contentSummary: Self.summarizeToolContent(call.content)
        )
        mergeToolCall(snapshot, for: agentId)
        emit(.transcriptUpsert(Self.mapToolItem(snapshot, agentId: agentId)), for: agentId)
        var meta = SessionMetadataUpdate()
        meta.activeToolName = .set(snapshot.title)
        emit(.metadataUpdated(meta), for: agentId)
    }

    private func handleToolCallUpdate(
        _ update: GeminiAcpProtocol.ToolCallUpdate,
        for agentId: UUID
    ) {
        // Out-of-order update for a tool call we never saw: synthesize a
        // minimal snapshot so the user still sees something rather than
        // silently dropping the event.
        var snapshot = currentToolCall(update.toolCallId, for: agentId) ?? ToolCallSnapshot(
            toolCallId: update.toolCallId,
            title: update.title ?? "Tool call",
            kind: update.kind,
            status: update.status,
            locations: update.locations ?? [],
            contentSummary: Self.summarizeToolContent(update.content)
        )

        if let title = update.title, !title.isEmpty { snapshot.title = title }
        if let kind = update.kind { snapshot.kind = kind }
        if let status = update.status { snapshot.status = status }
        if let locations = update.locations { snapshot.locations = locations }
        if let content = update.content {
            let summary = Self.summarizeToolContent(content)
            if !summary.isEmpty {
                snapshot.contentSummary = summary
            }
        }

        mergeToolCall(snapshot, for: agentId)
        emit(.transcriptUpsert(Self.mapToolItem(snapshot, agentId: agentId)), for: agentId)

        if snapshot.isTerminal {
            dropToolCall(snapshot.toolCallId, for: agentId)
            var meta = SessionMetadataUpdate()
            meta.activeToolName = .clear
            emit(.metadataUpdated(meta), for: agentId)
        }
    }

    // MARK: - Plan / commands / mode

    private func handlePlan(_ plan: GeminiAcpProtocol.Plan, for agentId: UUID) {
        let id = "gemini-plan-\(agentId.uuidString)"
        emit(
            .transcriptUpsert(SessionTranscriptItem(
                id: id,
                kind: .plan,
                text: Self.formatPlan(plan),
                createdAt: Date()
            )),
            for: agentId
        )
    }

    private func handleAvailableCommandsUpdate(
        _ payload: GeminiAcpProtocol.AvailableCommandsUpdate,
        for agentId: UUID
    ) {
        let commands = payload.availableCommands.map { command in
            SessionSlashCommand(name: command.name, description: command.description)
        }
        var update = SessionMetadataUpdate()
        update.slashCommands = .set(commands)
        emit(.metadataUpdated(update), for: agentId)
    }

    private func handleCurrentModeUpdate(
        _ payload: GeminiAcpProtocol.CurrentModeUpdate,
        for agentId: UUID
    ) {
        var update = SessionMetadataUpdate()
        update.currentModeId = .set(payload.currentModeId)
        emit(.metadataUpdated(update), for: agentId)
    }

    // MARK: - Prompt response (turn completion)

    /// Apply a `session/prompt` JSON-RPC response. Finalizes any active
    /// assistant/thought streams, then emits `turnCompleted` last per the
    /// shared contract's ordering rule. Also bumps `agent.state` back to
    /// `.idle` so the panel's thinking UI clears.
    func applyPromptResponse(
        _ response: GeminiAcpProtocol.PromptResponse,
        for agentId: UUID
    ) {
        if let assistantId = consumeAssistantStreamId(for: agentId) {
            emit(.transcriptFinished(id: assistantId), for: agentId)
        }
        if let thoughtId = consumeThoughtStreamId(for: agentId) {
            emit(.transcriptFinished(id: thoughtId), for: agentId)
        }

        let stopReason = Self.mapStopReason(
            response.stopReason,
            unknown: response.unknownStopReason
        )
        emit(.turnCompleted(SessionTurnCompletion(stopReason: stopReason)), for: agentId)
        onStateChange?(agentId, stopReason == .refusal ? .error : .idle)
    }

    // MARK: - Permission request

    /// Apply an incoming `session/request_permission` JSON-RPC request.
    /// The caller passes the JSON-RPC id so the monitor can answer with
    /// `respondToApproval` later.
    func applyPermissionRequest(
        _ request: GeminiAcpProtocol.RequestPermissionRequest,
        acpRequestId: GeminiAcpRpc.Id,
        for agentId: UUID
    ) {
        let promptId = "gemini-perm-\(request.toolCall.toolCallId)"
        let prompt = ApprovalPrompt(
            id: promptId,
            title: request.toolCall.title ?? "Tool permission",
            message: Self.summarizeToolContent(request.toolCall.content),
            actions: request.options.map(Self.mapApprovalAction)
        )
        setPendingApproval(
            PendingApproval(
                promptId: promptId,
                acpRequestId: acpRequestId,
                sessionId: request.sessionId
            ),
            for: agentId
        )
        emit(.promptPresented(.approval(prompt)), for: agentId)
    }

    // MARK: - Static mappers (pure functions)

    static func mapStopReason(
        _ reason: GeminiAcpProtocol.StopReason?,
        unknown: String?
    ) -> SessionStopReason {
        if let reason {
            switch reason {
            case .endTurn: return .endTurn
            case .maxTokens: return .maxTokens
            case .maxTurnRequests: return .maxTurnRequests
            case .refusal: return .refusal
            case .cancelled: return .cancelled
            }
        }
        return .unknown(unknown ?? "")
    }

    static func mapMode(_ mode: GeminiAcpProtocol.SessionMode) -> SessionModeInfo {
        SessionModeInfo(id: mode.id, name: mode.name, description: mode.description)
    }

    static func mapModel(_ model: GeminiAcpProtocol.ModelInfo) -> SessionModelInfo {
        SessionModelInfo(id: model.modelId, name: model.name, description: model.description)
    }

    static func mapApprovalAction(_ option: GeminiAcpProtocol.PermissionOption) -> ApprovalAction {
        ApprovalAction(
            id: option.optionId,
            label: option.name,
            kind: mapApprovalKind(option.kind),
            isDestructive: option.kind == .rejectOnce || option.kind == .rejectAlways
        )
    }

    static func mapApprovalKind(_ kind: GeminiAcpProtocol.PermissionOptionKind) -> ApprovalActionKind {
        switch kind {
        case .allowOnce: .allowOnce
        case .allowAlways: .allowAlways
        case .rejectOnce: .rejectOnce
        case .rejectAlways: .rejectAlways
        }
    }

    /// Pulls visible text out of a `ContentBlock`. Image and resource_link
    /// blocks fall back to a placeholder description; unknown variants are
    /// surfaced as their type tag so the user sees something rather than
    /// silently empty bubbles.
    static func extractText(_ block: GeminiAcpProtocol.ContentBlock) -> String {
        switch block {
        case let .text(text): text.text
        case .image: "[image]"
        case .audio: "[audio]"
        case let .resourceLink(link): "[\(link.title ?? link.name)](\(link.uri))"
        case .resource: "[embedded resource]"
        case let .unknown(type, _): "[\(type) content]"
        }
    }

    /// Build a one-line summary of a tool call's content array. Keeps text
    /// (truncated), labels diffs by file path, mentions terminals by id.
    static func summarizeToolContent(_ content: [GeminiAcpProtocol.ToolCallContent]?) -> String {
        guard let content, !content.isEmpty else { return "" }
        return content.compactMap { item -> String? in
            switch item {
            case let .content(block):
                let text = extractText(block)
                return text.isEmpty ? nil : text
            case let .diff(diff):
                return "Edit: \(diff.path)"
            case let .terminal(term):
                return "Terminal \(term.terminalId)"
            case let .unknown(type, _):
                return "[\(type) content]"
            }
        }.joined(separator: "\n")
    }

    static func formatPlan(_ plan: GeminiAcpProtocol.Plan) -> String {
        plan.entries.map { entry in
            let marker = switch entry.status {
            case .completed: "[x]"
            case .inProgress: "[~]"
            case .pending: "[ ]"
            }
            return "\(marker) \(entry.content) — \(entry.priority.rawValue)"
        }.joined(separator: "\n")
    }

    static func mapToolItem(_ snapshot: ToolCallSnapshot, agentId _: UUID) -> SessionTranscriptItem {
        let statusSuffix = switch snapshot.status {
        case .pending?: " (pending)"
        case .inProgress?: " (running)"
        case .completed?: ""
        case .failed?: " (failed)"
        case .none: ""
        }
        let titleLine = snapshot.title + statusSuffix
        let body = if snapshot.contentSummary.isEmpty {
            titleLine
        } else {
            titleLine + "\n" + snapshot.contentSummary
        }
        return SessionTranscriptItem(
            id: "gemini-tool-\(snapshot.toolCallId)",
            kind: .toolActivity,
            text: body,
            createdAt: Date(),
            metadata: TranscriptItemMetadata(
                toolName: snapshot.kind?.rawValue,
                displayTitle: snapshot.title,
                providerItemType: "gemini.tool_call"
            )
        )
    }
}
