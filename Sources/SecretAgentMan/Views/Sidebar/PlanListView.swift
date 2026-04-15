import SwiftUI

struct PlanListView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appTheme) private var theme
    @Binding var selectedPlanURL: URL?
    @State private var plans: [PlanFile] = []

    var body: some View {
        Group {
            if coordinator.store.selectedAgent?.provider == .codex {
                ContentUnavailableView(
                    "Plans Unavailable",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Codex does not write Claude-style plan files. Use the session terminal and status panels for Codex agents.")
                )
            } else {
                List(plans) { plan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.title)
                            .scaledFont(size: 13)
                            .lineLimit(1)

                        Text(plan.filename)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                    .hoverHighlight(isSelected: selectedPlanURL == plan.url)
                    .onTapGesture {
                        if selectedPlanURL == plan.url {
                            selectedPlanURL = nil
                        } else {
                            selectedPlanURL = plan.url
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            deletePlan(plan)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(theme.surface)
                .onAppear { loadPlans() }
                .onChange(of: coordinator.store.selectedAgent?.provider) {
                    loadPlans()
                }
            }
        }
    }

    private func loadPlans() {
        let fm = FileManager.default
        guard let plansDir else {
            plans = []
            return
        }
        guard let files = try? fm.contentsOfDirectory(
            at: plansDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            plans = []
            return
        }

        plans = files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> PlanFile? in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                    return nil
                }
                let title = extractTitle(from: content) ?? url.deletingPathExtension().lastPathComponent
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return PlanFile(url: url, title: title, filename: url.lastPathComponent, modified: modified)
            }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    private var plansDir: URL? {
        switch coordinator.store.selectedAgent?.provider {
        case .claude:
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plans")
        case .codex:
            nil
        case nil:
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plans")
        }
    }

    private func deletePlan(_ plan: PlanFile) {
        try? FileManager.default.removeItem(at: plan.url)
        if selectedPlanURL == plan.url {
            selectedPlanURL = nil
        }
        loadPlans()
    }

    private func extractTitle(from content: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
        }
        return nil
    }
}

struct PlanFile: Identifiable, Hashable {
    let url: URL
    let title: String
    let filename: String
    let modified: Date?

    var id: URL {
        url
    }
}
