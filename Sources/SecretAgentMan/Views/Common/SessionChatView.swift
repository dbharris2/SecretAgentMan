import SwiftUI

struct SessionChatView: View {
    let providerName: String
    let transcript: [SessionTranscriptItem]
    let streaming: String?
    let isThinking: Bool
    let activeTool: String?
    let hasPendingCard: Bool
    let fontScale: Double
    let emptyStateText: String

    @ViewBuilder let pendingCards: () -> AnyView

    @State private var expandedGroups: Set<String> = []
    @State private var visibleCount = 50

    private static let pageSize = 50

    private var allSections: [TranscriptSection] {
        TranscriptSection.group(transcript)
    }

    private var displayedSections: ArraySlice<TranscriptSection> {
        let all = allSections
        let start = max(0, all.count - visibleCount)
        return all[start...]
    }

    private var hasMoreAbove: Bool {
        allSections.count > visibleCount
    }

    var body: some View {
        ScrollViewReader { proxy in
            let scrollToBottom = { proxy.scrollTo("bottom", anchor: .bottom) }

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    if transcript.isEmpty, streaming == nil {
                        Text(emptyStateText)
                            .scaledFont(size: 13)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if hasMoreAbove {
                            Button {
                                let anchorId = displayedSections.first?.id
                                visibleCount += Self.pageSize
                                if let anchorId {
                                    DispatchQueue.main.async {
                                        proxy.scrollTo(anchorId, anchor: .top)
                                    }
                                }
                            } label: {
                                Text("Load earlier messages")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, Spacing.md)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(displayedSections) { section in
                            switch section {
                            case let .single(item):
                                if item.kind == .thought {
                                    thoughtDisclosureView(items: [item], groupId: "thought-\(item.id)")
                                } else if item.metadata?.toolName == "TodoWrite" {
                                    SessionTodoCard(text: item.text, fontScale: fontScale)
                                } else {
                                    SessionTranscriptBubble(
                                        kind: item.kind,
                                        text: item.text,
                                        fontScale: fontScale,
                                        images: item.imageData
                                    )
                                }
                            case let .systemGroup(items, groupId):
                                systemGroupView(items: items, groupId: groupId)
                            case let .thoughtGroup(items, groupId):
                                thoughtDisclosureView(items: items, groupId: groupId)
                            }
                        }
                    }

                    if let text = streaming, !text.isEmpty {
                        SessionStreamingBubble(text: text, fontScale: fontScale)
                    } else if isThinking {
                        SessionThinkingBubble(providerName: providerName, activeTool: activeTool)
                    }

                    pendingCards()

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(Spacing.xxl)
            }
            .onAppear {
                visibleCount = Self.pageSize
                scrollToBottom()
            }
            .onChange(of: streaming) { _, _ in scrollToBottom() }
            .onChange(of: transcript.count) { _, _ in scrollToBottom() }
            .onChange(of: isThinking) { _, thinking in if thinking { scrollToBottom() } }
            .onChange(of: hasPendingCard) { _, has in if has { scrollToBottom() } }
        }
    }

