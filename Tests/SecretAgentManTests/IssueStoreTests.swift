import Foundation
@testable import SecretAgentMan
import Testing

@MainActor
struct IssueStoreTests {
    @Test
    func workOnIssueCreatesAgentAndPendingPromptWithoutChangingSelection() throws {
        let store = AgentStore(loadFromDisk: false)
        let existingAgent = Agent(
            name: "Existing",
            folder: URL(fileURLWithPath: "/tmp/project"),
            provider: .claude,
            sessionId: "existing-session"
        )
        store.agents = [existingAgent]
        store.selectedAgentId = existingAgent.id

        let issueStore = IssueStore(store: store)
        let issue = makeIssue(repository: "acme/project", number: 12)

        issueStore.workOnIssue(issue)

        #expect(store.agents.count == 2)
        #expect(store.selectedAgentId == existingAgent.id)
        #expect(store.pendingPrompts.count == 1)

        let issueAgent = try #require(store.agents.last)
        let pendingPrompt = try #require(store.pendingPrompts.first)
        #expect(issueAgent.name == "Issue #12 - Fix the widget rendering bug")
        #expect(pendingPrompt.agentId == issueAgent.id)
        #expect(pendingPrompt.source == .workOnIssue)
        #expect(pendingPrompt.summary == "Work on: acme/project #12")
        #expect(pendingPrompt.fullPrompt.contains("gh issue view 12 --repo acme/project"))
    }

    @Test
    func workOnIssueDoesNothingWhenNoMatchingAgentFolderExists() {
        let store = AgentStore(loadFromDisk: false)
        store.agents = [
            Agent(
                name: "Existing",
                folder: URL(fileURLWithPath: "/tmp/other-repo"),
                provider: .claude,
                sessionId: "existing-session"
            ),
        ]
        store.selectedAgentId = store.agents.first?.id

        let issueStore = IssueStore(store: store)

        issueStore.workOnIssue(makeIssue(repository: "acme/project", number: 7))

        #expect(store.agents.count == 1)
        #expect(store.pendingPrompts.isEmpty)
    }

    @Test
    func selectIssueWithNilClearsSelectedState() {
        let store = AgentStore(loadFromDisk: false)
        let issueStore = IssueStore(store: store)

        issueStore.selectedIssue = makeIssue(repository: "acme/project", number: 99)
        issueStore.selectedIssueBody = "Some body text"
        issueStore.selectedIssueComments = [
            IssueComment(
                id: "comment-1",
                authorLogin: "devon",
                authorAvatarURL: nil,
                body: "A comment",
                createdAt: Date()
            ),
        ]

        issueStore.selectIssue(nil)

        #expect(issueStore.selectedIssue == nil)
        #expect(issueStore.selectedIssueBody.isEmpty)
        #expect(issueStore.selectedIssueComments.isEmpty)
    }

    @Test
    func workOnIssueTruncatesLongTitles() throws {
        let store = AgentStore(loadFromDisk: false)
        store.agents = [
            Agent(
                name: "Existing",
                folder: URL(fileURLWithPath: "/tmp/project"),
                provider: .claude,
                sessionId: "existing-session"
            ),
        ]
        store.selectedAgentId = store.agents.first?.id

        let issueStore = IssueStore(store: store)
        let issue = makeIssue(
            repository: "acme/project",
            number: 5,
            title: "This is a very long issue title that should be truncated in the agent name"
        )

        issueStore.workOnIssue(issue)

        let issueAgent = try #require(store.agents.last)
        #expect(issueAgent.name == "Issue #5 - This is a very long issue title that sho")
    }

    private func makeIssue(
        repository: String,
        number: Int,
        title: String = "Fix the widget rendering bug"
    ) -> GitHubIssue {
        GitHubIssue(
            id: "issue-\(number)",
            number: number,
            title: title,
            url: URL(string: "https://github.com/\(repository)/issues/\(number)")!,
            repository: repository,
            authorLogin: "devon",
            authorAvatarURL: nil,
            labels: [],
            commentCount: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
