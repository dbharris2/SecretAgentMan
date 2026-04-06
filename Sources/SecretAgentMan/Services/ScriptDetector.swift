import Foundation

enum ScriptDetector {
    static func detectScripts(in directory: URL) -> [ProjectScript] {
        var scripts: [ProjectScript] = []
        scripts.append(contentsOf: parseNPM(in: directory))
        scripts.append(contentsOf: parseJustfile(in: directory))
        scripts.append(contentsOf: parseMakefile(in: directory))
        scripts.append(contentsOf: parseCargo(in: directory))
        scripts.append(contentsOf: parsePyproject(in: directory))
        return scripts
    }

    // MARK: - package.json (npm / yarn / bun)

    private static func parseNPM(in directory: URL) -> [ProjectScript] {
        let file = directory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any]
        else { return [] }
        let (runner, source) = detectPackageManager(in: directory)
        return scripts.keys.sorted().map { name in
            ProjectScript(name: name, command: "\(runner) run \(name)", source: source)
        }
    }

    private static func detectPackageManager(in directory: URL) -> (runner: String, source: ProjectScript.ScriptSource) {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("bun.lockb").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("bun.lock").path) {
            return ("bun", .bun)
        }
        if fm.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) {
            return ("yarn", .yarn)
        }
        return ("npm", .npm)
    }

    private static func firstReadableFile(in directory: URL, candidates: [String]) -> String? {
        for candidate in candidates {
            let file = directory.appendingPathComponent(candidate)
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                return content
            }
        }
        return nil
    }

    // MARK: - just (Justfile)

    private static func parseJustfile(in directory: URL) -> [ProjectScript] {
        guard let content = firstReadableFile(in: directory, candidates: ["Justfile", "justfile", ".justfile"])
        else { return [] }
        return parseJustfileContent(content)
    }

    static func parseJustfileContent(_ content: String) -> [ProjectScript] {
        // Match recipe headers: lines starting with a name followed by optional params and a colon
        let pattern = #"^([a-zA-Z_][a-zA-Z0-9_-]*)\s*(?:[^:]*)?:"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return []
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        return matches.compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: content) else { return nil }
            let name = String(content[nameRange])
            return ProjectScript(name: name, command: "just \(name)", source: .just)
        }
    }

    // MARK: - make (Makefile)

    private static func parseMakefile(in directory: URL) -> [ProjectScript] {
        guard let content = firstReadableFile(in: directory, candidates: ["Makefile", "GNUmakefile", "makefile"])
        else { return [] }
        return parseMakefileContent(content)
    }

    static func parseMakefileContent(_ content: String) -> [ProjectScript] {
        // Collect .PHONY targets if declared
        var phonyTargets: Set<String> = []
        let phonyPattern = #"^\.PHONY\s*:\s*(.+)$"#
        if let phonyRegex = try? NSRegularExpression(pattern: phonyPattern, options: .anchorsMatchLines) {
            let range = NSRange(content.startIndex..., in: content)
            for match in phonyRegex.matches(in: content, range: range) {
                if let targetsRange = Range(match.range(at: 1), in: content) {
                    let targets = content[targetsRange].split(separator: " ").map(String.init)
                    phonyTargets.formUnion(targets)
                }
            }
        }

        // Match target lines: name followed by colon (skip dot-prefixed and variable assignments)
        let targetPattern = #"^([a-zA-Z_][a-zA-Z0-9_-]*)\s*:"#
        guard let regex = try? NSRegularExpression(pattern: targetPattern, options: .anchorsMatchLines) else {
            return []
        }
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        var seen: Set<String> = []
        var scripts: [ProjectScript] = []
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: content) else { continue }
            let name = String(content[nameRange])
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            // If .PHONY declarations exist, only show phony targets (the "runnable" ones)
            if !phonyTargets.isEmpty, !phonyTargets.contains(name) { continue }
            scripts.append(ProjectScript(name: name, command: "make \(name)", source: .make))
        }
        return scripts
    }

    // MARK: - cargo (Cargo.toml)

    private static func parseCargo(in directory: URL) -> [ProjectScript] {
        let file = directory.appendingPathComponent("Cargo.toml")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return [
            ProjectScript(name: "build", command: "cargo build", source: .cargo),
            ProjectScript(name: "test", command: "cargo test", source: .cargo),
            ProjectScript(name: "run", command: "cargo run", source: .cargo),
            ProjectScript(name: "clippy", command: "cargo clippy", source: .cargo),
        ]
    }

    // MARK: - python (pyproject.toml)

    private static func parsePyproject(in directory: URL) -> [ProjectScript] {
        let file = directory.appendingPathComponent("pyproject.toml")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parsePyprojectContent(content)
    }

    static func parsePyprojectContent(_ content: String) -> [ProjectScript] {
        // Look for [project.scripts] or [tool.poetry.scripts] sections
        let sectionPattern = #"^\[(project\.scripts|tool\.poetry\.scripts)\]\s*$"#
        guard let sectionRegex = try? NSRegularExpression(pattern: sectionPattern, options: .anchorsMatchLines) else {
            return []
        }
        let range = NSRange(content.startIndex..., in: content)
        guard let sectionMatch = sectionRegex.firstMatch(in: content, range: range),
              let sectionRange = Range(sectionMatch.range, in: content)
        else { return [] }

        // Parse key = "value" lines until next section or end of file
        let afterSection = content[sectionRange.upperBound...]
        var scripts: [ProjectScript] = []
        for line in afterSection.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break } // next section
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            scripts.append(ProjectScript(name: name, command: name, source: .python))
        }
        return scripts
    }
}
