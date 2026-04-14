import SwiftUI

struct JJLogView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.appTheme) private var theme
    @State private var logOutput = ""
    @State private var isLoading = false

    private var folder: URL? {
        coordinator.store.selectedAgent?.folder
    }

    var body: some View {
        Group {
            if logOutput.isEmpty, !isLoading {
                ContentUnavailableView(
                    "No JJ Log",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Select an agent in a jj repository.")
                )
            } else {
                ScrollView(.vertical) {
                    Text(Self.parseANSI(logOutput, theme: theme))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
        }
        .background(theme.surface)
        .onAppear { loadLog() }
        .onChange(of: coordinator.store.selectedAgentId) { _, _ in loadLog() }
        .onChange(of: coordinator.repositoryMonitor.vcsChangeCount) { _, _ in loadLog() }
        .toolbar {
            ToolbarItem {
                Button {
                    loadLog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh JJ log")
            }
        }
    }

    private func loadLog() {
        guard let folder else {
            logOutput = ""
            return
        }
        isLoading = true
        Task.detached {
            let output = Self.runJJ(in: folder)
            await MainActor.run {
                logOutput = output
                isLoading = false
            }
        }
    }

    private nonisolated static func jjPath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/jj",
            NSHomeDirectory() + "/.cargo/bin/jj",
            "/opt/homebrew/bin/jj",
            "/usr/local/bin/jj",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func runJJ(in folder: URL) -> String {
        guard let jj = jjPath() else {
            return "jj not found. Install with: brew install jj"
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: jj)
        process.arguments = ["log", "--no-pager", "--color=always"]
        process.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Failed to run jj: \(error.localizedDescription)"
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - ANSI Color Parsing

    private static let ansi256Base = [30, 31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97]

    private static func colorForBasicCode(_ code: Int, theme: AppTheme) -> Color? {
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

    private static func applySGR(_ codes: [Int], color: inout Color?, bold: inout Bool, theme: AppTheme) {
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

    static func parseANSI(_ input: String, theme: AppTheme) -> AttributedString {
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
