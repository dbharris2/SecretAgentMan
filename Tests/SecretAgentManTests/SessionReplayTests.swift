import Foundation
@testable import SecretAgentMan
import Testing

/// Replay-style tests for the normalized `SessionEvent` pipeline.
///
/// These verify "given this ordered event sequence, did we end up in the
/// right visible snapshot?" — the layer above unit-level reducer transitions
/// and below provider-specific parity tests. Each test should read as a
/// realistic mini-trace of session activity.
///
/// When a failure here is hard to localize, swap `.replay()` for
/// `.replayWithIntermediates()` and inspect which event caused the
/// divergence.
@MainActor
struct SessionReplayTests {
    // MARK: - Streaming

    @Test func claudeStyleStreamingResponseProducesFinalAssistantMessage() {
        let events: [SessionEvent] = [
            .sessionReady(sessionId: "sess-1"),
            .runStateChanged(.running),
            .transcriptUpsert(SessionTranscriptItem(
                id: "stream-1", kind: .assistantMessage, text: "Hel", isStreaming: true
            )),
            .transcriptDelta(id: "stream-1", appendedText: "lo "),
            .transcriptDelta(id: "stream-1", appendedText: "world"),
            .transcriptFinished(id: "stream-1"),
            // Claude pattern: the canonical assistant item upserts after the
            // stream finishes, reusing the stream id (via `lastFinalizedStreamId`
            // reconciliation in the monitor).
            .transcriptUpsert(SessionTranscriptItem(
                id: "stream-1", kind: .assistantMessage, text: "Hello world"
            )),
            .runStateChanged(.idle),
        ]
        let snap = events.replay()

        #expect(snap.runState == .idle)
        #expect(snap.streamingAssistantText == nil)
        #expect(snap.finalizedTranscript.count == 1)
        #expect(snap.finalizedTranscript[0].text == "Hello world")
        #expect(snap.finalizedTranscript[0].isStreaming == false)
    }

    @Test func assistantStreamInterleavedWithToolActivity() {
        // Real Claude turns interleave: assistant stream → tool use → tool
        // result → assistant stream resumes. The reducer must keep transcript
        // ordering by event order, not by id, and must not duplicate the
        // streaming bubble in `finalizedTranscript`.
        let events: [SessionEvent] = [
            .runStateChanged(.running),
            .transcriptUpsert(SessionTranscriptItem(
                id: "asst-1", kind: .assistantMessage, text: "Let me check.", isStreaming: true
            )),
            .transcriptFinished(id: "asst-1"),
            .transcriptUpsert(SessionTranscriptItem(
                id: "asst-1", kind: .assistantMessage, text: "Let me check."
            )),
            .transcriptUpsert(SessionTranscriptItem(
                id: "tool-1",
                kind: .toolActivity,
                text: "**Bash**: ls",
                metadata: TranscriptItemMetadata(toolName: "Bash")
            )),
            .transcriptUpsert(SessionTranscriptItem(
                id: "asst-2", kind: .assistantMessage, text: "Found ", isStreaming: true
            )),
            .transcriptDelta(id: "asst-2", appendedText: "three files."),
            .transcriptFinished(id: "asst-2"),
            .transcriptUpsert(SessionTranscriptItem(
                id: "asst-2", kind: .assistantMessage, text: "Found three files."
            )),
            .runStateChanged(.idle),
        ]
        let snap = events.replay()

        #expect(snap.streamingAssistantText == nil)
        #expect(snap.finalizedTranscript.count == 3)
        #expect(snap.finalizedTranscript[0].text == "Let me check.")
        #expect(snap.finalizedTranscript[1].kind == .toolActivity)
        #expect(snap.finalizedTranscript[2].text == "Found three files.")
    }

    // MARK: - Approval flow

    @Test func codexApprovalFlowFromRunningToResolved() {
        let approval = ApprovalPrompt(
            id: "approve-1",
            title: "Run rm -rf?",
            message: "OK?",
            actions: [
                ApprovalAction(id: "allow", label: "Allow"),
                ApprovalAction(id: "deny", label: "Deny", isDestructive: true),
            ]
        )
        let events: [SessionEvent] = [
            .sessionReady(sessionId: "thread-1"),
            .runStateChanged(.running),
            .runStateChanged(.needsPermission),
            .promptPresented(.approval(approval)),
            // User answers — monitor emits resolved + transitions back to running.
            .promptResolved(id: "approve-1"),
            .runStateChanged(.running),
            .runStateChanged(.idle),
        ]
        let snap = events.replay()

        #expect(snap.runState == .idle)
        #expect(snap.activePrompt == nil)
        #expect(snap.queuedPrompts.isEmpty)
    }

