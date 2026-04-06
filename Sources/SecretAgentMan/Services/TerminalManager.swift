import AppKit
import SwiftTerm

@MainActor
final class TerminalManager {
    private var terminals: [UUID: MonitoredTerminalView] = [:]
    private var delegates: [UUID: TerminalDelegate] = [:]
    private var processManager = AgentProcessManager()
    var onStateChange: ((UUID, AgentState) -> Void)?
    var onLaunched: ((UUID) -> Void)?
    var onSessionNotFound: ((UUID) -> Void)?
    private var lastStates: [UUID: AgentState] = [:]

    var themeName: String = UserDefaults.standard.string(forKey: UserDefaultsKeys.terminalTheme) ?? "Catppuccin Mocha" {
        didSet { applyThemeToAll() }
    }

    private var currentTheme: GhosttyTheme? {
        GhosttyThemeLoader.load(named: themeName)
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

        // Wire up event-driven state callbacks
        let agentId = agent.id
        terminal.onActivity = { [weak self] in
            guard let self else { return }
            if self.lastStates[agentId] != .active {
                self.lastStates[agentId] = .active
                self.onStateChange?(agentId, .active)
            }
        }
        terminal.onIdleTimeout = { [weak self] in
            guard let self else { return }
            self.lastStates[agentId] = .awaitingInput
            self.onStateChange?(agentId, .awaitingInput)
        }

        // IMPORTANT: Launch process on next run loop tick, NOT synchronously.
        // startProcess triggers immediate data callbacks that cause SwiftUI
        // re-renders, which re-enter updateNSView, creating a main thread
        // feedback loop (beachball). The async dispatch breaks the cycle.
        let pm = processManager
        let folder = agent.folder
        let prompt = agent.hasLaunched ? nil : agent.initialPrompt
        let sessionId = agent.sessionId
        let hasLaunched = agent.hasLaunched
        DispatchQueue.main.async { [weak self] in
            pm.startAgent(
                terminal: terminal,
                folder: folder,
                initialPrompt: prompt,
                sessionId: sessionId,
                hasLaunched: hasLaunched
            )
            self?.lastStates[agentId] = .active
            self?.onStateChange?(agentId, .active)
            self?.onLaunched?(agentId)
            terminal.startIdleTimer()
        }

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

    func sendInput(to agentId: UUID, text: String) {
        guard let terminal = terminals[agentId] else { return }
        // Use bracketed paste mode so multi-line text is treated as a
        // single input, not multiple Enter presses
        let bracketStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // \e[200~
        let bracketEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // \e[201~
        let content = Array(text.utf8)
        let newline: [UInt8] = [0x0A] // \n to submit
        terminal.send(bracketStart + content + bracketEnd + newline)
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
