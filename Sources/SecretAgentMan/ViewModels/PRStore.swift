import Foundation
import SwiftUI

@MainActor
@Observable
final class PRStore {
    let githubPRService: GitHubPRService

    var prInfos: [String: PRInfo] = [:]
    var githubPRSections: [GitHubPRService.PRSection: [GitHubPRService.GitHubPR]] = [:]
    var isLoadingPRs = true
    var githubRateLimit: GitHubPRService.RateLimit?
    var lastPRPollTime: Date?
    var selectedGitHubPR: GitHubPRService.GitHubPR?
    var selectedPRDiff: String = ""
    var selectedPRChanges: [FileChange] = []

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private let terminalManager: TerminalManager
    @ObservationIgnored private let eventBus: AgentEventBus
    @ObservationIgnored private let repositoryMonitor: RepositoryMonitor
    @ObservationIgnored private var repoNames: [String: String] = [:]
    @ObservationIgnored private var prTimer: Timer?
    @ObservationIgnored private var prPollCount = 0

    init(
        store: AgentStore,
        terminalManager: TerminalManager,
        eventBus: AgentEventBus,
        repositoryMonitor: RepositoryMonitor,
        githubPRService: GitHubPRService = GitHubPRService()
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.eventBus = eventBus
        self.repositoryMonitor = repositoryMonitor
        self.githubPRService = githubPRService
    }

    func start() {
        refresh()
        prTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        prTimer?.invalidate()
    }

    func refresh() {
        Task {
            let folders = Set(store.agents.map(\.folder))

            for folder in folders {
                let key = Self.folderKey(folder)
                if repoNames[key] == nil {
                    repoNames[key] = await repositoryMonitor.diffService.fetchRepoName(in: folder)
                }
            }

            let prSections = await githubPRService.fetchAllPRs()
            githubPRSections = prSections
            lastPRPollTime = Date()
            isLoadingPRs = false

            prPollCount += 1
            if prPollCount % 5 == 1 {
                githubRateLimit = await githubPRService.fetchRateLimit()
            }

            let currentInfos = matchPRsToFolders(prSections: prSections, folders: folders)
            applyMatchedPRInfos(currentInfos)
        }
    }

    func selectPR(_ pr: GitHubPRService.GitHubPR?) {
        selectedGitHubPR = pr
        selectedPRDiff = ""
        selectedPRChanges = []
        guard let pr else { return }
        Task {
            let diff = await githubPRService.fetchPRDiff(repo: pr.repository, number: pr.number)
            let changes = repositoryMonitor.diffService.parseChanges(from: diff)
            if selectedGitHubPR?.id == pr.id {
                selectedPRDiff = diff
                selectedPRChanges = changes
            }
        }
    }

    func addReviewers(_ pr: GitHubPRService.GitHubPR, group: ReviewerGroup) {
        performPRAction {
            await self.githubPRService.addReviewers(
                repo: pr.repository,
                number: pr.number,
                reviewers: group.reviewers
            )
        }
    }

    func closePR(_ pr: GitHubPRService.GitHubPR) {
        performPRAction { await self.githubPRService.closePR(repo: pr.repository, number: pr.number) }
    }

    func markPRReady(_ pr: GitHubPRService.GitHubPR) {
        performPRAction { await self.githubPRService.markPRReady(repo: pr.repository, number: pr.number) }
    }

    func convertPRToDraft(_ pr: GitHubPRService.GitHubPR) {
        performPRAction { await self.githubPRService.convertToDraft(repo: pr.repository, number: pr.number) }
    }

