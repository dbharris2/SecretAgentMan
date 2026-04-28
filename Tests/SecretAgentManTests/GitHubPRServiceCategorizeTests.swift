import Foundation
@testable import SecretAgentMan
import Testing

/// Tests for the section-bucketing logic in `GitHubPRService.categorize`.
/// Mirrors the bucketing tests in pr-mm so the two apps stay in sync on which
/// PRs land in "Needs my review" vs. "Reviewed" vs. the authored sections.
struct GitHubPRServiceCategorizeTests {
    @Test
    func categorizesAllSectionsCorrectly() {
        let reviewRequested = makePR(id: "pr-1", number: 1)
        let approved = makePR(id: "pr-2", number: 2, reviewDecision: "APPROVED")
        let changes = makePR(id: "pr-3", number: 3, reviewDecision: "CHANGES_REQUESTED")
        let waiting = makePR(id: "pr-4", number: 4, reviewDecision: "REVIEW_REQUIRED")
        let reviewed = makePR(id: "pr-5", number: 5)

        let sections = GitHubPRService.categorize(
            reviewRequested: [reviewRequested],
            authored: [approved, changes, waiting],
            reviewedByMe: [reviewed]
        )

        #expect(sections[.needsMyReview]?.map(\.id) == ["pr-1"])
        #expect(sections[.approved]?.map(\.id) == ["pr-2"])
        #expect(sections[.returnedToMe]?.map(\.id) == ["pr-3"])
        #expect(sections[.waitingForReview]?.map(\.id) == ["pr-4"])
        #expect(sections[.reviewed]?.map(\.id) == ["pr-5"])
    }

    @Test
    func authoredDraftsRouteToDraftsSection() {
        let draft = makePR(id: "pr-draft", number: 10, isDraft: true)
        let nonDraft = makePR(id: "pr-nondraft", number: 11, reviewDecision: "REVIEW_REQUIRED")

        let sections = GitHubPRService.categorize(
            reviewRequested: [],
            authored: [draft, nonDraft],
            reviewedByMe: []
        )

        #expect(sections[.approved]?.isEmpty == true)
        #expect(sections[.returnedToMe]?.isEmpty == true)
        #expect(sections[.waitingForReview]?.map(\.id) == ["pr-nondraft"])
        #expect(sections[.drafts]?.map(\.id) == ["pr-draft"])
    }

    @Test
    func reviewedSectionDeduplicatesAcrossSources() {
        // A PR that's both review-requested AND in reviewed-by:@me only appears once.
        let shared = makePR(id: "pr-shared", number: 20, reviewDecision: "CHANGES_REQUESTED")

        let sections = GitHubPRService.categorize(
            reviewRequested: [shared],
            authored: [],
            reviewedByMe: [shared]
        )

        #expect(sections[.reviewed]?.map(\.id) == ["pr-shared"])
        #expect(sections[.needsMyReview]?.isEmpty == true)
    }

    @Test
    func reReviewRequestedStaysInNeedsMyReview() {
        // Re-request after a previous review: PR is in both queries but reviewDecision is
        // back to REVIEW_REQUIRED with no lingering APPROVED reviews — must stay actionable.
        let reRequested = makePR(id: "pr-rerequested", number: 40, reviewDecision: "REVIEW_REQUIRED")

        let sections = GitHubPRService.categorize(
            reviewRequested: [reRequested],
            authored: [],
            reviewedByMe: [reRequested]
        )

        #expect(sections[.needsMyReview]?.map(\.id) == ["pr-rerequested"])
        #expect(sections[.reviewed]?.isEmpty == true)
    }

    @Test
    func needsMyReviewExcludesPRsWithExistingApproval() {
        // Repo without branch protection: reviewDecision stays nil even after someone
        // approves. We rely on hasAnyApproval to avoid nagging the viewer in that case.
        let pr = makePR(id: "pr-already-approved", number: 207, reviewDecision: nil, hasAnyApproval: true)

        let sections = GitHubPRService.categorize(
            reviewRequested: [pr],
            authored: [],
            reviewedByMe: []
        )

        #expect(sections[.needsMyReview]?.isEmpty == true)
        #expect(sections[.reviewed]?.map(\.id) == ["pr-already-approved"])
    }

    @Test
    func reviewedSectionIncludesPRsIApproved() {
        // PRs I've already reviewed should remain visible in "Reviewed" so I can track them.
        let pr = makePR(id: "pr-i-approved", number: 50)

        let sections = GitHubPRService.categorize(
            reviewRequested: [],
            authored: [],
            reviewedByMe: [pr]
        )

        #expect(sections[.reviewed]?.map(\.id) == ["pr-i-approved"])
        #expect(sections[.needsMyReview]?.isEmpty == true)
    }

    @Test
    func needsMyReviewIncludesCommentOnlyPRs() {
        // A comment-level review doesn't change PR state, so the viewer still owes a review.
        // hasAnyApproval is false because the only existing review is COMMENTED, not APPROVED.
        let pr = makePR(id: "pr-only-commented", number: 208, reviewDecision: nil, hasAnyApproval: false)

        let sections = GitHubPRService.categorize(
            reviewRequested: [pr],
            authored: [],
            reviewedByMe: []
        )

        #expect(sections[.needsMyReview]?.map(\.id) == ["pr-only-commented"])
        #expect(sections[.reviewed]?.isEmpty == true)
    }

    @Test
    func needsMyReviewFiltersApprovedAndChangesRequested() {
        // Three review-requested PRs in different states: only the pending one stays
        // actionable; APPROVED and CHANGES_REQUESTED move to Reviewed.
        let approved = makePR(id: "pr-a", number: 30, reviewDecision: "APPROVED")
        let changes = makePR(id: "pr-b", number: 31, reviewDecision: "CHANGES_REQUESTED")
        let pending = makePR(id: "pr-c", number: 32, reviewDecision: nil)

        let sections = GitHubPRService.categorize(
            reviewRequested: [approved, changes, pending],
            authored: [],
            reviewedByMe: []
        )

        #expect(sections[.needsMyReview]?.map(\.id) == ["pr-c"])
        #expect(Set(sections[.reviewed]?.map(\.id) ?? []) == ["pr-a", "pr-b"])
    }

    private func makePR(
        id: String,
        number: Int,
        reviewDecision: String? = nil,
        isDraft: Bool = false,
        hasAnyApproval: Bool = false
    ) -> GitHubPRService.GitHubPR {
        GitHubPRService.GitHubPR(
            id: id,
            number: number,
            title: "PR \(number)",
            url: URL(string: "https://github.com/owner/repo/pull/\(number)")!,
            repository: "owner/repo",
            headRefName: "feature-\(number)",
            authorLogin: "alice",
            authorAvatarURL: nil,
            additions: 0,
            deletions: 0,
            changedFiles: 0,
            commentCount: 0,
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            mergeStateStatus: "CLEAN",
            updatedAt: Date(),
            reviewers: [],
            checkStatus: .none,
            hasAnyApproval: hasAnyApproval
        )
    }
}
