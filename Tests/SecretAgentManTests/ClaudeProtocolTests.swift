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
            updatedInput: .object(["command": .string("ls -la")])
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
            updatedInput: .object([
                "questions": .array([
                    .object(["question": .string("What color?"), "header": .string("Color")]),
                ]),
                "answers": .object(["What color?": .string("Blue")]),
            ])
        )
        let json = try requireJSON(resp)

        let response = try #require(json["response"] as? [String: Any])
        let inner = try #require(response["response"] as? [String: Any])
        let input = try #require(inner["updatedInput"] as? [String: Any])
        let answers = try #require(input["answers"] as? [String: Any])
        #expect(answers["What color?"] as? String == "Blue")
        let questions = try #require(input["questions"] as? [[String: Any]])
        #expect(questions.first?["header"] as? String == "Color")
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
        // Minimal but Decodable bodies for each known type. control_request
        // requires its full typed payload to decode cleanly.
        let knownTypes: [(type: String, body: String)] = [
            ("system", ""),
            ("assistant", ""),
            ("user", ""),
            ("stream_event", #","event":{"type":"message_stop"}"#),
            ("control_request", #","request_id":"r","request":{"subtype":"elicitation","message":"x"}"#),
            ("control_response", ""),
            ("result", ""),
        ]
        for (type, body) in knownTypes {
            let line = #"{"type":"\#(type)"\#(body)}"#
            let event = try #require(try ClaudeProtocol.decodeLine(line), "decoding \(type)")
            if case .unknown = event {
                Issue.record("\(type) decoded as .unknown — discriminator dispatch broken")
            }
            #expect(event.typeName == type)
        }
    }

    // MARK: - Control Requests

    @Test
    func decodeLineParsesCanUseToolControlRequest() throws {
        let line = #"""
        {"type":"control_request","request_id":"req-9","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"ls"}}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .controlRequest(controlEvent) = event else {
            Issue.record("expected controlRequest, got \(event)")
            return
        }
        #expect(controlEvent.requestId == "req-9")
        guard case let .canUseTool(permission) = controlEvent.request else {
            Issue.record("expected canUseTool, got \(controlEvent.request)")
            return
        }
        #expect(permission.toolName == "Bash")
        #expect(permission.displayName == "Bash")
        guard case let .object(input) = permission.input else {
            Issue.record("expected .object input, got \(permission.input)")
            return
        }
        #expect(input["command"] == .string("ls"))
    }

    @Test
    func askUserQuestionInputDecodesQuestionsAndOptions() throws {
        let permission = ClaudeProtocol.PermissionRequest(
            toolName: "AskUserQuestion",
            displayName: nil,
            input: .object([
                "questions": .array([
                    .object([
                        "question": .string("Pick a color"),
                        "header": .string("Color"),
                        "options": .array([
                            .object(["label": .string("Red"), "description": .string("warm")]),
                            .object(["label": .string("Blue"), "description": .string("cool")]),
                        ]),
                    ]),
                ]),
            ])
        )
        let parsed = try permission.input.decode(as: ClaudeProtocol.AskUserQuestionInput.self)
        #expect(parsed.questions.count == 1)
        let q = try #require(parsed.questions.first)
        #expect(q.question == "Pick a color")
        #expect(q.header == "Color")
        let options = try #require(q.options)
        #expect(options.map(\.label) == ["Red", "Blue"])
        #expect(options.map(\.description) == ["warm", "cool"])
    }

    @Test
    func decodeLineParsesElicitationControlRequest() throws {
        let line = #"""
        {"type":"control_request","request_id":"req-10","request":{"subtype":"elicitation","message":"Please clarify"}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .controlRequest(controlEvent) = event,
              case let .elicitation(elic) = controlEvent.request
        else {
            Issue.record("expected elicitation, got \(event)")
            return
        }
        #expect(elic.message == "Please clarify")
    }

    @Test
    func unknownControlSubtypePreservesRawPayload() throws {
        let line = #"""
        {"type":"control_request","request_id":"req-11","request":{"subtype":"future_subtype","payload":{"x":1}}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .controlRequest(controlEvent) = event,
              case let .unknown(subtype, raw) = controlEvent.request
        else {
            Issue.record("expected unknown subtype, got \(event)")
            return
        }
        #expect(subtype == "future_subtype")
        #expect(controlEvent.request.subtypeName == "future_subtype")
        guard case let .object(rawObj) = raw else {
            Issue.record("expected .object raw, got \(raw)")
            return
        }
        #expect(rawObj["subtype"] == .string("future_subtype"))
    }

    @Test
    func malformedControlRequestThrows() {
        // Missing request_id — typed payload decode fails. The throw bubbles up
        // via decodeLine so the monitor can log/skip with full context.
        let line = #"""
        {"type":"control_request","request":{"subtype":"can_use_tool","tool_name":"Bash"}}
        """#
        #expect(throws: (any Error).self) {
            try ClaudeProtocol.decodeLine(line)
        }
    }

    @Test
    func permissionResponseEchoesJsonValueInputUnchanged() throws {
        // Round-trip a JSONValue tool input through `allow(...)` and check the
        // emitted JSON preserves shape and primitive types verbatim.
        let original = JSONValue.object([
            "command": .string("ls -la /tmp"),
            "timeout": .int(30),
            "flags": .array([.string("-x"), .bool(true)]),
        ])
        let resp = ClaudeProtocol.PermissionResponse.allow(requestId: "req-1", updatedInput: original)
        let json = try requireJSON(resp)
        let inner = try #require((json["response"] as? [String: Any])?["response"] as? [String: Any])
        let input = try #require(inner["updatedInput"] as? [String: Any])
        #expect(input["command"] as? String == "ls -la /tmp")
        #expect(input["timeout"] as? Int == 30)
        let flags = try #require(input["flags"] as? [Any])
        #expect(flags.count == 2)
        #expect(flags[0] as? String == "-x")
        #expect(flags[1] as? Bool == true)
    }

    // MARK: - Stream Events

    @Test
    func decodeLineParsesContentBlockStartToolUse() throws {
        let line = #"""
        {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_a","name":"Bash","input":{}}}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .streamEvent(.contentBlockStart(start)) = event else {
            Issue.record("expected streamEvent(.contentBlockStart), got \(event)")
            return
        }
        guard case let .toolUse(name) = start.contentBlock else {
            Issue.record("expected .toolUse, got \(start.contentBlock)")
            return
        }
        #expect(name == "Bash")
    }

    @Test
    func decodeLineParsesContentBlockStartText() throws {
        let line = #"""
        {"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .streamEvent(.contentBlockStart(start)) = event else {
            Issue.record("expected streamEvent(.contentBlockStart), got \(event)")
            return
        }
        #expect(start.contentBlock == .text)
    }

    @Test
    func decodeLineParsesTextDelta() throws {
        let line = #"""
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .streamEvent(.textDelta(text)) = event else {
            Issue.record("expected streamEvent(.textDelta), got \(event)")
            return
        }
        #expect(text == "Hello")
    }

    @Test
    func decodeLineParsesMessageStop() throws {
        let line = #"{"type":"stream_event","event":{"type":"message_stop"}}"#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case .streamEvent(.messageStop) = event else {
            Issue.record("expected streamEvent(.messageStop), got \(event)")
            return
        }
    }

    @Test
    func nonTextContentBlockDeltaPreservesRawAsUnknown() throws {
        // input_json_delta is real Claude wire content — make sure forward-compat
        // delta types don't get silently coerced into .textDelta.
        let line = #"""
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"x\":1}"}}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .streamEvent(.unknown(type, raw)) = event else {
            Issue.record("expected streamEvent(.unknown), got \(event)")
            return
        }
        #expect(type == "content_block_delta")
        guard case let .object(rawObj) = raw else {
            Issue.record("expected .object raw, got \(raw)")
            return
        }
        // Raw payload preserves the inner delta verbatim for diagnostics.
        guard case let .object(deltaObj) = rawObj["delta"] ?? .null else {
            Issue.record("expected raw.delta to be .object")
            return
        }
        #expect(deltaObj["type"] == .string("input_json_delta"))
    }

    @Test
    func unknownStreamEventTypeIsForwardCompatible() throws {
        let line = #"{"type":"stream_event","event":{"type":"future_event","payload":42}}"#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .streamEvent(.unknown(type, _)) = event else {
            Issue.record("expected streamEvent(.unknown), got \(event)")
            return
        }
        #expect(type == "future_event")
    }

    // MARK: - Helpers

    private func requireJSON(_ value: Encodable) throws -> [String: Any] {
        let data = try #require(ClaudeProtocol.encode(value))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
