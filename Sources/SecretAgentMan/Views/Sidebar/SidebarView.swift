import SwiftUI

struct SidebarView: View {
    @Bindable var store: AgentStore
    var branchNames: [String: String]
    var onRemoveAgent: (UUID) -> Void
    @State private var showingNewAgent = false
    @State private var renamingAgentId: UUID?
    @State private var renameText = ""
    @State private var collapsedFolders: Set<String> = []

    var body: some View {
        List(selection: $store.selectedAgentId) {
            ForEach(store.agentsByFolder, id: \.folder) { group in
                Section(isExpanded: Binding(
                    get: { !collapsedFolders.contains(group.folder) },
                    set: { isExpanded in
                        if isExpanded {
                            collapsedFolders.remove(group.folder)
                        } else {
                            collapsedFolders.insert(group.folder)
                        }
                    }
                )) {
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
                } header: {
                    let isExpanded = !collapsedFolders.contains(group.folder)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: isExpanded ? "folder" : "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.folder)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .textCase(nil)
                                .lineLimit(1)
                            if let branch = branchNames[group.folder] {
                                Text(branch)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
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
