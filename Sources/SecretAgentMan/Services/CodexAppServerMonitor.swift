// swiftlint:disable file_length
import Foundation
import Observation

@MainActor @Observable
final class CodexAppServerMonitor {
    @ObservationIgnored var onStateChange: ((UUID, AgentState) -> Void)?
    @ObservationIgnored var onSessionReady: ((UUID, String) -> Void)?
    @ObservationIgnored var onSessionEvent: ((UUID, SessionEvent) -> Void)?

    // Load-bearing: the monitor needs the original request to resolve
    // prompts via observer callbacks using provider-specific fields
    // (`itemId`, etc.). `AgentSessionCoordinator.handleAgentStateChange`
    // also reads these to suppress terminal-state races until the
    // coordinator migrates to snapshot-driven suppression.
    private(set) var pendingUserInputRequests: [UUID: CodexUserInputRequest] = [:]
    private(set) var pendingApprovalRequests: [UUID: CodexApprovalRequest] = [:]
    private(set) var runtimeStates: [UUID: AgentState] = [:]
    /// Debug-only channel retained per plan (provider-specific raw event
    /// details may exist internally for debugging).
    private(set) var debugMessages: [UUID: String] = [:]

    @ObservationIgnored private var observers: [UUID: Observer] = [:]

    /// Normalized event emission state (Phase 1 dual-emit migration).
    /// Visibility relaxed from `private` so the +SessionEvents extension in a
    /// separate file can access them.
    @ObservationIgnored var streamingItemIds: [UUID: Set<String>] = [:]

    struct PendingLocalUserMessage {
        let id: String
        let text: String
        let images: [Data]
    }

    @ObservationIgnored var pendingLocalUserMessages: [UUID: [PendingLocalUserMessage]] = [:]

    func syncMonitoredAgents(_ agents: [Agent]) {
        let desired = Dictionary(
            uniqueKeysWithValues: agents.compactMap { agent -> (UUID, Agent)? in
                guard agent.provider == .codex,
                      agent.hasLaunched
                else { return nil }
                return (agent.id, agent)
            }
        )

        for agentId in observers.keys where desired[agentId] == nil {
            observers.removeValue(forKey: agentId)?.stop()
        }

        for (_, agent) in desired {
            ensureSession(for: agent)
        }
    }

    func ensureSession(for agent: Agent) {
        guard agent.provider == .codex else { return }

        if let observer = observers[agent.id] {
            observer.update(agent: agent)
            observer.start()
            return
        }

        let observer = makeObserver(for: agent)
        observers[agent.id] = observer
        observer.start()
    }

