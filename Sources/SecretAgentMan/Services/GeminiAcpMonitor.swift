// swiftlint:disable file_length
import Foundation
import Observation

/// Per-agent monitor for `gemini --acp` ACP/JSON-RPC sessions.
///
/// Mirrors the shape of `CodexAppServerMonitor`: the outer class is a
/// per-agent dispatcher that owns one `Observer` (process + JSON-RPC client)
/// per agent and routes incoming protocol events through normalized
/// `SessionEvent`s.
@MainActor
@Observable
final class GeminiAcpMonitor {
    @ObservationIgnored var onStateChange: ((UUID, AgentState) -> Void)?
    @ObservationIgnored var onSessionReady: ((UUID, String) -> Void)?
    @ObservationIgnored var onSessionEvent: ((UUID, SessionEvent) -> Void)?

    /// Tracks an outstanding ACP `session/request_permission`. The monitor
    /// keeps the original request shape so it can answer the JSON-RPC request
    /// with the user's selected `optionId` (or a `cancelled` outcome) later.
    struct PendingApproval: Equatable {
        let promptId: String
        let acpRequestId: GeminiAcpRpc.Id
        let sessionId: String
    }

    private(set) var pendingApprovalRequests: [UUID: PendingApproval] = [:]
    /// Debug-only channel for surfacing raw monitor diagnostics. Mirrors
    /// Codex's `debugMessages`.
    private(set) var debugMessages: [UUID: String] = [:]

    /// Local user-message reconciliation. Gemini echoes user messages back as
    /// part of `session/update.user_message_chunk` for loaded history; for
    /// in-flight prompts the monitor stamps a local id and reuses it when the
    /// agent's `userMessageId` arrives via `PromptResponse`.
    struct PendingLocalUserMessage: Equatable {
        let id: String
        let text: String
        let imageData: [Data]
    }

    @ObservationIgnored private(set) var pendingLocalUserMessages: [UUID: [PendingLocalUserMessage]] = [:]

    /// Active streaming-bubble item id per agent, keyed by stream type. The
    /// `messageId` in incoming `ContentChunk`s is optional, so the monitor
    /// allocates a stable id on first chunk and reuses it for deltas until the
    /// turn ends.
    @ObservationIgnored private var activeAssistantStreamId: [UUID: String] = [:]
    @ObservationIgnored private var activeThoughtStreamId: [UUID: String] = [:]

    /// Tool call lifecycle state. Gemini sends `tool_call` once and then
    /// arbitrary `tool_call_update`s; the monitor merges partial fields into
    /// the cached snapshot before emitting normalized transcript updates.
    @ObservationIgnored private(set) var toolCallSnapshots: [UUID: [String: ToolCallSnapshot]] = [:]

    /// Sidecar tool-call data recovered from `~/.gemini/tmp/<slug>/chats/
    /// session-*.json` for sessions resumed via `session/load`. Used to
    /// substitute descriptive titles for tool calls that gemini's
    /// `streamHistory` replay strips down to bare registry names.
    /// Workaround — see `GeminiSessionSidecar`.
    @ObservationIgnored private(set) var sidecarToolInfo: [UUID: [String: GeminiSessionSidecar.ToolCallInfo]] = [:]

    @ObservationIgnored private var observers: [UUID: Observer] = [:]

    init() {}

    // MARK: - Public API (production)

