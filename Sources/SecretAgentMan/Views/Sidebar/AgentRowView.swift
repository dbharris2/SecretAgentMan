import SwiftUI

struct AgentRowView: View {
    let agent: Agent
    let isSelected: Bool
    var pendingPromptCount: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            Image("ClaudeIcon")
                .resizable()
                .frame(width: 16, height: 16)

            Text(agent.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

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
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
