import Foundation
import SwiftUI

@MainActor
@Observable
final class PRStore {
    let githubPRService: GitHubPRService
    let automationPolicy: PRAutomationPolicy

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
        githubPRService: GitHubPRService = GitHubPRService(),
        automationPolicy: PRAutomationPolicy = PRAutomationPolicy()
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.eventBus = eventBus
        self.repositoryMonitor = repositoryMonitor
        self.githubPRService = githubPRService
        self.automationPolicy = automationPolicy
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
        store.selectAgent(id: previousSelection)

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

    private func detectPRTransitions(
        folder: URL,
        old: PRInfo?,
        new: PRInfo,
        pr: GitHubPRService.GitHubPR
    ) {
        let agents = store.agents.filter { $0.folder.standardizedFileURL == folder.standardizedFileURL }
        guard !agents.isEmpty else { return }

        let settings = automationSettings()
        let initialPlan = automationPolicy.initialPlan(old: old, new: new, settings: settings)
        applyPromptRemovals(initialPlan.removedPromptSources, to: agents)

        guard initialPlan.needsDeepFetch else { return }

        Task {
            let deep = await githubPRService.fetchDeepPRInfo(repo: pr.repository, number: pr.number)
            let details = PRAutomationPolicy.DeepDetails(
                reviewComments: deep.reviewComments,
                failedChecks: deep.failedChecks,
                detailedCheckStatus: deep.detailedCheckStatus
            )

            let key = Self.folderKey(folder)
            if var info = prInfos[key] {
                info = automationPolicy.mergedInfo(current: info, details: details)
                prInfos[key] = info
            }

            let deepPlan = automationPolicy.deepPlan(old: old, new: new, details: details, settings: settings)
            applyPromptRemovals(deepPlan.removedPromptSources, to: agents)
            publishEvents(deepPlan.events, folder: folder)
            applyPromptRequests(deepPlan.prompts, to: agents)
        }
    }

    private func automationSettings() -> PRAutomationPolicy.Settings {
        PRAutomationPolicy.Settings(
            autoFixCI: Self.userDefault(forKey: UserDefaultsKeys.autoFixCIFailures, default: true),
            autoAnalyzeReviews: Self.userDefault(forKey: UserDefaultsKeys.autoAnalyzeReviews, default: true)
        )
    }

    private func applyPromptRemovals(
        _ sources: [PendingPrompt.PromptSource],
        to agents: [Agent]
    ) {
        for source in sources {
            for agent in agents {
                store.removePendingPrompts(for: agent.id, source: source)
            }
        }
    }

    private func publishEvents(_ events: [PRAutomationPolicy.EventKind], folder: URL) {
        for event in events {
            switch event {
            case .changesRequested:
                eventBus.publish(.changesRequested(folder: folder))
            case .checksFailed:
                eventBus.publish(.checksFailed(folder: folder))
            case .approvedWithComments:
                eventBus.publish(.approvedWithComments(folder: folder))
            }
        }
    }

    private func applyPromptRequests(
        _ prompts: [PRAutomationPolicy.PromptRequest],
        to agents: [Agent]
    ) {
        for prompt in prompts {
            for agent in agents {
                if prompt.sendDirectlyToAwaitingAgents, agent.state == .awaitingInput {
                    terminalManager.sendInput(to: agent.id, text: prompt.fullPrompt)
                    continue
                }

                store.addPendingPrompt(PendingPrompt(
                    agentId: agent.id,
                    source: prompt.source,
                    summary: prompt.summary,
                    fullPrompt: prompt.fullPrompt
                ))
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
