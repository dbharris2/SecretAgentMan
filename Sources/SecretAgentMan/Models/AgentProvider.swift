import Foundation

enum AgentProvider: String, CaseIterable, Codable, Hashable, Identifiable {
    case claude
    case codex
    case gemini

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        case .gemini:
            "Gemini"
        }
    }

    var executableName: String {
        switch self {
        case .claude:
            "claude"
        case .codex:
            "codex"
        case .gemini:
            "gemini"
        }
    }

    var homeDirectoryName: String {
        switch self {
        case .claude:
            ".claude"
        case .codex:
            ".codex"
        case .gemini:
            ".gemini"
        }
    }
}
