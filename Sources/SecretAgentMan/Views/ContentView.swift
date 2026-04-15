import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appTheme) private var theme
    @State private var selectedPlanURL: URL?
    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false
    @AppStorage("shellPanelHeight") private var shellPanelHeight: Double = 200
    @AppStorage("isLeftPanelVisible") private var isLeftPanelVisible = true
    @AppStorage("isRightPanelVisible") private var isRightPanelVisible = true
    @AppStorage("leftPanelWidth") private var leftPanelWidth: Double = 280
    @AppStorage("rightPanelWidth") private var rightPanelWidth: Double = 500
    /// Legacy key — migrated to `rightPanelWidth` on first launch post-upgrade.
    @AppStorage("agentPanelWidth") private var legacyAgentPanelWidth: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let maxLeftWidth = max(220, proxy.size.width / 3)
                let maxRightWidth = max(320, proxy.size.width * 2 / 3)
                let clampedLeftWidth = min(leftPanelWidth, maxLeftWidth)
                let clampedRightWidth = min(rightPanelWidth, maxRightWidth)

                HStack(spacing: 0) {
                    if isLeftPanelVisible {
                        ActivitySidebarView(selectedPlanURL: $selectedPlanURL)
                            .frame(width: clampedLeftWidth)
                        ResizableDivider(
                            size: $leftPanelWidth,
                            minSize: 220,
                            maxSize: maxLeftWidth,
                            axis: .vertical,
                            reverse: true
                        )
                    }

                    ZStack(alignment: .bottom) {
                        centerChat

                        if isShellPanelVisible {
                            VStack(spacing: 0) {
                                ResizableDivider(size: $shellPanelHeight, minSize: 100, axis: .horizontal)
                                ShellPanelView(
                                    selectedAgentId: coordinator.store.selectedAgentId,
                                    store: coordinator.store,
                                    shellManager: coordinator.shellManager
                                )
                            }
                            .frame(height: shellPanelHeight)
                        }
                    }
                    .frame(minWidth: 400)

                    if isRightPanelVisible {
                        ResizableDivider(
                            size: $rightPanelWidth,
                            minSize: 320,
                            maxSize: maxRightWidth,
                            axis: .vertical
                        )
                        ContextDetailView(selectedPlanURL: $selectedPlanURL)
                            .frame(width: clampedRightWidth)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(theme.background)
            .frame(minWidth: 900, minHeight: 600)
            .toolbarBackground(theme.surface, for: .windowToolbar)
            .toolbarColorScheme(theme.isDark ? .dark : .light, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        isLeftPanelVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Toggle Sidebar (⌘⇧[)")
                }

                ToolbarItem(placement: .automatic) {
                    OpenInEditorButton()
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isRightPanelVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help("Toggle Inspector (⌘⇧])")
                }
            }
            .onChange(of: coordinator.store.selectedAgentId) { _, _ in
                coordinator.invalidateDiffs()
                coordinator.usageMonitor.refreshSelectedAgent()
            }
            .onAppear {
                coordinator.start()
                migrateLegacyAgentPanelWidth()
            }
            .onDisappear {
                coordinator.stop()
            }
            .onChange(of: coordinator.store.agents.map(\.folder)) { _, _ in
                coordinator.syncWatchedAgents()
            }
            .onChange(of: isShellPanelVisible) {
                if isShellPanelVisible, let id = coordinator.store.selectedAgentId {
                    DispatchQueue.main.async {
                        coordinator.shellManager.focusTerminal(for: id)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleLeftPanel)) { _ in
                isLeftPanelVisible.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleRightPanel)) { _ in
                isRightPanelVisible.toggle()
            }

            Divider()

            StatusBarView()
        }
    }

    private var centerChat: some View {
        Group {
            if let agent = coordinator.store.selectedAgent {
                switch agent.provider {
                case .codex:
                    CodexSessionPanelView(agent: agent)
                case .claude:
                    ClaudeSessionPanelView(agent: agent)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .scaledFont(size: 28)
                        .foregroundStyle(.secondary)
                    Text("Select an agent to start chatting")
                        .scaledFont(size: 13)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            PendingPromptsBar(
                store: coordinator.store,
                selectedAgentId: coordinator.store.selectedAgentId,
                onSend: { coordinator.sendPrompt($0) }
            )
        }
    }

    private func migrateLegacyAgentPanelWidth() {
        // One-shot: if user had a customized agentPanelWidth and hasn't yet
        // customized the new rightPanelWidth, carry the value across.
        guard legacyAgentPanelWidth > 0 else { return }
        if rightPanelWidth == 500 {
            rightPanelWidth = legacyAgentPanelWidth
        }
        legacyAgentPanelWidth = 0
    }
}

extension Notification.Name {
    static let toggleLeftPanel = Notification.Name("SecretAgentMan.toggleLeftPanel")
    static let toggleRightPanel = Notification.Name("SecretAgentMan.toggleRightPanel")
}
