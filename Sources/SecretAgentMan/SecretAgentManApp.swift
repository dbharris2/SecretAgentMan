import SwiftUI

@main
struct SecretAgentManApp: App {
    @State private var store = AgentStore()
    @State private var terminalManager = TerminalManager()
    @State private var shellManager = ShellManager()
    @State private var diffService = DiffService()
    @State private var fileChanges: [FileChange] = []
    @State private var fullDiff: String = ""
    @State private var fileWatcher = FileSystemWatcher()
    @State private var sessionWatcher = FileSystemWatcher()
    @State private var prTimer: Timer?
    @State private var branchNames: [String: String] = [:]
    @State private var prInfos: [String: PRInfo] = [:]
    @State private var prService = PRService()
    @State private var eventBus = AgentEventBus()
    @State private var githubPRService = GitHubPRService()
    @State private var githubPRSections: [GitHubPRService.PRSection: [GitHubPRService.GitHubPR]] = [:]
    @State private var githubPRTimer: Timer?
    @State private var selectedGitHubPR: GitHubPRService.GitHubPR?
    @State private var selectedPRDiff: String = ""
    @State private var selectedPRChanges: [FileChange] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activityMode: ActivityMode = .agents
    @State private var selectedPlanURL: URL?
    @AppStorage("shellPanelVisible") private var isShellPanelVisible = false
    @AppStorage("shellPanelHeight") private var shellPanelHeight: Double = 200
    @State private var isAgentPanelVisible = true
    @AppStorage("agentPanelWidth") private var agentPanelWidth: Double = 500
    @AppStorage(UserDefaultsKeys.autoFixCIFailures) private var autoFixCI = true
    @AppStorage(UserDefaultsKeys.autoAnalyzeReviews) private var autoAnalyzeReviews = true

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
                            selectedPlanURL: $selectedPlanURL,
                            prSections: githubPRSections,
                            onReviewPR: reviewPR,
                            onSelectPR: selectPR,
                            selectedPRId: selectedGitHubPR?.id
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
                            case .prs:
                                if let pr = selectedGitHubPR {
                                    if selectedPRChanges.isEmpty, !selectedPRDiff.isEmpty {
                                        ChangesView(changes: selectedPRChanges, fullDiff: selectedPRDiff)
                                    } else if selectedPRChanges.isEmpty {
                                        VStack(spacing: 8) {
                                            ProgressView()
                                            Text("Loading diff for #\(pr.number)...")
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        ChangesView(changes: selectedPRChanges, fullDiff: selectedPRDiff)
                                    }
                                } else {
                                    VStack(spacing: 8) {
                                        Image("PRIcon")
                                            .resizable()
                                            .frame(width: 32, height: 32)
                                            .foregroundStyle(.secondary)
                                        Text("Select a PR from the sidebar")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
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
                        .overlay(alignment: .top) {
                            PendingPromptsBar(
                                store: store,
                                selectedAgentId: store.selectedAgentId,
                                onSend: { prompt in
                                    terminalManager.sendInput(to: prompt.agentId, text: prompt.fullPrompt)
                                }
                            )
                        }
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
                    setupFileWatcher()
                    startPRPolling()
                    startGitHubPRPolling()
                    terminalManager.onStateChange = { id, state in
                        store.updateState(id: id, state: state)
                        if state == .awaitingInput {
                            // Auto-send queued CI fix prompts when agent goes idle
                            let autoSendPrompts = store.pendingPrompts(for: id).filter(\.autoSend)
                            if let first = autoSendPrompts.first {
                                terminalManager.sendInput(to: id, text: first.fullPrompt)
                                store.removePendingPrompt(id: first.id)
                            }
                            eventBus.publish(.agentIdle(agentId: id))
                        } else if state == .active {
                            eventBus.publish(.agentActive(agentId: id))
                        }
                    }
                    eventBus.onSendPrompt = { agentId, prompt in
                        terminalManager.sendInput(to: agentId, text: prompt)
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
                    // Initial data load
                    refreshDiffs()
                    refreshBranchNames()
                }
                .onDisappear {
                    fileWatcher.unwatchAll()
                    sessionWatcher.unwatchAll()
                    prTimer?.invalidate()
                    githubPRTimer?.invalidate()
                }
                .onChange(of: store.agents.map(\.folder)) { oldFolders, newFolders in
                    let oldSet = Set(oldFolders)
                    let newSet = Set(newFolders)
                    for removed in oldSet.subtracting(newSet) {
                        fileWatcher.unwatch(directory: removed)
                        sessionWatcher.unwatch(
                            directory: SessionFileDetector.claudeProjectDir(for: removed)
                        )
                    }
                    for added in newSet.subtracting(oldSet) {
                        fileWatcher.watch(directory: added)
                        sessionWatcher.watch(
                            directory: SessionFileDetector.claudeProjectDir(for: added)
                        )
                    }
                }

                Divider()

                StatusBarView(
                    mode: $activityMode,
                    store: store,
                    branchNames: branchNames,
                    isShellPanelVisible: $isShellPanelVisible,
                    isAgentPanelVisible: $isAgentPanelVisible,
                    shellManager: shellManager
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
            CommandMenu("Debug") {
                Button("Test Pending Prompt") {
                    if let id = store.selectedAgentId {
                        store.addPendingPrompt(PendingPrompt(
                            agentId: id,
                            source: .ciFailed,
                            summary: "Test: multi-line prompt",
                            fullPrompt: """
                            This is a test multi-line prompt.

                            Line 2: Please confirm you received this as a single message.
                            Line 3: If you see this all at once, bracketed paste is working.

                            Just say "received" and nothing else.
                            """
                        ))
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
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

    private func setupFileWatcher() {
        fileWatcher.onDirectoryChanged = { changedFolder in
            refreshBranchName(for: changedFolder)
            eventBus.publish(.diffChanged(folder: changedFolder))
            if let selected = store.selectedAgent,
               selected.folder.standardizedFileURL == changedFolder {
                refreshDiffs()
            }
        }
        fileWatcher.onVCSMetadataChanged = { changedFolder in
            refreshBranchName(for: changedFolder)
            eventBus.publish(.branchChanged(folder: changedFolder))
        }
        for folder in Set(store.agents.map(\.folder)) {
            fileWatcher.watch(directory: folder)
        }
        setupSessionWatcher()
    }

    private func setupSessionWatcher() {
        sessionWatcher.onDirectoryChanged = { _ in
            // Only update agents whose session file no longer exists
            // (Claude Code replaced it with a new session)
            for agent in store.agents {
                guard let sessionId = agent.sessionId,
                      !SessionFileDetector.sessionFileExists(sessionId, for: agent.folder),
                      let actual = SessionFileDetector.latestSessionId(for: agent.folder)
                else { continue }
                store.updateSessionId(id: agent.id, sessionId: actual)
            }
        }
        // Watch each agent's Claude project directory
        for folder in Set(store.agents.map(\.folder)) {
            let projectDir = SessionFileDetector.claudeProjectDir(for: folder)
            sessionWatcher.watch(directory: projectDir)
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
                    let oldInfo = prInfos[key]
                    if oldInfo != info {
                        if let info {
                            prInfos[key] = info
                            detectPRTransitions(
                                folder: folder, old: oldInfo, new: info
                            )
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
        for folder in folders {
            refreshBranchName(for: folder)
        }
    }

    private func refreshBranchName(for folder: URL) {
        Task {
            let name = await diffService.fetchBranchName(in: folder)
            let key = Self.folderKey(folder)
            await MainActor.run {
                if branchNames[key] != name {
                    branchNames[key] = name
                    DispatchQueue.main.async { refreshPRStatuses() }
                }
            }
        }
    }

    private func detectPRTransitions(folder: URL, old: PRInfo?, new: PRInfo) {
        let agents = store.agents.filter { $0.folder.standardizedFileURL == folder.standardizedFileURL }
        guard !agents.isEmpty else { return }

        // CI checks went from non-fail to fail
        if autoFixCI, new.checkStatus == .fail, old?.checkStatus != .fail {
            eventBus.publish(.checksFailed(folder: folder))
            let checkNames = new.failedChecks.joined(separator: ", ")
            let prompt = """
            CI checks failed on PR #\(new.number). Failed checks: \(checkNames)

            Please investigate and fix the failures.
            """
            for agent in agents {
                let pending = PendingPrompt(
                    agentId: agent.id,
                    source: .ciFailed,
                    summary: "Failed: \(checkNames)",
                    fullPrompt: prompt
                )
                if agent.state == .awaitingInput {
                    terminalManager.sendInput(to: agent.id, text: prompt)
                } else {
                    store.addPendingPrompt(pending)
                }
            }
        }

        // CI checks passed — auto-dismiss stale CI prompts
        if new.checkStatus == .pass, old?.checkStatus == .fail {
            for agent in agents {
                store.removePendingPrompts(for: agent.id, source: .ciFailed)
            }
        }

        // Changes requested
        if autoAnalyzeReviews, new.state == .changesRequested, old?.state != .changesRequested {
            eventBus.publish(.changesRequested(folder: folder))
            let comments = new.reviewComments
                .filter { $0.state == .changesRequested }
                .map { "**\($0.author):** \($0.body)" }
                .joined(separator: "\n\n")
            let prompt = """
            PR #\(new.number) received review feedback requesting changes:

            \(comments)

            Summarize the feedback and suggest how you would address each point.
            Do NOT make any changes — just analyze and explain your approach.
            """
            for agent in agents {
                store.addPendingPrompt(PendingPrompt(
                    agentId: agent.id,
                    source: .changesRequested,
                    summary: "\(new.reviewComments.count) review comment(s)",
                    fullPrompt: prompt
                ))
            }
        }

        // Review approved — auto-dismiss changes requested prompts
        if new.state == .approved, old?.state == .changesRequested {
            for agent in agents {
                store.removePendingPrompts(for: agent.id, source: .changesRequested)
            }
        }

        // Approved with comments
        if autoAnalyzeReviews, new.state == .approved,
           !new.reviewComments.filter({ $0.state == .approved && !$0.body.isEmpty }).isEmpty {
            let approvalComments = new.reviewComments
                .filter { $0.state == .approved && !$0.body.isEmpty }
            // Only trigger if there are new comments we haven't seen
            let oldCommentCount = old?.reviewComments.count(where: { $0.state == .approved }) ?? 0
            if approvalComments.count > oldCommentCount {
                eventBus.publish(.approvedWithComments(folder: folder))
                let comments = approvalComments
                    .map { "**\($0.author):** \($0.body)" }
                    .joined(separator: "\n\n")
                let prompt = """
                PR #\(new.number) was approved with comments:

                \(comments)

                Summarize the comments. If any suggest changes, explain how you would address them.
                Do NOT make any changes — just analyze.
                """
                for agent in agents {
                    store.addPendingPrompt(PendingPrompt(
                        agentId: agent.id,
                        source: .approvedWithComments,
                        summary: "\(approvalComments.count) comment(s) on approval",
                        fullPrompt: prompt
                    ))
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

    private func startGitHubPRPolling() {
        refreshGitHubPRs()
        githubPRTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                refreshGitHubPRs()
            }
        }
    }

    private func refreshGitHubPRs() {
        Task {
            let sections = await githubPRService.fetchAllPRs()
            await MainActor.run {
                githubPRSections = sections
            }
        }
    }

    private func selectPR(_ pr: GitHubPRService.GitHubPR?) {
        selectedGitHubPR = pr
        selectedPRDiff = ""
        selectedPRChanges = []
        guard let pr else { return }
        Task {
            let diff = await githubPRService.fetchPRDiff(repo: pr.repository, number: pr.number)
            let changes = await diffService.parseChanges(from: diff)
            await MainActor.run {
                if selectedGitHubPR?.id == pr.id {
                    selectedPRDiff = diff
                    selectedPRChanges = changes
                }
            }
        }
    }

    private func reviewPR(_ pr: GitHubPRService.GitHubPR) {
        // Find an existing agent for this repo, or use the selected agent
        let repoFolder = store.agents.first { agent in
            agent.folderPath.contains(pr.repository.components(separatedBy: "/").last ?? "")
        }

        let targetAgent: Agent
        if let existing = repoFolder {
            targetAgent = existing
        } else if let selected = store.selectedAgent {
            targetAgent = selected
        } else {
            return
        }

        let prompt = """
        Review PR #\(pr.number) at \(pr.url.absoluteString)

        Run `gh pr diff \(pr.number) --repo \(pr.repository)` to see the full diff.
        Run `gh pr view \(pr.number) --repo \(pr.repository)` for the PR description.

        Provide a thorough code review covering:
        - Correctness and potential bugs
        - Edge cases
        - Code style and readability
        - Performance concerns
        - Any suggestions for improvement

        Do NOT post comments to GitHub. Just provide your analysis here.
        """

        store.addPendingPrompt(PendingPrompt(
            agentId: targetAgent.id,
            source: .reviewPR,
            summary: "Diff review: \(pr.repository) #\(pr.number)",
            fullPrompt: prompt
        ))

        // Switch to the target agent
        activityMode = .agents
        store.selectedAgentId = targetAgent.id
    }
}
