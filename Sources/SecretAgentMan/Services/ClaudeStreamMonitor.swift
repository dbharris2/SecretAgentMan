// swiftlint:disable file_length
//
// Follow-up: extract the static parsing helpers (transcriptItems,
// hydrateTranscriptItems, toolUseSummary, todoWriteSummary, formatToolInput,
// unwrapSlashCommand, friendlyModelName) into ClaudeStreamMonitor+Parsing.swift.
// They account for ~300 lines and are pure functions over typed
// ClaudeProtocol values, so they extract cleanly. Out of scope for the
// protocol-typing work tracked in docs/claude-protocol-sdk-plan.md.
import Foundation
import Observation

struct ClaudeApprovalRequest: Equatable {
    let agentId: UUID
    let requestId: String
    let toolName: String
    let displayName: String
    let inputDescription: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestId == rhs.requestId
    }
}

struct ClaudeElicitationRequest: Equatable {
    let agentId: UUID
    let requestId: String
    let message: String
    let options: [CodexUserInputOption]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestId == rhs.requestId
    }
}

@MainActor @Observable
final class ClaudeStreamMonitor {
    @ObservationIgnored var onStateChange: ((UUID, AgentState) -> Void)?
    @ObservationIgnored var onSessionReady: ((UUID, String) -> Void)?
    @ObservationIgnored var onSessionConflict: ((UUID) -> Void)?
    @ObservationIgnored var onSessionEvent: ((UUID, SessionEvent) -> Void)?

    // Load-bearing: the monitor needs the original request to resolve
    // approvals/elicitations via `observers[agentId]?.respondToApproval(...)`
    // using provider-specific fields like `requestId`.
    private(set) var pendingApprovalRequests: [UUID: ClaudeApprovalRequest] = [:]
    private(set) var pendingElicitations: [UUID: ClaudeElicitationRequest] = [:]
    private(set) var runtimeStates: [UUID: AgentState] = [:]

    struct SlashCommand {
        let name: String
        let description: String
        let argumentHint: String
    }

    private(set) var slashCommands: [SlashCommand] = []
    private(set) var permissionModes: [UUID: String] = [:]

