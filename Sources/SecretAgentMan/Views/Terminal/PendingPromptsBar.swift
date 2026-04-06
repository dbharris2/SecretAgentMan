import SwiftUI

struct PendingPromptsBar: View {
    @Bindable var store: AgentStore
    let selectedAgentId: UUID?
    let onSend: (PendingPrompt) -> Void

    @State private var expandedPromptId: UUID?

    private var prompts: [PendingPrompt] {
        guard let id = selectedAgentId else { return [] }
        return store.pendingPrompts(for: id)
    }

    var body: some View {
        if !prompts.isEmpty {
            VStack(spacing: 0) {
                ForEach(prompts) { prompt in
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: iconForSource(prompt.source))
                                .font(.system(size: 12))
                                .foregroundStyle(colorForSource(prompt.source))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(prompt.source.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(prompt.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                if expandedPromptId == prompt.id {
                                    expandedPromptId = nil
                                } else {
                                    expandedPromptId = prompt.id
                                }
                            } label: {
                                Image(systemName: expandedPromptId == prompt.id ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Preview prompt")

                            Button {
                                onSend(prompt)
                                store.removePendingPrompt(id: prompt.id)
                            } label: {
                                Text("Send")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                store.removePendingPrompt(id: prompt.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                        if expandedPromptId == prompt.id {
                            ScrollView {
                                Text(prompt.fullPrompt)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(maxHeight: 120)
                            .background(Color.black.opacity(0.2))
                        }

                        Divider()
                    }
                }
            }
            .background(.bar)
        }
    }

    private func iconForSource(_ source: PendingPrompt.PromptSource) -> String {
        switch source {
        case .ciFailed: "xmark.circle.fill"
        case .changesRequested: "bubble.left.fill"
        case .approvedWithComments: "checkmark.bubble.fill"
        case .reviewPR: "eye.fill"
        }
    }

    private func colorForSource(_ source: PendingPrompt.PromptSource) -> Color {
        switch source {
        case .ciFailed: .red
        case .changesRequested: .orange
        case .approvedWithComments: .green
        case .reviewPR: .blue
        }
    }
}
