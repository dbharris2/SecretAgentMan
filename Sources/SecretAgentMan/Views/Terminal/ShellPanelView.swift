import SwiftTerm
import SwiftUI

/// Shell terminal panel — wraps TerminalContainerView with the user's login shell
/// for the selected agent's folder. Multiple agents in the same folder share one
/// shell instance; switching between them does not re-embed the terminal.
///
/// Same pattern as TerminalPanelView — terminal resolution in `onChange`/`onAppear`
/// to avoid AttributeGraph cycles from @Observable tracking in body evaluation.
struct ShellPanelView: View {
    let selectedAgentId: UUID?
    let store: AgentStore
    let shellManager: ShellManager

    @State private var displayedKey: String?
    @State private var displayedTerminal: LocalProcessTerminalView?

    var body: some View {
        TerminalContainerView(
            terminalIdentity: displayedKey,
            terminal: displayedTerminal,
            onEmbed: { terminal in
                terminal.window?.makeFirstResponder(terminal)
            }
        )
        .onAppear { syncTerminal() }
        .onChange(of: selectedAgentId) { _, _ in syncTerminal() }
        .onChange(of: store.agents.map(\.folder)) { _, _ in syncTerminal() }
    }

    private func syncTerminal() {
        guard let agentId = selectedAgentId,
              let agent = store.agents.first(where: { $0.id == agentId })
        else {
            displayedKey = nil
            displayedTerminal = nil
            return
        }
        displayedKey = ShellManager.shellKey(forFolder: agent.folder)
        displayedTerminal = shellManager.terminal(forFolder: agent.folder)
    }
}
