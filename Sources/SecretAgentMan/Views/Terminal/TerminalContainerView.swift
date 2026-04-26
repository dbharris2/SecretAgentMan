import SwiftTerm
import SwiftUI

/// A reusable NSViewRepresentable container that swaps terminal views when
/// the terminal identity changes. Identity is a neutral string (e.g. a folder
/// path) so the same terminal can be reused across agents that share it.
///
/// IMPORTANT: This view takes a pre-resolved `terminal` and `terminalIdentity`
/// from @State in the parent view. Do NOT read @Observable properties (like
/// `store.agents`) in body or updateNSView — doing so creates an AttributeGraph
/// cycle when combined with non-comparable reference-type parameters.
struct TerminalContainerView: NSViewRepresentable {
    let terminalIdentity: String?
    let terminal: LocalProcessTerminalView?
    var onEmbed: ((LocalProcessTerminalView) -> Void)?

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView(frame: .zero)
        if let terminal {
            Self.embed(terminal, in: container)
            context.coordinator.currentIdentity = terminalIdentity
            context.coordinator.currentTerminal = terminal
            container.pendingFocusTerminal = terminal
            container.onEmbed = onEmbed
        }
        return container
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        container.onEmbed = onEmbed

        let newIdentity = terminalIdentity
        let oldIdentity = context.coordinator.currentIdentity

        guard let terminal else {
            if newIdentity != oldIdentity || context.coordinator.currentTerminal != nil {
                for subview in container.subviews {
                    subview.removeFromSuperview()
                }
                context.coordinator.currentIdentity = newIdentity
                context.coordinator.currentTerminal = nil
                container.pendingFocusTerminal = nil
            }
            return
        }

        // Re-embed if identity changed or terminal instance changed.
        guard newIdentity != oldIdentity || terminal !== context.coordinator.currentTerminal else { return }

        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        context.coordinator.currentIdentity = newIdentity
        context.coordinator.currentTerminal = terminal

        Self.embed(terminal, in: container)

        if terminal.window != nil {
            onEmbed?(terminal)
        } else {
            container.pendingFocusTerminal = terminal
        }
    }

    private static func embed(_ terminal: LocalProcessTerminalView, in container: NSView) {
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
        var currentIdentity: String?
        weak var currentTerminal: LocalProcessTerminalView?
    }
}

/// NSView subclass that fires the onEmbed callback once the terminal
/// has a window, solving the first-launch focus timing problem.
final class TerminalHostView: NSView {
    var pendingFocusTerminal: LocalProcessTerminalView?
    var onEmbed: ((LocalProcessTerminalView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let terminal = pendingFocusTerminal {
            pendingFocusTerminal = nil
            onEmbed?(terminal)
        }
    }
}
