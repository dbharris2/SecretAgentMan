import SwiftUI

struct SideBySideDiffView: View {
    let diffText: String
    @Environment(\.fontScale) private var fontScale
    @Environment(\.appTheme) private var theme
    @State private var collapsedFiles: Set<String> = []

    private var groupedFiles: [ParsedFile] {
        parseSideBySide(diffText)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedFiles) { file in
                    Section(header: stickyHeader(for: file)) {
                        if !collapsedFiles.contains(file.id) {
                            ForEach(Array(file.rows.enumerated()), id: \.offset) { _, row in
                                bodyRow(row)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, Spacing.sm)
        }
        .background(theme.background)
        .textSelection(.enabled)
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
    private func bodyRow(_ row: BodyRow) -> some View {
        switch row {
        case let .hunkHeader(text):
            Text(text)
                .scaledFont(size: 12, design: .monospaced)
                .foregroundStyle(theme.cyan)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.cyan.opacity(0.06))

        case let .pair(left, right, lang):
            HStack(spacing: 0) {
                sideCell(left, lang: lang)
                Divider()
                sideCell(right, lang: lang)
            }
        }
    }

    @ViewBuilder
    private func sideCell(_ cell: SideCell, lang: String?) -> some View {
        let bgColor = switch cell.kind {
        case .added: theme.green.opacity(0.1)
        case .removed: theme.red.opacity(0.1)
        case .context, .empty: Color.clear
        }

        let fallbackColor = switch cell.kind {
        case .added: theme.green
        case .removed: theme.red
        case .context: theme.foreground.opacity(0.6)
        case .empty: Color.clear
        }

        if cell.kind == .empty {
            Text(" ")
                .scaledFont(size: 12, design: .monospaced)
                .padding(.horizontal, Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let highlighted = SyntaxHighlighter.highlight(cell.text, language: lang, fontSize: 12 * fontScale) {
            Text(highlighted)
                .padding(.horizontal, Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bgColor)
        } else {
            Text(cell.text.isEmpty ? " " : cell.text)
                .scaledFont(size: 12, design: .monospaced)
                .foregroundStyle(fallbackColor)
                .padding(.horizontal, Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bgColor)
        }
    }
}

// MARK: - Parsing

private struct ParsedFile: Identifiable {
    var id: String {
        headerLine
    }

    let headerLine: String
    var rows: [BodyRow]
}

private enum BodyRow {
    case hunkHeader(String)
    case pair(SideCell, SideCell, lang: String?)
}

private struct SideCell {
    let text: String
    let kind: CellKind

    enum CellKind {
        case context, added, removed, empty
    }

    static let blank = SideCell(text: "", kind: .empty)
}

private func parseSideBySide(_ diff: String) -> [ParsedFile] {
    var files: [ParsedFile] = []
    var currentFile: ParsedFile?
    var currentLang: String?

    var removedBuffer: [String] = []
    var addedBuffer: [String] = []

    func flushBuffers() {
        guard !removedBuffer.isEmpty || !addedBuffer.isEmpty else { return }
        let maxCount = max(removedBuffer.count, addedBuffer.count)
        for i in 0 ..< maxCount {
            let left = i < removedBuffer.count
                ? SideCell(text: removedBuffer[i], kind: .removed)
                : SideCell.blank
            let right = i < addedBuffer.count
                ? SideCell(text: addedBuffer[i], kind: .added)
                : SideCell.blank
            currentFile?.rows.append(.pair(left, right, lang: currentLang))
        }
        removedBuffer.removeAll()
        addedBuffer.removeAll()
    }

    for line in diff.components(separatedBy: "\n") {
        if line.hasPrefix("diff --git") {
            flushBuffers()
            if let current = currentFile {
                files.append(current)
            }
            if let ext = SyntaxHighlighter.extensionFromDiffHeader(line) {
                currentLang = SyntaxHighlighter.language(forExtension: ext)
            }
            currentFile = ParsedFile(headerLine: line, rows: [])
        } else if line.hasPrefix("@@") {
            flushBuffers()
            currentFile?.rows.append(.hunkHeader(line))
        } else if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("rename ") {
            // Skip meta lines
        } else if line.hasPrefix("-") {
            removedBuffer.append(String(line.dropFirst()))
        } else if line.hasPrefix("+") {
            addedBuffer.append(String(line.dropFirst()))
        } else if currentFile != nil {
            flushBuffers()
            let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
            let cell = SideCell(text: text, kind: .context)
            currentFile?.rows.append(.pair(cell, cell, lang: currentLang))
        }
    }

    flushBuffers()
    if let current = currentFile {
        files.append(current)
    }
    return files
}
