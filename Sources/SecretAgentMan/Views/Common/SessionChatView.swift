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
    var groupsToolActivity: Bool = true

    @ViewBuilder let pendingCards: () -> AnyView

    @State private var expandedGroups: Set<String> = []
    @State private var visibleCount = 50
    @State private var distanceFromBottom: CGFloat = 0
    @State private var hasUnreadBelow: Bool = false

    private static let pageSize = 50
    /// Scroll-distance below which we consider the user "pinned" to the bottom
    /// and continue auto-scrolling on new content. Generous enough to absorb
    /// a single line of streaming growth between layout passes.
    private static let pinThreshold: CGFloat = 60
    /// Show the floating "Go to bottom" button only when the user has scrolled
    /// far enough that returning by hand would be tedious.
    private static let goToBottomThreshold: CGFloat = 200

    private var assistantMessageCount: Int {
        transcript.count(where: { $0.kind == .assistantMessage })
    }

    private var isPinnedToBottom: Bool {
        distanceFromBottom <= Self.pinThreshold
    }

    var body: some View {
        let allSections = TranscriptSection.group(transcript, groupsToolActivity: groupsToolActivity)
        let displayedStart = max(0, allSections.count - visibleCount)
        let displayedSections = allSections[displayedStart...]
        let hasMoreAbove = allSections.count > visibleCount

        return AutoScrollingScrollView(
            trigger: AutoScrollSignal(
                transcriptCount: transcript.count,
                streamingLength: streaming?.count,
                isThinking: isThinking,
                hasPendingCard: hasPendingCard
            ),
            pinThreshold: Self.pinThreshold,
            distanceFromBottom: $distanceFromBottom
        ) { proxy in
            chatContent(
                proxy: proxy,
                displayedSections: displayedSections,
                hasMoreAbove: hasMoreAbove
            )
        } overlay: { distance, scrollToBottom in
            if distance > Self.goToBottomThreshold {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollToBottom()
                    }
                    hasUnreadBelow = false
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
                        .overlay(alignment: .topTrailing) {
                            if hasUnreadBelow {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 9, height: 9)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 1.5)
                                    )
                                    .offset(x: 2, y: -2)
                            }
                        }
                        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding(Spacing.xxl)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: distanceFromBottom > Self.goToBottomThreshold)
        .onAppear { visibleCount = Self.pageSize }
        .onChange(of: assistantMessageCount) { old, new in
            if new > old, !isPinnedToBottom {
                hasUnreadBelow = true
            }
        }
        .onChange(of: isPinnedToBottom) { _, pinned in
            if pinned { hasUnreadBelow = false }
        }
    }

    private func chatContent(
        proxy: ScrollViewProxy,
        displayedSections: ArraySlice<TranscriptSection>,
        hasMoreAbove: Bool
    ) -> some View {
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
        }
        .padding(Spacing.xxl)
    }

    /// Collapsed-by-default disclosure for `agent_thought_chunk` content.
    /// Mirrors the current agent UX default of hiding internal reasoning unless
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
                .frame(maxWidth: .infinity, alignment: .leading)
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

                    Text(systemGroupLabel(items: items))
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)

                    if !isExpanded, let summary = collapsedSystemSummary(items: items) {
                        Text("·")
                            .scaledFont(size: 12)
                            .foregroundStyle(.tertiary)
                        Text(markdownAttributedString(summary))
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(items, id: \.id) { item in
                        SessionMarkdownText(text: item.text, fontScale: fontScale)
                            .padding(.leading, 18)
                    }
                }
            }
        }
    }

    private func systemGroupLabel(items: [SessionTranscriptItem]) -> String {
        let kinds: [TranscriptItemKind] = [.toolActivity, .plan, .diffSummary, .systemMessage, .error]
        let parts = kinds.compactMap { kind -> String? in
            let count = items.count(where: { $0.kind == kind })
            guard count > 0 else { return nil }
            return "\(count) \(noun(for: kind, plural: count != 1))"
        }
        return parts.isEmpty ? "\(items.count) items" : parts.joined(separator: ", ")
    }

    private func noun(for kind: TranscriptItemKind, plural: Bool) -> String {
        switch kind {
        case .toolActivity: plural ? "tools" : "tool"
        case .plan: plural ? "plans" : "plan"
        case .diffSummary: plural ? "diffs" : "diff"
        case .systemMessage: plural ? "system messages" : "system message"
        case .error: plural ? "errors" : "error"
        default: "item"
        }
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

    private func markdownAttributedString(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
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
}

// MARK: - Transcript Grouping

private enum TranscriptSection: Identifiable {
    case single(SessionTranscriptItem)
    case systemGroup([SessionTranscriptItem], groupId: String)
    /// Runs of `.thought` items are kept in a dedicated bucket so they render
    /// as a quiet collapsed reasoning disclosure rather than mixing into the
    /// "tool actions" group with system/tool/plan items.
    case thoughtGroup([SessionTranscriptItem], groupId: String)

    var id: String {
        switch self {
        case let .single(item): item.id
        case let .systemGroup(_, groupId): groupId
        case let .thoughtGroup(_, groupId): groupId
        }
    }

    static func group(
        _ items: [SessionTranscriptItem],
        groupsToolActivity: Bool = true
    ) -> [TranscriptSection] {
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
            } else if item.kind == .toolActivity, !groupsToolActivity {
                flushSystemRun()
                flushThoughtRun()
                sections.append(.single(item))
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
    /// into a single expandable "tool actions" block. `.thought` items
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

// MARK: - Auto-scroll trigger

/// Bundles the heterogeneous signals that should pin-aware auto-scroll the
/// chat into a single Equatable value so we can pass it through
/// `AutoScrollingScrollView`'s generic trigger parameter. Streaming is
/// represented by its character count rather than the full string so that
/// per-chunk Equatable comparisons stay O(1) instead of O(N).
private struct AutoScrollSignal: Equatable {
    let transcriptCount: Int
    let streamingLength: Int?
    let isThinking: Bool
    let hasPendingCard: Bool
}
