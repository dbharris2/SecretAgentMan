import Foundation

enum MCPConfigLoader {
    static func loadServerNames(in directory: URL) -> [String] {
        let mcpFile = directory.appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: mcpFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any]
        else { return [] }
        return servers.keys.sorted()
    }

    static func loadPluginNames(for provider: AgentProvider) -> [String] {
        switch provider {
        case .claude:
            guard let plugins = loadClaudeInstalledPlugins() else { return [] }
            return plugins.keys.map { $0.components(separatedBy: "@").first ?? $0 }.sorted()
        case .codex:
            return loadCodexPluginNames()
        case .gemini:
            // Gemini extensions/plugins are not surfaced in V1; ACP-managed
            // sessions advertise their slash commands via `available_commands_update`.
            return []
        }
    }

    static func loadSkills(in directory: URL, provider: AgentProvider = .claude) -> [SkillInfo] {
        var skills: [SkillInfo] = []

        // Repo-local skills
        let repoSkillDir = provider == .claude ? ".claude/skills" : ".codex/skills"
        skills.append(contentsOf: scanSkillsDir(
            directory.appendingPathComponent(repoSkillDir), source: "local"
        ))

        switch provider {
        case .claude:
            let pluginDir = UserDefaults.standard.string(forKey: UserDefaultsKeys.claudePluginDirectory) ?? ""
            if !pluginDir.isEmpty {
                let expanded = (pluginDir as NSString).expandingTildeInPath
                let pluginDirURL = URL(fileURLWithPath: expanded)
                let pluginName = pluginDirURL.lastPathComponent

                skills.append(contentsOf: scanSkillsDir(
                    pluginDirURL.appendingPathComponent("skills"), source: pluginName
                ))

                if let entries = try? FileManager.default.contentsOfDirectory(
                    at: pluginDirURL, includingPropertiesForKeys: nil
                ) {
                    for entry in entries where entry.lastPathComponent != "skills" {
                        skills.append(contentsOf: scanSkillsDir(
                            entry.appendingPathComponent("skills"), source: entry.lastPathComponent
                        ))
                    }
                }
            }

            if let plugins = loadClaudeInstalledPlugins() {
                for (key, value) in plugins {
                    let name = key.components(separatedBy: "@").first ?? key
                    guard let entries = value as? [[String: Any]],
                          let first = entries.first,
                          let installPath = first["installPath"] as? String
                    else { continue }
                    skills.append(contentsOf: scanSkillsDir(
                        URL(fileURLWithPath: installPath).appendingPathComponent("skills"),
                        source: name
                    ))
                }
            }
        case .codex:
            skills.append(contentsOf: scanSkillsDir(
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/skills"),
                source: "codex"
            ))
            for plugin in loadCodexPluginEntries() {
                skills.append(contentsOf: scanSkillsDir(
                    plugin.appendingPathComponent("skills"),
                    source: plugin.lastPathComponent
                ))
            }
        case .gemini:
            // No skills concept for Gemini in V1.
            break
        }

        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Private

    private static func loadClaudeInstalledPlugins() -> [String: Any]? {
        let pluginsFile = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: pluginsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any]
        else { return nil }
        return plugins
    }

    private static func loadCodexPluginNames() -> [String] {
        loadCodexPluginEntries()
            .map(\.lastPathComponent)
            .sorted()
    }

    private static func loadCodexPluginEntries() -> [URL] {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/plugins/cache")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.filter {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
    }

    private static func scanSkillsDir(_ skillsDir: URL, source: String) -> [SkillInfo] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries.compactMap { entry in
            parseSkillFile(entry.appendingPathComponent("SKILL.md"), source: source)
        }
    }

    private static func parseSkillFile(_ url: URL, source: String) -> SkillInfo? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            if line == "---" { break }
            if line.hasPrefix("name:") {
                name = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("description:") {
                description = line.dropFirst(12).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let skillName = name else { return nil }
        return SkillInfo(name: skillName, description: description ?? "", source: source)
    }
}
