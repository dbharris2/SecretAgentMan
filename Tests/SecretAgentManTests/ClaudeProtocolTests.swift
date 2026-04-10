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

    // MARK: - Event Parsing

    @Test
    func parsesSystemEvent() {
        let event = ClaudeProtocol.Event.parse([
            "type": "system",
            "session_id": "sess-1",
            "model": "claude-opus-4-6[1m]",
            "permissionMode": "default",
        ])

        guard case let .system(sessionId, model, mode) = event else {
            Issue.record("Expected system event")
            return
        }
        #expect(sessionId == "sess-1")
        #expect(model == "claude-opus-4-6[1m]")
        #expect(mode == "default")
    }

    @Test
    func parsesResultEvent() {
        let event = ClaudeProtocol.Event.parse([
            "type": "result",
            "is_error": true,
            "session_id": "sess-2",
        ])

        guard case let .result(isError, _, sessionId) = event else {
            Issue.record("Expected result event")
            return
        }
        #expect(isError == true)
        #expect(sessionId == "sess-2")
    }

    @Test
    func parsesControlRequestEvent() {
        let event = ClaudeProtocol.Event.parse([
            "type": "control_request",
            "request_id": "req-5",
            "request": ["subtype": "can_use_tool", "tool_name": "Bash"],
        ])

        guard case let .controlRequest(requestId, request) = event else {
            Issue.record("Expected control_request event")
            return
        }
        #expect(requestId == "req-5")
        #expect(request["subtype"] as? String == "can_use_tool")
    }

    @Test
    func returnsNilForMissingType() {
        let event = ClaudeProtocol.Event.parse(["no_type": true])
        #expect(event == nil)
    }

    // MARK: - Helpers

    private func requireJSON(_ value: Encodable) throws -> [String: Any] {
        let data = try #require(ClaudeProtocol.encode(value))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
