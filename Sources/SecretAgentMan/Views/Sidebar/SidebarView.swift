import SwiftUI

struct SidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var selectedPlanURL: URL?
    @State private var showingNewAgent = false
    @State private var renamingAgentId: UUID?
    @State private var renameText = ""

    private var sortedAgents: [Agent] {
        coordinator.store.agents.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        @Bindable var store = coordinator.store
        List(selection: $store.selectedAgentId) {
            ForEach(sortedAgents) { agent in
                AgentRowView(
                    agent: agent,
                    isSelected: coordinator.store.selectedAgentId == agent.id,
                    pendingPromptCount: coordinator.store.pendingPrompts(for: agent.id).count,
                    branchName: coordinator.repositoryMonitor.branchNames[agent.folderPath],
                    prInfo: coordinator.prStore.prInfos[agent.folderPath]
                )
                .tag(agent.id)
                .contextMenu {
                    Button("Rename...") {
                        renameText = agent.name
                        renamingAgentId = agent.id
                    }
                    Divider()
                    Button("Remove", role: .destructive) {
                        coordinator.removeAgent(agent.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .toolbar {
            ToolbarItem {
                Button {
                    showingNewAgent = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Agent (Cmd+N)")
                .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $showingNewAgent) {
            NewAgentSheet(store: coordinator.store, isPresented: $showingNewAgent)
        }
        .alert("Rename Agent", isPresented: Binding(
            get: { renamingAgentId != nil },
            set: { if !$0 { renamingAgentId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingAgentId = nil }
            Button("Rename") {
                if let id = renamingAgentId, !renameText.isEmpty {
                    coordinator.store.renameAgent(id: id, name: renameText)
                }
                renamingAgentId = nil
            }
        }
    }
}
