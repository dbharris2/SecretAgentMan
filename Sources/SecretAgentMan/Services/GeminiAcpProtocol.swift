import Foundation

/// Typed wire-format messages for the Gemini ACP protocol (Agent Client
/// Protocol). Mirrors the schema bundled with `gemini-cli 0.38.2` at
/// `bundle/gemini.js` (zod schemas around line 10410).
///
/// V1 scope: handshake, session lifecycle, prompt, mode/model switching,
/// session updates, and permission requests. Out of scope: file-system and
/// terminal proxying, authenticate, session list/fork/resume/close,
/// session/set_config_option.
enum GeminiAcpProtocol {
    /// JSON-RPC method names used on the wire. Mirrors the `AGENT_METHODS`
    /// and `CLIENT_METHODS` constants in the bundled ACP SDK.
    enum Method {
        static let initialize = "initialize"
        static let sessionNew = "session/new"
        static let sessionLoad = "session/load"
        static let sessionPrompt = "session/prompt"
        static let sessionCancel = "session/cancel"
        static let sessionUpdate = "session/update"
        static let sessionRequestPermission = "session/request_permission"
        static let sessionSetMode = "session/set_mode"
        static let sessionSetModel = "session/set_model"
    }

    static let protocolVersion: Int = 1

    // MARK: - Capabilities

    struct AuthCapabilities: Codable, Equatable {
        let terminal: Bool

        init(terminal: Bool = false) {
            self.terminal = terminal
        }
    }

    struct FileSystemCapabilities: Codable, Equatable {
        let readTextFile: Bool
        let writeTextFile: Bool

