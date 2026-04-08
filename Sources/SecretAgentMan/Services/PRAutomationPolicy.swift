import Foundation

struct PRAutomationPolicy {
    struct Settings: Equatable {
        let autoFixCI: Bool
        let autoAnalyzeReviews: Bool
    }

    struct DeepDetails: Equatable {
        let reviewComments: [PRReviewComment]
        let failedChecks: [String]
        let detailedCheckStatus: PRCheckStatus
    }

    struct PromptRequest: Equatable {
        let source: PendingPrompt.PromptSource
        let summary: String
        let fullPrompt: String
        let sendDirectlyToAwaitingAgents: Bool
    }

    enum EventKind: Equatable {
        case changesRequested
        case checksFailed
        case approvedWithComments
    }

    struct InitialPlan: Equatable {
        let needsDeepFetch: Bool
        let removedPromptSources: [PendingPrompt.PromptSource]
    }

    struct DeepPlan: Equatable {
        let removedPromptSources: [PendingPrompt.PromptSource]
        let events: [EventKind]
        let prompts: [PromptRequest]
    }

    func initialPlan(old: PRInfo?, new: PRInfo, settings: Settings) -> InitialPlan {
        let hasFailedChecksTransition = new.checkStatus == .fail && old?.checkStatus != .fail
        let hasChangesRequestedTransition = new.state == .changesRequested && old?.state != .changesRequested
        let hasApprovedTransition = new.state == .approved && old?.state != .approved

        let needsDeepFetch = (settings.autoFixCI && hasFailedChecksTransition)
            || (settings.autoAnalyzeReviews && hasChangesRequestedTransition)
            || (settings.autoAnalyzeReviews && hasApprovedTransition)

        var removedPromptSources: [PendingPrompt.PromptSource] = []
        if new.checkStatus == .pass, old?.checkStatus == .fail {
            removedPromptSources.append(.ciFailed)
        }
        if new.state == .approved, old?.state == .changesRequested {
            removedPromptSources.append(.changesRequested)
        }

        return InitialPlan(
            needsDeepFetch: needsDeepFetch,
            removedPromptSources: removedPromptSources
        )
    }

    func mergedInfo(current: PRInfo, details: DeepDetails) -> PRInfo {
        PRInfo(
            number: current.number,
            url: current.url,
            state: current.state,
            checkStatus: details.detailedCheckStatus,
            additions: current.additions,
            deletions: current.deletions,
            changedFiles: current.changedFiles,
            commentCount: current.commentCount,
            reviewers: current.reviewers,
            reviewComments: details.reviewComments,
            failedChecks: details.failedChecks
        )
    }

    func deepPlan(old: PRInfo?, new: PRInfo, details: DeepDetails, settings: Settings) -> DeepPlan {
        let hasFailedChecksTransition = new.checkStatus == .fail && old?.checkStatus != .fail
        let hasChangesRequestedTransition = new.state == .changesRequested && old?.state != .changesRequested
        let hasApprovedTransition = new.state == .approved && old?.state != .approved

        var removedPromptSources: [PendingPrompt.PromptSource] = []
        var events: [EventKind] = []
        var prompts: [PromptRequest] = []

        if settings.autoFixCI, hasFailedChecksTransition {
            let checkNames = details.failedChecks.joined(separator: ", ")
            events.append(.checksFailed)
            prompts.append(PromptRequest(
                source: .ciFailed,
                summary: "Failed: \(checkNames)",
                fullPrompt: """
                CI checks failed on PR #\(new.number). Failed checks: \(checkNames)

                Please investigate and fix the failures.
                """,
                sendDirectlyToAwaitingAgents: true
            ))
        }

        if settings.autoAnalyzeReviews, hasChangesRequestedTransition {
            let comments = details.reviewComments
                .filter { $0.state == .changesRequested }
                .map { "**\($0.author):** \($0.body)" }
                .joined(separator: "\n\n")
            events.append(.changesRequested)
            prompts.append(PromptRequest(
                source: .changesRequested,
                summary: "\(details.reviewComments.count) review comment(s)",
                fullPrompt: """
                PR #\(new.number) received review feedback requesting changes:

                \(comments)

                Summarize the feedback and suggest how you would address each point.
                Do NOT make any changes — just analyze and explain your approach.
                """,
                sendDirectlyToAwaitingAgents: false
            ))
        }

        if new.state == .approved, old?.state == .changesRequested {
            removedPromptSources.append(.changesRequested)
        }

        if settings.autoAnalyzeReviews, hasApprovedTransition {
            let approvalComments = details.reviewComments
                .filter { $0.state == .approved && !$0.body.isEmpty }
            let oldCommentCount = old?.reviewComments.count(where: { $0.state == .approved }) ?? 0
            if approvalComments.count > oldCommentCount {
                let comments = approvalComments
                    .map { "**\($0.author):** \($0.body)" }
                    .joined(separator: "\n\n")
                events.append(.approvedWithComments)
                prompts.append(PromptRequest(
                    source: .approvedWithComments,
                    summary: "\(approvalComments.count) comment(s) on approval",
                    fullPrompt: """
                    PR #\(new.number) was approved with comments:

                    \(comments)

                    Summarize the comments. If any suggest changes, explain how you would address them.
                    Do NOT make any changes — just analyze.
                    """,
                    sendDirectlyToAwaitingAgents: false
                ))
            }
        }

        return DeepPlan(
            removedPromptSources: removedPromptSources,
            events: events,
            prompts: prompts
        )
    }
}
