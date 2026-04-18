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

        static func threadStart(id: Int, cwd: String, approvalPolicy: String = "on-request") -> RPCRequest {
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

    // MARK: - Incoming Events (parsed from [String: Any])

    enum Event {
        case response(requestId: Int, object: [String: Any])
        case userInputRequest(requestId: Int, params: [String: Any])
        case approvalRequest(requestId: Int, method: String, params: [String: Any])
        case itemStarted(item: [String: Any])
        case agentMessageDelta(itemId: String, delta: String)
        case outputDelta(kind: ToolOutputKind, itemId: String, delta: String)
        case itemCompleted(item: [String: Any])
        case turnStarted(turnId: String)
        case turnCompleted(turnId: String)
        case threadStatusChanged(status: [String: Any])
        case error(message: String)
        case unknown(method: String?)

        enum ToolOutputKind {
            case commandExecution
            case fileChange
        }

        static func parse(_ object: [String: Any]) -> Event? {
            if let id = object["id"] as? Int, object["method"] == nil {
                return .response(requestId: id, object: object)
            }
            guard let method = object["method"] as? String else { return nil }
            let params = object["params"] as? [String: Any] ?? [:]
            let requestId = object["id"] as? Int
            if let requestEvent = requestEvent(method: method, params: params, requestId: requestId) {
                return requestEvent
            }
            if let itemEvent = itemEvent(method: method, params: params) {
                return itemEvent
            }
            if let turnEvent = turnLifecycleEvent(method: method, params: params) {
                return turnEvent
            }
            if let threadEvent = threadEvent(method: method, params: params) {
                return threadEvent
            }
            if let errorEvent = errorEvent(method: method, params: params) {
                return errorEvent
            }
            return .unknown(method: method)
        }

        private static func requestEvent(
            method: String,
            params: [String: Any],
            requestId: Int?
        ) -> Event? {
            switch method {
            case "item/tool/requestUserInput":
                guard let requestId else { return .unknown(method: method) }
                return .userInputRequest(requestId: requestId, params: params)
            case "item/commandExecution/requestApproval",
                 "item/fileChange/requestApproval",
                 "item/permissions/requestApproval":
                guard let requestId else { return .unknown(method: method) }
                return .approvalRequest(requestId: requestId, method: method, params: params)
            default:
                return nil
            }
        }

        private static func itemEvent(method: String, params: [String: Any]) -> Event? {
            switch method {
            case "item/started":
                guard let item = params["item"] as? [String: Any] else { return .unknown(method: method) }
                return .itemStarted(item: item)
            case "item/agentMessage/delta":
                return deltaEvent(method: method, params: params)
            case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
                return toolOutputEvent(method: method, params: params)
            case "item/completed":
                guard let item = params["item"] as? [String: Any] else { return .unknown(method: method) }
                return .itemCompleted(item: item)
            default:
                return nil
            }
        }

        private static func deltaEvent(method: String, params: [String: Any]) -> Event {
            guard let itemId = params["itemId"] as? String,
                  let delta = params["delta"] as? String,
                  !delta.isEmpty
            else { return .unknown(method: method) }
            return .agentMessageDelta(itemId: itemId, delta: delta)
        }

        private static func toolOutputEvent(method: String, params: [String: Any]) -> Event {
            guard let itemId = params["itemId"] as? String,
                  let delta = params["delta"] as? String,
                  !delta.isEmpty
            else { return .unknown(method: method) }
            let kind: ToolOutputKind = method == "item/fileChange/outputDelta" ? .fileChange : .commandExecution
            return .outputDelta(kind: kind, itemId: itemId, delta: delta)
        }

        private static func turnLifecycleEvent(method: String, params: [String: Any]) -> Event? {
            switch method {
            case "turn/started":
                guard let turnId = turnId(from: params) else { return .unknown(method: method) }
                return .turnStarted(turnId: turnId)
            case "turn/completed":
                guard let turnId = turnId(from: params) else { return .unknown(method: method) }
                return .turnCompleted(turnId: turnId)
            default:
                return nil
            }
        }

        private static func threadEvent(method: String, params: [String: Any]) -> Event? {
            guard method == "thread/status/changed" else { return nil }
            guard let status = params["status"] as? [String: Any] else { return .unknown(method: method) }
            return .threadStatusChanged(status: status)
        }

        private static func errorEvent(method: String, params: [String: Any]) -> Event? {
            guard method == "error" else { return nil }
            let errorInfo = params["error"] as? [String: Any] ?? [:]
            let message = errorInfo["message"] as? String ?? "Unknown error"
            return .error(message: message)
        }

        private static func turnId(from params: [String: Any]) -> String? {
            let turn = params["turn"] as? [String: Any]
            let turnId = (turn?["id"] as? String) ?? (params["turnId"] as? String) ?? ""
            return turnId.isEmpty ? nil : turnId
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
