import Foundation
import OSLog
import SwiftTerm

@MainActor
final class AgentProcessManager {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.secretagentman", category: "AgentProcess")

    func startAgent(
        terminal: LocalProcessTerminalView,
        agent: Agent,
        initialPrompt: String? = nil,
        sessionId: String? = nil,
        hasLaunched: Bool = false
    ) {
        let launch = Self.buildLaunchConfiguration(
            provider: agent.provider,
            folder: agent.folder,
            initialPrompt: initialPrompt,
            sessionId: sessionId,
            hasLaunched: hasLaunched
        )

        let env = currentEnvironment()
        let launchSummary =
            "Launching \(agent.provider.executableName): \(launch.executable) \(launch.args.joined(separator: " "))"
        let stateSummary =
            "cwd=\(agent.folder.path) hasLaunched=\(hasLaunched) sessionId=\(sessionId ?? "nil") prompt=\(initialPrompt != nil ? "yes" : "nil")"

        Self.logger
            .info(
                "\(launchSummary) | \(stateSummary)"
            )

        terminal.startProcess(
            executable: launch.executable,
            args: launch.args,
            environment: env,
            execName: agent.provider.executableName,
            currentDirectory: agent.folder.path
        )
    }

    static func buildLaunchConfiguration(
        provider: AgentProvider,
        folder: URL,
        initialPrompt: String? = nil,
        sessionId: String? = nil,
        hasLaunched: Bool = false
    ) -> (executable: String, args: [String]) {
        switch provider {
        case .claude:
            (
                executable: executablePath(for: .claude),
                args: claudeArgs(initialPrompt: initialPrompt, sessionId: sessionId, hasLaunched: hasLaunched)
            )
        case .codex:
            (
                executable: executablePath(for: .codex),
                args: codexArgs(folder: folder, initialPrompt: initialPrompt, sessionId: sessionId, hasLaunched: hasLaunched)
            )
        }
    }

    nonisolated static func executablePath(for provider: AgentProvider) -> String {
        let candidates: [String] = switch provider {
        case .claude:
            [
                NSHomeDirectory() + "/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ]
        case .codex:
            [
                NSHomeDirectory() + "/.local/bin/codex",
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex",
            ]
        }

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return provider.executableName
    }

    private static func claudeArgs(
        initialPrompt: String?,
        sessionId: String?,
        hasLaunched: Bool
    ) -> [String] {
        var args = ["--enable-auto-mode"]

        if let sessionId {
            if hasLaunched {
                args.append(contentsOf: ["--resume", sessionId])
                Self.logger.info("Resuming Claude session \(sessionId)")
            } else {
                args.append(contentsOf: ["--session-id", sessionId])
                Self.logger.info("Starting Claude session \(sessionId)")
            }
        } else {
            Self.logger.warning("No Claude session ID — session will not be resumable")
        }

        let pluginDir = (UserDefaults.standard.string(forKey: UserDefaultsKeys.claudePluginDirectory) ?? "")
            .replacingOccurrences(of: "~", with: NSHomeDirectory())
        if !pluginDir.isEmpty {
            args.append(contentsOf: ["--plugin-dir", pluginDir])
        }

        if let prompt = initialPrompt, !prompt.isEmpty {
            args.append(prompt)
        }

        return args
    }

    private static func codexArgs(
        folder: URL,
        initialPrompt: String?,
        sessionId: String?,
        hasLaunched: Bool
    ) -> [String] {
        var args = ["--full-auto", "--cd", folder.path]

        if let sessionId, hasLaunched {
            args.append("resume")
            args.append(sessionId)
            Self.logger.info("Resuming Codex session \(sessionId)")
        } else if let prompt = initialPrompt, !prompt.isEmpty {
            args.append(prompt)
        }

        return args
    }

    private func currentEnvironment() -> [String] {
        ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
    }
}
