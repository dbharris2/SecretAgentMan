import Foundation
@testable import SecretAgentMan
import Testing

struct ClaudeSettingsStoreTests {
    @Test func allowShellRuleCreatesSettingsFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try ClaudeSettingsStore.allowShellRule("Bash(just build *)", in: root)

        let settingsURL = root.appendingPathComponent(".claude/settings.local.json")
        let data = try Data(contentsOf: settingsURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try #require(json["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow == ["Bash(just build *)"])
    }

    @Test func allowShellRuleMergesWithoutDuplicating() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsDirectory = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.local.json")
        try """
        {
          "permissions": {
            "allow": [
              "Bash(jj *)"
            ]
          }
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        try ClaudeSettingsStore.allowShellRule("Bash(just build *)", in: root)
        try ClaudeSettingsStore.allowShellRule("Bash(just build *)", in: root)

        let data = try Data(contentsOf: settingsURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try #require(json["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow == ["Bash(jj *)", "Bash(just build *)"])
    }
}
