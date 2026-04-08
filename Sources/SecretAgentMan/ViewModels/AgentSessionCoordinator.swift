import Foundation
import SwiftUI

@MainActor
final class AgentSessionCoordinator {
    let store: AgentStore
    let terminalManager: TerminalManager
    let shellManager: ShellManager
    let eventBus: AgentEventBus

    private var sessionWatcher = FileSystemWatcher()

    init(
        store: AgentStore = AgentStore(),
        terminalManager: TerminalManager = TerminalManager(),
        shellManager: ShellManager = ShellManager(),
        eventBus: AgentEventBus = AgentEventBus()
    ) {
        self.store = store
        self.terminalManager = terminalManager
        self.shellManager = shellManager
        self.eventBus = eventBus
    }

    func start() {
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
                terminalManager.restartAgent(agent) { agentId, state in
                    self.store.updateState(id: agentId, state: state)
                }
            }
        }

        sessionWatcher.onDirectoryChanged = { [self] _ in
            for agent in store.agents {
                guard let sessionId = agent.sessionId,
                      !SessionFileDetector.sessionFileExists(sessionId, for: agent),
                      let actual = SessionFileDetector.latestSessionId(for: agent)
                else { continue }
                store.updateSessionId(id: agent.id, sessionId: actual)
            }
        }

        syncSessionWatches()
    }

    func stop() {
        sessionWatcher.unwatchAll()
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
    }

    func removeAgent(_ id: UUID) {
        terminalManager.removeTerminal(for: id)
        shellManager.removeTerminal(for: id)
        store.removeAgent(id: id)
    }

    func sendPrompt(_ prompt: PendingPrompt) {
        terminalManager.sendInput(to: prompt.agentId, text: prompt.fullPrompt)
    }
}
