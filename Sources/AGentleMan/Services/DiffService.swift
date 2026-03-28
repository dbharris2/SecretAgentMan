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

    func fetchChanges(in directory: URL) async -> [FileChange] {
        let vcs = detectVCS(in: directory)
        switch vcs {
        case .jj:
            return await runDiffStat(command: "/opt/homebrew/bin/jj", args: ["diff", "--stat"], in: directory)
        case .git:
            return await runDiffStat(command: "/usr/bin/git", args: ["diff", "--stat"], in: directory)
        case .none:
            return []
        }
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

    private func runDiffStat(command: String, args: [String], in directory: URL) async -> [FileChange] {
        let output = await runCommand(command, args: args, in: directory)
        return parseDiffStat(output)
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

    func parseDiffStat(_ output: String) -> [FileChange] {
        var changes: [FileChange] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            // Match lines like: " src/file.ts | 5 ++--" or " src/file.ts | 5 +++--"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("|") else { continue }

            let parts = trimmed.components(separatedBy: "|")
            guard parts.count == 2 else { continue }

            let path = parts[0].trimmingCharacters(in: .whitespaces)
            let statsStr = parts[1].trimmingCharacters(in: .whitespaces)

            // Skip the summary line (e.g. "3 files changed, 10 insertions(+)")
            guard !statsStr.contains("changed") else { continue }

            let insertions = statsStr.filter { $0 == "+" }.count
            let deletions = statsStr.filter { $0 == "-" }.count

            let status: FileChange.ChangeStatus
            if deletions == 0, insertions > 0 {
                status = .added
            } else if insertions == 0, deletions > 0 {
                status = .deleted
            } else {
                status = .modified
            }

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
}
