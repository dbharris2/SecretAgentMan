import SwiftUI

/// Shell terminal panel — wraps TerminalContainerView with the user's login shell.
struct ShellPanelView: View {
    let selectedAgentId: UUID?
    let store: AgentStore
    let shellManager: ShellManager

    var body: some View {
        TerminalContainerView(
            label: "shell",
            selectedAgentId: selectedAgentId,
            store: store,
            terminalProvider: { agent in
                shellManager.terminal(for: agent)
            }
        )
    }
}
