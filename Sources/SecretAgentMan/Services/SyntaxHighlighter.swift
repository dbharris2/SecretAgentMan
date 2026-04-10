import AppKit
import Highlightr
import SwiftUI

/// Wraps Highlightr for syntax highlighting code lines in diffs.
enum SyntaxHighlighter {
    private nonisolated(unsafe) static let highlightr: Highlightr? = {
        let h = Highlightr()
        h?.setTheme(to: "atom-one-dark")
        return h
    }()

    private nonisolated(unsafe) static var currentThemeName = "atom-one-dark"

    /// Update the Highlightr theme to match the app theme.
    static func setHighlightrTheme(_ name: String) {
        guard name != currentThemeName else { return }
        currentThemeName = name
        highlightr?.setTheme(to: name)
    }

    private static let extensionMap: [String: String] = [
        "ts": "typescript", "tsx": "typescript",
        "js": "javascript", "jsx": "javascript",
        "py": "python", "swift": "swift", "rs": "rust", "go": "go",
        "rb": "ruby", "java": "java", "kt": "kotlin",
        "css": "css", "html": "html", "htm": "html",
        "json": "json", "yml": "yaml", "yaml": "yaml",
        "md": "markdown", "sh": "bash", "bash": "bash", "zsh": "bash",
        "sql": "sql", "xml": "xml",
        "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp",
        "cs": "csharp", "m": "objectivec", "mm": "objectivec",
    ]

    /// Map file extensions to highlight.js language identifiers.
    static func language(forExtension ext: String) -> String? {
        extensionMap[ext.lowercased()]
    }

    /// Highlight a single line of code, returning an AttributedString.
    /// Returns nil if highlighting fails (caller should fall back to plain text).
    static func highlight(_ code: String, language: String?, fontSize: CGFloat = 12) -> AttributedString? {
        guard let highlightr,
              let lang = language,
              let nsAttr = highlightr.highlight(code, as: lang, fastRender: true)
        else {
            return nil
        }

        let mutable = NSMutableAttributedString(attributedString: nsAttr)
        let monoFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        mutable.addAttribute(.font, value: monoFont, range: NSRange(location: 0, length: mutable.length))
        return try? AttributedString(mutable, including: \.appKit)
    }

    /// Extract the file extension from a "diff --git a/path b/path" line.
    static func extensionFromDiffHeader(_ line: String) -> String? {
        guard line.hasPrefix("diff --git") else { return nil }
        let parts = line.components(separatedBy: " b/")
        guard let path = parts.last else { return nil }
        return (path as NSString).pathExtension
    }
}