    func syncMonitoredAgents(_ agents: [Agent]) {
        let desired = Dictionary(
            uniqueKeysWithValues: agents.compactMap { agent -> (UUID, Agent)? in
                guard agent.provider == .gemini, agent.hasLaunched else { return nil }
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
        guard agent.provider == .gemini else { return }
        if let existing = observers[agent.id] {
            existing.update(agent: agent)
            existing.start()
            return
        }
        let observer = Observer(agent: agent, monitor: self)
        observers[agent.id] = observer
        observer.start()
    }

    func stopAll() {
        for observer in observers.values {
            observer.stop()
        }
        observers.removeAll()
    }

    func removeObserver(for agentId: UUID) {
        observers.removeValue(forKey: agentId)?.stop()
        clearAgentState(for: agentId)
    }

    func sendMessage(for agentId: UUID, text: String, imageData: [Data] = []) {
        observers[agentId]?.sendPrompt(text: text, imageData: imageData)
    }

    func interrupt(for agentId: UUID) {
        observers[agentId]?.cancel()
    }

    func respondToApproval(for agentId: UUID, optionId: String) {
        guard let pending = pendingApprovalRequests[agentId] else { return }
        observers[agentId]?.respondToPermission(
            acpRequestId: pending.acpRequestId,
            outcome: .selected(optionId: optionId)
        )
        emit(.promptResolved(id: pending.promptId), for: agentId)
        pendingApprovalRequests.removeValue(forKey: agentId)
        // Turn is still in flight — bump back to `.active` until the
        // matching `session/prompt` response (or another approval) arrives.
        onStateChange?(agentId, .active)
    }

    func setMode(for agentId: UUID, modeId: String) {
        observers[agentId]?.setMode(modeId: modeId)
        var update = SessionMetadataUpdate()
        update.currentModeId = .set(modeId)
        emit(.metadataUpdated(update), for: agentId)
    }

    func setModel(for agentId: UUID, modelId: String) {
        observers[agentId]?.setModel(modelId: modelId)
        var update = SessionMetadataUpdate()
        update.currentModelId = .set(modelId)
        emit(.metadataUpdated(update), for: agentId)
    }

    // MARK: - Internal emit (also used by tests)

    func emit(_ event: SessionEvent, for agentId: UUID) {
        onSessionEvent?(agentId, event)
    }

    /// Records a locally-sent user message before the agent echoes it back.
    /// Mirrors Codex's `recordSentUserMessage`: a `local-user-*` id is created
    /// up front so the transcript shows the user's text immediately.
    func recordSentUserMessage(for agentId: UUID, text: String, imageData: [Data] = []) {
        guard !text.isEmpty || !imageData.isEmpty else { return }
        let localId = "local-user-\(UUID().uuidString)"
        pendingLocalUserMessages[agentId, default: []].append(
            PendingLocalUserMessage(id: localId, text: text, imageData: imageData)
        )
        emit(
            .transcriptUpsert(SessionTranscriptItem(
                id: localId,
                kind: .userMessage,
                text: text,
                createdAt: Date(),
                imageData: imageData
            )),
            for: agentId
        )
    }

    /// Called by the Observer with raw stderr lines from `gemini --acp`. The
    /// monitor surfaces them as system transcript items so a user-visible
    /// error message ("auth required", "rate limit", etc.) doesn't get
    /// swallowed silently. Also stashed in `debugMessages` for any panel that
    /// wants to display them inline.
    func recordStderr(for agentId: UUID, line: String) {
        debugMessages[agentId] = line
        recordSystemTranscript(for: agentId, text: "[gemini stderr] \(line)")
    }

    /// Called by the Observer just before sending a `session/prompt`. Bumps
    /// agent state to `.active` so the panel renders its "thinking" UI before
    /// the first `agent_message_chunk` arrives.
    func beginTurn(for agentId: UUID) {
        onStateChange?(agentId, .active)
        emit(.runStateChanged(.running), for: agentId)
    }

    /// Called by the Observer when the prompt response decode fails or some
    /// other terminal error short-circuits the turn. Mirrors what
    /// `applyPromptResponse` does on success so the agent doesn't stay stuck
    /// in `.active` forever.
    func endTurn(for agentId: UUID) {
        onStateChange?(agentId, .idle)
    }

    /// Called by the Observer when the underlying `gemini --acp` process
    /// exits. Clears prompt state and surfaces a system message.
    func handleProcessExit(for agentId: UUID) {
        pendingApprovalRequests.removeValue(forKey: agentId)
        pendingLocalUserMessages.removeValue(forKey: agentId)
        activeAssistantStreamId.removeValue(forKey: agentId)
        activeThoughtStreamId.removeValue(forKey: agentId)
        toolCallSnapshots.removeValue(forKey: agentId)
        emit(.runStateChanged(.error(message: "Gemini ACP process exited.")), for: agentId)
        recordSystemTranscript(for: agentId, text: "Gemini agent disconnected.")
        observers.removeValue(forKey: agentId)
    }

    /// Called by the Observer when `Process.run()` throws (binary missing,
    /// not executable, etc.).
    func handleSpawnFailure(for agentId: UUID, message: String) {
        emit(
            .runStateChanged(.error(message: "Could not start gemini --acp: \(message)")),
            for: agentId
        )
        recordSystemTranscript(
            for: agentId,
            text: "Could not start gemini --acp. Authenticate Gemini CLI in a terminal first."
        )
        observers.removeValue(forKey: agentId)
    }

    func recordSystemTranscript(for agentId: UUID, text: String) {
        emit(
            .transcriptUpsert(SessionTranscriptItem(
                id: "system-\(UUID().uuidString)",
                kind: .systemMessage,
                text: text,
                createdAt: Date()
            )),
            for: agentId
        )
    }

    private func clearAgentState(for agentId: UUID) {
        pendingApprovalRequests.removeValue(forKey: agentId)
        debugMessages.removeValue(forKey: agentId)
        pendingLocalUserMessages.removeValue(forKey: agentId)
        activeAssistantStreamId.removeValue(forKey: agentId)
        activeThoughtStreamId.removeValue(forKey: agentId)
        toolCallSnapshots.removeValue(forKey: agentId)
        sidecarToolInfo.removeValue(forKey: agentId)
    }

    /// Stash the sidecar map read from disk after a successful
    /// `session/load`. Subsequent `tool_call` notifications during the
    /// `streamHistory` replay can then look up the rich title via
    /// `sidecarToolDescription(_:for:)`.
    func setSidecarToolInfo(_ info: [String: GeminiSessionSidecar.ToolCallInfo], for agentId: UUID) {
        sidecarToolInfo[agentId] = info
    }

    func sidecarToolDescription(_ toolCallId: String, for agentId: UUID) -> String? {
        sidecarToolInfo[agentId]?[toolCallId]?.description
    }

    // MARK: - Internal accessors used by +SessionEvents extension

    func consumeAssistantStreamId(for agentId: UUID) -> String? {
        activeAssistantStreamId.removeValue(forKey: agentId)
    }

    func ensureAssistantStreamId(for agentId: UUID) -> (id: String, isNew: Bool) {
        if let existing = activeAssistantStreamId[agentId] {
            return (existing, false)
        }
        let id = "gemini-stream-\(UUID().uuidString)"
        activeAssistantStreamId[agentId] = id
        return (id, true)
    }

    func consumeThoughtStreamId(for agentId: UUID) -> String? {
        activeThoughtStreamId.removeValue(forKey: agentId)
    }

    func ensureThoughtStreamId(for agentId: UUID) -> (id: String, isNew: Bool) {
        if let existing = activeThoughtStreamId[agentId] {
            return (existing, false)
        }
        let id = "gemini-thought-\(UUID().uuidString)"
        activeThoughtStreamId[agentId] = id
        return (id, true)
    }

    func setPendingApproval(_ pending: PendingApproval, for agentId: UUID) {
        pendingApprovalRequests[agentId] = pending
    }

    func mergeToolCall(_ snapshot: ToolCallSnapshot, for agentId: UUID) {
        toolCallSnapshots[agentId, default: [:]][snapshot.toolCallId] = snapshot
    }

    func currentToolCall(_ toolCallId: String, for agentId: UUID) -> ToolCallSnapshot? {
        toolCallSnapshots[agentId]?[toolCallId]
    }

    func dropToolCall(_ toolCallId: String, for agentId: UUID) {
        toolCallSnapshots[agentId]?.removeValue(forKey: toolCallId)
    }

    /// Pop the oldest pending local user message matching `text`. Returns
    /// `nil` if there's no match — the agent emitted a user_message_chunk
    /// from session-history hydration rather than echoing a fresh prompt.
    func popPendingLocalUserMessage(for agentId: UUID, matching text: String) -> PendingLocalUserMessage? {
        guard var pending = pendingLocalUserMessages[agentId],
              let index = pending.firstIndex(where: { $0.text == text })
        else { return nil }
        let popped = pending.remove(at: index)
        pendingLocalUserMessages[agentId] = pending.isEmpty ? nil : pending
        return popped
    }
}

// MARK: - Tool call snapshot

/// Cached state for an in-flight tool call. The agent emits one `tool_call`
/// then arbitrary `tool_call_update`s; the monitor merges partial fields here.
struct ToolCallSnapshot: Equatable {
    let toolCallId: String
    var title: String
    var kind: GeminiAcpProtocol.ToolKind?
    var status: GeminiAcpProtocol.ToolCallStatus?
    var locations: [GeminiAcpProtocol.ToolCallLocation]
    var contentSummary: String

    /// Treat anything that's not pending/in_progress as terminal.
    var isTerminal: Bool {
        switch status {
        case .completed?, .failed?: true
        default: false
        }
    }
}

// MARK: - Observer (private)

/// Wraps one `gemini --acp` process. Owns the JSON-RPC client (pending
/// request map, ND-JSON framing) and routes incoming protocol events back to
/// the monitor by calling its `apply*` methods on the main actor.
///
/// Lifecycle: `start()` spawns the process, sends `initialize`, then either
/// `session/load` (if the agent advertises it and we have a stored sessionId)
/// or `session/new`. After the session is ready, `sendPrompt`, `cancel`,
/// `setMode`, and `setModel` operate on the live session.
private final class Observer: @unchecked Sendable {
    private(set) var agent: Agent
    private weak var monitor: GeminiAcpMonitor?

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let queue: DispatchQueue
    private var stdoutBuffer = Data()
    private var didStart = false

    /// Pending JSON-RPC requests keyed by integer id. The completion runs on
    /// the Observer's queue; per-method handlers re-dispatch to MainActor
    /// before touching monitor state.
    private var pendingResponses: [Int: (GeminiAcpRpc.IncomingResponse) -> Void] = [:]
    private var nextRequestId = 1

    private var loadSessionAvailable = false
    /// Set after the `initialize` exchange so `sendPrompt`/etc. know whether
    /// the prompt-time session/new lookup has completed.
    private var sessionEstablished = false
    private var queuedPrompts: [(text: String, imageData: [Data])] = []
    private var inFlightPromptId: Int?

    init(agent: Agent, monitor: GeminiAcpMonitor) {
        self.agent = agent
        self.monitor = monitor
        self.queue = DispatchQueue(label: "GeminiAcpMonitor.\(agent.id.uuidString)")
    }

    func update(agent: Agent) {
        self.agent = agent
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        process.executableURL = URL(fileURLWithPath: Self.geminiExecutablePath())
        process.arguments = ["--acp"]
        process.currentDirectoryURL = agent.folder
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
            self?.queue.async { self?.handleProcessExit() }
        }

        do {
            try process.run()
        } catch {
            reportSpawnFailure(error: error)
            return
        }

        sendInitialize()
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        queue.async { [weak self] in
            self?.pendingResponses.removeAll()
            self?.queuedPrompts.removeAll()
            self?.inFlightPromptId = nil
        }
        if process.isRunning {
            process.terminate()
        }
    }

    func sendPrompt(text: String, imageData: [Data]) {
        queue.async { [weak self] in
            guard let self else { return }
            guard sessionEstablished, let sessionId = agent.sessionId else {
                queuedPrompts.append((text, imageData))
                return
            }
            dispatchPrompt(sessionId: sessionId, text: text, imageData: imageData)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, let sessionId = agent.sessionId else { return }
            sendNotification(
                method: GeminiAcpProtocol.Method.sessionCancel,
                params: GeminiAcpProtocol.CancelNotification(sessionId: sessionId)
            )
        }
    }

    func setMode(modeId: String) {
        queue.async { [weak self] in
            guard let self, let sessionId = agent.sessionId else { return }
            sendRequest(
                method: GeminiAcpProtocol.Method.sessionSetMode,
                params: GeminiAcpProtocol.SetSessionModeRequest(sessionId: sessionId, modeId: modeId),
                completion: { _ in }
            )
        }
    }

    func setModel(modelId: String) {
        queue.async { [weak self] in
            guard let self, let sessionId = agent.sessionId else { return }
            sendRequest(
                method: GeminiAcpProtocol.Method.sessionSetModel,
                params: GeminiAcpProtocol.SetSessionModelRequest(sessionId: sessionId, modelId: modelId),
                completion: { _ in }
            )
        }
    }

    func respondToPermission(
        acpRequestId: GeminiAcpRpc.Id,
        outcome: GeminiAcpProtocol.RequestPermissionOutcome
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let response = GeminiAcpProtocol.RequestPermissionResponse(outcome: outcome)
            writeFrame(GeminiAcpRpc.Response(id: acpRequestId, result: response))
        }
    }

