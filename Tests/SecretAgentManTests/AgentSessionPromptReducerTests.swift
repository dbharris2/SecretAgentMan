import Foundation
@testable import SecretAgentMan
import Testing

struct AgentSessionPromptReducerTests {
    @Test func duplicateActivePromptUpdatesInPlace() {
        var snap = AgentSessionSnapshot()
        let first = approvalPrompt(id: "a1", title: "old")
        let updated = approvalPrompt(id: "a1", title: "new")

        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(first))
        snap = AgentSessionReducer.reduce(snap, event: .promptPresented(updated))

        #expect(snap.activePrompt == updated)
        #expect(snap.queuedPrompts.isEmpty)
    }

    @Test func resolvingActivePromptSkipsQueuedDuplicates() {
        var snap = AgentSessionSnapshot()
        let duplicate = approvalPrompt(id: "a1")
        let next = approvalPrompt(id: "a2")
        snap.activePrompt = duplicate
        snap.queuedPrompts = [duplicate, next]

        snap = AgentSessionReducer.reduce(snap, event: .promptResolved(id: "a1"))

        #expect(snap.activePrompt == next)
        #expect(snap.queuedPrompts.isEmpty)
    }

    private func approvalPrompt(id: String, title: String = "t") -> SessionPromptRequest {
        .approval(
            ApprovalPrompt(
                id: id,
                title: title,
                message: "m",
                actions: [ApprovalAction(id: "ok", label: "OK")]
            )
        )
    }
}
