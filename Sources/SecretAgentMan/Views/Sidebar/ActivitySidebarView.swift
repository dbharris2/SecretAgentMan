import SwiftUI

enum ActivityMode: String {
    case agents
    case plans
    case prs
}

struct ActivitySidebarView: View {
    @Binding var mode: ActivityMode
    @Bindable var store: AgentStore
    var branchNames: [String: String]
    var prInfos: [String: PRInfo]
    var onRemoveAgent: (UUID) -> Void
    @Binding var selectedPlanURL: URL?
    var prSections: [GitHubPRService.PRSection: [GitHubPRService.GitHubPR]]
    var onReviewPR: (GitHubPRService.GitHubPR) -> Void
    var onSelectPR: (GitHubPRService.GitHubPR?) -> Void
    var selectedPRId: String?

    var body: some View {
        switch mode {
        case .agents:
            SidebarView(
                store: store,
                branchNames: branchNames,
                prInfos: prInfos,
                onRemoveAgent: onRemoveAgent
            )
        case .plans:
            PlanListView(selectedPlanURL: $selectedPlanURL)
        case .prs:
            PRListView(
                sections: prSections,
                onReview: onReviewPR,
                onSelect: onSelectPR,
                selectedPRId: selectedPRId
            )
        }
    }
}
