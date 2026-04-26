import Foundation
@testable import SecretAgentMan
import Testing

struct ClaudeProtocolTests {
    // MARK: - UserMessage

    @Test
    func userMessageEncodesTextOnly() throws {
        let msg = ClaudeProtocol.UserMessage.build(text: "hello")
        let json = try requireJSON(msg)

        #expect(json["type"] as? String == "user")
        #expect(json["session_id"] as? String == "")

        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")

        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "hello")
    }

    @Test
    func userMessageEncodesImagesBeforeText() throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let msg = ClaudeProtocol.UserMessage.build(text: "describe this", images: [(imageData, "image/png")])
        let json = try requireJSON(msg)

        let message = try #require(json["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "image")
        #expect(content[1]["type"] as? String == "text")
        #expect(content[1]["text"] as? String == "describe this")

        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == imageData.base64EncodedString())
    }

    // MARK: - PermissionResponse

    @Test
    func allowResponseHasBehaviorAndUpdatedInput() throws {
        let resp = ClaudeProtocol.PermissionResponse.allow(
            requestId: "req-1",
            updatedInput: ["command": "ls -la"]
        )
        let json = try requireJSON(resp)

        let response = try #require(json["response"] as? [String: Any])
        #expect(response["subtype"] as? String == "success")
        #expect(response["request_id"] as? String == "req-1")

        let inner = try #require(response["response"] as? [String: Any])
        #expect(inner["behavior"] as? String == "allow")

        let input = try #require(inner["updatedInput"] as? [String: Any])
        #expect(input["command"] as? String == "ls -la")
    }

    @Test
    func denyResponseHasBehaviorAndMessage() throws {
        let resp = ClaudeProtocol.PermissionResponse.deny(requestId: "req-2", message: "Not allowed")
        let json = try requireJSON(resp)

        let response = try #require(json["response"] as? [String: Any])
        let inner = try #require(response["response"] as? [String: Any])
        #expect(inner["behavior"] as? String == "deny")
        #expect(inner["message"] as? String == "Not allowed")
        #expect(inner["updatedInput"] == nil)
    }

    @Test
    func allowResponseWithNestedInput() throws {
        let resp = ClaudeProtocol.PermissionResponse.allow(
            requestId: "req-3",
            updatedInput: [
                "questions": [
                    ["question": "What color?", "header": "Color"],
                ],
                "answers": ["What color?": "Blue"],
            ]
        )
        let json = try requireJSON(resp)

        let response = try #require(json["response"] as? [String: Any])
        let inner = try #require(response["response"] as? [String: Any])
        let input = try #require(inner["updatedInput"] as? [String: Any])
        #expect(input["answers"] != nil)
        #expect(input["questions"] != nil)
    }

    // MARK: - ControlRequest

    @Test
    func initializeRequestHasCorrectSubtype() throws {
        let req = ClaudeProtocol.ControlRequest.initialize()
        let json = try requireJSON(req)

        #expect(json["type"] as? String == "control_request")
        let request = try #require(json["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "initialize")
    }

    @Test
    func setPermissionModeRequestIncludesMode() throws {
        let req = ClaudeProtocol.ControlRequest.setPermissionMode("plan")
        let json = try requireJSON(req)

        let request = try #require(json["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "set_permission_mode")
        #expect(request["mode"] as? String == "plan")
    }

    // MARK: - decodeLine

    @Test
    func decodeLineReturnsNilForEmptyLine() throws {
        #expect(try ClaudeProtocol.decodeLine("") == nil)
        #expect(try ClaudeProtocol.decodeLine("   \t  ") == nil)
    }

    @Test
    func decodeLineThrowsOnMalformedJSON() {
        #expect(throws: (any Error).self) {
            try ClaudeProtocol.decodeLine("{not json")
        }
    }

    @Test
    func decodeLineThrowsOnMissingType() {
        #expect(throws: (any Error).self) {
            try ClaudeProtocol.decodeLine(#"{"no_type": true}"#)
        }
    }

    @Test
    func decodeLineParsesSystemEvent() throws {
        let line = #"""
        {"type":"system","session_id":"sess-1","model":"claude-opus-4-6[1m]","permissionMode":"default"}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .system(raw) = event else {
            Issue.record("expected system, got \(event)")
            return
        }
        let dict = raw.legacyDictionary()
        #expect(dict["session_id"] as? String == "sess-1")
        #expect(dict["model"] as? String == "claude-opus-4-6[1m]")
        #expect(dict["permissionMode"] as? String == "default")
    }

    @Test
    func decodeLineParsesControlRequestEvent() throws {
        let line = #"""
        {"type":"control_request","request_id":"req-5","request":{"subtype":"can_use_tool","tool_name":"Bash"}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .controlRequest(raw) = event else {
            Issue.record("expected control_request, got \(event)")
            return
        }
        let dict = raw.legacyDictionary()
        #expect(dict["request_id"] as? String == "req-5")
        let request = try #require(dict["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "can_use_tool")
    }

    @Test
    func decodeLineYieldsUnknownForUnrecognizedType() throws {
        let line = #"{"type":"some_future_event","payload":{"x":1}}"#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .unknown(type, raw) = event else {
            Issue.record("expected unknown, got \(event)")
            return
        }
        #expect(type == "some_future_event")
        let dict = raw.legacyDictionary()
        let payload = try #require(dict["payload"] as? [String: Any])
        #expect(payload["x"] as? Int == 1)
    }

    /// Regression guard: each known wire-level `type` value must map to a
    /// non-`.unknown` case. If someone reorders or removes a switch arm in
    /// `Event.init(from:)`, this catches it before it ships.
    @Test
    func decodeLinePinsKnownTypesToTypedCases() throws {
        let knownTypes = [
            "system", "assistant", "user", "stream_event",
            "control_request", "control_response", "result",
        ]
        for type in knownTypes {
            let line = #"{"type":"\#(type)"}"#
            let event = try #require(try ClaudeProtocol.decodeLine(line), "decoding \(type)")
            if case .unknown = event {
                Issue.record("\(type) decoded as .unknown — discriminator dispatch broken")
            }
            #expect(event.typeName == type)
        }
    }

    // MARK: - Helpers

    private func requireJSON(_ value: Encodable) throws -> [String: Any] {
        let data = try #require(ClaudeProtocol.encode(value))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
