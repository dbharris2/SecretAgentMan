import SwiftUI

@MainActor @Observable
final class AppCoordinator {
    let agentSessions: AgentSessionCoordinator
    let repositoryMonitor: RepositoryMonitor
    let prStore: PRStore
    let usageMonitor: UsageMonitor

    let store: AgentStore
    let terminalManager: TerminalManager
    let shellManager: ShellManager
    let eventBus: AgentEventBus
    let reviewerGroupStore = ReviewerGroupStore()
    @ObservationIgnored private let userDefaults: UserDefaults

    // MARK: - UI State

    var activeSidebarPanel: SidebarPanel? {
        didSet {
            persistActiveSidebarPanel()
        }
    }

    var isAgentPanelVisible = true

    init(
        loadStateFromDisk: Bool = true,
        userDefaults: UserDefaults = .standard
    ) {
        let store = AgentStore(loadFromDisk: loadStateFromDisk, userDefaults: userDefaults)
        let agentSessions = AgentSessionCoordinator(store: store)
        let repositoryMonitor = RepositoryMonitor(store: agentSessions.store)
        let prStore = PRStore(
            store: agentSessions.store,
            terminalManager: agentSessions.terminalManager,
            eventBus: agentSessions.eventBus,
            repositoryMonitor: repositoryMonitor
        )

        let usageMonitor = UsageMonitor(store: agentSessions.store)

        self.agentSessions = agentSessions
        self.repositoryMonitor = repositoryMonitor
        self.prStore = prStore
        self.usageMonitor = usageMonitor
        self.store = agentSessions.store
        terminalManager = agentSessions.terminalManager
        shellManager = agentSessions.shellManager
        eventBus = agentSessions.eventBus
        self.userDefaults = userDefaults
        activeSidebarPanel = Self.restoreActiveSidebarPanel(from: userDefaults)

        repositoryMonitor.onDiffChanged = { [weak self] folder in
            self?.eventBus.publish(.diffChanged(folder: folder))
        }
        repositoryMonitor.onBranchChanged = { [weak self] folder in
            self?.eventBus.publish(.branchChanged(folder: folder))
        }
        repositoryMonitor.onBranchMetadataChanged = { [weak self] _ in
            self?.prStore.refresh()
        }
    }

    // MARK: - Lifecycle

    func start() {
        agentSessions.start()
        repositoryMonitor.start()
        prStore.start()
        usageMonitor.start()
    }

    func stop() {
        repositoryMonitor.stop()
        agentSessions.stop()
        prStore.stop()
        usageMonitor.stop()
    }

    // MARK: - Agent Actions

    func removeAgent(_ id: UUID) {
        agentSessions.removeAgent(id)
    }

    func syncWatchedAgents() {
        repositoryMonitor.syncWatchedFolders()
        agentSessions.syncSessionWatches()
        usageMonitor.syncWatches()
        usageMonitor.refreshSelectedAgent()
    }

    func sendPrompt(_ prompt: PendingPrompt) {
        agentSessions.sendPrompt(prompt)
    }

    func invalidateDiffs() {
        repositoryMonitor.invalidateDiffs()
    }

    func selectPR(_ pr: GitHubPRService.GitHubPR?) {
        prStore.selectPR(pr)
    }

    func addReviewers(_ pr: GitHubPRService.GitHubPR, group: ReviewerGroup) {
        prStore.addReviewers(pr, group: group)
    }

    func closePR(_ pr: GitHubPRService.GitHubPR) {
        prStore.closePR(pr)
    }

    func markPRReady(_ pr: GitHubPRService.GitHubPR) {
        prStore.markPRReady(pr)
    }

    func convertPRToDraft(_ pr: GitHubPRService.GitHubPR) {
        prStore.convertPRToDraft(pr)
    }

    func reviewPR(_ pr: GitHubPRService.GitHubPR) {
        prStore.reviewPR(pr)
    }

    private static func restoreActiveSidebarPanel(from userDefaults: UserDefaults) -> SidebarPanel? {
        guard let rawValue = userDefaults.string(forKey: UserDefaultsKeys.activeSidebarPanel) else {
            return nil
        }
        return SidebarPanel(rawValue: rawValue)
    }

    private func persistActiveSidebarPanel() {
        if let activeSidebarPanel {
            userDefaults.set(activeSidebarPanel.rawValue, forKey: UserDefaultsKeys.activeSidebarPanel)
        } else {
            userDefaults.removeObject(forKey: UserDefaultsKeys.activeSidebarPanel)
        }
    }
}
