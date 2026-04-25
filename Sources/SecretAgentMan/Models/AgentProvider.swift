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

    var iconAssetName: String? {
        switch self {
        case .claude:
            "ClaudeIcon"
        case .codex:
            "CodexIcon"
        case .gemini:
            // Gemini ships without a bundled icon asset; the symbol fallback
            // below renders instead. Add a `GeminiIcon` asset to swap in.
            nil
        }
    }

    var symbolName: String {
        switch self {
        case .claude:
            "brain"
        case .codex:
            "chevron.left.forwardslash.chevron.right"
        case .gemini:
            "sparkles"
        }
    }
}
