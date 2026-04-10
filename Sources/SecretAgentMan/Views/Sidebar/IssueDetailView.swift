import SwiftUI

struct IssueDetailView: View {
    let issue: GitHubIssue
    let issueBody: String
    let comments: [IssueComment]
    @Environment(\.appTheme) private var theme

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.title)
                        .scaledFont(size: 16, weight: .semibold)

                    HStack(spacing: 8) {
                        Text(verbatim: "\(issue.repository) #\(issue.number)")
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)

                        if let avatarURL = issue.authorAvatarURL {
                            AsyncImage(url: avatarURL) { image in
                                image.resizable()
                            } placeholder: {
                                Text(verbatim: String(issue.authorLogin.prefix(2)))
                                    .scaledFont(size: 7, weight: .medium)
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 16, height: 16)
                            .background(Color.secondary.opacity(0.6))
                            .clipShape(Circle())
                        }

                        Text("@\(issue.authorLogin)")
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)

                        Text(Self.dateFormatter.string(from: issue.createdAt))
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                    }

                    if !issue.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(issue.labels, id: \.name) { label in
                                Text(label.name)
                                    .scaledFont(size: 10)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(hex: label.color).opacity(0.3))
                                    .foregroundStyle(Color(hex: label.color))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                Divider()

                if issueBody.isEmpty {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(issueBody)
                        .scaledFont(size: 13, design: .monospaced)
                        .textSelection(.enabled)
                }

                if !comments.isEmpty {
                    Divider()

                    Text("Comments (\(comments.count))")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(.secondary)

                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if let avatarURL = comment.authorAvatarURL {
                                    AsyncImage(url: avatarURL) { image in
                                        image.resizable()
                                    } placeholder: {
                                        Text(verbatim: String(comment.authorLogin.prefix(2)))
                                            .scaledFont(size: 7, weight: .medium)
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 16, height: 16)
                                    .background(Color.secondary.opacity(0.6))
                                    .clipShape(Circle())
                                }

                                Text("@\(comment.authorLogin)")
                                    .scaledFont(size: 12, weight: .medium)

                                Text(Self.dateFormatter.string(from: comment.createdAt))
                                    .scaledFont(size: 11)
                                    .foregroundStyle(.secondary)
                            }

                            Text(comment.body)
                                .scaledFont(size: 12, design: .monospaced)
                                .textSelection(.enabled)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.foreground.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                } else if comments.isEmpty, issue.commentCount > 0 {
                    Divider()
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading comments…")
                            .scaledFont(size: 12)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.background)
    }
}
