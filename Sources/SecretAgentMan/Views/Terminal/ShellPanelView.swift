import SwiftTerm
import SwiftUI

/// A stable container for a shell terminal that swaps when the selected agent changes.
/// Spawns the user's default shell in the agent's working directory.
struct ShellPanelView: NSViewRepresentable {
    let selectedAgentId: UUID?
    let store: AgentStore
    let shellManager: ShellManager

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        if let agentId = selectedAgentId, let agent = store.agents.first(where: { $0.id == agentId }) {
            let terminal = shellManager.terminal(for: agent)
            embed(terminal, in: container)
            context.coordinator.currentAgentId = agentId
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let newId = selectedAgentId
        let oldId = context.coordinator.currentAgentId

        guard newId != oldId else { return }

        for subview in container.subviews {
            subview.removeFromSuperview()
        }

        context.coordinator.currentAgentId = newId

        guard let agentId = newId, let agent = store.agents.first(where: { $0.id == agentId }) else {
            return
        }

        let terminal = shellManager.terminal(for: agent)
        embed(terminal, in: container)

        DispatchQueue.main.async {
            container.window?.makeFirstResponder(terminal)
        }
    }

    private func embed(_ terminal: LocalProcessTerminalView, in container: NSView) {
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var currentAgentId: UUID?
    }
}
