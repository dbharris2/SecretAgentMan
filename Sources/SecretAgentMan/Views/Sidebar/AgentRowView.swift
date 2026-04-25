import SwiftUI

struct AgentRowView: View {
    let agent: Agent
    let isSelected: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: Spacing.lg) {
            StatusBadge(state: agent.state)

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

            Spacer()

            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(agent.updatedAt.relativeAgo)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, Spacing.xxl)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .hoverHighlight(isSelected: isSelected, cornerRadius: 0)
    }

    private var providerPillColor: Color {
        switch agent.provider {
        case .claude: theme.orange
        case .codex: theme.blue
        case .gemini: theme.magenta
        }
    }
}
