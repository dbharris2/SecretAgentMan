import Foundation

/// Typed wire-format messages for the Codex app-server JSON-RPC protocol.
/// Replaces hand-built [String: Any] dictionaries with Encodable structs.
enum CodexProtocol {
    // MARK: - Outgoing Messages

    struct RPCRequest: Encodable {
        let id: Int
        let method: String
        let params: [String: AnyCodableValue]

        static func initialize(id: Int) -> RPCRequest {
            RPCRequest(id: id, method: "initialize", params: [
                "clientInfo": .dict([
                    "name": .string("secret-agent-man"),
                    "title": .string("SecretAgentMan"),
                    "version": .string("0.1.0"),
                ]),
                "capabilities": .dict([
                    "experimentalApi": .bool(true),
                ]),
            ])
        }

        static func threadStart(id: Int, cwd: String, approvalPolicy: String = "untrusted") -> RPCRequest {
            RPCRequest(id: id, method: "thread/start", params: [
                "cwd": .string(cwd),
                "approvalPolicy": .string(approvalPolicy),
                "sandbox": .string("workspace-write"),
                "personality": .string("pragmatic"),
            ])
        }

        static func threadResume(id: Int, threadId: String, cwd: String) -> RPCRequest {
            RPCRequest(id: id, method: "thread/resume", params: [
                "threadId": .string(threadId),
                "cwd": .string(cwd),
            ])
        }

        static func threadRead(id: Int, threadId: String) -> RPCRequest {
            RPCRequest(id: id, method: "thread/read", params: [
                "threadId": .string(threadId),
                "includeTurns": .bool(false),
            ])
        }

        static func turnStart(
            id: Int,
            threadId: String,
            text: String,
            imagePaths: [String] = [],
            collaborationMode: [String: AnyCodableValue] = [:]
        ) -> RPCRequest {
            var input: [AnyCodableValue] = imagePaths.map { path in
                .dict(["type": .string("localImage"), "path": .string(path)])
            }
            input.append(.dict(["type": .string("text"), "text": .string(text)]))

            var params: [String: AnyCodableValue] = [
                "threadId": .string(threadId),
                "input": .array(input),
            ]
            if !collaborationMode.isEmpty {
                params["collaborationMode"] = .dict(collaborationMode)
            }
            return RPCRequest(id: id, method: "turn/start", params: params)
        }
    }

    struct RPCResponse: Encodable {
        let id: Int
        let result: [String: AnyCodableValue]

        static func approvalDecision(id: Int, accept: Bool) -> RPCResponse {
            RPCResponse(id: id, result: [
                "decision": .string(accept ? "accept" : "decline"),
            ])
        }

        static func userInputAnswers(id: Int, answers: [String: [String: [String]]]) -> RPCResponse {
            let encoded = answers.mapValues { inner in
                AnyCodableValue.dict(inner.mapValues { arr in
                    AnyCodableValue.array(arr.map { .string($0) })
                })
            }
            return RPCResponse(id: id, result: [
                "answers": .dict(encoded),
            ])
        }
    }

    // MARK: - Encoding Helpers

    static func encode(_ value: Encodable) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func encodeLine(_ value: Encodable) -> Data? {
        guard var data = encode(value) else { return nil }
        data.append(0x0A)
        return data
    }
}

/// A type-safe JSON value that can be encoded without [String: Any] casts.
enum AnyCodableValue: Encodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case dict([String: AnyCodableValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(v): try container.encode(v)
        case let .int(v): try container.encode(v)
        case let .double(v): try container.encode(v)
        case let .bool(v): try container.encode(v)
        case .null: try container.encodeNil()
        case let .array(v): try container.encode(v)
        case let .dict(v): try container.encode(v)
        }
    }
}
