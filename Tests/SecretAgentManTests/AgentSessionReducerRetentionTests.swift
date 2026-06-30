import Foundation
@testable import SecretAgentMan
import Testing

struct AgentSessionReducerRetentionTests {
    @Test func transcriptDeltaCapsVisibleText() {
        var snap = AgentSessionSnapshot()
        snap = AgentSessionReducer.reduce(
            snap,
            event: .transcriptUpsert(SessionTranscriptItem(
                id: "a1",
                kind: .assistantMessage,
                text: String(repeating: "x", count: SessionRetentionPolicy.maxVisibleTranscriptCharacters - 1),
                isStreaming: true
            ))
        )

        snap = AgentSessionReducer.reduce(snap, event: .transcriptDelta(id: "a1", appendedText: "abcdef"))

        #expect(snap.transcript.first?.text.hasSuffix(SessionRetentionPolicy.visibleTranscriptTruncationSuffix) == true)
    }

    @Test func transcriptRetainsOnlyRecentItems() {
        var snap = AgentSessionSnapshot()
        for index in 0 ..< (SessionRetentionPolicy.maxRetainedTranscriptItems + 2) {
            snap = AgentSessionReducer.reduce(
                snap,
                event: .transcriptUpsert(SessionTranscriptItem(
                    id: "m\(index)",
                    kind: .systemMessage,
                    text: "\(index)"
                ))
            )
        }

        #expect(snap.transcript.count == SessionRetentionPolicy.maxRetainedTranscriptItems)
        #expect(snap.transcript.first?.id == "m2")
    }

    @Test func largeHydratedTranscriptRetainsBoundedRecentText() {
        let oversizedText = String(repeating: "x", count: SessionRetentionPolicy.maxVisibleTranscriptCharacters + 1000)
        let overflowCount = 25
        var snap = AgentSessionSnapshot()

        for index in 0 ..< (SessionRetentionPolicy.maxRetainedTranscriptItems + overflowCount) {
            snap = AgentSessionReducer.reduce(
                snap,
                event: .transcriptUpsert(SessionTranscriptItem(
                    id: "m\(index)",
                    kind: .assistantMessage,
                    text: oversizedText
                ))
            )
        }

        let maxItemCharacters = SessionRetentionPolicy.maxVisibleTranscriptCharacters
            + SessionRetentionPolicy.visibleTranscriptTruncationSuffix.count
        let maxSnapshotCharacters = SessionRetentionPolicy.maxRetainedTranscriptItems * maxItemCharacters

        #expect(snap.transcript.count == SessionRetentionPolicy.maxRetainedTranscriptItems)
        #expect(snap.transcript.first?.id == "m\(overflowCount)")
        #expect(snap.transcript.allSatisfy { $0.text.count <= maxItemCharacters })
        #expect(snap.transcript.reduce(0) { $0 + $1.text.count } <= maxSnapshotCharacters)
    }

    @MainActor
    @Test func codexStreamingPipelineRetainsBoundedSnapshotText() {
        let monitor = CodexAppServerMonitor()
        let agentId = UUID()
        let delta = String(repeating: "x", count: 4096)
        var snap = AgentSessionSnapshot()

        monitor.onSessionEvent = { _, event in
            snap = AgentSessionReducer.reduce(snap, event: event)
        }

        for _ in 0 ..< 200 {
            monitor.emitStreamDelta(id: agentId, itemId: "stream-1", delta: delta)
        }

        let retainedText = snap.streamingAssistantText ?? ""
        #expect(snap.transcript.count == 1)
        #expect(retainedText.count == SessionRetentionPolicy.maxVisibleTranscriptCharacters
            + SessionRetentionPolicy.visibleTranscriptTruncationSuffix.count)
        #expect(retainedText.hasSuffix(SessionRetentionPolicy.visibleTranscriptTruncationSuffix))
        #expect(monitor.streamingItemIds[agentId] == ["stream-1"])
    }
}
