import MarkdownUI
import SwiftUI

struct PlanDetailView: View {
    let url: URL
    @State private var content: String = ""

    var body: some View {
        ScrollView {
            Markdown(content)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)))
        .onAppear { loadContent() }
        .onChange(of: url) { loadContent() }
    }

    private func loadContent() {
        content = (try? String(contentsOf: url, encoding: .utf8)) ?? "Failed to load plan."
    }
}
