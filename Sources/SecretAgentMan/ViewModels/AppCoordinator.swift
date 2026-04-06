import SwiftUI

@MainActor @Observable
final class AppCoordinator {
    // MARK: - Services

    let store = AgentStore()
    let terminalManager = TerminalManager()
    let shellManager = ShellManager()
    let diffService = DiffService()
    let prService = PRService()
    let githubPRService = GitHubPRService()
    let eventBus = AgentEventBus()

    // MARK: - Cached Data

    var fileChanges: [FileChange] = []
    var fullDiff: String = ""
    var branchNames: [String: String] = [:]
    var prInfos: [String: PRInfo] = [:]
    var githubPRSections: [GitHubPRService.PRSection: [GitHubPRService.GitHubPR]] = [:]
    var selectedGitHubPR: GitHubPRService.GitHubPR?
    var selectedPRDiff: String = ""
    var selectedPRChanges: [FileChange] = []

    // MARK: - Private

    private var fileWatcher = FileSystemWatcher()
    private var sessionWatcher = FileSystemWatcher()
    private var prTimer: Timer?
    private var githubPRTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        setupFileWatcher()
        startPRPolling()
        startGitHubPRPolling()

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
        githubPRTimer?.invalidate()
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

    func refreshDiffs() {
        guard let agent = store.selectedAgent else {
            fileChanges = []
            fullDiff = ""
            return
        }

        Task {
            let diff = await diffService.fetchFullDiff(in: agent.folder)
            let changes = await diffService.parseChanges(from: diff)
            fullDiff = diff
            fileChanges = changes
        }
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
        refreshPRStatuses()
        prTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPRStatuses()
            }
        }
    }

    private func refreshPRStatuses() {
        let folders = Set(store.agents.map(\.folder))
        for folder in folders {
            Task {
                let info = await prService.fetchPRInfo(in: folder)
                let key = Self.folderKey(folder)
                let oldInfo = prInfos[key]
                if oldInfo != info {
                    if let info {
                        prInfos[key] = info
                        detectPRTransitions(
                            folder: folder, old: oldInfo, new: info
                        )
                    } else {
                        prInfos.removeValue(forKey: key)
                    }
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
            if branchNames[key] != name {
                branchNames[key] = name
                Task { refreshPRStatuses() }
            }
        }
    }

    private func detectPRTransitions(folder: URL, old: PRInfo?, new: PRInfo) {
        let agents = store.agents.filter { $0.folder.standardizedFileURL == folder.standardizedFileURL }
        guard !agents.isEmpty else { return }

        let autoFixCI = Self.userDefault(forKey: UserDefaultsKeys.autoFixCIFailures, default: true)
        let autoAnalyzeReviews = Self.userDefault(forKey: UserDefaultsKeys.autoAnalyzeReviews, default: true)

        // CI checks went from non-fail to fail
        if autoFixCI, new.checkStatus == .fail, old?.checkStatus != .fail {
            eventBus.publish(.checksFailed(folder: folder))
            let checkNames = new.failedChecks.joined(separator: ", ")
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

        // CI checks passed — auto-dismiss stale CI prompts
        if new.checkStatus == .pass, old?.checkStatus == .fail {
            for agent in agents {
                store.removePendingPrompts(for: agent.id, source: .ciFailed)
            }
        }

        // Changes requested
        if autoAnalyzeReviews, new.state == .changesRequested, old?.state != .changesRequested {
            eventBus.publish(.changesRequested(folder: folder))
            let comments = new.reviewComments
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
                    summary: "\(new.reviewComments.count) review comment(s)",
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
        if autoAnalyzeReviews, new.state == .approved,
           !new.reviewComments.filter({ $0.state == .approved && !$0.body.isEmpty }).isEmpty {
            let approvalComments = new.reviewComments
                .filter { $0.state == .approved && !$0.body.isEmpty }
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

    // MARK: - Private: GitHub PR Polling

    private func startGitHubPRPolling() {
        refreshGitHubPRs()
        githubPRTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshGitHubPRs()
            }
        }
    }

    private func refreshGitHubPRs() {
        Task {
            let sections = await githubPRService.fetchAllPRs()
            githubPRSections = sections
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
