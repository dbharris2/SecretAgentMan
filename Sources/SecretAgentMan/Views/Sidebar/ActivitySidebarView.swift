import SwiftUI

enum SidebarPanel: String {
    case plans
    case prs
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
                            sections: coordinator.prMonitor.githubPRSections,
                            actions: PRActions(
                                review: coordinator.reviewPR,
                                markReady: coordinator.markPRReady,
                                close: coordinator.closePR,
                                convertToDraft: coordinator.convertPRToDraft,
                                addReviewers: coordinator.addReviewers,
                                select: coordinator.selectPR
                            ),
                            isLoading: coordinator.prMonitor.isLoadingPRs,
                            rateLimit: coordinator.prMonitor.githubRateLimit,
                            lastPollTime: coordinator.prMonitor.lastPRPollTime,
                            reviewerGroups: coordinator.reviewerGroupStore.groups,
                            selectedPRId: coordinator.prMonitor.selectedGitHubPR?.id
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
