import SwiftUI

struct AgentRowView: View {
    let agent: Agent
    let isSelected: Bool
    var branchName: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(state: agent.state)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(agent.name)
                        .scaledFont(size: 13, weight: isSelected ? .semibold : .regular)
                        .lineLimit(1)

                    Text(agent.provider.displayName)
                        .scaledFont(size: 9, weight: .medium)
                        .foregroundStyle(providerPillColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(providerPillColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                if let branch = branchName {
                    BranchInfoView(branchName: branch)
                }
            }

            Spacer()

            Text(Self.relativeDate(agent.updatedAt))
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .hoverHighlight()
    }

    private var providerPillColor: Color {
        switch agent.provider {
        case .claude: theme.orange
        case .codex: theme.blue
        }
    }

    private static func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 604_800 { return "\(Int(seconds / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
