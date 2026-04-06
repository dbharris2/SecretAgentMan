import Foundation

actor PRService {
    private static let ghPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }()

    func fetchPRInfo(in directory: URL) -> PRInfo? {
        guard let ghPath = Self.ghPath else { return nil }

        let branch = detectBranch(in: directory)
        guard let branch, !branch.isEmpty else { return nil }

        let json = runSync(
            ghPath,
            args: [
                "pr", "list", "--head", branch,
                "--json",
                "number,url,isDraft,state,statusCheckRollup,additions,deletions,changedFiles,comments,reviews,reviewRequests,author,reviewDecision,mergeStateStatus",
                "--limit", "1",
            ],
            in: directory
        )

        return parsePRInfo(from: json)
    }

    private func detectBranch(in directory: URL) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent(".jj").path) {
            let raw = runSync(
                "/opt/homebrew/bin/jj",
                args: ["log", "-r", "@", "--no-graph", "-T", "bookmarks"],
                in: directory
            )
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip jj's trailing * (indicates local bookmark changes not yet pushed)
            return trimmed.components(separatedBy: " ").first { !$0.isEmpty }?
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        } else if fm.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            let raw = runSync("/usr/bin/git", args: ["branch", "--show-current"], in: directory)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func parsePRInfo(from json: String) -> PRInfo? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let number = first["number"] as? Int,
              let urlString = first["url"] as? String,
              let url = URL(string: urlString)
        else { return nil }

        let isDraft = first["isDraft"] as? Bool ?? false
        let ghState = first["state"] as? String ?? ""
        let reviewDecision = first["reviewDecision"] as? String ?? ""
        let mergeStateStatus = first["mergeStateStatus"] as? String ?? ""
        let prState: PRState = if ghState == "MERGED" {
            .merged
        } else if isDraft {
            .draft
        } else if mergeStateStatus == "QUEUED" || mergeStateStatus == "UNSTABLE" {
            .inMergeQueue
        } else if reviewDecision == "CHANGES_REQUESTED" {
            .changesRequested
        } else if reviewDecision == "APPROVED" {
            .approved
        } else {
            .needsReview
        }
        let checks = first["statusCheckRollup"] as? [[String: Any]] ?? []
        let checkStatus = parseCheckStatus(from: checks)
        let additions = first["additions"] as? Int ?? 0
        let deletions = first["deletions"] as? Int ?? 0
        let changedFiles = first["changedFiles"] as? Int ?? 0
        let comments = first["comments"] as? [[String: Any]] ?? []
        let reviews = first["reviews"] as? [[String: Any]] ?? []
        let reviewRequests = first["reviewRequests"] as? [[String: Any]] ?? []

        // Collect unique reviewers, excluding the PR author
        let authorLogin = (first["author"] as? [String: Any])?["login"] as? String
        let reviewLogins = reviews.compactMap { ($0["author"] as? [String: Any])?["login"] as? String }
        let requestLogins = reviewRequests.compactMap { $0["login"] as? String }
        var seen = Set<String>()
        if let authorLogin { seen.insert(authorLogin) }
        let reviewers = (reviewLogins + requestLogins).compactMap { login -> PRReviewer? in
            guard seen.insert(login).inserted,
                  let avatarURL = URL(string: "https://github.com/\(login).png?size=36")
            else { return nil }
            return PRReviewer(login: login, avatarURL: avatarURL)
        }

        // Extract review comments with non-empty bodies, excluding bots
        let reviewComments = reviews.compactMap { review -> PRReviewComment? in
            guard let author = (review["author"] as? [String: Any])?["login"] as? String,
                  let body = review["body"] as? String,
                  !body.isEmpty,
                  let stateStr = review["state"] as? String,
                  let state = PRReviewState(rawValue: stateStr),
                  author != authorLogin
            else { return nil }
            return PRReviewComment(author: author, body: body, state: state)
        }

        // Extract names of failed checks
        let failedChecks = checks.compactMap { check -> String? in
            let conclusion = check["conclusion"] as? String ?? ""
            guard conclusion == "FAILURE" || conclusion == "ERROR" else { return nil }
            return check["name"] as? String
        }

        return PRInfo(
            number: number,
            url: url,
            state: prState,
            checkStatus: checkStatus,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            commentCount: comments.count,
            reviewers: reviewers,
            reviewComments: reviewComments,
            failedChecks: failedChecks
        )
    }

    private func parseCheckStatus(from checks: [[String: Any]]) -> PRCheckStatus {
        if checks.isEmpty { return .none }

        var hasIncomplete = false
        for check in checks {
            let typename = check["__typename"] as? String ?? ""

            if typename == "StatusContext" {
                // Commit status API uses "state" instead of "status"/"conclusion"
                let state = check["state"] as? String ?? ""
                if state == "FAILURE" || state == "ERROR" {
                    return .fail
                }
                if state != "SUCCESS" {
                    hasIncomplete = true
                }
            } else {
                // CheckRun uses "status" and "conclusion"
                let conclusion = check["conclusion"] as? String ?? ""
                let status = check["status"] as? String ?? ""

                if conclusion == "FAILURE" || conclusion == "ERROR"
                    || conclusion == "CANCELLED" || conclusion == "TIMED_OUT" {
                    return .fail
                }
                if status != "COMPLETED" {
                    hasIncomplete = true
                }
            }
        }

        return hasIncomplete ? .pending : .pass
    }

    private func runSync(_ command: String, args: [String], in directory: URL) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