    static let permissionModes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]
    static let defaultPermissionMode = permissionModes[0]

    @ObservationIgnored private var observers: [UUID: Observer] = [:]

    // Normalized event emission state (Phase 1 dual-emit migration).
    // Visibility relaxed from `private` so the ClaudeStreamMonitor+SessionEvents
    // extension in a separate file can access them.
    @ObservationIgnored var activeStreamingId: [UUID: String] = [:]
    @ObservationIgnored var lastStreamingText: [UUID: String] = [:]
    @ObservationIgnored var lastFinalizedStreamId: [UUID: String] = [:]

    func syncMonitoredAgents(_ agents: [Agent]) {
        let desired = Dictionary(
            uniqueKeysWithValues: agents.compactMap { agent -> (UUID, Agent)? in
                guard agent.provider == .claude,
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
        guard agent.provider == .claude else { return }

        if let observer = observers[agent.id] {
            // Don't retry if the session ID is locked by an orphaned process
            guard !observer.hasSessionConflict else { return }
            observer.update(agent: agent)
            observer.start()
            return
        }

        let observer = Observer(agent: agent, delegate: makeObserverDelegate())
        observers[agent.id] = observer

        // Hydrate transcript from session file in background (avoid blocking main thread)
        if agent.hasLaunched, let sessionId = agent.sessionId {
            let agentId = agent.id
            let sessionDir = SessionFileDetector.claudeProjectDir(for: agent.folder)
            Task.detached {
                let hydrateStart = CFAbsoluteTimeGetCurrent()
                let items = Self.hydrateTranscriptItems(
                    sessionDir: sessionDir, sessionId: sessionId
                )
                PerfLogger.log("ClaudeStreamMonitor.hydrateTranscriptItems", start: hydrateStart, details: "agent=\(agentId.uuidString)")
                guard !items.isEmpty else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for item in items {
                        self.emitTranscriptItem(agentId, item: item)
                    }
                }
            }
        }

        observer.start()
    }

    private func makeObserverDelegate() -> ObserverDelegate {
        ObserverDelegate(
            stateChanged: { [weak self] id, state in
                Task { @MainActor in
                    guard let self else { return }
                    self.runtimeStates[id] = state
                    self.onStateChange?(id, state)
                    self.emitRunStateChanged(id, state: state)
                }
            },
            sessionReady: { [weak self] id, sessionId in
                Task { @MainActor in
                    guard let self else { return }
                    self.onSessionReady?(id, sessionId)
                    self.emit(.sessionReady(sessionId: sessionId), for: id)
                }
            },
            transcriptItem: { [weak self] id, item in
                Task { @MainActor in
                    self?.emitTranscriptItem(id, item: item)
                }
            },
            approvalRequest: { [weak self] id, request in
                Task { @MainActor in
                    guard let self else { return }
                    self.pendingApprovalRequests[id] = request
                    self.emit(.promptPresented(.approval(Self.mapApprovalPrompt(request))), for: id)
                }
            },
            approvalResolved: { [weak self] id in
                Task { @MainActor in
                    guard let self else { return }
                    if let pending = self.pendingApprovalRequests[id] {
                        self.emit(.promptResolved(id: pending.requestId), for: id)
                    }
                    self.pendingApprovalRequests.removeValue(forKey: id)
                }
            },
            elicitationRequest: { [weak self] id, request in
                Task { @MainActor in
                    guard let self else { return }
                    self.pendingElicitations[id] = request
                    self.emit(.promptPresented(.userInput(Self.mapElicitationPrompt(request))), for: id)
                }
            },
            elicitationResolved: { [weak self] id in
                Task { @MainActor in
                    guard let self else { return }
                    if let pending = self.pendingElicitations[id] {
                        self.emit(.promptResolved(id: pending.requestId), for: id)
                    }
                    self.pendingElicitations.removeValue(forKey: id)
                }
            },
            streamingText: { [weak self] id, text in
                Task { @MainActor in
                    self?.emitStreamingText(text, for: id)
                }
            },
            streamingFinished: { [weak self] id in
                Task { @MainActor in
                    self?.emitStreamingFinalize(for: id)
                }
            },
            activeToolChanged: { [weak self] id, name in
                Task { @MainActor in self?.applyActiveTool(name, for: id) }
            },
            permissionModeChanged: { [weak self] id, mode in
                Task { @MainActor in self?.applyPermissionMode(mode, for: id) }
            },
            modelInfo: { [weak self] id, model, contextPct in
                Task { @MainActor in self?.applyModelInfo(id: id, model: model, contextPct: contextPct) }
            },
            slashCommands: { [weak self] commands in
                Task { @MainActor in self?.applySlashCommands(commands) }
            },
            sessionConflict: { [weak self] id in
                Task { @MainActor in self?.onSessionConflict?(id) }
            }
        )
    }

    private func applyActiveTool(_ name: String?, for agentId: UUID) {
        var update = SessionMetadataUpdate()
        update.activeToolName = name.map { .set($0) } ?? .clear
        emit(.metadataUpdated(update), for: agentId)
    }

    private func applyPermissionMode(_ mode: String, for agentId: UUID) {
        permissionModes[agentId] = mode
        var update = SessionMetadataUpdate()
        update.permissionMode = .set(mode)
        emit(.metadataUpdated(update), for: agentId)
    }

    private func applyModelInfo(id: UUID, model: String, contextPct: Double) {
        var update = SessionMetadataUpdate()
        if !model.isEmpty { update.displayModelName = .set(model) }
        update.contextPercentUsed = .set(contextPct)
        emit(.metadataUpdated(update), for: id)
    }

    private func applySlashCommands(_ commands: [ClaudeProtocol.SlashCommand]) {
        slashCommands = commands.map { command in
            SlashCommand(
                name: command.name,
                description: command.description ?? "",
                argumentHint: command.argumentHint ?? ""
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Fan out to every monitored agent — Claude's slash-command list is
        // monitor-wide, but the normalized snapshot is per-agent.
        let normalized = slashCommands.map {
            SessionSlashCommand(name: $0.name, description: $0.description)
        }
        var update = SessionMetadataUpdate()
        update.slashCommands = .set(normalized)
        for agentId in observers.keys {
            emit(.metadataUpdated(update), for: agentId)
        }
    }

    nonisolated static func hydrateTranscriptItems(
        sessionDir: URL,
        sessionId: String
    ) -> [CodexTranscriptItem] {
        let filePath = sessionDir.appendingPathComponent("\(sessionId).jsonl").path
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8)
        else { return [] }

        var items: [CodexTranscriptItem] = []
        for line in content.split(separator: "\n") {
            guard let event = try? ClaudeProtocol.decodeLine(String(line)) else { continue }

            switch event {
            case let .assistant(message):
                items.append(contentsOf: transcriptItems(fromAssistantEvent: message))
            case let .user(message):
                // User-typed messages have a `userType`; tool results don't.
                if message.userType != nil {
                    // Skip CLI-injected meta messages (slash-command skill bodies, image
                    // placeholders). Live streaming never surfaces these; hydration shouldn't either.
                    if message.isMeta == true { continue }
                    let text = userTypedText(from: message)
                    guard !text.isEmpty else { continue }
                    items.append(CodexTranscriptItem(
                        id: message.uuid ?? UUID().uuidString,
                        role: .user,
                        text: unwrapSlashCommand(text)
                    ))
                } else if case let .blocks(blocks) = message.message?.content {
                    // Tool result — only surface errors during hydration.
                    for block in blocks {
                        guard case let .toolResult(result) = block, result.isError == true else { continue }
                        guard !result.text.isEmpty else { continue }
                        items.append(CodexTranscriptItem(
                            id: UUID().uuidString, role: .system, text: "Error: \(result.text)"
                        ))
                    }
                }
            default:
                continue
            }
        }
        return items
    }

    private nonisolated static func userTypedText(from message: ClaudeProtocol.MessageEvent) -> String {
        guard let content = message.message?.content else { return "" }
        switch content {
        case let .text(str):
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .blocks(blocks):
            let joined = blocks.compactMap { block -> String? in
                if case let .text(t) = block { return t }
                return nil
            }.joined()
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func stopAll() {
        for observer in observers.values {
            observer.stop()
        }
        observers.removeAll()
    }

    func removeObserver(for agentId: UUID) {
        observers.removeValue(forKey: agentId)?.stop()
        pendingApprovalRequests.removeValue(forKey: agentId)
        pendingElicitations.removeValue(forKey: agentId)
        runtimeStates.removeValue(forKey: agentId)
        permissionModes.removeValue(forKey: agentId)
        activeStreamingId.removeValue(forKey: agentId)
        lastStreamingText.removeValue(forKey: agentId)
        lastFinalizedStreamId.removeValue(forKey: agentId)
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
        emit(.transcriptUpsert(Self.mapTranscriptItem(item)), for: agentId)
    }

    func sendMessage(for agentId: UUID, text: String, images: [(Data, String)] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let userItem = CodexTranscriptItem(
            id: UUID().uuidString,
            role: .user,
            text: trimmed,
            images: images.map(\.0)
        )
        emit(.transcriptUpsert(Self.mapTranscriptItem(userItem)), for: agentId)
        // Immediately show "thinking" — don't wait for the first stream event.
        runtimeStates[agentId] = .active
        onStateChange?(agentId, .active)
        emitRunStateChanged(agentId, state: .active)
        observers[agentId]?.sendMessage(trimmed, images: images)
    }

    func respondToApproval(for agentId: UUID, accept: Bool) {
        observers[agentId]?.respondToApproval(accept: accept)
    }

    func setPermissionMode(for agentId: UUID, mode: String) {
        observers[agentId]?.setPermissionMode(mode)
        permissionModes[agentId] = mode
    }

    func respondToElicitation(for agentId: UUID, answer: String) {
        guard let request = pendingElicitations[agentId] else { return }
        let userItem = CodexTranscriptItem(id: UUID().uuidString, role: .user, text: answer)
        emit(.transcriptUpsert(Self.mapTranscriptItem(userItem)), for: agentId)
        observers[agentId]?.respondToElicitation(requestId: request.requestId, answer: answer)
        emit(.promptResolved(id: request.requestId), for: agentId)
        pendingElicitations.removeValue(forKey: agentId)
        runtimeStates[agentId] = .active
        onStateChange?(agentId, .active)
        emitRunStateChanged(agentId, state: .active)
    }

    // MARK: - Static Parsing Helpers

    nonisolated static func approvalRequest(
        agentId: UUID,
        requestId: String,
        permission: ClaudeProtocol.PermissionRequest
    ) -> ClaudeApprovalRequest {
        ClaudeApprovalRequest(
            agentId: agentId,
            requestId: requestId,
            toolName: permission.toolName,
            displayName: permission.displayName ?? permission.toolName,
            inputDescription: formatToolInput(permission.input)
        )
    }

    nonisolated static func transcriptItems(
        fromAssistantEvent message: ClaudeProtocol.MessageEvent
    ) -> [CodexTranscriptItem] {
        guard case let .blocks(blocks) = message.message?.content else { return [] }
        let baseId = message.uuid ?? UUID().uuidString
        var items: [CodexTranscriptItem] = []

        for (index, block) in blocks.enumerated() {
            switch block {
            case let .text(text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                items.append(CodexTranscriptItem(
                    id: "\(baseId)-text-\(index)",
                    role: .assistant,
                    text: text
                ))
            case let .toolUse(use):
                let summary = toolUseSummary(use: use)
                // AskUserQuestion and TodoWrite are Claude communicating with the user —
                // show as assistant messages so they aren't collapsed into the tool drawer.
                let role: CodexTranscriptRole = (use.name == "AskUserQuestion" || use.name == "TodoWrite") ? .assistant : .system
                items.append(CodexTranscriptItem(
                    id: "\(baseId)-tool-\(index)",
                    role: role,
                    text: summary,
                    toolName: use.name
                ))
            case .toolResult, .unknown:
                break
            }
        }

        return items
    }

    /// Claude Code rewrites user-typed slash commands into a wrapper like
    /// `<command-message>foo</command-message><command-name>/foo</command-name><command-args>…</command-args>`
    /// (element order varies) before writing them to the jsonl transcript. Live
    /// streaming shows the original typed text; on reload we want to match.
    nonisolated static func unwrapSlashCommand(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<command-name>"),
              let range = trimmed.range(
                  of: #"<command-name>([^<]+)</command-name>"#,
                  options: .regularExpression
              )
        else { return text }
        let name = trimmed[range]
            .replacingOccurrences(of: "<command-name>", with: "")
            .replacingOccurrences(of: "</command-name>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimmed
            .replacingOccurrences(
                of: #"<command-(?:message|name|args)>[^<]*</command-(?:message|name|args)>"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, remainder.isEmpty else { return text }
        return name
    }

    private nonisolated static func toolUseSummary(use: ClaudeProtocol.ToolUse) -> String {
        let input = use.input
        switch use.name {
        case "Bash":
            let cmd = input?["command"]?.stringValue ?? ""
            let truncated = cmd.count > 200 ? String(cmd.prefix(200)) + "…" : cmd
            return "💻 **Bash**: `\(truncated)`"
        case "Read":
            return "👀 **Read**: \(input?["file_path"]?.stringValue ?? "")"
        case "Write":
            return "✏️ **Write**: \(input?["file_path"]?.stringValue ?? "")"
        case "Edit":
            return "📝 **Edit**: \(input?["file_path"]?.stringValue ?? "")"
        case "Grep":
            return "🔍 **Grep**: `\(input?["pattern"]?.stringValue ?? "")`"
        case "Glob":
            return "🗂️ **Glob**: `\(input?["pattern"]?.stringValue ?? "")`"
        case "AskUserQuestion":
            if let question = input?["questions"]?.arrayValue?.first?["question"]?.stringValue {
                return "❓ **Question**: \(question)"
            }
            return "❓ **Question**"
        case "TodoWrite":
            return todoWriteSummary(input: input)
        case "ToolSearch":
            return "🧰 **ToolSearch**: `\(input?["query"]?.stringValue ?? "")`"
        case "Agent":
            return "🤖 **Agent**: \(input?["description"]?.stringValue ?? "")"
        case "WebFetch":
            return "🌐 **WebFetch**: \(input?["url"]?.stringValue ?? "")"
        case "WebSearch":
            return "🔎 **WebSearch**: `\(input?["query"]?.stringValue ?? "")`"
        case "TaskCreate", "TaskUpdate":
            let subject = input?["subject"]?.stringValue ?? input?["taskId"]?.stringValue ?? ""
            return "✨ **\(use.name)**: \(subject)"
        default:
            if let dict = input?.objectValue, !dict.isEmpty {
                let summary = dict.prefix(3).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                let truncated = summary.count > 100 ? String(summary.prefix(100)) + "…" : summary
                return "⚙️ **\(use.name)**: \(truncated)"
            }
            return "⚙️ **\(use.name)**"
        }
    }

    private nonisolated static func todoWriteSummary(input: JSONValue?) -> String {
        guard let todos = input?["todos"]?.arrayValue, !todos.isEmpty else {
            return "**TODO list**"
        }
        let completed = todos.count(where: { $0["status"]?.stringValue == "completed" })
        let inProgress = todos.count(where: { $0["status"]?.stringValue == "in_progress" })
        var segments: [String] = []
        if inProgress > 0 { segments.append("\(inProgress) in progress") }
        segments.append("\(completed)/\(todos.count) complete")
        let header = "**TODO list** (\(segments.joined(separator: ", ")))"

        let rows = todos.map { todo -> String in
            let status = todo["status"]?.stringValue ?? "pending"
            let content = todo["content"]?.stringValue ?? ""
            let activeForm = todo["activeForm"]?.stringValue ?? content
            switch status {
            case "completed": return "- ✅ \(content)"
            case "in_progress": return "- 🔄 **\(activeForm)**"
            default: return "- ⬜ \(content)"
            }
        }
        return ([header] + rows).joined(separator: "\n")
    }

    nonisolated static func friendlyModelName(_ raw: String) -> String {
        // "claude-opus-4-6[1m]" → "Opus 4.6 (1M)"
        var name = raw.replacingOccurrences(of: "claude-", with: "")
        var contextSuffix = ""
        if let bracket = name.range(of: "\\[.*\\]", options: .regularExpression) {
            let inside = name[bracket].dropFirst().dropLast().uppercased()
            contextSuffix = " (\(inside))"
            name.removeSubrange(bracket)
        }
        let parts = name.split(separator: "-")
        if parts.count >= 3 {
            return "\(parts[0].capitalized) \(parts[1]).\(parts[2])\(contextSuffix)"
        }
        return name.capitalized + contextSuffix
    }

    private nonisolated static func formatToolInput(_ input: JSONValue) -> String {
        guard case let .object(dict) = input else { return "" }
        return dict.map { key, value in
            let valueStr: String = if case let .string(str) = value {
                str.count > 200 ? String(str.prefix(200)) + "..." : str
            } else {
                String(describing: value)
            }
            return "\(key): \(valueStr)"
        }
        .joined(separator: "\n")
    }
}

// MARK: - Observer Types

private struct ObserverDelegate {
    let stateChanged: (UUID, AgentState) -> Void
    let sessionReady: (UUID, String) -> Void
    let transcriptItem: (UUID, CodexTranscriptItem) -> Void
    let approvalRequest: (UUID, ClaudeApprovalRequest) -> Void
    let approvalResolved: (UUID) -> Void
    let elicitationRequest: (UUID, ClaudeElicitationRequest) -> Void
    let elicitationResolved: (UUID) -> Void
    let streamingText: (UUID, String) -> Void
    let streamingFinished: (UUID) -> Void
    let activeToolChanged: (UUID, String?) -> Void
    let permissionModeChanged: (UUID, String) -> Void
    let modelInfo: (UUID, String, Double) -> Void
    let slashCommands: ([ClaudeProtocol.SlashCommand]) -> Void
    let sessionConflict: (UUID) -> Void
}

private struct PendingApproval {
    let requestId: String
    let toolInput: JSONValue
}

private struct PendingElicitation {
    let requestId: String
    let toolInput: JSONValue
    let questionText: String
}

// MARK: - Observer

private final class Observer: @unchecked Sendable {
    private(set) var agent: Agent
    private let delegate: ObserverDelegate

    private var process: Process?
    private var stdoutPipe = Pipe()
    private var stderrPipe = Pipe()
    private var stdinPipe = Pipe()
    private let queue: DispatchQueue

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var pendingApproval: PendingApproval?
    private var pendingElicitation: PendingElicitation?
    private var pendingMessages: [String] = []
    private var didLaunch = false
    /// Set when the session ID is already held by another process — prevents retries.
    private(set) var hasSessionConflict = false
    private var lastObservedState: AgentState?
    private var currentStreamingText = ""
    private var lastStreamingFlush = Date.distantPast

    init(agent: Agent, delegate: ObserverDelegate) {
        self.agent = agent
        self.delegate = delegate
        queue = DispatchQueue(label: "ClaudeStreamMonitor.\(agent.id.uuidString)")
    }

    func start() {
        if let existing = process, existing.isRunning { return }
        guard !hasSessionConflict else { return }

        // Create fresh pipes and process for each launch — Process is single-use.
        let newProcess = Process()
        let newStdout = Pipe()
        let newStderr = Pipe()
        let newStdin = Pipe()

        newProcess.executableURL = URL(fileURLWithPath: ProviderExecutableLocator.executablePath(for: .claude))
        newProcess.arguments = buildArguments()
        newProcess.currentDirectoryURL = agent.folder
        newProcess.environment = ProcessInfo.processInfo.environment
        newProcess.standardInput = newStdin
        newProcess.standardOutput = newStdout
        newProcess.standardError = newStderr

        // Reset buffers for the new process
        queue.sync {
            self.stdoutBuffer = Data()
            self.stderrBuffer = Data()
        }

        newStdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        newStderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }

        newProcess.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if proc.terminationStatus != 0 {
                let errorText = self.queue.sync {
                    String(data: self.stderrBuffer, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }

                // Detect "session already in use" — stop retrying and signal the coordinator
                if errorText.contains("already in use") {
                    self.hasSessionConflict = true
                    self.delegate.sessionConflict(self.agent.id)
                    return
                }

                if !errorText.isEmpty {
                    let truncated = errorText.count > 500
                        ? String(errorText.prefix(500)) + "…"
                        : errorText
                    let item = CodexTranscriptItem(
                        id: UUID().uuidString,
                        role: .system,
                        text: "Process exited with error:\n\(truncated)"
                    )
                    self.delegate.transcriptItem(self.agent.id, item)
                }
                self.publishIfChanged(.error)
            } else {
                self.publishIfChanged(.finished)
            }
        }

        // Swap in the new pipes/process before launching
        self.process = newProcess
        self.stdoutPipe = newStdout
        self.stderrPipe = newStderr
        self.stdinPipe = newStdin

        do {
            try newProcess.run()
        } catch {
            delegate.stateChanged(agent.id, .error)
            return
        }

        didLaunch = true
        sendInitializeRequest()
        flushPendingMessages()
    }

    private func sendInitializeRequest() {
        writeEncodable(ClaudeProtocol.ControlRequest.initialize())
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        pendingApproval = nil
        pendingElicitation = nil
        pendingMessages.removeAll()
        didLaunch = false
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }

    func interrupt() {
        queue.async { [weak self] in
            guard let self, let proc = self.process, proc.isRunning else { return }
            self.writeEncodable(ClaudeProtocol.ControlRequest.interrupt())
        }
    }

    func update(agent: Agent) {
        self.agent = agent
    }

    func sendMessage(_ text: String, images: [(Data, String)] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !didLaunch {
            pendingMessages.append(trimmed)
            start()
            return
        }

        writeUserMessage(trimmed, images: images)
    }

    func setPermissionMode(_ mode: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeEncodable(ClaudeProtocol.ControlRequest.setPermissionMode(mode))
            self.delegate.permissionModeChanged(self.agent.id, mode)
        }
    }

    func respondToApproval(accept: Bool) {
        queue.async { [weak self] in
            guard let self, let pending = self.pendingApproval else { return }
            self.pendingApproval = nil
            self.sendPermissionResponse(requestId: pending.requestId, allow: accept, toolInput: pending.toolInput)
            self.delegate.approvalResolved(self.agent.id)
            if accept {
                self.publishIfChanged(.active)
            }
        }
    }

    private func sendPermissionResponse(requestId: String, allow: Bool, toolInput: JSONValue) {
        let message = if allow {
            ClaudeProtocol.PermissionResponse.allow(requestId: requestId, updatedInput: toolInput)
        } else {
            ClaudeProtocol.PermissionResponse.deny(requestId: requestId)
        }
        writeEncodable(message)
    }

    // MARK: - Process Arguments

    private func buildArguments() -> [String] {
        var args = [
            "--print",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", "default",
            "--verbose",
        ]

        if agent.hasLaunched, let sessionId = agent.sessionId {
            args.append(contentsOf: ["--resume", sessionId])
        } else if let sessionId = agent.sessionId {
            args.append(contentsOf: ["--session-id", sessionId])
        }

        let pluginDir = (UserDefaults.standard.string(forKey: UserDefaultsKeys.claudePluginDirectory) ?? "")
            .replacingOccurrences(of: "~", with: NSHomeDirectory())
        if !pluginDir.isEmpty {
            args.append(contentsOf: ["--plugin-dir", pluginDir])
        }

        let mcpConfigURL = agent.folder.appendingPathComponent(".mcp.json")
        if FileManager.default.fileExists(atPath: mcpConfigURL.path) {
            args.append(contentsOf: ["--mcp-config", mcpConfigURL.path])
        }

        return args
    }

    // MARK: - Stdin Writes

    private func writeUserMessage(_ text: String, images: [(Data, String)] = []) {
        writeEncodable(ClaudeProtocol.UserMessage.build(text: text, images: images))
    }

    private func writeEncodable(_ value: Encodable) {
        guard let data = ClaudeProtocol.encodeLine(value) else { return }
        stdinPipe.fileHandleForWriting.write(data)
    }

    private func flushPendingMessages() {
        guard didLaunch, !pendingMessages.isEmpty else { return }
        let messages = pendingMessages
        pendingMessages.removeAll()
        for message in messages {
            writeUserMessage(message)
        }
    }

    // MARK: - Stdout Parsing

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.stderrBuffer.append(data)
            // Keep only the last 4KB to prevent unbounded growth
            if self.stderrBuffer.count > 4096 {
                self.stderrBuffer = self.stderrBuffer.suffix(4096)
            }
        }
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.stdoutBuffer.append(data)
            self.processBufferedLines()
        }
    }

    private func processBufferedLines() {
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8)
            else { continue }
            handleJSONLine(line)
        }
    }

    private func handleJSONLine(_ line: String) {
        let event: ClaudeProtocol.Event?
        do {
            event = try ClaudeProtocol.decodeLine(line)
        } catch {
            // Skip and log — one bad line shouldn't kill the stream.
            // Note: malformed control_request frames can leave the user waiting
            // on an approval that never arrives; surface those explicitly when
            // typed payloads land in Phase 2.
            NSLog("[Claude] dropped malformed JSONL: \(error)")
            return
        }
        guard let event else { return }

        switch event {
        case let .system(system):
            handleSystemEvent(system)
        case let .assistant(message):
            handleAssistantEvent(message)
        case let .user(message):
            handleUserEvent(message)
        case let .streamEvent(stream):
            handleStreamEvent(stream)
        case let .controlRequest(controlEvent):
            handleControlRequest(controlEvent)
        case let .controlResponse(response):
            handleControlResponse(response)
        case let .result(result):
            handleResultEvent(result)
        case .unknown:
            break
        }
    }

    // MARK: - Event Handlers

    private func handleSystemEvent(_ event: ClaudeProtocol.SystemEvent) {
        if let sessionId = event.sessionId, !sessionId.isEmpty {
            delegate.sessionReady(agent.id, sessionId)
        }
        if let model = event.model {
            delegate.modelInfo(agent.id, ClaudeStreamMonitor.friendlyModelName(model), 0)
        }
        if let mode = event.permissionMode {
            delegate.permissionModeChanged(agent.id, mode)
        }
        // Don't publish .active here — system events are metadata (session info,
        // config acks). The actual work events (handleStreamEvent, handleAssistantEvent)
        // publish .active when Claude starts processing. Publishing here would
        // spuriously show the "thinking" indicator on permission mode changes.
    }

    private func handleAssistantEvent(_ message: ClaudeProtocol.MessageEvent) {
        finalizeStreaming()

        for item in ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: message) {
            delegate.transcriptItem(agent.id, item)
        }
        publishIfChanged(.active)
    }

    private func handleUserEvent(_ message: ClaudeProtocol.MessageEvent) {
        // Only surface error tool results — successful results are noise.
        // The "thinking" bubble covers the gap while tools execute.
        guard case let .blocks(blocks) = message.message?.content else { return }

        for block in blocks {
            guard case let .toolResult(result) = block, result.isError == true else { continue }
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let truncated = trimmed.count > 500 ? String(trimmed.prefix(500)) + "…" : trimmed
            let item = CodexTranscriptItem(
                id: UUID().uuidString,
                role: .system,
                text: "Error: \(truncated)"
            )
            delegate.transcriptItem(agent.id, item)
        }
    }

    private func handleStreamEvent(_ stream: ClaudeProtocol.StreamEvent) {
        switch stream {
        case let .contentBlockStart(start):
            switch start.contentBlock {
            case .text:
                delegate.activeToolChanged(agent.id, nil)
            case let .toolUse(name):
                if let name {
                    delegate.activeToolChanged(agent.id, name)
                }
            case .unknown:
                break
            }

        case let .textDelta(text):
            guard !text.isEmpty else { break }
            currentStreamingText.append(text)
            let now = Date()
            if now.timeIntervalSince(lastStreamingFlush) > 0.05 {
                lastStreamingFlush = now
                delegate.streamingText(agent.id, currentStreamingText)
            }

        case .messageStop:
            finalizeStreaming()
            delegate.activeToolChanged(agent.id, nil)

        case .unknown:
            break
        }

        // Don't overwrite needsPermission/awaitingResponse — stream events
        // can arrive in the same buffer batch after a control_request.
        if pendingApproval == nil, pendingElicitation == nil {
            publishIfChanged(.active)
        }
    }

    private func handleControlRequest(_ event: ClaudeProtocol.ControlRequestEvent) {
        let requestId = event.requestId

        switch event.request {
        case let .canUseTool(permission):
            // AskUserQuestion: show options as buttons, fall back to composer for freeform
            if permission.toolName == "AskUserQuestion" {
                let parsed = try? permission.input.decode(as: ClaudeProtocol.AskUserQuestionInput.self)
                let firstQuestion = parsed?.questions.first
                let questionText = firstQuestion?.question ?? "Input requested"
                let options = (firstQuestion?.options ?? []).map { option in
                    CodexUserInputOption(label: option.label, description: option.description ?? "")
                }
                pendingElicitation = PendingElicitation(
                    requestId: requestId, toolInput: permission.input, questionText: questionText
                )
                let elicitation = ClaudeElicitationRequest(
                    agentId: agent.id,
                    requestId: requestId,
                    message: questionText,
                    options: options
                )
                delegate.elicitationRequest(agent.id, elicitation)
                publishIfChanged(.awaitingResponse)
                return
            }

            let approval = ClaudeStreamMonitor.approvalRequest(
                agentId: agent.id,
                requestId: requestId,
                permission: permission
            )
            pendingApproval = PendingApproval(requestId: requestId, toolInput: permission.input)
            delegate.approvalRequest(agent.id, approval)
            publishIfChanged(.needsPermission)

        case let .elicitation(elic):
            let elicitation = ClaudeElicitationRequest(
                agentId: agent.id,
                requestId: requestId,
                message: elic.message,
                options: []
            )
            delegate.elicitationRequest(agent.id, elicitation)
            publishIfChanged(.needsPermission)

        case .unknown:
            break
        }
    }

    func respondToElicitation(requestId: String, answer: String) {
        queue.async { [weak self] in
            guard let self, let pending = self.pendingElicitation else { return }

            // Echo Claude's original input verbatim, with `answers` merged in.
            // Tool input is always an `.object` from Claude — fall back to a
            // fresh object if it's not, so a misshapen input still produces a
            // valid permission response.
            let answers = JSONValue.object([pending.questionText: .string(answer)])
            var modified = pending.toolInput
            if case var .object(dict) = modified {
                dict["answers"] = answers
                modified = .object(dict)
            } else {
                modified = .object(["answers": answers])
            }

            self.pendingElicitation = nil
            self.sendPermissionResponse(requestId: requestId, allow: true, toolInput: modified)
            self.publishIfChanged(.active)
            self.delegate.elicitationResolved(self.agent.id)
        }
    }

    private func handleControlResponse(_ event: ClaudeProtocol.ControlResponseEvent) {
        if let commands = event.commands {
            delegate.slashCommands(commands)
        }
    }

    private func handleResultEvent(_ event: ClaudeProtocol.ResultEvent) {
        finalizeStreaming()

        if let pct = event.contextPercent {
            delegate.modelInfo(agent.id, "", pct)
        }

        delegate.activeToolChanged(agent.id, nil)
        publishIfChanged(event.isError == true ? .error : .awaitingInput)
    }

    // MARK: - Streaming Helpers

    private func finalizeStreaming() {
        guard !currentStreamingText.isEmpty else { return }
        delegate.streamingText(agent.id, currentStreamingText)
        currentStreamingText = ""
        delegate.streamingFinished(agent.id)
        lastStreamingFlush = .distantPast
    }

    private func publishIfChanged(_ state: AgentState) {
        guard lastObservedState != state else { return }
        lastObservedState = state
        delegate.stateChanged(agent.id, state)
    }
}

// swiftlint:enable file_length
