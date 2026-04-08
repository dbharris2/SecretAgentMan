import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedPlanURL: URL?
    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false
    @AppStorage("shellPanelHeight") private var shellPanelHeight: Double = 200
    @AppStorage("agentPanelWidth") private var agentPanelWidth: Double = 500

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    ActivitySidebarView(selectedPlanURL: $selectedPlanURL)
                } detail: {
                    ZStack(alignment: .bottom) {
                        if coordinator.activeSidebarPanel == .plans, let url = selectedPlanURL {
                            PlanDetailView(url: url)
                        } else if coordinator.activeSidebarPanel == .prs, let pr = coordinator.prStore.selectedGitHubPR {
                            if coordinator.prStore.selectedPRChanges.isEmpty, !coordinator.prStore.selectedPRDiff.isEmpty {
                                ChangesView(changes: coordinator.prStore.selectedPRChanges, fullDiff: coordinator.prStore.selectedPRDiff)
                            } else if coordinator.prStore.selectedPRChanges.isEmpty {
                                VStack(spacing: 8) {
                                    ProgressView()
                                    Text("Loading diff for #\(pr.number)...")
                                        .scaledFont(size: 13)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ChangesView(changes: coordinator.prStore.selectedPRChanges, fullDiff: coordinator.prStore.selectedPRDiff)
                            }
                        } else {
                            ChangesView(changes: coordinator.repositoryMonitor.fileChanges, fullDiff: coordinator.repositoryMonitor.fullDiff)
                        }

                        if isShellPanelVisible {
                            VStack(spacing: 0) {
                                ResizableDivider(size: $shellPanelHeight, minSize: 100, axis: .horizontal)
                                ShellPanelView(
                                    selectedAgentId: coordinator.store.selectedAgentId,
                                    store: coordinator.store,
                                    shellManager: coordinator.shellManager
                                )
                            }
                            .frame(height: shellPanelHeight)
                        }
                    }
                }

                if coordinator.isAgentPanelVisible {
                    ResizableDivider(size: $agentPanelWidth, minSize: 300, axis: .vertical)

                    TerminalPanelView(
                        selectedAgentId: coordinator.store.selectedAgentId,
                        store: coordinator.store,
                        terminalManager: coordinator.terminalManager
                    )
                    .overlay(alignment: .top) {
                        PendingPromptsBar(
                            store: coordinator.store,
                            selectedAgentId: coordinator.store.selectedAgentId,
                            onSend: { coordinator.sendPrompt($0) }
                        )
                    }
                    .frame(width: agentPanelWidth)
                }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 900, minHeight: 600)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    VersionBadgeView()
                }
            }
            .onChange(of: coordinator.store.selectedAgentId) {
                coordinator.invalidateDiffs()
                if let id = coordinator.store.selectedAgentId {
                    UserDefaults.standard.set(id.uuidString, forKey: "selectedAgentId")
                }
            }
            .onAppear {
                coordinator.start()
            }
            .onDisappear {
                coordinator.stop()
            }
            .onChange(of: coordinator.store.agents.map(\.folder)) { _, _ in
                coordinator.syncWatchedAgents()
            }
            .onChange(of: isShellPanelVisible) {
                if isShellPanelVisible, let id = coordinator.store.selectedAgentId {
                    DispatchQueue.main.async {
                        coordinator.shellManager.focusTerminal(for: id)
                    }
                }
            }

            Divider()

            StatusBarView()
        }
    }
}
