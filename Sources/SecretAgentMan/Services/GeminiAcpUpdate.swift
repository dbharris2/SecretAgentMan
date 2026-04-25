import Foundation

extension GeminiAcpProtocol {
    // MARK: - Content blocks

    /// `_meta` and `annotations` are dropped on decode for V1 since we don't
    /// surface them in the UI. Encoder side mirrors this — we only emit
    /// the fields V1 actually sends (text and image).
    enum ContentBlock: Codable, Equatable {
        case text(TextContent)
        case image(ImageContent)
        case audio(AudioContent)
        case resourceLink(ResourceLink)
        case resource(EmbeddedResource)
        /// Forward-compat: agent sent a `type` value V1 doesn't recognize.
        /// Monitor logs and surfaces the raw value but does not crash.
        case unknown(type: String, raw: GeminiAcpJsonValue)

        private enum CodingKeys: String, CodingKey {
            case type
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            let single = try decoder.singleValueContainer()
            switch type {
            case "text":
                self = try .text(single.decode(TextContent.self))
            case "image":
                self = try .image(single.decode(ImageContent.self))
            case "audio":
                self = try .audio(single.decode(AudioContent.self))
            case "resource_link":
                self = try .resourceLink(single.decode(ResourceLink.self))
            case "resource":
                self = try .resource(single.decode(EmbeddedResource.self))
            default:
                let raw = try single.decode(GeminiAcpJsonValue.self)
                self = .unknown(type: type, raw: raw)
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .text(text):
                try text.encode(to: encoder)
                try encodeType("text", to: encoder)
            case let .image(image):
                try image.encode(to: encoder)
                try encodeType("image", to: encoder)
            case let .audio(audio):
                try audio.encode(to: encoder)
                try encodeType("audio", to: encoder)
            case let .resourceLink(link):
                try link.encode(to: encoder)
                try encodeType("resource_link", to: encoder)
            case let .resource(res):
                try res.encode(to: encoder)
                try encodeType("resource", to: encoder)
            case let .unknown(type, raw):
                try raw.encode(to: encoder)
                try encodeType(type, to: encoder)
            }
        }

        private func encodeType(_ type: String, to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
        }
    }

    struct TextContent: Codable, Equatable {
        let text: String
    }

    struct ImageContent: Codable, Equatable {
        let data: String
        let mimeType: String
        let uri: String?

        init(data: String, mimeType: String, uri: String? = nil) {
            self.data = data
            self.mimeType = mimeType
            self.uri = uri
        }
    }

    struct AudioContent: Codable, Equatable {
        let data: String
        let mimeType: String
    }

    struct ResourceLink: Codable, Equatable {
        let name: String
        let uri: String
        let title: String?
        let description: String?
        let mimeType: String?
        let size: Int?
    }

    struct EmbeddedResource: Codable, Equatable {
        let resource: GeminiAcpJsonValue
    }

    // MARK: - Plan

    enum PlanEntryPriority: String, Codable, Equatable {
        case high, medium, low
    }

    enum PlanEntryStatus: String, Codable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    struct PlanEntry: Codable, Equatable {
        let content: String
        let priority: PlanEntryPriority
        let status: PlanEntryStatus
    }

    struct Plan: Codable, Equatable {
        let entries: [PlanEntry]
    }

    // MARK: - Tool calls

    enum ToolKind: String, Codable, Equatable {
        case read, edit, delete, move, search, execute, think, fetch, other
        case switchMode = "switch_mode"
    }

