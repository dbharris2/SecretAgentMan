import Foundation

// MARK: - Models

struct WindowUsage: Equatable {
    let usedPercent: Double
    let resetsAt: Date?
    let windowLabel: String
}

struct AgentRateLimits: Equatable {
    let shortWindow: WindowUsage
    let longWindow: WindowUsage
}

// MARK: - UsageMonitor

@MainActor @Observable
final class UsageMonitor {
    /// Rate limits are account-level, so stored per provider rather than per agent.
    var rateLimits: [AgentProvider: AgentRateLimits] = [:]

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored private let watcher = FileSystemWatcher()
    @ObservationIgnored private var watchedDirs: Set<URL> = []
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var refreshGeneration = 0

    init(store: AgentStore) {
        self.store = store
    }

    func start() {
        watcher.onDirectoryChanged = { [weak self] _ in
            self?.refreshSelectedAgent()
        }
        syncWatches()
        refreshSelectedAgent()

        // Periodic fallback — agent-status files may not trigger FSEvents on every update
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.refreshSelectedAgent()
            }
        }
    }

    func stop() {
        watcher.unwatchAll()
        watchedDirs.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Call when the selected agent changes to update watches and read current data.
    func syncWatches() {
        let needed = neededDirectories()
        let toRemove = watchedDirs.subtracting(needed)
        let toAdd = needed.subtracting(watchedDirs)

        for dir in toRemove {
            watcher.unwatch(directory: dir)
        }
        for dir in toAdd {
            watcher.watch(directory: dir)
        }
        watchedDirs = needed
    }

    func refreshSelectedAgent() {
        guard let agent = store.selectedAgent,
              agent.sessionId != nil
        else { return }

        let refreshStart = CFAbsoluteTimeGetCurrent()
        refreshGeneration += 1
        let generation = refreshGeneration
        let agentId = agent.id
        let provider = agent.provider
        Task.detached(priority: .background) {
            let limits: AgentRateLimits? =
                switch provider {
                case .claude:
                    Self.readLatestClaudeRateLimits()
                case .codex:
                    Self.readLatestCodexRateLimits()
                case .gemini:
                    // ACP `usage_update` notifications carry per-session usage,
                    // not account-level rate limits. Skip in V1.
                    nil
                }

            await MainActor.run {
                guard generation == self.refreshGeneration, self.store.selectedAgentId == agentId else { return }
                if let limits {
                    self.rateLimits[provider] = limits
                }
                PerfLogger.log("UsageMonitor.refreshSelectedAgent.total", start: refreshStart, details: "provider=\(provider)")
            }
        }
    }

    // MARK: - Private

    private func neededDirectories() -> Set<URL> {
        var dirs = Set<URL>()
        let claudeDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/agent-status")
        if FileManager.default.fileExists(atPath: claudeDir.path) {
            dirs.insert(claudeDir.standardizedFileURL)
        }
        let codexDir = SessionFileDetector.codexSessionsDir()
        if FileManager.default.fileExists(atPath: codexDir.path) {
            dirs.insert(codexDir.standardizedFileURL)
        }
        return dirs
    }

    // MARK: - Claude Parsing

    /// Rate limits are account-level. Scan agent-status `.json` files newest-first
    /// until one contains `rate_limits` — only TUI sessions write this field.
    private nonisolated static func readLatestClaudeRateLimits() -> AgentRateLimits? {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/agent-status")

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let sorted = entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                    .flatMap(\.contentModificationDate)
                else { return nil }
                return (url, modified)
            }
            .sorted { $0.date > $1.date }

        for entry in sorted {
            guard let data = try? Data(contentsOf: entry.url),
                  let limits = Self.parseClaudeAgentStatus(data)
            else { continue }
            return limits
        }
        return nil
    }

    nonisolated static func parseClaudeAgentStatus(_ data: Data) -> AgentRateLimits? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = json["rate_limits"] as? [String: Any]
        else { return nil }

        let short = parseWindow(
            rl["five_hour"] as? [String: Any],
            percentKey: "used_percentage",
            label: "5h"
        )
        let long = parseWindow(
            rl["seven_day"] as? [String: Any],
            percentKey: "used_percentage",
            label: "7d"
        )

        guard let short, let long else { return nil }
        return AgentRateLimits(shortWindow: short, longWindow: long)
    }

    // MARK: - Codex Parsing

    /// Rate limits are account-level, so read from the most recently modified Codex session file.
    private nonisolated static func readLatestCodexRateLimits() -> AgentRateLimits? {
        let dir = SessionFileDetector.codexSessionsDir()
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                  .flatMap(\.contentModificationDate)
            else { continue }
            if newest == nil || modified > newest!.date {
                newest = (url, modified)
            }
        }

        guard let fileURL = newest?.url,
              let content = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return nil }

        return Self.parseCodexSessionContent(content)
    }

    nonisolated static func parseCodexSessionContent(_ content: String) -> AgentRateLimits? {
        let lines = content.components(separatedBy: .newlines)
        for line in lines.reversed() {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rl = payload["rate_limits"] as? [String: Any]
            else { continue }

            let short = parseWindow(
                rl["primary"] as? [String: Any],
                percentKey: "used_percent",
                label: "5h"
            )
            let long = parseWindow(
                rl["secondary"] as? [String: Any],
                percentKey: "used_percent",
                label: "7d"
            )

            guard let short, let long else { continue }
            return AgentRateLimits(shortWindow: short, longWindow: long)
        }

        return nil
    }

    // MARK: - Shared Parsing

    nonisolated static func parseWindow(
        _ dict: [String: Any]?,
        percentKey: String,
        label: String
    ) -> WindowUsage? {
        guard let dict,
              let percent = dict[percentKey] as? Double
        else { return nil }

        let resetsAt: Date? =
            if let epoch = dict["resets_at"] as? TimeInterval {
                Date(timeIntervalSince1970: epoch)
            } else {
                nil
            }

        let windowLabel: String =
            if let minutes = dict["window_minutes"] as? Int {
                switch minutes {
                case ..<120: "\(minutes)m"
                case ..<1440: "\(minutes / 60)h"
                default: "\(minutes / 1440)d"
                }
            } else {
                label
            }

        return WindowUsage(usedPercent: percent, resetsAt: resetsAt, windowLabel: windowLabel)
    }
}
