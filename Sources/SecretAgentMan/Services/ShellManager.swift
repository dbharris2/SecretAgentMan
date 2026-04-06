import AppKit
import SwiftTerm

/// Manages shell terminal instances (one per agent) for running commands
/// in the agent's working directory.
@MainActor
final class ShellManager {
    private var terminals: [UUID: LocalProcessTerminalView] = [:]
    var themeName: String = UserDefaults.standard.string(forKey: UserDefaultsKeys.terminalTheme) ?? "Catppuccin Mocha" {
        didSet { applyThemeToAll() }
    }

    private func applyThemeToAll() {
        for terminal in terminals.values {
            applyTheme(to: terminal)
        }
    }

    func terminal(for agent: Agent) -> LocalProcessTerminalView {
        if let existing = terminals[agent.id] {
            return existing
        }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = TerminalManager.terminalFont()

        applyTheme(to: terminal)

        let shell = Self.userShell()
        let env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: (shell as NSString).lastPathComponent,
            currentDirectory: agent.folder.path
        )

        terminals[agent.id] = terminal
        return terminal
    }

    func sendCommand(_ command: String, for agent: Agent) {
        let terminal = terminal(for: agent)
        let bytes = Array((command + "\n").utf8)
        terminal.send(source: terminal, data: ArraySlice(bytes))
    }

    func removeTerminal(for agentId: UUID) {
        if let terminal = terminals[agentId] {
            terminal.terminate()
        }
        terminals.removeValue(forKey: agentId)
    }

    /// Get the user's login shell from directory services, falling back to $SHELL.
    private static func userShell() -> String {
        let task = Process()
        let out = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        task.arguments = [".", "-read", "/Users/\(NSUserName())", "UserShell"]
        task.standardOutput = out
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8),
               let shell = str.components(separatedBy: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
               !shell.isEmpty {
                return shell
            }
        } catch {}

        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private func applyTheme(to terminal: LocalProcessTerminalView) {
        guard let theme = GhosttyThemeLoader.load(named: themeName) else { return }
        TerminalTheming.applyTheme(theme, to: terminal)
    }
}
