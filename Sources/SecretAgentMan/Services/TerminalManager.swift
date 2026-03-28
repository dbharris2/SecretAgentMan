import AppKit
import SwiftTerm

@MainActor
final class TerminalManager {
    private var terminals: [UUID: MonitoredTerminalView] = [:]
    private var delegates: [UUID: TerminalDelegate] = [:]
    private var processManager = AgentProcessManager()
    private var statusTimer: Timer?
    private var onStateChange: ((UUID, AgentState) -> Void)?
    private var lastStates: [UUID: AgentState] = [:]

    /// Seconds of no output before considering agent idle (ready for input).
    private let idleThreshold: TimeInterval = 4.0

    var themeName: String = UserDefaults.standard.string(forKey: "terminalTheme") ?? "Catppuccin Mocha" {
        didSet { applyThemeToAll() }
    }

    private var currentTheme: GhosttyTheme? {
        GhosttyThemeLoader.load(named: themeName)
    }

    func startMonitoring(onStateChange: @escaping (UUID, AgentState) -> Void) {
        self.onStateChange = onStateChange
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollStatus()
            }
        }
    }

    func stopMonitoring() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    func terminal(
        for agent: Agent,
        onStateChange: @escaping (UUID, AgentState) -> Void
    ) -> MonitoredTerminalView {
        if let existing = terminals[agent.id] {
            return existing
        }

        let terminal = MonitoredTerminalView(frame: .zero)
        terminal.font = Self.terminalFont()
        applyTheme(to: terminal)

        let delegate = TerminalDelegate(agentId: agent.id, onStateChange: onStateChange)
        terminal.processDelegate = delegate

        terminals[agent.id] = terminal
        delegates[agent.id] = delegate

        processManager.startAgent(
            terminal: terminal,
            folder: agent.folder,
            initialPrompt: agent.initialPrompt,
            sessionId: agent.sessionId
        )

        lastStates[agent.id] = .active
        onStateChange(agent.id, .active)

        return terminal
    }

    func removeTerminal(for agentId: UUID) {
        if let terminal = terminals[agentId] {
            terminal.terminate()
        }
        terminals.removeValue(forKey: agentId)
        delegates.removeValue(forKey: agentId)
        lastStates.removeValue(forKey: agentId)
    }

    func hasTerminal(for agentId: UUID) -> Bool {
        terminals[agentId] != nil
    }

    private func pollStatus() {
        for (agentId, terminal) in terminals {
            guard terminal.process?.running == true else { continue }

            // Status detection temporarily simplified
            let newState: AgentState = .active

            if lastStates[agentId] != newState {
                lastStates[agentId] = newState
                onStateChange?(agentId, newState)
            }
        }
    }

    private func applyTheme(to terminal: MonitoredTerminalView) {
        guard let theme = currentTheme else { return }
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.cursorColor
        terminal.selectedTextBackgroundColor = theme.selectionBackground
        let swiftTermColors = theme.swiftTermColors.map { nsColorToTermColor($0) }
        terminal.installColors(swiftTermColors)
    }

    private func nsColorToTermColor(_ nsColor: NSColor) -> SwiftTerm.Color {
        guard let color = nsColor.usingColorSpace(.deviceRGB) else {
            return SwiftTerm.Color(red: 32768, green: 32768, blue: 32768)
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
    }

    /// Read terminal font from Ghostty config, falling back to system monospace.
    static func terminalFont() -> NSFont {
        if let config = try? String(
            contentsOfFile: NSHomeDirectory() + "/.config/ghostty/config",
            encoding: .utf8
        ) {
            for line in config.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("font-family") {
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let fontName = parts[1].trimmingCharacters(in: .whitespaces)
                        if let font = NSFont(name: fontName, size: 13) {
                            return font
                        }
                    }
                }
            }
        }
        return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    private func applyThemeToAll() {
        for terminal in terminals.values {
            applyTheme(to: terminal)
        }
    }
}

final class TerminalDelegate: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    let agentId: UUID
    let onStateChange: (UUID, AgentState) -> Void

    init(agentId: UUID, onStateChange: @escaping (UUID, AgentState) -> Void) {
        self.agentId = agentId
        self.onStateChange = onStateChange
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange(self.agentId, .finished)
        }
    }
}
