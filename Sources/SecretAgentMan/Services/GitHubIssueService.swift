import Foundation
import OSLog

actor GitHubIssueService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.secretagentman",
        category: "GitHubIssue"
    )

    private static let ghPath: String? = {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }()

    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let issueFields = """
        id number title url
        repository { nameWithOwner }
        author { login avatarUrl }
        labels(first: 10) { nodes { name color } }
        comments { totalCount }
        createdAt updatedAt
    """

    func fetchAllIssues() -> [IssueSection: [GitHubIssue]] {
        guard let ghPath = Self.ghPath else { return [:] }

        let graphQL = """
        {
          assigned: search(query: "is:issue is:open assignee:@me sort:updated-desc", type: ISSUE, first: 50) {
            nodes { ... on Issue { \(Self.issueFields) } }
          }
          mentioned: search(query: "is:issue is:open mentions:@me -assignee:@me sort:updated-desc", type: ISSUE, first: 30) {
            nodes { ... on Issue { \(Self.issueFields) } }
          }
          authored: search(query: "is:issue is:open author:@me -assignee:@me sort:updated-desc", type: ISSUE, first: 30) {
            nodes { ... on Issue { \(Self.issueFields) } }
          }
        }
        """

        let json = runSync(ghPath, args: ["api", "graphql", "-f", "query=\(graphQL)"])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any]
        else { return [:] }

        var sections: [IssueSection: [GitHubIssue]] = [:]

        let sectionMap: [(key: String, section: IssueSection)] = [
            ("assigned", .assigned),
            ("mentioned", .mentioned),
            ("authored", .authored),
        ]

        for (key, section) in sectionMap {
            guard let searchObj = dataObj[key] as? [String: Any],
                  let nodes = searchObj["nodes"] as? [[String: Any]]
            else { continue }
            sections[section] = nodes.compactMap { parseIssueNode($0) }
        }

        return sections
    }

    struct IssueDetail {
        let body: String
        let comments: [IssueComment]
    }

    func fetchIssueDetail(repo: String, number: Int) -> IssueDetail {
        guard let ghPath = Self.ghPath else { return IssueDetail(body: "", comments: []) }

        let owner = repo.components(separatedBy: "/").first ?? ""
        let name = repo.components(separatedBy: "/").last ?? ""

        let graphQL = """
        {
          repository(owner: "\(owner)", name: "\(name)") {
            issue(number: \(number)) {
              body
              comments(first: 50) {
                nodes {
                  id
                  author { login avatarUrl }
                  body
                  createdAt
                }
              }
            }
          }
        }
        """

        let json = runSync(ghPath, args: ["api", "graphql", "-f", "query=\(graphQL)"])
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let repoObj = dataObj["repository"] as? [String: Any],
              let issueObj = repoObj["issue"] as? [String: Any]
        else { return IssueDetail(body: "", comments: []) }

        let body = issueObj["body"] as? String ?? ""
        let commentsObj = issueObj["comments"] as? [String: Any]
        let nodes = (commentsObj?["nodes"] as? [[String: Any]]) ?? []
        let comments = nodes.compactMap { parseCommentNode($0) }

        return IssueDetail(body: body, comments: comments)
    }

    private func parseIssueNode(_ node: [String: Any]) -> GitHubIssue? {
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

        let labelNodes = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let labels = labelNodes.compactMap { labelNode -> IssueLabel? in
            guard let name = labelNode["name"] as? String,
                  let color = labelNode["color"] as? String
            else { return nil }
            return IssueLabel(name: name, color: color)
        }

        let commentCount = (node["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0
        let createdStr = node["createdAt"] as? String ?? ""
        let updatedStr = node["updatedAt"] as? String ?? ""
        let createdAt = dateFormatter.date(from: createdStr) ?? Date()
        let updatedAt = dateFormatter.date(from: updatedStr) ?? Date()

        return GitHubIssue(
            id: id,
            number: number,
            title: title,
            url: url,
            repository: repo,
            authorLogin: authorLogin,
            authorAvatarURL: avatarURL,
            labels: labels,
            commentCount: commentCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func parseCommentNode(_ node: [String: Any]) -> IssueComment? {
        guard let id = node["id"] as? String,
              let body = node["body"] as? String
        else { return nil }

        let author = node["author"] as? [String: Any]
        let authorLogin = author?["login"] as? String ?? ""
        let avatarStr = author?["avatarUrl"] as? String
        let avatarURL = avatarStr.flatMap { URL(string: $0 + "&size=36") }
        let createdStr = node["createdAt"] as? String ?? ""
        let createdAt = dateFormatter.date(from: createdStr) ?? Date()

        return IssueComment(
            id: id,
            authorLogin: authorLogin,
            authorAvatarURL: avatarURL,
            body: body,
            createdAt: createdAt
        )
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
