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

    static func loadPluginNames() -> [String] {
        guard let plugins = loadInstalledPlugins() else { return [] }
        return plugins.keys.map { $0.components(separatedBy: "@").first ?? $0 }.sorted()
    }

    static func loadSkills(in directory: URL) -> [SkillInfo] {
        var skills: [SkillInfo] = []

        // Repo-local skills
        skills.append(contentsOf: scanSkillsDir(
            directory.appendingPathComponent(".claude/skills"), source: "local"
        ))

        // Local plugin directory skills
        let pluginDir = UserDefaults.standard.string(forKey: UserDefaultsKeys.pluginDirectory) ?? ""
        if !pluginDir.isEmpty {
            let expanded = (pluginDir as NSString).expandingTildeInPath
            let pluginDirURL = URL(fileURLWithPath: expanded)
            let pluginName = pluginDirURL.lastPathComponent

            // Plugin dir is the plugin itself
            skills.append(contentsOf: scanSkillsDir(
                pluginDirURL.appendingPathComponent("skills"), source: pluginName
            ))

            // Plugin dir contains multiple plugins
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

        // Marketplace plugin skills
        if let plugins = loadInstalledPlugins() {
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

        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Private

    private static func loadInstalledPlugins() -> [String: Any]? {
        let pluginsFile = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: pluginsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any]
        else { return nil }
        return plugins
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
