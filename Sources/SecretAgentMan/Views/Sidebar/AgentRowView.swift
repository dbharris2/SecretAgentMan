import SwiftUI

struct AgentRowView: View {
    let agent: Agent
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image("ClaudeIcon")
                .resizable()
                .frame(width: 16, height: 16)

            Text(agent.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer()

            StatusBadge(state: agent.state)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}
