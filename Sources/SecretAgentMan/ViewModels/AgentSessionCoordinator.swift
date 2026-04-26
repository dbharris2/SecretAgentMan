import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AgentSessionCoordinator {
    let store: AgentStore
    let shellManager: ShellManager
    let eventBus: AgentEventBus
    let codexMonitor: CodexAppServerMonitor
    let claudeMonitor: ClaudeStreamMonitor
    let geminiMonitor: GeminiAcpMonitor

    /// Per-agent reduced session snapshots. Populated by the normalized
    /// `SessionEvent` stream from each provider monitor. Phase 2 of the
    /// migration is now reading from this in select views; the legacy
    /// provider-specific dictionaries still back everything else.
    private(set) var snapshots: [UUID: AgentSessionSnapshot] = [:]

    @ObservationIgnored private var sessionWatcher = FileSystemWatcher()

    init(
        store: AgentStore = AgentStore(),
        shellManager: ShellManager = ShellManager(),
        eventBus: AgentEventBus = AgentEventBus(),
        codexMonitor: CodexAppServerMonitor = CodexAppServerMonitor(),
        claudeMonitor: ClaudeStreamMonitor = ClaudeStreamMonitor(),
        geminiMonitor: GeminiAcpMonitor = GeminiAcpMonitor()
    ) {
        self.store = store
        self.shellManager = shellManager
        self.eventBus = eventBus
        self.codexMonitor = codexMonitor
        self.claudeMonitor = claudeMonitor
        self.geminiMonitor = geminiMonitor
    }

    func start() {
        codexMonitor.onSessionReady = { [self] id, threadId in
            store.updateSessionId(id: id, sessionId: threadId)
            store.markLaunched(id: id)
            syncSessionWatches()
        }

        codexMonitor.onStateChange = { [self] id, state in
            handleAgentStateChange(agentId: id, state: state)
        }

        codexMonitor.onSessionEvent = { [self] id, event in
            reduceSessionEvent(agentId: id, event: event)
        }

        claudeMonitor.onSessionReady = { [self] id, sessionId in
            store.updateSessionId(id: id, sessionId: sessionId)
            store.markLaunched(id: id)
            syncSessionWatches()
        }

        claudeMonitor.onStateChange = { [self] id, state in
            handleAgentStateChange(agentId: id, state: state)
        }

        claudeMonitor.onSessionEvent = { [self] id, event in
            reduceSessionEvent(agentId: id, event: event)
        }

        claudeMonitor.onSessionConflict = { [self] id in
            // Session ID is locked by an orphaned Claude process.
            // Remove the broken observer, reset to a fresh session ID, and retry once.
            claudeMonitor.removeObserver(for: id)
            store.resetSession(id: id)
            if let agent = store.agents.first(where: { $0.id == id }) {
                claudeMonitor.ensureSession(for: agent)
            }
        }

        geminiMonitor.onSessionReady = { [self] id, sessionId in
            store.updateSessionId(id: id, sessionId: sessionId)
            store.markLaunched(id: id)
            syncSessionWatches()
        }
        geminiMonitor.onStateChange = { [self] id, state in
            handleAgentStateChange(agentId: id, state: state)
        }
        geminiMonitor.onSessionEvent = { [self] id, event in
            reduceSessionEvent(agentId: id, event: event)
        }

        eventBus.onSendPrompt = { [self] agentId, prompt in
            guard let agent = store.agents.first(where: { $0.id == agentId }) else { return }
            switch agent.provider {
            case .claude:
                claudeMonitor.sendMessage(for: agentId, text: prompt)
            case .codex:
                codexMonitor.sendMessage(for: agentId, text: prompt)
            case .gemini:
                geminiMonitor.sendMessage(for: agentId, text: prompt)
            }
        }

        sessionWatcher.onDirectoryChanged = { [self] _ in
            for agent in store.agents {
                // Only recover sessions for agents that have launched. New agents
                // won't have their session file yet — without this guard, the watcher
                // would see the file as "missing" and overwrite the sessionId with
                // whatever stale session was most recent in the directory.
                guard agent.hasLaunched,
                      let sessionId = agent.sessionId,
                      !SessionFileDetector.sessionFileExists(sessionId, for: agent),
                      let actual = SessionFileDetector.latestSessionId(for: agent)
                else { continue }
                store.updateSessionId(id: agent.id, sessionId: actual)
            }
            codexMonitor.syncMonitoredAgents(store.agents)
        }

        syncSessionWatches()
    }

    func stop() {
        sessionWatcher.unwatchAll()
        codexMonitor.stopAll()
        claudeMonitor.stopAll()
        geminiMonitor.stopAll()
    }

    func syncSessionWatches() {
        let desired = Set(store.agents.map { SessionFileDetector.sessionDirectory(for: $0) })
        let current = sessionWatcher.watchedDirectories
        for removed in current.subtracting(desired) {
            sessionWatcher.unwatch(directory: removed)
        }
        for added in desired.subtracting(current) {
            sessionWatcher.watch(directory: added)
        }
        codexMonitor.syncMonitoredAgents(store.agents)
        claudeMonitor.syncMonitoredAgents(store.agents)
        geminiMonitor.syncMonitoredAgents(store.agents)
    }

    func removeAgent(_ id: UUID) {
        let folder = store.agents.first(where: { $0.id == id })?.folder
        codexMonitor.removeObserver(for: id)
        claudeMonitor.removeObserver(for: id)
        geminiMonitor.removeObserver(for: id)
        snapshots.removeValue(forKey: id)
        store.removeAgent(id: id)
        if let folder, !folderHasAgents(folder) {
            shellManager.removeShell(forFolder: folder)
        }
    }

    func removeAgents(in folder: URL) {
        let folderURL = folder.standardizedFileURL
        let agentIds = store.agents
            .filter { $0.folder.standardizedFileURL == folderURL }
            .map(\.id)

        for id in agentIds {
            removeAgent(id)
        }

        syncSessionWatches()
    }

    func ensureCodexSession(for agentId: UUID) {
        guard let agent = store.agents.first(where: { $0.id == agentId }),
              agent.provider == .codex
        else { return }
        codexMonitor.ensureSession(for: agent)
    }

    func ensureClaudeSession(for agentId: UUID) {
        guard let agent = store.agents.first(where: { $0.id == agentId }),
              agent.provider == .claude
        else { return }
        claudeMonitor.ensureSession(for: agent)
    }

    func ensureGeminiSession(for agentId: UUID) {
        guard let agent = store.agents.first(where: { $0.id == agentId }),
              agent.provider == .gemini
        else { return }
        // First ensureSession spawns the process; the session id arrives via
        // the ACP `session/new` (or `session/load`) response.
        store.markLaunched(id: agentId)
        geminiMonitor.ensureSession(for: agent)
    }

    private func reduceSessionEvent(agentId: UUID, event: SessionEvent) {
        let previous = snapshots[agentId] ?? AgentSessionSnapshot()
        let next = AgentSessionReducer.reduce(previous, event: event)
        snapshots[agentId] = next
    }

    private func folderHasAgents(_ folder: URL) -> Bool {
        let key = ShellManager.shellKey(forFolder: folder)
        return store.agents.contains { ShellManager.shellKey(forFolder: $0.folder) == key }
    }

    private func handleAgentStateChange(agentId: UUID, state: AgentState) {
        guard store.agents.contains(where: { $0.id == agentId }) else { return }
        store.updateState(id: agentId, state: state)
        if state == .awaitingInput {
            eventBus.publish(.agentIdle(agentId: agentId))
        } else if state == .active {
            eventBus.publish(.agentActive(agentId: agentId))
        }
    }
}
