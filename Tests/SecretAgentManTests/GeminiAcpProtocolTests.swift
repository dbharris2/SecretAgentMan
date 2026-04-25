import Foundation
@testable import SecretAgentMan
import Testing

/// Encoding/decoding tests for `GeminiAcpProtocol` and `GeminiAcpRpc`.
/// JSON fixtures here mirror real frames produced by `gemini-cli 0.38.2`.
/// If the spec drifts, these will fail visibly.
struct GeminiAcpProtocolTests {
    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    private static let decoder = JSONDecoder()

    private static func roundTripJson<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try Self.encoder.encode(value)
        return try Self.decoder.decode(T.self, from: data)
    }

    private static func decodeJson<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        let data = Data(json.utf8)
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: - JSON-RPC framing

    @Test func incomingResponseFrame() throws {
        let json = #"{"jsonrpc":"2.0","id":7,"result":{"sessionId":"sess-1"}}"#
        let frame = try GeminiAcpRpc.decodeIncoming(Data(json.utf8))
        guard case let .response(resp) = frame else {
            Issue.record("Expected response frame, got \(String(describing: frame))")
            return
        }
        #expect(resp.id == .int(7))
        #expect(resp.error == nil)
        #expect(resp.result != nil)
    }

    @Test func incomingErrorResponseFrame() throws {
        let json = #"""
        {"jsonrpc":"2.0","id":"req-3","error":{"code":-32600,"message":"Invalid request"}}
        """#
        let frame = try GeminiAcpRpc.decodeIncoming(Data(json.utf8))
        guard case let .response(resp) = frame else {
            Issue.record("Expected response frame, got \(String(describing: frame))")
            return
        }
        #expect(resp.id == .string("req-3"))
        #expect(resp.error?.code == -32600)
        #expect(resp.error?.message == "Invalid request")
    }

    @Test func incomingRequestFrame() throws {
        let json = #"""
        {"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"s","options":[],"toolCall":{"toolCallId":"t1"}}}
        """#
        let frame = try GeminiAcpRpc.decodeIncoming(Data(json.utf8))
        guard case let .request(req) = frame else {
            Issue.record("Expected request frame, got \(String(describing: frame))")
            return
        }
        #expect(req.id == .int(42))
        #expect(req.method == "session/request_permission")
        #expect(req.params != nil)
    }

    @Test func incomingNotificationFrame() throws {
        let json = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}
        """#
        let frame = try GeminiAcpRpc.decodeIncoming(Data(json.utf8))
        guard case let .notification(note) = frame else {
            Issue.record("Expected notification frame, got \(String(describing: frame))")
            return
        }
        #expect(note.method == "session/update")
        #expect(note.params != nil)
    }

    @Test func decodingMalformedEnvelopeReturnsNil() throws {
        let json = #"{"jsonrpc":"2.0"}"#
        #expect(try GeminiAcpRpc.decodeIncoming(Data(json.utf8)) == nil)
    }

    @Test func requestEncoderEmitsJsonRpcVersionAndShape() throws {
        let request = GeminiAcpRpc.Request<GeminiAcpProtocol.NewSessionRequest>(
            id: .int(1),
            method: "session/new",
            params: GeminiAcpProtocol.NewSessionRequest(cwd: "/repo")
        )
        let data = try Self.encoder.encode(request)
        let raw = try Self.decoder.decode(RawEnvelope.self, from: data)
        #expect(raw.jsonrpc == "2.0")
        #expect(raw.id == 1)
        #expect(raw.method == "session/new")
    }

    @Test func notificationEncoderOmitsId() throws {
        let note = GeminiAcpRpc.Notification<GeminiAcpProtocol.CancelNotification>(
            method: "session/cancel",
            params: GeminiAcpProtocol.CancelNotification(sessionId: "s")
        )
        let data = try Self.encoder.encode(note)
        let raw = try Self.decoder.decode(RawEnvelope.self, from: data)
        #expect(raw.method == "session/cancel")
        #expect(raw.id == nil)
    }

    @Test func idRoundTripsForIntStringNull() throws {
        for id: GeminiAcpRpc.Id in [.int(5), .string("abc"), .null] {
            let data = try Self.encoder.encode(id)
            let decoded = try Self.decoder.decode(GeminiAcpRpc.Id.self, from: data)
            #expect(decoded == id)
        }
    }

    // MARK: - Initialize

    @Test func initializeRequestEncodesV1Defaults() throws {
        let request = GeminiAcpProtocol.InitializeRequest(
            clientInfo: GeminiAcpProtocol.Implementation(
                name: "secret-agent-man",
                title: nil,
                version: "0.1.0"
            )
        )
        let data = try Self.encoder.encode(request)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""protocolVersion":1"#))
        #expect(json.contains(#""terminal":false"#))
        #expect(json.contains(#""readTextFile":false"#))
        #expect(json.contains(#""writeTextFile":false"#))
    }

    @Test func initializeResponseDecodesAgentCapabilities() throws {
        let json = #"""
        {
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": true,
                "promptCapabilities": {"audio": false, "embeddedContext": false, "image": true}
            },
            "agentInfo": {"name": "gemini", "version": "0.38.2"}
        }
        """#
        let response = try Self.decodeJson(json, as: GeminiAcpProtocol.InitializeResponse.self)
        #expect(response.protocolVersion == 1)
        #expect(response.agentCapabilities?.loadSession == true)
        #expect(response.agentCapabilities?.promptCapabilities?.image == true)
        #expect(response.agentInfo?.name == "gemini")
    }

    // MARK: - Session lifecycle

    @Test func newSessionResponseDecodesWithModesAndModels() throws {
        let json = #"""
        {
            "sessionId": "s-1",
            "modes": {
                "availableModes": [{"id": "auto", "name": "Auto"}],
                "currentModeId": "auto"
            },
            "models": {
                "availableModels": [{"modelId": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"}],
                "currentModelId": "gemini-2.5-pro"
            }
        }
        """#
        let response = try Self.decodeJson(json, as: GeminiAcpProtocol.NewSessionResponse.self)
        #expect(response.sessionId == "s-1")
        #expect(response.modes?.currentModeId == "auto")
        #expect(response.models?.availableModels.first?.modelId == "gemini-2.5-pro")
    }

    @Test func newSessionResponseDecodesMinimal() throws {
        let response = try Self.decodeJson(
            #"{"sessionId": "s-2"}"#,
            as: GeminiAcpProtocol.NewSessionResponse.self
        )
        #expect(response.sessionId == "s-2")
        #expect(response.modes == nil)
        #expect(response.models == nil)
    }

    @Test func loadSessionRequestEncodesShape() throws {
        let request = GeminiAcpProtocol.LoadSessionRequest(
            sessionId: "stored-1",
            cwd: "/repo"
        )
        let data = try Self.encoder.encode(request)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""sessionId":"stored-1""#))
        #expect(json.contains(#""cwd":"/repo""#))
        #expect(json.contains(#""mcpServers":[]"#))
    }

    @Test func cancelNotificationRoundTrips() throws {
        let note = GeminiAcpProtocol.CancelNotification(sessionId: "s-1")
        let restored = try Self.roundTripJson(note)
        #expect(restored == note)
    }

    // MARK: - Prompt

    @Test func promptRequestEncodesTextAndImage() throws {
        let request = GeminiAcpProtocol.PromptRequest(
            sessionId: "s-1",
            prompt: [
                .text(GeminiAcpProtocol.TextContent(text: "describe this")),
                .image(GeminiAcpProtocol.ImageContent(data: "BASE64", mimeType: "image/png")),
            ],
            messageId: "local-msg-1"
        )
        let data = try Self.encoder.encode(request)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""type":"text""#))
        #expect(json.contains(#""text":"describe this""#))
        #expect(json.contains(#""type":"image""#))
        #expect(json.contains(#""mimeType":"image/png""#))
        #expect(json.contains(#""messageId":"local-msg-1""#))
    }

    @Test func promptResponseDecodesEachKnownStopReason() throws {
        let raws: [(String, GeminiAcpProtocol.StopReason)] = [
            ("end_turn", .endTurn),
            ("max_tokens", .maxTokens),
            ("max_turn_requests", .maxTurnRequests),
            ("refusal", .refusal),
            ("cancelled", .cancelled),
        ]
        for (raw, expected) in raws {
            let json = #"{"stopReason":"\#(raw)"}"#
            let response = try Self.decodeJson(json, as: GeminiAcpProtocol.PromptResponse.self)
            #expect(response.stopReason == expected)
            #expect(response.unknownStopReason == nil)
        }
    }

    @Test func promptResponseDecodesUnknownStopReason() throws {
        let json = #"{"stopReason":"future_reason"}"#
        let response = try Self.decodeJson(json, as: GeminiAcpProtocol.PromptResponse.self)
        #expect(response.stopReason == nil)
        #expect(response.unknownStopReason == "future_reason")
    }

    @Test func promptResponseDecodesUsage() throws {
        let json = #"""
        {
            "stopReason": "end_turn",
            "usage": {"inputTokens": 100, "outputTokens": 50, "totalTokens": 150, "thoughtTokens": 5},
            "userMessageId": "local-msg-1"
        }
        """#
        let response = try Self.decodeJson(json, as: GeminiAcpProtocol.PromptResponse.self)
        #expect(response.usage?.inputTokens == 100)
        #expect(response.usage?.thoughtTokens == 5)
        #expect(response.userMessageId == "local-msg-1")
    }

    // MARK: - Session updates

    @Test func sessionUpdateDecodesAgentMessageChunk() throws {
        let json = #"""
        {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hello"}}
        """#
        let update = try Self.decodeJson(json, as: GeminiAcpProtocol.SessionUpdate.self)
        guard case let .agentMessageChunk(chunk) = update else {
            Issue.record("Expected agentMessageChunk, got \(update)")
            return
        }
        if case let .text(text) = chunk.content {
            #expect(text.text == "Hello")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test func sessionUpdateDecodesAgentThoughtChunk() throws {
        let json = #"""
        {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "thinking..."}}
        """#
        let update = try Self.decodeJson(json, as: GeminiAcpProtocol.SessionUpdate.self)
        if case .agentThoughtChunk = update {
            // ok
        } else {
            Issue.record("Expected agentThoughtChunk, got \(update)")
        }
    }

    @Test func sessionUpdateDecodesToolCallWithContent() throws {
        let json = #"""
        {
            "sessionUpdate": "tool_call",
            "toolCallId": "tc1",
            "title": "Read file",
            "kind": "read",
            "status": "in_progress",
            "locations": [{"path": "/repo/src/main.swift", "line": 10}],
            "content": [{"type": "content", "content": {"type": "text", "text": "file body"}}]
        }
        """#
        let update = try Self.decodeJson(json, as: GeminiAcpProtocol.SessionUpdate.self)
        guard case let .toolCall(call) = update else {
            Issue.record("Expected toolCall, got \(update)")
            return
        }
        #expect(call.toolCallId == "tc1")
        #expect(call.title == "Read file")
        #expect(call.kind == .read)
        #expect(call.status == .inProgress)
        #expect(call.locations?.first?.line == 10)
        #expect(call.content?.count == 1)
    }

    @Test func sessionUpdateDecodesToolCallUpdateAllowsPartialFields() throws {
        let json = #"""
        {"sessionUpdate": "tool_call_update", "toolCallId": "tc1", "status": "completed"}
        """#
        let update = try Self.decodeJson(json, as: GeminiAcpProtocol.SessionUpdate.self)
        guard case let .toolCallUpdate(call) = update else {
            Issue.record("Expected toolCallUpdate, got \(update)")
            return
        }
        #expect(call.toolCallId == "tc1")
        #expect(call.status == .completed)
        #expect(call.title == nil)
    }

    @Test func sessionUpdateDecodesPlan() throws {
        let json = #"""
        {
            "sessionUpdate": "plan",
            "entries": [
                {"content": "step 1", "priority": "high", "status": "in_progress"},
                {"content": "step 2", "priority": "medium", "status": "pending"}
            ]
        }
        """#
        let update = try Self.decodeJson(json, as: GeminiAcpProtocol.SessionUpdate.self)
        guard case let .plan(plan) = update else {
            Issue.record("Expected plan, got \(update)")
            return
        }
        #expect(plan.entries.count == 2)
        #expect(plan.entries[0].priority == .high)
        #expect(plan.entries[0].status == .inProgress)
    }

    @Test func sessionUpdateDecodesAvailableCommands() throws {
        let json = #"""
        {
            "sessionUpdate": "available_commands_update",
            "availableCommands": [
                {"name": "compress", "description": "Compress conversation"},
                {"name": "memory", "description": "Manage memory", "input": {"hint": "<text>"}}
            ]
        }
        """#
        let update = try Self.decodeJson(json, as: GeminiAcpProtocol.SessionUpdate.self)
        guard case let .availableCommandsUpdate(cmds) = update else {
            Issue.record("Expected availableCommandsUpdate, got \(update)")
            return
        }
        #expect(cmds.availableCommands.count == 2)
        #expect(cmds.availableCommands[1].input?.hint == "<text>")
    }

    @Test func sessionUpdateDecodesCurrentModeUpdate() throws {
        let json = #"{"sessionUpdate": "current_mode_update", "currentModeId": "auto"}"#
        let update = try Self.decodeJson(json, as: GeminiAcpProtocol.SessionUpdate.self)
        guard case let .currentModeUpdate(mode) = update else {
            Issue.record("Expected currentModeUpdate, got \(update)")
            return
        }
        #expect(mode.currentModeId == "auto")
    }

    @Test func sessionUpdateDecodesUnknownKindWithoutThrowing() throws {
        let json = #"{"sessionUpdate": "future_update_kind", "extra": 42}"#
        let update = try Self.decodeJson(json, as: GeminiAcpProtocol.SessionUpdate.self)
        guard case let .unknown(kind, _) = update else {
            Issue.record("Expected unknown, got \(update)")
            return
        }
        #expect(kind == "future_update_kind")
    }

    // MARK: - Content blocks

    @Test func contentBlockDecodesUnknownTypeWithoutThrowing() throws {
        let json = #"{"type":"some_future_block","weird":true}"#
        let block = try Self.decodeJson(json, as: GeminiAcpProtocol.ContentBlock.self)
        guard case let .unknown(type, _) = block else {
            Issue.record("Expected unknown, got \(block)")
            return
        }
        #expect(type == "some_future_block")
    }

    @Test func contentBlockTextRoundTrips() throws {
        let block = GeminiAcpProtocol.ContentBlock.text(
            GeminiAcpProtocol.TextContent(text: "round-trip")
        )
        let restored = try Self.roundTripJson(block)
        if case let .text(text) = restored {
            #expect(text.text == "round-trip")
        } else {
            Issue.record("Expected text after round-trip, got \(restored)")
        }
    }

    // MARK: - Permission

    @Test func requestPermissionRequestDecodesAllOptionKinds() throws {
        let json = #"""
        {
            "sessionId": "s-1",
            "toolCall": {"toolCallId": "tc1", "title": "Run rm -rf"},
            "options": [
                {"optionId": "ao", "name": "Allow once", "kind": "allow_once"},
                {"optionId": "aa", "name": "Allow always", "kind": "allow_always"},
                {"optionId": "ro", "name": "Reject once", "kind": "reject_once"},
                {"optionId": "ra", "name": "Reject always", "kind": "reject_always"}
            ]
        }
        """#
        let request = try Self.decodeJson(json, as: GeminiAcpProtocol.RequestPermissionRequest.self)
        #expect(request.options.count == 4)
        #expect(request.options.map(\.kind) == [.allowOnce, .allowAlways, .rejectOnce, .rejectAlways])
        #expect(request.toolCall.toolCallId == "tc1")
    }

    @Test func requestPermissionResponseEncodesSelected() throws {
        let response = GeminiAcpProtocol.RequestPermissionResponse(
            outcome: .selected(optionId: "ao")
        )
        let data = try Self.encoder.encode(response)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""outcome":"selected""#))
        #expect(json.contains(#""optionId":"ao""#))
    }

    @Test func requestPermissionResponseEncodesCancelled() throws {
        let response = GeminiAcpProtocol.RequestPermissionResponse(outcome: .cancelled)
        let data = try Self.encoder.encode(response)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""outcome":"cancelled""#))
        #expect(json.contains("optionId") == false)
    }

    @Test func requestPermissionResponseRoundTripsBothOutcomes() throws {
        for outcome: GeminiAcpProtocol.RequestPermissionOutcome in [.selected(optionId: "x"), .cancelled] {
            let original = GeminiAcpProtocol.RequestPermissionResponse(outcome: outcome)
            let restored = try Self.roundTripJson(original)
            #expect(restored == original)
        }
    }

    // MARK: - Set mode / model

    @Test func setSessionModeRequestEncodes() throws {
        let request = GeminiAcpProtocol.SetSessionModeRequest(sessionId: "s", modeId: "auto")
        let data = try Self.encoder.encode(request)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""sessionId":"s""#))
        #expect(json.contains(#""modeId":"auto""#))
    }

    @Test func setSessionModelRequestEncodes() throws {
        let request = GeminiAcpProtocol.SetSessionModelRequest(
            sessionId: "s",
            modelId: "gemini-2.5-pro"
        )
        let data = try Self.encoder.encode(request)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""modelId":"gemini-2.5-pro""#))
    }

    @Test func setSessionModeResponseDecodesEmpty() throws {
        let json = "{}"
        _ = try Self.decodeJson(json, as: GeminiAcpProtocol.SetSessionModeResponse.self)
    }

    // MARK: - Method name constants

    @Test func methodConstantsMatchAcpSpec() {
        #expect(GeminiAcpProtocol.Method.initialize == "initialize")
        #expect(GeminiAcpProtocol.Method.sessionNew == "session/new")
        #expect(GeminiAcpProtocol.Method.sessionLoad == "session/load")
        #expect(GeminiAcpProtocol.Method.sessionPrompt == "session/prompt")
        #expect(GeminiAcpProtocol.Method.sessionCancel == "session/cancel")
        #expect(GeminiAcpProtocol.Method.sessionUpdate == "session/update")
        #expect(GeminiAcpProtocol.Method.sessionRequestPermission == "session/request_permission")
        #expect(GeminiAcpProtocol.Method.sessionSetMode == "session/set_mode")
        #expect(GeminiAcpProtocol.Method.sessionSetModel == "session/set_model")
    }

    // MARK: - JsonValue staged decoding

    @Test func jsonValueDecodeAsTypedShape() throws {
        // Stage 1: parse as loose JsonValue
        let json = #"{"sessionId":"s","update":{"sessionUpdate":"current_mode_update","currentModeId":"auto"}}"#
        let frame = try GeminiAcpRpc.decodeIncoming(Data(
            #"{"jsonrpc":"2.0","method":"session/update","params":\#(json)}"#.utf8
        ))
        guard case let .notification(note) = frame else {
            Issue.record("Expected notification frame")
            return
        }
        // Stage 2: re-decode params as the typed shape
        let params = try #require(note.params)
        let decoded = try params.decode(as: GeminiAcpProtocol.SessionNotification.self)
        #expect(decoded.sessionId == "s")
        if case let .currentModeUpdate(mode) = decoded.update {
            #expect(mode.currentModeId == "auto")
        } else {
            Issue.record("Expected currentModeUpdate")
        }
    }
}

/// Helper for verifying envelope-level fields without depending on the
/// generic param type.
private struct RawEnvelope: Decodable {
    let jsonrpc: String?
    let id: Int?
    let method: String?
}
