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

    private func makeStore(store: AgentStore) -> PRStore {
        let repositoryMonitor = RepositoryMonitor(store: store)
        return PRStore(
            store: store,
            eventBus: AgentEventBus(loadFromDisk: false),
            repositoryMonitor: repositoryMonitor
        )
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
