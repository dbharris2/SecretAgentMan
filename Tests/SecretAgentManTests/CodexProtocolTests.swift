import Foundation
@testable import SecretAgentMan
import Testing

struct CodexProtocolTests {
    // MARK: - RPCResponse

    @Test
    func approvalAcceptHasCorrectDecision() throws {
        let resp = CodexProtocol.RPCResponse.approvalDecision(id: 42, accept: true)
        let json = try requireJSON(resp)

        #expect(json["id"] as? Int == 42)
        let result = try #require(json["result"] as? [String: Any])
        #expect(result["decision"] as? String == "accept")
    }

    @Test
    func approvalDeclineHasCorrectDecision() throws {
        let resp = CodexProtocol.RPCResponse.approvalDecision(id: 7, accept: false)
        let json = try requireJSON(resp)

        let result = try #require(json["result"] as? [String: Any])
        #expect(result["decision"] as? String == "decline")
    }

    @Test
    func userInputAnswersEncodesNestedStructure() throws {
        let resp = CodexProtocol.RPCResponse.userInputAnswers(
            id: 10,
            answers: ["q1": ["answers": ["Alpha"]]]
        )
        let json = try requireJSON(resp)

        #expect(json["id"] as? Int == 10)
        let result = try #require(json["result"] as? [String: Any])
        let answers = try #require(result["answers"] as? [String: Any])
        let q1 = try #require(answers["q1"] as? [String: Any])
        let selected = try #require(q1["answers"] as? [String])
        #expect(selected == ["Alpha"])
    }

    // MARK: - RPCRequest

    @Test
    func initializeRequestHasClientInfo() throws {
        let req = CodexProtocol.RPCRequest.initialize(id: 1)
        let json = try requireJSON(req)

        #expect(json["id"] as? Int == 1)
        #expect(json["method"] as? String == "initialize")
        let params = try #require(json["params"] as? [String: Any])
        let clientInfo = try #require(params["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "secret-agent-man")
    }

