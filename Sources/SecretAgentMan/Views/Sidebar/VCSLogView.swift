import SwiftUI

struct VCSLogView: View {
    struct CommandSpec: Equatable {
        let executablePath: String
        let arguments: [String]
        let perfLabel: String
    }

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appTheme) private var theme
    @State private var parsedLog = AttributedString()
    @State private var isLoading = false
    @State private var isVisible = false
    @State private var latestRequestID = 0
    @State private var debounceTask: Task<Void, Never>?

    private let vcsDebounceDelay: Duration = .milliseconds(400)

    private var folder: URL? {
        coordinator.store.selectedAgent?.folder
    }

    private var vcsType: DiffService.VCSType {
        guard let folder else { return .none }
        return coordinator.repositoryMonitor.vcsType(for: folder) ?? DiffService().detectVCS(in: folder)
    }

    var body: some View {
        Group {
            if parsedLog.characters.isEmpty, !isLoading {
                ContentUnavailableView(
                    Self.emptyStateTitle(for: vcsType),
                    systemImage: "arrow.triangle.branch",
                    description: Text(Self.emptyStateDescription(for: vcsType))
                )
            } else {
                ScrollView(.vertical) {
                    Text(parsedLog)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(Spacing.xxl)
                }
            }
        }
        .background(theme.surface)
        .onAppear {
            isVisible = true
            loadLog(trigger: "appear")
        }
        .onDisappear {
            isVisible = false
            debounceTask?.cancel()
            debounceTask = nil
        }
        .onChange(of: coordinator.store.selectedAgentId) { _, _ in
            guard isVisible else { return }
            loadLog(trigger: "selectedAgentChanged")
        }
        .onChange(of: coordinator.repositoryMonitor.vcsChangeCount) { _, _ in
            guard isVisible,
                  let folder,
                  coordinator.repositoryMonitor.lastVCSChangedFolder?.standardizedFileURL == folder.standardizedFileURL
            else { return }
            scheduleDebouncedLoad(trigger: "vcsChange")
        }
    }

    private func scheduleDebouncedLoad(trigger: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            do {
                try await Task.sleep(for: vcsDebounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isVisible else { return }
                loadLog(trigger: "\(trigger):debounced")
            }
        }
    }

    private func loadLog(trigger: String) {
        guard isVisible else { return }
        guard let folder else {
            parsedLog = AttributedString()
            return
        }
        latestRequestID += 1
        let requestID = latestRequestID
        isLoading = true
        let currentTheme = theme
        let loadStart = CFAbsoluteTimeGetCurrent()
        let vcsType = self.vcsType
        Task.detached {
            let t0 = CFAbsoluteTimeGetCurrent()
            let output = Self.runLog(in: folder, vcsType: vcsType)
            PerfLogger.log("VCSLogView.runLog", start: t0, details: "folder=\(folder.lastPathComponent) vcs=\(vcsType.displayName)")
            let t1 = CFAbsoluteTimeGetCurrent()
            let parsed = Self.parseANSI(output, theme: currentTheme)
            PerfLogger.log("VCSLogView.parseANSI", start: t1, details: "folder=\(folder.lastPathComponent)")
            await MainActor.run {
                guard requestID == latestRequestID else { return }
                parsedLog = parsed
                isLoading = false
                PerfLogger.log("VCSLogView.loadLog.total", start: loadStart, details: "folder=\(folder.lastPathComponent) trigger=\(trigger)")
            }
        }
    }

    private nonisolated static func emptyStateTitle(for vcsType: DiffService.VCSType) -> String {
        switch vcsType {
        case .jj:
            "No JJ Log"
        case .graphite:
            "No Graphite Log"
        case .git, .none:
            "No VCS Log"
        }
    }

    private nonisolated static func emptyStateDescription(for vcsType: DiffService.VCSType) -> String {
        switch vcsType {
        case .jj:
            "Select an agent in a Jujutsu repository."
        case .graphite:
            "Select an agent in a Graphite-initialized repository."
        case .git:
            "Plain Git repositories do not have a VCS log panel."
        case .none:
            "Select an agent in a Jujutsu or Graphite repository."
        }
    }

    nonisolated static func commandSpec(for vcsType: DiffService.VCSType) -> CommandSpec? {
        switch vcsType {
        case .jj:
            guard let executablePath = executablePath(candidates: [
                NSHomeDirectory() + "/.local/bin/jj",
                NSHomeDirectory() + "/.cargo/bin/jj",
                "/opt/homebrew/bin/jj",
                "/usr/local/bin/jj",
            ]) else {
                return nil
            }
            return CommandSpec(
                executablePath: executablePath,
                arguments: ["log", "--no-pager", "--color=always", "--limit=50"],
                perfLabel: "jj"
            )
        case .graphite:
            guard let executablePath = executablePath(candidates: [
                NSHomeDirectory() + "/.local/bin/gt",
                "/opt/homebrew/bin/gt",
                "/usr/local/bin/gt",
            ]) else {
                return nil
            }
            return CommandSpec(
                executablePath: executablePath,
                arguments: ["log", "short", "--no-interactive"],
                perfLabel: "graphite"
            )
        case .git, .none:
            return nil
        }
    }

    private nonisolated static func executablePath(candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func runLog(in folder: URL, vcsType: DiffService.VCSType) -> String {
        guard let spec = commandSpec(for: vcsType) else {
            return switch vcsType {
            case .jj:
                "jj not found. Install with: brew install jj"
            case .graphite:
                "gt not found. Install Graphite CLI first."
            case .git:
                "Plain Git repositories do not have a VCS log panel."
            case .none:
                ""
            }
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: spec.executablePath)
        process.arguments = spec.arguments
        process.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Failed to run \(spec.perfLabel): \(error.localizedDescription)"
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            if !error.isEmpty { return error }
            if !output.isEmpty { return output }
            return "Failed to run \(spec.perfLabel)."
        }

        return output
    }

    // MARK: - ANSI Color Parsing

    private nonisolated static let ansi256Base = [30, 31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97]

    private nonisolated static func colorForBasicCode(_ code: Int, theme: AppTheme) -> Color? {
        switch code {
        case 30, 90: theme.foreground.opacity(0.5)
        case 31, 91: theme.red
        case 32, 92: theme.green
        case 33, 93: theme.yellow
        case 34, 94: theme.blue
        case 35, 95: theme.magenta
        case 36, 96: theme.cyan
        case 37, 97: theme.foreground
        default: nil
        }
    }

    private nonisolated static func applySGR(_ codes: [Int], color: inout Color?, bold: inout Bool, theme: AppTheme) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            if code == 0 {
                color = nil
                bold = false
            } else if code == 1 {
                bold = true
            } else if code == 38, i + 2 < codes.count, codes[i + 1] == 5 {
                // 256-color: 38;5;N — map 0-15 to theme, others to default
                let n = codes[i + 2]
                color = n < 16 ? colorForBasicCode(ansi256Base[n], theme: theme) : theme.foreground
                i += 2
            } else if code == 39 {
                color = nil
            } else if let c = colorForBasicCode(code, theme: theme) {
                color = c
            }
            i += 1
        }
    }

    nonisolated static func parseANSI(_ input: String, theme: AppTheme) -> AttributedString {
        var result = AttributedString()
        var currentColor: Color?
        var isBold = false

        let scanner = Scanner(string: input)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            if let text = scanner.scanUpToString("\u{1B}") {
                var attrs = AttributeContainer()
                if let color = currentColor { attrs.foregroundColor = color }
                if isBold { attrs.font = .system(size: 12, weight: .bold, design: .monospaced) }
                result.append(AttributedString(text, attributes: attrs))
            }

            guard scanner.scanString("\u{1B}[") != nil else {
                if !scanner.isAtEnd {
                    let idx = scanner.currentIndex
                    scanner.currentIndex = input.index(after: idx)
                    result.append(AttributedString(String(input[idx])))
                }
                continue
            }

            let params = scanner.scanUpToString("m") ?? ""
            _ = scanner.scanString("m")

            let codes = params.split(separator: ";").compactMap { Int($0) }
            applySGR(codes, color: &currentColor, bold: &isBold, theme: theme)
        }

        return result
    }
}