    func reviewPR(_ pr: GitHubPRService.GitHubPR) {
        let repoName = pr.repository.components(separatedBy: "/").last ?? ""
        let matchingAgent = store.agents.first { $0.folderPath.contains(repoName) }

        guard let folder = matchingAgent?.folder else { return }

        let previousSelection = store.selectedAgentId
        let reviewAgent = store.addAgent(
            name: "PR #\(pr.number) - Review",
            folder: folder,
            provider: .claude
        )
        store.selectedAgentId = previousSelection

        let prompt = """
        Review PR #\(pr.number) at \(pr.url.absoluteString)

        Run `gh pr diff \(pr.number) --repo \(pr.repository)` to see the full diff.
        Run `gh pr view \(pr.number) --repo \(pr.repository)` for the PR description.

        Provide a thorough code review covering:
        - Correctness and potential bugs
        - Edge cases
        - Code style and readability
        - Performance concerns
        - Any suggestions for improvement

        Do NOT post comments to GitHub. Just provide your analysis here.
        """

        store.addPendingPrompt(PendingPrompt(
            agentId: reviewAgent.id,
            source: .reviewPR,
            summary: "Diff review: \(pr.repository) #\(pr.number)",
            fullPrompt: prompt
        ))
    }

    private struct MatchedPR {
        let folder: URL
        let pr: GitHubPRService.GitHubPR
        let info: PRInfo
    }

    private func matchPRsToFolders(
        prSections: [GitHubPRService.PRSection: [GitHubPRService.GitHubPR]],
        folders: Set<URL>
    ) -> [String: MatchedPR?] {
        var prByRepoBranch: [String: GitHubPRService.GitHubPR] = [:]
        let authoredSections: [GitHubPRService.PRSection] = [.returnedToMe, .approved, .waitingForReview, .drafts]
        for section in authoredSections {
            for pr in prSections[section] ?? [] {
                prByRepoBranch["\(pr.repository)/\(pr.headRefName)"] = pr
            }
        }

        var result: [String: MatchedPR?] = [:]
        for folder in folders {
            let key = Self.folderKey(folder)
            guard let repo = repoNames[key],
                  let bookmark = repositoryMonitor.bookmark(for: folder)
            else { continue }

            if let pr = prByRepoBranch["\(repo)/\(bookmark)"] {
                result[key] = MatchedPR(folder: folder, pr: pr, info: GitHubPRService.prInfo(from: pr))
            } else {
                result[key] = nil // folder was checked but has no matching PR
            }
        }
        return result
    }

    private func applyMatchedPRInfos(_ checkedFolders: [String: MatchedPR?]) {
        // Remove prInfos for folders that were checked but have no PR
        for (key, matched) in checkedFolders where matched == nil {
            prInfos.removeValue(forKey: key)
        }

        for case let (key, matched?) in checkedFolders {
            let oldInfo = prInfos[key]
            let merged = PRInfo(
                number: matched.info.number,
                url: matched.info.url,
                state: matched.info.state,
                checkStatus: matched.info.checkStatus,
                additions: matched.info.additions,
                deletions: matched.info.deletions,
                changedFiles: matched.info.changedFiles,
                commentCount: matched.info.commentCount,
                reviewers: matched.info.reviewers,
                reviewComments: oldInfo?.reviewComments ?? [],
                failedChecks: oldInfo?.failedChecks ?? []
            )

            if oldInfo != merged {
                prInfos[key] = merged
                detectPRTransitions(folder: matched.folder, old: oldInfo, new: merged, pr: matched.pr)
            }
        }
    }

    private func performPRAction(_ action: @escaping () async -> Bool) {
        Task {
            if await action() {
                refresh()
            }
        }
    }