    // MARK: - Elicitation flow

    @Test func claudeElicitationFlowFromRunningToResumed() {
        let prompt = UserInputPrompt(
            id: "elicit-1",
            title: "Input Requested",
            message: "Pick one",
            questions: [
                PromptQuestion(
                    id: "q1",
                    header: "Choose",
                    question: "Alpha or beta?",
                    allowsOther: false,
                    options: [
                        PromptOption(label: "Alpha"),
                        PromptOption(label: "Beta"),
                    ]
                ),
            ]
        )
        let events: [SessionEvent] = [
            .runStateChanged(.running),
            .runStateChanged(.needsInput),
            .promptPresented(.userInput(prompt)),
            // User answers — answer surfaces as a user transcript item.
            .transcriptUpsert(SessionTranscriptItem(
                id: "user-answer", kind: .userMessage, text: "Alpha"
            )),
            .promptResolved(id: "elicit-1"),
            .runStateChanged(.running),
            .runStateChanged(.idle),
        ]
        let snap = events.replay()

        #expect(snap.runState == .idle)
        #expect(snap.activePrompt == nil)
        #expect(snap.finalizedTranscript.contains { $0.text == "Alpha" })
    }

    // MARK: - sessionReady replacement

    @Test func secondSessionReadyClearsTranscriptAndPrompts() {
        // Bug class: an in-flight session is replaced by a new sessionId
        // (e.g. user starts a fresh conversation). Transcript and prompt
        // state must clear; metadata that's session-scoped (sessionId)
        // updates; agent-level metadata (model name, permission mode)
        // is intentionally preserved unless the monitor re-clears it.
        let pending = ApprovalPrompt(
            id: "a",
            title: "T",
            message: "M",
            actions: [ApprovalAction(id: "allow", label: "Allow")]
        )
        var update = SessionMetadataUpdate()
        update.displayModelName = .set("Claude Sonnet")
        update.permissionMode = .set("acceptEdits")

        let events: [SessionEvent] = [
            .sessionReady(sessionId: "old"),
            .metadataUpdated(update),
            .runStateChanged(.running),
            .transcriptUpsert(SessionTranscriptItem(
                id: "u1", kind: .userMessage, text: "first"
            )),
            .promptPresented(.approval(pending)),
            // Replacement.
            .sessionReady(sessionId: "new"),
        ]
        let snap = events.replay()

        #expect(snap.metadata.sessionId == "new")
        #expect(snap.transcript.isEmpty)
        #expect(snap.activePrompt == nil)
        #expect(snap.queuedPrompts.isEmpty)
        #expect(snap.runState == .idle)
        // Agent-level metadata preserved across the replacement boundary.
        #expect(snap.metadata.displayModelName == "Claude Sonnet")
        #expect(snap.metadata.permissionMode == "acceptEdits")
    }

    // MARK: - Error recovery

    @Test func errorStateIsReplacedByLaterRunningOrIdle() {
        let events: [SessionEvent] = [
            .runStateChanged(.running),
            .transcriptUpsert(SessionTranscriptItem(
                id: "u1", kind: .userMessage, text: "hi"
            )),
            .runStateChanged(.error(message: "stream broken")),
            // Recovery — error state should be replaced, transcript preserved.
            .runStateChanged(.running),
            .runStateChanged(.idle),
        ]
        let snap = events.replay()

        #expect(snap.runState == .idle)
        #expect(snap.finalizedTranscript.count == 1)
    }

    // MARK: - Regression fixtures

    //
    // Each test below pins a specific bug class the plan called out. The
    // comment names the failure mode so future readers know what regression
    // they protect against.

    @Test func bootstrapSessionReadyDoesNotClearPriorTranscript() {
        // Regression: in real Claude flows the user can send a message
        // *before* the provider emits its first `sessionReady`. The first
        // `sessionReady` must be treated as bootstrap (no clearing), not
        // replacement. We shipped a fix for this — this fixture pins it.
        let events: [SessionEvent] = [
            .transcriptUpsert(SessionTranscriptItem(
                id: "u1", kind: .userMessage, text: "early message"
            )),
            .runStateChanged(.running),
            .sessionReady(sessionId: "sess-bootstrap"),
        ]
        let snap = events.replay()

        #expect(snap.metadata.sessionId == "sess-bootstrap")
        #expect(snap.finalizedTranscript.count == 1)
        #expect(snap.finalizedTranscript[0].text == "early message")
        #expect(snap.runState == .running)
    }

