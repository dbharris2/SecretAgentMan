import SwiftUI

struct PlanListView: View {
    @Binding var selectedPlanURL: URL?
    @State private var plans: [PlanFile] = []

    private static let plansDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/plans")

    var body: some View {
        List(plans, selection: $selectedPlanURL) { plan in
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Text(plan.filename)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .tag(plan.url)
            .contextMenu {
                Button("Delete", role: .destructive) {
                    deletePlan(plan)
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { loadPlans() }
        .toolbar {
            ToolbarItem {
                Button {
                    loadPlans()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh plans")
            }
        }
    }

    private func loadPlans() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.plansDir,
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
