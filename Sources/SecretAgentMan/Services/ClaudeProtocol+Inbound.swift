import Foundation

extension ClaudeProtocol {
    // MARK: - Incoming Events

    /// Top-level event from Claude's stream-json output. Each known case
    /// carries a typed payload; `.unknown(type:raw:)` preserves both the
    /// discriminator and the raw payload so future-compatibility logging has
    /// the full body to work with.
    enum Event: Decodable, Equatable {
        case system(SystemEvent)
        case assistant(MessageEvent)
        case user(MessageEvent)
        case streamEvent(StreamEvent)
        case controlRequest(ControlRequestEvent)
        case controlResponse(ControlResponseEvent)
        case result(ResultEvent)
        case unknown(type: String, raw: JSONValue)

        private enum CodingKeys: String, CodingKey {
            case type
        }

        /// Outer envelope around a stream event: `{type: "stream_event", event: ...}`.
        private struct StreamEventEnvelope: Decodable {
            let event: StreamEvent
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            let type = try keyed.decode(String.self, forKey: .type)
            let single = try decoder.singleValueContainer()
            switch type {
            case "system": self = try .system(single.decode(SystemEvent.self))
            case "assistant": self = try .assistant(single.decode(MessageEvent.self))
            case "user": self = try .user(single.decode(MessageEvent.self))
            case "stream_event": self = try .streamEvent(single.decode(StreamEventEnvelope.self).event)
            case "control_request": self = try .controlRequest(single.decode(ControlRequestEvent.self))
            case "control_response": self = try .controlResponse(single.decode(ControlResponseEvent.self))
            case "result": self = try .result(single.decode(ResultEvent.self))
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

    // MARK: - System Event

    /// Session/config metadata event. Emitted on connect and on
    /// permission-mode changes. Must NOT publish `.active` from the monitor —
    /// system events are config acks, not work indicators.
    struct SystemEvent: Decodable, Equatable {
        let sessionId: String?
        let model: String?
        let permissionMode: String?

        private enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case model
            case permissionMode
        }
    }

    // MARK: - Control Requests

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

    // MARK: - Stream Events

    /// Inner stream event from Claude's incremental output. The wire shape
    /// is `{type: "stream_event", event: <StreamEvent>}`; this enum models
    /// just the inner `event` field.
    ///
    /// V1 only acts on three shapes (active tool tracking, text deltas, and
    /// message_stop). Everything else preserves its raw payload via
    /// `.unknown` for forward-compat.
    enum StreamEvent: Decodable, Equatable {
        case contentBlockStart(ContentBlockStart)
        case textDelta(String)
        case messageStop
        case unknown(type: String, raw: JSONValue)

        private enum CodingKeys: String, CodingKey {
            case type, delta
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            let type = try keyed.decode(String.self, forKey: .type)
            switch type {
            case "content_block_start":
                self = try .contentBlockStart(ContentBlockStart(from: decoder))
            case "content_block_delta":
                // Only `text_delta` deltas are surfaced as `.textDelta`.
                // Any other delta type (input_json_delta, etc.) preserves
                // its raw frame so future debugging has the full shape.
                if let inner = try? keyed.decode(InnerDelta.self, forKey: .delta),
                   case let .text(text) = inner {
                    self = .textDelta(text)
                } else {
                    let raw = try decoder.singleValueContainer().decode(JSONValue.self)
                    self = .unknown(type: "content_block_delta", raw: raw)
                }
            case "message_stop":
                self = .messageStop
            default:
                let raw = try decoder.singleValueContainer().decode(JSONValue.self)
                self = .unknown(type: type, raw: raw)
            }
        }

        private enum InnerDelta: Decodable, Equatable {
            case text(String)

            private enum CodingKeys: String, CodingKey {
                case type, text
            }

            init(from decoder: Decoder) throws {
                let keyed = try decoder.container(keyedBy: CodingKeys.self)
                let type = try keyed.decode(String.self, forKey: .type)
                guard type == "text_delta" else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: keyed,
                        debugDescription: "Unsupported delta type: \(type)"
                    )
                }
                self = try .text(keyed.decode(String.self, forKey: .text))
            }
        }
    }

    /// Payload of a `content_block_start` stream event. Carries just the
    /// `content_block` projection the monitor cares about (active tool
    /// tracking) — additional wire fields are ignored.
    struct ContentBlockStart: Decodable, Equatable {
        let contentBlock: ContentBlockHeader

        private enum CodingKeys: String, CodingKey {
            case contentBlock = "content_block"
        }
    }

    /// `content_block` header. The monitor uses this to set/clear the
    /// active tool indicator.
    enum ContentBlockHeader: Decodable, Equatable {
        case text
        case toolUse(name: String?)
        case unknown(type: String, raw: JSONValue)

