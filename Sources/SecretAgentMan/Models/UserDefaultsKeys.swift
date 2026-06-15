import Foundation

/// Centralized UserDefaults key constants to avoid stringly-typed access.
enum UserDefaultsKeys {
    static let terminalTheme = "terminalTheme"
    static let claudePluginDirectory = "pluginDirectory"
    static let diffViewMode = "diffViewMode"
    static let defaultAgentFolder = "defaultAgentFolder"
    static let codexModel = "codexModel"
    static let codexApprovalPolicy = "codexApprovalPolicy"
    static let codexSandboxMode = "codexSandboxMode"
    static let selectedAgentId = "selectedAgentId"
    static let activeSidebarPanel = "activeSidebarPanel"
    static let autoFixCIFailures = "autoFixCIFailures"
    static let autoAnalyzeReviews = "autoAnalyzeReviews"
    static let fontScale = "fontScale"
    static let preferredEditor = "preferredEditor"
    static let favoriteThemes = "favoriteThemes"
}
