import Foundation

enum CodexApprovalPolicy: String, CaseIterable, Codable {
    case untrusted
    case onRequest = "on-request"
    case never

    var label: String {
        switch self {
        case .untrusted: "Untrusted"
        case .onRequest: "On Request"
        case .never: "Never"
        }
    }

    var settingsDescription: String {
        switch self {
        case .untrusted:
            "Prompt for edits and other approvals."
        case .onRequest:
            "Only prompt when the agent explicitly requests approval."
        case .never:
            "Do not ask for approval. Best for trusted local sessions."
        }
    }

    static var storedValue: CodexApprovalPolicy {
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.codexApprovalPolicy),
           let policy = CodexApprovalPolicy(rawValue: raw) {
            return policy
        }
        return CodexConfigLoader.loadDefaults().approvalPolicy ?? .onRequest
    }
}

enum CodexSandboxMode: String, CaseIterable, Codable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    var label: String {
        switch self {
        case .readOnly: "Read Only"
        case .workspaceWrite: "Workspace Write"
        case .dangerFullAccess: "Danger Full Access"
        }
    }

    var settingsDescription: String {
        switch self {
        case .readOnly:
            "Codex can read files but not write anywhere or use the network."
        case .workspaceWrite:
            "Codex can write inside the project folder. `.git/` is read-only and network is blocked."
        case .dangerFullAccess:
            "No restrictions — Codex commands run with your full user privileges."
        }
    }

    static var storedValue: CodexSandboxMode {
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.codexSandboxMode),
           let mode = CodexSandboxMode(rawValue: raw) {
            return mode
        }
        return CodexConfigLoader.loadDefaults().sandboxMode ?? .workspaceWrite
    }
}

enum CodexCollaborationMode: String, CaseIterable, Codable {
    case `default`
    case plan

    var label: String {
        switch self {
        case .default: "Default"
        case .plan: "Plan"
        }
    }
}

struct CodexUserInputOption: Identifiable, Equatable {
    let label: String
    let description: String

    var id: String {
        label
    }
}

struct CodexUserInputQuestion: Identifiable, Equatable {
    let id: String
    let header: String
    let prompt: String
    let options: [CodexUserInputOption]
    let allowsOther: Bool
}

struct CodexUserInputRequest: Equatable {
    let agentId: UUID
    let threadId: String
    let turnId: String
    let itemId: String
    let questions: [CodexUserInputQuestion]
}

enum CodexTranscriptRole: String, Equatable {
    case user
    case assistant
    case system
}

struct CodexTranscriptItem: Identifiable, Equatable {
    let id: String
    let role: CodexTranscriptRole
    var text: String
    var images: [Data] = []
    var tool: CodexToolDetail?
    var toolName: String?

    var displayText: String {
        tool?.markdownText ?? text
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.role == rhs.role
            && lhs.text == rhs.text
            && lhs.tool == rhs.tool
            && lhs.toolName == rhs.toolName
    }
}

enum CodexToolDetail: Equatable {
    case command(CodexCommandToolDetail)
    case fileChange(CodexFileChangeToolDetail)

    var markdownText: String {
        switch self {
        case let .command(detail): detail.markdownText
        case let .fileChange(detail): detail.markdownText
        }
    }
}

struct CodexCommandToolDetail: Equatable {
    var command: String
    var output: String
    var status: String?
    var exitCode: Int?
    var durationMs: Double?
    var isRunning: Bool

    var markdownText: String {
        var suffixParts: [String] = []
        if isRunning {
            suffixParts.append("running")
        }
        if let status, !status.isEmpty, !isRunning {
            suffixParts.append("status: \(status)")
        }
        if let exitCode {
            suffixParts.append("exit: \(exitCode)")
        }
        if let durationMs {
            suffixParts.append("duration: \(Int(durationMs))ms")
        }
        let suffix = suffixParts.isEmpty ? "" : " (\(suffixParts.joined(separator: " · ")))"
        var parts = ["Ran command\(suffix):\n\n```sh\n\(command)\n```"]
        if let formatted = CodexAppServerMonitor.formattedCommandOutput(output) {
            parts.append("Command output:\n\n```text\n\(formatted)\n```")
        }
        return parts.joined(separator: "\n\n")
    }
}

struct CodexFileChangeToolDetail: Equatable {
    var patch: String
    var status: String?
    var isRunning: Bool

    var markdownText: String {
        let suffix = isRunning ? " (applying)" : ""
        let trimmed = CodexAppServerMonitor.formattedFileChangeSummary(patch)
        return "Applied file changes\(suffix):\n\n```diff\n\(trimmed)\n```"
    }
}

enum CodexApprovalKind: Equatable {
    case command(command: String?, reason: String?)
    case fileChange(reason: String?, grantRoot: String?)
    case unsupportedPermissions(reason: String?)

