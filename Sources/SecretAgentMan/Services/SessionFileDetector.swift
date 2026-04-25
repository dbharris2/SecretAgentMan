import Foundation

/// Detects the actual Claude Code session ID by scanning session files
/// or Codex session ID by scanning provider-specific local state.
enum SessionFileDetector {
    struct SessionRecord: Identifiable, Equatable {
        let id: String
        let modifiedAt: Date?
        let firstMessage: String?

        var displayName: String {
            if let firstMessage, !firstMessage.isEmpty {
                return String(firstMessage.prefix(80))
            }
            return id
        }
    }

    /// Convert an agent's folder URL to the Claude project directory path.
    static func claudeProjectDir(for folder: URL) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let projectKey = folder.path.replacingOccurrences(of: "/", with: "-")
        return home.appendingPathComponent(".claude/projects/\(projectKey)")
    }

    static func sessionDirectory(for agent: Agent) -> URL {
        switch agent.provider {
        case .claude:
            claudeProjectDir(for: agent.folder)
        case .codex:
            codexSessionsDir()
        case .gemini:
            // Gemini sessions live behind ACP `session/load`; SAM doesn't
            // detect or list them on disk in V1.
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/tmp")
        }
    }

    static func codexSessionsDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// Check if a session file exists for the given session ID in an agent's project directory.
    static func sessionFileExists(_ sessionId: String, for agent: Agent) -> Bool {
        switch agent.provider {
        case .claude:
            sessionFileExists(sessionId, inDirectory: claudeProjectDir(for: agent.folder))
        case .codex:
            codexSessionFile(for: sessionId) != nil
        case .gemini:
            // Existence is decided by the agent's `loadSession` capability +
            // ACP response, not the local filesystem.
            false
        }
    }

    /// Check if a session file exists in a directory.
    static func sessionFileExists(_ sessionId: String, inDirectory dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(sessionId).jsonl").path)
    }

    /// Find the most recently modified .jsonl session file for an agent folder.
    /// Returns the session ID (filename without extension) or nil.
    static func latestSessionId(for agent: Agent) -> String? {
        availableSessions(for: agent).first?.id
    }

    static func availableSessions(for agent: Agent) -> [SessionRecord] {
        switch agent.provider {
        case .claude:
            sessions(inDirectory: claudeProjectDir(for: agent.folder))
        case .codex:
            codexSessions(for: agent.folder)
        case .gemini:
            // No local session enumeration in V1.
            []
        }
    }

    static func availableSessions(for agent: Agent, inClaudeDirectory dir: URL) -> [SessionRecord] {
        guard agent.provider == .claude else { return [] }
        return sessions(inDirectory: dir)
    }

    static func availableSessions(for agent: Agent, inCodexDirectory dir: URL) -> [SessionRecord] {
        guard agent.provider == .codex else { return [] }
        return codexSessions(for: agent.folder, inDirectory: dir)
    }

    /// Find the most recently modified .jsonl session file in a directory.
    static func latestSessionId(inDirectory dir: URL) -> String? {
        sessions(inDirectory: dir).first?.id
    }

    static func latestCodexSessionId(for folder: URL) -> String? {
        latestCodexSessionId(for: folder, inDirectory: codexSessionsDir())
    }

    static func latestCodexSessionId(for folder: URL, inDirectory dir: URL) -> String? {
        codexSessions(for: folder, inDirectory: dir).first?.id
    }

    static func codexSessionFileExists(_ sessionId: String, inDirectory dir: URL) -> Bool {
        codexSessionFile(for: sessionId, inDirectory: dir) != nil
    }

    static func parseCodexSessionMetaLine(_ line: String) -> (id: String, cwd: String)? {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String,
              type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String
        else { return nil }

        return (id, cwd)
    }

    /// Returns the file URL for a Codex session with the given ID, or nil if not found.
    static func codexSessionFileURL(for sessionId: String) -> URL? {
        codexSessionFile(for: sessionId, inDirectory: codexSessionsDir())
    }

    private static func codexSessionFile(for sessionId: String) -> URL? {
        codexSessionFile(for: sessionId, inDirectory: codexSessionsDir())
    }

    private static func codexSessionFile(for sessionId: String, inDirectory dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if parseCodexSessionMeta(at: url)?.id == sessionId {
                return url
            }
        }
        return nil
    }

    private static func sessions(inDirectory dir: URL) -> [SessionRecord] {
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return entries
            .filter { $0.pathExtension == "jsonl" }
            .map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                    .flatMap(\.contentModificationDate)
                return SessionRecord(
                    id: url.deletingPathExtension().lastPathComponent,
                    modifiedAt: modified,
                    firstMessage: firstClaudeUserMessage(at: url)
                )
            }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    private static func codexSessions(for folder: URL) -> [SessionRecord] {
        codexSessions(for: folder, inDirectory: codexSessionsDir())
    }

    private static func codexSessions(for folder: URL, inDirectory dir: URL) -> [SessionRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var matches: [SessionRecord] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let meta = parseCodexSessionMeta(at: url),
                  URL(fileURLWithPath: meta.cwd).standardizedFileURL == folder.standardizedFileURL
            else { continue }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])).flatMap(\.contentModificationDate)
            matches.append(SessionRecord(id: meta.id, modifiedAt: modified, firstMessage: firstCodexUserMessage(at: url)))
        }
        return matches.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    private static func parseCodexSessionMeta(at url: URL) -> (id: String, cwd: String)? {
        // Session meta lines can be very large (15KB+) due to embedded base_instructions.
        // Read enough to capture the full first line.
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 32768),
              let firstLine = String(data: data, encoding: .utf8)?
              .components(separatedBy: .newlines)
              .first
        else { return nil }

        return parseCodexSessionMetaLine(firstLine)
    }

    // MARK: - First user message extraction

    /// Extract the first user-typed message from a Claude session JSONL file.
    /// Reads only enough data to find the first user message (up to 256KB).
    private static func firstClaudeUserMessage(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 262_144),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "user",
                  object["userType"] != nil,
                  let message = object["message"] as? [String: Any]
            else { continue }

            let text: String
            if let str = message["content"] as? String {
                text = str.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                continue
            }

            if !text.isEmpty {
                return String(text.prefix(200))
            }
        }
        return nil
    }

    /// Extract the first user message from a Codex session JSONL file.
    private static func firstCodexUserMessage(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 262_144),
              let content = String(data: data, encoding: .utf8)
        else { return nil }

        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user"
            else { continue }

            let text = extractTextContent(from: payload["content"])
            if !text.isEmpty {
                return String(text.prefix(200))
            }
        }
        return nil
    }

    private static func extractTextContent(from content: Any?) -> String {
        if let str = content as? String {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard let type = block["type"] as? String,
                      type == "input_text" || type == "text"
                else { return nil }
                return block["text"] as? String
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Look up the first user message for a specific session.
    static func firstUserMessage(sessionId: String, for agent: Agent) -> String? {
        switch agent.provider {
        case .claude:
            let dir = claudeProjectDir(for: agent.folder)
            let url = dir.appendingPathComponent("\(sessionId).jsonl")
            return firstClaudeUserMessage(at: url)
        case .codex:
            guard let url = codexSessionFileURL(for: sessionId) else { return nil }
            return firstCodexUserMessage(at: url)
        case .gemini:
            // Loaded history reaches the snapshot via ACP `session/update`
            // notifications instead of disk scraping.
            return nil
        }
    }
}
