import Foundation

struct CodexConfigDefaults {
    let approvalPolicy: CodexApprovalPolicy?
    let sandboxMode: CodexSandboxMode?
}

enum CodexConfigLoader {
    static func loadDefaults() -> CodexConfigDefaults {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return CodexConfigDefaults(approvalPolicy: nil, sandboxMode: nil)
        }

        var approvalPolicy: CodexApprovalPolicy?
        var sandboxMode: CodexSandboxMode?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = strippedTomlLine(rawLine)
            guard !line.isEmpty, !line.hasPrefix("[") else { continue }

            if approvalPolicy == nil,
               let value = tomlStringValue(for: "approval_policy", in: line) {
                approvalPolicy = CodexApprovalPolicy(rawValue: value)
            }

            if sandboxMode == nil,
               let value = tomlStringValue(for: "sandbox_mode", in: line) {
                sandboxMode = CodexSandboxMode(rawValue: value)
            }
        }

        return CodexConfigDefaults(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode)
    }

    private static func strippedTomlLine(_ line: String) -> String {
        var result = ""
        var inQuotes = false

        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            }
            if character == "#", !inQuotes {
                break
            }
            result.append(character)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tomlStringValue(for key: String, in line: String) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let parsedKey = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard parsedKey == key else { return nil }

        let rawValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawValue.first == "\"", rawValue.last == "\"", rawValue.count >= 2 else { return nil }
        return String(rawValue.dropFirst().dropLast())
    }
}
