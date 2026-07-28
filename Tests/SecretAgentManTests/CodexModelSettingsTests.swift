import Foundation
@testable import SecretAgentMan
import Testing

struct CodexModelSettingsTests {
    @Test
    func configLoaderParsesModelDefault() throws {
        let url = try writeConfig("""
        model = "gpt-5.5"
        model_reasoning_effort = "high"
        approval_policy = "never"
        sandbox_mode = "read-only"
        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let defaults = CodexConfigLoader.loadDefaults(from: url)

        #expect(defaults.modelName == "gpt-5.5")
        #expect(defaults.reasoningEffort == "high")
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
            reasoningEffort: nil,
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
            configDefaults: CodexConfigDefaults(
                modelName: "gpt-5.4",
                reasoningEffort: nil,
                approvalPolicy: nil,
                sandboxMode: nil
            )
        ) == "gpt-5.4")

        #expect(CodexModelSettings.effectiveModel(
            userDefaults: userDefaults,
            configDefaults: CodexConfigDefaults(
                modelName: nil,
                reasoningEffort: nil,
                approvalPolicy: nil,
                sandboxMode: nil
            )
        ) == CodexModelSettings.fallbackModelName)
    }

    @Test
    func fallbackUsesSolAndIncludesTheCurrentCatalog() {
        #expect(CodexModelSettings.fallbackModelName == "gpt-5.6-sol")
        #expect(CodexModelSettings.fallbackModels.map(\.model) == [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
        ])
    }

    @Test
    func modelListResponseParsesVisibleModelsAndCursor() {
        let response: [String: Any] = [
            "result": [
                "data": [
                    [
                        "id": "gpt-5.6-sol",
                        "model": "gpt-5.6-sol",
                        "displayName": "GPT-5.6-Sol",
                        "description": "Latest frontier agentic coding model.",
                        "hidden": false,
                        "supportedReasoningEfforts": [
                            ["reasoningEffort": "low"],
                            ["reasoningEffort": "xhigh"],
                        ],
                        "defaultReasoningEffort": "xhigh",
                        "isDefault": false,
                    ],
                    [
                        "id": "hidden-model",
                        "model": "hidden-model",
                        "displayName": "Hidden",
                        "description": "Not shown by default.",
                        "hidden": true,
                        "supportedReasoningEfforts": [],
                        "defaultReasoningEffort": "medium",
                        "isDefault": false,
                    ],
                ],
                "nextCursor": "page-2",
            ],
        ]

        let models = CodexModelSettings.models(from: response)

        #expect(models.map(\.id) == ["gpt-5.6-sol"])
        #expect(models.first?.displayTitle == "GPT-5.6-Sol")
        #expect(models.first?.description == "Latest frontier agentic coding model.")
        #expect(models.first?.supportedReasoningEfforts == ["low", "xhigh"])
        #expect(models.first?.defaultReasoningEffort == "xhigh")
        #expect(CodexModelSettings.nextCursor(from: response) == "page-2")
    }

    @Test
    func modelOptionsKeepCurrentCustomModel() {
        let discovered = [
            CodexAvailableModel.fallback(id: "gpt-5.5"),
            CodexAvailableModel.fallback(id: "gpt-5.4"),
        ]

        let options = CodexModelSettings.modelOptions(
            discoveredModels: discovered,
            currentModelName: "private-rollout-model"
        )

        #expect(options.map(\.id) == ["private-rollout-model", "gpt-5.5", "gpt-5.4"])
    }

    @Test
    func modelOptionsUseTheSelectableModelValue() {
        let discovered = [
            CodexAvailableModel(
                id: "catalog-entry",
                model: "selectable-model",
                displayName: "Selectable Model",
                description: "",
                hidden: false,
                isDefault: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
        ]

        let options = CodexModelSettings.modelOptions(
            discoveredModels: discovered,
            currentModelName: "selectable-model"
        )

        #expect(options.count == 1)
        #expect(options.first?.id == "catalog-entry")
        #expect(options.first?.model == "selectable-model")
    }

    @Test
    func collaborationModePayloadUsesRequestedModel() throws {
        let model = CodexAvailableModel(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "",
            description: "",
            hidden: false,
            isDefault: false,
            supportedReasoningEfforts: ["medium", "xhigh"],
            defaultReasoningEffort: "xhigh"
        )
        let payload = CodexAppServerMonitor.collaborationModePayload(
            mode: .default,
            modelName: "gpt-5.5",
            reasoningEffort: "xhigh",
            availableModel: model
        )
        let settings = try #require(payload["settings"] as? [String: Any])

        #expect(settings["model"] as? String == "gpt-5.5")
        #expect(settings["reasoning_effort"] as? String == "xhigh")
    }

    @Test
    func collaborationModePayloadUsesModelDefaultForUnsupportedReasoningOverride() throws {
        let model = CodexAvailableModel(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "",
            description: "",
            hidden: false,
            isDefault: false,
            supportedReasoningEfforts: ["medium", "high"],
            defaultReasoningEffort: "high"
        )
        let payload = CodexAppServerMonitor.collaborationModePayload(
            mode: .default,
            modelName: "gpt-5.5",
            reasoningEffort: "xhigh",
            availableModel: model
        )
        let settings = try #require(payload["settings"] as? [String: Any])

        #expect(settings["reasoning_effort"] as? String == "high")
    }

    @Test
    func collaborationModePayloadOmitsReasoningUntilModelCapabilitiesAreKnown() throws {
        let payload = CodexAppServerMonitor.collaborationModePayload(
            mode: .default,
            modelName: "gpt-5.5",
            reasoningEffort: "xhigh"
        )
        let settings = try #require(payload["settings"] as? [String: Any])

        #expect(settings["reasoning_effort"] is NSNull)
    }

    @Test
    func effectiveReasoningEffortUsesUserOverrideBeforeConfigDefault() throws {
        let suiteName = "CodexModelSettingsTests.reasoning.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let configDefaults = CodexConfigDefaults(
            modelName: nil,
            reasoningEffort: "medium",
            approvalPolicy: nil,
            sandboxMode: nil
        )
        #expect(CodexModelSettings.effectiveReasoningEffort(
            userDefaults: userDefaults,
            configDefaults: configDefaults
        ) == "medium")

        userDefaults.set("xhigh", forKey: UserDefaultsKeys.codexReasoningEffort)
        #expect(CodexModelSettings.effectiveReasoningEffort(
            userDefaults: userDefaults,
            configDefaults: configDefaults
        ) == "xhigh")

        userDefaults.removeObject(forKey: UserDefaultsKeys.codexReasoningEffort)
        #expect(CodexModelSettings.effectiveReasoningEffort(
            userDefaults: userDefaults,
            configDefaults: configDefaults
        ) == "medium")
    }

    @Test
    func modelFallsBackToItsDefaultForUnsupportedReasoningOverride() {
        let model = CodexAvailableModel(
            id: "model",
            model: "model",
            displayName: "",
            description: "",
            hidden: false,
            isDefault: false,
            supportedReasoningEfforts: ["medium", "high"],
            defaultReasoningEffort: "high"
        )

        #expect(model.effectiveReasoningEffort(preferred: "xhigh") == "high")
        #expect(model.effectiveReasoningEffort(preferred: "medium") == "medium")
    }

    @Test
    func modelCatalogSharesCapabilityUpdatesAcrossConsumers() {
        let catalog = CodexModelCatalog(models: [CodexAvailableModel.fallback(id: "model")])
        let firstConsumer = catalog
        let secondConsumer = catalog
        let updatedModel = CodexAvailableModel(
            id: "model",
            model: "model",
            displayName: "",
            description: "",
            hidden: false,
            isDefault: false,
            supportedReasoningEfforts: ["medium", "high"],
            defaultReasoningEffort: "high"
        )

        catalog.replace([updatedModel])

        #expect(firstConsumer.model(named: "model")?.effectiveReasoningEffort(preferred: "xhigh") == "high")
        #expect(secondConsumer.model(named: "model")?.effectiveReasoningEffort(preferred: "medium") == "medium")
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
