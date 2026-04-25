import Foundation

/// Loose JSON value used for protocol-level fields whose schema is `unknown`
/// (e.g. `rawInput`, `rawOutput`, `_meta`) and for staged decoding of
/// incoming frames before the concrete payload type is known.
enum GeminiAcpJsonValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Re-decode this loose value into a concrete `Decodable` type. Useful
    /// after reading an incoming frame's `params`/`result` and dispatching by
    /// method.
    func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// JSON-RPC 2.0 framing for the Gemini ACP wire protocol.
///
/// Communicate over stdio with newline-delimited JSON (no `Content-Length`
/// framing). One JSON object per line; encoder appends `\n` after each frame.
enum GeminiAcpRpc {
    /// JSON-RPC request id. The spec allows int, string, or null.
    enum Id: Codable, Equatable, Hashable {
        case int(Int)
        case string(String)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
                return
            }
            if let int = try? container.decode(Int.self) {
                self = .int(int)
                return
            }
            self = try .string(container.decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .int(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    /// JSON-RPC error object.
    struct ErrorObject: Codable, Equatable {
        let code: Int
        let message: String
        let data: GeminiAcpJsonValue?
    }

    /// Outgoing request envelope. `Params` must be `Encodable`.
    struct Request<Params: Encodable>: Encodable {
        let jsonrpc: String
        let id: Id
        let method: String
        let params: Params?

        init(id: Id, method: String, params: Params? = nil) {
            self.jsonrpc = "2.0"
            self.id = id
            self.method = method
            self.params = params
        }
    }

    /// Outgoing notification envelope (no response expected).
    struct Notification<Params: Encodable>: Encodable {
        let jsonrpc: String
        let method: String
        let params: Params?

        init(method: String, params: Params? = nil) {
            self.jsonrpc = "2.0"
            self.method = method
            self.params = params
        }
    }

    /// Outgoing response envelope. Used when the agent makes a request of us
    /// (e.g. `session/request_permission`) and we reply with a result.
    struct Response<Result: Encodable>: Encodable {
        let jsonrpc: String
        let id: Id
        let result: Result

        init(id: Id, result: Result) {
            self.jsonrpc = "2.0"
            self.id = id
            self.result = result
        }
    }

    /// Outgoing error response envelope.
    struct ErrorResponse: Encodable {
        let jsonrpc: String
        let id: Id
        let error: ErrorObject

        init(id: Id, error: ErrorObject) {
            self.jsonrpc = "2.0"
            self.id = id
            self.error = error
        }
    }

    /// Incoming frame after JSON parsing but before per-method decoding.
    /// Three cases:
    ///   - `.response`: has an `id` and `result` or `error`. Match against
    ///     a pending request to dispatch.
    ///   - `.request`: has an `id` and a `method`. The agent expects a reply.
    ///   - `.notification`: has a `method` but no `id`. Fire-and-forget.
    ///
    /// `params`/`result` are kept as raw `GeminiAcpJsonValue` so callers can
    /// decode them into a concrete typed payload once the method/id is known.
    enum IncomingFrame: Equatable {
        case response(IncomingResponse)
        case request(IncomingRequest)
        case notification(IncomingNotification)
    }

    struct IncomingResponse: Equatable {
        let id: Id
        let result: GeminiAcpJsonValue?
        let error: ErrorObject?
    }

    struct IncomingRequest: Equatable {
        let id: Id
        let method: String
        let params: GeminiAcpJsonValue?
    }

    struct IncomingNotification: Equatable {
        let method: String
        let params: GeminiAcpJsonValue?
    }

    /// Parses a single newline-delimited JSON frame into an `IncomingFrame`.
    /// Returns `nil` for unrecognized envelopes (e.g. missing both `id` and
    /// `method`). Callers should log and continue.
    static func decodeIncoming(_ data: Data) throws -> IncomingFrame? {
        let raw = try JSONDecoder().decode(IncomingRaw.self, from: data)
        if let id = raw.id {
            if let method = raw.method {
                return .request(IncomingRequest(id: id, method: method, params: raw.params))
            }
            return .response(IncomingResponse(id: id, result: raw.result, error: raw.error))
        }
        if let method = raw.method {
            return .notification(IncomingNotification(method: method, params: raw.params))
        }
        return nil
    }

    private struct IncomingRaw: Decodable {
        let jsonrpc: String?
        let id: Id?
        let method: String?
        let params: GeminiAcpJsonValue?
        let result: GeminiAcpJsonValue?
        let error: ErrorObject?
    }
}
