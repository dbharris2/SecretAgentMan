import MarkdownUI
import SwiftUI

struct PlanDetailView: View {
    let url: URL
    @State private var content: String = ""
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            Markdown(content)
                .markdownTheme(theme.isDark ? .basic : .gitHub)
                .foregroundStyle(theme.foreground)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.background)
        .onAppear { loadContent() }
        .onChange(of: url) { loadContent() }
    }

    private func loadContent() {
        content = (try? String(contentsOf: url, encoding: .utf8)) ?? "Failed to load plan."
    }
}
