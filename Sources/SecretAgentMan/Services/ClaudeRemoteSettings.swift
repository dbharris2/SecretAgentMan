import Foundation

enum ClaudeRemoteSettings {
    static let allPermissionModes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]
    static let defaultPermissionMode = allPermissionModes[0]

    static var availablePermissionModes: [String] {
        availablePermissionModes(settingsURLs: defaultSettingsURLs)
    }

    static func isPermissionModeAvailable(_ mode: String) -> Bool {
        availablePermissionModes.contains(mode)
    }

    static func displayPermissionMode(_ mode: String) -> String {
        isPermissionModeAvailable(mode) ? mode : defaultPermissionMode
    }

    static func availablePermissionModes(settingsURLs: [URL]) -> [String] {
        let disabledModes = disabledPermissionModes(settingsURLs: settingsURLs)
        return allPermissionModes.filter { !disabledModes.contains($0) }
    }

    private static var defaultSettingsURLs: [URL] {
        let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        return [
            claudeDirectory.appendingPathComponent("remote-settings.json"),
            claudeDirectory.appendingPathComponent("remote_settings.json"),
        ]
    }

    private static func disabledPermissionModes(settingsURLs: [URL]) -> Set<String> {
        settingsURLs.reduce(into: Set<String>()) { modes, url in
            guard let data = FileManager.default.contents(atPath: url.path) else { return }
            modes.formUnion(disabledPermissionModes(data: data))
        }
    }

    private static func disabledPermissionModes(data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = root["permissions"] as? [String: Any]
        else { return [] }

        var modes = Set<String>()
        if disablesFeature(permissions["disableAutoMode"]) {
            modes.insert("auto")
        }
        if disablesFeature(permissions["disableBypassPermissionsMode"]) {
            modes.insert("bypassPermissions")
        }
        return modes
    }

    private static func disablesFeature(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "disable", "disabled"].contains(normalized)
        default:
            return false
        }
    }
}