    private func makeObserver(for agent: Agent) -> Observer {
        Observer(agent: agent) { [weak self] id, state in
            Task { @MainActor in
                guard let self else { return }
                self.runtimeStates[id] = state
                self.onStateChange?(id, state)
                self.emit(.runStateChanged(Self.mapRunState(state)), for: id)
            }
        } onSessionReady: { [weak self] id, threadId in
            Task { @MainActor in
                guard let self else { return }
                self.onSessionReady?(id, threadId)
                self.emit(.sessionReady(sessionId: threadId), for: id)
            }
        } onTranscriptItem: { [weak self] id, item in
            Task { @MainActor in self?.handleTranscriptItem(id, item: item) }
        } onStreamingText: { _, _ in
            // No-op: the normalized path tracks streaming via onStreamDelta.
        } onStreamDelta: { [weak self] id, itemId, delta in
            Task { @MainActor in self?.emitStreamDelta(id: id, itemId: itemId, delta: delta) }
        } onStreamFinalize: { [weak self] id, itemId in
            Task { @MainActor in self?.emitStreamFinalize(id: id, itemId: itemId) }
        } onUserInputRequest: { [weak self] id, request in
            Task { @MainActor in
                guard let self else { return }
                self.debugMessages.removeValue(forKey: id)
                self.pendingUserInputRequests[id] = request
                self.emit(.promptPresented(.userInput(Self.mapUserInputPrompt(request))), for: id)
            }
        } onApprovalRequest: { [weak self] id, request in
            Task { @MainActor in
                guard let self else { return }
                self.pendingApprovalRequests[id] = request
                self.emit(.promptPresented(.approval(Self.mapApprovalPrompt(request))), for: id)
            }
        } onDebugMessage: { [weak self] id, message in
            Task { @MainActor in
                self?.debugMessages[id] = message
            }
        } onUserInputResolved: { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                if let pending = self.pendingUserInputRequests[id] {
                    self.emit(.promptResolved(id: pending.itemId), for: id)
                }
                self.pendingUserInputRequests.removeValue(forKey: id)
            }
        } onApprovalResolved: { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                if let pending = self.pendingApprovalRequests[id] {
                    self.emit(.promptResolved(id: pending.itemId), for: id)
                }
                self.pendingApprovalRequests.removeValue(forKey: id)
            }
        } onModelInfo: { [weak self] id, rawModel, displayModel, mode, contextPct in
            Task { @MainActor in
                self?.applyModelInfo(id: id, rawModel: rawModel, displayModel: displayModel, mode: mode, contextPct: contextPct)
            }
        }
    }

    func handleTranscriptItem(_ agentId: UUID, item: CodexTranscriptItem) {
        // Reconcile with an in-flight local user message: the monitor records
        // user messages under a `local-user-*` id; when the server echoes
        // the message back, we swap to the server's id but preserve the
        // client-side image data the server never round-trips.
        if item.role == .user,
           var pending = pendingLocalUserMessages[agentId],
           let pendingIdx = pending.lastIndex(where: { $0.text == item.text }) {
            let local = pending[pendingIdx]
            pending.remove(at: pendingIdx)
            pendingLocalUserMessages[agentId] = pending.isEmpty ? nil : pending

            let merged = CodexTranscriptItem(
                id: item.id,
                role: item.role,
                text: item.text,
                images: item.images.isEmpty ? local.images : item.images
            )
            emitTranscriptUpsert(agentId, item: merged, canonicalId: local.id)
            return
        }
        emitTranscriptUpsert(agentId, item: item, canonicalId: item.id)
    }

    private func applyModelInfo(id: UUID, rawModel: String, displayModel: String, mode: CodexCollaborationMode, contextPct: Double) {
        var update = SessionMetadataUpdate()
        if !rawModel.isEmpty { update.rawModelName = .set(rawModel) }
        if !displayModel.isEmpty { update.displayModelName = .set(displayModel) }
        update.collaborationMode = .set(mode.rawValue)
        update.contextPercentUsed = .set(contextPct)
        emit(.metadataUpdated(update), for: id)
    }

    func stopAll() {
        for observer in observers.values {
            observer.stop()
        }
        observers.removeAll()
    }

    func removeObserver(for agentId: UUID) {
        observers.removeValue(forKey: agentId)?.stop()
        pendingUserInputRequests.removeValue(forKey: agentId)
        pendingApprovalRequests.removeValue(forKey: agentId)
        runtimeStates.removeValue(forKey: agentId)
        debugMessages.removeValue(forKey: agentId)
        streamingItemIds.removeValue(forKey: agentId)
        pendingLocalUserMessages.removeValue(forKey: agentId)
    }

    func sendMessage(for agentId: UUID, text: String, imagePaths: [String] = []) {
        observers[agentId]?.sendMessage(text, imagePaths: imagePaths)
    }

    func recordSentUserMessage(for agentId: UUID, text: String, imageData: [Data]) {
        guard !text.isEmpty || !imageData.isEmpty else { return }
        let item = CodexTranscriptItem(
            id: "local-user-\(UUID().uuidString)",
            role: .user,
            text: text,
            images: imageData
        )
        pendingLocalUserMessages[agentId, default: []].append(
            PendingLocalUserMessage(id: item.id, text: text, images: imageData)
        )
        emitTranscriptUpsert(agentId, item: item, canonicalId: item.id)
    }

    func setCollaborationMode(for agentId: UUID, mode: CodexCollaborationMode) {
        observers[agentId]?.setCollaborationMode(mode)
        var update = SessionMetadataUpdate()
        update.collaborationMode = .set(mode.rawValue)
        emit(.metadataUpdated(update), for: agentId)
    }

    func setApprovalPolicy(for agentId: UUID, policy: CodexApprovalPolicy) {
        observers[agentId]?.setApprovalPolicy(policy)
    }

    func respondToApproval(for agentId: UUID, accept: Bool) {
        observers[agentId]?.respondToApproval(accept: accept)
    }

    func debugTriggerUserInput(for agentId: UUID) {
        debugMessages.removeValue(forKey: agentId)
        observers[agentId]?.debugTriggerUserInput()
    }

    func interrupt(for agentId: UUID) {
        observers[agentId]?.interrupt()
    }

    func recordSystemTranscript(for agentId: UUID, text: String) {
        let item = CodexTranscriptItem(
            id: "system-\(UUID().uuidString)",
            role: .system,
            text: text
        )
        emitTranscriptUpsert(agentId, item: item, canonicalId: item.id)
    }

    func respondToUserInput(for agentId: UUID, answers: [String: [String]]) {
        guard let pending = pendingUserInputRequests[agentId] else { return }
        observers[agentId]?.respondToUserInput(answers: answers)
        emit(.promptResolved(id: pending.itemId), for: agentId)
        pendingUserInputRequests.removeValue(forKey: agentId)
    }

    nonisolated static func agentState(fromThreadStatus status: [String: Any]) -> AgentState? {
        guard let type = status["type"] as? String else { return nil }
        switch type {
        case "idle":
            return .idle
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") {
                return .needsPermission
            } else if flags.contains("waitingOnUserInput") {
                return .awaitingResponse
            } else {
                return .active
            }
        case "systemError":
            return .error
        case "notLoaded":
            return nil
        default:
            return nil
        }
    }
}