    // swiftlint:disable:next function_body_length
    private func detectPRTransitions(
        folder: URL,
        old: PRInfo?,
        new: PRInfo,
        pr: GitHubPRService.GitHubPR
    ) {
        let agents = store.agents.filter { $0.folder.standardizedFileURL == folder.standardizedFileURL }
        guard !agents.isEmpty else { return }

        let autoFixCI = Self.userDefault(forKey: UserDefaultsKeys.autoFixCIFailures, default: true)
        let autoAnalyzeReviews = Self.userDefault(forKey: UserDefaultsKeys.autoAnalyzeReviews, default: true)

        let needsDeepFetch = (autoFixCI && new.checkStatus == .fail && old?.checkStatus != .fail)
            || (autoAnalyzeReviews && new.state == .changesRequested && old?.state != .changesRequested)
            || (autoAnalyzeReviews && new.state == .approved && old?.state != .approved)

        guard needsDeepFetch else {
            if new.checkStatus == .pass, old?.checkStatus == .fail {
                for agent in agents {
                    store.removePendingPrompts(for: agent.id, source: .ciFailed)
                }
            }
            if new.state == .approved, old?.state == .changesRequested {
                for agent in agents {
                    store.removePendingPrompts(for: agent.id, source: .changesRequested)
                }
            }
            return
        }

        Task {
            let deep = await githubPRService.fetchDeepPRInfo(repo: pr.repository, number: pr.number)

            let key = Self.folderKey(folder)
            if var info = prInfos[key] {
                info = PRInfo(
                    number: info.number,
                    url: info.url,
                    state: info.state,
                    checkStatus: deep.detailedCheckStatus,
                    additions: info.additions,
                    deletions: info.deletions,
                    changedFiles: info.changedFiles,
                    commentCount: info.commentCount,
                    reviewers: info.reviewers,
                    reviewComments: deep.reviewComments,
                    failedChecks: deep.failedChecks
                )
                prInfos[key] = info
            }

            if autoFixCI, new.checkStatus == .fail, old?.checkStatus != .fail {
                eventBus.publish(.checksFailed(folder: folder))
                let checkNames = deep.failedChecks.joined(separator: ", ")
                let prompt = """
                CI checks failed on PR #\(new.number). Failed checks: \(checkNames)

                Please investigate and fix the failures.
                """
                for agent in agents {
                    let pending = PendingPrompt(
                        agentId: agent.id,
                        source: .ciFailed,
                        summary: "Failed: \(checkNames)",
                        fullPrompt: prompt
                    )
                    if agent.state == .awaitingInput {
                        terminalManager.sendInput(to: agent.id, text: prompt)
                    } else {
                        store.addPendingPrompt(pending)
                    }
                }
            }

            if autoAnalyzeReviews, new.state == .changesRequested, old?.state != .changesRequested {
                eventBus.publish(.changesRequested(folder: folder))
                let comments = deep.reviewComments
                    .filter { $0.state == .changesRequested }
                    .map { "**\($0.author):** \($0.body)" }
                    .joined(separator: "\n\n")
                let prompt = """
                PR #\(new.number) received review feedback requesting changes:

                \(comments)

                Summarize the feedback and suggest how you would address each point.
                Do NOT make any changes — just analyze and explain your approach.
                """
                for agent in agents {
                    store.addPendingPrompt(PendingPrompt(
                        agentId: agent.id,
                        source: .changesRequested,
                        summary: "\(deep.reviewComments.count) review comment(s)",
                        fullPrompt: prompt
                    ))
                }
            }

            if new.state == .approved, old?.state == .changesRequested {
                for agent in agents {
                    store.removePendingPrompts(for: agent.id, source: .changesRequested)
                }
            }

            if autoAnalyzeReviews, new.state == .approved {
                let approvalComments = deep.reviewComments
                    .filter { $0.state == .approved && !$0.body.isEmpty }
                guard !approvalComments.isEmpty else { return }
                let oldCommentCount = old?.reviewComments.count(where: { $0.state == .approved }) ?? 0
                if approvalComments.count > oldCommentCount {
                    eventBus.publish(.approvedWithComments(folder: folder))
                    let comments = approvalComments
                        .map { "**\($0.author):** \($0.body)" }
                        .joined(separator: "\n\n")
                    let prompt = """
                    PR #\(new.number) was approved with comments:

                    \(comments)

                    Summarize the comments. If any suggest changes, explain how you would address them.
                    Do NOT make any changes — just analyze.
                    """
                    for agent in agents {
                        store.addPendingPrompt(PendingPrompt(
                            agentId: agent.id,
                            source: .approvedWithComments,
                            summary: "\(approvalComments.count) comment(s) on approval",
                            fullPrompt: prompt
                        ))
                    }
                }
            }
        }
    }

    private static func folderKey(_ folder: URL) -> String {
        folder.tildeAbbreviatedPath
    }

    private static func userDefault(forKey key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
    }
}
