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
    private(set) var pendingApprovalRequests: [UUID: [String: CodexApprovalRequest]] = [:]
    private(set) var runtimeStates: [UUID: AgentState] = [:]
    /// Debug-only channel retained per plan (provider-specific raw event
    /// details may exist internally for debugging).
    private(set) var debugMessages: [UUID: String] = [:]
    private(set) var availableModels: [CodexAvailableModel] = CodexModelSettings.fallbackModels

    @ObservationIgnored private let modelCatalog = CodexModelCatalog(models: CodexModelSettings.fallbackModels)
    @ObservationIgnored private var observers: [UUID: Observer] = [:]
    @ObservationIgnored private var modelDiscovery: CodexModelDiscovery?
    @ObservationIgnored private var modelDiscoveryID: UUID?

    /// Normalized event emission state (Phase 1 dual-emit migration).
    /// Visibility relaxed from `private` so the +SessionEvents extension in a
    /// separate file can access them.
    @ObservationIgnored var streamingItemIds: [UUID: Set<String>] = [:]
    /// After a local interrupt, late provider events belong to the cancelled
    /// turn until the next local send or a non-in-flight provider status.
    @ObservationIgnored var interruptedProviderEventAgentIds: Set<UUID> = []
    @ObservationIgnored var interruptedProviderItemIds: [UUID: Set<String>] = [:]

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
        Observer(agent: agent, modelCatalog: modelCatalog) { [weak self] id, state in
            Task { @MainActor in
                self?.handleStateChange(for: id, state: state)
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
                self?.presentUserInputRequest(id: id, request: request)
            }
        } onApprovalRequest: { [weak self] id, request in
            Task { @MainActor in
                self?.presentApprovalRequest(id: id, request: request)
            }
        } onDebugMessage: { [weak self] id, message in
            Task { @MainActor in
                self?.debugMessages[id] = message
            }
        } onUserInputResolved: { [weak self] id in
            Task { @MainActor in
                self?.resolveUserInputRequest(id: id)
            }
        } onApprovalResolved: { [weak self] id, promptId in
            Task { @MainActor in
                self?.resolveApprovalRequest(id: id, promptId: promptId)
            }
        } onModelInfo: { [weak self] id, rawModel, displayModel, mode, contextPct in
            Task { @MainActor in
                self?.applyModelInfo(id: id, rawModel: rawModel, displayModel: displayModel, mode: mode, contextPct: contextPct)
            }
        } onAvailableModels: { [weak self] _, models in
            Task { @MainActor in
                self?.updateAvailableModels(models)
            }
        } onActiveToolChanged: { [weak self] id, name in
            Task { @MainActor in self?.applyActiveTool(name, for: id) }
        }
    }

    private func updateAvailableModels(_ models: [CodexAvailableModel]) {
        guard !models.isEmpty else { return }
        modelCatalog.replace(models)
        availableModels = models
    }

    func handleStateChange(for agentId: UUID, state: AgentState) {
        if shouldSuppressProviderStateChange(for: agentId, state: state) {
            return
        }
        if !Self.isInFlightState(state) {
            clearInterruptedProviderGate(for: agentId)
        }
        runtimeStates[agentId] = state
        onStateChange?(agentId, state)

        if shouldFinalizeStreams(for: state) {
            finalizeLingeringStreams(for: agentId)
        }

        emit(.runStateChanged(Self.mapRunState(state)), for: agentId)
    }

    private func applyActiveTool(_ name: String?, for agentId: UUID) {
        var update = SessionMetadataUpdate()
        update.activeToolName = name.map { .set($0) } ?? .clear
        emit(.metadataUpdated(update), for: agentId)
    }

    func presentUserInputRequest(id agentId: UUID, request: CodexUserInputRequest) {
        debugMessages.removeValue(forKey: agentId)
        pendingUserInputRequests[agentId] = request
        finalizeLingeringStreams(for: agentId)
        emit(.promptPresented(.userInput(Self.mapUserInputPrompt(request))), for: agentId)
    }

    func presentApprovalRequest(id agentId: UUID, request: CodexApprovalRequest) {
        pendingApprovalRequests[agentId, default: [:]][request.itemId] = request
        finalizeLingeringStreams(for: agentId)
        emit(.promptPresented(.approval(Self.mapApprovalPrompt(request))), for: agentId)
    }

    func resolveUserInputRequest(id agentId: UUID) {
        if let pending = pendingUserInputRequests[agentId] {
            finalizeLingeringStreams(for: agentId)
            emit(.promptResolved(id: pending.itemId), for: agentId)
        }
        pendingUserInputRequests.removeValue(forKey: agentId)
    }

    func resolveApprovalRequest(id agentId: UUID, promptId: String) {
        let pending = pendingApprovalRequests[agentId]?[promptId]
        if let pending {
            finalizeLingeringStreams(for: agentId)
        }
        emit(.promptResolved(id: pending?.itemId ?? promptId), for: agentId)
        pendingApprovalRequests[agentId]?.removeValue(forKey: promptId)
        if pendingApprovalRequests[agentId]?.isEmpty == true {
            pendingApprovalRequests.removeValue(forKey: agentId)
        }
    }

    func handleTranscriptItem(_ agentId: UUID, item: CodexTranscriptItem) {
        guard !shouldSuppressProviderItem(agentId: agentId, itemId: item.id)
        else { return }
        finalizeLingeringStreams(before: item, for: agentId)

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
        modelDiscovery?.stop()
        modelDiscovery = nil
        modelDiscoveryID = nil
    }

    func removeObserver(for agentId: UUID) {
        observers.removeValue(forKey: agentId)?.stop()
        pendingUserInputRequests.removeValue(forKey: agentId)
        pendingApprovalRequests.removeValue(forKey: agentId)
        runtimeStates.removeValue(forKey: agentId)
        debugMessages.removeValue(forKey: agentId)
        streamingItemIds.removeValue(forKey: agentId)
        interruptedProviderEventAgentIds.remove(agentId)
        interruptedProviderItemIds.removeValue(forKey: agentId)
        pendingLocalUserMessages.removeValue(forKey: agentId)
    }

    func sendMessage(for agentId: UUID, text: String, imagePaths: [String] = []) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imagePaths.isEmpty else { return }
        interruptedProviderEventAgentIds.remove(agentId)
        observers[agentId]?.sendMessage(text, imagePaths: imagePaths)
    }

    func recordSentUserMessage(for agentId: UUID, text: String, imageData: [Data]) {
        guard !text.isEmpty || !imageData.isEmpty else { return }
        finalizeLingeringStreams(for: agentId)
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

    func setSandboxMode(for agentId: UUID, mode: CodexSandboxMode) {
        observers[agentId]?.setSandboxMode(mode)
    }

    func setModelName(for agentId: UUID, modelName: String) {
        observers[agentId]?.setModelName(modelName)
    }

    func refreshAvailableModels() {
        if let observer = observers.values.first {
            observer.refreshAvailableModels()
            return
        }
        guard modelDiscovery == nil else { return }

        let discoveryID = UUID()
        let discovery = CodexModelDiscovery { [weak self] models in
            Task { @MainActor in
                guard let self, self.modelDiscoveryID == discoveryID else { return }
                self.modelDiscovery = nil
                self.modelDiscoveryID = nil
                self.updateAvailableModels(models)
            }
        }
        modelDiscovery = discovery
        modelDiscoveryID = discoveryID
        discovery.start()
    }

    func respondToApproval(for agentId: UUID, promptId: String, action: ApprovalAction) {
        observers[agentId]?.respondToApproval(promptId: promptId, action: action)
        resolveApprovalRequest(id: agentId, promptId: promptId)
    }

    func interrupt(for agentId: UUID) {
        applyLocalInterrupt(for: agentId)
        observers[agentId]?.interrupt()
    }

    func recordSystemTranscript(for agentId: UUID, text: String) {
        finalizeLingeringStreams(for: agentId)
        let item = CodexTranscriptItem(
            id: "system-\(UUID().uuidString)",
            role: .system,
            text: text
        )
        emitTranscriptUpsert(agentId, item: item, canonicalId: item.id)
    }

    private func applyLocalInterrupt(for agentId: UUID) {
        guard shouldApplyLocalInterrupt(for: agentId) else { return }

        let interruptedItemIds = streamingItemIds[agentId] ?? []
        if !interruptedItemIds.isEmpty {
            interruptedProviderItemIds[agentId, default: []].formUnion(interruptedItemIds)
        }
        finalizeLingeringStreams(for: agentId)
        resolveUserInputRequest(id: agentId)
        for promptId in pendingApprovalRequests[agentId]?.keys.sorted() ?? [] {
            resolveApprovalRequest(id: agentId, promptId: promptId)
        }
        applyActiveTool(nil, for: agentId)
        handleStateChange(for: agentId, state: .idle)
        interruptedProviderEventAgentIds.insert(agentId)
    }

    private func shouldApplyLocalInterrupt(for agentId: UUID) -> Bool {
        if let state = runtimeStates[agentId], Self.isInFlightState(state) {
            return true
        }
        return hasLingeringStreams(for: agentId)
            || pendingUserInputRequests[agentId] != nil
            || pendingApprovalRequests[agentId]?.isEmpty == false
    }

    private static func isInFlightState(_ state: AgentState) -> Bool {
        switch state {
        case .active, .needsPermission, .awaitingResponse, .awaitingInput:
            true
        case .idle, .finished, .error:
            false
        }
    }

    private func shouldSuppressProviderEvents(for agentId: UUID) -> Bool {
        interruptedProviderEventAgentIds.contains(agentId)
    }

    private func shouldSuppressProviderStateChange(for agentId: UUID, state: AgentState) -> Bool {
        shouldSuppressProviderEvents(for: agentId) && Self.isInFlightState(state)
    }

    func shouldSuppressProviderItem(agentId: UUID, itemId: String) -> Bool {
        interruptedProviderItemIds[agentId]?.contains(itemId) == true
    }

    private func clearInterruptedProviderGate(for agentId: UUID) {
        interruptedProviderEventAgentIds.remove(agentId)
    }

    private func shouldFinalizeStreams(for state: AgentState) -> Bool {
        switch state {
        case .active, .needsPermission:
            false
        case .idle, .awaitingInput, .awaitingResponse, .finished, .error:
            true
        }
    }

    private func finalizeLingeringStreams(before item: CodexTranscriptItem, for agentId: UUID) {
        guard hasLingeringStreams(for: agentId) else { return }

        // Any non-delta transcript item means timeline progress beyond the
        // dedicated live-stream row. Finalize first so the stale bottom row
        // cannot outlive the later item that supersedes it.
        finalizeLingeringStreams(for: agentId)
    }

    private func finalizeLingeringStreams(for agentId: UUID) {
        guard let itemIds = streamingItemIds[agentId], !itemIds.isEmpty else { return }
        for itemId in itemIds.sorted() {
            emitStreamFinalize(id: agentId, itemId: itemId)
        }
    }

    private func hasLingeringStreams(for agentId: UUID) -> Bool {
        guard let itemIds = streamingItemIds[agentId] else { return false }
        return !itemIds.isEmpty
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

    nonisolated static func collaborationModePayload(
        mode: CodexCollaborationMode,
        modelName: String,
        reasoningEffort: String?,
        availableModel: CodexAvailableModel? = nil
    ) -> [String: Any] {
        let supportedReasoningEffort = availableModel?.effectiveReasoningEffort(preferred: reasoningEffort)
        return [
            "mode": mode.rawValue,
            "settings": [
                "model": modelName,
                "reasoning_effort": supportedReasoningEffort.map { $0 as Any } ?? NSNull(),
                "developer_instructions": NSNull(),
            ],
        ]
    }
}

final class CodexModelCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var modelsByName: [String: CodexAvailableModel]

    init(models: [CodexAvailableModel]) {
        modelsByName = Self.index(models)
    }

    func replace(_ models: [CodexAvailableModel]) {
        guard !models.isEmpty else { return }
        lock.lock()
        modelsByName = Self.index(models)
        lock.unlock()
    }

    func model(named name: String) -> CodexAvailableModel? {
        lock.lock()
        defer { lock.unlock() }
        return modelsByName[name]
    }

    private static func index(_ models: [CodexAvailableModel]) -> [String: CodexAvailableModel] {
        models.reduce(into: [:]) { $0[$1.model] = $1 }
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
    private let onApprovalResolved: (UUID, String) -> Void
    private let onModelInfo: (UUID, String, String, CodexCollaborationMode, Double) -> Void
    private let onAvailableModels: (UUID, [CodexAvailableModel]) -> Void
    private let onActiveToolChanged: (UUID, String?) -> Void

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let queue: DispatchQueue

    private var didStartProcess = false
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var pollTimer: Timer?
    private var didInitialize = false
    private var lastObservedState: AgentState?
    private var pendingApprovalRequests: [String: PendingApprovalServerRequest] = [:]
    private var pendingUserInputRequest: PendingUserInputServerRequest?
    private var pendingMessages: [String] = []
    private var sessionFilePath: String?
    private var requestedModelName = CodexModelSettings.storedValue
    private var reportedModelName: String?
    private let modelCatalog: CodexModelCatalog
    private var collaborationMode: CodexCollaborationMode = .default
    private var approvalPolicy: CodexApprovalPolicy = .storedValue
    private var sandboxMode: CodexSandboxMode = .storedValue
    private var inProgressToolItems: [String: CodexTranscriptItem] = [:]
    private var activeStreamingItemId: String?
    private var activeTurnId: String?
    private var pendingImageTempPaths: [String] = []

    init(
        agent: Agent,
        modelCatalog: CodexModelCatalog,
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
        onApprovalResolved: @escaping (UUID, String) -> Void,
        onModelInfo: @escaping (UUID, String, String, CodexCollaborationMode, Double) -> Void,
        onAvailableModels: @escaping (UUID, [CodexAvailableModel]) -> Void,
        onActiveToolChanged: @escaping (UUID, String?) -> Void
    ) {
        self.agent = agent
        self.modelCatalog = modelCatalog
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
        self.onAvailableModels = onAvailableModels
        self.onActiveToolChanged = onActiveToolChanged
        queue = DispatchQueue(label: "CodexAppServerMonitor.\(agent.id.uuidString)")
    }

    func start() {
        // A Foundation Process is single-use: after run() has been called,
        // calling run() again can raise an Objective-C exception even if the
        // process is no longer running.
        guard !didStartProcess else { return }
        didStartProcess = true

        process.executableURL = URL(fileURLWithPath: ProviderExecutableLocator.executablePath(for: .codex))
        process.arguments = ["app-server", "--enable", "default_mode_request_user_input"]
        process.environment = ProcessEnvironment.interactive()
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
            didStartProcess = false
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
        pendingApprovalRequests.removeAll()
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
            self.refreshAvailableModels()
            self.startOrResumeThread()
        }
    }

    private func startOrResumeThread() {
        requestedModelName = CodexModelSettings.storedValue
        reportedModelName = nil
        approvalPolicy = .storedValue
        sandboxMode = .storedValue

        if agent.hasLaunched, let threadId = agent.sessionId, !threadId.isEmpty {
            sendRequest(
                method: "thread/resume",
                params: [
                    "threadId": threadId,
                    "cwd": agent.folder.path,
                    "approvalPolicy": approvalPolicy.rawValue,
                    "sandbox": sandboxMode.rawValue,
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
                "sandbox": sandboxMode.rawValue,
                "personality": "pragmatic",
            ]
        ) { [weak self] response in
            self?.finishThreadBootstrap(response: response)
        }
    }

    private func finishThreadBootstrap(response: [String: Any]) {
        didInitialize = true

        var didRefreshMetadata = false
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
                didRefreshMetadata = true
            }
            if let status = thread["status"] as? [String: Any],
               let mapped = CodexAppServerMonitor.agentState(fromThreadStatus: status) {
                publishIfChanged(mapped)
            }
        }
        if !didRefreshMetadata {
            publishModelInfo(contextPercent: 0)
        }

        Task { @MainActor in
            startPolling()
        }

        flushPendingMessages()
    }

    private func hydrateTranscriptFromThread(_ thread: [String: Any]) {
        guard let turns = thread["turns"] as? [[String: Any]] else { return }

        var sawTaskStarted = false
        var recentItems: [CodexTranscriptItem] = []
        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for rawItem in items {
                guard let item = CodexAppServerMonitor.transcriptItem(from: rawItem) else { continue }
                if !sawTaskStarted, CodexAppServerMonitor.isBootstrapUserContextMessage(item) {
                    continue
                }
                sawTaskStarted = true
                recentItems.append(item)
                if recentItems.count > SessionRetentionPolicy.maxRetainedTranscriptItems {
                    recentItems.removeFirst(recentItems.count - SessionRetentionPolicy.maxRetainedTranscriptItems)
                }
            }
        }
        for item in recentItems {
            onTranscriptItem(agent.id, item)
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
        publishModelInfo(contextPercent: 0)
    }

    func setApprovalPolicy(_ policy: CodexApprovalPolicy) {
        approvalPolicy = policy
    }

    func setSandboxMode(_ mode: CodexSandboxMode) {
        sandboxMode = mode
    }

    func setModelName(_ modelName: String) {
        guard let normalized = CodexModelSettings.normalized(modelName) else { return }
        requestedModelName = normalized
        reportedModelName = nil
        publishModelInfo(contextPercent: 0)
    }

    func refreshAvailableModels() {
        queue.async { [weak self] in
            self?.fetchAvailableModels(cursor: nil, accumulated: [], pagesRemaining: 10)
        }
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

    func respondToApproval(promptId: String, action: ApprovalAction) {
        queue.async { [weak self] in
            guard let self,
                  let pendingRequest = self.pendingApprovalRequests[promptId]
            else { return }

            if action.kind == .allowAlways,
               let prefixRule = action.metadata?.prefixRule {
                try? CodexRulesStore.allowCommandPrefix(prefixRule)
            }

            if case .unsupportedPermissions = pendingRequest.request.kind {
                self.pendingApprovalRequests.removeValue(forKey: promptId)
                self.onApprovalResolved(self.agent.id, promptId)
                return
            }

            let decision: JSONValue = switch action.kind {
            case .allowOnce:
                .string("accept")
            case .allowForSession:
                .string("acceptForSession")
            case .allowAlways:
                if let amendment = action.metadata?.execpolicyAmendment, !amendment.isEmpty {
                    .object([
                        "acceptWithExecpolicyAmendment": .object([
                            "execpolicy_amendment": .array(amendment.map(JSONValue.string)),
                        ]),
                    ])
                } else {
                    .string("accept")
                }
            case .rejectOnce, .rejectAlways, .dismiss, .none:
                .string("decline")
            }

            let response = CodexProtocol.RPCResponse.approvalDecision(
                id: pendingRequest.requestId, decision: decision
            )

            self.pendingApprovalRequests.removeValue(forKey: promptId)
            self.writeEncodable(response)
            self.onApprovalResolved(self.agent.id, promptId)
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
        let pendingApprovalIds = pendingApprovalRequests.keys.sorted()
        let hadPendingUserInput = pendingUserInputRequest != nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        pendingRequests.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        pendingApprovalRequests.removeAll()
        pendingUserInputRequest = nil
        didInitialize = false
        activeTurnId = nil
        for promptId in pendingApprovalIds {
            onApprovalResolved(agent.id, promptId)
        }
        if hadPendingUserInput {
            onUserInputResolved(agent.id)
        }
    }
}

private extension Observer {
    func fetchAvailableModels(
        cursor: String?,
        accumulated: [CodexAvailableModel],
        pagesRemaining: Int
    ) {
        guard pagesRemaining > 0 else {
            publishAvailableModels(accumulated)
            return
        }

        var params: [String: Any] = [
            "includeHidden": false,
            "limit": 100,
        ]
        if let cursor {
            params["cursor"] = cursor
        }

        sendRequest(method: "model/list", params: params) { [weak self] response in
            guard let self else { return }
            let page = CodexModelSettings.models(from: response)
            let models = CodexModelSettings.deduplicated(accumulated + page)
            if let nextCursor = CodexModelSettings.nextCursor(from: response) {
                self.fetchAvailableModels(
                    cursor: nextCursor,
                    accumulated: models,
                    pagesRemaining: pagesRemaining - 1
                )
            } else {
                self.publishAvailableModels(models)
            }
        }
    }

    func publishAvailableModels(_ models: [CodexAvailableModel]) {
        guard !models.isEmpty else { return }
        modelCatalog.replace(models)
        onAvailableModels(agent.id, models)
    }

    func collaborationModePayload() -> [String: Any] {
        let model = modelCatalog.model(named: requestedModelName)
        return CodexAppServerMonitor.collaborationModePayload(
            mode: collaborationMode,
            modelName: requestedModelName,
            reasoningEffort: CodexModelSettings.storedReasoningEffort,
            availableModel: model
        )
    }

    func publishModelInfo(contextPercent: Double) {
        let displayRawModelName = reportedModelName ?? requestedModelName
        onModelInfo(
            agent.id,
            displayRawModelName,
            modelCatalog.model(named: displayRawModelName)?.displayTitle
                ?? CodexAppServerMonitor.friendlyModelName(displayRawModelName),
            collaborationMode,
            contextPercent
        )
    }

    func refreshSessionMetadataFromFile(at path: String) {
        let metadata = CodexAppServerMonitor.sessionFileMetadata(
            atPath: path,
            initial: CodexSessionFileMetadata(
                rawModelName: reportedModelName,
                collaborationMode: collaborationMode,
                contextPercentUsed: 0
            )
        )

        reportedModelName = metadata.rawModelName
        collaborationMode = metadata.collaborationMode
        publishModelInfo(contextPercent: metadata.contextPercentUsed)
    }

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
            pendingApprovalRequests[request.itemId] = PendingApprovalServerRequest(requestId: requestId, request: request)
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
        onActiveToolChanged(agent.id, currentActiveToolLabel())
    }

    private func currentActiveToolLabel() -> String? {
        guard let item = inProgressToolItems.values.first else { return nil }
        switch item.tool {
        case .command: return "Shell"
        case .fileChange: return "Edit"
        case .none: return nil
        }
    }

    func handleAgentMessageDelta(itemId: String, delta: String) {
        activeStreamingItemId = itemId
        onStreamDelta(agent.id, itemId, delta)
    }

    func handleToolOutputDelta(itemId: String, delta: String) {
        guard var item = inProgressToolItems[itemId] else { return }
        let previousDisplayText = item.displayText
        switch item.tool {
        case var .command(detail)?:
            detail.output = SessionRetentionPolicy.appendRetainedToolOutput(delta, to: detail.output)
            item.tool = .command(detail)
        case var .fileChange(detail)?:
            detail.patch = SessionRetentionPolicy.appendRetainedToolOutput(delta, to: detail.patch)
            item.tool = .fileChange(detail)
        default:
            return
        }
        inProgressToolItems[itemId] = item
        if item.displayText != previousDisplayText {
            onTranscriptItem(agent.id, item)
        }
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
            onActiveToolChanged(agent.id, currentActiveToolLabel())
        } else if let transcriptItem = CodexAppServerMonitor.transcriptItem(from: item) {
            onTranscriptItem(agent.id, transcriptItem)
        }

        if itemType == "agentMessage", let rawId {
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