    // MARK: - Lifecycle

    private func sendInitialize() {
        let params = GeminiAcpProtocol.InitializeRequest(
            clientInfo: GeminiAcpProtocol.Implementation(
                name: "secret-agent-man",
                title: "SecretAgentMan",
                version: "0.1.0"
            )
        )
        sendRequest(method: GeminiAcpProtocol.Method.initialize, params: params) { [weak self] response in
            guard let self else { return }
            queue.async {
                self.handleInitializeResponse(response)
            }
        }
    }

    private func handleInitializeResponse(_ response: GeminiAcpRpc.IncomingResponse) {
        if let result = response.result,
           let init_ = try? result.decode(as: GeminiAcpProtocol.InitializeResponse.self) {
            loadSessionAvailable = init_.agentCapabilities?.loadSession ?? false
        }

        // ACP-mode sessions are persisted to `~/.gemini/tmp/<project>/chats/
        // session-*.json` by gemini-cli's `ChatRecordingService`. The ACP
        // `session/load` handler resolves through the same on-disk
        // `SessionSelector` that backs `gemini --resume <id>` in the TUI, so
        // a session with at least one user/assistant exchange is loadable
        // across processes.
        //
        // Sessions with zero user/assistant messages (e.g. spawned via
        // `session/new` then closed before any prompt) get filtered by
        // `getAllSessionFiles`, causing `session/load` to throw and surface
        // as JSON-RPC -32603. We treat that as a benign "stale stored id"
        // signal and silently fall back to `session/new` rather than nagging
        // the user every launch.
        if loadSessionAvailable, let stored = agent.sessionId, !stored.isEmpty {
            sendLoadSession(sessionId: stored)
        } else {
            sendNewSession()
        }
    }

