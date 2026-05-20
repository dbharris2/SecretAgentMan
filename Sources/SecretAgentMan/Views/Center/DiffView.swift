import SwiftUI

struct DiffView: View {
    let diffText: String
    var scrollRequest: DiffScrollRequest?
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme
    @State private var collapsedFiles: Set<String> = []

    private struct ParsedFile: Identifiable {
        var id: String {
            path
        }

        let path: String
        let headerLine: String
        var otherLines: [(line: String, kind: LineKind, lang: String?)]
    }

    private var groupedFiles: [ParsedFile] {
        var files: [ParsedFile] = []
        var currentFile: ParsedFile?
        var currentLang: String?

        for line in diffText.components(separatedBy: "\n") {
            let kind = classify(line)
            if kind == .fileHeader {
                if let current = currentFile {
                    files.append(current)
                }
                let path = SyntaxHighlighter.pathFromDiffHeader(line) ?? line
                currentFile = ParsedFile(path: path, headerLine: line, otherLines: [])
                if let ext = SyntaxHighlighter.extensionFromDiffHeader(line) {
                    currentLang = SyntaxHighlighter.language(forExtension: ext)
                }
            } else if currentFile != nil {
                currentFile?.otherLines.append((line, kind, currentLang))
            } else {
                // Content before first file header (rare for git diffs)
                currentFile = ParsedFile(path: "(meta)", headerLine: "diff (meta)", otherLines: [(line, .meta, nil)])
            }
        }
        if let current = currentFile {
            files.append(current)
        }
        return files
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedFiles) { file in
                        Section(header: stickyHeader(for: file)) {
                            if !collapsedFiles.contains(file.id) {
                                ForEach(Array(file.otherLines.enumerated()), id: \.offset) { _, entry in
                                    diffLine(entry.line, kind: entry.kind, lang: entry.lang)
                                }
                            }
                        }
                        .id(file.id)
                    }
                }
                .padding(.vertical, Spacing.sm)
            }
            .background(theme.background)
            .textSelection(.enabled)
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                collapsedFiles.remove(request.path)
                withAnimation {
                    proxy.scrollTo(request.path, anchor: .top)
                }
            }
        }
    }

    private func stickyHeader(for file: ParsedFile) -> some View {
        Button {
            if collapsedFiles.contains(file.id) {
                collapsedFiles.remove(file.id)
            } else {
                collapsedFiles.insert(file.id)
            }
        } label: {
            HStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(collapsedFiles.contains(file.id) ? 0 : 90))
                    .foregroundStyle(theme.foreground.opacity(0.5))

                Text(file.headerLine)
                    .scaledFont(size: 12, weight: .bold, design: .monospaced)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface.opacity(0.95))
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func diffLine(
        _ line: String,
        kind: LineKind,
        lang: String?
    ) -> some View {
        switch kind {
        case .fileHeader:
            // Rendered separately as a pinned Section header; never reached via diffLine.
            EmptyView()

        case .hunkHeader:
            Text(line)
                .scaledFont(size: 12, design: .monospaced)
                .foregroundStyle(theme.cyan)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.cyan.opacity(0.06))

        case .added:
            highlightedText(line, prefix: "+", lang: lang, fallbackColor: theme.green)
                .padding(.horizontal, Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.green.opacity(0.1))

        case .removed:
            highlightedText(line, prefix: "-", lang: lang, fallbackColor: theme.red)
                .padding(.horizontal, Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.red.opacity(0.1))

        case .context:
            highlightedText(line, prefix: " ", lang: lang, fallbackColor: theme.foreground.opacity(0.6))
                .padding(.horizontal, Spacing.lg)

        case .meta:
            Text(line)
                .scaledFont(size: 11, design: .monospaced)
                .foregroundStyle(theme.foreground.opacity(0.6))
                .padding(.horizontal, Spacing.lg)
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
