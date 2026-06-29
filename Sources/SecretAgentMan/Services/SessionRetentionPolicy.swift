import Foundation

enum SessionRetentionPolicy {
    static let maxRetainedTranscriptItems = 300
    static let maxVisibleTranscriptCharacters = 120_000
    static let maxRetainedToolOutputCharacters = 12000
    static let visibleTranscriptTruncationSuffix = "\n\n[Transcript truncated in UI]"
    static let toolOutputTruncationSuffix = "\n..."

    static func visibleTranscriptText(_ text: String) -> String {
        guard text.count > maxVisibleTranscriptCharacters else { return text }
        return String(text.prefix(maxVisibleTranscriptCharacters)) + visibleTranscriptTruncationSuffix
    }

    static func appendVisibleTranscriptText(_ delta: String, to text: String) -> String {
        guard !delta.isEmpty else { return text }
        guard !text.hasSuffix(visibleTranscriptTruncationSuffix) else { return text }

        let remaining = maxVisibleTranscriptCharacters - text.count
        guard remaining > 0 else {
            return visibleTranscriptText(text)
        }
        guard delta.count > remaining else { return text + delta }

        return text + String(delta.prefix(remaining)) + visibleTranscriptTruncationSuffix
    }

    static func retainedToolOutput(_ output: String) -> String {
        guard output.count > maxRetainedToolOutputCharacters else { return output }
        return String(output.prefix(maxRetainedToolOutputCharacters)) + toolOutputTruncationSuffix
    }

    static func appendRetainedToolOutput(_ delta: String, to output: String) -> String {
        guard !delta.isEmpty else { return output }
        guard !output.hasSuffix(toolOutputTruncationSuffix) else { return output }

        let remaining = maxRetainedToolOutputCharacters - output.count
        guard remaining > 0 else { return retainedToolOutput(output) }
        guard delta.count > remaining else { return output + delta }

        return output + String(delta.prefix(remaining)) + toolOutputTruncationSuffix
    }
}
