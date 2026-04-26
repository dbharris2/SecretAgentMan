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
        guard case let .system(system) = event else {
            Issue.record("expected system, got \(event)")
            return
        }
        #expect(system.sessionId == "sess-1")
        #expect(system.model == "claude-opus-4-6[1m]")
        #expect(system.permissionMode == "default")
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
        #expect(raw["payload"]?["x"]?.intValue == 1)
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

    // MARK: - Message Content

    @Test
    func decodeLineParsesAssistantTextAndToolUse() throws {
        let line = #"""
        {"type":"assistant","uuid":"a-1","message":{"role":"assistant","content":[{"type":"text","text":"Hi"},{"type":"tool_use","id":"toolu_x","name":"Bash","input":{"command":"ls"}}]}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .assistant(message) = event else {
            Issue.record("expected assistant, got \(event)")
            return
        }
        #expect(message.uuid == "a-1")
        guard case let .blocks(blocks) = message.message?.content else {
            Issue.record("expected blocks, got \(String(describing: message.message?.content))")
            return
        }
        #expect(blocks.count == 2)
        guard case let .text(text) = blocks[0] else {
            Issue.record("expected text, got \(blocks[0])")
            return
        }
        #expect(text == "Hi")
        guard case let .toolUse(use) = blocks[1] else {
            Issue.record("expected toolUse, got \(blocks[1])")
            return
        }
        #expect(use.name == "Bash")
        #expect(use.input?["command"]?.stringValue == "ls")
    }

    @Test
    func userMessageAcceptsStringContent() throws {
        let line = #"""
        {"type":"user","uuid":"u-1","userType":"external","message":{"role":"user","content":"hello"}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .user(message) = event else {
            Issue.record("expected user, got \(event)")
            return
        }
        #expect(message.userType == "external")
        guard case let .text(text) = message.message?.content else {
            Issue.record("expected .text content")
            return
        }
        #expect(text == "hello")
    }

    @Test
    func toolResultAssemblesContentFromArrayOfTextBlocks() throws {
        // Wire variant: tool_result.content can be `[{type:"text", text:"..."}]`.
        let line = #"""
        {"type":"user","uuid":"u-2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"line one\n"},{"type":"text","text":"line two"}]}]}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .user(message) = event,
              case let .blocks(blocks) = message.message?.content,
              case let .toolResult(result) = blocks.first
        else {
            Issue.record("expected tool_result, got \(event)")
            return
        }
        #expect(result.isError == true)
        #expect(result.text == "line one\nline two")
    }

    @Test
    func toolResultFallsBackToTextField() throws {
        // Some wire variants put the failure message in a sibling `text` field
        // rather than `content`. The typed model should still surface it.
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"text":"boom"}]}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .user(message) = event,
              case let .blocks(blocks) = message.message?.content,
              case let .toolResult(result) = blocks.first
        else {
            Issue.record("expected tool_result, got \(event)")
            return
        }
        #expect(result.text == "boom")
    }

    @Test
    func unknownContentBlockTypePreservesRaw() throws {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"future_block","payload":{"x":1}}]}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .assistant(message) = event,
              case let .blocks(blocks) = message.message?.content,
              case let .unknown(type, raw) = blocks.first
        else {
            Issue.record("expected unknown content block, got \(event)")
            return
        }
        #expect(type == "future_block")
        #expect(raw["payload"]?["x"]?.intValue == 1)
    }

    // MARK: - Control Response (slash commands)

    @Test
    func decodeLineParsesSlashCommandsFromControlResponse() throws {
        let line = #"""
        {"type":"control_response","response":{"subtype":"success","request_id":"r1",
         "response":{"commands":[
           {"name":"clear","description":"Clear conversation","argumentHint":""},
           {"name":"agents","description":"Manage subagents","argumentHint":"<name>"}
         ]}}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .controlResponse(response) = event else {
            Issue.record("expected controlResponse, got \(event)")
            return
        }
        let commands = try #require(response.commands)
        #expect(commands.count == 2)
        #expect(commands[0].name == "clear")
        #expect(commands[0].description == "Clear conversation")
        #expect(commands[0].argumentHint == "")
        #expect(commands[1].name == "agents")
        #expect(commands[1].argumentHint == "<name>")
    }

    @Test
    func controlResponseWithoutCommandsLeavesNil() throws {
        // Permission-mode acks share the control_response wire shape but
        // don't carry a `commands` array. Make sure that's nil rather than
        // throwing or yielding an empty list.
        let line = #"""
        {"type":"control_response","response":{"subtype":"success","request_id":"r2","response":{}}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .controlResponse(response) = event else {
            Issue.record("expected controlResponse, got \(event)")
            return
        }
        #expect(response.commands == nil)
    }

    // MARK: - Result Event

    @Test
    func decodeLineParsesResultErrorAndSessionId() throws {
        let line = #"""
        {"type":"result","is_error":true,"session_id":"sess-9"}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .result(result) = event else {
            Issue.record("expected result, got \(event)")
            return
        }
        #expect(result.isError == true)
        #expect(result.sessionId == "sess-9")
        // No usage data → no context percent.
        #expect(result.contextPercent == nil)
    }

    @Test
    func resultContextPercentSumsLastIterationOverContextWindow() throws {
        // 1000 + 2000 + 500 + 500 = 4000 / 8000 = 50%
        let line = #"""
        {"type":"result","is_error":false,
         "modelUsage":{"claude-opus-4-7":{"contextWindow":8000}},
         "usage":{"iterations":[
           {"input_tokens":100,"output_tokens":100},
           {"input_tokens":1000,"cache_read_input_tokens":2000,
            "cache_creation_input_tokens":500,"output_tokens":500}
         ]}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .result(result) = event else {
            Issue.record("expected result, got \(event)")
            return
        }
        #expect(result.contextPercent == 50)
    }

    @Test
    func resultContextPercentNilWhenContextWindowMissing() throws {
        // Without a contextWindow we can't compute a percent — must be nil
        // rather than dividing by zero or returning a junk value.
        let line = #"""
        {"type":"result","modelUsage":{"claude-opus-4-7":{}},"usage":{"iterations":[{"input_tokens":100}]}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .result(result) = event else {
            Issue.record("expected result, got \(event)")
            return
        }
        #expect(result.contextPercent == nil)
    }

    @Test
    func resultContextPercentTreatsMissingTokenFieldsAsZero() throws {
        // Cache fields can be absent on cold iterations — they should default
        // to 0 rather than making contextPercent nil.
        let line = #"""
        {"type":"result","modelUsage":{"m":{"contextWindow":1000}},"usage":{"iterations":[{"input_tokens":250}]}}
        """#
        let event = try #require(try ClaudeProtocol.decodeLine(line))
        guard case let .result(result) = event else {
            Issue.record("expected result, got \(event)")
            return
        }
        #expect(result.contextPercent == 25)
    }

    // MARK: - Helpers

    private func requireJSON(_ value: Encodable) throws -> [String: Any] {
        let data = try #require(ClaudeProtocol.encode(value))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
