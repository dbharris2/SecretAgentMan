import Foundation
@testable import SecretAgentMan
import Testing

/// Unit tests for the Phase 1 dual-emit normalization layer. Covers the pure
/// mappers and the instance-level helpers that track streaming reconciliation
/// and terminal-state normalization rules.
@MainActor
struct ClaudeStreamMonitorSessionEventTests {
    // MARK: - mapRunState

    @Test func mapRunStateCoversAllCases() {
        #expect(ClaudeStreamMonitor.mapRunState(.idle) == .idle)
        #expect(ClaudeStreamMonitor.mapRunState(.active) == .running)
        #expect(ClaudeStreamMonitor.mapRunState(.needsPermission) == .needsPermission)
        // Claude's `.awaitingInput` means the turn finished and the user
        // has control — that's idle in the normalized model.
        #expect(ClaudeStreamMonitor.mapRunState(.awaitingInput) == .idle)
        // Claude's `.awaitingResponse` is elicitation (AskUserQuestion).
        #expect(ClaudeStreamMonitor.mapRunState(.awaitingResponse) == .needsInput)
        #expect(ClaudeStreamMonitor.mapRunState(.finished) == .finished)
        #expect(ClaudeStreamMonitor.mapRunState(.error) == .error(message: nil))
    }

    // MARK: - mapTranscriptItem

    @Test func mapTranscriptItemAssistantText() {
        let item = CodexTranscriptItem(id: "x", role: .assistant, text: "hello")
        let normalized = ClaudeStreamMonitor.mapTranscriptItem(item)
        #expect(normalized.kind == .assistantMessage)
        #expect(normalized.text == "hello")
    }

    @Test func mapTranscriptItemUser() {
        let item = CodexTranscriptItem(id: "x", role: .user, text: "hi")
        let normalized = ClaudeStreamMonitor.mapTranscriptItem(item)
        #expect(normalized.kind == .userMessage)
    }

    @Test func mapTranscriptItemSystemToolIsToolActivity() {
        let item = CodexTranscriptItem(id: "x", role: .system, text: "**Bash**: ls", toolName: "Bash")
        let normalized = ClaudeStreamMonitor.mapTranscriptItem(item)
        #expect(normalized.kind == .toolActivity)
        #expect(normalized.metadata?.toolName == "Bash")
    }

    @Test func mapTranscriptItemAssistantToolStaysAssistantMessage() {
        // AskUserQuestion / TodoWrite get role=.assistant + toolName set.
        // They should stay .assistantMessage so views don't collapse them
        // into the tool drawer.
        let item = CodexTranscriptItem(
            id: "x",
            role: .assistant,
            text: "❓ Question: ...",
            toolName: "AskUserQuestion"
        )
        let normalized = ClaudeStreamMonitor.mapTranscriptItem(item)
        #expect(normalized.kind == .assistantMessage)
        #expect(normalized.metadata?.toolName == "AskUserQuestion")
    }

    @Test func mapTranscriptItemPlainSystemIsSystemMessage() {
        let item = CodexTranscriptItem(id: "x", role: .system, text: "Error: boom")
        let normalized = ClaudeStreamMonitor.mapTranscriptItem(item)
        #expect(normalized.kind == .systemMessage)
    }

    // MARK: - mapApprovalPrompt / mapElicitationPrompt

    @Test func mapApprovalPrompt() {
        let request = ClaudeApprovalRequest(
            agentId: UUID(),
            requestId: "req-1",
            toolName: "Write",
            displayName: "Write File",
            inputDescription: "file_path: /tmp/x"
        )
        let prompt = ClaudeStreamMonitor.mapApprovalPrompt(request)
        #expect(prompt.id == "req-1")
        #expect(prompt.title == "Write File")
        #expect(prompt.message == "file_path: /tmp/x")
        #expect(prompt.options == ["allow", "deny"])
    }

    @Test func mapElicitationPromptWithoutOptionsAllowsFreeform() {
        let request = ClaudeElicitationRequest(
            agentId: UUID(),
            requestId: "req-2",
            message: "What should we do?",
            options: []
        )
        let prompt = ClaudeStreamMonitor.mapElicitationPrompt(request)
        #expect(prompt.id == "req-2")
        #expect(prompt.questions.count == 1)
        let question = prompt.questions[0]
        #expect(question.question == "What should we do?")
        #expect(question.allowsOther == true)
        #expect(question.options.isEmpty)
    }

