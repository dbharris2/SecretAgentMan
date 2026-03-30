import SwiftUI

@main
struct SecretAgentManApp: App {
    @State private var store = AgentStore()
    @State private var terminalManager = TerminalManager()
    @State private var shellManager = ShellManager()
    @State private var diffService = DiffService()
    @State private var fileChanges: [FileChange] = []
    @State private var fullDiff: String = ""
    @State private var diffTimer: Timer?
    @State private var prTimer: Timer?
    @State private var branchNames: [String: String] = [:]
    @State private var prInfos: [String: PRInfo] = [:]
    @State private var prService = PRService()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activityMode: ActivityMode = .agents
    @State private var selectedPlanURL: URL?
    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false
    @AppStorage("shellPanelHeight") private var shellPanelHeight: Double = 200
    @State private var isAgentPanelVisible = true
    @AppStorage("agentPanelWidth") private var agentPanelWidth: Double = 500

    var body: some Scene {
        WindowGroup("Secret Agent Man") {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        ActivitySidebarView(
                            mode: $activityMode,
                            store: store,
                            branchNames: branchNames,
                            prInfos: prInfos,
                            onRemoveAgent: removeAgent,
                            selectedPlanURL: $selectedPlanURL
                        )
                    } detail: {
                        ZStack(alignment: .bottom) {
                            switch activityMode {
                            case .agents:
                                ChangesView(changes: fileChanges, fullDiff: fullDiff)
                            case .plans:
                                if let url = selectedPlanURL {
                                    PlanDetailView(url: url)
                                } else {
                                    ContentUnavailableView(
                                        "No Plan Selected",
                                        systemImage: "doc.text",
                                        description: Text("Select a plan from the sidebar")
                                    )
                                }
                            }

                            if isShellPanelVisible {
                                VStack(spacing: 0) {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.6))
                                        .frame(height: 3)
                                        .contentShape(Rectangle().size(width: 1000, height: 12))
                                        .gesture(
                                            DragGesture()
                                                .onChanged { value in
                                                    shellPanelHeight = max(100, shellPanelHeight - value.translation.height)
                                                }
                                        )
                                        .onHover { hovering in
                                            if hovering {
                                                NSCursor.resizeUpDown.push()
                                            } else {
                                                NSCursor.pop()
                                            }
                                        }
                                    ShellPanelView(
                                        selectedAgentId: store.selectedAgentId,
                                        store: store,
                                        shellManager: shellManager
                                    )
                                }
                                .frame(height: shellPanelHeight)
                            }
                        }
                    }

                    if isAgentPanelVisible {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: 3)
                            .contentShape(Rectangle().size(width: 12, height: 1000))
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        agentPanelWidth = max(300, agentPanelWidth - value.translation.width)
                                    }
                            )
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.resizeLeftRight.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }

                        TerminalPanelView(
                            selectedAgentId: store.selectedAgentId,
                            store: store,
                            terminalManager: terminalManager
                        )
                        .frame(width: agentPanelWidth)
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .frame(minWidth: 900, minHeight: 600)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        VersionBadgeView()
                    }
                }
                .onChange(of: store.selectedAgentId) {
                    refreshDiffs()
                    if let id = store.selectedAgentId {
                        UserDefaults.standard.set(id.uuidString, forKey: "selectedAgentId")
                    }
                }
                .onAppear {
                    startDiffPolling()
                    startPRPolling()
                    terminalManager.startMonitoring { id, state in
                        store.updateState(id: id, state: state)
                    }
                    terminalManager.onLaunched = { id in
                        store.markLaunched(id: id)
                    }
                    terminalManager.onSessionNotFound = { id in
                        store.resetSession(id: id)
                        if let agent = store.agents.first(where: { $0.id == id }) {
                            terminalManager.restartAgent(agent) { id, state in
                                store.updateState(id: id, state: state)
                            }
                        }
                    }
                }
                .onDisappear {
                    diffTimer?.invalidate()
                    prTimer?.invalidate()
                    terminalManager.stopMonitoring()
                }

                Divider()

                StatusBarView(
                    mode: $activityMode,
                    store: store,
                    branchNames: branchNames,
                    isShellPanelVisible: $isShellPanelVisible,
                    isAgentPanelVisible: $isAgentPanelVisible
                )
            } // VStack
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(terminalManager: terminalManager, shellManager: shellManager)
        }
        .commands {
            CommandMenu("View") {
                Button(isShellPanelVisible ? "Hide Terminal" : "Show Terminal") {
                    isShellPanelVisible.toggle()
                }
                .keyboardShortcut("j")
            }
            CommandMenu("Agents") {
                let orderedAgents = store.agentsByFolder.flatMap(\.agents)
                ForEach(Array(orderedAgents.prefix(9).enumerated()), id: \.element.id) { index, agent in
                    Button(agent.name) {
                        activityMode = .agents
                        store.selectedAgentId = agent.id
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }

    private func removeAgent(_ id: UUID) {
        terminalManager.removeTerminal(for: id)
        shellManager.removeTerminal(for: id)
        store.removeAgent(id: id)
    }

    private static func folderKey(_ folder: URL) -> String {
        folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func startDiffPolling() {
        diffTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                refreshDiffs()
                refreshBranchNames()
            }
        }
    }

    private func startPRPolling() {
        refreshPRStatuses()
        prTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task { @MainActor in
                refreshPRStatuses()
            }
        }
    }

    private func refreshPRStatuses() {
        let folders = Set(store.agents.map(\.folder))
        for folder in folders {
            Task {
                let info = await prService.fetchPRInfo(in: folder)
                let key = Self.folderKey(folder)
                await MainActor.run {
                    if prInfos[key] != info {
                        if let info {
                            prInfos[key] = info
                        } else {
                            prInfos.removeValue(forKey: key)
                        }
                    }
                }
            }
        }
    }

    private func refreshBranchNames() {
        let folders = Set(store.agents.map(\.folder))
        var anyChanged = false
        for folder in folders {
            Task {
                let name = await diffService.fetchBranchName(in: folder)
                let key = Self.folderKey(folder)
                await MainActor.run {
                    if branchNames[key] != name {
                        branchNames[key] = name
                        if !anyChanged {
                            anyChanged = true
                            // Defer PR refresh until next run loop tick to batch changes
                            DispatchQueue.main.async { refreshPRStatuses() }
                        }
                    }
                }
            }
        }
    }

    private func refreshDiffs() {
        guard let agent = store.selectedAgent else {
            fileChanges = []
            fullDiff = ""
            return
        }

        Task {
            let diff = await diffService.fetchFullDiff(in: agent.folder)
            let changes = await diffService.parseChanges(from: diff)
            await MainActor.run {
                fullDiff = diff
                fileChanges = changes
            }
        }
    }
}
