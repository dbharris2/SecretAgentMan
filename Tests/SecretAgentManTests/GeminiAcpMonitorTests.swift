import Foundation
@testable import SecretAgentMan
import Testing

/// Tests for `GeminiAcpMonitor`'s public `apply*` entry points and the
/// emission patterns they trigger. These don't spawn a real `gemini --acp`
/// process; they drive the monitor with synthetic ACP payloads and assert on
/// the captured `SessionEvent` stream.
@MainActor
struct GeminiAcpMonitorTests {
    // MARK: - sessionReady + initial mode/model state

    @Test func newSessionResponseEmitsSessionReadyAndInitialMetadata() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        var sessionReady: (UUID, String)?
        monitor.onSessionEvent = { _, event in events.append(event) }
        monitor.onSessionReady = { id, sid in sessionReady = (id, sid) }

        let response = GeminiAcpProtocol.NewSessionResponse(
            sessionId: "s-1",
            modes: GeminiAcpProtocol.SessionModeState(
                availableModes: [
                    GeminiAcpProtocol.SessionMode(id: "default", name: "Default", description: nil),
                    GeminiAcpProtocol.SessionMode(id: "auto", name: "Auto", description: "Auto-approve"),
                ],
                currentModeId: "auto"
            ),
            models: GeminiAcpProtocol.SessionModelState(
                availableModels: [
                    GeminiAcpProtocol.ModelInfo(
                        modelId: "gemini-2.5-pro",
                        name: "Gemini 2.5 Pro",
                        description: nil
                    ),
                ],
                currentModelId: "gemini-2.5-pro"
            )
        )
        monitor.applyNewSessionResponse(response, for: agentId)

