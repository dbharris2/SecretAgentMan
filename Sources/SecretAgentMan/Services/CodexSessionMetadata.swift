import Foundation

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
    let text: String
}

enum CodexApprovalKind: Equatable {
    case command(command: String?, reason: String?)
    case fileChange(reason: String?)
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
            [command, reason].compactMap(\.self).joined(separator: "\n\n")
        case let .fileChange(reason):
            reason ?? "Codex requested approval for a file change."
        case let .unsupportedPermissions(reason):
            reason ?? "Codex requested additional permissions."
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
}

struct CodexApprovalRequest: Equatable {
    let agentId: UUID
    let requestId: Int
    let threadId: String
    let turnId: String
    let itemId: String
    let kind: CodexApprovalKind
}

extension CodexAppServerMonitor {
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
            kind = .fileChange(reason: params["reason"] as? String)
        case "item/permissions/requestApproval":
            kind = .unsupportedPermissions(reason: params["reason"] as? String)
        default:
            return nil
        }

        return CodexApprovalRequest(
            agentId: agentId,
            requestId: requestId,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            kind: kind
        )
    }

    nonisolated static func transcriptItem(from item: [String: Any]) -> CodexTranscriptItem? {
        guard let type = item["type"] as? String else { return nil }

        switch type {
        case "userMessage":
            let text = extractText(from: item["content"])
            guard !text.isEmpty else { return nil }
            return CodexTranscriptItem(
                id: item["id"] as? String ?? UUID().uuidString,
                role: .user,
                text: text
            )
        case "agentMessage":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return CodexTranscriptItem(
                id: item["id"] as? String ?? UUID().uuidString,
                role: .assistant,
                text: text
            )
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
}
