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

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
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
        let hasAnyApproval: Bool
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
        latestReviews(first: 5) { nodes { state author { login avatarUrl } } }
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
          reviewedByMe: search(query: "is:pr is:open -is:draft reviewed-by:@me -author:@me", type: ISSUE, first: 50) {
            nodes { ... on PullRequest { \(Self.prFields) } }
          }
        }
        """

        let json = runSync(ghPath, args: ["api", "graphql", "-f", "query=\(graphQL)"])
        guard let payload: GraphQLResponse<AllPRsData> = Self.decode(json),
              let data = payload.data
        else { return [:] }

        return Self.categorize(
            reviewRequested: data.needsReview.nodes.map(Self.makeGitHubPR),
            authored: data.authored.nodes.map(Self.makeGitHubPR),
            reviewedByMe: data.reviewedByMe.nodes.map(Self.makeGitHubPR)
        )
    }

    /// Bucket the three GitHub search result sets into UI sections. Pure function — exposed
    /// internally so tests can exercise the bucketing without spawning `gh`.
    static func categorize(
        reviewRequested: [GitHubPR],
        authored: [GitHubPR],
        reviewedByMe: [GitHubPR]
    ) -> [PRSection: [GitHubPR]] {
        // A requested-reviewer PR moves to "Reviewed" once it has a state-changing review
        // (APPROVED / CHANGES_REQUESTED at PR level, or any APPROVED review when the repo
        // lacks branch protection so reviewDecision stays nil).
        let needsReviewPRs = reviewRequested.filter { pr in
            pr.reviewDecision != "APPROVED"
                && pr.reviewDecision != "CHANGES_REQUESTED"
                && !pr.hasAnyApproval
        }
        let requestedWithStateChange = reviewRequested.filter { pr in
            pr.reviewDecision == "APPROVED"
                || pr.reviewDecision == "CHANGES_REQUESTED"
                || pr.hasAnyApproval
        }

        var sections: [PRSection: [GitHubPR]] = [:]
        sections[.needsMyReview] = needsReviewPRs

        let needsReviewIds = Set(needsReviewPRs.map(\.id))
        var seenReviewedIds = Set<String>()
        sections[.reviewed] = (reviewedByMe + requestedWithStateChange).filter { pr in
            seenReviewedIds.insert(pr.id).inserted && !needsReviewIds.contains(pr.id)
        }

        var returned: [GitHubPR] = []
        var approved: [GitHubPR] = []
        var waiting: [GitHubPR] = []
        var drafts: [GitHubPR] = []

        for pr in authored {
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

    /// Fetch deep fields (review comments, failed checks) for a single PR.
    /// Called on-demand when a state transition is detected.
    func fetchDeepPRInfo(
        repo: String,
        number: Int
    ) -> (reviewComments: [PRReviewComment], failedChecks: [String], detailedCheckStatus: PRCheckStatus) {
        guard let ghPath = Self.ghPath else { return ([], [], .none) }

        let owner = repo.components(separatedBy: "/").first ?? ""
        let name = repo.components(separatedBy: "/").last ?? ""
        let graphQL = """
        {
          repository(owner: "\(owner)", name: "\(name)") {
            pullRequest(number: \(number)) {
              author { login avatarUrl }
              reviews(first: 20) { nodes { author { login avatarUrl } body state } }
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
        guard let payload: GraphQLResponse<DeepPRData> = Self.decode(json),
              let pr = payload.data?.repository?.pullRequest
        else { return ([], [], .none) }

        let authorLogin = pr.author?.login ?? ""

        let reviewComments = pr.reviews.nodes.compactMap { review -> PRReviewComment? in
            guard let reviewer = review.author?.login, reviewer != authorLogin,
                  !review.body.isEmpty,
                  let state = PRReviewState(rawValue: review.state)
            else { return nil }
            return PRReviewComment(author: reviewer, body: review.body, state: state)
        }

        let checks = pr.statusCheckRollup?.contexts.nodes ?? []
        let failedChecks = checks.compactMap(\.failureName)

        let detailedCheckStatus: PRCheckStatus = {
            if checks.isEmpty { return .none }
            var hasIncomplete = false
            for check in checks {
                switch check.health {
                case .fail: return .fail
                case .incomplete: hasIncomplete = true
                case .pass: continue
                }
            }
            return hasIncomplete ? .pending : .pass
        }()

        return (reviewComments, failedChecks, detailedCheckStatus)
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
        guard let response: RateLimitResponse = Self.decode(json) else { return nil }
        let g = response.resources.graphql
        return RateLimit(used: g.used, limit: g.limit, remaining: g.remaining)
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

    private static func decode<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            logger.error("Decode \(String(describing: T.self), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - DTO → domain mapping

private extension GitHubPRService {
    static func makeGitHubPR(_ dto: PRNode) -> GitHubPR {
        let authorLogin = dto.author?.login ?? ""
        let authorAvatarURL = dto.author?.avatarUrl.flatMap {
            URL(string: $0.absoluteString + "&size=36")
        }

        var seen = Set([authorLogin])
        var reviewers: [PRReviewer] = []

        for request in dto.reviewRequests.nodes {
            guard let reviewer = request.requestedReviewer else { continue }
            let (identifier, avatar): (String, URL?) = switch reviewer {
            case let .user(login), let .mannequin(login):
                (login, URL(string: "https://github.com/\(login).png?size=36"))
            case let .team(name, avatarUrl):
                (name, avatarUrl)
            }
            guard seen.insert(identifier).inserted, let avatar else { continue }
            reviewers.append(PRReviewer(login: identifier, avatarURL: avatar))
        }

        for review in dto.latestReviews.nodes {
            guard let login = review.author?.login,
                  seen.insert(login).inserted,
                  let avatar = URL(string: "https://github.com/\(login).png?size=36")
            else { continue }
            reviewers.append(PRReviewer(login: login, avatarURL: avatar))
        }

        let checkStatus: PRCheckStatus = switch dto.statusCheckRollup?.state {
        case "SUCCESS": .pass
        case "FAILURE", "ERROR": .fail
        case "PENDING": .pending
        default: .none
        }

        return GitHubPR(
            id: dto.id,
            number: dto.number,
            title: dto.title,
            url: dto.url,
            repository: dto.repository.nameWithOwner,
            headRefName: dto.headRefName,
            authorLogin: authorLogin,
            authorAvatarURL: authorAvatarURL,
            additions: dto.additions,
            deletions: dto.deletions,
            changedFiles: dto.changedFiles,
            commentCount: dto.totalCommentsCount,
            reviewDecision: dto.reviewDecision,
            isDraft: dto.isDraft,
            mergeStateStatus: dto.mergeStateStatus,
            updatedAt: dto.updatedAt,
            reviewers: reviewers,
            checkStatus: checkStatus,
            hasAnyApproval: dto.hasAnyApproval
        )
    }
}

private extension GitHubPRService.PRNode {
    var hasAnyApproval: Bool {
        latestReviews.nodes.contains { $0.state == "APPROVED" }
    }
}

// MARK: - GraphQL response DTOs

private extension GitHubPRService {
    struct GraphQLResponse<Payload: Decodable>: Decodable {
        let data: Payload?
    }

    struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node]
    }

    struct Author: Decodable {
        let login: String
        let avatarUrl: URL?
    }

    struct Repository: Decodable {
        let nameWithOwner: String
    }

    // MARK: Search / PR list

    struct AllPRsData: Decodable {
        let needsReview: Connection<PRNode>
        let authored: Connection<PRNode>
        let reviewedByMe: Connection<PRNode>
    }

    struct PRNode: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let headRefName: String
        let repository: Repository
        let author: Author?
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let totalCommentsCount: Int
        let reviewDecision: String?
        let isDraft: Bool
        let mergeStateStatus: String
        let updatedAt: Date
        let reviewRequests: Connection<ReviewRequestNode>
        let latestReviews: Connection<LatestReviewNode>
        let statusCheckRollup: RollupStateNode?
    }

    struct ReviewRequestNode: Decodable {
        let requestedReviewer: RequestedReviewer?
    }

    enum RequestedReviewer: Decodable {
        case user(login: String)
        case team(name: String, avatarUrl: URL?)
        case mannequin(login: String)

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case login, name, avatarUrl
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .typename) {
            case "User":
                self = try .user(login: c.decode(String.self, forKey: .login))
            case "Team":
                self = try .team(
                    name: c.decode(String.self, forKey: .name),
                    avatarUrl: c.decodeIfPresent(URL.self, forKey: .avatarUrl)
                )
            case "Mannequin":
                self = try .mannequin(login: c.decode(String.self, forKey: .login))
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .typename, in: c,
                    debugDescription: "Unknown requestedReviewer type: \(other)"
                )
            }
        }
    }

    struct LatestReviewNode: Decodable {
        let state: String?
        let author: Author?
    }

    struct RollupStateNode: Decodable {
        let state: String?
    }

    // MARK: Deep PR info

    struct DeepPRData: Decodable {
        let repository: DeepRepository?
    }

    struct DeepRepository: Decodable {
        let pullRequest: DeepPullRequest?
    }

    struct DeepPullRequest: Decodable {
        let author: Author?
        let reviews: Connection<DeepReviewNode>
        let statusCheckRollup: DeepRollupNode?
    }

    struct DeepReviewNode: Decodable {
        let author: Author?
        let body: String
        let state: String
    }

    struct DeepRollupNode: Decodable {
        let contexts: Connection<CheckContextNode>
    }

    enum CheckContextNode: Decodable {
        case checkRun(name: String, status: String, conclusion: String?)
        case statusContext(context: String, state: String)

        enum Health { case pass, fail, incomplete }

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case name, status, conclusion, context, state
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .typename) {
            case "CheckRun":
                self = try .checkRun(
                    name: c.decode(String.self, forKey: .name),
                    status: c.decode(String.self, forKey: .status),
                    conclusion: c.decodeIfPresent(String.self, forKey: .conclusion)
                )
            case "StatusContext":
                self = try .statusContext(
                    context: c.decode(String.self, forKey: .context),
                    state: c.decode(String.self, forKey: .state)
                )
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .typename, in: c,
                    debugDescription: "Unknown statusCheckRollup context type: \(other)"
                )
            }
        }

        var failureName: String? {
            switch self {
            case let .checkRun(name, _, conclusion):
                (conclusion == "FAILURE" || conclusion == "ERROR") ? name : nil
            case let .statusContext(context, state):
                (state == "FAILURE" || state == "ERROR") ? context : nil
            }
        }

        var health: Health {
            switch self {
            case let .checkRun(_, status, conclusion):
                if conclusion == "FAILURE" || conclusion == "ERROR"
                    || conclusion == "CANCELLED" || conclusion == "TIMED_OUT" {
                    .fail
                } else if status == "COMPLETED" {
                    .pass
                } else {
                    .incomplete
                }
            case let .statusContext(_, state):
                if state == "FAILURE" || state == "ERROR" {
                    .fail
                } else if state == "SUCCESS" {
                    .pass
                } else {
                    .incomplete
                }
            }
        }
    }

    // MARK: Rate limit (REST)

    struct RateLimitResponse: Decodable {
        let resources: RateLimitResources
    }

    struct RateLimitResources: Decodable {
        let graphql: RateLimitValues
    }

    struct RateLimitValues: Decodable {
        let used: Int
        let limit: Int
        let remaining: Int
    }
}
