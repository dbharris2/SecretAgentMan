import Foundation

/// Centralized UserDefaults key constants to avoid stringly-typed access.
enum UserDefaultsKeys {
    static let terminalTheme = "terminalTheme"
    static let pluginDirectory = "pluginDirectory"
    static let diffViewMode = "diffViewMode"
    static let defaultAgentFolder = "defaultAgentFolder"
    static let autoFixCIFailures = "autoFixCIFailures"
    static let autoAnalyzeReviews = "autoAnalyzeReviews"
}
