import SwiftUI

@MainActor @Observable
final class AppCoordinator {
    // MARK: - Services

    let store = AgentStore()
    let terminalManager = TerminalManager()
    let shellManager = ShellManager()
    let diffService = DiffService()
    let githubPRService = GitHubPRService()
    let eventBus = AgentEventBus()
    let reviewerGroupStore = ReviewerGroupStore()

    // MARK: - Cached Data

    var fileChanges: [FileChange] = []
    var fullDiff: String = ""
    var branchNames: [String: String] = [:]
    var prInfos: [String: PRInfo] = [:]
    @ObservationIgnored private var repoNames: [String: String] = [:]
    @ObservationIgnored private var bookmarks: [String: String] = [:]
    var githubPRSections: [GitHubPRService.PRSection: [GitHubPRService.GitHubPR]] = [:]
    var isLoadingPRs = true
    var githubRateLimit: GitHubPRService.RateLimit?
    var lastPRPollTime: Date?
    var selectedGitHubPR: GitHubPRService.GitHubPR?
    var selectedPRDiff: String = ""
    var selectedPRChanges: [FileChange] = []

    // MARK: - UI State

    var activeSidebarPanel: SidebarPanel?
    var isAgentPanelVisible = true

    // MARK: - Private

    private var fileWatcher = FileSystemWatcher()
    private var sessionWatcher = FileSystemWatcher()
    private var prTimer: Timer?
    private var prPollCount = 0

    // MARK: - Lifecycle

    func start() {
        setupFileWatcher()
        startPRPolling()

        terminalManager.onStateChange = { [self] id, state in
            store.updateState(id: id, state: state)
            if state == .awaitingInput {
                let autoSendPrompts = store.pendingPrompts(for: id).filter(\.autoSend)
                if let first = autoSendPrompts.first {
                    terminalManager.sendInput(to: id, text: first.fullPrompt)
                    store.removePendingPrompt(id: first.id)
                }
                eventBus.publish(.agentIdle(agentId: id))
            } else if state == .active {
                eventBus.publish(.agentActive(agentId: id))
            }
        }

        eventBus.onSendPrompt = { [self] agentId, prompt in
            terminalManager.sendInput(to: agentId, text: prompt)
        }

        terminalManager.onLaunched = { [self] id in
            store.markLaunched(id: id)
        }

        terminalManager.onSessionNotFound = { [self] id in
            store.resetSession(id: id)
            if let agent = store.agents.first(where: { $0.id == id }) {
                terminalManager.restartAgent(agent) { id, state in
                    self.store.updateState(id: id, state: state)
                }
            }
        }

        refreshDiffs()
        refreshBranchNames()
    }

    func stop() {
        fileWatcher.unwatchAll()
        sessionWatcher.unwatchAll()
        prTimer?.invalidate()
    }

    // MARK: - Agent Actions

    func removeAgent(_ id: UUID) {
        terminalManager.removeTerminal(for: id)
        shellManager.removeTerminal(for: id)
        store.removeAgent(id: id)
    }

    func handleAgentFoldersChanged(old oldFolders: [URL], new newFolders: [URL]) {
        let oldSet = Set(oldFolders)
        let newSet = Set(newFolders)
        for removed in oldSet.subtracting(newSet) {
            fileWatcher.unwatch(directory: removed)
            sessionWatcher.unwatch(
                directory: SessionFileDetector.claudeProjectDir(for: removed)
            )
        }
        for added in newSet.subtracting(oldSet) {
            fileWatcher.watch(directory: added)
            sessionWatcher.watch(
                directory: SessionFileDetector.claudeProjectDir(for: added)
            )
        }
    }

    func sendPrompt(_ prompt: PendingPrompt) {
        terminalManager.sendInput(to: prompt.agentId, text: prompt.fullPrompt)
    }

    // MARK: - Diff

    private var diffGeneration = 0

    func refreshDiffs() {
        guard let agent = store.selectedAgent else {
            fileChanges = []
            fullDiff = ""
            return
        }

        let generation = diffGeneration
        let agentId = agent.id
        Task {
            let diff = await diffService.fetchFullDiff(in: agent.folder)
            let changes = await diffService.parseChanges(from: diff)
            guard generation == diffGeneration, store.selectedAgentId == agentId else { return }
            fullDiff = diff
            fileChanges = changes
        }
    }

    func invalidateDiffs() {
        diffGeneration += 1
        refreshDiffs()
    }

    // MARK: - GitHub PRs

    func selectPR(_ pr: GitHubPRService.GitHubPR?) {
        selectedGitHubPR = pr
        selectedPRDiff = ""
        selectedPRChanges = []
        guard let pr else { return }
        Task {
            let diff = await githubPRService.fetchPRDiff(repo: pr.repository, number: pr.number)
            let changes = await diffService.parseChanges(from: diff)
            if selectedGitHubPR?.id == pr.id {
                selectedPRDiff = diff
                selectedPRChanges = changes
            }
        }
    }

