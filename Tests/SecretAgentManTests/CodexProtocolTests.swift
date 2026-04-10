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
        #expect(params["approvalPolicy"] as? String == "untrusted")
        #expect(params["sandbox"] as? String == "workspace-write")
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

    // MARK: - Helpers

    private func requireJSON(_ value: Encodable) throws -> [String: Any] {
        let data = try #require(CodexProtocol.encode(value))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
