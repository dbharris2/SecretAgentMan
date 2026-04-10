import SwiftUI

enum SidebarPanel: String {
    case plans
    case prs
    case issues
}

struct ActivitySidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var selectedPlanURL: URL?
    @AppStorage("sidebarSplitHeight") private var bottomPanelHeight: Double = 250

    var body: some View {
        @Bindable var coordinator = coordinator
        if let panel = coordinator.activeSidebarPanel {
            VStack(spacing: 0) {
                SidebarView(selectedPlanURL: $selectedPlanURL)

                ResizableDivider(size: $bottomPanelHeight, minSize: 100, axis: .horizontal)

                Group {
                    switch panel {
                    case .plans:
                        PlanListView(selectedPlanURL: $selectedPlanURL)
                    case .prs:
                        PRListView(
                            sections: coordinator.prStore.githubPRSections,
                            actions: PRActions(
                                review: coordinator.reviewPR,
                                markReady: coordinator.markPRReady,
                                close: coordinator.closePR,
                                convertToDraft: coordinator.convertPRToDraft,
                                addReviewers: coordinator.addReviewers,
                                select: coordinator.selectPR
                            ),
                            isLoading: coordinator.prStore.isLoadingPRs,
                            rateLimit: coordinator.prStore.githubRateLimit,
                            lastPollTime: coordinator.prStore.lastPRPollTime,
                            reviewerGroups: coordinator.reviewerGroupStore.groups,
                            selectedPRId: coordinator.prStore.selectedGitHubPR?.id
                        )
                    case .issues:
                        IssueListView(
                            sections: coordinator.issueStore.issueSections,
                            isLoading: coordinator.issueStore.isLoadingIssues,
                            rateLimit: coordinator.prStore.githubRateLimit,
                            lastPollTime: coordinator.issueStore.lastIssuePollTime,
                            selectedIssueId: coordinator.issueStore.selectedIssue?.id,
                            onSelect: coordinator.selectIssue,
                            onWorkOnIssue: coordinator.workOnIssue
                        )
                    }
                }
                .frame(height: bottomPanelHeight)
            }
        } else {
            SidebarView(selectedPlanURL: $selectedPlanURL)
        }
    }
}
