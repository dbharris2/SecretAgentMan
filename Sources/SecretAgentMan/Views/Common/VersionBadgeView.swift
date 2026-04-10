import SwiftUI

struct VersionBadgeView: View {
    @State private var latestVersion: String?
    private let releasesURL = URL(string: "https://github.com/dbharris2/SecretAgentMan/releases/latest")!

    private var isDebug: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var isOutdated: Bool {
        guard !isDebug, let latest = latestVersion else { return false }
        return latest != currentVersion
    }

    @Environment(\.appTheme) private var theme

    var body: some View {
        Link(destination: releasesURL) {
            HStack(spacing: 4) {
                if isDebug {
                    Text("DEBUG")
                        .scaledFont(size: 11, weight: .bold, design: .monospaced)
                        .foregroundStyle(theme.yellow)
                } else {
                    Text(verbatim: "v\(currentVersion)")
                        .scaledFont(size: 11)
                        .foregroundStyle(isOutdated ? theme.yellow : .secondary)
                    if isOutdated {
                        Image(systemName: "arrow.up.circle.fill")
                            .scaledFont(size: 10)
                            .foregroundStyle(theme.yellow)
                    }
                }
            }
        }
        .help(isDebug ? "Debug build" : isOutdated ? "Update available: v\(latestVersion ?? "")" : "Up to date")
        .task {
            if !isDebug { await checkForUpdate() }
        }
    }

    private func checkForUpdate() async {
        let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ghPath else { return }

        let result = await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = [
                "release", "view", "--repo", "dbharris2/SecretAgentMan",
                "--json", "tagName", "-q", ".tagName",
            ]
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let tag = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "v", with: "")
                continuation.resume(returning: tag)
            } catch {
                continuation.resume(returning: nil)
            }
        }

        await MainActor.run {
            latestVersion = result
        }
    }
}
