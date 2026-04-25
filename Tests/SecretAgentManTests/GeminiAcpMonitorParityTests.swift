import Foundation
@testable import SecretAgentMan
import Testing

/// End-to-end parity tests for `GeminiAcpMonitor`. Mirrors the structure of
/// `CodexAppServerMonitorParityTests`: drive the monitor through the same
/// `apply*` entry points the production Observer uses, capture the emitted
/// `SessionEvent`s, replay through `AgentSessionReducer`, and assert on the
/// resulting `AgentSessionSnapshot`.
@MainActor
struct GeminiAcpMonitorParityTests {
    // MARK: - Full turn

    @Test func newSessionFollowedByUserPromptThoughtsTextAndEndTurn() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        // 1. session/new response
        monitor.applyNewSessionResponse(
            GeminiAcpProtocol.NewSessionResponse(
                sessionId: "s-1",
                modes: GeminiAcpProtocol.SessionModeState(
                    availableModes: [
                        GeminiAcpProtocol.SessionMode(id: "default", name: "Default", description: nil),
                    ],
                    currentModeId: "default"
                ),
                models: GeminiAcpProtocol.SessionModelState(
                    availableModels: [
                        GeminiAcpProtocol.ModelInfo(modelId: "g-pro", name: "Pro", description: nil),
                    ],
                    currentModelId: "g-pro"
                )
            ),
            for: agentId
        )

        // 2. User sends a prompt locally; monitor records it.
        monitor.recordSentUserMessage(for: agentId, text: "hello", imageData: [])

