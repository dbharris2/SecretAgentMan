import SwiftUI

struct DiffView: View {
    let diffText: String
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme

    private var parsedLines: [(line: String, kind: LineKind, lang: String?)] {
        var result: [(String, LineKind, String?)] = []
        var currentLang: String?

        for line in diffText.components(separatedBy: "\n") {
            let kind = classify(line)
            if kind == .fileHeader {
                if let ext = SyntaxHighlighter.extensionFromDiffHeader(line) {
                    currentLang = SyntaxHighlighter.language(forExtension: ext)
                }
            }
            result.append((line, kind, currentLang))
        }
        return result
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, entry in
                    diffLine(entry.line, kind: entry.kind, lang: entry.lang)
                }
            }
            .padding(.vertical, 4)
        }
        .background(theme.background)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func diffLine(
        _ line: String,
        kind: LineKind,
        lang: String?
    ) -> some View {
        switch kind {
        case .fileHeader:
            Text(line)
                .scaledFont(size: 12, weight: .bold, design: .monospaced)
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.foreground.opacity(0.08))

        case .hunkHeader:
            Text(line)
                .scaledFont(size: 12, design: .monospaced)
                .foregroundStyle(theme.cyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.cyan.opacity(0.06))

        case .added:
            highlightedText(line, prefix: "+", lang: lang, fallbackColor: theme.green)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.green.opacity(0.1))

        case .removed:
            highlightedText(line, prefix: "-", lang: lang, fallbackColor: theme.red)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.red.opacity(0.1))

        case .context:
            highlightedText(line, prefix: " ", lang: lang, fallbackColor: theme.foreground.opacity(0.6))
                .padding(.horizontal, 8)

        case .meta:
            Text(line)
                .scaledFont(size: 11, design: .monospaced)
                .foregroundStyle(theme.foreground.opacity(0.6))
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func highlightedText(
        _ line: String,
        prefix: String,
        lang: String?,
        fallbackColor: Color
    ) -> some View {
        // Strip the diff prefix for highlighting, then display with prefix
        let code = line.hasPrefix(prefix) ? String(line.dropFirst()) : line
        let scaledSize = 12 * fontScale
        if let highlighted = SyntaxHighlighter.highlight(code, language: lang, fontSize: scaledSize) {
            let prefixAttr = Self.monoAttributedString(prefix, size: scaledSize)
            Text(prefixAttr) + Text(highlighted)
        } else {
            Text(line.isEmpty ? " " : line)
                .scaledFont(size: 12, design: .monospaced)
                .foregroundStyle(fallbackColor)
        }
    }

    private static func monoAttributedString(_ text: String, size: CGFloat) -> AttributedString {
        var attr = AttributedString(text)
        attr.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        return attr
    }

    private enum LineKind {
        case fileHeader, hunkHeader, added, removed, meta, context
    }

    private func classify(_ line: String) -> LineKind {
        if line.hasPrefix("diff --git") {
            return .fileHeader
        }
        if line.hasPrefix("@@") {
            return .hunkHeader
        }
        if line.hasPrefix("+") {
            return .added
        }
        if line.hasPrefix("-") {
            return .removed
        }
        if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("rename ") {
            return .meta
        }
        return .context
    }
}
