import AppKit
import SwiftTerm

/// Shared terminal theme application logic used by ShellManager.
enum TerminalTheming {
    @MainActor static func applyTheme(_ theme: GhosttyTheme, to terminal: LocalProcessTerminalView) {
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.cursorColor
        terminal.selectedTextBackgroundColor = theme.selectionBackground
        let colors = theme.swiftTermColors.map { nsColorToTermColor($0) }
        terminal.installColors(colors)
    }

    private static func nsColorToTermColor(_ nsColor: NSColor) -> SwiftTerm.Color {
        guard let color = nsColor.usingColorSpace(.deviceRGB) else {
            return SwiftTerm.Color(red: 32768, green: 32768, blue: 32768)
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
    }
}