        // 3. Agent thought stream + message stream + endTurn.
        monitor.applySessionUpdate(
            .agentThoughtChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "thinking...")),
                messageId: nil
            )),
            sessionId: "s-1",
            for: agentId
        )
        monitor.applySessionUpdate(
            .agentMessageChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "Hi! ")),
                messageId: nil
            )),
            sessionId: "s-1",
            for: agentId
        )
        monitor.applySessionUpdate(
            .agentMessageChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "How can I help?")),
                messageId: nil
            )),
            sessionId: "s-1",
            for: agentId
        )
        monitor.applyPromptResponse(
            GeminiAcpProtocol.PromptResponse(stopReason: .endTurn),
            for: agentId
        )

        let snap = events.replay()

        #expect(snap.runState == .idle)
        #expect(snap.metadata.sessionId == "s-1")
        #expect(snap.metadata.currentModelId == "g-pro")
        #expect(snap.streamingAssistantText == nil)
        // 1 user message + 1 thought + 1 assistant — exact transcript shape.
        let kinds = snap.finalizedTranscript.map(\.kind)
        #expect(kinds == [.userMessage, .thought, .assistantMessage])
        #expect(snap.finalizedTranscript[0].text == "hello")
        #expect(snap.finalizedTranscript[1].text == "thinking...")
        #expect(snap.finalizedTranscript[2].text == "Hi! How can I help?")
    }

    // MARK: - Tool call lifecycle

    @Test func toolCallFromInProgressToCompletedClearsActiveTool() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.applySessionUpdate(
            .toolCall(GeminiAcpProtocol.ToolCall(
                toolCallId: "tc1",
                title: "Read README",
                kind: .read,
                status: .inProgress,
                content: nil,
                locations: [GeminiAcpProtocol.ToolCallLocation(path: "README.md", line: nil)],
                rawInput: nil,
                rawOutput: nil
            )),
            sessionId: "s-1",
            for: agentId
        )

        // Mid-progress: assert active tool is set.
        var snap = events.replay()
        #expect(snap.metadata.activeToolName == "Read README")

        // Completion update.
        monitor.applySessionUpdate(
            .toolCallUpdate(GeminiAcpProtocol.ToolCallUpdate(
                toolCallId: "tc1",
                title: nil,
                kind: nil,
                status: .completed,
                content: [.content(.text(GeminiAcpProtocol.TextContent(text: "file body")))],
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            )),
            sessionId: "s-1",
            for: agentId
        )

        snap = events.replay()
        #expect(snap.metadata.activeToolName == nil)
        let tool = snap.transcript.first { $0.kind == .toolActivity }
        #expect(tool?.text.contains("file body") == true)
    }

    // MARK: - Approval flow

    @Test func approvalFlowEndToEnd() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let permRequest = GeminiAcpProtocol.RequestPermissionRequest(
            sessionId: "s",
            toolCall: GeminiAcpProtocol.ToolCallUpdate(
                toolCallId: "tc-cmd",
                title: "Run rm -rf /tmp/foo",
                kind: .execute,
                status: nil,
                content: nil,
                locations: nil,
                rawInput: nil,
                rawOutput: nil
            ),
            options: [
                GeminiAcpProtocol.PermissionOption(optionId: "ao", name: "Allow", kind: .allowOnce),
                GeminiAcpProtocol.PermissionOption(optionId: "ro", name: "Deny", kind: .rejectOnce),
            ]
        )

        monitor.applyPermissionRequest(permRequest, acpRequestId: .int(42), for: agentId)
        var snap = events.replay()
        #expect(snap.activePrompt?.id == "gemini-perm-tc-cmd")
        #expect(snap.approvalPrompt?.actions.count == 2)

        monitor.respondToApproval(for: agentId, optionId: "ao")
        snap = events.replay()
        #expect(snap.activePrompt == nil)
    }

    // MARK: - Cancellation

    @Test func turnCompletedCancelledTransitionsToIdleAfterStreamFinalizes() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        // Start streaming, then cancel mid-flight.
        monitor.applySessionUpdate(
            .agentMessageChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "partial")),
                messageId: nil
            )),
            sessionId: "s",
            for: agentId
        )
        monitor.applyPromptResponse(
            GeminiAcpProtocol.PromptResponse(stopReason: .cancelled),
            for: agentId
        )

        let snap = events.replay()
        #expect(snap.runState == .idle)
        // The streaming bubble is finalized — cancelled is an end-of-turn,
        // not a "discard the partial response" signal.
        #expect(snap.streamingAssistantText == nil)
        #expect(snap.finalizedTranscript.last?.text == "partial")
    }

    // MARK: - Plan + slash commands together

    @Test func planUpdateAddsPlanItemAndAvailableCommandsUpdatesMetadata() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.applySessionUpdate(
            .plan(GeminiAcpProtocol.Plan(entries: [
                GeminiAcpProtocol.PlanEntry(content: "step 1", priority: .high, status: .inProgress),
                GeminiAcpProtocol.PlanEntry(content: "step 2", priority: .medium, status: .pending),
            ])),
            sessionId: "s",
            for: agentId
        )
        monitor.applySessionUpdate(
            .availableCommandsUpdate(GeminiAcpProtocol.AvailableCommandsUpdate(availableCommands: [
                GeminiAcpProtocol.AvailableCommand(name: "compress", description: "Compress", input: nil),
            ])),
            sessionId: "s",
            for: agentId
        )

        let snap = events.replay()
        let plan = snap.transcript.first { $0.kind == .plan }
        #expect(plan != nil)
        #expect(plan?.text.contains("step 1") == true)
        #expect(snap.metadata.slashCommands?.first?.name == "compress")
    }

    // MARK: - Refusal flow

    @Test func refusalEndsTurnInErrorStateWithFinalizedTranscript() {
        let monitor = GeminiAcpMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.applySessionUpdate(
            .agentMessageChunk(GeminiAcpProtocol.ContentChunk(
                content: .text(GeminiAcpProtocol.TextContent(text: "I can't help with that.")),
                messageId: nil
            )),
            sessionId: "s",
            for: agentId
        )
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
        #expect(snap.finalizedTranscript.last?.text == "I can't help with that.")
    }
}
