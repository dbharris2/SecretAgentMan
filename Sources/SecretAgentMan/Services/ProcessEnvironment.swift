import Foundation

enum ProcessEnvironment {
    static func interactive(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let homeDirectory = base["HOME"] ?? NSHomeDirectory()

        environment["HOME"] = homeDirectory
        environment["PATH"] = mergedPath(
            currentPath: base["PATH"],
            homeDirectory: homeDirectory
        )

        return environment
    }

    static func interactiveArray(base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        environmentArray(interactive(base: base))
    }

    static func interactiveTerminal(
        base: [String: String] = ProcessInfo.processInfo.environment,
        shell: String? = nil
    ) -> [String: String] {
        var environment = interactive(base: base)

        environment["TERM"] = "xterm-256color"
        if environment["COLORTERM"]?.isEmpty ?? true {
            environment["COLORTERM"] = "truecolor"
        }
        if environment["LANG"]?.isEmpty ?? true {
            environment["LANG"] = "en_US.UTF-8"
        }
        if let shell, !shell.isEmpty {
            environment["SHELL"] = shell
        }

        return environment
    }

    static func interactiveTerminalArray(
        base: [String: String] = ProcessInfo.processInfo.environment,
        shell: String? = nil
    ) -> [String] {
        environmentArray(interactiveTerminal(base: base, shell: shell))
    }

    static func environmentArray(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().map { key in
            "\(key)=\(environment[key] ?? "")"
        }
    }

    static func mergedPath(currentPath: String?, homeDirectory: String = NSHomeDirectory()) -> String {
        let candidates = userSearchPaths(homeDirectory: homeDirectory)
            + pathComponents(currentPath)
            + systemSearchPaths
        var seen = Set<String>()
        var result: [String] = []

        for candidate in candidates {
            let path = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(path)
        }

        return result.joined(separator: ":")
    }

    private static let systemSearchPaths = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    private static func userSearchPaths(homeDirectory: String) -> [String] {
        let home = homeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let homePrefix = home.isEmpty ? "" : "/\(home)"

        return [
            "\(homePrefix)/.local/bin",
            "\(homePrefix)/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ]
    }

    private static func pathComponents(_ path: String?) -> [String] {
        path?.split(separator: ":", omittingEmptySubsequences: false).map(String.init) ?? []
    }
}