    enum ToolCallStatus: String, Codable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed, failed
    }

    struct ToolCallLocation: Codable, Equatable {
        let path: String
        let line: Int?
    }

    /// A single chunk inside a tool call's `content` array. Tagged by `type`.
    /// `terminal` is decoded but V1 just shows the `terminalId` since we don't
    /// proxy terminal output.
    enum ToolCallContent: Codable, Equatable {
        case content(GeminiAcpProtocol.ContentBlock)
        case diff(Diff)
        case terminal(Terminal)
        case unknown(type: String, raw: GeminiAcpJsonValue)

        private enum CodingKeys: String, CodingKey {
            case type, content
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            let type = try keyed.decode(String.self, forKey: .type)
            let single = try decoder.singleValueContainer()
            switch type {
            case "content":
                let wrapper = try single.decode(ContentWrapper.self)
                self = .content(wrapper.content)
            case "diff":
                self = try .diff(single.decode(Diff.self))
            case "terminal":
                self = try .terminal(single.decode(Terminal.self))
            default:
                let raw = try single.decode(GeminiAcpJsonValue.self)
                self = .unknown(type: type, raw: raw)
            }
        }

        func encode(to encoder: Encoder) throws {
            // V1 only decodes tool call content; encoding is unused.
            // Provided for round-trip completeness.
            switch self {
            case let .content(block):
                try ContentWrapper(content: block).encode(to: encoder)
                try encodeType("content", to: encoder)
            case let .diff(diff):
                try diff.encode(to: encoder)
                try encodeType("diff", to: encoder)
            case let .terminal(term):
                try term.encode(to: encoder)
                try encodeType("terminal", to: encoder)
            case let .unknown(type, raw):
                try raw.encode(to: encoder)
                try encodeType(type, to: encoder)
            }
        }

        private func encodeType(_ type: String, to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
        }

        private struct ContentWrapper: Codable {
            let content: ContentBlock
        }
    }

    struct Diff: Codable, Equatable {
        let path: String
        let oldText: String?
        let newText: String
    }

    struct Terminal: Codable, Equatable {
        let terminalId: String
    }

    struct ToolCall: Codable, Equatable {
        let toolCallId: String
        let title: String
        let kind: ToolKind?
        let status: ToolCallStatus?
        let content: [ToolCallContent]?
        let locations: [ToolCallLocation]?
        let rawInput: GeminiAcpJsonValue?
        let rawOutput: GeminiAcpJsonValue?
    }

    /// Update form has all fields except `toolCallId` optional. The agent
    /// sends partial updates; the monitor merges them into the prior call
    /// state by `toolCallId`.
    struct ToolCallUpdate: Codable, Equatable {
        let toolCallId: String
        let title: String?
        let kind: ToolKind?
        let status: ToolCallStatus?
        let content: [ToolCallContent]?
        let locations: [ToolCallLocation]?
        let rawInput: GeminiAcpJsonValue?
        let rawOutput: GeminiAcpJsonValue?
    }

    // MARK: - Available commands (slash command metadata)

    struct AvailableCommandInput: Codable, Equatable {
        let hint: String
    }

    struct AvailableCommand: Codable, Equatable {
        let name: String
        let description: String
        let input: AvailableCommandInput?
    }

    struct AvailableCommandsUpdate: Codable, Equatable {
        let availableCommands: [AvailableCommand]
    }

    // MARK: - Mode / model / session / usage updates

    struct CurrentModeUpdate: Codable, Equatable {
        let currentModeId: String
    }

    struct SessionInfoUpdate: Codable, Equatable {
        let title: String?
        let updatedAt: String?
    }

    struct UsageUpdate: Codable, Equatable {
        let used: Double
        let size: Double
        let cost: GeminiAcpJsonValue?
    }

    // MARK: - Content chunks (for user/agent/thought messages)

    struct ContentChunk: Codable, Equatable {
        let content: ContentBlock
        let messageId: String?
    }

    // MARK: - session/update notification

    struct SessionNotification: Codable, Equatable {
        let sessionId: String
        let update: SessionUpdate
    }

    /// All known incoming session/update variants. Discriminated on the
    /// `sessionUpdate` string field. Forward-compat via `.unknown`.
    enum SessionUpdate: Codable, Equatable {
        case userMessageChunk(ContentChunk)
        case agentMessageChunk(ContentChunk)
        case agentThoughtChunk(ContentChunk)
        case toolCall(ToolCall)
        case toolCallUpdate(ToolCallUpdate)
        case plan(Plan)
        case availableCommandsUpdate(AvailableCommandsUpdate)
        case currentModeUpdate(CurrentModeUpdate)
        case sessionInfoUpdate(SessionInfoUpdate)
        case usageUpdate(UsageUpdate)
        case unknown(kind: String, raw: GeminiAcpJsonValue)

        private enum CodingKeys: String, CodingKey {
            case sessionUpdate
        }

        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try keyed.decode(String.self, forKey: .sessionUpdate)
            let single = try decoder.singleValueContainer()
            switch kind {
            case "user_message_chunk":
                self = try .userMessageChunk(single.decode(ContentChunk.self))
            case "agent_message_chunk":
                self = try .agentMessageChunk(single.decode(ContentChunk.self))
            case "agent_thought_chunk":
                self = try .agentThoughtChunk(single.decode(ContentChunk.self))
            case "tool_call":
                self = try .toolCall(single.decode(ToolCall.self))
            case "tool_call_update":
                self = try .toolCallUpdate(single.decode(ToolCallUpdate.self))
            case "plan":
                self = try .plan(single.decode(Plan.self))
            case "available_commands_update":
                self = try .availableCommandsUpdate(single.decode(AvailableCommandsUpdate.self))
            case "current_mode_update":
                self = try .currentModeUpdate(single.decode(CurrentModeUpdate.self))
            case "session_info_update":
                self = try .sessionInfoUpdate(single.decode(SessionInfoUpdate.self))
            case "usage_update":
                self = try .usageUpdate(single.decode(UsageUpdate.self))
            default:
                let raw = try single.decode(GeminiAcpJsonValue.self)
                self = .unknown(kind: kind, raw: raw)
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .userMessageChunk(chunk):
                try chunk.encode(to: encoder)
                try encodeKind("user_message_chunk", to: encoder)
            case let .agentMessageChunk(chunk):
                try chunk.encode(to: encoder)
                try encodeKind("agent_message_chunk", to: encoder)
            case let .agentThoughtChunk(chunk):
                try chunk.encode(to: encoder)
                try encodeKind("agent_thought_chunk", to: encoder)
            case let .toolCall(call):
                try call.encode(to: encoder)
                try encodeKind("tool_call", to: encoder)
            case let .toolCallUpdate(call):
                try call.encode(to: encoder)
                try encodeKind("tool_call_update", to: encoder)
            case let .plan(plan):
                try plan.encode(to: encoder)
                try encodeKind("plan", to: encoder)
            case let .availableCommandsUpdate(update):
                try update.encode(to: encoder)
                try encodeKind("available_commands_update", to: encoder)
            case let .currentModeUpdate(update):
                try update.encode(to: encoder)
                try encodeKind("current_mode_update", to: encoder)
            case let .sessionInfoUpdate(update):
                try update.encode(to: encoder)
                try encodeKind("session_info_update", to: encoder)
            case let .usageUpdate(update):
                try update.encode(to: encoder)
                try encodeKind("usage_update", to: encoder)
            case let .unknown(kind, raw):
                try raw.encode(to: encoder)
                try encodeKind(kind, to: encoder)
            }
        }

        private func encodeKind(_ kind: String, to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .sessionUpdate)
        }
    }

    // MARK: - session/request_permission

    enum PermissionOptionKind: String, Codable, Equatable {
        case allowOnce = "allow_once"
        case allowAlways = "allow_always"
        case rejectOnce = "reject_once"
        case rejectAlways = "reject_always"
    }

    struct PermissionOption: Codable, Equatable, Identifiable {
        var id: String {
            optionId
        }

        let optionId: String
        let name: String
        let kind: PermissionOptionKind
    }

    struct RequestPermissionRequest: Codable, Equatable {
        let sessionId: String
        let toolCall: ToolCallUpdate
        let options: [PermissionOption]
    }

    /// Outcome we send back to the agent. Either the user picked one of the
    /// agent-supplied options, or the prompt was cancelled (e.g. by an
    /// out-of-band `session/cancel`).
    enum RequestPermissionOutcome: Codable, Equatable {
        case selected(optionId: String)
        case cancelled

        private enum CodingKeys: String, CodingKey {
            case outcome, optionId
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .selected(optionId):
                try container.encode("selected", forKey: .outcome)
                try container.encode(optionId, forKey: .optionId)
            case .cancelled:
                try container.encode("cancelled", forKey: .outcome)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let outcome = try container.decode(String.self, forKey: .outcome)
            switch outcome {
            case "selected":
                self = try .selected(optionId: container.decode(String.self, forKey: .optionId))
            case "cancelled":
                self = .cancelled
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .outcome,
                    in: container,
                    debugDescription: "Unknown permission outcome: \(outcome)"
                )
            }
        }
    }

    struct RequestPermissionResponse: Codable, Equatable {
        let outcome: RequestPermissionOutcome
    }
}