    @Test
    func threadStartHasRequiredParams() throws {
        let req = CodexProtocol.RPCRequest.threadStart(id: 2, cwd: "/tmp")
        let json = try requireJSON(req)

        #expect(json["method"] as? String == "thread/start")
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["cwd"] as? String == "/tmp")
        #expect(params["approvalPolicy"] as? String == "on-request")
        #expect(params["sandbox"] as? String == "workspace-write")
    }

    @Test
    func threadStartSupportsCustomApprovalPolicy() throws {
        let req = CodexProtocol.RPCRequest.threadStart(id: 3, cwd: "/tmp", approvalPolicy: "never")
        let json = try requireJSON(req)

        let params = try #require(json["params"] as? [String: Any])
        #expect(params["approvalPolicy"] as? String == "never")
    }

    @Test
    func turnStartWithImagesHasLocalImageEntries() throws {
        let req = CodexProtocol.RPCRequest.turnStart(
            id: 5,
            threadId: "thr-1",
            text: "describe this",
            imagePaths: ["/tmp/img.png"]
        )
        let json = try requireJSON(req)

        let params = try #require(json["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])
        #expect(input.count == 2)
        #expect(input[0]["type"] as? String == "localImage")
        #expect(input[0]["path"] as? String == "/tmp/img.png")
        #expect(input[1]["type"] as? String == "text")
        #expect(input[1]["text"] as? String == "describe this")
    }

    @Test
    func turnStartWithoutImagesHasTextOnly() throws {
        let req = CodexProtocol.RPCRequest.turnStart(id: 6, threadId: "thr-2", text: "hello")
        let json = try requireJSON(req)

        let params = try #require(json["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "text")
    }

    // MARK: - AnyCodableValue

    @Test
    func anyCodableValueEncodesAllTypes() throws {
        let value: [String: AnyCodableValue] = [
            "str": .string("hello"),
            "num": .int(42),
            "dbl": .double(3.14),
            "flag": .bool(true),
            "arr": .array([.string("a"), .int(1)]),
            "nested": .dict(["key": .string("val")]),
        ]
        let data = try #require(try? JSONEncoder().encode(value))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["str"] as? String == "hello")
        #expect(json["num"] as? Int == 42)
        #expect(json["flag"] as? Bool == true)
    }

    // MARK: - Event parsing

    @Test
    func parsesAgentMessageDeltaEvent() {
        let event = CodexProtocol.Event.parse([
            "method": "item/agentMessage/delta",
            "params": [
                "threadId": "t1",
                "itemId": "item-42",
                "delta": "hello ",
            ],
        ])
        guard case let .agentMessageDelta(itemId, delta) = event else {
            Issue.record("expected agentMessageDelta, got \(String(describing: event))")
            return
        }
        #expect(itemId == "item-42")
        #expect(delta == "hello ")
    }

    @Test
    func parsesCommandOutputDeltaEvent() {
        let event = CodexProtocol.Event.parse([
            "method": "item/commandExecution/outputDelta",
            "params": ["itemId": "cmd-1", "delta": "line\n"],
        ])
        guard case let .outputDelta(kind, itemId, delta) = event else {
            Issue.record("expected outputDelta, got \(String(describing: event))")
            return
        }
        #expect(kind == .commandExecution)
        #expect(itemId == "cmd-1")
        #expect(delta == "line\n")
    }

    @Test
    func parsesFileChangeOutputDeltaEvent() {
        let event = CodexProtocol.Event.parse([
            "method": "item/fileChange/outputDelta",
            "params": ["itemId": "fc-1", "delta": "@@ -1 +1 @@"],
        ])
        guard case let .outputDelta(kind, _, _) = event else {
            Issue.record("expected outputDelta")
            return
        }
        #expect(kind == .fileChange)
    }

    @Test
    func parsesResponseEventWhenNoMethod() {
        let event = CodexProtocol.Event.parse([
            "id": 7,
            "result": ["hello": "world"],
        ])
        guard case let .response(id, _) = event else {
            Issue.record("expected response")
            return
        }
        #expect(id == 7)
    }

    @Test
    func parsesThreadStatusChangedEvent() {
        let event = CodexProtocol.Event.parse([
            "method": "thread/status/changed",
            "params": ["status": ["type": "idle"]],
        ])
        guard case let .threadStatusChanged(status) = event else {
            Issue.record("expected threadStatusChanged")
            return
        }
        #expect(status["type"] as? String == "idle")
    }

    @Test
    func parsesTurnStartedEvent() {
        let event = CodexProtocol.Event.parse([
            "method": "turn/started",
            "params": [
                "threadId": "thread-1",
                "turn": ["id": "turn-1"],
            ],
        ])
        guard case let .turnStarted(turnId) = event else {
            Issue.record("expected turnStarted")
            return
        }
        #expect(turnId == "turn-1")
    }

    @Test
    func parsesTurnCompletedEvent() {
        let event = CodexProtocol.Event.parse([
            "method": "turn/completed",
            "params": [
                "threadId": "thread-1",
                "turn": ["id": "turn-1"],
            ],
        ])
        guard case let .turnCompleted(turnId) = event else {
            Issue.record("expected turnCompleted")
            return
        }
        #expect(turnId == "turn-1")
    }

    @Test
    func parsesItemStartedEvent() {
        let event = CodexProtocol.Event.parse([
            "method": "item/started",
            "params": ["item": ["id": "i", "type": "commandExecution"]],
        ])
        guard case let .itemStarted(item) = event else {
            Issue.record("expected itemStarted")
            return
        }
        #expect(item["id"] as? String == "i")
    }

    @Test
    func parsesErrorEvent() {
        let event = CodexProtocol.Event.parse([
            "method": "error",
            "params": ["error": ["message": "boom"]],
        ])
        guard case let .error(message) = event else {
            Issue.record("expected error")
            return
        }
        #expect(message == "boom")
    }

    @Test
    func returnsUnknownForUnhandledMethod() {
        let event = CodexProtocol.Event.parse([
            "method": "some/novel/method",
            "params": [:],
        ])
        guard case let .unknown(method) = event else {
            Issue.record("expected unknown")
            return
        }
        #expect(method == "some/novel/method")
    }

    // MARK: - Helpers

    private func requireJSON(_ value: Encodable) throws -> [String: Any] {
        let data = try #require(CodexProtocol.encode(value))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
