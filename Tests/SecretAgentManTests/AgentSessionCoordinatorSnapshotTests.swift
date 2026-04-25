import Foundation
@testable import SecretAgentMan
import Testing

/// Tests that `AgentSessionCoordinator` reduces normalized `SessionEvent`
/// streams from both monitors into per-agent `AgentSessionSnapshot`s.
@MainActor
struct AgentSessionCoordinatorSnapshotTests {
    @Test func claudeSessionEventsBuildSnapshot() {
        let coordinator = AgentSessionCoordinator()
        coordinator.start()

        let agentId = UUID()
        let claudeEmit = try? #require(coordinator.claudeMonitor.onSessionEvent)
        claudeEmit?(agentId, .sessionReady(sessionId: "sess-1"))
        claudeEmit?(agentId, .runStateChanged(.running))
        claudeEmit?(
            agentId,
            .transcriptUpsert(SessionTranscriptItem(id: "u1", kind: .userMessage, text: "hello"))
        )

        let snap = coordinator.snapshots[agentId]
        #expect(snap?.metadata.sessionId == "sess-1")
        #expect(snap?.runState == .running)
        #expect(snap?.transcript.count == 1)
        #expect(snap?.transcript.first?.text == "hello")
    }

    @Test func codexSessionEventsBuildSnapshot() {
        let coordinator = AgentSessionCoordinator()
        coordinator.start()

        let agentId = UUID()
        let codexEmit = try? #require(coordinator.codexMonitor.onSessionEvent)
        codexEmit?(agentId, .sessionReady(sessionId: "thread-1"))
        codexEmit?(agentId, .runStateChanged(.needsPermission))
        codexEmit?(
            agentId,
            .promptPresented(.approval(ApprovalPrompt(
                id: "a1",
                title: "Approval",
                message: "OK?",
                actions: [
                    ApprovalAction(id: "allow", label: "Allow"),
                    ApprovalAction(id: "deny", label: "Deny", isDestructive: true),
                ]
            )))
        )

        let snap = coordinator.snapshots[agentId]
        #expect(snap?.metadata.sessionId == "thread-1")
        #expect(snap?.runState == .needsPermission)
        #expect(snap?.activePrompt?.id == "a1")
    }

    @Test func eventsForDifferentAgentsProduceSeparateSnapshots() {
        let coordinator = AgentSessionCoordinator()
        coordinator.start()

        let a = UUID()
        let b = UUID()
        let emit = try? #require(coordinator.claudeMonitor.onSessionEvent)

        emit?(a, .runStateChanged(.running))
        emit?(b, .runStateChanged(.needsInput))
        emit?(a, .transcriptUpsert(SessionTranscriptItem(id: "x", kind: .userMessage, text: "A")))

        #expect(coordinator.snapshots[a]?.runState == .running)
        #expect(coordinator.snapshots[b]?.runState == .needsInput)
        #expect(coordinator.snapshots[a]?.transcript.count == 1)
        #expect(coordinator.snapshots[b]?.transcript.isEmpty == true)
    }

    @Test func removeAgentClearsSnapshot() {
        let coordinator = AgentSessionCoordinator()
        coordinator.start()

        let agentId = UUID()
        let emit = try? #require(coordinator.claudeMonitor.onSessionEvent)
        emit?(agentId, .runStateChanged(.running))
        #expect(coordinator.snapshots[agentId] != nil)

        coordinator.removeAgent(agentId)
        #expect(coordinator.snapshots[agentId] == nil)
    }

    @Test func streamingDeltasAccumulateInSnapshot() {
        let coordinator = AgentSessionCoordinator()
        coordinator.start()

        let agentId = UUID()
        let emit = try? #require(coordinator.codexMonitor.onSessionEvent)

        emit?(
            agentId,
            .transcriptUpsert(SessionTranscriptItem(
                id: "msg-1",
                kind: .assistantMessage,
                text: "Hel",
                isStreaming: true
            ))
        )
        emit?(agentId, .transcriptDelta(id: "msg-1", appendedText: "lo"))
        emit?(agentId, .transcriptFinished(id: "msg-1"))

        let snap = coordinator.snapshots[agentId]
        #expect(snap?.transcript.count == 1)
        #expect(snap?.transcript.first?.text == "Hello")
        #expect(snap?.transcript.first?.isStreaming == false)
    }

    @Test func claudeAndCodexEventsForSameAgentShareSnapshot() {
        // Agents have a single provider in practice, but the coordinator
        // routes events by agent id, not provider. This locks in that it
        // treats both monitors' emissions as equivalent.
        let coordinator = AgentSessionCoordinator()
        coordinator.start()

        let agentId = UUID()
        let claudeEmit = try? #require(coordinator.claudeMonitor.onSessionEvent)
        let codexEmit = try? #require(coordinator.codexMonitor.onSessionEvent)

        claudeEmit?(agentId, .runStateChanged(.running))
        codexEmit?(
            agentId,
            .transcriptUpsert(SessionTranscriptItem(id: "t1", kind: .systemMessage, text: "hi"))
        )

        let snap = coordinator.snapshots[agentId]
        #expect(snap?.runState == .running)
        #expect(snap?.transcript.count == 1)
    }
}
