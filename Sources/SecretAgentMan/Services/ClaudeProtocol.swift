import Foundation

/// Typed wire-format messages for the Claude Code stream-json protocol.
///
/// Outgoing messages and JSON encode/decode entry points live here.
/// Inbound event models split into `ClaudeProtocol+Inbound.swift` and
/// per-tool input projections live in `ClaudeProtocol+ToolInputs.swift`.
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
