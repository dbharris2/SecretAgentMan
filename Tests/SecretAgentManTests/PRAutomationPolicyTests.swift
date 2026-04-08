import Foundation
@testable import SecretAgentMan
import Testing

struct PRAutomationPolicyTests {
    private let policy = PRAutomationPolicy()
    private let settings = PRAutomationPolicy.Settings(autoFixCI: true, autoAnalyzeReviews: true)

    @Test
    func initialPlanRequestsDeepFetchForNewFailures() {
        let old = makeInfo(state: .needsReview, checkStatus: .pending)
        let new = makeInfo(state: .needsReview, checkStatus: .fail)

        let plan = policy.initialPlan(old: old, new: new, settings: settings)

        #expect(plan.needsDeepFetch)
        #expect(plan.removedPromptSources.isEmpty)
    }

    @Test
    func initialPlanRemovesResolvedFailureAndObsoleteReviewPrompts() {
        let old = makeInfo(state: .changesRequested, checkStatus: .fail)
        let new = makeInfo(state: .approved, checkStatus: .pass)

        let plan = policy.initialPlan(old: old, new: new, settings: settings)

        #expect(plan.needsDeepFetch)
        #expect(plan.removedPromptSources == [.ciFailed, .changesRequested])
    }

    @Test
    func deepPlanBuildsFailurePromptAndEvent() throws {
        let old = makeInfo(state: .needsReview, checkStatus: .pending)
        let new = makeInfo(state: .needsReview, checkStatus: .fail)
        let details = PRAutomationPolicy.DeepDetails(
            reviewComments: [],
            failedChecks: ["ci / unit", "ci / lint"],
            detailedCheckStatus: .fail
        )

        let plan = policy.deepPlan(old: old, new: new, details: details, settings: settings)

        #expect(plan.events == [.checksFailed])
        let prompt = try #require(plan.prompts.first)
        #expect(prompt.source == .ciFailed)
        #expect(prompt.sendDirectlyToAwaitingAgents)
        #expect(prompt.summary == "Failed: ci / unit, ci / lint")
        #expect(prompt.fullPrompt.contains("Please investigate and fix the failures."))
    }

    @Test
    func deepPlanBuildsReviewFeedbackPrompt() throws {
        let old = makeInfo(state: .needsReview, checkStatus: .pass)
        let new = makeInfo(state: .changesRequested, checkStatus: .pass)
        let details = PRAutomationPolicy.DeepDetails(
            reviewComments: [
                PRReviewComment(author: "alice", body: "Please add tests.", state: .changesRequested),
                PRReviewComment(author: "bob", body: "Consider renaming this.", state: .commented),
            ],
            failedChecks: [],
            detailedCheckStatus: .pass
        )

        let plan = policy.deepPlan(old: old, new: new, details: details, settings: settings)

        #expect(plan.events == [.changesRequested])
        let prompt = try #require(plan.prompts.first)
        #expect(prompt.source == .changesRequested)
        #expect(prompt.summary == "2 review comment(s)")
        #expect(prompt.fullPrompt.contains("Please add tests."))
    }

    @Test
    func deepPlanBuildsApprovalPromptOnlyForNewApprovalComments() throws {
        let old = makeInfo(
            state: .changesRequested,
            checkStatus: .pass,
            reviewComments: [PRReviewComment(author: "alice", body: "Ship it", state: .approved)]
        )
        let new = makeInfo(state: .approved, checkStatus: .pass)
        let details = PRAutomationPolicy.DeepDetails(
            reviewComments: [
                PRReviewComment(author: "alice", body: "Ship it", state: .approved),
                PRReviewComment(author: "bob", body: "Looks good with one note.", state: .approved),
            ],
            failedChecks: [],
            detailedCheckStatus: .pass
        )

        let plan = policy.deepPlan(old: old, new: new, details: details, settings: settings)

        #expect(plan.removedPromptSources == [.changesRequested])
        #expect(plan.events == [.approvedWithComments])
        let prompt = try #require(plan.prompts.first)
        #expect(prompt.source == .approvedWithComments)
        #expect(prompt.summary == "2 comment(s) on approval")
        #expect(prompt.fullPrompt.contains("Looks good with one note."))
    }

    private func makeInfo(
        state: PRState,
        checkStatus: PRCheckStatus,
        reviewComments: [PRReviewComment] = []
    ) -> PRInfo {
        PRInfo(
            number: 42,
            url: URL(string: "https://github.com/acme/project/pull/42")!,
            state: state,
            checkStatus: checkStatus,
            additions: 10,
            deletions: 3,
            changedFiles: 2,
            commentCount: 1,
            reviewers: [],
            reviewComments: reviewComments,
            failedChecks: []
        )
    }
}
