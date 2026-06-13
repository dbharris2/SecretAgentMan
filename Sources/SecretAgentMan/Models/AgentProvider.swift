import Foundation

enum AgentProvider: String, CaseIterable, Codable, Hashable, Identifiable {
    case claude
    case codex

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        }
    }

    var executableName: String {
        switch self {
        case .claude:
            "claude"
        case .codex:
            "codex"
        }
    }

    var homeDirectoryName: String {
        switch self {
        case .claude:
            ".claude"
        case .codex:
            ".codex"
        }
    }
}
