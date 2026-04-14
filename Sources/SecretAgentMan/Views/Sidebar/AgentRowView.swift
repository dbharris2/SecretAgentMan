import SwiftUI

struct AgentRowView: View {
    let agent: Agent
    let isSelected: Bool
    var pendingPromptCount: Int = 0
    var branchName: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            AgentProviderIconView(provider: agent.provider)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .scaledFont(size: 13, weight: isSelected ? .semibold : .regular)
                        .lineLimit(1)
                }

                if let branch = branchName {
                    BranchInfoView(branchName: branch)
                }
            }

            Spacer()

            if pendingPromptCount > 0 {
                Text(verbatim: "\(pendingPromptCount)")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(theme.red)
                    .clipShape(Circle())
            }

            StatusBadge(state: agent.state)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .hoverHighlight()
    }
}
