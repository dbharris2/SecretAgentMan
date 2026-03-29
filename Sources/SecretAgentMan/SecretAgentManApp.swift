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
    @State private var branchNames: [String: String] = [:]
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activityMode: ActivityMode = .agents
    @State private var selectedPlanURL: URL?

    var body: some Scene {
        WindowGroup("Secret Agent Man") {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                ActivitySidebarView(
                    mode: $activityMode,
                    store: store,
                    branchNames: branchNames,
                    onRemoveAgent: removeAgent,
                    selectedPlanURL: $selectedPlanURL
                )
            } content: {
                switch activityMode {
                case .agents:
                    ChangesView(changes: fileChanges, fullDiff: fullDiff)
                case .plans:
                    if let url = selectedPlanURL {
                        PlanDetailView(url: url)
                    } else {
                        ContentUnavailableView(
                            "No Plan Selected",
                            systemImage: "doc.text",
                            description: Text("Select a plan from the sidebar")
                        )
                    }
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
            SettingsView(terminalManager: terminalManager, shellManager: shellManager)
        }
        .commands {
            CommandMenu("Agents") {
                let orderedAgents = store.agentsByFolder.flatMap(\.agents)
                ForEach(Array(orderedAgents.prefix(9).enumerated()), id: \.element.id) { index, agent in
                    Button(agent.name) {
                        activityMode = .agents
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
                refreshBranchNames()
            }
        }
    }

    private func refreshBranchNames() {
        let folders = Set(store.agents.map { $0.folder })
        for folder in folders {
            Task {
                let name = await diffService.fetchBranchName(in: folder)
                let key = folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                await MainActor.run {
                    branchNames[key] = name
                }
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
