import Foundation

enum CodexModelSettings {
    static let fallbackModelName = "gpt-5.5"
    static let suggestedModelNames = ["gpt-5.5", "gpt-5.4"]

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
}
