import SwiftUI

struct PRListView: View {
    let sections: [GitHubPRService.PRSection: [GitHubPRService.GitHubPR]]
    let onReview: (GitHubPRService.GitHubPR) -> Void
    let onSelect: (GitHubPRService.GitHubPR?) -> Void
    var selectedPRId: String?
    @State private var collapsedSections: Set<GitHubPRService.PRSection> = []

    private var orderedSections: [(section: GitHubPRService.PRSection, prs: [GitHubPRService.GitHubPR])] {
        GitHubPRService.PRSection.allCases.compactMap { section in
            guard let prs = sections[section], !prs.isEmpty else { return nil }
            return (section, prs)
        }
    }

    var body: some View {
        List {
            ForEach(orderedSections, id: \.section) { item in
                Section(isExpanded: Binding(
                    get: { !collapsedSections.contains(item.section) },
                    set: { isExpanded in
                        if isExpanded {
                            collapsedSections.remove(item.section)
                        } else {
                            collapsedSections.insert(item.section)
                        }
                    }
                )) {
                    ForEach(item.prs) { pr in
                        PRRowView(
                            pr: pr,
                            isSelected: selectedPRId == pr.id,
                            showReviewButton: item.section == .needsMyReview,
                            onReview: onReview
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedPRId == pr.id {
                                onSelect(nil)
                            } else {
                                onSelect(pr)
                            }
                        }
                        .contextMenu {
                            Button("Open in GitHub") {
                                NSWorkspace.shared.open(pr.url)
                            }
                            Button("Copy URL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: sectionIcon(item.section))
                            .font(.system(size: 11))
                            .foregroundStyle(sectionColor(item.section))
                        Text(item.section.rawValue)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(verbatim: "\(item.prs.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .padding(.horizontal, 4)
                            .background(sectionColor(item.section))
                            .clipShape(Capsule())
                    }
                    .padding(.trailing, 8)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sectionIcon(_ section: GitHubPRService.PRSection) -> String {
        switch section {
        case .needsMyReview: "eye"
        case .returnedToMe: "exclamationmark.arrow.triangle.2.circlepath"
        case .approved: "checkmark.circle"
        case .waitingForReview: "clock"
        case .reviewed: "bubble.left.and.text.bubble.right"
        case .drafts: "doc.text"
        }
    }

    private func sectionColor(_ section: GitHubPRService.PRSection) -> Color {
        switch section {
        case .needsMyReview: .blue
        case .returnedToMe: .red
        case .approved: .green
        case .waitingForReview: .orange
        case .reviewed: .purple
        case .drafts: .secondary
        }
    }
}

struct PRRowView: View {
    let pr: GitHubPRService.GitHubPR
    var isSelected: Bool = false
    let showReviewButton: Bool
    let onReview: (GitHubPRService.GitHubPR) -> Void

    @State private var isHovered = false

    private static func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 604_800 { return "\(Int(seconds / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Row 1: avatar, title, date, review button
            HStack {
                if let avatarURL = pr.authorAvatarURL {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable()
                    } placeholder: {
                        Text(verbatim: String(pr.authorLogin.prefix(2)))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 18, height: 18)
                    .background(Color.secondary.opacity(0.6))
                    .clipShape(Circle())
                }

                Text(pr.title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer()

                Text(Self.relativeDate(pr.updatedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Row 2: repo info, stats, comments, reviewers
            HStack(spacing: 6) {
                Text(verbatim: "\(pr.repository) #\(pr.number)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text(verbatim: "+\(pr.additions)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.green)
                Text(verbatim: "-\(pr.deletions)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                Text(verbatim: "@\(pr.changedFiles)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if pr.commentCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 9))
                        Text(verbatim: "\(pr.commentCount)")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                ForEach(pr.reviewers, id: \.login) { reviewer in
                    AsyncImage(url: reviewer.avatarURL) { image in
                        image.resizable()
                    } placeholder: {
                        Text(verbatim: String(reviewer.login.prefix(2)))
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 16, height: 16)
                    .background(Color.secondary.opacity(0.6))
                    .clipShape(Circle())
                    .help(reviewer.login)
                }

                if pr.checkStatus != .none {
                    Image(systemName: "flask.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(pr.checkStatus.color)
                        .help(pr.checkStatus.label)
                }
            }

            // Row 3: actions
            if showReviewButton {
                HStack {
                    Spacer()
                    Button("Review") {
                        onReview(pr)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : isHovered ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}
