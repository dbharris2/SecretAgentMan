import SwiftUI

/// Agent terminal panel — wraps TerminalContainerView with agent process management.
struct TerminalPanelView: View {
    let selectedAgentId: UUID?
    let store: AgentStore
    let terminalManager: TerminalManager

    var body: some View {
        TerminalContainerView(
            label: "agent",
            selectedAgentId: selectedAgentId,
            store: store,
            terminalProvider: { agent in
                terminalManager.terminal(for: agent, onStateChange: { id, state in
                    Task { @MainActor in store.updateState(id: id, state: state) }
                })
            }
        )
    }
}