    private func sendNewSession() {
        let params = GeminiAcpProtocol.NewSessionRequest(cwd: agent.folder.path)
        sendRequest(method: GeminiAcpProtocol.Method.sessionNew, params: params) { [weak self] response in
            self?.queue.async { self?.handleNewSessionResponse(response) }
        }
    }

    private func sendLoadSession(sessionId: String) {
        let params = GeminiAcpProtocol.LoadSessionRequest(sessionId: sessionId, cwd: agent.folder.path)
        sendRequest(method: GeminiAcpProtocol.Method.sessionLoad, params: params) { [weak self] response in
            self?.queue.async {
                guard let self else { return }
                if response.error != nil {
                    // Most common failure mode: the stored sessionId points
                    // at a chats file with zero user/assistant messages, so
                    // `getAllSessionFiles` filters it out and ACP wraps the
                    // resulting SessionError as -32603. Silently fall back —
                    // the user doesn't need a system banner for stale ids.
                    self.sendNewSession()
                    return
                }
                self.handleLoadSessionResponse(response, sessionId: sessionId)
            }
        }
    }

    private func handleNewSessionResponse(_ response: GeminiAcpRpc.IncomingResponse) {
        guard let result = response.result,
              let parsed = try? result.decode(as: GeminiAcpProtocol.NewSessionResponse.self)
        else { return }

        sessionEstablished = true
        let agentId = agent.id
        let monitor = self.monitor
        let queued = queuedPrompts
        queuedPrompts.removeAll()
        DispatchQueue.main.async {
            monitor?.applyNewSessionResponse(parsed, for: agentId)
        }
        for prompt in queued {
            dispatchPrompt(sessionId: parsed.sessionId, text: prompt.text, imageData: prompt.imageData)
        }
    }

