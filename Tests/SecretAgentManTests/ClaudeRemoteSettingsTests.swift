import Foundation
@testable import SecretAgentMan
import Testing

struct ClaudeRemoteSettingsTests {
    @Test
    func availablePermissionModesDropsDisabledRemoteSettingsModes() throws {
        let url = try writeSettings("""
        {
          "permissions": {
            "disableAutoMode": "disable",
            "disableBypassPermissionsMode": "disable"
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let modes = ClaudeRemoteSettings.availablePermissionModes(settingsURLs: [url])

        #expect(modes == ["default", "acceptEdits", "plan"])
    }

    @Test
    func availablePermissionModesTreatsBooleanDisableFlagsAsDisabled() throws {
        let url = try writeSettings("""
        {
          "permissions": {
            "disableAutoMode": true,
            "disableBypassPermissionsMode": false
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let modes = ClaudeRemoteSettings.availablePermissionModes(settingsURLs: [url])

        #expect(modes == ["default", "acceptEdits", "plan", "bypassPermissions"])
    }

    @Test
    func availablePermissionModesFallsBackToAllModesWhenSettingsAreMissing() {
        let modes = ClaudeRemoteSettings.availablePermissionModes(settingsURLs: [])

        #expect(modes == ClaudeRemoteSettings.allPermissionModes)
    }

    private func writeSettings(_ json: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-remote-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("remote-settings.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
