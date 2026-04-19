import SwiftUI

struct SidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appTheme) private var theme
    @Binding var selectedPlanURL: URL?
    @SceneStorage("collapsedAgentFolders") private var collapsedFoldersStorage = ""
    @State private var showingNewAgent = false
    @State private var newAgentPrefillFolder: URL?
    @State private var renamingAgentId: UUID?
    @State private var renameText = ""

    private var groupedAgents: [(folder: String, agents: [Agent])] {
        coordinator.store.agentsByFolder
    }

    var body: some View {
        let collapsedSet = collapsedFolders
        VStack(spacing: 0) {
            newAgentButton
            Divider()
            agentList(collapsedSet: collapsedSet)
        }
        .background(theme.surface)
        .frame(minWidth: 200)
        .sheet(isPresented: $showingNewAgent) {
            NewAgentSheet(store: coordinator.store, isPresented: $showingNewAgent, prefillFolder: $newAgentPrefillFolder)
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

    private var newAgentButton: some View {
        Button {
            newAgentPrefillFolder = nil
            showingNewAgent = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)
                Text("New Agent")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.foreground)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 0)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n")
        .help("New Agent (⌘N)")
    }

    private func agentList(collapsedSet: Set<String>) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedAgents, id: \.folder) { group in
                    let isExpanded = folderExpandedBinding(for: group.folder, in: collapsedSet)

                    HStack(spacing: 10) {
                        Image(systemName: isExpanded.wrappedValue ? "folder.fill" : "folder")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.accent)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.agents.first?.folderName ?? "")
                                .scaledFont(size: 13, weight: .bold)
                                .foregroundStyle(theme.foreground)

                            if let branch = coordinator.repositoryMonitor.branchNames[group.folder] {
                                BranchInfoView(branchName: branch)
                            }
                        }

                        Spacer()

                        Menu {
                            Button("New Agent in Folder...") {
                                newAgentPrefillFolder = group.agents.first?.folder
                                showingNewAgent = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .scaledFont(size: 13)
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: 0)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) {
                            isExpanded.wrappedValue.toggle()
                        }
                    }
                    .contextMenu {
                        Button("New Agent in Folder...") {
                            newAgentPrefillFolder = group.agents.first?.folder
                            showingNewAgent = true
                        }
                    }

                    if isExpanded.wrappedValue {
                        ForEach(group.agents) { agent in
                            AgentRowView(
                                agent: agent,
                                isSelected: coordinator.store.selectedAgentId == agent.id
                            )
                            .onTapGesture {
                                coordinator.store.selectAgent(id: agent.id)
                            }
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
                }
            }
        }
        .background(theme.surface)
    }

    private var collapsedFolders: Set<String> {
        Set(
            collapsedFoldersStorage
                .split(separator: "\n")
                .map(String.init)
        )
    }

    private func folderExpandedBinding(for folder: String, in collapsed: Set<String>) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(folder) },
            set: { isExpanded in
                var updated = collapsed
                if isExpanded {
                    updated.remove(folder)
                } else {
                    updated.insert(folder)
                }
                collapsedFoldersStorage = updated.sorted().joined(separator: "\n")
            }
        )
    }
}
