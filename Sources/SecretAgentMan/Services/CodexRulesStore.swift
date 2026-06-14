import Foundation

enum CodexRulesStore {
    private static let rulesDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/rules", isDirectory: true)
    private static let defaultRulesFile = rulesDirectory.appendingPathComponent("default.rules")

    static func allowCommandPrefix(_ prefixRule: [String]) throws {
        guard !prefixRule.isEmpty else { return }

        let ruleLine = #"prefix_rule(pattern=\#(serializedArray(prefixRule)), decision="allow")"#

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: defaultRulesFile, encoding: .utf8)) ?? ""
        let existingLines = existing
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard !existingLines.contains(ruleLine) else { return }

        let updated = existing.isEmpty || existing.hasSuffix("\n")
            ? existing + ruleLine + "\n"
            : existing + "\n" + ruleLine + "\n"
        try updated.write(to: defaultRulesFile, atomically: true, encoding: .utf8)
    }

    private static func serializedArray(_ values: [String]) -> String {
        let quoted = values.map { value in
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return "[\(quoted.joined(separator: ", "))]"
    }
}
