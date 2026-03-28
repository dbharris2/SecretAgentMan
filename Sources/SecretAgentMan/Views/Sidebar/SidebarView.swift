import SwiftUI

struct SidebarView: View {
    @Bindable var store: AgentStore
    var onRemoveAgent: (UUID) -> Void
    @State private var showingNewAgent = false
    @State private var renamingAgentId: UUID?
    @State private var renameText = ""

    var body: some View {
        List(selection: $store.selectedAgentId) {
            ForEach(store.agentsByFolder, id: \.folder) { group in
                Section(group.folder) {
                    ForEach(group.agents) { agent in
                        AgentRowView(agent: agent, isSelected: store.selectedAgentId == agent.id)
                            .tag(agent.id)
                            .contextMenu {
                                Button("Rename...") {
                                    renameText = agent.name
                                    renamingAgentId = agent.id
                                }
                                Divider()
                                Button("Remove", role: .destructive) {
                                    onRemoveAgent(agent.id)
                                }
                            }
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
            NewAgentSheet(store: store, isPresented: $showingNewAgent)
        }
        .alert("Rename Agent", isPresented: Binding(
            get: { renamingAgentId != nil },
            set: { if !$0 { renamingAgentId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingAgentId = nil }
            Button("Rename") {
                if let id = renamingAgentId, !renameText.isEmpty {
                    store.renameAgent(id: id, name: renameText)
                }
                renamingAgentId = nil
            }
        }
    }
}