        init(readTextFile: Bool = false, writeTextFile: Bool = false) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
        }
    }

    struct ClientCapabilities: Codable, Equatable {
        let auth: AuthCapabilities
        let fs: FileSystemCapabilities
        let terminal: Bool

        init(
            auth: AuthCapabilities = AuthCapabilities(),
            fs: FileSystemCapabilities = FileSystemCapabilities(),
            terminal: Bool = false
        ) {
            self.auth = auth
            self.fs = fs
            self.terminal = terminal
        }
    }

    /// V1 client advertises no fs/terminal proxy support.
    static let defaultClientCapabilities = ClientCapabilities()

    struct McpCapabilities: Codable, Equatable {
        let http: Bool
        let sse: Bool
    }

    struct PromptCapabilities: Codable, Equatable {
        let audio: Bool
        let embeddedContext: Bool
        let image: Bool
    }

    struct SessionCloseCapabilities: Codable, Equatable {}
    struct SessionForkCapabilities: Codable, Equatable {}
    struct SessionListCapabilities: Codable, Equatable {}
    struct SessionResumeCapabilities: Codable, Equatable {}

    struct SessionCapabilities: Codable, Equatable {
        let close: SessionCloseCapabilities?
        let fork: SessionForkCapabilities?
        let list: SessionListCapabilities?
        let resume: SessionResumeCapabilities?
    }

    struct AgentCapabilities: Codable, Equatable {
        let loadSession: Bool
        let mcpCapabilities: McpCapabilities?
        let promptCapabilities: PromptCapabilities?
        let sessionCapabilities: SessionCapabilities?
    }

    // MARK: - Implementation info

    struct Implementation: Codable, Equatable {
        let name: String
        let title: String?
        let version: String
    }

    // MARK: - initialize

    struct InitializeRequest: Codable, Equatable {
        let protocolVersion: Int
        let clientCapabilities: ClientCapabilities
        let clientInfo: Implementation?

        init(
            protocolVersion: Int = GeminiAcpProtocol.protocolVersion,
            clientCapabilities: ClientCapabilities = defaultClientCapabilities,
            clientInfo: Implementation? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.clientCapabilities = clientCapabilities
            self.clientInfo = clientInfo
        }
    }

    /// Auth methods are advertised by the agent in `InitializeResponse`. V1
    /// does not implement in-app auth; this structured stub lets the type
    /// round-trip without losing field-level fidelity.
    struct AuthMethod: Codable, Equatable {
        let id: String
        let name: String
        let description: String?
    }

    struct InitializeResponse: Codable, Equatable {
        let protocolVersion: Int
        let agentCapabilities: AgentCapabilities?
        let agentInfo: Implementation?
        let authMethods: [AuthMethod]?
    }

    // MARK: - MCP servers (V1 always sends an empty array)

    /// Stdio MCP server. V1 doesn't register any, but the type is here so
    /// `NewSessionRequest` and `LoadSessionRequest` can encode `[]` cleanly.
    struct McpServer: Codable, Equatable {
        let name: String
        let command: String
        let args: [String]
        let env: [EnvVariable]
    }

    struct EnvVariable: Codable, Equatable {
        let name: String
        let value: String
    }

    // MARK: - Mode / model state

    struct SessionMode: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let description: String?
    }

    struct SessionModeState: Codable, Equatable {
        let availableModes: [SessionMode]
        let currentModeId: String
    }

    struct ModelInfo: Codable, Equatable, Identifiable {
        var id: String {
            modelId
        }

        let modelId: String
        let name: String
        let description: String?
    }

    struct SessionModelState: Codable, Equatable {
        let availableModels: [ModelInfo]
        let currentModelId: String
    }

    // MARK: - session/new

    struct NewSessionRequest: Codable, Equatable {
        let cwd: String
        let mcpServers: [McpServer]

        init(cwd: String, mcpServers: [McpServer] = []) {
            self.cwd = cwd
            self.mcpServers = mcpServers
        }
    }

    struct NewSessionResponse: Codable, Equatable {
        let sessionId: String
        let modes: SessionModeState?
        let models: SessionModelState?
    }

    // MARK: - session/load

    struct LoadSessionRequest: Codable, Equatable {
        let sessionId: String
        let cwd: String
        let mcpServers: [McpServer]

        init(sessionId: String, cwd: String, mcpServers: [McpServer] = []) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.mcpServers = mcpServers
        }
    }

    struct LoadSessionResponse: Codable, Equatable {
        let modes: SessionModeState?
        let models: SessionModelState?
    }

    // MARK: - session/prompt

    struct PromptRequest: Codable, Equatable {
        let sessionId: String
        let prompt: [ContentBlock]
        let messageId: String?

        init(sessionId: String, prompt: [ContentBlock], messageId: String? = nil) {
            self.sessionId = sessionId
            self.prompt = prompt
            self.messageId = messageId
        }
    }

    enum StopReason: String, Codable, Equatable {
        case endTurn = "end_turn"
        case maxTokens = "max_tokens"
        case maxTurnRequests = "max_turn_requests"
        case refusal
        case cancelled
    }

    struct Usage: Codable, Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let cachedReadTokens: Int?
        let cachedWriteTokens: Int?
        let thoughtTokens: Int?
    }

    /// Decoder accepts an unknown stop reason without throwing. Monitor maps
    /// `nil` recognized cases to `.unknown(rawValue)` when handing off to the
    /// shared `SessionStopReason`.
    struct PromptResponse: Codable, Equatable {
        let stopReason: StopReason?
        /// Present iff the agent sent a stopReason we don't recognize. The
        /// monitor preserves the raw string so callers can log/reason about it.
        let unknownStopReason: String?
        let usage: Usage?
        let userMessageId: String?

        init(
            stopReason: StopReason?,
            unknownStopReason: String? = nil,
            usage: Usage? = nil,
            userMessageId: String? = nil
        ) {
            self.stopReason = stopReason
            self.unknownStopReason = unknownStopReason
            self.usage = usage
            self.userMessageId = userMessageId
        }

        private enum CodingKeys: String, CodingKey {
            case stopReason, usage, userMessageId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let known = try? container.decodeIfPresent(StopReason.self, forKey: .stopReason) {
                self.stopReason = known
                self.unknownStopReason = nil
            } else if let raw = try container.decodeIfPresent(String.self, forKey: .stopReason) {
                self.stopReason = nil
                self.unknownStopReason = raw
            } else {
                self.stopReason = nil
                self.unknownStopReason = nil
            }
            self.usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
            self.userMessageId = try container.decodeIfPresent(String.self, forKey: .userMessageId)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let stopReason {
                try container.encode(stopReason, forKey: .stopReason)
            } else if let unknownStopReason {
                try container.encode(unknownStopReason, forKey: .stopReason)
            }
            try container.encodeIfPresent(usage, forKey: .usage)
            try container.encodeIfPresent(userMessageId, forKey: .userMessageId)
        }
    }

    // MARK: - session/cancel (notification)

    struct CancelNotification: Codable, Equatable {
        let sessionId: String
    }

    // MARK: - session/set_mode, session/set_model

    struct SetSessionModeRequest: Codable, Equatable {
        let sessionId: String
        let modeId: String
    }

    struct SetSessionModeResponse: Codable, Equatable {}

    struct SetSessionModelRequest: Codable, Equatable {
        let sessionId: String
        let modelId: String
    }
}
