import AppKit
import SwiftTerm

/// Tracks terminal activity to determine agent state.
/// Uses user input (send) and output quiescence (dataReceived) as signals.
class MonitoredTerminalView: LocalProcessTerminalView {
    var lastDataReceived = Date()
    var userSubmitted = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        lastDataReceived = Date()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        // Detect Enter key (carriage return)
        if data.contains(13) {
            userSubmitted = true
        }
    }

    /// Seconds since last output from the process.
    var idleSeconds: TimeInterval {
        Date().timeIntervalSince(lastDataReceived)
    }
}
