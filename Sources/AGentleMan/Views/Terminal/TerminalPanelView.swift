import SwiftTerm
import SwiftUI

/// A stable container that swaps terminal views when the selected agent changes.
/// This avoids SwiftUI recreating the NSView on every agent switch.
struct TerminalPanelView: NSViewRepresentable {
    let selectedAgentId: UUID?
    let store: AgentStore
    let terminalManager: TerminalManager

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        if let agentId = selectedAgentId, let agent = store.agents.first(where: { $0.id == agentId }) {
            let terminal = terminalManager.terminal(for: agent, onStateChange: { id, state in
                Task { @MainActor in store.updateState(id: id, state: state) }
            })
            embed(terminal, in: container)
            context.coordinator.currentAgentId = agentId
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let newId = selectedAgentId
        let oldId = context.coordinator.currentAgentId

        guard newId != oldId else { return }

        // Detach old terminal (don't destroy — TerminalManager keeps it alive)
        for subview in container.subviews {
            subview.removeFromSuperview()
        }

        context.coordinator.currentAgentId = newId

        guard let agentId = newId, let agent = store.agents.first(where: { $0.id == agentId }) else {
            return
        }

        let terminal = terminalManager.terminal(for: agent, onStateChange: { id, state in
            Task { @MainActor in store.updateState(id: id, state: state) }
        })
        embed(terminal, in: container)

        // Give focus to the new terminal
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(terminal)
        }
    }

    private func embed(_ terminal: MonitoredTerminalView, in container: NSView) {
        // Remove from previous parent if reparenting
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
