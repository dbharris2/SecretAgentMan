import Foundation

actor DiffService {
    enum VCSType {
        case jj
        case graphite
        case git
        case none
    }

    struct DiffSnapshot {
        let fullDiff: String
        let changes: [FileChange]
    }

    nonisolated func detectVCS(in directory: URL) -> VCSType {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent(".jj").path) {
            return .jj
        } else if fm.fileExists(atPath: directory.appendingPathComponent(".git/.graphite_repo_config").path) {
            return .graphite
        } else if fm.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            return .git
        }
        return .none
    }

    nonisolated func fetchBranchName(in directory: URL) async -> String? {
        let vcs = detectVCS(in: directory)
        let raw: String
        switch vcs {
        case .jj:
            raw = await runCommand(
                "/opt/homebrew/bin/jj",
                args: [
                    "log", "-r", "@", "--no-graph", "-T",
                    "if(description, description.first_line(), change_id.shortest(8))",
                ],
                in: directory
            ) ?? ""
        case .graphite, .git:
            raw = await runCommand("/usr/bin/git", args: ["branch", "--show-current"], in: directory) ?? ""
        case .none:
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Get the "owner/repo" name from git remote (local, no API call). Suitable for caching.
    nonisolated func fetchRepoName(in directory: URL) async -> String? {
        let remoteRaw = await runCommand("/usr/bin/git", args: ["remote", "get-url", "origin"], in: directory) ?? ""
        return Self.parseRepoFromRemote(remoteRaw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Get the actual branch/bookmark name for PR matching (distinct from display name for jj repos).
    nonisolated func fetchBookmark(in directory: URL) async -> String? {
        let vcs = detectVCS(in: directory)
        switch vcs {
        case .jj:
            let raw = await runCommand(
                "/opt/homebrew/bin/jj",
                args: ["log", "-r", "@", "--no-graph", "-T", "bookmarks"],
                in: directory
            ) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.components(separatedBy: " ").first { !$0.isEmpty }?
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        case .graphite, .git:
            let raw = await runCommand("/usr/bin/git", args: ["branch", "--show-current"], in: directory) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .none:
            return nil
        }
    }

    /// Parse "owner/repo" from a git remote URL (SSH or HTTPS).
    static func parseRepoFromRemote(_ remote: String) -> String? {
        // git@github.com:owner/repo.git or https://github.com/owner/repo.git
        var path = remote
        if path.contains("github.com:") {
            path = path.components(separatedBy: "github.com:").last ?? ""
        } else if path.contains("github.com/") {
            path = path.components(separatedBy: "github.com/").last ?? ""
        } else {
            return nil
        }
        path = path.replacingOccurrences(of: ".git", with: "")
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Returns the full diff, or `nil` if the VCS command failed (non-zero exit or launch error).
    /// Empty string means "no changes"; `nil` signals a transient/real error the caller should handle.
    nonisolated func fetchFullDiff(in directory: URL) async -> String? {
        let vcs = detectVCS(in: directory)
        switch vcs {
        case .jj:
            return await runCommand("/opt/homebrew/bin/jj", args: ["diff", "--git"], in: directory)
        case .graphite, .git:
            return await fetchGitWorkingTreeDiff(in: directory, locationsByPath: nil)
        case .none:
            return ""
        }
    }

    nonisolated func fetchWorkingTreeSnapshot(in directory: URL) async -> DiffSnapshot? {
        let vcs = detectVCS(in: directory)
        switch vcs {
        case .jj:
            guard let diff = await fetchFullDiff(in: directory) else { return nil }
            return DiffSnapshot(fullDiff: diff, changes: parseChanges(from: diff))
        case .graphite, .git:
            guard let status = await runCommand(
                "/usr/bin/git",
                args: ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
                in: directory
            ) else { return nil }
            let locationsByPath = parseGitStatusLocations(status)
            guard let diff = await fetchGitWorkingTreeDiff(in: directory, locationsByPath: locationsByPath) else {
                return nil
            }
            return DiffSnapshot(
                fullDiff: diff,
                changes: parseChanges(from: diff, locationsByPath: locationsByPath)
            )
        case .none:
            return DiffSnapshot(fullDiff: "", changes: [])
        }
    }

    /// Extract file changes directly from unified diff output (no truncation).
    nonisolated func parseChanges(
        from diff: String,
        locationsByPath: [String: Set<FileChange.ChangeLocation>] = [:]
    ) -> [FileChange] {
        var changes: [FileChange] = []
        let lines = diff.components(separatedBy: "\n")

        var currentPath: String?
        var insertions = 0
        var deletions = 0
        var isNewFile = false
        var isDeletedFile = false

        for line in lines {
            if line.hasPrefix("diff --git") {
                // Flush previous file
                if let path = currentPath {
                    let status = fileStatus(
                        isNew: isNewFile,
                        isDeleted: isDeletedFile,
                        insertions: insertions,
                        deletions: deletions
                    )
                    changes.append(FileChange(
                        id: path,
                        path: path,
                        insertions: insertions,
                        deletions: deletions,
                        status: status,
                        locations: locationsByPath[path] ?? []
                    ))
                }

                // Parse path from "diff --git a/path b/path"
                currentPath = extractPath(from: line)
                insertions = 0
                deletions = 0
                isNewFile = false
                isDeletedFile = false
            } else if line.hasPrefix("new file") {
                isNewFile = true
            } else if line.hasPrefix("deleted file") {
                isDeletedFile = true
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                insertions += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                deletions += 1
            }
        }

        // Flush last file
        if let path = currentPath {
            let status = fileStatus(
                isNew: isNewFile,
                isDeleted: isDeletedFile,
                insertions: insertions,
                deletions: deletions
            )
            changes.append(FileChange(
                id: path,
                path: path,
                insertions: insertions,
                deletions: deletions,
                status: status,
                locations: locationsByPath[path] ?? []
            ))
        }

        guard !locationsByPath.isEmpty else { return changes }
        let diffPaths = Set(changes.map(\.path))
        let statusOnlyChanges = locationsByPath
            .filter { !diffPaths.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { path, locations in
                FileChange(
                    id: path,
                    path: path,
                    insertions: 0,
                    deletions: 0,
                    status: .modified,
                    locations: locations
                )
            }

        return changes + statusOnlyChanges
    }

    private nonisolated func fetchGitWorkingTreeDiff(
        in directory: URL,
        locationsByPath: [String: Set<FileChange.ChangeLocation>]?
    ) async -> String? {
        var parts: [String] = []
        let hasHead = await runCommand("/usr/bin/git", args: ["rev-parse", "--verify", "HEAD"], in: directory) != nil

        if hasHead {
            guard let trackedDiff = await runCommand(
                "/usr/bin/git",
                args: ["diff", "--no-color", "HEAD", "--"],
                in: directory
            ) else { return nil }
            parts.append(trackedDiff)
        } else {
            guard let stagedDiff = await runCommand(
                "/usr/bin/git",
                args: ["diff", "--no-color", "--cached", "--"],
                in: directory
            ) else { return nil }
            guard let unstagedDiff = await runCommand(
                "/usr/bin/git",
                args: ["diff", "--no-color", "--"],
                in: directory
            ) else { return nil }
            parts.append(stagedDiff)
            parts.append(unstagedDiff)
        }

        let untrackedPaths: [String]
        if let locationsByPath {
            untrackedPaths = locationsByPath
                .filter { $0.value.contains(.untracked) }
                .map(\.key)
                .sorted()
        } else {
            guard let rawPaths = await runCommand(
                "/usr/bin/git",
                args: ["ls-files", "--others", "--exclude-standard", "-z"],
                in: directory
            ) else { return nil }
            untrackedPaths = rawPaths
                .split(separator: "\0", omittingEmptySubsequences: true)
                .map(String.init)
                .sorted()
        }

        for path in untrackedPaths {
            guard let untrackedDiff = await runCommand(
                "/usr/bin/git",
                args: ["diff", "--no-color", "--no-index", "--", "/dev/null", path],
                in: directory,
                allowedExitCodes: [0, 1]
            ) else { return nil }
            parts.append(untrackedDiff)
        }

        return joinedDiffs(parts)
    }

    private nonisolated func parseGitStatusLocations(
        _ output: String
    ) -> [String: Set<FileChange.ChangeLocation>] {
        let records = output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        var locationsByPath: [String: Set<FileChange.ChangeLocation>] = [:]
        var index = 0

        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                index += 1
                continue
            }

            let status = Array(record.prefix(2))
            let indexStatus = status[0]
            let worktreeStatus = status[1]
            let path = String(record.dropFirst(3))

            var locations: Set<FileChange.ChangeLocation> = []
            if indexStatus == "?", worktreeStatus == "?" {
                locations.insert(.untracked)
            } else {
                if indexStatus != " ", indexStatus != "!", indexStatus != "?" {
                    locations.insert(.staged)
                }
                if worktreeStatus != " ", worktreeStatus != "!", worktreeStatus != "?" {
                    locations.insert(.unstaged)
                }
            }

            if !path.isEmpty, !locations.isEmpty {
                locationsByPath[path, default: []].formUnion(locations)
            }

            if indexStatus == "R" || indexStatus == "C" {
                index += 1
            }
            index += 1
        }

        return locationsByPath
    }

    private nonisolated func joinedDiffs(_ parts: [String]) -> String {
        let diff = parts
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return diff.isEmpty ? "" : "\(diff)\n"
    }

    private nonisolated func extractPath(from diffLine: String) -> String {
        // "diff --git a/some/path b/some/path" → "some/path"
        let parts = diffLine.components(separatedBy: " b/")
        if parts.count >= 2 {
            return parts.last!
        }
        return diffLine
    }

    private nonisolated func fileStatus(
        isNew: Bool,
        isDeleted: Bool,
        insertions: Int,
        deletions: Int
    ) -> FileChange.ChangeStatus {
        if isNew { return .added }
        if isDeleted { return .deleted }
        if deletions == 0, insertions > 0 { return .added }
        if insertions == 0, deletions > 0 { return .deleted }
        return .modified
    }

    /// Runs `command` and returns stdout on success (exit code 0), or `nil` on launch failure
    /// or non-zero exit. `nil` lets callers distinguish real errors from empty-but-successful output.
    private nonisolated func runCommand(
        _ command: String,
        args: [String],
        in directory: URL,
        allowedExitCodes: Set<Int32> = [0]
    ) async -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard allowedExitCodes.contains(process.terminationStatus) else { return nil }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return nil
        }
    }
}

extension DiffService.VCSType {
    var displayName: String {
        switch self {
        case .jj:
            "JJ"
        case .graphite:
            "Graphite"
        case .git:
            "Git"
        case .none:
            ""
        }
    }

    var supportsLogPanel: Bool {
        switch self {
        case .jj, .graphite:
            true
        case .git, .none:
            false
        }
    }
}