    /// Collapsed-by-default disclosure for `agent_thought_chunk` content.
    /// Mirrors the Gemini CLI's default of hiding internal reasoning unless
    /// the user opts in to see it.
    @ViewBuilder
    private func thoughtDisclosureView(items: [SessionTranscriptItem], groupId: String) -> some View {
        let isExpanded = expandedGroups.contains(groupId)
        let combinedText = items.map(\.text).joined(separator: "\n\n")
        let lineCount = combinedText.split(whereSeparator: \.isNewline).count

        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedGroups.remove(groupId)
                    } else {
                        expandedGroups.insert(groupId)
                    }
                }
            } label: {
                HStack(spacing: Spacing.md) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Image(systemName: "brain")
                        .scaledFont(size: 10)
                        .foregroundStyle(.tertiary)
                    Text(isExpanded ? "Hide reasoning" : "Show reasoning (\(lineCount) lines)")
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                SessionMarkdownText(text: combinedText, fontScale: fontScale)
                    .padding(.leading, 24)
                    .opacity(0.85)
            }
        }
    }

    @ViewBuilder
    private func systemGroupView(items: [SessionTranscriptItem], groupId: String) -> some View {
        let isExpanded = expandedGroups.contains(groupId)

        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedGroups.remove(groupId)
                    } else {
                        expandedGroups.insert(groupId)
                    }
                }
            } label: {
                HStack(spacing: Spacing.md) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Text("\(items.count) saved tool actions")
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)

                    if !isExpanded, let summary = collapsedSystemSummary(items: items) {
                        Text("·")
                            .scaledFont(size: 12)
                            .foregroundStyle(.tertiary)
                        Text(summary)
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(mergedExpandedSystemItems(items: items), id: \.id) { item in
                        SessionMarkdownText(text: item.text, fontScale: fontScale)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }

    private func mergedExpandedSystemItems(items: [SessionTranscriptItem]) -> [SessionTranscriptItem] {
        var merged: [SessionTranscriptItem] = []

        for item in items {
            guard let preview = systemPreview(item: item) else {
                merged.append(item)
                continue
            }

            let body = systemBody(item.text)
            if let last = merged.last,
               let lastPreview = systemPreview(item: last),
               lastPreview.title == preview.title {
                let mergedBody = [systemBody(last.text), body]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                let mergedText = mergedBody.isEmpty ? preview.title : "\(preview.title)\n\n\(mergedBody)"
                merged[merged.count - 1] = SessionTranscriptItem(
                    id: last.id,
                    kind: last.kind,
                    text: mergedText,
                    isStreaming: last.isStreaming,
                    createdAt: last.createdAt,
                    imageData: last.imageData,
                    metadata: last.metadata
                )
            } else {
                merged.append(item)
            }
        }

        return merged
    }

    private func collapsedSystemSummary(items: [SessionTranscriptItem]) -> String? {
        let previews = items.compactMap(systemPreview)
        guard !previews.isEmpty else { return nil }

        let uniqueTitles = previews.map(\.title).uniqued()
        if uniqueTitles.count == 1, let title = uniqueTitles.first {
            let mergedDetails = previews
                .flatMap(\.details)
                .uniqued()
                .prefix(4)

            if mergedDetails.isEmpty {
                return title
            }
            return "\(title) \(mergedDetails.joined(separator: ", "))"
        }

        return previews.last.map { preview in
            ([preview.title] + preview.details)
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func systemPreview(item: SessionTranscriptItem) -> (title: String, details: [String])? {
        let lines = item.text
            .split(separator: "\n")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }

        guard let title = lines.first else { return nil }
        let details = lines.dropFirst().filter { !$0.hasSuffix(":") }
        return (title, Array(details))
    }

    private func systemBody(_ text: String) -> String {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return "" }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Transcript Grouping

private enum TranscriptSection: Identifiable {
    case single(SessionTranscriptItem)
    case systemGroup([SessionTranscriptItem], groupId: String)
    /// Runs of `.thought` items are kept in a dedicated bucket so they render
    /// as a quiet collapsed reasoning disclosure rather than mixing into the
    /// "saved tool actions" group with system/tool/plan items.
    case thoughtGroup([SessionTranscriptItem], groupId: String)

    var id: String {
        switch self {
        case let .single(item): item.id
        case let .systemGroup(_, groupId): groupId
        case let .thoughtGroup(_, groupId): groupId
        }
    }

    static func group(_ items: [SessionTranscriptItem]) -> [TranscriptSection] {
        var sections: [TranscriptSection] = []
        var systemRun: [SessionTranscriptItem] = []
        var thoughtRun: [SessionTranscriptItem] = []

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

        func flushThoughtRun() {
            guard !thoughtRun.isEmpty else { return }
            if thoughtRun.count == 1 {
                // Single-thought sections still render through the dedicated
                // disclosure path via the .single(.thought) branch upstream.
                sections.append(.single(thoughtRun[0]))
            } else {
                let groupId = "thought-group-\(thoughtRun[0].id)"
                sections.append(.thoughtGroup(thoughtRun, groupId: groupId))
            }
            thoughtRun.removeAll()
        }

        for item in items {
            if item.kind == .thought {
                flushSystemRun()
                thoughtRun.append(item)
            } else if isGroupableKind(item.kind) {
                flushThoughtRun()
                systemRun.append(item)
            } else {
                flushSystemRun()
                flushThoughtRun()
                sections.append(.single(item))
            }
        }
        flushSystemRun()
        flushThoughtRun()

        return sections
    }

    /// System messages, tool activity, plan, diff summaries, and errors all
    /// render outside the primary conversation flow; consecutive runs collapse
    /// into a single expandable "saved tool actions" block. `.thought` items
    /// have their own dedicated grouping path (above) so they don't mix into
    /// that bucket.
    private static func isGroupableKind(_ kind: TranscriptItemKind) -> Bool {
        switch kind {
        case .userMessage, .assistantMessage, .thought: false
        case .systemMessage, .toolActivity, .plan, .diffSummary, .error: true
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
