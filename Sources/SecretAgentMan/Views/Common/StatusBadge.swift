import SwiftUI

struct StatusBadge: View {
    let state: AgentState
    @Environment(\.appTheme) private var theme

    var body: some View {
        let presentation = state.presentation

        Image(systemName: presentation.systemImage)
            .foregroundStyle(presentation.tone.color(in: theme))
            .scaledFont(size: 10)
            .help(presentation.label)
    }
}
