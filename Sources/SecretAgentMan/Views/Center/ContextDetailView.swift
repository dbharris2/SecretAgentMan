import SwiftUI

/// Right-panel content: shows whatever context the user is currently inspecting.
/// Defaults to working-directory changes; swaps to a plan / PR detail
/// view when one of those is selected in the sidebar.
struct ContextDetailView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var selectedPlanURL: URL?

    var body: some View {
        if coordinator.activeSidebarPanel == .plans, let url = selectedPlanURL {
            PlanDetailView(url: url)
        } else if coordinator.activeSidebarPanel == .prs, let pr = coordinator.prStore.selectedGitHubPR {
            if coordinator.prStore.selectedPRChanges.isEmpty, !coordinator.prStore.selectedPRDiff.isEmpty {
                ChangesView(changes: coordinator.prStore.selectedPRChanges, fullDiff: coordinator.prStore.selectedPRDiff)
            } else if coordinator.prStore.selectedPRChanges.isEmpty {
                VStack(spacing: Spacing.lg) {
                    ProgressView()
                    Text("Loading diff for #\(pr.number)...")
                        .scaledFont(size: 13)
                        .foregroundStyle(.secondary)
                }
            } else {
                ChangesView(changes: coordinator.prStore.selectedPRChanges, fullDiff: coordinator.prStore.selectedPRDiff)
            }
        } else {
            ChangesView(changes: coordinator.repositoryMonitor.fileChanges, fullDiff: coordinator.repositoryMonitor.fullDiff)
        }
    }
}