    @Test func promptResolvedWhileQueuedRemovesQueuedEntry() {
        // Regression: if a second prompt arrives while one is active, it
        // queues. If the *queued* prompt's id resolves (out-of-band, e.g.
        // protocol cancel), it must drop from the queue without disturbing
        // the active prompt.
        let active = ApprovalPrompt(
            id: "a",
            title: "A",
            message: "",
            actions: [ApprovalAction(id: "allow", label: "Allow")]
        )
        let queued = ApprovalPrompt(
            id: "q",
            title: "Q",
            message: "",
            actions: [ApprovalAction(id: "allow", label: "Allow")]
        )

        let events: [SessionEvent] = [
            .promptPresented(.approval(active)),
            .promptPresented(.approval(queued)),
            .promptResolved(id: "q"),
        ]
        let snap = events.replay()

        #expect(snap.activePrompt?.id == "a")
        #expect(snap.queuedPrompts.isEmpty)
    }

    @Test func streamFinalizeBeforeCanonicalUpsertConverges() {
        // Regression: the monitor flips a streaming placeholder via
        // `transcriptFinished(id:)` and then upserts the final canonical
        // content reusing that same id. The two events can land in either
        // order for late-arriving server echoes. After both, exactly one
        // logical assistant item should remain, finalized, with the canonical
        // text.
        let events: [SessionEvent] = [
            .transcriptUpsert(SessionTranscriptItem(
                id: "stream-1", kind: .assistantMessage, text: "Hel", isStreaming: true
            )),
            .transcriptDelta(id: "stream-1", appendedText: "lo"),
            .transcriptFinished(id: "stream-1"),
            .transcriptUpsert(SessionTranscriptItem(
                id: "stream-1", kind: .assistantMessage, text: "Hello"
            )),
        ]
        let snap = events.replay()

        #expect(snap.transcript.count == 1)
        #expect(snap.transcript[0].text == "Hello")
        #expect(snap.transcript[0].isStreaming == false)
    }

    @Test func localEchoReconciliationPreservesImageData() {
        // Regression: Codex `recordSentUserMessage` upserts a user item with
        // a `local-user-*` id and image data. The server echoes the same
        // text back without images; the monitor reconciles by reusing the
        // local id but the merged item it emits must keep the original
        // images. Image preservation is the easy-to-regress part — the
        // server never round-trips image bytes.
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header

        let events: [SessionEvent] = [
            // Local echo: user sent a message with an image.
            .transcriptUpsert(SessionTranscriptItem(
                id: "local-user-abc",
                kind: .userMessage,
                text: "see this",
                imageData: [imageBytes]
            )),
            // Server echo arrives with the same canonical id (the monitor
            // reconciles via `pendingLocalUserMessages`) but its items array
            // already includes the original images because the monitor merged
            // them in before emitting.
            .transcriptUpsert(SessionTranscriptItem(
                id: "local-user-abc",
                kind: .userMessage,
                text: "see this",
                imageData: [imageBytes]
            )),
        ]
        let snap = events.replay()

        #expect(snap.transcript.count == 1)
        #expect(snap.transcript[0].imageData == [imageBytes])
    }

    @Test func runStateNeedsPermissionPersistsThroughLaterPromptPresent() {
        // Regression: once the monitor has decided we're blocked on a prompt,
        // the `needsPermission`/`needsInput` run state should survive
        // alongside the active prompt. This is the snapshot-level analog of
        // the coordinator's terminal-state suppression rule.
        let approval = ApprovalPrompt(
            id: "a",
            title: "T",
            message: "M",
            actions: [
                ApprovalAction(id: "allow", label: "Allow"),
                ApprovalAction(id: "deny", label: "Deny", isDestructive: true),
            ]
        )
        let events: [SessionEvent] = [
            .runStateChanged(.running),
            .runStateChanged(.needsPermission),
            .promptPresented(.approval(approval)),
        ]
        let snap = events.replay()

        #expect(snap.runState == .needsPermission)
        #expect(snap.activePrompt?.id == "a")
    }

    // MARK: - Intermediate-snapshot diagnostics

    @Test func replayWithIntermediatesReturnsOneSnapshotPerEventPlusInitial() {
        // Sanity check on the helper itself: intermediate count is
        // events.count + 1 (including the initial empty snapshot at index 0),
        // so a failing larger replay can locate the divergence by index.
        let events: [SessionEvent] = [
            .runStateChanged(.running),
            .transcriptUpsert(SessionTranscriptItem(
                id: "u1", kind: .userMessage, text: "hi"
            )),
            .runStateChanged(.idle),
        ]
        let snapshots = events.replayWithIntermediates()

        #expect(snapshots.count == events.count + 1)
        #expect(snapshots[0].runState == .idle) // initial
        #expect(snapshots[1].runState == .running) // after running
        #expect(snapshots[2].transcript.count == 1) // after upsert
        #expect(snapshots[3].runState == .idle) // after final idle
    }
}
