import Foundation
@testable import SecretAgentMan
import Testing

struct CodexModelSettingsTests {
    @Test
    func configLoaderParsesModelDefault() throws {
        let url = try writeConfig("""
        model = "gpt-5.5"
        approval_policy = "never"
        sandbox_mode = "read-only"
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let defaults = CodexConfigLoader.loadDefaults(from: url)

        #expect(defaults.modelName == "gpt-5.5")
        #expect(defaults.approvalPolicy == .never)
        #expect(defaults.sandboxMode == .readOnly)
    }

    @Test
    func effectiveModelUsesUserOverrideBeforeConfigDefault() throws {
        let suiteName = "CodexModelSettingsTests.override.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let configDefaults = CodexConfigDefaults(
            modelName: "gpt-5.4",
            approvalPolicy: nil,
            sandboxMode: nil
        )

        #expect(CodexModelSettings.effectiveModel(
            userDefaults: userDefaults,
            configDefaults: configDefaults
        ) == "gpt-5.4")

        userDefaults.set("gpt-5.5", forKey: UserDefaultsKeys.codexModel)

        #expect(CodexModelSettings.effectiveModel(
            userDefaults: userDefaults,
            configDefaults: configDefaults
        ) == "gpt-5.5")
    }

    @Test
    func effectiveModelIgnoresBlankOverrideAndFallsBackWhenConfigIsMissing() throws {
        let suiteName = "CodexModelSettingsTests.blank.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("   ", forKey: UserDefaultsKeys.codexModel)

        #expect(CodexModelSettings.effectiveModel(
            userDefaults: userDefaults,
            configDefaults: CodexConfigDefaults(modelName: "gpt-5.4", approvalPolicy: nil, sandboxMode: nil)
        ) == "gpt-5.4")

        #expect(CodexModelSettings.effectiveModel(
            userDefaults: userDefaults,
            configDefaults: CodexConfigDefaults(modelName: nil, approvalPolicy: nil, sandboxMode: nil)
        ) == CodexModelSettings.fallbackModelName)
    }

    @Test
    func collaborationModePayloadUsesRequestedModel() throws {
        let payload = CodexAppServerMonitor.collaborationModePayload(
            mode: .default,
            modelName: "gpt-5.5"
        )
        let settings = try #require(payload["settings"] as? [String: Any])

        #expect(settings["model"] as? String == "gpt-5.5")
    }

    private func writeConfig(_ toml: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-model-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("config.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
