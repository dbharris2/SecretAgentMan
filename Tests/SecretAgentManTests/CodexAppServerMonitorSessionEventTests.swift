import Foundation
@testable import SecretAgentMan
import Testing

/// Unit tests for the Phase 1 dual-emit normalization layer on the Codex
/// monitor. Covers the pure mappers and the instance-level helpers that
/// track per-item streaming and reconcile local-user-* ids with the
/// server's echoes.
@MainActor
struct CodexAppServerMonitorSessionEventTests {
    // MARK: - mapRunState

    @Test func mapRunStateCoversAllCases() {
        #expect(CodexAppServerMonitor.mapRunState(.idle) == .idle)
        #expect(CodexAppServerMonitor.mapRunState(.active) == .running)
        #expect(CodexAppServerMonitor.mapRunState(.needsPermission) == .needsPermission)
        #expect(CodexAppServerMonitor.mapRunState(.awaitingInput) == .idle)
        #expect(CodexAppServerMonitor.mapRunState(.awaitingResponse) == .needsInput)
        #expect(CodexAppServerMonitor.mapRunState(.finished) == .finished)
        #expect(CodexAppServerMonitor.mapRunState(.error) == .error(message: nil))
    }

    // MARK: - mapTranscriptItem

    @Test func mapTranscriptItemCommandToolBecomesToolActivity() {
        let detail = CodexCommandToolDetail(
            command: "ls",
            output: "",
            status: nil,
            exitCode: nil,
            durationMs: nil,
            isRunning: true
        )
        var item = CodexTranscriptItem(id: "x", role: .system, text: "")
        item.tool = .command(detail)
        let normalized = CodexAppServerMonitor.mapTranscriptItem(item)
        #expect(normalized.kind == .toolActivity)
        #expect(normalized.metadata?.toolName == "command")
    }

    @Test func mapTranscriptItemFileChangeToolBecomesToolActivity() {
        let detail = CodexFileChangeToolDetail(patch: "diff", status: nil, isRunning: false)
        var item = CodexTranscriptItem(id: "x", role: .system, text: "")
        item.tool = .fileChange(detail)
        let normalized = CodexAppServerMonitor.mapTranscriptItem(item)
        #expect(normalized.kind == .toolActivity)
        #expect(normalized.metadata?.toolName == "fileChange")
    }

    @Test func mapTranscriptItemUserAssistantSystem() {
        let user = CodexTranscriptItem(id: "u", role: .user, text: "hi")
        let assistant = CodexTranscriptItem(id: "a", role: .assistant, text: "hello")
        let system = CodexTranscriptItem(id: "s", role: .system, text: "Error")

        #expect(CodexAppServerMonitor.mapTranscriptItem(user).kind == .userMessage)
        #expect(CodexAppServerMonitor.mapTranscriptItem(assistant).kind == .assistantMessage)
        #expect(CodexAppServerMonitor.mapTranscriptItem(system).kind == .systemMessage)
    }

    @Test func mapTranscriptItemAppliesOverrideId() {
        let item = CodexTranscriptItem(id: "server-123", role: .user, text: "hi")
        let normalized = CodexAppServerMonitor.mapTranscriptItem(item, overrideId: "local-user-abc")
        #expect(normalized.id == "local-user-abc")
        #expect(normalized.text == "hi")
    }

    // MARK: - mapApprovalPrompt

    @Test func mapApprovalPromptForCommand() {
        let request = CodexApprovalRequest(
            agentId: UUID(),
            requestId: 1,
            threadId: "t",
            turnId: "T1",
            itemId: "item-1",
            kind: .command(command: "rm -rf", reason: "dangerous")
        )
        let prompt = CodexAppServerMonitor.mapApprovalPrompt(request)
        #expect(prompt.id == "item-1")
        #expect(prompt.title == "Command Approval")
        #expect(prompt.actions.map(\.id) == ["allow", "deny"])
        #expect(prompt.actions.map(\.label) == ["Allow", "Deny"])
        #expect(prompt.actions.map(\.isDestructive) == [false, true])
        #expect(prompt.supportsDecisions)
    }

    @Test func mapApprovalPromptForUnsupportedPermissionsIsDismissOnly() {
        let request = CodexApprovalRequest(
            agentId: UUID(),
            requestId: 2,
            threadId: "t",
            turnId: "T1",
            itemId: "item-2",
            kind: .unsupportedPermissions(reason: "explain")
        )
        let prompt = CodexAppServerMonitor.mapApprovalPrompt(request)
        #expect(prompt.actions.map(\.id) == ["dismiss"])
        #expect(prompt.supportsDecisions == false)
    }

    // MARK: - mapUserInputPrompt