    private func handleLoadSessionResponse(
        _ response: GeminiAcpRpc.IncomingResponse,
        sessionId: String
    ) {
        guard let result = response.result,
              let parsed = try? result.decode(as: GeminiAcpProtocol.LoadSessionResponse.self)
        else { return }

        sessionEstablished = true
        let agentId = agent.id
        let monitor = self.monitor
        let projectRoot = agent.folder
        let queued = queuedPrompts
        queuedPrompts.removeAll()

        // Read gemini's on-disk session JSON to recover descriptive titles
        // that the ACP `streamHistory` replay drops. Done before the
        // applyLoadSessionResponse hop so the sidecar is in place by the
        // time `tool_call` notifications start arriving.
        let sidecar = GeminiSessionSidecar.toolCallInfo(
            forSessionId: sessionId,
            projectRoot: projectRoot
        )
        DispatchQueue.main.async {
            monitor?.setSidecarToolInfo(sidecar, for: agentId)
            monitor?.applyLoadSessionResponse(parsed, sessionId: sessionId, for: agentId)
        }
        for prompt in queued {
            dispatchPrompt(sessionId: sessionId, text: prompt.text, imageData: prompt.imageData)
        }
    }

    // MARK: - Prompt dispatch

    private func dispatchPrompt(sessionId: String, text: String, imageData: [Data]) {
        var blocks: [GeminiAcpProtocol.ContentBlock] = []
        if !text.isEmpty {
            blocks.append(.text(GeminiAcpProtocol.TextContent(text: text)))
        }
        for data in imageData {
            blocks.append(.image(GeminiAcpProtocol.ImageContent(
                data: data.base64EncodedString(),
                mimeType: "image/png"
            )))
        }
        let messageId = "client-\(UUID().uuidString)"
        let params = GeminiAcpProtocol.PromptRequest(
            sessionId: sessionId,
            prompt: blocks,
            messageId: messageId
        )

        // Surface that a turn has started — drives the "thinking" UI before
        // the first agent_message_chunk arrives. The matching `.idle` is
        // emitted from `monitor.applyPromptResponse` when the turn ends.
        let agentId = agent.id
        let monitor = self.monitor
        DispatchQueue.main.async {
            monitor?.beginTurn(for: agentId)
        }

        let promptIdGuess = nextRequestId
        sendRequest(method: GeminiAcpProtocol.Method.sessionPrompt, params: params) { [weak self] response in
            self?.queue.async {
                guard let self else { return }
                if self.inFlightPromptId == promptIdGuess {
                    self.inFlightPromptId = nil
                }

                if let err = response.error {
                    self.surfaceDebug(
                        prefix: "session/prompt error",
                        text: "code=\(err.code) message=\(err.message)"
                    )
                    let agentId = self.agent.id
                    let monitor = self.monitor
                    DispatchQueue.main.async {
                        monitor?.endTurn(for: agentId)
                    }
                    return
                }

                guard let result = response.result else {
                    self.surfaceDebug(prefix: "session/prompt response missing result", text: "")
                    let agentId = self.agent.id
                    let monitor = self.monitor
                    DispatchQueue.main.async {
                        monitor?.endTurn(for: agentId)
                    }
                    return
                }

                let parsed: GeminiAcpProtocol.PromptResponse
                do {
                    parsed = try result.decode(as: GeminiAcpProtocol.PromptResponse.self)
                } catch {
                    let raw = (try? JSONEncoder().encode(result))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable>"
                    self.surfaceDebug(
                        prefix: "session/prompt response decode failed: \(error.localizedDescription)",
                        text: raw
                    )
                    let agentId = self.agent.id
                    let monitor = self.monitor
                    DispatchQueue.main.async {
                        monitor?.endTurn(for: agentId)
                    }
                    return
                }

                let agentId = self.agent.id
                let monitor = self.monitor
                DispatchQueue.main.async {
                    monitor?.applyPromptResponse(parsed, for: agentId)
                }
            }
        }
        inFlightPromptId = promptIdGuess
    }

