import SwiftUI

struct SessionChatView: View {
    let providerName: String
    let transcript: [CodexTranscriptItem]
    let streaming: String?
    let isThinking: Bool
    let fontScale: Double
    let emptyStateText: String

    @ViewBuilder let pendingCards: () -> AnyView

    @State private var expandedGroups: Set<String> = []

    private var sections: [TranscriptSection] {
        TranscriptSection.group(transcript)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if transcript.isEmpty, streaming == nil {
                        Text(emptyStateText)
                            .scaledFont(size: 13)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(sections) { section in
                            switch section {
                            case let .single(item):
                                SessionTranscriptBubble(
                                    role: item.role,
                                    label: SessionPanelTheme.label(for: item.role, providerName: providerName),
                                    text: item.text,
                                    fontScale: fontScale
                                )
                            case let .systemGroup(items, groupId):
                                systemGroupView(items: items, groupId: groupId)
                            }
                        }
                    }

                    if let text = streaming, !text.isEmpty {
                        SessionStreamingBubble(providerName: providerName, text: text, fontScale: fontScale)
                    } else if isThinking {
                        SessionThinkingBubble(providerName: providerName)
                    }

                    pendingCards()

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: streaming) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: transcript.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: isThinking) { _, thinking in
                if thinking { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func systemGroupView(items: [CodexTranscriptItem], groupId: String) -> some View {
        let isExpanded = expandedGroups.contains(groupId)

        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedGroups.remove(groupId)
                    } else {
                        expandedGroups.insert(groupId)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text("\(items.count) tool actions")
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        SessionMarkdownText(text: item.text, fontScale: fontScale)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }
}

// MARK: - Transcript Grouping

private enum TranscriptSection: Identifiable {
    case single(CodexTranscriptItem)
    case systemGroup([CodexTranscriptItem], groupId: String)

    var id: String {
        switch self {
        case let .single(item): item.id
        case let .systemGroup(_, groupId): groupId
        }
    }

    static func group(_ items: [CodexTranscriptItem]) -> [TranscriptSection] {
        var sections: [TranscriptSection] = []
        var systemRun: [CodexTranscriptItem] = []

        func flushSystemRun() {
            guard !systemRun.isEmpty else { return }
            if systemRun.count == 1 {
                sections.append(.single(systemRun[0]))
            } else {
                let groupId = "group-\(systemRun[0].id)"
                sections.append(.systemGroup(systemRun, groupId: groupId))
            }
            systemRun.removeAll()
        }

        for item in items {
            if item.role == .system {
                systemRun.append(item)
            } else {
                flushSystemRun()
                sections.append(.single(item))
            }
        }
        flushSystemRun()

        return sections
    }
}
