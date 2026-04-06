import SwiftUI

struct SidebarView: View {
    @Bindable var store: AgentStore
    var branchNames: [String: String]
    var prInfos: [String: PRInfo]
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
                        AgentRowView(
                            agent: agent,
                            isSelected: store.selectedAgentId == agent.id,
                            pendingPromptCount: store.pendingPrompts(for: agent.id).count
                        )
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
                                .lineLimit(1)
                            if let branch = branchNames[group.folder] {
                                Text(branch)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            if let pr = prInfos[group.folder] {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(pr.state.color)
                                        .frame(width: 3, height: 14)
                                    Link(destination: pr.url) {
                                        Text(verbatim: "#\(pr.number)")
                                    }
                                    .font(.system(size: 11))
                                    .foregroundStyle(.blue)
                                    Text(verbatim: "+\(pr.additions)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.green)
                                    Text(verbatim: "-\(pr.deletions)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.red)
                                    Text(verbatim: "@\(pr.changedFiles)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    if pr.commentCount > 0 {
                                        HStack(spacing: 2) {
                                            Image(systemName: "bubble.left")
                                                .font(.system(size: 9))
                                            Text(verbatim: "\(pr.commentCount)")
                                                .font(.system(size: 10))
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                                    if pr.checkStatus != .none {
                                        Image(systemName: "flask.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(pr.checkStatus.color)
                                            .help(pr.checkStatus.label)
                                    }
                                    ForEach(pr.reviewers, id: \.self) { reviewer in
                                        AsyncImage(url: reviewer.avatarURL) { image in
                                            image.resizable()
                                        } placeholder: {
                                            Text(verbatim: String(reviewer.login.prefix(2)))
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundStyle(.white)
                                        }
                                        .frame(width: 18, height: 18)
                                        .background(Color.secondary.opacity(0.6))
                                        .clipShape(Circle())
                                        .help(reviewer.login)
                                    }
                                }
                            }
                        }
                        .textCase(nil)
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