        private enum CodingKeys: String, CodingKey {
            case type, name
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            let type = try keyed.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text
            case "tool_use":
                let name = try keyed.decodeIfPresent(String.self, forKey: .name)
                self = .toolUse(name: name)
            default:
                let raw = try decoder.singleValueContainer().decode(JSONValue.self)
                self = .unknown(type: type, raw: raw)
            }
        }
    }

    // MARK: - Message Content

    /// Top-level shape for `assistant` and `user` events. Both share the
    /// envelope `{type, uuid?, userType?, isMeta?, message: {role?, content}}`;
    /// the discriminator is the outer `type`, so `MessageEvent` itself is
    /// type-agnostic.
    struct MessageEvent: Decodable, Equatable {
        let uuid: String?
        let userType: String?
        let isMeta: Bool?
        let message: MessageBody?

        private enum CodingKeys: String, CodingKey {
            case uuid, userType, isMeta, message
        }
    }

    struct MessageBody: Decodable, Equatable {
        let role: String?
        let content: MessageContent
    }

    /// `message.content` is either a plain string (user-typed messages) or an
    /// array of structured content blocks (assistant messages, tool results).
    enum MessageContent: Decodable, Equatable {
        case text(String)
        case blocks([ContentBlock])

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let str = try? single.decode(String.self) {
                self = .text(str)
            } else {
                self = try .blocks(single.decode([ContentBlock].self))
            }
        }
    }

    /// One block inside `message.content[]`. V1 surfaces text, tool_use, and
    /// tool_result; anything else preserves its raw payload.
    enum ContentBlock: Decodable, Equatable {
        case text(String)
        case toolUse(ToolUse)
        case toolResult(ToolResult)
        case unknown(type: String, raw: JSONValue)

        private enum CodingKeys: String, CodingKey {
            case type
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            let type = try keyed.decode(String.self, forKey: .type)
            let single = try decoder.singleValueContainer()
            switch type {
            case "text":
                struct TextBlock: Decodable {
                    let text: String?
                }
                let block = try single.decode(TextBlock.self)
                self = .text(block.text ?? "")
            case "tool_use":
                self = try .toolUse(single.decode(ToolUse.self))
            case "tool_result":
                self = try .toolResult(single.decode(ToolResult.self))
            default:
                self = try .unknown(type: type, raw: single.decode(JSONValue.self))
            }
        }
    }

    /// `tool_use` block: an assistant invocation of a named tool with
    /// open-ended input. Input stays as raw `JSONValue`; per-tool
    /// projections live in `ClaudeProtocol+ToolInputs.swift`.
    struct ToolUse: Decodable, Equatable {
        let id: String?
        let name: String
        let input: JSONValue?
    }

    /// `tool_result` block: a user-side block reporting a tool's outcome.
    /// V1 only surfaces these on errors, so we eagerly assemble a display
    /// string from whichever shape the wire used.
    struct ToolResult: Decodable, Equatable {
        let toolUseId: String?
        let isError: Bool?
        /// Display text assembled from `content` (string or `[{text}]`) with
        /// a fallback to a sibling `text` field. Empty when nothing matched.
        let text: String

        private enum CodingKeys: String, CodingKey {
            case toolUseId = "tool_use_id"
            case isError = "is_error"
            case content, text
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            toolUseId = try keyed.decodeIfPresent(String.self, forKey: .toolUseId)
            isError = try keyed.decodeIfPresent(Bool.self, forKey: .isError)

            var assembled = ""
            if let str = try? keyed.decodeIfPresent(String.self, forKey: .content) {
                assembled = str
            } else if let blocks = try? keyed.decodeIfPresent([JSONValue].self, forKey: .content) {
                assembled = blocks.compactMap { $0["text"]?.stringValue }.joined()
            }
            if assembled.isEmpty,
               let fallback = try? keyed.decodeIfPresent(String.self, forKey: .text) {
                assembled = fallback
            }
            text = assembled
        }
    }

    // MARK: - Control Responses

    /// Wire shape: `{type: "control_response", response: {subtype, request_id, response: {...}}}`.
    /// V1 only reads `commands` from the deeply nested inner body, so this
    /// type collapses the envelope down to that.
    struct ControlResponseEvent: Decodable, Equatable {
        let commands: [SlashCommand]?

        private enum CodingKeys: String, CodingKey {
            case response
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            commands = try keyed
                .decodeIfPresent(Body.self, forKey: .response)?
                .response?.commands
        }

        private struct Body: Decodable {
            let response: InnerResponse?

            struct InnerResponse: Decodable {
                let commands: [SlashCommand]?
            }
        }
    }

    /// Slash command metadata as advertised by Claude Code on initialize and
    /// after permission-mode changes.
    struct SlashCommand: Decodable, Equatable {
        let name: String
        let description: String?
        let argumentHint: String?
    }

    // MARK: - Result Event

    /// Terminal event for a turn. Carries error state, session id, and the
    /// usage/modelUsage shapes that drive the context-window indicator.
    struct ResultEvent: Decodable, Equatable {
        let isError: Bool?
        let sessionId: String?
        let modelUsage: [String: ModelUsage]?
        let usage: Usage?

        private enum CodingKeys: String, CodingKey {
            case isError = "is_error"
            case sessionId = "session_id"
            case modelUsage, usage
        }

        struct ModelUsage: Decodable, Equatable {
            let contextWindow: Double?
        }

        struct Usage: Decodable, Equatable {
            let iterations: [Iteration]?

            struct Iteration: Decodable, Equatable {
                let inputTokens: Double?
                let cacheReadInputTokens: Double?
                let cacheCreationInputTokens: Double?
                let outputTokens: Double?

                private enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                    case outputTokens = "output_tokens"
                }
            }
        }

        /// Context-window percentage for the last API call. `modelUsage` is
        /// cumulative across the session, so we divide the last iteration's
        /// token totals by the model's contextWindow.
        var contextPercent: Double? {
            guard let firstModel = modelUsage?.values.first,
                  let window = firstModel.contextWindow, window > 0,
                  let lastIter = usage?.iterations?.last
            else { return nil }
            let total = (lastIter.inputTokens ?? 0)
                + (lastIter.cacheReadInputTokens ?? 0)
                + (lastIter.cacheCreationInputTokens ?? 0)
                + (lastIter.outputTokens ?? 0)
            return total / window * 100
        }
    }
}