private final class Observer: @unchecked Sendable {
    private struct PendingRequest {
        let completion: @Sendable ([String: Any]) -> Void
    }

    private struct PendingApprovalServerRequest {
        let requestId: Int
        let request: CodexApprovalRequest
    }

    private struct PendingUserInputServerRequest {
        let requestId: Int
        let request: CodexUserInputRequest
    }

    private(set) var agent: Agent
    private let onStateChange: (UUID, AgentState) -> Void
    private let onSessionReady: (UUID, String) -> Void
    private let onTranscriptItem: (UUID, CodexTranscriptItem) -> Void
    private let onStreamingText: (UUID, String) -> Void
    private let onStreamDelta: (UUID, String, String) -> Void
    private let onStreamFinalize: (UUID, String) -> Void
    private let onUserInputRequest: (UUID, CodexUserInputRequest) -> Void
    private let onApprovalRequest: (UUID, CodexApprovalRequest) -> Void
    private let onDebugMessage: (UUID, String) -> Void
    private let onUserInputResolved: (UUID) -> Void
    private let onApprovalResolved: (UUID) -> Void
    private let onModelInfo: (UUID, String, String, CodexCollaborationMode, Double) -> Void

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let queue: DispatchQueue

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var pollTimer: Timer?
    private var didInitialize = false
    private var lastObservedState: AgentState?
    private var pendingApprovalRequest: PendingApprovalServerRequest?
    private var pendingUserInputRequest: PendingUserInputServerRequest?
    private var pendingMessages: [String] = []
    private var sessionFilePath: String?
    private var rawModelName = "gpt-5.4"
    private var collaborationMode: CodexCollaborationMode = .default
    private var approvalPolicy: CodexApprovalPolicy = .storedValue
    private var inProgressToolItems: [String: CodexTranscriptItem] = [:]
    private var streamingAgentMessages: [String: String] = [:]
    private var activeStreamingItemId: String?
    private var activeTurnId: String?
    private var pendingImageTempPaths: [String] = []

