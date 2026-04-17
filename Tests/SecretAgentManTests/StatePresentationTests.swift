@testable import SecretAgentMan
import Testing

struct StatePresentationTests {
    @Test func agentStatePresentationMapsExpectedLabelIconAndTone() {
        #expect(AgentState.idle.presentation == AgentStatePresentation(
            label: "Idle",
            systemImage: "circle",
            tone: .neutral
        ))
        #expect(AgentState.active.presentation == AgentStatePresentation(
            label: "Working",
            systemImage: "bolt.fill",
            tone: .info
        ))
        #expect(AgentState.needsPermission.presentation == AgentStatePresentation(
            label: "Needs Approval",
            systemImage: "hand.raised.fill",
            tone: .orange
        ))
        #expect(AgentState.awaitingInput.presentation == AgentStatePresentation(
            label: "Ready",
            systemImage: "circle.fill",
            tone: .success
        ))
        #expect(AgentState.awaitingResponse.presentation == AgentStatePresentation(
            label: "Needs Input",
            systemImage: "questionmark.bubble.fill",
            tone: .warning
        ))
        #expect(AgentState.finished.presentation == AgentStatePresentation(
            label: "Done",
            systemImage: "checkmark.circle",
            tone: .neutral
        ))
        #expect(AgentState.error.presentation == AgentStatePresentation(
            label: "Error",
            systemImage: "xmark.octagon.fill",
            tone: .danger
        ))
    }

    @Test func prStatusPresentationMapsExpectedTonesAndLabels() {
        #expect(PRState.draft.tone == .neutral)
        #expect(PRState.changesRequested.tone == .danger)
        #expect(PRState.needsReview.tone == .warning)
        #expect(PRState.approved.tone == .success)
        #expect(PRState.inMergeQueue.tone == .queued)
        #expect(PRState.merged.tone == .merged)

        #expect(PRCheckStatus.pass.presentation == PRCheckStatusPresentation(
            label: "Checks passed",
            tone: .success
        ))
        #expect(PRCheckStatus.fail.presentation == PRCheckStatusPresentation(
            label: "Checks failed",
            tone: .danger
        ))
        #expect(PRCheckStatus.pending.presentation == PRCheckStatusPresentation(
            label: "Checks running",
            tone: .warning
        ))
        #expect(PRCheckStatus.none.presentation == PRCheckStatusPresentation(
            label: "No checks",
            tone: .neutral
        ))
    }
}