    var title: String {
        switch self {
        case .command:
            "Command Approval"
        case .fileChange:
            "File Change Approval"
        case .unsupportedPermissions:
            "Permissions Request"
        }
    }

    var detail: String {
        switch self {
        case let .command(command, reason):
            return [command, reason].compactMap(\.self).joined(separator: "\n\n")
        case let .fileChange(reason, grantRoot):
            let parts = [
                reason,
                grantRoot.map { "Write scope: \($0)" },
            ].compactMap(\.self)
            return parts.isEmpty ? "Codex requested approval for a file change." : parts.joined(separator: "\n\n")
        case let .unsupportedPermissions(reason):
            return reason ?? "Codex requested additional permissions."
        }
    }

    var supportsDecisions: Bool {
        switch self {
        case .unsupportedPermissions:
            false
        default:
            true
        }
    }

    var declineLabel: String {
        switch self {
        case .unsupportedPermissions:
            "Dismiss"
        case .command, .fileChange:
            "No, and tell Codex what to do differently"
        }
    }
}

struct CodexApprovalRequest: Equatable {
    let agentId: UUID
    let requestId: Int
    let threadId: String
    let turnId: String
    let itemId: String
    let kind: CodexApprovalKind
    let actions: [ApprovalAction]
}

extension CodexAppServerMonitor {
    nonisolated static func outputDeltaText(
        params: [String: Any]
    ) -> (itemId: String, delta: String)? {
        guard let itemId = params["itemId"] as? String,
              let delta = params["delta"] as? String,
              !delta.isEmpty
        else { return nil }
        return (itemId, delta)
    }

    nonisolated static func commandToolItem(
        fromStartedItem item: [String: Any],
        isRunning: Bool = true
    ) -> CodexTranscriptItem? {
        guard let itemId = item["id"] as? String,
              let type = item["type"] as? String,
              type == "commandExecution"
        else { return nil }

        let detail = CodexCommandToolDetail(
            command: commandText(from: item) ?? "",
            output: item["aggregatedOutput"] as? String ?? "",
            status: item["status"] as? String,
            exitCode: item["exitCode"] as? Int ?? item["exit_code"] as? Int,
            durationMs: item["durationMs"] as? Double ?? item["duration_ms"] as? Double,
            isRunning: isRunning
        )
        return CodexTranscriptItem(
            id: "command-\(itemId)",
            role: .system,
            text: "",
            tool: .command(detail)
        )
    }

    nonisolated static func fileChangeToolItem(
        fromStartedItem item: [String: Any],
        isRunning: Bool = true
    ) -> CodexTranscriptItem? {
        guard let itemId = item["id"] as? String,
              let type = item["type"] as? String,
              type == "fileChange"
        else { return nil }

        let detail = CodexFileChangeToolDetail(
            patch: fileChangePatchText(from: item),
            status: item["status"] as? String,
            isRunning: isRunning
        )
        return CodexTranscriptItem(
            id: "file-change-\(itemId)",
            role: .system,
            text: "",
            tool: .fileChange(detail)
        )
    }

