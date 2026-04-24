import SwiftUI

/// Shared chrome for a per-agent session panel: the chat-divider-composer
/// stack plus the panel-level lifecycle (Ctrl+C interrupt, ensureSession on
/// appear and on agent change, focus-composer notification).
///
/// Provider-specific content lives in the `chat` and `composer` slots; this
/// shell intentionally does not own snapshot reads or provider actions.
struct SessionPanelShell<Chat: View, Composer: View>: View {
    let agent: Agent
    var composerFocused: FocusState<Bool>.Binding
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let composer: () -> Composer

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            chat()
            Divider()
            composer()
        }
        .background(theme.background)
        .id(agent.id)
        .onKeyPress(phases: .down) { keyPress in
            if keyPress.key == .init("c"), keyPress.modifiers.contains(.control) {
                coordinator.interruptAgent(for: agent.id)
                return .handled
            }
            return .ignored
        }
        .onAppear {
            coordinator.ensureSession(for: agent)
        }
        .onChange(of: agent.id) { _, _ in
            coordinator.ensureSession(for: agent)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusComposer)) { _ in
            composerFocused.wrappedValue = true
        }
    }
}