        let snap = events.replay()
        #expect(sessionReady?.1 == "s-1")
        #expect(snap.metadata.sessionId == "s-1")
        #expect(snap.metadata.availableModes?.count == 2)
        #expect(snap.metadata.currentModeId == "auto")
        #expect(snap.metadata.availableModels?.first?.id == "gemini-2.5-pro")
        #expect(snap.metadata.displayModelName == "Gemini 2.5 Pro")
        #expect(snap.metadata.rawModelName == "gemini-2.5-pro")
    }

    @Test func loadSessionResponseUsesProvidedSessionId() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let response = GeminiAcpProtocol.LoadSessionResponse(modes: nil, models: nil)
        monitor.applyLoadSessionResponse(response, sessionId: "stored-1", for: agentId)

        let snap = events.replay()
        #expect(snap.metadata.sessionId == "stored-1")
    }

    // MARK: - turnCompleted ordering

    @Test func promptResponseFinalizesActiveStreamThenEmitsTurnCompleted() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        // Start a streaming assistant message.
        monitor.applySessionUpdate(
            .agentMessageChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "hello ")),
                messageId: nil
            )),
            sessionId: "s",
            for: agentId
        )
        monitor.applySessionUpdate(
            .agentMessageChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "world")),
                messageId: nil
            )),
            sessionId: "s",
            for: agentId
        )
        monitor.applyPromptResponse(
            GeminiAcpProtocol.PromptResponse(stopReason: .endTurn),
            for: agentId
        )

        // Contract: transcriptFinished must precede turnCompleted.
        let kinds = events.compactMap { event -> String? in
            switch event {
            case .transcriptFinished: "finished"
            case .turnCompleted: "turnCompleted"
            default: nil
            }
        }
        #expect(kinds == ["finished", "turnCompleted"])

        let snap = events.replay()
        #expect(snap.runState == .idle)
        #expect(snap.finalizedTranscript.last?.text == "hello world")
        #expect(snap.finalizedTranscript.last?.isStreaming == false)
    }

    @Test func promptResponseRefusalSetsErrorState() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.applyPromptResponse(
            GeminiAcpProtocol.PromptResponse(stopReason: .refusal),
            for: agentId
        )

        let snap = events.replay()
        if case .error = snap.runState {
            // expected
        } else {
            Issue.record("Expected .error after refusal, got \(snap.runState)")
        }
    }

    @Test func promptResponseUnknownStopReasonStillTransitionsToIdle() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.applyPromptResponse(
            GeminiAcpProtocol.PromptResponse(stopReason: nil, unknownStopReason: "future"),
            for: agentId
        )

        let snap = events.replay()
        #expect(snap.runState == .idle)
    }

    // MARK: - Permission flow

    @Test func permissionRequestEmitsApprovalAndTracksPending() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let permRequest = GeminiAcpProtocol.RequestPermissionRequest(
            sessionId: "s",
            toolCall: GeminiAcpProtocol.ToolCallUpdate(
                toolCallId: "tc1",
                title: "Run rm -rf",
                kind: .execute,
                status: nil,
                content: nil,
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            ),
            options: [
                GeminiAcpProtocol.PermissionOption(optionId: "ao", name: "Allow once", kind: .allowOnce),
                GeminiAcpProtocol.PermissionOption(optionId: "ro", name: "Reject once", kind: .rejectOnce),
            ]
        )
        monitor.applyPermissionRequest(permRequest, acpRequestId: .int(99), for: agentId)

        let snap = events.replay()
        #expect(snap.activePrompt != nil)
        #expect(snap.approvalPrompt?.actions.count == 2)
        #expect(snap.approvalPrompt?.actions.first?.kind == .allowOnce)
        #expect(monitor.pendingApprovalRequests[agentId]?.acpRequestId == .int(99))
    }

    @Test func respondToApprovalEmitsResolvedAndClearsPending() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let permRequest = GeminiAcpProtocol.RequestPermissionRequest(
            sessionId: "s",
            toolCall: GeminiAcpProtocol.ToolCallUpdate(
                toolCallId: "tc1",
                title: "Run rm -rf",
                kind: .execute,
                status: nil,
                content: nil,
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            ),
            options: [
                GeminiAcpProtocol.PermissionOption(optionId: "ao", name: "Allow", kind: .allowOnce),
            ]
        )
        monitor.applyPermissionRequest(permRequest, acpRequestId: .int(99), for: agentId)
        monitor.respondToApproval(for: agentId, optionId: "ao")

        let snap = events.replay()
        #expect(snap.activePrompt == nil)
        #expect(monitor.pendingApprovalRequests[agentId] == nil)
    }

    // MARK: - Streaming chunks

    @Test func agentThoughtChunkUsesThoughtKindAndStreams() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.applySessionUpdate(
            .agentThoughtChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "let me think")),
                messageId: nil
            )),
            sessionId: "s",
            for: agentId
        )
        monitor.applyPromptResponse(
            GeminiAcpProtocol.PromptResponse(stopReason: .endTurn),
            for: agentId
        )

        let snap = events.replay()
        let thought = snap.finalizedTranscript.first { $0.kind == .thought }
        #expect(thought?.text == "let me think")
    }

    // MARK: - Tool calls

    @Test func toolCallEmitsTranscriptAndSetsActiveTool() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let call = GeminiAcpProtocol.ToolCall(
            toolCallId: "tc1",
            title: "Read file",
            kind: .read,
            status: .inProgress,
            content: nil,
            locations: [GeminiAcpProtocol.ToolCallLocation(path: "/repo/foo.swift", line: 5)],
            rawInput: nil,
            rawOutput: nil
        )
        monitor.applySessionUpdate(.toolCall(call), sessionId: "s", for: agentId)

        let snap = events.replay()
        #expect(snap.metadata.activeToolName == "Read file")
        let tool = snap.transcript.first { $0.kind == .toolActivity }
        #expect(tool?.text.contains("Read file") == true)
    }

    @Test func toolCallUpdateCompletedClearsActiveTool() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let call = GeminiAcpProtocol.ToolCall(
            toolCallId: "tc1",
            title: "Read file",
            kind: .read,
            status: .inProgress,
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil
        )
        monitor.applySessionUpdate(.toolCall(call), sessionId: "s", for: agentId)

        let update = GeminiAcpProtocol.ToolCallUpdate(
            toolCallId: "tc1",
            title: nil,
            kind: nil,
            status: .completed,
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil
        )
        monitor.applySessionUpdate(.toolCallUpdate(update), sessionId: "s", for: agentId)

        let snap = events.replay()
        #expect(snap.metadata.activeToolName == nil)
    }

    @Test func toolCallUpdateOutOfOrderStillEmitsTranscript() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let update = GeminiAcpProtocol.ToolCallUpdate(
            toolCallId: "orphan",
            title: "Write to /repo/foo",
            kind: .edit,
            status: .completed,
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil
        )
        monitor.applySessionUpdate(.toolCallUpdate(update), sessionId: "s", for: agentId)

        let snap = events.replay()
        let tool = snap.transcript.first { $0.kind == .toolActivity }
        #expect(tool?.text.contains("Write to /repo/foo") == true)
    }

    // MARK: - Available commands + mode update

    @Test func availableCommandsUpdateSetsSlashCommands() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let payload = GeminiAcpProtocol.AvailableCommandsUpdate(availableCommands: [
            GeminiAcpProtocol.AvailableCommand(name: "compress", description: "Compress conversation", input: nil),
            GeminiAcpProtocol.AvailableCommand(name: "memory", description: "Manage memory", input: nil),
        ])
        monitor.applySessionUpdate(.availableCommandsUpdate(payload), sessionId: "s", for: agentId)

        let snap = events.replay()
        #expect(snap.metadata.slashCommands?.map(\.name) == ["compress", "memory"])
    }

    @Test func currentModeUpdateUpdatesCurrentModeId() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.applySessionUpdate(
            .currentModeUpdate(GeminiAcpProtocol.CurrentModeUpdate(currentModeId: "auto")),
            sessionId: "s",
            for: agentId
        )

        let snap = events.replay()
        #expect(snap.metadata.currentModeId == "auto")
    }

    // MARK: - Local user message reconciliation

    @Test func userMessageChunkMatchingPendingPromptReusesLocalId() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let imageBytes = Data([0x89, 0x50])
        monitor.recordSentUserMessage(
            for: agentId,
            text: "describe this",
            imageData: [imageBytes]
        )
        monitor.applySessionUpdate(
            .userMessageChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "describe this")),
                messageId: nil
            )),
            sessionId: "s",
            for: agentId
        )

        let snap = events.replay()
        let userMessages = snap.transcript.filter { $0.kind == .userMessage }
        // Reconciled to a single transcript item — the upsert reused the
        // local-user-* id rather than creating a second history item.
        #expect(userMessages.count == 1)
        #expect(userMessages[0].imageData == [imageBytes])
    }

    @Test func userMessageChunkWithoutMatchEmitsHistoricalItem() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.applySessionUpdate(
            .userMessageChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "earlier history")),
                messageId: "hist-1"
            )),
            sessionId: "s",
            for: agentId
        )

        let snap = events.replay()
        let userMessages = snap.transcript.filter { $0.kind == .userMessage }
        #expect(userMessages.count == 1)
        #expect(userMessages[0].text == "earlier history")
        #expect(userMessages[0].id.contains("hist-1"))
    }

    // MARK: - Mode/model setters

    @Test func setModeEmitsCurrentModeIdMetadata() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.setMode(for: agentId, modeId: "auto")

        let snap = events.replay()
        #expect(snap.metadata.currentModeId == "auto")
    }

    @Test func setModelEmitsCurrentModelIdMetadata() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.setModel(for: agentId, modelId: "gemini-2.5-flash")

        let snap = events.replay()
        #expect(snap.metadata.currentModelId == "gemini-2.5-flash")
    }
}
