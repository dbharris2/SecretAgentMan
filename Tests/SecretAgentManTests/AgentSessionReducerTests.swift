import Foundation
@testable import SecretAgentMan
import Testing

struct AgentSessionReducerTests {
    // MARK: - Run state

    @Test func runStateChangeUpdatesSnapshot() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(snap, event: .runStateChanged(.running))
        #expect(snap.runState == .running)

        snap = AgentSessionReducer.reduce(snap, event: .runStateChanged(.needsPermission))
        #expect(snap.runState == .needsPermission)

        snap = AgentSessionReducer.reduce(snap, event: .runStateChanged(.error(message: "boom")))
        #expect(snap.runState == .error(message: "boom"))
    }

    @Test func errorStateDoesNotClearTranscriptOrPrompts() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(id: "m1", kind: .userMessage, text: "hi"))
        )
        snap = AgentSessionReducer.reduce(
            snap,
            event: .promptPresented(.approval(ApprovalPrompt(id: "a1", title: "t", message: "m", options: ["ok"])))
        )

        snap = AgentSessionReducer.reduce(snap, event: .runStateChanged(.error(message: "x")))

        #expect(snap.runState == .error(message: "x"))
        #expect(snap.transcript.count == 1)
        #expect(snap.activePrompt?.id == "a1")
    }

    @Test func errorStateIsReplacedByLaterRunStateEvent() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(snap, event: .runStateChanged(.error(message: "x")))
        snap = AgentSessionReducer.reduce(snap, event: .runStateChanged(.running))
        #expect(snap.runState == .running)
    }

    // MARK: - Transcript

    @Test func transcriptUpsertAppendsNewItem() {
        var snap = AgentSessionSnapshot()
        let item = SessionTranscriptItem(id: "u1", kind: .userMessage, text: "hello")

        snap = AgentSessionReducer.reduce(snap, event: .transcriptUpsert(item))

        #expect(snap.transcript == [item])
    }

    @Test func transcriptUpsertUpdatesExistingItemByID() {
        var snap = AgentSessionSnapshot()
        let first = SessionTranscriptItem(id: "u1", kind: .assistantMessage, text: "hel")
        let second = SessionTranscriptItem(id: "u1", kind: .assistantMessage, text: "hello")

        snap = AgentSessionReducer.reduce(snap, event: .transcriptUpsert(first))
        snap = AgentSessionReducer.reduce(snap, event: .transcriptUpsert(second))

        #expect(snap.transcript.count == 1)
        #expect(snap.transcript[0].text == "hello")
    }

    @Test func transcriptDeltaAppendsToStreamingItem() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "a1",
                kind: .assistantMessage,
                text: "Hel",
                isStreaming: true
            ))
        )

        snap = AgentSessionReducer.reduce(snap, event: .transcriptDelta(id: "a1", appendedText: "lo"))
        snap = AgentSessionReducer.reduce(snap, event: .transcriptDelta(id: "a1", appendedText: " world"))

        #expect(snap.transcript.first?.text == "Hello world")
        #expect(snap.transcript.first?.isStreaming == true)
    }

    @Test func transcriptFinishedFlipsStreamingFalse() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "a1",
                kind: .assistantMessage,
                text: "Hi",
                isStreaming: true
            ))
        )

        snap = AgentSessionReducer.reduce(snap, event: .transcriptFinished(id: "a1"))

        #expect(snap.transcript.first?.isStreaming == false)
        #expect(snap.transcript.first?.text == "Hi")
    }

    @Test func transcriptFinishedForUnknownIDIsNoOp() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(id: "a1", kind: .assistantMessage, text: "Hi"))
        )

        snap = AgentSessionReducer.reduce(snap, event: .transcriptFinished(id: "other"))

        #expect(snap.transcript.count == 1)
        #expect(snap.transcript.first?.isStreaming == false)
    }

    @Test func upsertDoesNotEndStreamingOnExistingStreamingItem() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "a1",
                kind: .assistantMessage,
                text: "Hi",
                isStreaming: true
            ))
        )

        // Incoming upsert has isStreaming: false; existing was streaming.
        // Reducer must preserve streaming until transcriptFinished.
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "a1",
                kind: .assistantMessage,
                text: "Hi updated",
                isStreaming: false
            ))
        )

        #expect(snap.transcript.first?.isStreaming == true)
        #expect(snap.transcript.first?.text == "Hi updated")
    }

    @Test func upsertPreservesEarliestCreatedAt() {
        var snap = AgentSessionSnapshot()
        let early = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)

        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "u1", kind: .userMessage, text: "a", createdAt: later
            ))
        )
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "u1", kind: .userMessage, text: "a", createdAt: early
            ))
        )

        #expect(snap.transcript.first?.createdAt == early)
    }

    @Test func upsertWithNilCreatedAtDoesNotEraseExisting() {
        var snap = AgentSessionSnapshot()
        let stamp = Date(timeIntervalSince1970: 1000)

        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "u1", kind: .userMessage, text: "a", createdAt: stamp
            ))
        )
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "u1", kind: .userMessage, text: "a", createdAt: nil
            ))
        )

        #expect(snap.transcript.first?.createdAt == stamp)
    }

    // MARK: - Prompts

    @Test func firstPromptBecomesActive() {
        var snap = AgentSessionSnapshot()
        let prompt: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a1", title: "t", message: "m", options: ["ok"])
        )

        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(prompt))

        #expect(snap.activePrompt == prompt)
        #expect(snap.queuedPrompts.isEmpty)
    }

    @Test func secondPromptIsQueued() {
        var snap = AgentSessionSnapshot()
        let first: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a1", title: "t", message: "m", options: ["ok"])
        )
        let second: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a2", title: "t", message: "m", options: ["ok"])
        )

        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(first))
        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(second))

        #expect(snap.activePrompt == first)
        #expect(snap.queuedPrompts == [second])
    }

    @Test func resolvingActivePromotesQueued() {
        var snap = AgentSessionSnapshot()
        let first: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a1", title: "t", message: "m", options: ["ok"])
        )
        let second: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a2", title: "t", message: "m", options: ["ok"])
        )

        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(first))
        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(second))
        snap = AgentSessionReducer.reduce(snap, event: .promptResolved(id: "a1"))

        #expect(snap.activePrompt == second)
        #expect(snap.queuedPrompts.isEmpty)
    }

    @Test func resolvingActiveWithEmptyQueueClearsActive() {
        var snap = AgentSessionSnapshot()
        let prompt: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a1", title: "t", message: "m", options: ["ok"])
        )

        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(prompt))
        snap = AgentSessionReducer.reduce(snap, event: .promptResolved(id: "a1"))

        #expect(snap.activePrompt == nil)
    }

    @Test func resolvingQueuedPromptRemovesInPlace() {
        var snap = AgentSessionSnapshot()
        let active: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a1", title: "t", message: "m", options: ["ok"])
        )
        let queued: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a2", title: "t", message: "m", options: ["ok"])
        )

        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(active))
        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(queued))
        snap = AgentSessionReducer.reduce(snap, event: .promptResolved(id: "a2"))

        #expect(snap.activePrompt == active)
        #expect(snap.queuedPrompts.isEmpty)
    }

    @Test func resolvingUnknownPromptIsNoOp() {
        var snap = AgentSessionSnapshot()
        let active: SessionPromptRequest = .approval(
            ApprovalPrompt(id: "a1", title: "t", message: "m", options: ["ok"])
        )

        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(active))
        snap = AgentSessionReducer.reduce(snap, event: .promptResolved(id: "unknown"))

        #expect(snap.activePrompt == active)
    }

    // MARK: - Metadata

    @Test func metadataSetAndClear() {
        var snap = AgentSessionSnapshot()

        var update = SessionMetadataUpdate()
        update.displayModelName = .set("Claude Sonnet 4.6")
        update.contextPercentUsed = .set(42.5)
        snap = AgentSessionReducer.reduce(snap, event: .metadataUpdated(update))

        #expect(snap.metadata.displayModelName == "Claude Sonnet 4.6")
        #expect(snap.metadata.contextPercentUsed == 42.5)

        var clearUpdate = SessionMetadataUpdate()
        clearUpdate.displayModelName = .clear
        snap = AgentSessionReducer.reduce(snap, event: .metadataUpdated(clearUpdate))

        #expect(snap.metadata.displayModelName == nil)
        // Absent fields stayed untouched.
        #expect(snap.metadata.contextPercentUsed == 42.5)
    }

    @Test func metadataUnchangedPreservesExisting() {
        var snap = AgentSessionSnapshot()

        var firstUpdate = SessionMetadataUpdate()
        firstUpdate.permissionMode = .set("acceptEdits")
        firstUpdate.activeToolName = .set("Grep")
        snap = AgentSessionReducer.reduce(snap, event: .metadataUpdated(firstUpdate))

        // All fields default to .unchanged — should be a no-op.
        snap = AgentSessionReducer.reduce(snap, event: .metadataUpdated(SessionMetadataUpdate()))

        #expect(snap.metadata.permissionMode == "acceptEdits")
        #expect(snap.metadata.activeToolName == "Grep")
    }

    // MARK: - Session ready / replacement

    @Test func sessionReadySetsSessionId() {
        var snap = AgentSessionSnapshot()

        snap = AgentSessionReducer.reduce(snap, event: .sessionReady(sessionId: "sess-1"))

        #expect(snap.metadata.sessionId == "sess-1")
    }

    @Test func firstSessionReadyDoesNotClearPrecedingState() {
        // Realistic flow: the user sends a message before the provider
        // has finished initializing and emitted its `sessionReady`. The
        // initial `sessionReady` must not wipe the transcript/prompt
        // state that was already accumulated.
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(id: "m1", kind: .userMessage, text: "hi"))
        )
        snap = AgentSessionReducer.reduce(snap, event: .runStateChanged(.running))

        snap = AgentSessionReducer.reduce(snap, event: .sessionReady(sessionId: "sess-1"))

        #expect(snap.metadata.sessionId == "sess-1")
        #expect(snap.transcript.count == 1)
        #expect(snap.runState == .running)
    }

    @Test func sessionReadyWithSameIdIsNoOp() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(snap, event: .sessionReady(sessionId: "sess-1"))
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(id: "m1", kind: .userMessage, text: "x"))
        )

        snap = AgentSessionReducer.reduce(snap, event: .sessionReady(sessionId: "sess-1"))

        #expect(snap.transcript.count == 1)
    }

    @Test func sessionReadyWithNewIdClearsSessionScopedState() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(snap, event: .sessionReady(sessionId: "sess-1"))
        snap = AgentSessionReducer.reduce(snap, event: .runStateChanged(.running))
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(id: "m1", kind: .userMessage, text: "x"))
        )
        snap = AgentSessionReducer.reduce(
            snap,
            event: .promptPresented(.approval(
                ApprovalPrompt(id: "a1", title: "t", message: "m", options: ["ok"])
            ))
        )
        var meta = SessionMetadataUpdate()
        meta.displayModelName = .set("Model")
        meta.permissionMode = .set("acceptEdits")
        meta.activeToolName = .set("Grep")
        snap = AgentSessionReducer.reduce(snap, event: .metadataUpdated(meta))

        snap = AgentSessionReducer.reduce(snap, event: .sessionReady(sessionId: "sess-2"))

        #expect(snap.metadata.sessionId == "sess-2")
        #expect(snap.runState == .idle)
        #expect(snap.transcript.isEmpty)
        #expect(snap.activePrompt == nil)
        // Session-scoped fields cleared.
        #expect(snap.metadata.activeToolName == nil)
        // Agent-level metadata preserved so views don't flicker between the
        // sessionReady and the first post-restart metadataUpdated.
        #expect(snap.metadata.displayModelName == "Model")
        #expect(snap.metadata.permissionMode == "acceptEdits")
    }

    // MARK: - Provider-parity reducer tests

    @Test func sameEventSequenceProducesSameSnapshotRegardlessOfProvider() {
        // This test exists to document the core invariant: the reducer does
        // not know or care which provider produced the events. If this test
        // ever requires provider-aware branching to pass, that's a bug.
        let events: [SessionEvent] = [
            .sessionReady(sessionId: "s1"),
            .runStateChanged(.running),
            .transcriptUpsert(SessionTranscriptItem(
                id: "a1", kind: .assistantMessage, text: "", isStreaming: true
            )),
            .transcriptDelta(id: "a1", appendedText: "Hello"),
            .transcriptDelta(id: "a1", appendedText: " world"),
            .transcriptFinished(id: "a1"),
            .runStateChanged(.finished),
        ]

        let finalSnap = events.reduce(AgentSessionSnapshot()) { snap, event in
            AgentSessionReducer.reduce(snap, event: event)
        }

        #expect(finalSnap.runState == .finished)
        #expect(finalSnap.transcript.count == 1)
        #expect(finalSnap.transcript[0].text == "Hello world")
        #expect(finalSnap.transcript[0].isStreaming == false)
        #expect(finalSnap.metadata.sessionId == "s1")
    }
}
