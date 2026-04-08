import SwiftUI

struct StatusBarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false

    @State private var showingMCPPopover = false
    @State private var showingPluginsPopover = false
    @State private var showingScriptsPopover = false
    @State private var showingSkillsPopover = false
    @State private var showingSessionPopover = false

    private var selectedAgent: Agent? {
        coordinator.store.selectedAgent
    }

    private var mcpServers: [String] {
        guard let agent = selectedAgent else { return [] }
        return MCPConfigLoader.loadServerNames(in: agent.folder)
    }

    private var plugins: [String] {
        guard let agent = selectedAgent else { return [] }
        return MCPConfigLoader.loadPluginNames(for: agent.provider)
    }

    private var scripts: [ProjectScript] {
        guard let agent = selectedAgent else { return [] }
        return ScriptDetector.detectScripts(in: agent.folder)
    }

    private var skills: [SkillInfo] {
        guard let agent = selectedAgent else { return [] }
        return MCPConfigLoader.loadSkills(in: agent.folder, provider: agent.provider)
    }

    private var sessions: [SessionFileDetector.SessionRecord] {
        guard let agent = selectedAgent else { return [] }
        return SessionFileDetector.availableSessions(for: agent)
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        let mcpServers = mcpServers
        let plugins = plugins
        let scripts = scripts
        let skills = skills
        let sessions = sessions

        HStack(spacing: 8) {
            // Left: navigation icons
            HStack(spacing: 2) {
                panelToggleButton(icon: "doc.text", panel: .plans, label: "Plans")
                panelToggleImageButton(image: "PRIcon", panel: .prs, label: "Pull Requests")
            }

            Divider()
                .frame(height: 16)

            // Center-left: per-agent context
            HStack(spacing: 10) {
                Button {
                    showingMCPPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "server.rack")
                            .scaledFont(size: 10)
                        Text(verbatim: "\(mcpServers.count) MCP")
                            .scaledFont(size: 11)
                    }
                    .foregroundStyle(mcpServers.isEmpty ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .help("MCP Servers")
                .popover(isPresented: $showingMCPPopover) {
                    popoverList(
                        title: "MCP Servers",
                        items: mcpServers,
                        emptyMessage: "No MCP servers configured"
                    )
                }

                Button {
                    showingPluginsPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "puzzlepiece.extension")
                            .scaledFont(size: 10)
                        Text(verbatim: "\(plugins.count) Plugins")
                            .scaledFont(size: 11)
                    }
                    .foregroundStyle(plugins.isEmpty ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .help("Plugins")
                .popover(isPresented: $showingPluginsPopover) {
                    popoverList(
                        title: "Plugins",
                        items: plugins,
                        emptyMessage: "No plugins installed"
                    )
                }

                Button {
                    showingSkillsPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .scaledFont(size: 10)
                        Text(verbatim: "\(skills.count) Skills")
                            .scaledFont(size: 11)
                    }
                    .foregroundStyle(skills.isEmpty ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .help("Skills")
                .popover(isPresented: $showingSkillsPopover) {
                    SkillsPopover(skills: skills) { skill in
                        showingSkillsPopover = false
                        sendSkill(skill)
                    }
                }

                Button {
                    showingScriptsPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.rectangle")
                            .scaledFont(size: 10)
                        Text(verbatim: "\(scripts.count) Scripts")
                            .scaledFont(size: 11)
                    }
                    .foregroundStyle(scripts.isEmpty ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .help("Project Scripts")
                .popover(isPresented: $showingScriptsPopover) {
                    ScriptRunnerPopover(scripts: scripts) { script in
                        showingScriptsPopover = false
                        runScript(script)
                    }
                }
            }

            Spacer()

            // Right: panel toggles + agent info
            Button {
                isShellPanelVisible.toggle()
            } label: {
                Image(systemName: "terminal")
                    .scaledFont(size: 11)
                    .foregroundStyle(isShellPanelVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Terminal (Cmd+J)")

            Button {
                coordinator.isAgentPanelVisible.toggle()
            } label: {
                Image(systemName: "sparkle")
                    .scaledFont(size: 11)
                    .foregroundStyle(
                        coordinator.isAgentPanelVisible ? Color.accentColor : .secondary
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle Agent Panel")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 8)

            if let agent = selectedAgent {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text(agent.provider.displayName)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                    }

                    if let branch = coordinator.repositoryMonitor.branchNames[agent.folderPath] {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .scaledFont(size: 10)
                            Text(branch)
                                .scaledFont(size: 11)
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    if let sessionId = agent.sessionId {
                        Button {
                            showingSessionPopover.toggle()
                        } label: {
                            Text(verbatim: sessionId)
                                .scaledFont(size: 10, design: .monospaced)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Sessions")
                        .popover(isPresented: $showingSessionPopover) {
                            SessionPopover(
                                agent: agent,
                                sessions: sessions,
                                onResume: { sessionId in
                                    showingSessionPopover = false
                                    _ = coordinator.store.addAgent(
                                        basedOn: agent,
                                        sessionChoice: .resume(sessionId: sessionId)
                                    )
                                },
                                onStartNew: {
                                    showingSessionPopover = false
                                    _ = coordinator.store.addAgent(
                                        basedOn: agent,
                                        sessionChoice: .newSession
                                    )
                                }
                            )
                        }
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    private func sendSkill(_ skill: SkillInfo) {
        guard let agentId = coordinator.store.selectedAgentId else { return }
        coordinator.terminalManager.typeText(to: agentId, text: "/\(skill.name) ")
        coordinator.terminalManager.focusTerminal(for: agentId)
    }

    private func runScript(_ script: ProjectScript) {
        guard let agent = selectedAgent else { return }
        coordinator.shellManager.sendCommand(script.command, for: agent)
        isShellPanelVisible = true
    }

    private func panelToggleButton(icon: String, panel: SidebarPanel, label: String) -> some View {
        Button {
            coordinator.activeSidebarPanel = coordinator.activeSidebarPanel == panel ? nil : panel
        } label: {
            Image(systemName: icon)
                .scaledFont(size: 11)
                .frame(width: 24, height: 20)
                .foregroundStyle(
                    coordinator.activeSidebarPanel == panel ? Color.accentColor : .secondary
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func panelToggleImageButton(image: String, panel: SidebarPanel, label: String)
        -> some View {
        Button {
            coordinator.activeSidebarPanel = coordinator.activeSidebarPanel == panel ? nil : panel
        } label: {
            Image(image)
                .resizable()
                .frame(width: 12, height: 12)
                .foregroundStyle(
                    coordinator.activeSidebarPanel == panel ? Color.accentColor : .secondary
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func popoverList(title: String, items: [String], emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
            Divider()
            if items.isEmpty {
                Text(emptyMessage)
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { item in
                    PopoverRow(label: item)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 180)
    }
}

private struct SessionPopover: View {
    let agent: Agent
    let sessions: [SessionFileDetector.SessionRecord]
    let onResume: (String) -> Void
    let onStartNew: () -> Void

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .scaledFont(size: 12, weight: .medium)
                Text(agent.folderPath)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            Button {
                onStartNew()
            } label: {
                SessionActionRow(
                    icon: "plus.circle",
                    title: "Start New Session",
                    subtitle: "Create a new agent in \(agent.provider.displayName)"
                )
            }
            .buttonStyle(.plain)

            Divider()

            if sessions.isEmpty {
                Text("No saved sessions found for this folder")
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    Button {
                        onResume(session.id)
                    } label: {
                        SessionActionRow(
                            icon: "arrow.clockwise.circle",
                            title: session.id,
                            subtitle: sessionSubtitle(for: session)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 320)
    }

    private func sessionSubtitle(for session: SessionFileDetector.SessionRecord) -> String {
        guard let modifiedAt = session.modifiedAt else { return "Modified date unavailable" }
        return "Updated \(Self.formatter.localizedString(for: modifiedAt, relativeTo: Date()))"
    }
}

private struct SessionActionRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(size: 12)
                    .lineLimit(1)
                Text(subtitle)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight()
    }
}

private struct PopoverRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text(label)
                .scaledFont(size: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight()
    }
}
