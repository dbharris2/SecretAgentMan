import SwiftUI

struct IssueListView: View {
    let sections: [IssueSection: [GitHubIssue]]
    var isLoading = false
    var rateLimit: GitHubPRService.RateLimit?
    var lastPollTime: Date?
    var selectedIssueId: String?
    let onSelect: (GitHubIssue?) -> Void
    let onWorkOnIssue: (GitHubIssue) -> Void

    @State private var collapsedSections: Set<IssueSection> = []
    @Environment(\.appTheme) private var theme

    private var orderedSections: [(section: IssueSection, issues: [GitHubIssue])] {
        IssueSection.allCases.compactMap { section in
            guard let issues = sections[section], !issues.isEmpty else { return nil }
            return (section, issues)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading issues…")
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.sm)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if orderedSections.isEmpty {
                VStack {
                    Spacer()
                    Text("No open issues")
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                issueList
            }

            if let rateLimit {
                rateLimitBar(rateLimit)
            }
        }
        .background(theme.surface)
    }

    private func rateLimitBar(_ limit: GitHubPRService.RateLimit) -> some View {
        let fraction = limit.limit > 0 ? Double(limit.used) / Double(limit.limit) : 0
        let color: Color = fraction > 0.8 ? theme.red : fraction > 0.5 ? theme.yellow : theme.green

        return HStack(spacing: Spacing.md) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("GitHub API: \(limit.used)/\(limit.limit) used")
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
            Spacer()
            if let lastPollTime {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.relativeTime(lastPollTime))
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.sm)
        .background(theme.surface)
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    private var issueList: some View {
        List {
            ForEach(orderedSections, id: \.section) { item in
                let isExpanded = !collapsedSections.contains(item.section)

                Section {
                    if isExpanded {
                        ForEach(item.issues) { issue in
                            IssueRowView(
                                issue: issue,
                                isSelected: selectedIssueId == issue.id,
                                lastPollTime: lastPollTime
                            )
                            .contentShape(Rectangle())
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .onTapGesture {
                                if selectedIssueId == issue.id {
                                    onSelect(nil)
                                } else {
                                    onSelect(issue)
                                }
                            }
                            .contextMenu {
                                Button("Open in GitHub") {
                                    NSWorkspace.shared.open(issue.url)
                                }
                                Button("Copy URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(issue.url.absoluteString, forType: .string)
                                }
                                Divider()
                                Button("Work on Issue with Agent") {
                                    onWorkOnIssue(issue)
                                }
                            }
                        }
                    }
                } header: {
                    Button {
                        if isExpanded {
                            collapsedSections.insert(item.section)
                        } else {
                            collapsedSections.remove(item.section)
                        }
                    } label: {
                        HStack(alignment: .center) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .scaledFont(size: 10, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text(item.section.rawValue)
                                .scaledFont(size: 13)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(verbatim: "\(item.issues.count)")
                                .scaledFont(size: 9, weight: .bold)
                                .foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 16)
                                .padding(.horizontal, 3)
                                .background(sectionColor(item.section))
                                .clipShape(Capsule())
                        }
                        .padding(.trailing, Spacing.lg)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.surface)
        .padding(.top, Spacing.lg)
    }

    private func sectionColor(_ section: IssueSection) -> Color {
        switch section {
        case .assigned: theme.blue
        case .mentioned: theme.yellow
        case .authored: theme.magenta
        }
    }
}

struct IssueRowView: View {
    let issue: GitHubIssue
    var isSelected: Bool = false
    var lastPollTime: Date?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(theme.green)
                .frame(width: 3)

            if let avatarURL = issue.authorAvatarURL {
                AsyncImage(url: avatarURL) { image in
                    image.resizable()
                } placeholder: {
                    Text(verbatim: String(issue.authorLogin.prefix(2)))
                        .scaledFont(size: 9, weight: .medium)
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.6))
                .clipShape(Circle())
                .help(issue.authorLogin)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text(issue.title)
                        .scaledFont(size: 12)
                        .lineLimit(1)

                    Spacer()

                    Text(issue.updatedAt.relativeAgo)
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: Spacing.md) {
                    Text(verbatim: "\(issue.repository) #\(issue.number)")
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)

                    ForEach(Array(issue.labels.prefix(3)), id: \.name) { label in
                        Text(label.name)
                            .scaledFont(size: 9)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, 1)
                            .background(Color(hex: label.color).opacity(0.3))
                            .foregroundStyle(Color(hex: label.color))
                            .clipShape(Capsule())
                    }

                    if issue.labels.count > 3 {
                        Text(verbatim: "+\(issue.labels.count - 3)")
                            .scaledFont(size: 9)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if issue.commentCount > 0 {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "bubble.left")
                                .scaledFont(size: 9)
                            Text(verbatim: "\(issue.commentCount)")
                                .scaledFont(size: 10)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .hoverHighlight(isSelected: isSelected, cornerRadius: 0)
    }
}