    func addReviewers(_ pr: GitHubPRService.GitHubPR, group: ReviewerGroup) {
        performPRAction {
            await self.githubPRService.addReviewers(
                repo: pr.repository, number: pr.number, reviewers: group.reviewers
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

    private func performPRAction(_ action: @escaping () async -> Bool) {
        Task {
            if await action() {
                refreshCorePRData()
            }
        }
    }

    func reviewPR(_ pr: GitHubPRService.GitHubPR) {
        let repoName = pr.repository.components(separatedBy: "/").last ?? ""
        let matchingAgent = store.agents.first { $0.folderPath.contains(repoName) }

        guard let folder = matchingAgent?.folder else { return }

        let previousSelection = store.selectedAgentId
        let reviewAgent = store.addAgent(
            name: "PR #\(pr.number) - Review",
            folder: folder
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

    // MARK: - Private: File Watching

    private func setupFileWatcher() {
        fileWatcher.onDirectoryChanged = { [self] changedFolder in
            refreshBranchName(for: changedFolder)
            eventBus.publish(.diffChanged(folder: changedFolder))
            if let selected = store.selectedAgent,
               selected.folder.standardizedFileURL == changedFolder {
                refreshDiffs()
            }
        }
        fileWatcher.onVCSMetadataChanged = { [self] changedFolder in
            refreshBranchName(for: changedFolder)
            eventBus.publish(.branchChanged(folder: changedFolder))
            // jj new, jj commit, git commit etc. change VCS metadata without
            // touching working copy files — refresh diffs for the selected agent
            if let selected = store.selectedAgent,
               selected.folder.standardizedFileURL == changedFolder {
                refreshDiffs()
            }
        }
        for folder in Set(store.agents.map(\.folder)) {
            fileWatcher.watch(directory: folder)
        }
        setupSessionWatcher()
    }

    private func setupSessionWatcher() {
        sessionWatcher.onDirectoryChanged = { [self] _ in
            for agent in store.agents {
                guard let sessionId = agent.sessionId,
                      !SessionFileDetector.sessionFileExists(sessionId, for: agent.folder),
                      let actual = SessionFileDetector.latestSessionId(for: agent.folder)
                else { continue }
                store.updateSessionId(id: agent.id, sessionId: actual)
            }
        }
        for folder in Set(store.agents.map(\.folder)) {
            let projectDir = SessionFileDetector.claudeProjectDir(for: folder)
            sessionWatcher.watch(directory: projectDir)
        }
    }

    // MARK: - Private: PR Polling

    private func startPRPolling() {
        refreshCorePRData()
        prTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCorePRData()
            }
        }
    }

    /// Fast poll (30s): fetches all PRs, matches authored PRs to agent folders.
    private func refreshCorePRData() {
        Task {
            let folders = Set(store.agents.map(\.folder))

            // Cache repo names on first encounter (local git command, never changes)
            for folder in folders {
                let key = Self.folderKey(folder)
                if repoNames[key] == nil {
                    repoNames[key] = await diffService.fetchRepoName(in: folder)
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

            // Match authored PRs to agent folders
            var prByRepoBranch: [String: GitHubPRService.GitHubPR] = [:]
            let authoredSections: [GitHubPRService.PRSection] = [.returnedToMe, .approved, .waitingForReview, .drafts]
            for section in authoredSections {
                for pr in prSections[section] ?? [] {
                    prByRepoBranch["\(pr.repository)/\(pr.headRefName)"] = pr
                }
            }

            for folder in folders {
                let key = Self.folderKey(folder)
                guard let repo = repoNames[key],
                      let bookmark = bookmarks[key]
                else { continue }

                let lookupKey = "\(repo)/\(bookmark)"
                let oldInfo = prInfos[key]

                if let pr = prByRepoBranch[lookupKey] {
                    let newInfo = GitHubPRService.prInfo(from: pr)
                    // Preserve deep-fetch fields from previous enrichment
                    let merged = PRInfo(
                        number: newInfo.number, url: newInfo.url, state: newInfo.state,
                        checkStatus: newInfo.checkStatus,
                        additions: newInfo.additions, deletions: newInfo.deletions,
                        changedFiles: newInfo.changedFiles, commentCount: newInfo.commentCount,
                        reviewers: newInfo.reviewers,
                        reviewComments: oldInfo?.reviewComments ?? [],
                        failedChecks: oldInfo?.failedChecks ?? []
                    )
                    if oldInfo != merged {
                        prInfos[key] = merged
                        detectPRTransitions(folder: folder, old: oldInfo, new: merged, pr: pr)
                    }
                } else if oldInfo != nil {
                    prInfos.removeValue(forKey: key)
                }
            }
        }
    }

    private func refreshBranchNames() {
        let folders = Set(store.agents.map(\.folder))
        for folder in folders {
            refreshBranchName(for: folder)
        }
    }

    private func refreshBranchName(for folder: URL) {
        Task {
            let name = await diffService.fetchBranchName(in: folder)
            let key = Self.folderKey(folder)
            let bookmark = await diffService.fetchBookmark(in: folder)
            let changed = branchNames[key] != name || bookmarks[key] != bookmark
            branchNames[key] = name
            bookmarks[key] = bookmark
            if changed {
                Task { refreshCorePRData() }
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
            // CI checks passed — auto-dismiss stale CI prompts
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

        // Fetch deep fields on-demand (single targeted API call)
        Task {
            let deep = await githubPRService.fetchDeepPRInfo(repo: pr.repository, number: pr.number)

            // Update prInfos with the deep data
            let key = Self.folderKey(folder)
            if var info = prInfos[key] {
                info = PRInfo(
                    number: info.number, url: info.url, state: info.state,
                    checkStatus: deep.detailedCheckStatus,
                    additions: info.additions, deletions: info.deletions,
                    changedFiles: info.changedFiles, commentCount: info.commentCount,
                    reviewers: info.reviewers, reviewComments: deep.reviewComments,
                    failedChecks: deep.failedChecks
                )
                prInfos[key] = info
            }

            // CI checks went from non-fail to fail
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

            // Changes requested
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

            // Review approved — auto-dismiss changes requested prompts
            if new.state == .approved, old?.state == .changesRequested {
                for agent in agents {
                    store.removePendingPrompts(for: agent.id, source: .changesRequested)
                }
            }

            // Approved with comments
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

    // MARK: - Helpers

    private static func folderKey(_ folder: URL) -> String {
        folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func userDefault(forKey key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
    }
}
