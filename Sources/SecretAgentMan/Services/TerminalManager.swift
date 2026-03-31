import AppKit
import SwiftTerm

@MainActor
final class TerminalManager {
    private var terminals: [UUID: MonitoredTerminalView] = [:]
    private var delegates: [UUID: TerminalDelegate] = [:]
    private var processManager = AgentProcessManager()
    private var statusTimer: Timer?
    private var onStateChange: ((UUID, AgentState) -> Void)?
    var onLaunched: ((UUID) -> Void)?
    var onSessionNotFound: ((UUID) -> Void)?
    private var lastStates: [UUID: AgentState] = [:]

    /// Seconds of no output before considering agent idle (ready for input).
    private let idleThreshold: TimeInterval = 5.0

    var themeName: String = UserDefaults.standard.string(forKey: UserDefaultsKeys.terminalTheme) ?? "Catppuccin Mocha" {
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
        delegate.terminal = terminal
        delegate.onSessionNotFound = { [weak self] id in
            self?.onSessionNotFound?(id)
        }
        terminal.processDelegate = delegate

        terminals[agent.id] = terminal
        delegates[agent.id] = delegate

        processManager.startAgent(
            terminal: terminal,
            folder: agent.folder,
            initialPrompt: agent.hasLaunched ? nil : agent.initialPrompt,
            sessionId: agent.sessionId,
            hasLaunched: agent.hasLaunched
        )

        lastStates[agent.id] = .active
        onStateChange(agent.id, .active)
        onLaunched?(agent.id)

        return terminal
    }

    func restartAgent(
        _ agent: Agent,
        onStateChange: @escaping (UUID, AgentState) -> Void
    ) {
        // Remove stale terminal
        terminals.removeValue(forKey: agent.id)
        delegates.removeValue(forKey: agent.id)
        lastStates.removeValue(forKey: agent.id)
        // Re-create with fresh session
        _ = terminal(for: agent, onStateChange: onStateChange)
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

            let idle = terminal.secondsSinceMeaningfulData > idleThreshold
            let currentState = lastStates[agentId] ?? .idle

            // Only go active if user submitted input since we last went idle
            let userSubmittedSinceIdle = if let submitted = terminal.userSubmittedAt {
                !idle && submitted.timeIntervalSinceNow > -terminal.secondsSinceMeaningfulData
            } else {
                false
            }

            let newState: AgentState = if idle {
                if currentState == .idle, terminal.secondsSinceMeaningfulData < 15 {
                    // Startup phase — still loading
                    .active
                } else {
                    .awaitingInput
                }
            } else {
                // Terminal is producing output — Claude is working
                .active
            }

            if lastStates[agentId] != newState {
                lastStates[agentId] = newState
                onStateChange?(agentId, newState)
            }
        }
    }

    private func applyTheme(to terminal: MonitoredTerminalView) {
        guard let theme = currentTheme else { return }
        TerminalTheming.applyTheme(theme, to: terminal)
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
        return NSFont(name: "Monaco", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
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
    var onSessionNotFound: ((UUID) -> Void)?
    weak var terminal: MonitoredTerminalView?

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
            if self.terminal?.detectedSessionNotFound == true {
                self.onSessionNotFound?(self.agentId)
            } else {
                self.onStateChange(self.agentId, .finished)
            }
        }
    }
}
