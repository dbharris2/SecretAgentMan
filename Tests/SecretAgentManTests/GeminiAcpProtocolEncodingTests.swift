import Foundation
@testable import SecretAgentMan
import Testing

/// Wire-format encoding/decoding sanity tests. Catches issues with the
/// custom `ContentBlock` / `SessionUpdate` / `RequestPermissionOutcome`
/// encoders that aren't visible in higher-level monitor tests.
@MainActor
struct GeminiAcpProtocolEncodingTests {
    // MARK: - PromptRequest round-trip

    @Test func promptRequestEncodesContentBlocksWithType() throws {
        let request = GeminiAcpProtocol.PromptRequest(
            sessionId: "s-1",
            prompt: [
                .text(GeminiAcpProtocol.TextContent(text: "hello"))
            ],
            messageId: "client-msg-1"
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))

        // Wire shape gemini --acp expects per the bundled zPromptRequest schema:
        //   { sessionId, prompt: [{type, text}], messageId? }
        #expect(json.contains("\"sessionId\":\"s-1\""))
        #expect(json.contains("\"messageId\":\"client-msg-1\""))
        #expect(json.contains("\"text\":\"hello\""))
        #expect(json.contains("\"type\":\"text\""))
    }

    @Test func promptRequestRoundTripsThroughDecoder() throws {
        let original = GeminiAcpProtocol.PromptRequest(
            sessionId: "s-1",
            prompt: [
                .text(GeminiAcpProtocol.TextContent(text: "hello"))
            ],
            messageId: "client-msg-1"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeminiAcpProtocol.PromptRequest.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - ContentBlock encoding

    @Test func contentBlockTextEncodesBothKeys() throws {
        let block = GeminiAcpProtocol.ContentBlock.text(GeminiAcpProtocol.TextContent(text: "hi"))
        let data = try JSONEncoder().encode(block)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"text\":\"hi\""))
        #expect(json.contains("\"type\":\"text\""))
    }

    @Test func contentBlockImageEncodesDataAndMimeType() throws {
        let block = GeminiAcpProtocol.ContentBlock.image(GeminiAcpProtocol.ImageContent(
            data: "BASE64DATA",
            mimeType: "image/png"
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(block)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"data\":\"BASE64DATA\""))
        #expect(json.contains("\"mimeType\":\"image/png\""))
        #expect(json.contains("\"type\":\"image\""))
    }

    // MARK: - SessionNotification (incoming session/update) decoding

    @Test func sessionNotificationDecodesAgentMessageChunk() throws {
        let raw = #"""
        {
            "sessionId": "s-1",
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {
                    "type": "text",
                    "text": "Hello!"
                }
            }
        }
        """#
        let data = try #require(raw.data(using: .utf8))
        let parsed = try JSONDecoder().decode(GeminiAcpProtocol.SessionNotification.self, from: data)
        #expect(parsed.sessionId == "s-1")
        guard case let .agentMessageChunk(chunk) = parsed.update else {
            Issue.record("Expected agentMessageChunk, got \(parsed.update)")
            return
        }
        guard case let .text(text) = chunk.content else {
            Issue.record("Expected text content, got \(chunk.content)")
            return
        }
        #expect(text.text == "Hello!")
    }

    @Test func sessionNotificationDecodesToolCall() throws {
        let raw = #"""
        {
            "sessionId": "s-1",
            "update": {
                "sessionUpdate": "tool_call",
                "toolCallId": "tc-1",
                "title": "Read README",
                "kind": "read",
                "status": "in_progress"
            }
        }
        """#
        let data = try #require(raw.data(using: .utf8))
        let parsed = try JSONDecoder().decode(GeminiAcpProtocol.SessionNotification.self, from: data)
        guard case let .toolCall(call) = parsed.update else {
            Issue.record("Expected toolCall, got \(parsed.update)")
            return
        }
        #expect(call.toolCallId == "tc-1")
        #expect(call.title == "Read README")
        #expect(call.kind == .read)
        #expect(call.status == .inProgress)
    }

    // MARK: - End-to-end via JsonValue (the production decode path)

    @Test func sessionUpdateDecodesViaJsonValueRetrip() throws {
        // The Observer reads `params` as a `GeminiAcpJsonValue` and then
        // re-decodes it as a typed payload. This test exercises that exact
        // hop so a regression in JsonValue (e.g. Int/Double conflation) is
        // caught.
        let raw = #"""
        {
            "sessionId": "s-1",
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": { "type": "text", "text": "Hi" }
            }
        }
        """#
        let data = try #require(raw.data(using: .utf8))
        let value = try JSONDecoder().decode(GeminiAcpJsonValue.self, from: data)
        let parsed = try value.decode(as: GeminiAcpProtocol.SessionNotification.self)
        if case let .agentMessageChunk(chunk) = parsed.update,
           case let .text(text) = chunk.content {
            #expect(text.text == "Hi")
        } else {
            Issue.record("Round-trip via JsonValue lost shape")
        }
    }

    // MARK: - Incoming frame parsing

    @Test func decodeIncomingParsesNotification() throws {
        let raw = #"""
        {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": "s-1",
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": { "type": "text", "text": "Hi" }
                }
            }
        }
        """#
        let data = try #require(raw.data(using: .utf8))
        let frame = try GeminiAcpRpc.decodeIncoming(data)
        guard case let .notification(note) = frame else {
            Issue.record("Expected notification frame, got \(String(describing: frame))")
            return
        }
        #expect(note.method == "session/update")
        #expect(note.params != nil)
    }

    @Test func decodeIncomingParsesIncomingRequest() throws {
        let raw = #"""
        {
            "jsonrpc": "2.0",
            "id": 99,
            "method": "session/request_permission",
            "params": {
                "sessionId": "s-1",
                "toolCall": { "toolCallId": "tc-1", "title": "Run cmd" },
                "options": [
                    { "optionId": "ao", "name": "Allow once", "kind": "allow_once" }
                ]
            }
        }
        """#
        let data = try #require(raw.data(using: .utf8))
        let frame = try GeminiAcpRpc.decodeIncoming(data)
        guard case let .request(req) = frame else {
            Issue.record("Expected request frame, got \(String(describing: frame))")
            return
        }
        #expect(req.method == "session/request_permission")
        let parsed = try #require(try req.params?.decode(as: GeminiAcpProtocol.RequestPermissionRequest.self))
        #expect(parsed.options.first?.kind == .allowOnce)
    }
}