    @Test func mapElicitationPromptWithOptionsDisallowsFreeform() {
        let request = ClaudeElicitationRequest(
            agentId: UUID(),
            requestId: "req-3",
            message: "Pick one",
            options: [
                CodexUserInputOption(label: "A", description: "first"),
                CodexUserInputOption(label: "B", description: ""),
            ]
        )
        let prompt = ClaudeStreamMonitor.mapElicitationPrompt(request)
        let question = prompt.questions[0]
        #expect(question.allowsOther == false)
        #expect(question.options.count == 2)
        #expect(question.options[0].label == "A")
        #expect(question.options[0].description == "first")
        // Empty descriptions normalize to nil so downstream consumers can
        // reliably check `description != nil` without special-casing "".
        #expect(question.options[1].description == nil)
    }

    // MARK: - Streaming emission

    @MainActor
    @Test func streamingEmitsUpsertThenDeltasThenFinished() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { id, event in
            #expect(id == agentId)
            events.append(event)
        }

        // First delivery creates the streaming item.
        monitor.emitStreamingText("Hel", for: agentId)
        // Second delivery computes the delta (monotonic append).
        monitor.emitStreamingText("Hello", for: agentId)
        // Finalize flips streaming off via transcriptFinished.
        monitor.emitStreamingFinalize(for: agentId)

        #expect(events.count == 3)
        guard case let .transcriptUpsert(item) = events[0] else {
            Issue.record("expected transcriptUpsert, got \(events[0])")
            return
        }
        #expect(item.kind == .assistantMessage)
        #expect(item.isStreaming)
        #expect(item.text == "Hel")

        guard case let .transcriptDelta(deltaId, appended) = events[1] else {
            Issue.record("expected transcriptDelta, got \(events[1])")
            return
        }
        #expect(deltaId == item.id)
        #expect(appended == "lo")

        guard case let .transcriptFinished(finishedId) = events[2] else {
            Issue.record("expected transcriptFinished, got \(events[2])")
            return
        }
        #expect(finishedId == item.id)
    }

    @MainActor
    @Test func streamingIgnoresNonMonotonicText() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamingText("Hello", for: agentId)
        // Shorter or non-prefix text is a defensive no-op — monitor should not
        // emit a malformed delta.
        monitor.emitStreamingText("Hi", for: agentId)

        #expect(events.count == 1)
    }

    @MainActor
    @Test func transcriptItemReusesFinalizedStreamId() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamingText("Hi", for: agentId)
        monitor.emitStreamingFinalize(for: agentId)

        guard case let .transcriptUpsert(streamItem) = events[0] else {
            Issue.record("expected transcriptUpsert first")
            return
        }
        events.removeAll()

        let finalItem = CodexTranscriptItem(
            id: "claude-msg-final",
            role: .assistant,
            text: "Hi final"
        )
        monitor.emitTranscriptItem(agentId, item: finalItem)

        #expect(events.count == 1)
        guard case let .transcriptUpsert(reconciled) = events[0] else {
            Issue.record("expected transcriptUpsert after stream finalize")
            return
        }
        // The final assistant text block reuses the streaming id so the
        // reducer replaces the placeholder rather than appending a duplicate.
        #expect(reconciled.id == streamItem.id)
        #expect(reconciled.text == "Hi final")
        #expect(reconciled.isStreaming == false)
    }

    @MainActor
    @Test func toolActivityAfterStreamingKeepsOwnId() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamingText("Hi", for: agentId)
        monitor.emitStreamingFinalize(for: agentId)
        events.removeAll()

        // Tool activity is a distinct item — should NOT steal the stream id.
        let toolItem = CodexTranscriptItem(
            id: "tool-item-1",
            role: .system,
            text: "**Bash**: ls",
            toolName: "Bash"
        )
        monitor.emitTranscriptItem(agentId, item: toolItem)

        guard case let .transcriptUpsert(normalized) = events[0] else {
            Issue.record("expected transcriptUpsert")
            return
        }
        #expect(normalized.id == "tool-item-1")
        #expect(normalized.kind == .toolActivity)
    }

    // MARK: - Terminal normalization

    @MainActor
    @Test func finishedPassesThroughWhenIdle() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitRunStateChanged(agentId, state: .finished)
        #expect(events.count == 1)
        if case .runStateChanged(.finished) = events[0] {
            // pass-through — no pending prompt or stream
        } else {
            Issue.record("expected .runStateChanged(.finished), got \(events[0])")
        }
    }

    @MainActor
    @Test func finishedIsSuppressedWhileStreaming() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamingText("partial", for: agentId)
        events.removeAll()

        monitor.emitRunStateChanged(agentId, state: .finished)

        #expect(events.isEmpty)
    }

    @MainActor
    @Test func nonFinishedStatesPassThrough() {
        let monitor = ClaudeStreamMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamingText("partial", for: agentId)
        events.removeAll()

        // Streaming in progress, but an .active state change should still emit.
        monitor.emitRunStateChanged(agentId, state: .active)

        #expect(events.count == 1)
        if case .runStateChanged(.running) = events[0] {
            // ok
        } else {
            Issue.record("expected .runStateChanged(.running), got \(events[0])")
        }
    }
}