    nonisolated static func formattedCommandOutput(_ output: String) -> String? {
        let trimmed = trimmedTranscriptOutput(output, maxLines: 120, maxCharacters: 4000)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func formattedFileChangeSummary(_ patch: String) -> String {
        trimmedTranscriptOutput(patch, maxLines: 120, maxCharacters: 4000)
    }

    nonisolated static func userInputRequest(
        agentId: UUID,
        params: [String: Any]
    ) -> CodexUserInputRequest? {
        guard let threadId = params["threadId"] as? String,
              let turnId = params["turnId"] as? String,
              let itemId = params["itemId"] as? String,
              let questionObjects = params["questions"] as? [[String: Any]]
        else { return nil }

        let questions = questionObjects.compactMap { question -> CodexUserInputQuestion? in
            guard let id = question["id"] as? String,
                  let header = question["header"] as? String,
                  let prompt = question["question"] as? String
            else { return nil }

            let optionObjects = question["options"] as? [[String: Any]] ?? []
            let options = optionObjects.compactMap { option -> CodexUserInputOption? in
                guard let label = option["label"] as? String,
                      let description = option["description"] as? String
                else { return nil }
                return CodexUserInputOption(label: label, description: description)
            }

            return CodexUserInputQuestion(
                id: id,
                header: header,
                prompt: prompt,
                options: options,
                allowsOther: question["isOther"] as? Bool ?? false
            )
        }

        guard !questions.isEmpty else { return nil }

        return CodexUserInputRequest(
            agentId: agentId,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            questions: questions
        )
    }

    nonisolated static func approvalRequest(
        agentId: UUID,
        requestId: Int,
        method: String,
        params: [String: Any]
    ) -> CodexApprovalRequest? {
        guard let threadId = params["threadId"] as? String,
              let turnId = params["turnId"] as? String,
              let itemId = params["itemId"] as? String
        else { return nil }

        let kind: CodexApprovalKind
        switch method {
        case "item/commandExecution/requestApproval":
            kind = .command(
                command: params["command"] as? String,
                reason: params["reason"] as? String
            )
        case "item/fileChange/requestApproval":
            kind = .fileChange(
                reason: params["reason"] as? String,
                grantRoot: params["grantRoot"] as? String
            )
        case "item/permissions/requestApproval":
            kind = .unsupportedPermissions(reason: params["reason"] as? String)
        default:
            return nil
        }

        let actions = approvalActions(for: kind, params: params)

        return CodexApprovalRequest(
            agentId: agentId,
            requestId: requestId,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            kind: kind,
            actions: actions
        )
    }

    nonisolated static func approvalActions(
        for kind: CodexApprovalKind,
        params: [String: Any]
    ) -> [ApprovalAction] {
        guard kind.supportsDecisions else {
            return [ApprovalAction(id: "dismiss", label: "Dismiss", kind: .dismiss)]
        }

        var actions: [ApprovalAction] = [
            ApprovalAction(id: "approve", label: "Yes, proceed", kind: .allowOnce),
        ]

        if let amendment = proposedExecpolicyAmendment(from: params), !amendment.isEmpty {
            let prefix = amendment.joined(separator: " ")
            actions.append(
                ApprovalAction(
                    id: "approve_for_prefix",
                    label: "Yes, and don't ask again for commands that start with `\(prefix)`",
                    kind: .allowAlways,
                    metadata: ApprovalActionMetadata(
                        prefixRule: amendment,
                        execpolicyAmendment: amendment
                    )
                )
            )
        }

        actions.append(
            ApprovalAction(
                id: "decline",
                label: kind.declineLabel,
                kind: .rejectOnce,
                isDestructive: true
            )
        )

        return actions
    }

    nonisolated static func proposedExecpolicyAmendment(from params: [String: Any]) -> [String]? {
        if let amendment = params["proposedExecpolicyAmendment"] as? [String], !amendment.isEmpty {
            return normalizedExecpolicyAmendment(amendment)
        }
        if let amendment = params["proposed_execpolicy_amendment"] as? [String], !amendment.isEmpty {
            return normalizedExecpolicyAmendment(amendment)
        }
        return nil
    }

    nonisolated static func normalizedExecpolicyAmendment(_ amendment: [String]) -> [String] {
        guard amendment.count >= 3 else { return amendment }

        let executable = URL(fileURLWithPath: amendment[0]).lastPathComponent.lowercased()
        guard ["sh", "bash", "zsh"].contains(executable),
              amendment[1] == "-lc"
        else { return amendment }

        let prefix = categoricalCommandPrefix(fromShellCommand: amendment[2])
        return prefix.isEmpty ? amendment : prefix
    }

    private nonisolated static func categoricalCommandPrefix(fromShellCommand command: String) -> [String] {
        let shellOperators = Set(["|", "||", "&&", ";", "(", ")", "<", ">", ">>", "<<"])
        let tokens = shellWords(in: command)

        var prefix = [String]()
        for token in tokens {
            if shellOperators.contains(token) || token == "--" || token.hasPrefix("-") {
                break
            }
            prefix.append(token)
            if prefix.count == 3 {
                break
            }
        }

        return prefix
    }

    private nonisolated static func shellWords(in command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" && quote != "'" {
                escaping = true
                continue
            }

            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character.isWhitespace {
                self.append(current, to: &tokens)
                current = ""
                continue
            }

            current.append(character)
        }