    init(
        agent: Agent,
        onStateChange: @escaping (UUID, AgentState) -> Void,
        onSessionReady: @escaping (UUID, String) -> Void,
        onTranscriptItem: @escaping (UUID, CodexTranscriptItem) -> Void,
        onStreamingText: @escaping (UUID, String) -> Void,
        onStreamDelta: @escaping (UUID, String, String) -> Void,
        onStreamFinalize: @escaping (UUID, String) -> Void,
        onUserInputRequest: @escaping (UUID, CodexUserInputRequest) -> Void,
        onApprovalRequest: @escaping (UUID, CodexApprovalRequest) -> Void,
        onDebugMessage: @escaping (UUID, String) -> Void,
        onUserInputResolved: @escaping (UUID) -> Void,
        onApprovalResolved: @escaping (UUID) -> Void,
        onModelInfo: @escaping (UUID, String, String, CodexCollaborationMode, Double) -> Void
    ) {
        self.agent = agent
        self.onStateChange = onStateChange
        self.onSessionReady = onSessionReady
        self.onTranscriptItem = onTranscriptItem
        self.onStreamingText = onStreamingText
        self.onStreamDelta = onStreamDelta
        self.onStreamFinalize = onStreamFinalize
        self.onUserInputRequest = onUserInputRequest
        self.onApprovalRequest = onApprovalRequest
        self.onDebugMessage = onDebugMessage
        self.onUserInputResolved = onUserInputResolved
        self.onApprovalResolved = onApprovalResolved
        self.onModelInfo = onModelInfo
        queue = DispatchQueue(label: "CodexAppServerMonitor.\(agent.id.uuidString)")
    }

    func start() {
        guard process.isRunning == false else { return }

        process.executableURL = URL(fileURLWithPath: ProviderExecutableLocator.executablePath(for: .codex))
        process.arguments = ["app-server", "--enable", "default_mode_request_user_input"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.handleProcessTermination()
            }
        }

        do {
            try process.run()
        } catch {
            onStateChange(agent.id, .error)
            return
        }

