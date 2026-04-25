import Foundation

/// Reads gemini-cli's on-disk session JSON to recover per-tool-call data
/// that gemini's ACP `streamHistory` (the `session/load` replay path)
/// discards.
///
/// gemini-cli persists every session — TUI and `--acp` — to
/// `~/.gemini/tmp/<projectSlug>/chats/session-<timestamp>-<idPrefix>.json`.
/// Each persisted tool call has rich fields (`name`, `displayName`, `args`,
/// `description`, `result`, `resultDisplay`) but `streamHistory` only emits
/// `title: displayName || name` over ACP, throwing the descriptive
/// `description` away. This sidecar reads the same JSON ourselves so we
/// can substitute the descriptive title during load replay.
///
/// This is a workaround for gemini-cli's asymmetric replay path
/// (`acpClient.ts:13226` vs the live execution `:13554` / `:13999`). When
/// upstream sends `description` in `streamHistory`, this whole file can be
/// deleted.
enum GeminiSessionSidecar {
    /// Per-tool-call sidecar fields recovered from disk. Keyed by
    /// `toolCallId` to match against ACP `tool_call` notifications.
    struct ToolCallInfo: Equatable {
        let description: String
        let displayName: String
        let name: String
    }

    /// Locates and parses the on-disk session JSON for the given sessionId
    /// and project root, returning a map keyed by `toolCallId`.
    /// Fails-soft: returns an empty map if the file isn't found or can't
    /// be parsed. Never throws.
    static func toolCallInfo(forSessionId sessionId: String, projectRoot: URL) -> [String: ToolCallInfo] {
        guard let chatsDir = chatsDirectory(for: projectRoot),
              let sessionFile = sessionFile(in: chatsDir, sessionId: sessionId),
              let data = try? Data(contentsOf: sessionFile),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = raw["messages"] as? [[String: Any]]
        else { return [:] }

        var result: [String: ToolCallInfo] = [:]
        for message in messages {
            guard let toolCalls = message["toolCalls"] as? [[String: Any]] else { continue }
            for tc in toolCalls {
                guard let id = tc["id"] as? String else { continue }
                let description = (tc["description"] as? String) ?? ""
                let displayName = (tc["displayName"] as? String) ?? ""
                let name = (tc["name"] as? String) ?? ""
                guard !description.isEmpty || !displayName.isEmpty || !name.isEmpty else { continue }
                result[id] = ToolCallInfo(
                    description: description,
                    displayName: displayName,
                    name: name
                )
            }
        }
        return result
    }

    /// Resolves `~/.gemini/tmp/<slug>/chats/` for a given working directory
    /// by matching `.project_root` files against the supplied path. Returns
    /// `nil` if no matching project slug is found.
    private static func chatsDirectory(for projectRoot: URL) -> URL? {
        let geminiTmp = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".gemini/tmp")
        guard let slugs = try? FileManager.default.contentsOfDirectory(
            at: geminiTmp,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let target = projectRoot.standardizedFileURL.path
        for slug in slugs {
            let projectRootFile = slug.appendingPathComponent(".project_root")
            guard let recorded = try? String(contentsOf: projectRootFile, encoding: .utf8) else {
                continue
            }
            let trimmed = recorded.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == target {
                return slug.appendingPathComponent("chats")
            }
        }
        return nil
    }

    /// Finds the most recent session-*.json file whose embedded `sessionId`
    /// matches. The filename only contains the first 8 chars of the id, so
    /// we have to read each candidate's contents to disambiguate. Returns
    /// the latest by `lastUpdated` since gemini may write multiple files
    /// for the same sessionId across runs.
    private static func sessionFile(in chatsDir: URL, sessionId: String) -> URL? {
        let prefix = String(sessionId.prefix(8))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: chatsDir,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let candidates = entries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("session-") && name.hasSuffix(".json") && name.contains(prefix)
        }

        var best: (url: URL, lastUpdated: String)?
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  raw["sessionId"] as? String == sessionId
            else { continue }
            let lastUpdated = (raw["lastUpdated"] as? String) ?? ""
            if let current = best {
                if lastUpdated > current.lastUpdated {
                    best = (url, lastUpdated)
                }
            } else {
                best = (url, lastUpdated)
            }
        }
        return best?.url
    }
}
