import SwiftUI

struct PRActions {
    let review: (GitHubPRService.GitHubPR) -> Void
    let markReady: (GitHubPRService.GitHubPR) -> Void
    let close: (GitHubPRService.GitHubPR) -> Void
    let convertToDraft: (GitHubPRService.GitHubPR) -> Void
    let addReviewers: (GitHubPRService.GitHubPR, ReviewerGroup) -> Void
    let select: (GitHubPRService.GitHubPR?) -> Void
}

struct PRListView: View {
    let sections: [GitHubPRService.PRSection: [GitHubPRService.GitHubPR]]
    let actions: PRActions
    var reviewerGroups: [ReviewerGroup] = []
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
                let isExpanded = !collapsedSections.contains(item.section)

                Section {
                    if isExpanded {
                        ForEach(item.prs) { pr in
                            PRRowView(
                                pr: pr,
                                isSelected: selectedPRId == pr.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedPRId == pr.id {
                                    actions.select(nil)
                                } else {
                                    actions.select(pr)
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
                                Divider()
                                Button("Review with Agent") {
                                    actions.review(pr)
                                }
                                if pr.isDraft || item.section.isAuthored {
                                    Divider()
                                }
                                if pr.isDraft {
                                    Button("Mark as Ready for Review") {
                                        actions.markReady(pr)
                                    }
                                }
                                if item.section.isAuthored, !pr.isDraft {
                                    Button("Convert to Draft") {
                                        actions.convertToDraft(pr)
                                    }
                                }
                                if item.section.isAuthored, !reviewerGroups.isEmpty {
                                    Menu("Add Reviewers") {
                                        ForEach(reviewerGroups) { group in
                                            Button("\(group.name) (\(group.reviewers.joined(separator: ", ")))") {
                                                actions.addReviewers(pr, group)
                                            }
                                        }
                                    }
                                }
                                if item.section.isAuthored {
                                    Button("Close PR", role: .destructive) {
                                        actions.close(pr)
                                    }
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
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text(item.section.rawValue)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(verbatim: "\(item.prs.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 16)
                                .padding(.horizontal, 3)
                                .background(sectionColor(item.section))
                                .clipShape(Capsule())
                        }
                        .padding(.trailing, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .padding(.top, 8)
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

    private var stateColor: Color {
        if pr.reviewDecision == "APPROVED" { return .green }
        if pr.reviewDecision == "CHANGES_REQUESTED" { return .red }
        if pr.isDraft { return .secondary }
        return .orange
    }

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
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(stateColor)
                .frame(width: 3)

            if let avatarURL = pr.authorAvatarURL {
                AsyncImage(url: avatarURL) { image in
                    image.resizable()
                } placeholder: {
                    Text(verbatim: String(pr.authorLogin.prefix(2)))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.6))
                .clipShape(Circle())
                .help(pr.authorLogin)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(pr.title)
                        .font(.system(size: 12))
                        .lineLimit(1)

                    Spacer()

                    Text(Self.relativeDate(pr.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

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
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .hoverHighlight(isSelected: isSelected)
    }
}
