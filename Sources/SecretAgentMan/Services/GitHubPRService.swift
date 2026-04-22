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

    struct RateLimit: Equatable {
        let used: Int
        let limit: Int
        let remaining: Int
    }

    struct GitHubPR: Identifiable, Equatable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let repository: String
        let headRefName: String
        let authorLogin: String
        let authorAvatarURL: URL?
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let commentCount: Int
        let reviewDecision: String?
        let isDraft: Bool
        let mergeStateStatus: String
        let updatedAt: Date
        let reviewers: [PRReviewer]
        let checkStatus: PRCheckStatus
    }

    // MARK: - Authored PRs → PRInfo (for agent sidebar)

    static func prInfo(from pr: GitHubPR) -> PRInfo {
        let ghState = pr.mergeStateStatus
        let prState: PRState = if pr.isDraft {
            .draft
        } else if ghState == "QUEUED" || ghState == "UNSTABLE" {
            .inMergeQueue
        } else if pr.reviewDecision == "CHANGES_REQUESTED" {
            .changesRequested
        } else if pr.reviewDecision == "APPROVED" {
            .approved
        } else {
            .needsReview
        }

        return PRInfo(
            number: pr.number,
            url: pr.url,
            state: prState,
            checkStatus: pr.checkStatus,
            additions: pr.additions,
            deletions: pr.deletions,
            changedFiles: pr.changedFiles,
            commentCount: pr.commentCount,
            reviewers: pr.reviewers,
            reviewComments: [],
            failedChecks: []
        )
    }

    enum PRSection: String, CaseIterable {
        case needsMyReview = "Needs my review"
        case returnedToMe = "Returned to me"
        case approved = "Approved"
        case waitingForReview = "Waiting for review"
        case reviewed = "Reviewed"
        case drafts = "Drafts"

        var isAuthored: Bool {
            switch self {
            case .returnedToMe, .approved, .waitingForReview, .drafts: true
            case .needsMyReview, .reviewed: false
            }
        }
    }

    private static let prFields = """
        id number title url headRefName
        repository { nameWithOwner }
        author { login avatarUrl }
        additions deletions changedFiles
        reviewDecision isDraft mergeStateStatus updatedAt
        totalCommentsCount
        reviewRequests(first: 5) { nodes { requestedReviewer {
            __typename
            ... on User { login avatarUrl }
            ... on Team { name avatarUrl }
            ... on Mannequin { login avatarUrl }
        } } }
        latestReviews(first: 5) { nodes { author { login avatarUrl } } }
        statusCheckRollup { state }
    """

    /// Fetches all PR sections in a single GraphQL call.
    func fetchAllPRs() async -> [PRSection: [GitHubPR]] {
        guard let ghPath = Self.ghPath else { return [:] }

        let graphQL = """
        {
          needsReview: search(query: "is:pr is:open -is:draft review-requested:@me", type: ISSUE, first: 50) {
            nodes { ... on PullRequest { \(Self.prFields) } }
          }
          authored: search(query: "is:pr is:open author:@me", type: ISSUE, first: 50) {
            nodes { ... on PullRequest { \(Self.prFields) } }
          }
          reviewedByMe: search(query: "is:pr is:open reviewed-by:@me -author:@me", type: ISSUE, first: 50) {
            nodes { ... on PullRequest { \(Self.prFields) } }
          }
        }
        """

        let json = runSync(ghPath, args: ["api", "graphql", "-f", "query=\(graphQL)"])
        let parsed = parseMultiSearch(json: json)

        let reviewPRs = parsed["needsReview"] ?? []
        let authoredPRs = parsed["authored"] ?? []
        let reviewedPRs = parsed["reviewedByMe"] ?? []

        var sections: [PRSection: [GitHubPR]] = [:]
        sections[.needsMyReview] = reviewPRs

        let needsReviewIds = Set(reviewPRs.map(\.id))
        sections[.reviewed] = reviewedPRs.filter { !needsReviewIds.contains($0.id) }

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

    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func parseMultiSearch(json: String) -> [String: [GitHubPR]] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any]
        else { return [:] }

        var result: [String: [GitHubPR]] = [:]
        for (key, value) in dataObj {
            guard let searchObj = value as? [String: Any],
                  let nodes = searchObj["nodes"] as? [[String: Any]]
            else { continue }
            result[key] = nodes.compactMap { parseNode($0, dateFormatter: dateFormatter) }
        }
        return result
    }

    /// Fetch deep fields (review comments, failed checks) for a single PR.
    /// Called on-demand when a state transition is detected.
    func fetchDeepPRInfo(
        repo: String,
        number: Int
    ) -> (reviewComments: [PRReviewComment], failedChecks: [String], detailedCheckStatus: PRCheckStatus) {
        guard let ghPath = Self.ghPath else { return ([], [], .none) }

        let graphQL = """
        {
          repository(owner: "\(repo.components(separatedBy: "/").first ?? "")", name: "\(repo.components(separatedBy: "/").last ?? "")") {
            pullRequest(number: \(number)) {
              author { login }
              reviews(first: 20) { nodes { author { login } body state } }
              statusCheckRollup { contexts(first: 50) { nodes {
                __typename
                ... on CheckRun { name status conclusion }
                ... on StatusContext { context state }
              } } }
            }
          }
        }
        """

        let json = runSync(ghPath, args: ["api", "graphql", "-f", "query=\(graphQL)"])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repoObj = dataObj["repository"] as? [String: Any],
              let prObj = repoObj["pullRequest"] as? [String: Any]
        else { return ([], [], .none) }

        let authorLogin = (prObj["author"] as? [String: Any])?["login"] as? String ?? ""

        let reviewsNodes = ((prObj["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let reviewComments = reviewsNodes.compactMap { review -> PRReviewComment? in
            guard let revAuthor = (review["author"] as? [String: Any])?["login"] as? String,
                  let body = review["body"] as? String,
                  !body.isEmpty,
                  let stateStr = review["state"] as? String,
                  let state = PRReviewState(rawValue: stateStr),
                  revAuthor != authorLogin
            else { return nil }
            return PRReviewComment(author: revAuthor, body: body, state: state)
        }

        let rollupObj = prObj["statusCheckRollup"] as? [String: Any]
        let contextsObj = rollupObj?["contexts"] as? [String: Any]
        let checkNodes = (contextsObj?["nodes"] as? [[String: Any]]) ?? []

        let failedChecks = checkNodes.compactMap { check -> String? in
            let conclusion = check["conclusion"] as? String ?? ""
            let state = check["state"] as? String ?? ""
            guard conclusion == "FAILURE" || conclusion == "ERROR"
                || state == "FAILURE" || state == "ERROR"
            else { return nil }
            return check["name"] as? String ?? check["context"] as? String
        }

        let detailedCheckStatus: PRCheckStatus = {
            if checkNodes.isEmpty { return .none }
            var hasIncomplete = false
            for check in checkNodes {
                let typename = check["__typename"] as? String ?? ""
                if typename == "StatusContext" {
                    let st = check["state"] as? String ?? ""
                    if st == "FAILURE" || st == "ERROR" { return .fail }
                    if st != "SUCCESS" { hasIncomplete = true }
                } else {
                    let conclusion = check["conclusion"] as? String ?? ""
                    let status = check["status"] as? String ?? ""
                    if conclusion == "FAILURE" || conclusion == "ERROR"
                        || conclusion == "CANCELLED" || conclusion == "TIMED_OUT" {
                        return .fail
                    }
                    if status != "COMPLETED" { hasIncomplete = true }
                }
            }
            return hasIncomplete ? .pending : .pass
        }()

        return (reviewComments, failedChecks, detailedCheckStatus)
    }

    func parseNode(_ node: [String: Any], dateFormatter: ISO8601DateFormatter) -> GitHubPR? {
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
            guard let reviewer = req["requestedReviewer"] as? [String: Any] else { continue }
            let isTeam = (reviewer["__typename"] as? String) == "Team"
            guard let identifier = (reviewer["login"] as? String) ?? (reviewer["name"] as? String),
                  seenLogins.insert(identifier).inserted
            else { continue }
            let avatarURL: URL? = isTeam
                ? (reviewer["avatarUrl"] as? String).flatMap { URL(string: $0) }
                : URL(string: "https://github.com/\(identifier).png?size=36")
            guard let avatarURL else { continue }
            reviewers.append(PRReviewer(login: identifier, avatarURL: avatarURL))
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

        let rollupObj = node["statusCheckRollup"] as? [String: Any]
        let rollupState = rollupObj?["state"] as? String
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
            headRefName: node["headRefName"] as? String ?? "",
            authorLogin: authorLogin,
            authorAvatarURL: avatarURL,
            additions: node["additions"] as? Int ?? 0,
            deletions: node["deletions"] as? Int ?? 0,
            changedFiles: node["changedFiles"] as? Int ?? 0,
            commentCount: node["totalCommentsCount"] as? Int ?? 0,
            reviewDecision: node["reviewDecision"] as? String,
            isDraft: node["isDraft"] as? Bool ?? false,
            mergeStateStatus: node["mergeStateStatus"] as? String ?? "",
            updatedAt: updatedAt,
            reviewers: reviewers,
            checkStatus: checkStatus
        )
    }

    func addReviewers(repo: String, number: Int, reviewers: [String]) -> Bool {
        guard !reviewers.isEmpty else { return false }
        let reviewerArgs = reviewers.flatMap { ["--add-reviewer", $0] }
        return runPRCommand(["edit", "\(number)", "--repo", repo] + reviewerArgs)
    }

    func closePR(repo: String, number: Int) -> Bool {
        runPRCommand(["close", "\(number)", "--repo", repo])
    }

    func convertToDraft(repo: String, number: Int) -> Bool {
        runPRCommand(["ready", "\(number)", "--repo", repo, "--undo"])
    }

    func markPRReady(repo: String, number: Int) -> Bool {
        runPRCommand(["ready", "\(number)", "--repo", repo])
    }

    private func runPRCommand(_ subArgs: [String]) -> Bool {
        guard let ghPath = Self.ghPath else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["pr"] + subArgs
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Self.logger.error("gh pr \(subArgs.first ?? "") failed: \(error)")
            return false
        }
    }

    func fetchRateLimit() -> RateLimit? {
        guard let ghPath = Self.ghPath else { return nil }
        let json = runSync(ghPath, args: ["api", "rate_limit"])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = root["resources"] as? [String: Any],
              let graphql = resources["graphql"] as? [String: Any],
              let used = graphql["used"] as? Int,
              let limit = graphql["limit"] as? Int,
              let remaining = graphql["remaining"] as? Int
        else { return nil }
        return RateLimit(used: used, limit: limit, remaining: remaining)
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
