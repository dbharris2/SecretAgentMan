import Foundation
import SwiftUI

@MainActor
final class AgentSessionCoordinator {
    let store: AgentStore
    let terminalManager: TerminalManager
    let shellManager: ShellManager
    let eventBus: AgentEventBus
    let codexMonitor: CodexAppServerMonitor
    let claudeMonitor: ClaudeStreamMonitor

    private var sessionWatcher = FileSystemWatcher()

    init(
        store: AgentStore = AgentStore(),
        terminalManager: TerminalManager = TerminalManager(),
        shellManager: ShellManager = ShellManager(),
        eventBus: AgentEventBus = AgentEventBus(),
        codexMonitor: CodexAppServerMonitor = CodexAppServerMonitor(),
        claudeMonitor: ClaudeStreamMonitor = ClaudeStreamMonitor()
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.shellManager = shellManager
        self.eventBus = eventBus
        self.codexMonitor = codexMonitor
        self.claudeMonitor = claudeMonitor
    }

    func start() {
        terminalManager.onStateChange = { [self] id, state in
            handleAgentStateChange(agentId: id, state: state, source: .terminal)
        }

        codexMonitor.onSessionReady = { [self] id, threadId in
            store.updateSessionId(id: id, sessionId: threadId)
            store.markLaunched(id: id)
            syncSessionWatches()
        }

        codexMonitor.onStateChange = { [self] id, state in
            handleAgentStateChange(agentId: id, state: state, source: .codex)
        }

        claudeMonitor.onSessionReady = { [self] id, sessionId in
            store.updateSessionId(id: id, sessionId: sessionId)
            store.markLaunched(id: id)
            syncSessionWatches()
        }

        claudeMonitor.onStateChange = { [self] id, state in
            handleAgentStateChange(agentId: id, state: state, source: .claude)
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

        eventBus.onSendPrompt = { [self] agentId, prompt in
            if let agent = store.agents.first(where: { $0.id == agentId }) {
                switch agent.provider {
                case .claude:
                    claudeMonitor.sendMessage(for: agentId, text: prompt)
                case .codex:
                    codexMonitor.sendMessage(for: agentId, text: prompt)
                }
            } else {
                terminalManager.sendInput(to: agentId, text: prompt)
            }
        }

        terminalManager.onLaunched = { [self] id in
            store.markLaunched(id: id)
            codexMonitor.syncMonitoredAgents(store.agents)
        }

        terminalManager.onSessionNotFound = { [self] id in
            store.resetSession(id: id)
            if let agent = store.agents.first(where: { $0.id == id }) {
                terminalManager.restartAgent(agent) { agentId, state in
                    self.store.updateState(id: agentId, state: state)
                }
            }
            store.terminalRestartCount += 1
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
    }

    func removeAgent(_ id: UUID) {
        terminalManager.removeTerminal(for: id)
        shellManager.removeTerminal(for: id)
        codexMonitor.removeObserver(for: id)
        claudeMonitor.removeObserver(for: id)
        store.removeAgent(id: id)
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

    private enum StateSource {
        case terminal
        case codex
        case claude
    }

    private func handleAgentStateChange(agentId: UUID, state: AgentState, source: StateSource) {
        guard let agent = store.agents.first(where: { $0.id == agentId }) else { return }

        // For Codex agents, terminal state is secondary to the monitor's runtime state.
        if agent.provider == .codex, source == .terminal {
            if state == .finished {
                store.updateState(id: agentId, state: state)
                return
            }
            if state == .active {
                let runtimeState = codexMonitor.runtimeStates[agentId]
                if runtimeState == .needsPermission || runtimeState == .awaitingInput
                    || codexMonitor.pendingApprovalRequests[agentId] != nil
                    || codexMonitor.pendingUserInputRequests[agentId] != nil {
                    return
                }
                store.updateState(id: agentId, state: .active)
                eventBus.publish(.agentActive(agentId: agentId))
            }
            return
        }

        // For Claude agents, the stream monitor is authoritative — ignore terminal state.
        if agent.provider == .claude, source == .terminal {
            return
        }

        store.updateState(id: agentId, state: state)
        if state == .awaitingInput {
            eventBus.publish(.agentIdle(agentId: agentId))
        } else if state == .active {
            eventBus.publish(.agentActive(agentId: agentId))
        }
    }
}
