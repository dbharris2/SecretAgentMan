import Foundation

/// Centralized UserDefaults key constants to avoid stringly-typed access.
enum UserDefaultsKeys {
    static let terminalTheme = "terminalTheme"
    static let claudePluginDirectory = "pluginDirectory"
    static let diffViewMode = "diffViewMode"
    static let defaultAgentFolder = "defaultAgentFolder"
    static let selectedAgentId = "selectedAgentId"
    static let activeSidebarPanel = "activeSidebarPanel"
    static let autoFixCIFailures = "autoFixCIFailures"
    static let autoAnalyzeReviews = "autoAnalyzeReviews"
    static let fontScale = "fontScale"
    static let preferredEditor = "preferredEditor"
}
