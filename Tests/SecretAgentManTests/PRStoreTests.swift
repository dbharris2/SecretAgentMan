import Foundation
@testable import SecretAgentMan
import Testing

@MainActor
struct PRStoreTests {
    @Test
    func reviewPRCreatesReviewAgentWithInitialPromptWithoutChangingSelection() throws {
        let store = AgentStore(loadFromDisk: false)
        let existingAgent = Agent(
            name: "Existing",
            folder: URL(fileURLWithPath: "/tmp/project"),
            provider: .claude,
            sessionId: "existing-session"
        )
        store.agents = [existingAgent]
        store.selectedAgentId = existingAgent.id

        let prStore = makeStore(store: store)
        let pr = makePR(repository: "acme/project", number: 42)

        prStore.reviewPR(pr)

        #expect(store.agents.count == 2)
        #expect(store.selectedAgentId == existingAgent.id)

        let reviewAgent = try #require(store.agents.last)
        #expect(reviewAgent.name == "PR #42 - Review")
        #expect(reviewAgent.initialPrompt?.contains("gh pr diff 42 --repo acme/project") == true)
    }

    @Test
    func reviewPRDoesNothingWhenNoMatchingAgentFolderExists() {
        let store = AgentStore(loadFromDisk: false)
        store.agents = [
            Agent(
                name: "Existing",
                folder: URL(fileURLWithPath: "/tmp/other-repo"),
                provider: .claude,
                sessionId: "existing-session"
            )
        ]
        store.selectedAgentId = store.agents.first?.id

        let prStore = makeStore(store: store)

        prStore.reviewPR(makePR(repository: "acme/project", number: 7))

        #expect(store.agents.count == 1)
    }

    @Test
    func selectPRWithNilClearsSelectedPRState() {
        let store = AgentStore(loadFromDisk: false)
        let prStore = makeStore(store: store)

        prStore.selectedGitHubPR = makePR(repository: "acme/project", number: 99)
        prStore.selectedPRDiff = "diff --git a/file b/file"
        prStore.selectedPRChanges = [
            FileChange(id: "file", path: "file", insertions: 1, deletions: 0, status: .modified)
        ]

        prStore.selectPR(nil)

        #expect(prStore.selectedGitHubPR == nil)
        #expect(prStore.selectedPRDiff.isEmpty)
        #expect(prStore.selectedPRChanges.isEmpty)
    }

    @Test
    func repositoryMonitorTracksRepoTypesForJJGraphiteAndGitFolders() async throws {
        let store = AgentStore(loadFromDisk: false)
        let root = try makeTemporaryDirectory()
        let jjFolder = root.appendingPathComponent("jj-repo", isDirectory: true)
        let graphiteFolder = root.appendingPathComponent("graphite-repo", isDirectory: true)
        let gitFolder = root.appendingPathComponent("git-repo", isDirectory: true)

        try FileManager.default.createDirectory(at: jjFolder.appendingPathComponent(".jj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: graphiteFolder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitFolder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: graphiteFolder.appendingPathComponent(".git/.graphite_repo_config").path,
            contents: Data()
        )

        _ = store.addAgent(name: "JJ", folder: jjFolder)
        _ = store.addAgent(name: "Graphite", folder: graphiteFolder)
        _ = store.addAgent(name: "Git", folder: gitFolder)

        let monitor = RepositoryMonitor(store: store)
        defer { monitor.stop() }

        monitor.start()

        try await assertEventually {
            monitor.vcsType(for: jjFolder) == .jj
                && monitor.vcsType(for: graphiteFolder) == .graphite
                && monitor.vcsType(for: gitFolder) == .git
        }
    }

    private func makeStore(store: AgentStore) -> PRStore {
        let repositoryMonitor = RepositoryMonitor(store: store)
        return PRStore(
            store: store,
            eventBus: AgentEventBus(loadFromDisk: false),
            repositoryMonitor: repositoryMonitor
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func assertEventually(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        Issue.record("Condition was not satisfied before timeout")
        throw CancellationError()
    }

    private func makePR(repository: String, number: Int) -> GitHubPRService.GitHubPR {
        GitHubPRService.GitHubPR(
            id: "pr-\(number)",
            number: number,
            title: "PR \(number)",
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            repository: repository,
            headRefName: "feature-\(number)",
            authorLogin: "devon",
            authorAvatarURL: nil,
            additions: 10,
            deletions: 2,
            changedFiles: 3,
            commentCount: 1,
            reviewDecision: nil,
            isDraft: false,
            mergeStateStatus: "CLEAN",
            updatedAt: Date(),
            reviewers: [],
            checkStatus: .pending,
            hasAnyApproval: false
        )
    }
}