        initialize()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        pendingRequests.removeAll()
        pendingApprovalRequest = nil
        pendingUserInputRequest = nil
        pendingMessages.removeAll()
        didInitialize = false
        activeTurnId = nil
        if process.isRunning {
            process.terminate()
        }
    }

    func interrupt() {
        queue.async { [weak self] in
            guard let self,
                  self.process.isRunning,
                  let threadId = self.agent.sessionId
            else { return }
            let turnId = self.activeTurnId ?? "pending"
            self.sendRequest(
                method: "turn/interrupt",
                params: [
                    "threadId": threadId,
                    "turnId": turnId,
                ]
            ) { _ in }
        }
    }

    func update(agent: Agent) {
        let sessionChanged = agent.sessionId != self.agent.sessionId
        self.agent = agent
        if sessionChanged {
            lastObservedState = nil
            if didInitialize {
                pollNow()
            }
        }
    }

    private func initialize() {
        sendRequest(
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
        ) { [weak self] _ in
            guard let self else { return }
            self.startOrResumeThread()
        }
    }

    private func startOrResumeThread() {
        approvalPolicy = .storedValue

        if agent.hasLaunched, let threadId = agent.sessionId, !threadId.isEmpty {
            sendRequest(
                method: "thread/resume",
                params: [
                    "threadId": threadId,
                    "cwd": agent.folder.path,
                    "approvalPolicy": approvalPolicy.rawValue,
                    "sandbox": "workspace-write",
                ]
            ) { [weak self] response in
                self?.finishThreadBootstrap(response: response)
            }
            return
        }

        sendRequest(
            method: "thread/start",
            params: [
                "cwd": agent.folder.path,
                "approvalPolicy": approvalPolicy.rawValue,
                "sandbox": "workspace-write",
                "personality": "pragmatic",
            ]
        ) { [weak self] response in
            self?.finishThreadBootstrap(response: response)
        }
    }

    private func finishThreadBootstrap(response: [String: Any]) {
        didInitialize = true

        if let result = response["result"] as? [String: Any],
           let thread = result["thread"] as? [String: Any] {
            if let threadId = thread["id"] as? String {
                agent.sessionId = threadId
                onSessionReady(agent.id, threadId)
            }
            hydrateTranscriptFromThread(thread)
            if let path = thread["path"] as? String {
                sessionFilePath = path
                refreshSessionMetadataFromFile(at: path)
            }
            if let status = thread["status"] as? [String: Any],
               let mapped = CodexAppServerMonitor.agentState(fromThreadStatus: status) {
                publishIfChanged(mapped)
            }
        }

        Task { @MainActor in
            startPolling()
        }

        flushPendingMessages()
    }

    private func hydrateTranscriptFromThread(_ thread: [String: Any]) {
        guard let turns = thread["turns"] as? [[String: Any]] else { return }

        var sawTaskStarted = false
        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for rawItem in items {
                guard let item = CodexAppServerMonitor.transcriptItem(from: rawItem) else { continue }
                if !sawTaskStarted, CodexAppServerMonitor.isBootstrapUserContextMessage(item) {
                    continue
                }
                sawTaskStarted = true
                onTranscriptItem(agent.id, item)
            }
        }
    }

    @MainActor
    private func startPolling() {
        pollTimer?.invalidate()
        pollNow()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
    }

    private func pollNow() {
        guard didInitialize, let threadId = agent.sessionId else { return }
        sendRequest(
            method: "thread/read",
            params: [
                "threadId": threadId,
                "includeTurns": false,
            ]
        ) { [weak self] response in
            guard let self,
                  let status = Self.extractThreadStatus(fromResponse: response),
                  let mapped = CodexAppServerMonitor.agentState(fromThreadStatus: status)
            else { return }
            self.publishIfChanged(mapped)
        }
    }

    private func publishIfChanged(_ state: AgentState) {
        guard lastObservedState != state else { return }
        lastObservedState = state
        onStateChange(agent.id, state)
    }

    func sendMessage(_ text: String, imagePaths: [String] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !didInitialize || agent.sessionId == nil {
            pendingMessages.append(trimmed)
            start()
            return
        }

        guard let threadId = agent.sessionId else { return }
        var input: [[String: Any]] = imagePaths.map { path in
            ["type": "localImage", "path": path] as [String: Any]
        }
        input.append(["type": "text", "text": trimmed])

        pendingImageTempPaths.append(contentsOf: imagePaths)
        activeTurnId = "pending"

        sendRequest(
            method: "turn/start",
            params: [
                "threadId": threadId,
                "input": input,
                "approvalPolicy": approvalPolicy.rawValue,
                "collaborationMode": collaborationModePayload(),
            ]
        ) { _ in }
    }

    func setCollaborationMode(_ mode: CodexCollaborationMode) {
        collaborationMode = mode
        onModelInfo(
            agent.id,
            rawModelName,
            CodexAppServerMonitor.friendlyModelName(rawModelName),
            mode,
            0
        )
    }

    func setApprovalPolicy(_ policy: CodexApprovalPolicy) {
        approvalPolicy = policy
    }

    func debugTriggerUserInput() {
        sendMessage("""
        Before doing any file or shell work, use the request_user_input tool to ask me one question with exactly two options:

        - Alpha
        - Beta

        Wait for my answer before continuing. Do not replace this with a plain-text question.
        """)
    }

    func respondToUserInput(answers: [String: [String]]) {
        queue.async { [weak self] in
            guard let self,
                  let pendingRequest = self.pendingUserInputRequest
            else { return }

            let payloadAnswers = answers.reduce(into: [String: [String: [String]]]()) { partial, entry in
                partial[entry.key] = ["answers": entry.value]
            }
            let response = CodexProtocol.RPCResponse.userInputAnswers(
                id: pendingRequest.requestId, answers: payloadAnswers
            )

            self.pendingUserInputRequest = nil
            self.writeEncodable(response)
            self.onUserInputResolved(self.agent.id)
        }
    }

    func respondToApproval(accept: Bool) {
        queue.async { [weak self] in
            guard let self,
                  let pendingRequest = self.pendingApprovalRequest
            else { return }

            if case .unsupportedPermissions = pendingRequest.request.kind { return }

            let response = CodexProtocol.RPCResponse.approvalDecision(
                id: pendingRequest.requestId, accept: accept
            )

            self.pendingApprovalRequest = nil
            self.writeEncodable(response)
            self.onApprovalResolved(self.agent.id)
        }
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        completion: @escaping @Sendable ([String: Any]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let id = self.nextRequestID
            self.nextRequestID += 1
            self.pendingRequests[id] = PendingRequest(completion: completion)

            let payload: [String: Any] = [
                "id": id,
                "method": method,
                "params": params,
            ]

            self.writeJSONObject(payload)
        }
    }

    private func writeEncodable(_ value: Encodable) {
        guard process.isRunning, let data = CodexProtocol.encodeLine(value) else { return }
        stdinPipe.fileHandleForWriting.write(data)
    }

    private func writeJSONObject(_ payload: [String: Any]) {
        guard process.isRunning,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        stdinPipe.fileHandleForWriting.write(Data(line.utf8))
    }

    private func flushPendingMessages() {
        guard didInitialize, let threadId = agent.sessionId, !pendingMessages.isEmpty else { return }
        let messages = pendingMessages
        pendingMessages.removeAll()
        for message in messages {
            activeTurnId = "pending"
            sendRequest(
                method: "turn/start",
                params: [
                    "threadId": threadId,
                    "input": [
                        [
                            "type": "text",
                            "text": message,
                        ],
                    ],
                    "approvalPolicy": approvalPolicy.rawValue,
                    "collaborationMode": collaborationModePayload(),
                ]
            ) { _ in }
        }
    }

    private func collaborationModePayload() -> [String: Any] {
        [
            "mode": collaborationMode.rawValue,
            "settings": [
                "model": rawModelName,
                "reasoning_effort": NSNull(),
                "developer_instructions": NSNull(),
            ],
        ]
    }

    private func refreshSessionMetadataFromFile(at path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8)
        else { return }

        var latestRawModelName = rawModelName
        var latestModelName = ""
        var latestMode = collaborationMode
        var latestContextPercent = 0.0

        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let rawModelName = CodexAppServerMonitor.rawModelName(fromSessionEvent: object) {
                latestRawModelName = rawModelName
            }
            if let modelName = CodexAppServerMonitor.modelName(fromSessionEvent: object) {
                latestModelName = modelName
            }
            if let mode = CodexAppServerMonitor.collaborationMode(fromSessionEvent: object) {
                latestMode = mode
            }
            if let contextPercent = CodexAppServerMonitor.contextPercentUsed(fromSessionEvent: object) {
                latestContextPercent = contextPercent
            }
        }

        rawModelName = latestRawModelName
        collaborationMode = latestMode
        onModelInfo(agent.id, latestRawModelName, latestModelName, latestMode, latestContextPercent)
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.stdoutBuffer.append(data)
            self.processBufferedLines(buffer: &self.stdoutBuffer, source: "stdout")
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.stderrBuffer.append(data)
            self.processBufferedLines(buffer: &self.stderrBuffer, source: "stderr")
        }
    }

    private func processBufferedLines(buffer: inout Data, source: String) {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8)
            else { continue }
            if source == "stdout" {
                handleJSONLine(line)
            }
        }
    }

    private func handleJSONLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        handleJSONObject(object)
    }

    private static func extractThreadStatus(fromResponse response: [String: Any]) -> [String: Any]? {
        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let status = thread["status"] as? [String: Any]
        else { return nil }
        return status
    }

    private func handleProcessTermination() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        pendingRequests.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        pendingApprovalRequest = nil
        pendingUserInputRequest = nil
        didInitialize = false
        activeTurnId = nil
    }
}

