import Foundation

/// Resolves provider CLI binaries (`claude`, `codex`) by checking a
/// fixed list of standard install locations, falling back to the bare
/// executable name so the system PATH can take over.
enum ProviderExecutableLocator {
    static func executablePath(for provider: AgentProvider) -> String {
        let candidates: [String] = switch provider {
        case .claude:
            [
                NSHomeDirectory() + "/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ]
        case .codex:
            [
                NSHomeDirectory() + "/.local/bin/codex",
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
            ]
        }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return provider.executableName
    }
}
