import Foundation

/// Typed wire-format messages for the Claude Code stream-json protocol.
/// Replaces hand-built [String: Any] dictionaries with Encodable structs.
enum ClaudeProtocol {
    // MARK: - Outgoing Messages (Encodable)

    struct UserMessage: Encodable {
        let type = "user"
        let session_id = ""
        let parent_tool_use_id: String? = nil
        let message: MessageBody

        struct MessageBody: Encodable {
            let role = "user"
            let content: [ContentBlock]
        }

        enum ContentBlock: Encodable {
            case text(String)
            case image(data: String, mediaType: String)

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case let .text(text):
                    try container.encode("text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case let .image(data, mediaType):
                    try container.encode("image", forKey: .type)
                    try container.encode(
                        ImageSource(type: "base64", media_type: mediaType, data: data),
                        forKey: .source
                    )
                }
            }

            private enum CodingKeys: String, CodingKey {
                case type, text, source
            }

            private struct ImageSource: Encodable {
                let type: String
                let media_type: String
                let data: String
            }
        }

        static func build(text: String, images: [(Data, String)] = []) -> UserMessage {
            var blocks: [ContentBlock] = images.map { .image(data: $0.0.base64EncodedString(), mediaType: $0.1) }
            blocks.append(.text(text))
            return UserMessage(message: MessageBody(content: blocks))
        }
    }

    struct ControlRequest: Encodable {
        let type = "control_request"
        let request_id: String
        let request: Request

        struct Request: Encodable {
            let subtype: String
            let mode: String?

            init(subtype: String, mode: String? = nil) {
                self.subtype = subtype
                self.mode = mode
            }
        }

        static func initialize() -> ControlRequest {
            ControlRequest(
                request_id: "init-\(UUID().uuidString)",
                request: Request(subtype: "initialize")
            )
        }

        static func setPermissionMode(_ mode: String) -> ControlRequest {
            ControlRequest(
                request_id: "perm-\(UUID().uuidString)",
                request: Request(subtype: "set_permission_mode", mode: mode)
            )
        }

        static func interrupt() -> ControlRequest {
            ControlRequest(
                request_id: "int-\(UUID().uuidString)",
                request: Request(subtype: "interrupt")
            )
        }
    }

    struct PermissionResponse: Encodable {
        let type = "control_response"
        let response: ResponseBody

        struct ResponseBody: Encodable {
            let subtype = "success"
            let request_id: String
            let response: Decision
        }

        enum Decision: Encodable {
            case allow(updatedInput: JSONValue)
            case deny(message: String)

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case let .allow(updatedInput):
                    try container.encode("allow", forKey: .behavior)
                    try container.encode(updatedInput, forKey: .updatedInput)
                case let .deny(message):
                    try container.encode("deny", forKey: .behavior)
                    try container.encode(message, forKey: .message)
                }
            }

            private enum CodingKeys: String, CodingKey {
                case behavior, updatedInput, message
            }
        }

        static func allow(requestId: String, updatedInput: JSONValue) -> PermissionResponse {
            PermissionResponse(
                response: ResponseBody(
                    request_id: requestId,
                    response: .allow(updatedInput: updatedInput)
                )
            )
        }

        static func deny(requestId: String, message: String = "User denied") -> PermissionResponse {
            PermissionResponse(
                response: ResponseBody(
                    request_id: requestId,
                    response: .deny(message: message)
                )
            )
        }
    }

    // MARK: - Incoming Events

    /// Top-level event from Claude's stream-json output. The known cases
    /// each carry the full event JSON as a `JSONValue`; phases beyond 1b
    /// will narrow the inner payload to typed structs case by case.
    ///
    /// `.unknown(type:raw:)` preserves both the discriminator and the raw
    /// payload so future-compatibility logging has the full body to work
    /// with.
    enum Event: Decodable, Equatable {
        case system(JSONValue)
        case assistant(JSONValue)
        case user(JSONValue)
        case streamEvent(JSONValue)
        case controlRequest(ControlRequestEvent)
        case controlResponse(JSONValue)
        case result(JSONValue)
        case unknown(type: String, raw: JSONValue)

        private enum CodingKeys: String, CodingKey {
            case type
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            let type = try keyed.decode(String.self, forKey: .type)
            let single = try decoder.singleValueContainer()
            switch type {
            case "system": self = try .system(single.decode(JSONValue.self))
            case "assistant": self = try .assistant(single.decode(JSONValue.self))
            case "user": self = try .user(single.decode(JSONValue.self))
            case "stream_event": self = try .streamEvent(single.decode(JSONValue.self))
            case "control_request": self = try .controlRequest(single.decode(ControlRequestEvent.self))
            case "control_response": self = try .controlResponse(single.decode(JSONValue.self))
            case "result": self = try .result(single.decode(JSONValue.self))
            default: self = try .unknown(type: type, raw: single.decode(JSONValue.self))
            }
        }

        /// Wire-format discriminator. Useful for logging when downstream
        /// payload decoding fails — callers can still attribute the bad
        /// frame to a known event type.
        var typeName: String {
            switch self {
            case .system: "system"
            case .assistant: "assistant"
            case .user: "user"
            case .streamEvent: "stream_event"
            case .controlRequest: "control_request"
            case .controlResponse: "control_response"
            case .result: "result"
            case let .unknown(type, _): type
            }
        }
    }

    /// Decodes one JSONL line from Claude's stream-json output.
    ///
    /// Returns `nil` for empty or whitespace-only lines.
    /// Throws for malformed JSON, missing top-level `type`, or anything else
    /// that fails `Event.init(from:)`.
    /// Unknown event types decode to `.unknown(type:raw:)` rather than
    /// throwing, so forward-compatible types don't kill the stream.
    static func decodeLine(_ line: String) throws -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try JSONDecoder().decode(Event.self, from: Data(trimmed.utf8))
    }

    // MARK: - Control Requests (typed)

    /// Wire shape: `{type: "control_request", request_id: ..., request: {...}}`.
    /// The inner `request` is discriminated on `subtype`.
    struct ControlRequestEvent: Decodable, Equatable {
        let requestId: String
        let request: ControlRequestSubtype

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case request
        }
    }

    /// Discriminated on `subtype`. Forward-compatible subtypes preserve their
    /// raw payload via `.unknown` so logs can attribute them to a wire shape.
    enum ControlRequestSubtype: Decodable, Equatable {
        case canUseTool(PermissionRequest)
        case elicitation(ElicitationRequest)
        case unknown(subtype: String, raw: JSONValue)

        private enum CodingKeys: String, CodingKey {
            case subtype
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            let subtype = try keyed.decode(String.self, forKey: .subtype)
            let single = try decoder.singleValueContainer()
            switch subtype {
            case "can_use_tool":
                self = try .canUseTool(single.decode(PermissionRequest.self))
            case "elicitation":
                self = try .elicitation(single.decode(ElicitationRequest.self))
            default:
                self = try .unknown(subtype: subtype, raw: single.decode(JSONValue.self))
            }
        }

        var subtypeName: String {
            switch self {
            case .canUseTool: "can_use_tool"
            case .elicitation: "elicitation"
            case let .unknown(subtype, _): subtype
            }
        }
    }

    /// `can_use_tool`: Claude is asking permission to invoke a tool. Tool
    /// `input` is left as raw `JSONValue` so the monitor can echo it back in
    /// the permission response unchanged, and decode tool-specific shapes on
    /// demand (e.g. `AskUserQuestionInput`).
    struct PermissionRequest: Decodable, Equatable {
        let toolName: String
        let displayName: String?
        let input: JSONValue

        private enum CodingKeys: String, CodingKey {
            case toolName = "tool_name"
            case displayName = "display_name"
            case input
        }
    }

    /// `elicitation`: freeform prompt to the user, no tool involvement.
    struct ElicitationRequest: Decodable, Equatable {
        let message: String
    }

    /// Tool-input projection for the `AskUserQuestion` tool. Decoded from
    /// `PermissionRequest.input` on demand when the monitor sees that tool.
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

    // MARK: - Encoding Helpers

    static func encode(_ value: Encodable) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func encodeLine(_ value: Encodable) -> Data? {
        guard var data = encode(value) else { return nil }
        data.append(0x0A) // newline
        return data
    }
}