private extension Observer {
    func handleJSONObject(_ object: [String: Any]) {
        guard let event = CodexProtocol.Event.parse(object) else { return }
        switch event {
        case let .response(requestId, object):
            guard let request = pendingRequests.removeValue(forKey: requestId) else { return }
            request.completion(object)

        case let .userInputRequest(requestId, params):
            guard let request = CodexAppServerMonitor.userInputRequest(agentId: agent.id, params: params)
            else { return }
            pendingUserInputRequest = PendingUserInputServerRequest(requestId: requestId, request: request)
            publishIfChanged(.awaitingResponse)
            onUserInputRequest(agent.id, request)

        case let .approvalRequest(requestId, method, params):
            guard let request = CodexAppServerMonitor.approvalRequest(
                agentId: agent.id,
                requestId: requestId,
                method: method,
                params: params
            ) else { return }
            pendingApprovalRequest = PendingApprovalServerRequest(requestId: requestId, request: request)
            publishIfChanged(.needsPermission)
            onApprovalRequest(agent.id, request)

        case let .itemStarted(item):
            handleItemStarted(item: item)

        case let .agentMessageDelta(itemId, delta):
            handleAgentMessageDelta(itemId: itemId, delta: delta)

        case let .outputDelta(_, itemId, delta):
            handleToolOutputDelta(itemId: itemId, delta: delta)

        case let .itemCompleted(item):
            handleItemCompleted(item: item)

        case let .turnStarted(turnId):
            activeTurnId = turnId

        case .turnCompleted:
            activeTurnId = nil

        case let .threadStatusChanged(status):
            if let mapped = CodexAppServerMonitor.agentState(fromThreadStatus: status) {
                switch mapped {
                case .idle, .finished, .error:
                    activeTurnId = nil
                case .active, .needsPermission, .awaitingResponse, .awaitingInput:
                    break
                }
                publishIfChanged(mapped)
            }

        case let .error(message):
            let item = CodexTranscriptItem(
                id: UUID().uuidString,
                role: .system,
                text: "Error: \(message)"
            )
            onTranscriptItem(agent.id, item)
            publishIfChanged(.error)

        case .unknown:
            break
        }
    }

