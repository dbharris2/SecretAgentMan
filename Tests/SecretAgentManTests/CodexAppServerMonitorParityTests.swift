import Foundation
@testable import SecretAgentMan
import Testing

/// End-to-end parity tests for `CodexAppServerMonitor`.
///
/// Each test drives the monitor through the helper entry points the production
/// code uses (`emitStreamDelta`, `emitStreamFinalize`, `handleTranscriptItem`,
/// `recordSentUserMessage`, etc.), captures the emitted normalized
/// `SessionEvent`s, replays them through `AgentSessionReducer`, and asserts the
/// resulting visible `AgentSessionSnapshot`.
///
/// Snapshot-level assertions are the default. Event-sequence assertions appear
/// only where ordering itself is the contract under test.
@MainActor
struct CodexAppServerMonitorParityTests {
    // MARK: - Streaming

    @Test func streamingTraceProducesAccumulatedAssistantMessage() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamDelta(id: agentId, itemId: "msg-1", delta: "Hel")
        monitor.emitStreamDelta(id: agentId, itemId: "msg-1", delta: "lo ")
        monitor.emitStreamDelta(id: agentId, itemId: "msg-1", delta: "world")
        monitor.emitStreamFinalize(id: agentId, itemId: "msg-1")

        let snap = events.replay()

        #expect(snap.streamingAssistantText == nil)
        #expect(snap.finalizedTranscript.count == 1)
        #expect(snap.finalizedTranscript[0].text == "Hello world")
        #expect(snap.finalizedTranscript[0].isStreaming == false)
    }

    @Test func twoConcurrentStreamsBothFinalize() {
        // Codex tracks streaming per item-id, so two interleaved streams
        // should both finalize cleanly and end up as separate transcript items.
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.emitStreamDelta(id: agentId, itemId: "a", delta: "alpha")
        monitor.emitStreamDelta(id: agentId, itemId: "b", delta: "beta")
        monitor.emitStreamFinalize(id: agentId, itemId: "a")
        monitor.emitStreamFinalize(id: agentId, itemId: "b")

        let snap = events.replay()

        #expect(snap.finalizedTranscript.count == 2)
        #expect(snap.finalizedTranscript.allSatisfy { !$0.isStreaming })
    }

    // MARK: - Local-echo reconciliation

    @Test func localUserMessageWithImagesIsPreservedThroughServerEcho() {
        // Regression: Codex `recordSentUserMessage` stashes (id, text, images)
        // in `pendingLocalUserMessages`. When the server echoes the same text
        // back without images, the monitor reconciles to one logical item and
        // must keep the original images. Image preservation is the easy-to-
        // regress part.
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header
        monitor.recordSentUserMessage(
            for: agentId,
            text: "see this photo",
            imageData: [imageBytes]
        )
        // Server echoes back without images.
        let serverEcho = CodexTranscriptItem(
            id: "server-echo-1",
            role: .user,
            text: "see this photo"
        )
        monitor.handleTranscriptItem(agentId, item: serverEcho)

        let snap = events.replay()

        #expect(snap.transcript.count == 1)
        #expect(snap.transcript[0].text == "see this photo")
        #expect(snap.transcript[0].imageData == [imageBytes])
        // Canonical id stays the local one (the reducer updates in place
        // rather than appending a duplicate).
        #expect(snap.transcript[0].id.hasPrefix("local-user-"))
    }

    @Test func serverUserMessageWithNoLocalMatchAppearsAsServerItem() {
        // Hydration / out-of-band server messages have no local pending entry.
        // They should appear under the server's id with no reconciliation.
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.handleTranscriptItem(
            agentId,
            item: CodexTranscriptItem(id: "server-hydrate-1", role: .user, text: "from history")
        )

        let snap = events.replay()

        #expect(snap.transcript.count == 1)
        #expect(snap.transcript[0].id == "server-hydrate-1")
        #expect(snap.transcript[0].text == "from history")
    }

    // MARK: - Approval flow

    @Test func approvalPromptAndResolutionLeavesNoActivePrompt() {
        // Drive an approval prompt via the normalized emit, then resolve it.
        // The visible snapshot should end with no active prompt.
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        let approval = CodexAppServerMonitor.mapApprovalPrompt(
            CodexApprovalRequest(
                agentId: agentId,
                requestId: 1,
                threadId: "t",
                turnId: "T1",
                itemId: "approve-1",
                kind: .command(command: "rm -rf", reason: "dangerous")
            )
        )
        monitor.emit(.promptPresented(.approval(approval)), for: agentId)
        monitor.emit(.promptResolved(id: "approve-1"), for: agentId)

        let snap = events.replay()

        #expect(snap.activePrompt == nil)
        #expect(snap.queuedPrompts.isEmpty)
    }

    // MARK: - Metadata

    @Test func collaborationModeUpdateLandsInSnapshotMetadata() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.setCollaborationMode(for: agentId, mode: .plan)

        let snap = events.replay()

        #expect(snap.metadata.collaborationMode == "plan")
    }

    // MARK: - System transcript

    @Test func recordSystemTranscriptShowsAsSystemMessageInSnapshot() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        var events: [SessionEvent] = []
        monitor.onSessionEvent = { _, event in events.append(event) }

        monitor.recordSystemTranscript(for: agentId, text: "[Request interrupted by user]")

        let snap = events.replay()

        #expect(snap.transcript.count == 1)
        #expect(snap.transcript[0].kind == .systemMessage)
        #expect(snap.transcript[0].text == "[Request interrupted by user]")
    }
}
