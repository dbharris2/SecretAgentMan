import Foundation
import OSLog

/// Fetches the current user's PRs across all repos using GitHub GraphQL API via `gh`.
actor GitHubPRService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.secretagentman",
        category: "GitHubPR"
    )

    private static let ghPath: String? = {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }()

    struct GitHubPR: Identifiable, Equatable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let repository: String
        let authorLogin: String
        let authorAvatarURL: URL?
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let commentCount: Int
        let reviewDecision: String?
        let isDraft: Bool
        let updatedAt: Date
        let reviewers: [PRReviewer]
        let checkStatus: PRCheckStatus
    }

    enum PRSection: String, CaseIterable {
        case needsMyReview = "Needs my review"
        case returnedToMe = "Returned to me"
        case approved = "Approved"
        case waitingForReview = "Waiting for review"
        case reviewed = "Reviewed"
        case drafts = "Drafts"
    }

    func fetchAllPRs() async -> [PRSection: [GitHubPR]] {
        guard Self.ghPath != nil else { return [:] }

        async let needsReview = fetchPRs(
            query: "is:pr is:open -is:draft review-requested:@me"
        )
        async let authored = fetchPRs(
            query: "is:pr is:open author:@me"
        )

        let reviewPRs = await needsReview
        let authoredPRs = await authored

        var sections: [PRSection: [GitHubPR]] = [:]

        // Needs my review: requested but I haven't approved or requested changes
        sections[.needsMyReview] = reviewPRs

        // Authored PRs split by state
        var returned: [GitHubPR] = []
        var approved: [GitHubPR] = []
        var waiting: [GitHubPR] = []
        var drafts: [GitHubPR] = []

        for pr in authoredPRs {
            if pr.isDraft {
                drafts.append(pr)
            } else if pr.reviewDecision == "CHANGES_REQUESTED" {
                returned.append(pr)
            } else if pr.reviewDecision == "APPROVED" {
                approved.append(pr)
            } else {
                waiting.append(pr)
            }
        }

        sections[.returnedToMe] = returned
        sections[.approved] = approved
        sections[.waitingForReview] = waiting
        sections[.drafts] = drafts

        return sections
    }

    private func fetchPRs(query: String) async -> [GitHubPR] {
        guard let ghPath = Self.ghPath else { return [] }

        let graphQL = """
        {
          search(query: "\(query)", type: ISSUE, first: 50) {
            nodes {
              ... on PullRequest {
                id
                number
                title
                url
                repository { nameWithOwner }
                author { login avatarUrl }
                additions
                deletions
                changedFiles
                reviewDecision
                isDraft
                updatedAt
                comments { totalCount }
                reviewRequests(first: 5) {
                  nodes {
                    requestedReviewer {
                      ... on User { login avatarUrl }
                    }
                  }
                }
                latestReviews(first: 5) {
                  nodes {
                    author { login avatarUrl }
                  }
                }
                statusCheckRollup { state }
              }
            }
          }
        }
        """

        let json = runSync(ghPath, args: ["api", "graphql", "-f", "query=\(graphQL)"])
        return parsePRs(from: json)
    }

    func parsePRs(from json: String) -> [GitHubPR] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any]
        else { return [] }

        // Find the first search result (key name varies)
        guard let searchObj = dataObj.values.first as? [String: Any],
              let nodes = searchObj["nodes"] as? [[String: Any]]
        else { return [] }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        return nodes.compactMap { node -> GitHubPR? in
            guard let id = node["id"] as? String,
                  let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let urlStr = node["url"] as? String,
                  let url = URL(string: urlStr),
                  let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String
            else { return nil }

            let author = node["author"] as? [String: Any]
            let authorLogin = author?["login"] as? String ?? ""
            let avatarStr = author?["avatarUrl"] as? String
            let avatarURL = avatarStr.flatMap { URL(string: $0 + "&size=36") }
            let updatedStr = node["updatedAt"] as? String ?? ""
            let updatedAt = dateFormatter.date(from: updatedStr) ?? Date()

            // Parse reviewers from requests + latest reviews, dedup, exclude author
            var seenLogins = Set<String>()
            seenLogins.insert(authorLogin)
            var reviewers: [PRReviewer] = []

            let requestNodes = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for req in requestNodes {
                if let reviewer = req["requestedReviewer"] as? [String: Any],
                   let login = reviewer["login"] as? String,
                   seenLogins.insert(login).inserted,
                   let avatarUrl = URL(string: "https://github.com/\(login).png?size=36") {
                    reviewers.append(PRReviewer(login: login, avatarURL: avatarUrl))
                }
            }
            let reviewNodes = ((node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for rev in reviewNodes {
                if let revAuthor = rev["author"] as? [String: Any],
                   let login = revAuthor["login"] as? String,
                   seenLogins.insert(login).inserted,
                   let avatarUrl = URL(string: "https://github.com/\(login).png?size=36") {
                    reviewers.append(PRReviewer(login: login, avatarURL: avatarUrl))
                }
            }

            let rollupState = (node["statusCheckRollup"] as? [String: Any])?["state"] as? String
            let checkStatus: PRCheckStatus = switch rollupState {
            case "SUCCESS": .pass
            case "FAILURE", "ERROR": .fail
            case "PENDING": .pending
            default: .none
            }

            return GitHubPR(
                id: id,
                number: number,
                title: title,
                url: url,
                repository: repo,
                authorLogin: authorLogin,
                authorAvatarURL: avatarURL,
                additions: node["additions"] as? Int ?? 0,
                deletions: node["deletions"] as? Int ?? 0,
                changedFiles: node["changedFiles"] as? Int ?? 0,
                commentCount: (node["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0,
                reviewDecision: node["reviewDecision"] as? String,
                isDraft: node["isDraft"] as? Bool ?? false,
                updatedAt: updatedAt,
                reviewers: reviewers,
                checkStatus: checkStatus
            )
        }
    }

    func fetchPRDiff(repo: String, number: Int) -> String {
        guard let ghPath = Self.ghPath else { return "" }
        return runSync(ghPath, args: ["pr", "diff", "\(number)", "--repo", repo])
    }

    private func runSync(_ command: String, args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            Self.logger.error("Failed to run gh: \(error)")
            return ""
        }
    }
}
