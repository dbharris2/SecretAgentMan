import Foundation

actor DiffService {
    enum VCSType {
        case jj
        case git
        case none
    }

    func detectVCS(in directory: URL) -> VCSType {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent(".jj").path) {
            return .jj
        } else if fm.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            return .git
        }
        return .none
    }

    func fetchFullDiff(in directory: URL) async -> String {
        let vcs = detectVCS(in: directory)
        switch vcs {
        case .jj:
            return await runCommand("/opt/homebrew/bin/jj", args: ["diff", "--git"], in: directory)
        case .git:
            return await runCommand("/usr/bin/git", args: ["diff"], in: directory)
        case .none:
            return ""
        }
    }

    /// Extract file changes directly from unified diff output (no truncation).
    func parseChanges(from diff: String) -> [FileChange] {
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
                        status: status
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
                status: status
            ))
        }

        return changes
    }

    private func extractPath(from diffLine: String) -> String {
        // "diff --git a/some/path b/some/path" → "some/path"
        let parts = diffLine.components(separatedBy: " b/")
        if parts.count >= 2 {
            return parts.last!
        }
        return diffLine
    }

    private func fileStatus(
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

    private func runCommand(_ command: String, args: [String], in directory: URL) async -> String {
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
