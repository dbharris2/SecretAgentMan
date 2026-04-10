import SwiftUI

struct StatusBarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appTheme) private var theme
    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false

    @State private var showingMCPPopover = false
    @State private var showingPluginsPopover = false
    @State private var showingScriptsPopover = false
    @State private var showingSkillsPopover = false
    @State private var showingSessionPopover = false
    @State private var showingUsagePopover = false

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
        let openSessionIds = coordinator.store.openSessionIds(for: agent)
        return SessionFileDetector.availableSessions(for: agent)
            .filter { !openSessionIds.contains($0.id) }
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        let mcpServers = mcpServers
        let plugins = plugins
        let scripts = scripts
        let skills = skills
        let sessions = sessions

        HStack(spacing: 8) {
            // Left: navigation toggles
            HStack(spacing: 8) {
                panelToggleButton(icon: "doc.text", panel: .plans, label: "Plans")
                panelToggleImageButton(image: "PRIcon", panel: .prs, label: "Pull Requests")
                panelToggleButton(icon: "exclamationmark.circle", panel: .issues, label: "Issues")
            }

            Divider()
                .frame(height: 16)

            // Center-left: per-agent context
            HStack(spacing: 10) {
                popoverButton(isPresented: $showingMCPPopover, help: "MCP Servers") {
                    HStack(spacing: 3) {
                        Image(systemName: "server.rack")
                            .scaledFont(size: 10)
                        Text(verbatim: "\(mcpServers.count) MCP")
                            .scaledFont(size: 11)
                    }
                    .foregroundStyle(mcpServers.isEmpty ? .secondary : .primary)
                }
                .popover(isPresented: $showingMCPPopover) {
                    popoverList(
                        title: "MCP Servers",
                        items: mcpServers,
                        emptyMessage: "No MCP servers configured"
                    )
                }

                popoverButton(isPresented: $showingPluginsPopover, help: "Plugins") {
                    HStack(spacing: 3) {
                        Image(systemName: "puzzlepiece.extension")
                            .scaledFont(size: 10)
                        Text(verbatim: "\(plugins.count) Plugins")
                            .scaledFont(size: 11)
                    }
                    .foregroundStyle(plugins.isEmpty ? .secondary : .primary)
                }
                .popover(isPresented: $showingPluginsPopover) {
                    popoverList(
                        title: "Plugins",
                        items: plugins,
                        emptyMessage: "No plugins installed"
                    )
                }

                popoverButton(isPresented: $showingSkillsPopover, help: "Skills") {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .scaledFont(size: 10)
                        Text(verbatim: "\(skills.count) Skills")
                            .scaledFont(size: 11)
                    }
                    .foregroundStyle(skills.isEmpty ? .secondary : .primary)
                }
                .popover(isPresented: $showingSkillsPopover) {
                    SkillsPopover(skills: skills) { skill in
                        showingSkillsPopover = false
                        sendSkill(skill)
                    }
                }

                popoverButton(isPresented: $showingScriptsPopover, help: "Project Scripts") {
                    HStack(spacing: 3) {
                        Image(systemName: "play.rectangle")
                            .scaledFont(size: 10)
                        Text(verbatim: "\(scripts.count) Scripts")
                            .scaledFont(size: 11)
                    }
                    .foregroundStyle(scripts.isEmpty ? .secondary : .primary)
                }
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
                    .foregroundStyle(isShellPanelVisible ? theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Terminal (Cmd+J)")
            .statusBarPill(isSelected: isShellPanelVisible)

            Button {
                coordinator.isAgentPanelVisible.toggle()
            } label: {
                Image(systemName: "sparkle")
                    .scaledFont(size: 11)
                    .foregroundStyle(
                        coordinator.isAgentPanelVisible ? theme.accent : .secondary
                    )
            }
            .buttonStyle(.plain)
            .help("Toggle Agent Panel")
            .statusBarPill(isSelected: coordinator.isAgentPanelVisible)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 8)

            if let agent = selectedAgent {
                HStack(spacing: 8) {
                    if agent.provider == .codex,
                       let limits = coordinator.usageMonitor.rateLimits[agent.provider] {
                        popoverButton(isPresented: $showingUsagePopover, help: "API Usage") {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(usageColor(for: limits.shortWindow.usedPercent))
                                    .frame(width: 6, height: 6)
                                Text(verbatim: "\(Int(limits.shortWindow.usedPercent))%")
                                    .scaledFont(size: 11)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .popover(isPresented: $showingUsagePopover) {
                            UsagePopover(limits: limits, provider: agent.provider)
                        }
                    }

                    if let sessionId = agent.sessionId {
                        popoverButton(isPresented: $showingSessionPopover, help: "Sessions") {
                            HStack(spacing: 4) {
                                providerIcon(for: agent.provider)

                                Text(verbatim: sessionId)
                                    .scaledFont(size: 10, design: .monospaced)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Copy Session ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sessionId, forType: .string)
                            }
                        }
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
        .background(theme.surface)
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
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .scaledFont(size: 11)
                Text(label)
                    .scaledFont(size: 11)
            }
            .frame(height: 20)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(label)
        .statusBarPill(isSelected: coordinator.activeSidebarPanel == panel)
    }

    private func panelToggleImageButton(image: String, panel: SidebarPanel, label: String)
        -> some View {
        Button {
            coordinator.activeSidebarPanel = coordinator.activeSidebarPanel == panel ? nil : panel
        } label: {
            HStack(spacing: 4) {
                Image(image)
                    .resizable()
                    .frame(width: 12, height: 12)
                Text(label)
                    .scaledFont(size: 11)
            }
            .frame(height: 20)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(label)
        .statusBarPill(isSelected: coordinator.activeSidebarPanel == panel)
    }

    private func popoverButton(
        isPresented: Binding<Bool>,
        help: String,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button {
            isPresented.wrappedValue.toggle()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .help(help)
        .statusBarPill(isSelected: isPresented.wrappedValue)
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

    private func usageColor(for percent: Double) -> Color {
        if percent > 80 { return theme.red }
        if percent > 50 { return theme.yellow }
        return theme.green
    }

    @ViewBuilder
    private func providerIcon(for provider: AgentProvider) -> some View {
        switch provider {
        case .claude:
            Image("ClaudeIcon")
                .resizable()
                .frame(width: 12, height: 12)
        case .codex:
            Image("CodexIcon")
                .resizable()
                .frame(width: 12, height: 12)
        }
    }
}

private extension View {
    func statusBarPill(isSelected: Bool) -> some View {
        self
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .hoverHighlight(isSelected: isSelected)
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
                    title: "Start New \(agent.provider.displayName) Session",
                    subtitle: agent.folderPath
                )
            }
            .buttonStyle(.plain)

            Divider()

            if sessions.isEmpty {
                Text("No saved sessions found for this folder")
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
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
                .frame(maxHeight: 300)
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
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.green)
                .frame(width: 6, height: 6)
            Text(label)
                .scaledFont(size: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight()
    }
}

private struct UsagePopover: View {
    let limits: AgentRateLimits
    let provider: AgentProvider
    @Environment(\.appTheme) private var theme

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Usage — \(provider.displayName)")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)

            Divider()

            usageRow(limits.shortWindow)
            usageRow(limits.longWindow)
        }
        .padding(10)
        .frame(minWidth: 200)
    }

    private func usageRow(_ window: WindowUsage) -> some View {
        let percent = window.usedPercent
        let color: Color = percent > 80 ? theme.red : percent > 50 ? theme.yellow : theme.green

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(window.windowLabel) window")
                    .scaledFont(size: 11, weight: .medium)
                Spacer()
                Text(verbatim: "\(Int(percent))%")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * min(percent / 100, 1.0), height: 4)
                }
            }
            .frame(height: 4)

            if let resetsAt = window.resetsAt {
                let formatter =
                    if Calendar.current.isDate(resetsAt, inSameDayAs: Date()) {
                        Self.timeFormatter
                    } else {
                        Self.dateTimeFormatter
                    }
                Text("Resets at \(formatter.string(from: resetsAt))")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
