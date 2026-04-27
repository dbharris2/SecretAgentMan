import AppKit
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

    private var groupedAgents: [AgentStore.FolderGroup] {
        coordinator.store.agentsByFolder
    }

    var body: some View {
        let collapsedSet = collapsedFolders
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                newAgentButton
                addFolderButton
            }
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
            HStack(spacing: Spacing.xl) {
                Image(systemName: "square.and.pencil")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)
                Text("New Agent")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.foreground)
                Spacer()
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.lg)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 0)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n")
        .help("New Agent (⌘N)")
    }

    private var addFolderButton: some View {
        Button {
            chooseAndAddFolder()
        } label: {
            Image(systemName: "folder.badge.plus")
                .scaledFont(size: 13)
                .foregroundStyle(theme.accent)
                .frame(width: 16, height: 16)
                .padding(.horizontal, Spacing.xxl)
                .padding(.vertical, Spacing.lg)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: 0)
        }
        .buttonStyle(.plain)
        .help("Add Folder")
    }

    private func agentList(collapsedSet: Set<String>) -> some View {
        List {
            ForEach(groupedAgents) { group in
                let isExpanded = folderExpandedBinding(for: group.key, in: collapsedSet)
                folderHeaderRow(group: group, isExpanded: isExpanded)
                if isExpanded.wrappedValue {
                    ForEach(group.agents) { agent in
                        agentRow(agent)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.surface)
    }

    private func folderHeaderRow(group: AgentStore.FolderGroup, isExpanded: Binding<Bool>) -> some View {
        HStack(spacing: Spacing.xl) {
            Image(systemName: folderIconName(isExpanded: isExpanded.wrappedValue, isEmpty: group.agents.isEmpty))
                .scaledFont(size: 13)
                .foregroundStyle(theme.accent)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(group.url.lastPathComponent)
                        .scaledFont(size: 13, weight: .bold)
                        .foregroundStyle(theme.foreground)
                    if group.agents.isEmpty {
                        Text("(empty)")
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                }

                if let branch = coordinator.repositoryMonitor.branchNames[group.key] {
                    BranchInfoView(branchName: branch)
                }
            }

            Spacer()

            Menu {
                folderMenuContents(group: group)
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
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 0)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.wrappedValue.toggle()
            }
        }
        .contextMenu {
            folderMenuContents(group: group)
        }
    }

    @ViewBuilder
    private func folderMenuContents(group: AgentStore.FolderGroup) -> some View {
        Button("New agent in folder") {
            newAgentPrefillFolder = group.url
            showingNewAgent = true
        }
        Divider()
        Button("Remove", role: .destructive) {
            removeFolder(folderURL: group.url, folderKey: group.key)
        }
    }

    private func agentRow(_ agent: Agent) -> some View {
        AgentRowView(
            agent: agent,
            isSelected: coordinator.store.selectedAgentId == agent.id
        )
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .onTapGesture {
            coordinator.store.selectAgent(id: agent.id)
        }
        .contextMenu {
            if let sessionId = agent.sessionId {
                Button("Copy session id") {
                    copyToPasteboard(sessionId)
                }
                Divider()
            }
            Button("Rename") {
                renameText = agent.name
                renamingAgentId = agent.id
            }
            Divider()
            Button("Remove", role: .destructive) {
                coordinator.removeAgent(agent.id)
            }
        }
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

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func removeFolder(folderURL: URL, folderKey: String) {
        coordinator.removeFolder(folderURL)

        var updated = collapsedFolders
        updated.remove(folderKey)
        collapsedFoldersStorage = updated.sorted().joined(separator: "\n")
    }

    private func chooseAndAddFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Add a project folder"

        if panel.runModal() == .OK, let url = panel.url {
            coordinator.store.addFolder(url)
        }
    }

    private func folderIconName(isExpanded: Bool, isEmpty: Bool) -> String {
        if isEmpty { return "folder" }
        return isExpanded ? "folder.fill" : "folder"
    }
}
