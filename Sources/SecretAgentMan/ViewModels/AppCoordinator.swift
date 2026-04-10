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
    let codexMonitor: CodexAppServerMonitor
    let claudeMonitor: ClaudeStreamMonitor
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
        codexMonitor = agentSessions.codexMonitor
        claudeMonitor = agentSessions.claudeMonitor
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

    func ensureCodexSession(for agentId: UUID) {
        agentSessions.ensureCodexSession(for: agentId)
    }

    func sendCodexMessage(for agentId: UUID, text: String, imagePaths: [String] = []) {
        agentSessions.ensureCodexSession(for: agentId)
        codexMonitor.sendMessage(for: agentId, text: text, imagePaths: imagePaths)
    }

    func setCodexCollaborationMode(for agentId: UUID, mode: CodexCollaborationMode) {
        agentSessions.ensureCodexSession(for: agentId)
        codexMonitor.setCollaborationMode(for: agentId, mode: mode)
    }

    func triggerCodexUserInputTest(for agentId: UUID) {
        codexMonitor.debugTriggerUserInput(for: agentId)
    }

    func answerCodexUserInput(for agentId: UUID, answers: [String: [String]]) {
        codexMonitor.respondToUserInput(for: agentId, answers: answers)
    }

    func answerCodexApproval(for agentId: UUID, accept: Bool) {
        codexMonitor.respondToApproval(for: agentId, accept: accept)
    }

    // MARK: - Claude Actions

    func ensureClaudeSession(for agentId: UUID) {
        agentSessions.ensureClaudeSession(for: agentId)
    }

    func sendClaudeMessage(for agentId: UUID, text: String, images: [(Data, String)] = []) {
        agentSessions.ensureClaudeSession(for: agentId)
        claudeMonitor.sendMessage(for: agentId, text: text, images: images)
    }

    func answerClaudeApproval(for agentId: UUID, accept: Bool) {
        claudeMonitor.respondToApproval(for: agentId, accept: accept)
    }

    func answerClaudeElicitation(for agentId: UUID, answer: String) {
        claudeMonitor.respondToElicitation(for: agentId, answer: answer)
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