    @Test func mapUserInputPromptNormalizesEmptyDescriptions() {
        let request = CodexUserInputRequest(
            agentId: UUID(),
            threadId: "t",
            turnId: "T1",
            itemId: "item-u1",
            questions: [
                CodexUserInputQuestion(
                    id: "q1",
                    header: "Pick",
                    prompt: "Choose a color",
                    options: [
                        CodexUserInputOption(label: "red", description: "warm"),
                        CodexUserInputOption(label: "blue", description: ""),
                    ],
                    allowsOther: true
                ),
            ]
        )
        let prompt = CodexAppServerMonitor.mapUserInputPrompt(request)
        #expect(prompt.id == "item-u1")
        #expect(prompt.questions.count == 1)
        let question = prompt.questions[0]
        #expect(question.allowsOther == true)
        #expect(question.options[0].description == "warm")
        #expect(question.options[1].description == nil)
    }

    // MARK: - Streaming emission

    @Test func streamDeltasEmitUpsertThenDeltasThenFinished() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamDelta(id: agentId, itemId: "msg-1", delta: "Hel")
        monitor.emitStreamDelta(id: agentId, itemId: "msg-1", delta: "lo")
        monitor.emitStreamFinalize(id: agentId, itemId: "msg-1")

        #expect(events.count == 3)
        guard case let .transcriptUpsert(item) = events[0] else {
            Issue.record("expected transcriptUpsert, got \(events[0])")
            return
        }
        #expect(item.id == "msg-1")
        #expect(item.isStreaming)
        #expect(item.text == "Hel")

        guard case let .transcriptDelta(id, appended) = events[1] else {
            Issue.record("expected transcriptDelta, got \(events[1])")
            return
        }
        #expect(id == "msg-1")
        #expect(appended == "lo")

        guard case let .transcriptFinished(finishedId) = events[2] else {
            Issue.record("expected transcriptFinished, got \(events[2])")
            return
        }
        #expect(finishedId == "msg-1")
    }

    @Test func concurrentStreamIdsAreTrackedIndependently() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        // Two different item ids should produce two independent upserts.
        monitor.emitStreamDelta(id: agentId, itemId: "msg-a", delta: "A")
        monitor.emitStreamDelta(id: agentId, itemId: "msg-b", delta: "B")

        #expect(events.count == 2)
        let ids = events.compactMap { event -> String? in
            if case let .transcriptUpsert(item) = event { return item.id }
            return nil
        }
        #expect(Set(ids) == Set(["msg-a", "msg-b"]))
    }

    @Test func streamFinalizeForUntrackedItemIsNoOp() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamFinalize(id: agentId, itemId: "unknown")
        #expect(events.isEmpty)
    }

    // MARK: - Local user message reconciliation

    @Test func localUserMessageReconcilesServerEchoToLocalId() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        // User sends a message — monitor appends local-user-* item and emits
        // a normalized upsert under the local id.
        monitor.recordSentUserMessage(for: agentId, text: "hello world", imageData: [])

        guard case let .transcriptUpsert(localItem) = events.last else {
            Issue.record("expected transcriptUpsert for local user message")
            return
        }
        #expect(localItem.id.hasPrefix("local-user-"))
        #expect(localItem.kind == .userMessage)

        events.removeAll()

        // Server later echoes the user message with its own id.
        let serverItem = CodexTranscriptItem(
            id: "server-user-42",
            role: .user,
            text: "hello world"
        )
        monitor.handleTranscriptItem(agentId, item: serverItem)

        // Reconciliation: the normalized path keeps the local id so the
        // reducer updates the existing item rather than appending a dup.
        #expect(events.count == 1)
        guard case let .transcriptUpsert(reconciled) = events[0] else {
            Issue.record("expected transcriptUpsert after server echo")
            return
        }
        #expect(reconciled.id == localItem.id)
        #expect(reconciled.text == "hello world")
    }

    @Test func serverUserMessageWithNoLocalMatchKeepsServerId() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        // No pending local-user-* entries — server-initiated hydration.
        let serverItem = CodexTranscriptItem(
            id: "server-hydrate-1",
            role: .user,
            text: "old message from history"
        )
        monitor.handleTranscriptItem(agentId, item: serverItem)

        #expect(events.count == 1)
        guard case let .transcriptUpsert(item) = events[0] else {
            Issue.record("expected transcriptUpsert")
            return
        }
        #expect(item.id == "server-hydrate-1")
    }

    // MARK: - recordSystemTranscript

    @Test func recordSystemTranscriptEmitsSystemMessage() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.recordSystemTranscript(for: agentId, text: "session stopped")

        #expect(events.count == 1)
        guard case let .transcriptUpsert(item) = events[0] else {
            Issue.record("expected transcriptUpsert")
            return
        }
        #expect(item.kind == .systemMessage)
        #expect(item.text == "session stopped")
    }

    // MARK: - Collaboration mode

    @Test func setCollaborationModeEmitsMetadataUpdate() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.setCollaborationMode(for: agentId, mode: .plan)

        #expect(events.count == 1)
        guard case let .metadataUpdated(update) = events[0] else {
            Issue.record("expected metadataUpdated")
            return
        }
        #expect(update.collaborationMode == .set("plan"))
    }
}