        self.append(current, to: &tokens)
        return tokens
    }

    private nonisolated static func append(_ token: String, to tokens: inout [String]) {
        guard !token.isEmpty else { return }
        tokens.append(token)
    }

    nonisolated static func transcriptItem(from item: [String: Any]) -> CodexTranscriptItem? {
        guard let type = item["type"] as? String else { return nil }

        switch type {
        case "userMessage":
            let text = extractText(from: item["content"])
            let images = extractLocalImageData(from: item["content"])
            guard !text.isEmpty || !images.isEmpty else { return nil }
            return CodexTranscriptItem(
                id: item["id"] as? String ?? UUID().uuidString,
                role: .user,
                text: text,
                images: images
            )
        case "agentMessage":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return CodexTranscriptItem(
                id: item["id"] as? String ?? UUID().uuidString,
                role: .assistant,
                text: text
            )
        case "commandExecution":
            return commandToolItem(fromStartedItem: item, isRunning: false)
        case "fileChange":
            return fileChangeToolItem(fromStartedItem: item, isRunning: false)
        default:
            return nil
        }
    }

    nonisolated static func transcriptItem(fromSessionEvent object: [String: Any]) -> CodexTranscriptItem? {
        guard let type = object["type"] as? String,
              type == "response_item",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              payloadType == "message",
              let roleRaw = payload["role"] as? String,
              let role = CodexTranscriptRole(rawValue: roleRaw)
        else { return nil }

        let text = extractMessageText(from: payload["content"])
        guard !text.isEmpty else { return nil }

        return CodexTranscriptItem(
            id: payload["id"] as? String ?? UUID().uuidString,
            role: role,
            text: text
        )
    }

    nonisolated static func isTurnAbortedEvent(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String,
              type == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else { return false }

        return payloadType == "turn_aborted"
    }

    nonisolated static func isTaskStartedEvent(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String,
              type == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String
        else { return false }

        return payloadType == "task_started"
    }

    nonisolated static func isBootstrapUserContextMessage(_ item: CodexTranscriptItem) -> Bool {
        guard item.role == .user else { return false }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("# AGENTS.md instructions for ")
            || text.contains("<environment_context>")
    }

    nonisolated static func modelName(fromSessionEvent object: [String: Any]) -> String? {
        rawModelName(fromSessionEvent: object).map(friendlyModelName)
    }

    nonisolated static func rawModelName(fromSessionEvent object: [String: Any]) -> String? {
        guard let type = object["type"] as? String else { return nil }

        switch type {
        case "turn_context":
            guard let payload = object["payload"] as? [String: Any],
                  let model = payload["model"] as? String
            else { return nil }
            return model
        default:
            return nil
        }
    }

    nonisolated static func collaborationMode(fromSessionEvent object: [String: Any]) -> CodexCollaborationMode? {
        guard let type = object["type"] as? String,
              type == "turn_context",
              let payload = object["payload"] as? [String: Any],
              let collaboration = payload["collaboration_mode"] as? [String: Any],
              let mode = collaboration["mode"] as? String
        else { return nil }

        return CodexCollaborationMode(rawValue: mode)
    }

    nonisolated static func contextPercentUsed(fromSessionEvent object: [String: Any]) -> Double? {
        guard let type = object["type"] as? String,
              type == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              payloadType == "token_count",
              let info = payload["info"] as? [String: Any],
              let contextWindow = info["model_context_window"] as? Double,
              contextWindow > 0,
              let total = info["total_token_usage"] as? [String: Any]
        else { return nil }

        let totalTokens = total["total_tokens"] as? Double
            ?? total["input_tokens"] as? Double
            ?? 0
        return max(0, min(100, (totalTokens / contextWindow) * 100))
    }

    nonisolated static func friendlyModelName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "gpt-", with: "GPT-")
    }

    fileprivate nonisolated static func extractText(from content: Any?) -> String {
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    fileprivate nonisolated static func extractLocalImageData(from content: Any?) -> [Data] {
        guard let parts = content as? [[String: Any]] else { return [] }
        return parts.compactMap { part -> Data? in
            guard (part["type"] as? String) == "localImage",
                  let path = part["path"] as? String
            else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    fileprivate nonisolated static func extractMessageText(from content: Any?) -> String {
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part in
            if let text = part["text"] as? String {
                return text
            }
            return part["input_text"] as? String ?? part["output_text"] as? String
        }
        .joined()
    }

    fileprivate nonisolated static func commandText(from item: [String: Any]) -> String? {
        if let command = item["command"] as? String, !command.isEmpty {
            return command
        }
        if let parts = item["command"] as? [Any] {
            let command = parts.map { String(describing: $0) }.joined(separator: " ")
            return command.isEmpty ? nil : command
        }
        return nil
    }

    fileprivate nonisolated static func fileChangePatchText(from item: [String: Any]) -> String {
        if let aggregated = item["aggregatedOutput"] as? String, !aggregated.isEmpty {
            return aggregated
        }
        guard let changes = item["changes"] as? [[String: Any]] else { return "" }
        return changes.compactMap { $0["diff"] as? String }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    fileprivate nonisolated static func trimmedTranscriptOutput(
        _ output: String,
        maxLines: Int,
        maxCharacters: Int
    ) -> String {
        let rawLines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmedLines = Array(rawLines.prefix(maxLines))
        var trimmedText = trimmedLines.joined(separator: "\n")
        let wasLineTruncated = rawLines.count > trimmedLines.count
        if trimmedText.count > maxCharacters {
            trimmedText = String(trimmedText.prefix(maxCharacters))
        }
        let wasCharTruncated = output.count > trimmedText.count
        if wasLineTruncated || wasCharTruncated {
            trimmedText.append("\n...")
        }
        return trimmedText
    }
}
