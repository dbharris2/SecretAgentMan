import SwiftUI

@main
struct SecretAgentManApp: App {
    @State private var store = AgentStore()
    @State private var terminalManager = TerminalManager()
    @State private var shellManager = ShellManager()
    @State private var diffService = DiffService()
    @State private var fileChanges: [FileChange] = []
    @State private var fullDiff: String = ""
    @State private var diffTimer: Timer?

    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                SidebarView(store: store, onRemoveAgent: removeAgent)
            } content: {
                if store.selectedAgent != nil {
                    ChangesView(changes: fileChanges, fullDiff: fullDiff)
                } else {
                    EmptyStateView()
                }
            } detail: {
                GeometryReader { geo in
                    VSplitView {
                        TerminalPanelView(
                            selectedAgentId: store.selectedAgentId,
                            store: store,
                            terminalManager: terminalManager
                        )
                        .frame(minHeight: 200, idealHeight: geo.size.height * 0.7)

                        ShellPanelView(
                            selectedAgentId: store.selectedAgentId,
                            store: store,
                            shellManager: shellManager
                        )
                        .frame(minHeight: 100, idealHeight: geo.size.height * 0.3)
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 900, minHeight: 600)
            .onChange(of: store.selectedAgentId) {
                refreshDiffs()
            }
            .onAppear {
                startDiffPolling()
                terminalManager.startMonitoring { id, state in
                    store.updateState(id: id, state: state)
                }
            }
            .onDisappear {
                diffTimer?.invalidate()
                terminalManager.stopMonitoring()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(terminalManager: terminalManager)
        }
        .commands {
            CommandMenu("Agents") {
                let orderedAgents = store.agentsByFolder.flatMap(\.agents)
                ForEach(Array(orderedAgents.prefix(9).enumerated()), id: \.element.id) { index, agent in
                    Button(agent.name) {
                        store.selectedAgentId = agent.id
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }

    private func removeAgent(_ id: UUID) {
        terminalManager.removeTerminal(for: id)
        shellManager.removeTerminal(for: id)
        store.removeAgent(id: id)
    }

    private func startDiffPolling() {
        diffTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                refreshDiffs()
            }
        }
    }

    private func refreshDiffs() {
        guard let agent = store.selectedAgent else {
            fileChanges = []
            fullDiff = ""
            return
        }

        Task {
            let diff = await diffService.fetchFullDiff(in: agent.folder)
            let changes = await diffService.parseChanges(from: diff)
            await MainActor.run {
                fullDiff = diff
                fileChanges = changes
            }
        }
    }
}