    // MARK: - JSON-RPC framing

    /// Always called on `queue`.
    private func sendRequest(
        method: String,
        params: some Encodable,
        completion: @escaping (GeminiAcpRpc.IncomingResponse) -> Void
    ) {
        let id = nextRequestId
        nextRequestId += 1
        pendingResponses[id] = completion
        let request = GeminiAcpRpc.Request(id: .int(id), method: method, params: params)
        writeFrame(request)
    }

    /// Always called on `queue`.
    private func sendNotification(method: String, params: some Encodable) {
        let note = GeminiAcpRpc.Notification(method: method, params: params)
        writeFrame(note)
    }

    private func writeFrame(_ value: some Encodable) {
        guard process.isRunning else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        stdinPipe.fileHandleForWriting.write(data)
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            stdoutBuffer.append(data)
            processBufferedLines()
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty,
              let raw = String(data: data, encoding: .utf8)
        else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let agentId = agent.id
        let monitor = self.monitor
        DispatchQueue.main.async {
            monitor?.recordStderr(for: agentId, line: text)
        }
    }

    private func processBufferedLines() {
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else { continue }
            dispatchFrame(Data(lineData))
        }
    }

    private func dispatchFrame(_ data: Data) {
        do {
            guard let frame = try GeminiAcpRpc.decodeIncoming(data) else {
                surfaceDebug(prefix: "unrecognized frame", data: data)
                return
            }
            switch frame {
            case let .response(resp):
                guard case let .int(rawId) = resp.id else {
                    surfaceDebug(prefix: "response with non-int id", data: data)
                    return
                }
                // Per-method completion handlers decide whether an error
                // is expected (e.g. session/load failure → graceful
                // fallback) or surface-worthy. Don't auto-surface here.
                let completion = pendingResponses.removeValue(forKey: rawId)
                completion?(resp)
            case let .request(req):
                handleIncomingRequest(req)
            case let .notification(note):
                handleIncomingNotification(note)
            }
        } catch {
            surfaceDebug(prefix: "decode failed: \(error.localizedDescription)", data: data)
        }
    }

    private func surfaceDebug(prefix: String, data: Data) {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<\(data.count) bytes>"
        surfaceDebug(prefix: prefix, text: text)
    }

    private func surfaceDebug(prefix: String, text: String) {
        let line = "\(prefix): \(text)"
        let agentId = agent.id
        let monitor = self.monitor
        DispatchQueue.main.async {
            monitor?.recordStderr(for: agentId, line: line)
        }
    }

    private func handleIncomingRequest(_ req: GeminiAcpRpc.IncomingRequest) {
        guard req.method == GeminiAcpProtocol.Method.sessionRequestPermission,
              let params = req.params,
              let parsed = try? params.decode(as: GeminiAcpProtocol.RequestPermissionRequest.self)
        else {
            // Method we don't implement: respond with an error so the agent
            // doesn't hang on a missing handler.
            let response = GeminiAcpRpc.ErrorResponse(
                id: req.id,
                error: GeminiAcpRpc.ErrorObject(
                    code: -32601,
                    message: "Method not supported by SecretAgentMan: \(req.method)",
                    data: nil
                )
            )
            writeFrame(response)
            return
        }
        let agentId = agent.id
        let acpId = req.id
        DispatchQueue.main.async { [weak monitor] in
            monitor?.applyPermissionRequest(parsed, acpRequestId: acpId, for: agentId)
        }
    }

    private func handleIncomingNotification(_ note: GeminiAcpRpc.IncomingNotification) {
        guard note.method == GeminiAcpProtocol.Method.sessionUpdate else {
            surfaceDebug(prefix: "unknown notification method", text: note.method)
            return
        }
        guard let params = note.params else {
            surfaceDebug(prefix: "session/update without params", text: note.method)
            return
        }
        do {
            let parsed = try params.decode(as: GeminiAcpProtocol.SessionNotification.self)
            let agentId = agent.id
            let monitor = self.monitor
            DispatchQueue.main.async {
                monitor?.applySessionUpdate(parsed.update, sessionId: parsed.sessionId, for: agentId)
            }
        } catch {
            surfaceDebug(
                prefix: "session/update decode failed: \(error.localizedDescription)",
                text: "(see log)"
            )
        }
    }

    private func handleProcessExit() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        pendingResponses.removeAll()
        queuedPrompts.removeAll()
        inFlightPromptId = nil
        sessionEstablished = false
        let agentId = agent.id
        DispatchQueue.main.async { [weak monitor] in
            monitor?.handleProcessExit(for: agentId)
        }
    }

    private func reportSpawnFailure(error: Error) {
        let agentId = agent.id
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak monitor] in
            monitor?.handleSpawnFailure(for: agentId, message: message)
        }
    }

    private static func geminiExecutablePath() -> String {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/gemini",
            "/usr/local/bin/gemini",
            "/opt/homebrew/bin/gemini",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "gemini"
    }
}

// swiftlint:enable file_length
