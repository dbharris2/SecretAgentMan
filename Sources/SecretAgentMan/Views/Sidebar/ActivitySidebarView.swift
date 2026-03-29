import SwiftUI

enum ActivityMode: String {
    case agents
    case plans
}

struct ActivitySidebarView: View {
    @Binding var mode: ActivityMode
    @Bindable var store: AgentStore
    var branchNames: [String: String]
    var onRemoveAgent: (UUID) -> Void
    @Binding var selectedPlanURL: URL?

    var body: some View {
        HStack(spacing: 0) {
            // Activity bar
            VStack(spacing: 4) {
                activityButton(icon: "person.2", mode: .agents, label: "Agents")
                activityButton(icon: "doc.text", mode: .plans, label: "Plans")
                Spacer()
            }
            .padding(.vertical, 8)
            .frame(width: 40)
            .background(.background)

            Divider()

            // Sidebar content
            Group {
                switch mode {
                case .agents:
                    SidebarView(store: store, branchNames: branchNames, onRemoveAgent: onRemoveAgent)
                case .plans:
                    PlanListView(selectedPlanURL: $selectedPlanURL)
                }
            }
        }
    }

    private func activityButton(icon: String, mode: ActivityMode, label: String) -> some View {
        Button {
            self.mode = mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .foregroundStyle(self.mode == mode ? .primary : .secondary)
                .background(self.mode == mode ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
