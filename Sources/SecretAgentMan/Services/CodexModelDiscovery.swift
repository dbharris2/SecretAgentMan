import Foundation

/// Performs a short-lived Codex app-server handshake so model discovery also
/// works before any Codex agent session has been launched.
final class CodexModelDiscovery: @unchecked Sendable {
    private let completion: @Sendable ([CodexAvailableModel]) -> Void
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stdinPipe = Pipe()
    private let queue = DispatchQueue(label: "CodexModelDiscovery")

    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var modelListRequestID: Int?
    private var accumulatedModels: [CodexAvailableModel] = []
    private var pagesRemaining = 10
    private var timeoutWorkItem: DispatchWorkItem?
    private var didFinish = false

    init(completion: @escaping @Sendable ([CodexAvailableModel]) -> Void) {
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            startProcess()
        }
    }

    func stop() {
        queue.async { [self] in
            finish(with: [])
        }
    }

    private func startProcess() {
        guard !didFinish else { return }

        process.executableURL = URL(fileURLWithPath: ProviderExecutableLocator.executablePath(for: .codex))
        process.arguments = ["app-server", "--enable", "default_mode_request_user_input"]
        process.environment = ProcessEnvironment.interactive()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in
                self?.consumeStdout(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.finish(with: [])
            }
        }

        do {
            try process.run()
        } catch {
            finish(with: [])
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(with: [])
        }
        timeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)

        initializeRequestID = sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "secret-agent-man",
                    "title": "SecretAgentMan",
                    "version": "0.1.0",
                ],
                "capabilities": [
                    "experimentalApi": true,
                ],
            ]
        )
        if initializeRequestID == nil {
            finish(with: [])
        }
    }

    private func sendRequest(method: String, params: [String: Any]) -> Int? {
        guard process.isRunning else { return nil }

        let requestID = nextRequestID
        nextRequestID += 1
        let payload: [String: Any] = [
            "id": requestID,
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { return nil }

        line.append("\n")
        stdinPipe.fileHandleForWriting.write(Data(line.utf8))
        return requestID
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let requestID = object["id"] as? Int
            else { continue }

            handleResponse(object, requestID: requestID)
        }
    }

    private func handleResponse(_ response: [String: Any], requestID: Int) {
        if requestID == initializeRequestID {
            initializeRequestID = nil
            requestModelPage(cursor: nil)
            return
        }

        guard requestID == modelListRequestID else { return }
        modelListRequestID = nil
        accumulatedModels = CodexModelSettings.deduplicated(
            accumulatedModels + CodexModelSettings.models(from: response)
        )

        if let nextCursor = CodexModelSettings.nextCursor(from: response),
           pagesRemaining > 1 {
            pagesRemaining -= 1
            requestModelPage(cursor: nextCursor)
        } else {
            finish(with: accumulatedModels)
        }
    }

    private func requestModelPage(cursor: String?) {
        var params: [String: Any] = [
            "includeHidden": false,
            "limit": 100,
        ]
        if let cursor {
            params["cursor"] = cursor
        }

        modelListRequestID = sendRequest(method: "model/list", params: params)
        if modelListRequestID == nil {
            finish(with: [])
        }
    }

    private func finish(with models: [CodexAvailableModel]) {
        guard !didFinish else { return }
        didFinish = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
        }
        completion(models)
    }
}
