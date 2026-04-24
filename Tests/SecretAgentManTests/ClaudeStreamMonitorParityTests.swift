import Foundation
@testable import SecretAgentMan
import Testing

/// End-to-end parity tests for `ClaudeStreamMonitor`.
///
/// Each test drives the monitor through the helper entry points the production
/// code actually uses, captures the emitted normalized `SessionEvent`s, replays
/// them through `AgentSessionReducer`, and asserts the resulting visible
/// `AgentSessionSnapshot`.
///
/// This is the "raw inputs → events → snapshot" composition the replay/parity
/// plan calls out. Snapshot-level assertions are the default; event-sequence
/// assertions are reserved for cases where ordering itself is the contract
/// (e.g. terminal-state suppression).
@MainActor
struct ClaudeStreamMonitorParityTests {
    // MARK: - Streaming

    @Test func streamingTraceProducesSingleFinalAssistantMessage() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        // Drive a Claude-shaped streaming turn: monotonic stream text, finalize,
        // then a canonical assistant transcript item that should reuse the
        // stream id via `lastFinalizedStreamId`.
        monitor.emitRunStateChanged(agentId, state: .active)
        monitor.emitStreamingText("Hel", for: agentId)
        monitor.emitStreamingText("Hello", for: agentId)
        monitor.emitStreamingText("Hello world", for: agentId)
        monitor.emitStreamingFinalize(for: agentId)
        monitor.emitTranscriptItem(
            agentId,
            item: CodexTranscriptItem(id: "claude-final-1", role: .assistant, text: "Hello world")
        )
        monitor.emitRunStateChanged(agentId, state: .awaitingInput)

        let snap = events.replay()

        #expect(snap.runState == .idle) // .awaitingInput → .idle in normalized
        #expect(snap.streamingAssistantText == nil)
        #expect(snap.finalizedTranscript.count == 1)
        #expect(snap.finalizedTranscript[0].text == "Hello world")
        #expect(snap.finalizedTranscript[0].kind == .assistantMessage)
    }

    @Test func toolActivityInterleavedWithStreamingDoesNotMerge() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        // Streaming → finalize → final assistant block, then a tool activity
        // item, then a second streaming turn. Each logical item should remain
        // distinct in the visible transcript.
        monitor.emitStreamingText("Let me check.", for: agentId)
        monitor.emitStreamingFinalize(for: agentId)
        monitor.emitTranscriptItem(
            agentId,
            item: CodexTranscriptItem(id: "asst-1", role: .assistant, text: "Let me check.")
        )
        monitor.emitTranscriptItem(
            agentId,
            item: CodexTranscriptItem(id: "tool-1", role: .system, text: "**Bash**: ls", toolName: "Bash")
        )
        monitor.emitStreamingText("Found ", for: agentId)
        monitor.emitStreamingText("Found three files.", for: agentId)
        monitor.emitStreamingFinalize(for: agentId)
        monitor.emitTranscriptItem(
            agentId,
            item: CodexTranscriptItem(id: "asst-2", role: .assistant, text: "Found three files.")
        )

        let snap = events.replay()

        #expect(snap.finalizedTranscript.count == 3)
        #expect(snap.finalizedTranscript[0].text == "Let me check.")
        #expect(snap.finalizedTranscript[1].kind == .toolActivity)
        #expect(snap.finalizedTranscript[2].text == "Found three files.")
    }

    // MARK: - Terminal-state suppression

    //
    // Ordering is the contract here, so we assert the emitted event sequence
    // alongside the snapshot — the plan's "exact event sequence checks
    // reserved for cases where ordering is the property under test."

    @Test func terminalFinishedIsSuppressedWhileStreamingActive() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamingText("partial", for: agentId)
        // Terminal `.finished` arrives mid-stream — Claude monitor must suppress.
        monitor.emitRunStateChanged(agentId, state: .finished)

        // No runStateChanged event should have been emitted between the two
        // calls above.
        let runStateEvents = events.compactMap { event -> SessionRunState? in
            if case let .runStateChanged(state) = event { return state }
            return nil
        }
        #expect(runStateEvents.isEmpty)

        // Snapshot should still show the streaming item and an idle run state
        // (no run-state change happened).
        let snap = events.replay()
        #expect(snap.runState == .idle)
        #expect(snap.streamingAssistantText == "partial")
    }

    @Test func terminalFinishedPassesThroughWhenNothingPending() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitRunStateChanged(agentId, state: .finished)

        let snap = events.replay()
        #expect(snap.runState == .finished)
    }

    // MARK: - Elicitation flow

    @Test func elicitationPromptAndResolutionLeavesNoActivePrompt() {
        // Drive an elicitation prompt through the normalized emit and resolve
        // it. The visible snapshot should end with no active prompt. The user
        // answer surfaces as a user transcript item via `respondToElicitation`,
        // but here we go through the `emit` path directly to keep this a
        // monitor-level parity check.
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let prompt = ClaudeStreamMonitor.mapElicitationPrompt(
            ClaudeElicitationRequest(
                agentId: agentId,
                requestId: "elicit-1",
                message: "Pick one",
                options: [
                    .init(label: "Alpha", description: ""),
                    .init(label: "Beta", description: ""),
                ]
            )
        )
        monitor.emit(.promptPresented(.userInput(prompt)), for: agentId)
        monitor.emit(.promptResolved(id: "elicit-1"), for: agentId)

        let snap = events.replay()

        #expect(snap.activePrompt == nil)
        #expect(snap.queuedPrompts.isEmpty)
    }

    // MARK: - Stream placeholder reconciliation

    @Test func streamPlaceholderReconciliationProducesOneItem() {
        // Regression: the streaming placeholder and the canonical final
        // assistant block must converge to one logical transcript item, not
        // duplicate.
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamingText("Hi", for: agentId)
        monitor.emitStreamingFinalize(for: agentId)
        monitor.emitTranscriptItem(
            agentId,
            item: CodexTranscriptItem(id: "claude-canonical-1", role: .assistant, text: "Hi final")
        )

        let snap = events.replay()

        #expect(snap.transcript.count == 1)
        #expect(snap.transcript[0].text == "Hi final")
        #expect(snap.transcript[0].isStreaming == false)
    }
}
