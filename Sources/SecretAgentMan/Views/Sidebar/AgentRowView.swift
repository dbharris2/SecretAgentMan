import SwiftUI

struct AgentRowView: View {
    let agent: Agent
    let isSelected: Bool
    var pendingPromptCount: Int = 0
    var branchName: String?
    var prInfo: PRInfo?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image("ClaudeIcon")
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                if let branch = branchName {
                    BranchInfoView(branchName: branch)
                }

                if let pr = prInfo {
                    PRMetadataView(prInfo: pr)
                }
            }

            Spacer()

            if pendingPromptCount > 0 {
                Text(verbatim: "\(pendingPromptCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(.red)
                    .clipShape(Circle())
            }

            StatusBadge(state: agent.state)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered && !isSelected ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}
