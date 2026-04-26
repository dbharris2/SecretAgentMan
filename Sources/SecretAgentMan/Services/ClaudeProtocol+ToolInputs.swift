import Foundation

/// Per-tool input projections.
///
/// `ClaudeProtocol.ToolUse.input` is a raw `JSONValue` so the monitor can
/// echo permission responses back unchanged. When the monitor needs a
/// specific tool's structured input, decode through one of these on demand
/// via `value.decode(as: ClaudeProtocol.SomeInput.self)`.
extension ClaudeProtocol {
    /// `AskUserQuestion`: structured input for the question/options
    /// prompt UI. Decoded from `PermissionRequest.input` when the monitor
    /// sees that tool name in a `can_use_tool` request.
    struct AskUserQuestionInput: Decodable, Equatable {
        let questions: [Question]

        struct Question: Decodable, Equatable {
            let question: String
            let header: String?
            let options: [Option]?
        }

        struct Option: Decodable, Equatable {
            let label: String
            let description: String?
        }
    }
}
