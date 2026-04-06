import SwiftUI

@main
struct SecretAgentManApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup("Secret Agent Man") {
            ContentView()
                .environment(coordinator)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(
                terminalManager: coordinator.terminalManager,
                shellManager: coordinator.shellManager
            )
        }
        .commands {
            CommandMenu("View") {
                Button(isShellPanelVisible ? "Hide Terminal" : "Show Terminal") {
                    isShellPanelVisible.toggle()
                }
                .keyboardShortcut("j")
            }
            CommandMenu("Debug") {
                Button("Test Pending Prompt") {
                    if let id = coordinator.store.selectedAgentId {
                        coordinator.store.addPendingPrompt(PendingPrompt(
                            agentId: id,
                            source: .ciFailed,
                            summary: "Test: multi-line prompt",
                            fullPrompt: """
                            This is a test multi-line prompt.

                            Line 2: Please confirm you received this as a single message.
                            Line 3: If you see this all at once, bracketed paste is working.

                            Just say "received" and nothing else.
                            """
                        ))
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandMenu("Agents") {
                let orderedAgents = coordinator.store.agentsByFolder.flatMap(\.agents)
                ForEach(Array(orderedAgents.prefix(9).enumerated()), id: \.element.id) { index, agent in
                    Button(agent.name) {
                        coordinator.store.selectedAgentId = agent.id
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }

    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false
}
