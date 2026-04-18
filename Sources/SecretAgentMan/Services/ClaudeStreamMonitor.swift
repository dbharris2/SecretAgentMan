// swiftlint:disable file_length
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

    private(set) var pendingApprovalRequests: [UUID: ClaudeApprovalRequest] = [:]
    private(set) var pendingElicitations: [UUID: ClaudeElicitationRequest] = [:]
    private(set) var transcriptItems: [UUID: [CodexTranscriptItem]] = [:]
    private(set) var runtimeStates: [UUID: AgentState] = [:]
    private(set) var streamingText: [UUID: String] = [:]
    private(set) var activeToolName: [UUID: String] = [:]
    struct SlashCommand {
        let name: String
        let description: String
        let argumentHint: String
    }

    private(set) var slashCommands: [SlashCommand] = []
    private(set) var modelNames: [UUID: String] = [:]
    private(set) var contextPercentUsed: [UUID: Double] = [:]
    private(set) var permissionModes: [UUID: String] = [:]

    static let permissionModes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]

    @ObservationIgnored private var observers: [UUID: Observer] = [:]

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

        let delegate = ObserverDelegate(
            stateChanged: { [weak self] id, state in
                Task { @MainActor in
                    self?.runtimeStates[id] = state
                    self?.onStateChange?(id, state)
                }
            },
            sessionReady: { [weak self] id, sessionId in
                Task { @MainActor in self?.onSessionReady?(id, sessionId) }
            },
            transcriptItem: { [weak self] id, item in
                Task { @MainActor in self?.transcriptItems[id, default: []].append(item) }
            },
            approvalRequest: { [weak self] id, request in
                Task { @MainActor in self?.pendingApprovalRequests[id] = request }
            },
            approvalResolved: { [weak self] id in
                Task { @MainActor in self?.pendingApprovalRequests.removeValue(forKey: id) }
            },
            elicitationRequest: { [weak self] id, request in
                Task { @MainActor in self?.pendingElicitations[id] = request }
            },
            elicitationResolved: { [weak self] id in
                Task { @MainActor in self?.pendingElicitations.removeValue(forKey: id) }
            },
            streamingText: { [weak self] id, text in
                Task { @MainActor in self?.streamingText[id] = text }
            },
            streamingFinished: { [weak self] id in
                Task { @MainActor in self?.streamingText.removeValue(forKey: id) }
            },
            activeToolChanged: { [weak self] id, name in
                Task { @MainActor in
                    if let name {
                        self?.activeToolName[id] = name
                    } else {
                        self?.activeToolName.removeValue(forKey: id)
                    }
                }
            },
            permissionModeChanged: { [weak self] id, mode in
                Task { @MainActor in self?.permissionModes[id] = mode }
            },
            modelInfo: { [weak self] id, model, contextPct in
                Task { @MainActor in
                    if !model.isEmpty { self?.modelNames[id] = model }
                    self?.contextPercentUsed[id] = contextPct
                }
            },
            slashCommands: { [weak self] commands in
                Task { @MainActor in
                    self?.slashCommands = commands.compactMap { dict in
                        guard let name = dict["name"] as? String else { return nil }
                        return SlashCommand(
                            name: name,
                            description: dict["description"] as? String ?? "",
                            argumentHint: dict["argumentHint"] as? String ?? ""
                        )
                    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            },
            sessionConflict: { [weak self] id in
                Task { @MainActor in self?.onSessionConflict?(id) }
            }
        )

        let observer = Observer(agent: agent, delegate: delegate)

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
                    self?.transcriptItems[agentId] = items
                }
            }
        }

        observer.start()
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
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            switch type {
            case "assistant":
                items.append(contentsOf: transcriptItems(fromAssistantEvent: object))
            case "user":
                // During hydration, check if this is a user-typed message or a tool result.
                // User-typed messages have "userType" field; tool results don't.
                if object["userType"] != nil {
                    if let message = object["message"] as? [String: Any] {
                        let text: String
                        if let str = message["content"] as? String {
                            text = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let blocks = message["content"] as? [[String: Any]] {
                            text = blocks.compactMap { block -> String? in
                                guard block["type"] as? String == "text" else { return nil }
                                return block["text"] as? String
                            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            continue
                        }
                        guard !text.isEmpty else { continue }
                        items.append(CodexTranscriptItem(
                            id: object["uuid"] as? String ?? UUID().uuidString,
                            role: .user,
                            text: text
                        ))
                    }
                } else {
                    // Tool result — only surface errors during hydration
                    if let message = object["message"] as? [String: Any],
                       let blocks = message["content"] as? [[String: Any]] {
                        for block in blocks where block["is_error"] as? Bool == true {
                            let text = block["content"] as? String ?? ""
                            if !text.isEmpty {
                                items.append(CodexTranscriptItem(
                                    id: UUID().uuidString, role: .system, text: "Error: \(text)"
                                ))
                            }
                        }
                    }
                }
            default:
                continue
            }
        }
        return items
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
        transcriptItems.removeValue(forKey: agentId)
        runtimeStates.removeValue(forKey: agentId)
        streamingText.removeValue(forKey: agentId)
        activeToolName.removeValue(forKey: agentId)
        modelNames.removeValue(forKey: agentId)
        contextPercentUsed.removeValue(forKey: agentId)
        permissionModes.removeValue(forKey: agentId)
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
        var items = transcriptItems[agentId, default: []]
        items.append(item)
        transcriptItems[agentId] = items
    }

    func sendMessage(for agentId: UUID, text: String, images: [(Data, String)] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcriptItems[agentId, default: []].append(
            CodexTranscriptItem(id: UUID().uuidString, role: .user, text: trimmed, images: images.map(\.0))
        )
        // Immediately show "thinking" — don't wait for the first stream event.
        runtimeStates[agentId] = .active
        onStateChange?(agentId, .active)
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
        transcriptItems[agentId, default: []].append(
            CodexTranscriptItem(id: UUID().uuidString, role: .user, text: answer)
        )
        observers[agentId]?.respondToElicitation(requestId: request.requestId, answer: answer)
        pendingElicitations.removeValue(forKey: agentId)
        runtimeStates[agentId] = .active
        onStateChange?(agentId, .active)
    }

    // MARK: - Static Parsing Helpers

    nonisolated static func approvalRequest(
        agentId: UUID,
        requestId: String,
        request: [String: Any]
    ) -> ClaudeApprovalRequest? {
        guard request["subtype"] as? String == "can_use_tool",
              let toolName = request["tool_name"] as? String
        else { return nil }

        let displayName = request["display_name"] as? String ?? toolName
        let input = request["input"] as? [String: Any]
        let inputDescription = input.map { formatToolInput($0) } ?? ""

        return ClaudeApprovalRequest(
            agentId: agentId,
            requestId: requestId,
            toolName: toolName,
            displayName: displayName,
            inputDescription: inputDescription
        )
    }

    nonisolated static func transcriptItems(
        fromAssistantEvent event: [String: Any]
    ) -> [CodexTranscriptItem] {
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        let baseId = event["uuid"] as? String ?? UUID().uuidString
        var items: [CodexTranscriptItem] = []

        for (index, block) in content.enumerated() {
            let blockType = block["type"] as? String ?? ""
            switch blockType {
            case "text":
                if let text = block["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(CodexTranscriptItem(
                        id: "\(baseId)-text-\(index)",
                        role: .assistant,
                        text: text
                    ))
                }
            case "tool_use":
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any]
                let summary = toolUseSummary(name: name, input: input)
                // AskUserQuestion is Claude asking the user — show as assistant message
                let role: CodexTranscriptRole = name == "AskUserQuestion" ? .assistant : .system
                items.append(CodexTranscriptItem(
                    id: "\(baseId)-tool-\(index)",
                    role: role,
                    text: summary
                ))
            default:
                break
            }
        }

        return items
    }

    private nonisolated static func toolUseSummary(name: String, input: [String: Any]?) -> String {
        switch name {
        case "Bash":
            let cmd = input?["command"] as? String ?? ""
            let truncated = cmd.count > 200 ? String(cmd.prefix(200)) + "…" : cmd
            return "**Bash**: `\(truncated)`"
        case "Read":
            let path = input?["file_path"] as? String ?? ""
            return "**Read**: \(path)"
        case "Write":
            let path = input?["file_path"] as? String ?? ""
            return "**Write**: \(path)"
        case "Edit":
            let path = input?["file_path"] as? String ?? ""
            return "**Edit**: \(path)"
        case "Grep":
            let pattern = input?["pattern"] as? String ?? ""
            return "**Grep**: `\(pattern)`"
        case "Glob":
            let pattern = input?["pattern"] as? String ?? ""
            return "**Glob**: `\(pattern)`"
        case "AskUserQuestion":
            if let questions = input?["questions"] as? [[String: Any]],
               let first = questions.first,
               let question = first["question"] as? String {
                return "**Question**: \(question)"
            }
            return "**Question**"
        case "ToolSearch":
            let query = input?["query"] as? String ?? ""
            return "**ToolSearch**: `\(query)`"
        case "Agent":
            let desc = input?["description"] as? String ?? ""
            return "**Agent**: \(desc)"
        case "WebFetch":
            let url = input?["url"] as? String ?? ""
            return "**WebFetch**: \(url)"
        case "WebSearch":
            let query = input?["query"] as? String ?? ""
            return "**WebSearch**: `\(query)`"
        case "TaskCreate", "TaskUpdate":
            let subject = input?["subject"] as? String ?? input?["taskId"] as? String ?? ""
            return "**\(name)**: \(subject)"
        default:
            if let input, !input.isEmpty {
                let summary = input.prefix(3).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                let truncated = summary.count > 100 ? String(summary.prefix(100)) + "…" : summary
                return "**\(name)**: \(truncated)"
            }
            return "**\(name)**"
        }
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

    private nonisolated static func formatToolInput(_ input: [String: Any]) -> String {
        input.map { key, value in
            let valueStr = if let str = value as? String {
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
    let slashCommands: ([[String: Any]]) -> Void
    let sessionConflict: (UUID) -> Void
}

private struct PendingApproval {
    let requestId: String
    let toolInput: [String: Any]
}

private struct PendingElicitation {
    let requestId: String
    let toolInput: [String: Any]
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

        newProcess.executableURL = URL(fileURLWithPath: AgentProcessManager.executablePath(for: .claude))
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

    private func sendPermissionResponse(requestId: String, allow: Bool, toolInput: [String: Any]) {
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

    /// Fallback for cases still using [String: Any] (e.g. AskUserQuestion auto-allow with dynamic toolInput)
    private func writeJSONObject(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        stdinPipe.fileHandleForWriting.write(Data(line.utf8))
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
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = object["type"] as? String
        else { return }

        switch eventType {
        case "system":
            handleSystemEvent(object)
        case "assistant":
            handleAssistantEvent(object)
        case "user":
            handleUserEvent(object)
        case "stream_event":
            handleStreamEvent(object)
        case "control_request":
            handleControlRequest(object)
        case "control_response":
            handleControlResponse(object)
        case "result":
            handleResultEvent(object)
        default:
            break
        }
    }

    // MARK: - Event Handlers

    private func handleSystemEvent(_ event: [String: Any]) {
        if let sessionId = event["session_id"] as? String, !sessionId.isEmpty {
            delegate.sessionReady(agent.id, sessionId)
        }
        if let model = event["model"] as? String {
            delegate.modelInfo(agent.id, ClaudeStreamMonitor.friendlyModelName(model), 0)
        }
        if let mode = event["permissionMode"] as? String {
            delegate.permissionModeChanged(agent.id, mode)
        }
        // Don't publish .active here — system events are metadata (session info,
        // config acks). The actual work events (handleStreamEvent, handleAssistantEvent)
        // publish .active when Claude starts processing. Publishing here would
        // spuriously show the "thinking" indicator on permission mode changes.
    }

    private func handleAssistantEvent(_ event: [String: Any]) {
        finalizeStreaming()

        for item in ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: event) {
            delegate.transcriptItem(agent.id, item)
        }
        publishIfChanged(.active)
    }

    private func handleUserEvent(_ event: [String: Any]) {
        // Only surface error tool results — successful results are noise.
        // The "thinking" bubble covers the gap while tools execute.
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }

        for block in content {
            let isError = block["is_error"] as? Bool ?? false
            guard isError else { continue }
            let text = block["content"] as? String ?? block["text"] as? String ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let item = CodexTranscriptItem(
                id: UUID().uuidString,
                role: .system,
                text: "Error: \(text.count > 500 ? String(text.prefix(500)) + "…" : text)"
            )
            delegate.transcriptItem(agent.id, item)
        }
    }

    private func handleStreamEvent(_ event: [String: Any]) {
        guard let inner = event["event"] as? [String: Any],
              let innerType = inner["type"] as? String
        else { return }

        // Track active tool from content_block_start events
        if innerType == "content_block_start",
           let block = inner["content_block"] as? [String: Any],
           let blockType = block["type"] as? String {
            if blockType == "tool_use", let name = block["name"] as? String {
                delegate.activeToolChanged(agent.id, name)
            } else if blockType == "text" {
                delegate.activeToolChanged(agent.id, nil)
            }
        }

        if innerType == "content_block_delta",
           let delta = inner["delta"] as? [String: Any],
           let deltaType = delta["type"] as? String,
           deltaType == "text_delta",
           let text = delta["text"] as? String {
            currentStreamingText.append(text)

            let now = Date()
            if now.timeIntervalSince(lastStreamingFlush) > 0.05 {
                lastStreamingFlush = now
                delegate.streamingText(agent.id, currentStreamingText)
            }
        }

        if innerType == "message_stop" {
            finalizeStreaming()
            delegate.activeToolChanged(agent.id, nil)
        }

        // Don't overwrite needsPermission/awaitingResponse — stream events
        // can arrive in the same buffer batch after a control_request.
        if pendingApproval == nil, pendingElicitation == nil {
            publishIfChanged(.active)
        }
    }

    private func handleControlRequest(_ event: [String: Any]) {
        guard let requestId = event["request_id"] as? String,
              let request = event["request"] as? [String: Any],
              let subtype = request["subtype"] as? String
        else { return }

        switch subtype {
        case "can_use_tool":
            let toolName = request["tool_name"] as? String ?? ""
            let toolInput = request["input"] as? [String: Any] ?? [:]

            // AskUserQuestion: show options as buttons, fall back to composer for freeform
            if toolName == "AskUserQuestion" {
                let questions = toolInput["questions"] as? [[String: Any]] ?? []
                let firstQuestion = questions.first ?? [:]
                let questionText = firstQuestion["question"] as? String ?? "Input requested"
                let optionDicts = firstQuestion["options"] as? [[String: Any]] ?? []
                let options = optionDicts.compactMap { dict -> CodexUserInputOption? in
                    guard let label = dict["label"] as? String else { return nil }
                    return CodexUserInputOption(label: label, description: dict["description"] as? String ?? "")
                }
                pendingElicitation = PendingElicitation(
                    requestId: requestId, toolInput: toolInput, questionText: questionText
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

            guard let approval = ClaudeStreamMonitor.approvalRequest(
                agentId: agent.id,
                requestId: requestId,
                request: request
            ) else { return }
            pendingApproval = PendingApproval(requestId: requestId, toolInput: toolInput)
            delegate.approvalRequest(agent.id, approval)
            publishIfChanged(.needsPermission)

        case "elicitation":
            let message = request["message"] as? String ?? "Input requested"
            let elicitation = ClaudeElicitationRequest(
                agentId: agent.id,
                requestId: requestId,
                message: message,
                options: []
            )
            delegate.elicitationRequest(agent.id, elicitation)
            publishIfChanged(.needsPermission)

        default:
            break
        }
    }

    func respondToElicitation(requestId: String, answer: String) {
        queue.async { [weak self] in
            guard let self, let pending = self.pendingElicitation else { return }

            var modified = pending.toolInput
            modified["answers"] = [pending.questionText: answer]

            self.pendingElicitation = nil
            self.sendPermissionResponse(requestId: requestId, allow: true, toolInput: modified)
            self.publishIfChanged(.active)
            self.delegate.elicitationResolved(self.agent.id)
        }
    }

    private func handleControlResponse(_ event: [String: Any]) {
        guard let response = event["response"] as? [String: Any],
              let inner = response["response"] as? [String: Any]
        else { return }

        if let commands = inner["commands"] as? [[String: Any]] {
            delegate.slashCommands(commands)
        }

        // Extract default model display name from initialize response
        if let models = inner["models"] as? [[String: Any]] {
            let defaultModel = models.first { ($0["displayName"] as? String)?.contains("Default") == true }
                ?? models.first
            if let name = defaultModel?["displayName"] as? String {
                delegate.modelInfo(agent.id, name, 0)
            }
        }
    }

    private func handleResultEvent(_ event: [String: Any]) {
        finalizeStreaming()

        // Context window % from the last API call's actual token consumption.
        // modelUsage is cumulative across the session, so use usage.iterations instead.
        if let modelUsage = event["modelUsage"] as? [String: Any],
           let firstUsage = modelUsage.values.first as? [String: Any],
           let contextWindow = firstUsage["contextWindow"] as? Double, contextWindow > 0,
           let usage = event["usage"] as? [String: Any],
           let iterations = usage["iterations"] as? [[String: Any]],
           let lastIter = iterations.last {
            let input = lastIter["input_tokens"] as? Double ?? 0
            let cacheRead = lastIter["cache_read_input_tokens"] as? Double ?? 0
            let cacheCreate = lastIter["cache_creation_input_tokens"] as? Double ?? 0
            let output = lastIter["output_tokens"] as? Double ?? 0
            let pct = (input + cacheRead + cacheCreate + output) / contextWindow * 100
            delegate.modelInfo(agent.id, "", pct)
        }

        delegate.activeToolChanged(agent.id, nil)

        let isError = event["is_error"] as? Bool ?? false
        publishIfChanged(isError ? .error : .awaitingInput)
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
