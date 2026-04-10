import AppKit
import SwiftUI

/// App-wide theme derived from the active Ghostty terminal theme.
/// Provides semantic colors for consistent styling across all views.
struct AppTheme: Equatable {
    let name: String

    // Core colors
    let background: Color
    let foreground: Color
    let surface: Color
    let overlay: Color

    // ANSI palette semantic colors
    let red: Color
    let green: Color
    let yellow: Color
    let blue: Color
    let magenta: Color
    let cyan: Color

    // UI accent (cursor color) and selection
    let accent: Color
    let selection: Color

    let isDark: Bool
    let highlightrTheme: String

    static func == (lhs: AppTheme, rhs: AppTheme) -> Bool {
        lhs.name == rhs.name
    }

    init(name: String, from ghostty: GhosttyTheme) {
        self.name = name

        let bg = ghostty.background
        let fg = ghostty.foreground

        background = Color(nsColor: bg)
        foreground = Color(nsColor: fg)

        // Surface/overlay: slightly elevated from background by blending toward foreground
        let bgSRGB = bg.usingColorSpace(NSColorSpace.sRGB) ?? bg
        let fgSRGB = fg.usingColorSpace(NSColorSpace.sRGB) ?? fg
        surface = Color(nsColor: bgSRGB.blended(withFraction: 0.06, of: fgSRGB) ?? bg)
        overlay = Color(nsColor: bgSRGB.blended(withFraction: 0.12, of: fgSRGB) ?? bg)

        // ANSI palette → semantic colors
        red = Color(nsColor: ghostty.palette[1] ?? .systemRed)
        green = Color(nsColor: ghostty.palette[2] ?? .systemGreen)
        yellow = Color(nsColor: ghostty.palette[3] ?? .systemYellow)
        blue = Color(nsColor: ghostty.palette[4] ?? .systemBlue)
        magenta = Color(nsColor: ghostty.palette[5] ?? .systemPurple)
        cyan = Color(nsColor: ghostty.palette[6] ?? .systemCyan)

        accent = Color(nsColor: ghostty.cursorColor)
        selection = Color(nsColor: ghostty.selectionBackground)

        // Background luminance determines dark/light mode
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        if let srgb = bg.usingColorSpace(NSColorSpace.sRGB) {
            srgb.getRed(&r, green: &g, blue: &b, alpha: nil)
        }
        isDark = (0.299 * r + 0.587 * g + 0.114 * b) < 0.5

        highlightrTheme = Self.mapHighlightrTheme(for: name, isDark: isDark)
    }

    static func load(named name: String) -> AppTheme {
        guard let ghostty = GhosttyThemeLoader.load(named: name) else {
            return .default
        }
        return AppTheme(name: name, from: ghostty)
    }

    static let `default` = AppTheme(name: "default", from: GhosttyTheme())

    private static func mapHighlightrTheme(for name: String, isDark: Bool) -> String {
        let lower = name.lowercased()
        if lower.contains("monokai") { return "monokai-sublime" }
        if lower.contains("dracula") { return "dracula" }
        if lower.contains("nord") { return "nord" }
        if lower.contains("solarized") {
            return isDark ? "solarized-dark" : "solarized-light"
        }
        if lower.contains("gruvbox") {
            return isDark ? "gruvbox-dark" : "gruvbox-light"
        }
        return isDark ? "atom-one-dark" : "atom-one-light"
    }
}

// MARK: - SwiftUI Environment

extension EnvironmentValues {
    @Entry var appTheme: AppTheme = .default
}
