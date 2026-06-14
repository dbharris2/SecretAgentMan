import Foundation

enum ClaudeSettingsStore {
    static func allowShellRule(_ rule: String, in projectRoot: URL) throws {
        guard !rule.isEmpty else { return }

        let settingsDirectory = projectRoot.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.local.json")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)

        var root = try loadSettings(from: settingsURL)
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var allowRules = permissions["allow"] as? [String] ?? []

        guard !allowRules.contains(rule) else { return }

        allowRules.append(rule)
        permissions["allow"] = allowRules
        root["permissions"] = permissions

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard var serialized = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        serialized.append("\n")
        try serialized.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    private static func loadSettings(from url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }
}
