import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activeSidebarPanel: SidebarPanel?
    @State private var selectedPlanURL: URL?
    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false
    @AppStorage("shellPanelHeight") private var shellPanelHeight: Double = 200
    @State private var isAgentPanelVisible = true
    @AppStorage("agentPanelWidth") private var agentPanelWidth: Double = 500

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    ActivitySidebarView(
                        activePanel: $activeSidebarPanel,
                        store: coordinator.store,
                        branchNames: coordinator.branchNames,
                        prInfos: coordinator.prInfos,
                        onRemoveAgent: coordinator.removeAgent,
                        selectedPlanURL: $selectedPlanURL,
                        prSections: coordinator.githubPRSections,
                        onReviewPR: coordinator.reviewPR,
                        onSelectPR: coordinator.selectPR,
                        selectedPRId: coordinator.selectedGitHubPR?.id
                    )
                } detail: {
                    ZStack(alignment: .bottom) {
                        if activeSidebarPanel == .plans, let url = selectedPlanURL {
                            PlanDetailView(url: url)
                        } else if activeSidebarPanel == .prs, let pr = coordinator.selectedGitHubPR {
                            if coordinator.selectedPRChanges.isEmpty, !coordinator.selectedPRDiff.isEmpty {
                                ChangesView(changes: coordinator.selectedPRChanges, fullDiff: coordinator.selectedPRDiff)
                            } else if coordinator.selectedPRChanges.isEmpty {
                                VStack(spacing: 8) {
                                    ProgressView()
                                    Text("Loading diff for #\(pr.number)...")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ChangesView(changes: coordinator.selectedPRChanges, fullDiff: coordinator.selectedPRDiff)
                            }
                        } else {
                            ChangesView(changes: coordinator.fileChanges, fullDiff: coordinator.fullDiff)
                        }

                        if isShellPanelVisible {
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.6))
                                    .frame(height: 3)
                                    .contentShape(Rectangle().size(width: 1000, height: 12))
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                shellPanelHeight = max(100, shellPanelHeight - value.translation.height)
                                            }
                                    )
                                    .onHover { hovering in
                                        if hovering {
                                            NSCursor.resizeUpDown.push()
                                        } else {
                                            NSCursor.pop()
                                        }
                                    }
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

                if isAgentPanelVisible {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 3)
                        .contentShape(Rectangle().size(width: 12, height: 1000))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    agentPanelWidth = max(300, agentPanelWidth - value.translation.width)
                                }
                        )
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }

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
                coordinator.refreshDiffs()
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
            .onChange(of: coordinator.store.agents.map(\.folder)) { oldFolders, newFolders in
                coordinator.handleAgentFoldersChanged(old: oldFolders, new: newFolders)
            }

            Divider()

            StatusBarView(
                activePanel: $activeSidebarPanel,
                store: coordinator.store,
                branchNames: coordinator.branchNames,
                isShellPanelVisible: $isShellPanelVisible,
                isAgentPanelVisible: $isAgentPanelVisible,
                shellManager: coordinator.shellManager
            )
        }
    }
}
