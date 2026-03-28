import AppKit
import SwiftTerm

/// Manages shell terminal instances (one per agent) for running commands
/// in the agent's working directory.
@MainActor
final class ShellManager {
    private var terminals: [UUID: LocalProcessTerminalView] = [:]
    private var themeName: String {
        UserDefaults.standard.string(forKey: "terminalTheme") ?? "Catppuccin Mocha"
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
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.cursorColor
        terminal.selectedTextBackgroundColor = theme.selectionBackground

        let colors = theme.swiftTermColors.map { nsColor -> SwiftTerm.Color in
            guard let c = nsColor.usingColorSpace(.deviceRGB) else {
                return SwiftTerm.Color(red: 32768, green: 32768, blue: 32768)
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        }
        terminal.installColors(colors)
    }
}