    func handleItemStarted(item: [String: Any]) {
        guard let toolItem = CodexAppServerMonitor.commandToolItem(fromStartedItem: item, isRunning: true)
            ?? CodexAppServerMonitor.fileChangeToolItem(fromStartedItem: item, isRunning: true),
            let rawId = item["id"] as? String
        else { return }
        inProgressToolItems[rawId] = toolItem
        onTranscriptItem(agent.id, toolItem)
    }

    func handleAgentMessageDelta(itemId: String, delta: String) {
        let existing = streamingAgentMessages[itemId] ?? ""
        let updated = existing + delta
        streamingAgentMessages[itemId] = updated
        activeStreamingItemId = itemId
        onStreamingText(agent.id, updated)
        onStreamDelta(agent.id, itemId, delta)
    }

    func handleToolOutputDelta(itemId: String, delta: String) {
        guard var item = inProgressToolItems[itemId] else { return }
        switch item.tool {
        case var .command(detail)?:
            detail.output += delta
            item.tool = .command(detail)
        case var .fileChange(detail)?:
            detail.patch += delta
            item.tool = .fileChange(detail)
        default:
            return
        }
        inProgressToolItems[itemId] = item
        onTranscriptItem(agent.id, item)
    }

    func handleItemCompleted(item: [String: Any]) {
        let itemType = item["type"] as? String
        let rawId = item["id"] as? String

        if itemType == "commandExecution" || itemType == "fileChange" {
            if let rawId {
                inProgressToolItems.removeValue(forKey: rawId)
            }
            if let finalized = CodexAppServerMonitor.transcriptItem(from: item) {
                onTranscriptItem(agent.id, finalized)
            }
        } else if let transcriptItem = CodexAppServerMonitor.transcriptItem(from: item) {
            onTranscriptItem(agent.id, transcriptItem)
        }

        if itemType == "agentMessage", let rawId {
            streamingAgentMessages.removeValue(forKey: rawId)
            if activeStreamingItemId == rawId {
                activeStreamingItemId = nil
                onStreamingText(agent.id, "")
            }
            onStreamFinalize(agent.id, rawId)
        }

        if itemType == "userMessage", !pendingImageTempPaths.isEmpty {
            for path in pendingImageTempPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
            pendingImageTempPaths.removeAll()
        }

        if let sessionFilePath {
            refreshSessionMetadataFromFile(at: sessionFilePath)
        }
        if itemType == "agentMessage",
           let text = item["text"] as? String,
           text.contains("request_user_input"),
           text.contains("unavailable in Default mode") {
            onDebugMessage(agent.id, text)
        }
    }
}

// swiftlint:enable file_length
