import SwiftUI

struct StatusBarView: View {
    @Binding var mode: ActivityMode
    @Bindable var store: AgentStore
    var branchNames: [String: String]
    @Binding var isShellPanelVisible: Bool
    @Binding var isAgentPanelVisible: Bool

    @State private var showingMCPPopover = false
    @State private var showingPluginsPopover = false

    private var selectedAgent: Agent? {
        store.selectedAgent
    }

    private var mcpServers: [String] {
        guard let agent = selectedAgent else { return [] }
        return MCPConfigLoader.loadServerNames(in: agent.folder)
    }

    private var plugins: [String] {
        MCPConfigLoader.loadPluginNames()
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left: navigation icons
            HStack(spacing: 2) {
                activityButton(icon: "person.2", targetMode: .agents, label: "Agents")
                activityButton(icon: "doc.text", targetMode: .plans, label: "Plans")
            }

            Divider()
                .frame(height: 16)

            // Center-left: per-agent context
            HStack(spacing: 10) {
                // MCP servers
                Button {
                    showingMCPPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 10))
                        Text(verbatim: "\(mcpServers.count) MCP")
                            .font(.system(size: 11))
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

                // Plugins
                Button {
                    showingPluginsPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 10))
                        Text(verbatim: "\(plugins.count) Plugins")
                            .font(.system(size: 11))
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
            }

            Spacer()

            // Right: panel toggles + agent info
            Button {
                isShellPanelVisible.toggle()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(isShellPanelVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Terminal (Cmd+J)")

            Button {
                isAgentPanelVisible.toggle()
            } label: {
                Image(systemName: "sparkle")
                    .font(.system(size: 11))
                    .foregroundStyle(isAgentPanelVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Agent Panel")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 8)

            // Agent info
            if let agent = selectedAgent {
                HStack(spacing: 8) {
                    if let branch = branchNames[agent.folderPath] {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                            Text(branch)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    if let sessionId = agent.sessionId {
                        Text(verbatim: sessionId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    private func activityButton(icon: String, targetMode: ActivityMode, label: String) -> some View {
        Button {
            mode = targetMode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 24, height: 20)
                .foregroundStyle(mode == targetMode ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func popoverList(title: String, items: [String], emptyMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Divider()
            if items.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text(item)
                            .font(.system(size: 12))
                    }
                }
            }
        }
        .padding(10)
        .frame(minWidth: 180)
    }
}
