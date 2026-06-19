import Foundation

enum SessionMarkdownSegment: Equatable {
    case markdown(String)
    case code(language: String?, text: String)
}

enum SessionMarkdownSegmentParser {
    static func parse(_ text: String) -> [SessionMarkdownSegment] {
        guard !text.isEmpty else { return [.markdown("")] }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [SessionMarkdownSegment] = []
        var markdownLines: [String] = []
        var codeLines: [String] = []
        var openFence: Fence?

        func flushMarkdown() {
            guard !markdownLines.isEmpty else { return }
            let markdown = markdownLines.joined(separator: "\n")
            if !markdown.isEmpty {
                segments.append(.markdown(markdown))
            }
            markdownLines.removeAll(keepingCapacity: true)
        }

        func flushCode(language: String?) {
            segments.append(.code(language: language, text: codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if let fence = openFence {
                if isClosingFence(line, for: fence) {
                    flushCode(language: fence.language)
                    openFence = nil
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if let fence = openingFence(in: line) {
                flushMarkdown()
                openFence = fence
            } else {
                markdownLines.append(line)
            }
        }

        if let fence = openFence {
            flushCode(language: fence.language)
        } else {
            flushMarkdown()
        }

        return segments.isEmpty ? [.markdown("")] : segments
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
    }

    private static func openingFence(in line: String) -> Fence? {
        guard let content = lineAfterOptionalFenceIndent(line),
              let marker = content.first,
              marker == "`" || marker == "~"
        else {
            return nil
        }

        let length = markerRunLength(in: content, marker: marker)
        guard length >= 3 else { return nil }

        let info = String(content.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") {
            return nil
        }

        return Fence(marker: marker, length: length, language: language(from: info))
    }

    private static func isClosingFence(_ line: String, for fence: Fence) -> Bool {
        guard let content = lineAfterOptionalFenceIndent(line),
              content.first == fence.marker
        else {
            return false
        }

        let length = markerRunLength(in: content, marker: fence.marker)
        guard length >= fence.length else { return false }

        let rest = String(content.dropFirst(length)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty
    }

    private static func lineAfterOptionalFenceIndent(_ line: String) -> Substring? {
        var index = line.startIndex
        var spaces = 0

        while index < line.endIndex, line[index] == " " {
            spaces += 1
            guard spaces <= 3 else { return nil }
            index = line.index(after: index)
        }

        return line[index...]
    }

    private static func markerRunLength(in content: Substring, marker: Character) -> Int {
        var index = content.startIndex
        var length = 0

        while index < content.endIndex, content[index] == marker {
            length += 1
            index = content.index(after: index)
        }

        return length
    }

    private static func language(from info: String) -> String? {
        info.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() }
    }
}
