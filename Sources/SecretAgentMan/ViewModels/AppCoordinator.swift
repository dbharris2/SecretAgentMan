import SwiftUI

@MainActor @Observable
final class AppCoordinator {
    let agentSessions: AgentSessionCoordinator
    let repositoryMonitor: RepositoryMonitor
    let prMonitor: PRMonitor

    let store: AgentStore
    let terminalManager: TerminalManager
    let shellManager: ShellManager
    let eventBus: AgentEventBus
    let reviewerGroupStore = ReviewerGroupStore()

    // MARK: - UI State

    var activeSidebarPanel: SidebarPanel?
    var isAgentPanelVisible = true

    init() {
        let agentSessions = AgentSessionCoordinator()
        let repositoryMonitor = RepositoryMonitor(store: agentSessions.store)
        let prMonitor = PRMonitor(
            store: agentSessions.store,
            terminalManager: agentSessions.terminalManager,
            eventBus: agentSessions.eventBus,
            repositoryMonitor: repositoryMonitor
        )

        self.agentSessions = agentSessions
        self.repositoryMonitor = repositoryMonitor
        self.prMonitor = prMonitor
        store = agentSessions.store
        terminalManager = agentSessions.terminalManager
        shellManager = agentSessions.shellManager
        eventBus = agentSessions.eventBus

        repositoryMonitor.onDiffChanged = { [weak self] folder in
            self?.eventBus.publish(.diffChanged(folder: folder))
        }
        repositoryMonitor.onBranchChanged = { [weak self] folder in
            self?.eventBus.publish(.branchChanged(folder: folder))
        }
        repositoryMonitor.onBranchMetadataChanged = { [weak self] _ in
            self?.prMonitor.refreshCorePRData()
        }
    }

    // MARK: - Lifecycle

    func start() {
        agentSessions.start()
        repositoryMonitor.start()
        prMonitor.start()
    }

    func stop() {
        repositoryMonitor.stop()
        agentSessions.stop()
        prMonitor.stop()
    }

    // MARK: - Agent Actions

    func removeAgent(_ id: UUID) {
        agentSessions.removeAgent(id)
    }

    func syncWatchedAgents() {
        repositoryMonitor.syncWatchedFolders()
        agentSessions.syncSessionWatches()
    }

    func sendPrompt(_ prompt: PendingPrompt) {
        agentSessions.sendPrompt(prompt)
    }

    func invalidateDiffs() {
        repositoryMonitor.invalidateDiffs()
    }

    func selectPR(_ pr: GitHubPRService.GitHubPR?) {
        prMonitor.selectPR(pr)
    }

    func addReviewers(_ pr: GitHubPRService.GitHubPR, group: ReviewerGroup) {
        prMonitor.addReviewers(pr, group: group)
    }

    func closePR(_ pr: GitHubPRService.GitHubPR) {
        prMonitor.closePR(pr)
    }

    func markPRReady(_ pr: GitHubPRService.GitHubPR) {
        prMonitor.markPRReady(pr)
    }

    func convertPRToDraft(_ pr: GitHubPRService.GitHubPR) {
        prMonitor.convertPRToDraft(pr)
    }

    func reviewPR(_ pr: GitHubPRService.GitHubPR) {
        prMonitor.reviewPR(pr)
    }
}
