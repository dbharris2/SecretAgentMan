import Foundation

struct CodexAvailableModel: Identifiable, Hashable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let hidden: Bool
    let isDefault: Bool
    let supportedReasoningEfforts: [String]
    let defaultReasoningEffort: String?

    var displayTitle: String {
        displayName.isEmpty ? CodexAvailableModel.friendlyModelName(model) : displayName
    }

    static func fallback(id: String, description: String = "") -> CodexAvailableModel {
        CodexAvailableModel(
            id: id,
            model: id,
            displayName: friendlyModelName(id),
            description: description,
            hidden: false,
            isDefault: id == CodexModelSettings.fallbackModelName,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil
        )
    }

    static func friendlyModelName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "gpt-", with: "GPT-")
    }

    static func parse(_ object: [String: Any]) -> CodexAvailableModel? {
        let id = CodexModelSettings.normalized(object["id"] as? String)
            ?? CodexModelSettings.normalized(object["model"] as? String)
        guard let id else { return nil }

        let supportedReasoningEfforts = (object["supportedReasoningEfforts"] as? [[String: Any]])?
            .compactMap { CodexModelSettings.normalized($0["reasoningEffort"] as? String) }
            ?? []

        return CodexAvailableModel(
            id: id,
            model: CodexModelSettings.normalized(object["model"] as? String) ?? id,
            displayName: CodexModelSettings.normalized(object["displayName"] as? String) ?? "",
            description: CodexModelSettings.normalized(object["description"] as? String) ?? "",
            hidden: object["hidden"] as? Bool ?? false,
            isDefault: object["isDefault"] as? Bool ?? false,
            supportedReasoningEfforts: supportedReasoningEfforts,
            defaultReasoningEffort: CodexModelSettings.normalized(object["defaultReasoningEffort"] as? String)
        )
    }
}

enum CodexModelSettings {
    static let fallbackModelName = "gpt-5.6-sol"
    static let fallbackModels = [
        CodexAvailableModel.fallback(
            id: "gpt-5.6-sol",
            description: "Latest frontier agentic coding model."
        ),
        CodexAvailableModel.fallback(
            id: "gpt-5.6-terra",
            description: "Balanced agentic coding model for everyday work."
        ),
        CodexAvailableModel.fallback(
            id: "gpt-5.6-luna",
            description: "Fast and affordable agentic coding model."
        ),
        CodexAvailableModel.fallback(
            id: "gpt-5.5",
            description: "Frontier model for complex coding, research, and real-world work."
        ),
        CodexAvailableModel.fallback(
            id: "gpt-5.4",
            description: "Strong model for everyday coding."
        ),
        CodexAvailableModel.fallback(
            id: "gpt-5.4-mini",
            description: "Small, fast, and cost-efficient model for simpler coding tasks."
        ),
    ]

    static func normalized(_ modelName: String?) -> String? {
        guard let modelName else { return nil }
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var storedValue: String {
        effectiveModel()
    }

    static func effectiveModel(
        userDefaults: UserDefaults = .standard,
        configDefaults: CodexConfigDefaults? = nil
    ) -> String {
        if let override = normalized(userDefaults.string(forKey: UserDefaultsKeys.codexModel)) {
            return override
        }

        let defaults = configDefaults ?? CodexConfigLoader.loadDefaults()
        return normalized(defaults.modelName) ?? fallbackModelName
    }

    static func models(from response: [String: Any], includeHidden: Bool = false) -> [CodexAvailableModel] {
        guard let result = response["result"] as? [String: Any],
              let data = result["data"] as? [[String: Any]]
        else { return [] }

        return deduplicated(data.compactMap(CodexAvailableModel.parse).filter { includeHidden || !$0.hidden })
    }

    static func nextCursor(from response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any] else { return nil }
        return normalized(result["nextCursor"] as? String)
    }

    static func modelOptions(
        discoveredModels: [CodexAvailableModel],
        currentModelName: String
    ) -> [CodexAvailableModel] {
        var options = discoveredModels.isEmpty ? fallbackModels : discoveredModels
        if let normalized = normalized(currentModelName),
           !options.contains(where: { $0.model == normalized }) {
            options.insert(CodexAvailableModel.fallback(id: normalized), at: 0)
        }
        return deduplicated(options)
    }

    static func deduplicated(_ models: [CodexAvailableModel]) -> [CodexAvailableModel] {
        var seen: Set<String> = []
        var result: [CodexAvailableModel] = []
        for model in models where seen.insert(model.model).inserted {
            result.append(model)
        }
        return result
    }
}
