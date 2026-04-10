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
            case allow(updatedInput: [String: Any])
            case deny(message: String)

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case let .allow(updatedInput):
                    try container.encode("allow", forKey: .behavior)
                    // updatedInput contains arbitrary tool input, encode via JSONSerialization
                    let data = try JSONSerialization.data(withJSONObject: updatedInput)
                    let raw = try JSONDecoder().decode(AnyCodable.self, from: data)
                    try container.encode(raw, forKey: .updatedInput)
                case let .deny(message):
                    try container.encode("deny", forKey: .behavior)
                    try container.encode(message, forKey: .message)
                }
            }

            private enum CodingKeys: String, CodingKey {
                case behavior, updatedInput, message
            }
        }

        static func allow(requestId: String, updatedInput: [String: Any]) -> PermissionResponse {
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

    // MARK: - Incoming Events (parsed from [String: Any])

    enum Event {
        case system(sessionId: String?, model: String?, permissionMode: String?)
        case assistant(uuid: String, contentBlocks: [[String: Any]])
        case user(uuid: String, contentBlocks: [[String: Any]])
        case streamEvent(innerType: String, delta: [String: Any]?)
        case controlRequest(requestId: String, request: [String: Any])
        case controlResponse(response: [String: Any])
        case result(isError: Bool, modelUsage: [String: Any]?, sessionId: String?)
        case rateLimitEvent(utilization: Double, resetsAt: TimeInterval?)
        case unknown(type: String)

        static func parse(_ object: [String: Any]) -> Event? {
            guard let type = object["type"] as? String else { return nil }
            switch type {
            case "system":
                return .system(
                    sessionId: object["session_id"] as? String,
                    model: object["model"] as? String,
                    permissionMode: object["permissionMode"] as? String
                )
            case "assistant":
                let message = object["message"] as? [String: Any] ?? [:]
                let content = message["content"] as? [[String: Any]] ?? []
                return .assistant(
                    uuid: object["uuid"] as? String ?? UUID().uuidString,
                    contentBlocks: content
                )
            case "user":
                let message = object["message"] as? [String: Any] ?? [:]
                let content = message["content"] as? [[String: Any]] ?? []
                return .user(uuid: object["uuid"] as? String ?? UUID().uuidString, contentBlocks: content)
            case "stream_event":
                let inner = object["event"] as? [String: Any] ?? [:]
                return .streamEvent(innerType: inner["type"] as? String ?? "", delta: inner["delta"] as? [String: Any])
            case "control_request":
                guard let requestId = object["request_id"] as? String,
                      let request = object["request"] as? [String: Any]
                else { return nil }
                return .controlRequest(requestId: requestId, request: request)
            case "control_response":
                let resp = object["response"] as? [String: Any] ?? [:]
                let inner = resp["response"] as? [String: Any] ?? [:]
                return .controlResponse(response: inner)
            case "result":
                return .result(
                    isError: object["is_error"] as? Bool ?? false,
                    modelUsage: object["modelUsage"] as? [String: Any],
                    sessionId: object["session_id"] as? String
                )
            case "rate_limit_event":
                let info = object["rate_limit_info"] as? [String: Any] ?? [:]
                let utilization = info["utilization"] as? Double ?? 0
                let resetsAt = info["resetsAt"] as? TimeInterval
                return .rateLimitEvent(utilization: utilization, resetsAt: resetsAt)
            default:
                return .unknown(type: type)
            }
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

/// Wrapper to encode arbitrary JSON values from JSONSerialization into Codable.
private struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable(value: $0) })
        case let array as [Any]:
            try container.encode(array.map { AnyCodable(value: $0) })
        case let string as String:
            try container.encode(string)
        case let number as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(number) {
                try container.encode(number.boolValue)
            } else {
                try container.encode(number.doubleValue)
            }
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        default:
            try container.encodeNil()
        }
    }

    init(value: Any) {
        self.value = value
    }
}
