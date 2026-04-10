import Foundation
import SwiftUI

@MainActor
@Observable
final class IssueStore {
    private let githubIssueService: GitHubIssueService

    var issueSections: [IssueSection: [GitHubIssue]] = [:]
    var isLoadingIssues = true
    var lastIssuePollTime: Date?
    var selectedIssue: GitHubIssue?
    var selectedIssueBody: String = ""
    var selectedIssueComments: [IssueComment] = []

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private var issueTimer: Timer?

    init(
        store: AgentStore,
        githubIssueService: GitHubIssueService = GitHubIssueService()
    ) {
        self.store = store
        self.githubIssueService = githubIssueService
    }

    func start() {
        refresh()
        issueTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        issueTimer?.invalidate()
    }

    func refresh() {
        Task {
            let sections = await githubIssueService.fetchAllIssues()
            issueSections = sections
            lastIssuePollTime = Date()
            isLoadingIssues = false
        }
    }

    func selectIssue(_ issue: GitHubIssue?) {
        selectedIssue = issue
        selectedIssueBody = ""
        selectedIssueComments = []
        guard let issue else { return }
        Task {
            let detail = await githubIssueService.fetchIssueDetail(
                repo: issue.repository,
                number: issue.number
            )
            if selectedIssue?.id == issue.id {
                selectedIssueBody = detail.body
                selectedIssueComments = detail.comments
            }
        }
    }

    func workOnIssue(_ issue: GitHubIssue) {
        let repoName = issue.repository.components(separatedBy: "/").last ?? ""
        let matchingAgent = store.agents.first { $0.folderPath.contains(repoName) }

        guard let folder = matchingAgent?.folder else { return }

        let previousSelection = store.selectedAgentId
        let truncatedTitle = String(issue.title.prefix(40))
        let issueAgent = store.addAgent(
            name: "Issue #\(issue.number) - \(truncatedTitle)",
            folder: folder,
            provider: .claude
        )
        store.selectAgent(id: previousSelection)

        let prompt = """
        Work on issue #\(issue.number): \(issue.title)
        \(issue.url.absoluteString)

        Read the full issue with `gh issue view \(issue.number) --repo \(issue.repository)`.
        Plan your approach, then implement the changes.
        """

        store.addPendingPrompt(PendingPrompt(
            agentId: issueAgent.id,
            source: .workOnIssue,
            summary: "Work on: \(issue.repository) #\(issue.number)",
            fullPrompt: prompt
        ))
    }
}
