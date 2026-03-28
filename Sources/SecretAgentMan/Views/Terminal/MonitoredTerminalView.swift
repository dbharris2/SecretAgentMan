import AppKit
import SwiftTerm

class MonitoredTerminalView: LocalProcessTerminalView {
    /// Tracks "meaningful" data — bursts larger than cursor blink escape sequences.
    var lastMeaningfulData = Date()
    var userSubmittedAt: Date?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        // Cursor blink/position updates are typically < 20 bytes.
        // Real output (text, tool calls, progress) is larger.
        if slice.count > 20 {
            lastMeaningfulData = Date()
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        // Detect Enter key (carriage return)
        if data.contains(13) {
            userSubmittedAt = Date()
        }
    }

    var secondsSinceMeaningfulData: TimeInterval {
        Date().timeIntervalSince(lastMeaningfulData)
    }

    var isUserWaiting: Bool {
        guard let submitted = userSubmittedAt else { return false }
        // User submitted and we haven't gone idle since
        return Date().timeIntervalSince(submitted) < secondsSinceMeaningfulData
    }
}
