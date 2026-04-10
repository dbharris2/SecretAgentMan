import SwiftUI

@main
struct SecretAgentManApp: App {
    @State private var coordinator = AppCoordinator()
    @AppStorage(UserDefaultsKeys.terminalTheme) private var themeName = "Catppuccin Mocha"

    var body: some Scene {
        let appTheme = AppTheme.load(named: themeName)

        WindowGroup("Secret Agent Man") {
            ContentView()
                .environment(coordinator)
                .environment(\.fontScale, fontScale)
                .environment(\.appTheme, appTheme)
                .preferredColorScheme(appTheme.isDark ? .dark : .light)
                .onChange(of: fontScale) {
                    coordinator.terminalManager.applyFontToAll()
                    coordinator.shellManager.applyFontToAll()
                }
                .onChange(of: themeName) {
                    SyntaxHighlighter.setHighlightrTheme(AppTheme.load(named: themeName).highlightrTheme)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(
                terminalManager: coordinator.terminalManager,
                shellManager: coordinator.shellManager,
                reviewerGroupStore: coordinator.reviewerGroupStore
            )
        }
        .commands {
            CommandMenu("View") {
                Button(isShellPanelVisible ? "Hide Terminal" : "Show Terminal") {
                    isShellPanelVisible.toggle()
                }
                .keyboardShortcut("j")

                Divider()

                Button("Zoom In") {
                    fontScale = min(fontScale + 0.1, 2.0)
                }
                .keyboardShortcut("+")

                Button("Zoom Out") {
                    fontScale = max(fontScale - 0.1, 0.5)
                }
                .keyboardShortcut("-")

                Button("Reset Zoom") {
                    fontScale = 1.0
                }
                .keyboardShortcut("0")
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
                        coordinator.store.selectAgent(id: agent.id)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }

    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false
    @AppStorage(UserDefaultsKeys.fontScale) private var fontScale = 1.0
}
