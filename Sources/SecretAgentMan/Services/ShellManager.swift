import AppKit
import SwiftTerm

/// Manages per-folder project shell terminals. One shell exists per unique
/// standardized agent folder; agents sharing a folder share the same shell
/// and scrollback. Shells run the user's login shell — they do not launch
/// Claude/Codex, and their lifecycle does not affect agent state.
@MainActor
final class ShellManager {
    private var terminals: [String: LocalProcessTerminalView] = [:]
    var themeName: String = UserDefaults.standard.string(forKey: UserDefaultsKeys.terminalTheme) ?? "Catppuccin Mocha" {
        didSet { applyThemeToAll() }
    }

    /// Canonical key for a folder shell. Resolves symlinks and standardizes
    /// the path so different URL spellings of the same directory map to one
    /// shell instance.
    static func shellKey(forFolder url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func applyFontToAll() {
        let font = Self.terminalFont()
        for terminal in terminals.values {
            terminal.font = font
        }
    }

    private func applyThemeToAll() {
        for terminal in terminals.values {
            applyTheme(to: terminal)
        }
    }

    func terminal(forFolder folder: URL) -> LocalProcessTerminalView {
        let key = Self.shellKey(forFolder: folder)
        if let existing = terminals[key] {
            return existing
        }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = Self.terminalFont()
        applyTheme(to: terminal)
        terminals[key] = terminal

        // IMPORTANT: launch the shell on the next run loop tick. Synchronous
        // startProcess inside updateNSView causes a main-thread feedback loop
        // (beachball) because data callbacks re-enter SwiftUI updates.
        let shell = Self.userShell()
        let env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let cwd = key
        DispatchQueue.main.async {
            terminal.startProcess(
                executable: shell,
                args: [],
                environment: env,
                execName: (shell as NSString).lastPathComponent,
                currentDirectory: cwd
            )
        }

        return terminal
    }

    func sendCommand(_ command: String, inFolder folder: URL) {
        let terminal = terminal(forFolder: folder)
        let bytes = Array((command + "\n").utf8)
        terminal.send(source: terminal, data: ArraySlice(bytes))
    }

    func removeShell(forFolder folder: URL) {
        let key = Self.shellKey(forFolder: folder)
        if let terminal = terminals[key] {
            terminal.terminate()
        }
        terminals.removeValue(forKey: key)
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

    /// Read terminal font from Ghostty config, falling back to system monospace.
    /// Applies the user's font scale preference.
    static func terminalFont() -> NSFont {
        let scale = UserDefaults.standard.double(forKey: UserDefaultsKeys.fontScale)
        let effectiveScale = scale > 0 ? scale : 1.0
        let baseSize: CGFloat = 13
        let size = baseSize * effectiveScale

        if let fontName = UserDefaults.standard.string(forKey: UserDefaultsKeys.terminalFontName),
           let font = resolveFont(named: fontName, size: size) {
            return font
        }

        for fontName in ghosttyFontNames() {
            if let font = resolveFont(named: fontName, size: size) {
                return font
            }
        }
        return NSFont(name: "Monaco", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func resolveFont(named rawName: String, size: CGFloat) -> NSFont? {
        let name = cleanFontName(rawName)
        guard !name.isEmpty else { return nil }

        if let font = NSFont(name: name, size: size) {
            return font
        }

        let fontManager = NSFontManager.shared
        if let family = fontManager.availableFontFamilies.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
           let font = fontManager.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }

        for family in fontManager.availableFontFamilies {
            guard let members = fontManager.availableMembers(ofFontFamily: family) else { continue }
            for member in members {
                guard let fontName = member.first as? String else { continue }
                if fontName.caseInsensitiveCompare(name) == .orderedSame,
                   let font = NSFont(name: fontName, size: size) {
                    return font
                }
            }
        }

        return nil
    }

    private static func ghosttyFontNames() -> [String] {
        let home = NSHomeDirectory()
        let paths = [
            "\(home)/.config/ghostty/config",
            "\(home)/.config/ghostty/config.ghostty",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
        ]

        return paths.compactMap { path in
            guard let config = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return ghosttyFontName(in: config)
        }
    }

    private static func ghosttyFontName(in config: String) -> String? {
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key == "font-family" else { continue }

            let fontName = cleanFontName(String(parts[1]))
            if !fontName.isEmpty {
                return fontName
            }
        }

        return nil
    }

    private static func cleanFontName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commentStart = name.firstIndex(of: "#") {
            name = String(name[..<commentStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if name.count >= 2,
           let first = name.first,
           let last = name.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            name = String(name.dropFirst().dropLast())
        }

        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyTheme(to terminal: LocalProcessTerminalView) {
        guard let theme = GhosttyThemeLoader.load(named: themeName) else { return }
        TerminalTheming.applyTheme(theme, to: terminal)
    }
}
