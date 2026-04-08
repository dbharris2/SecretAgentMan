import Foundation
@testable import SecretAgentMan
import Testing

struct SessionFileDetectorTests {
    @Test
    func claudeProjectDirMapsPathCorrectly() {
        let folder = URL(fileURLWithPath: "/Users/devon/projects/MyApp")
        let result = SessionFileDetector.claudeProjectDir(for: folder)
        #expect(result.path.hasSuffix(".claude/projects/-Users-devon-projects-MyApp"))
    }

    @Test
    func claudeProjectDirHandlesHomeDirectory() {
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/dmars/SecretAgentMan")
        let result = SessionFileDetector.claudeProjectDir(for: folder)
        let expected = NSHomeDirectory() + "/.claude/projects/-"
            + NSHomeDirectory().replacingOccurrences(of: "/", with: "-").dropFirst()
            + "-dmars-SecretAgentMan"
        #expect(result.path == expected)
    }

    @Test
    func latestSessionIdReturnsNewestFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create two session files with different modification dates
        let old = tmpDir.appendingPathComponent("old-session.jsonl")
        let new = tmpDir.appendingPathComponent("new-session.jsonl")
        try Data().write(to: old)
        // Small delay so modification dates differ
        Thread.sleep(forTimeInterval: 0.1)
        try Data().write(to: new)

        let result = SessionFileDetector.latestSessionId(inDirectory: tmpDir)
        #expect(result == "new-session")
    }

    @Test
    func latestSessionIdIgnoresNonJsonlFiles() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try Data().write(to: tmpDir.appendingPathComponent("session.jsonl"))
        try Data().write(to: tmpDir.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("some-dir"),
            withIntermediateDirectories: true
        )

        let result = SessionFileDetector.latestSessionId(inDirectory: tmpDir)
        #expect(result == "session")
    }

    @Test
    func latestSessionIdReturnsNilForEmptyDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = SessionFileDetector.latestSessionId(inDirectory: tmpDir)
        #expect(result == nil)
    }

    @Test
    func latestSessionIdReturnsNilForMissingDirectory() {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        let result = SessionFileDetector.latestSessionId(inDirectory: missing)
        #expect(result == nil)
    }

    @Test
    func availableClaudeSessionsReturnsAllSessionsNewestFirst() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let old = tmpDir.appendingPathComponent("old-session.jsonl")
        let new = tmpDir.appendingPathComponent("new-session.jsonl")
        try Data().write(to: old)
        Thread.sleep(forTimeInterval: 0.1)
        try Data().write(to: new)

        let agent = Agent(
            name: "Claude",
            folder: URL(fileURLWithPath: "/tmp/project"),
            provider: .claude
        )
        let sessions = SessionFileDetector.availableSessions(
            for: agent,
            inClaudeDirectory: tmpDir
        )

        #expect(sessions.map(\.id) == ["new-session", "old-session"])
    }

    // MARK: - sessionFileExists

    @Test
    func sessionFileExistsReturnsTrueWhenPresent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try Data().write(to: tmpDir.appendingPathComponent("abc-123.jsonl"))

        #expect(SessionFileDetector.sessionFileExists("abc-123", inDirectory: tmpDir))
    }

    @Test
    func sessionFileExistsReturnsFalseWhenMissing() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try Data().write(to: tmpDir.appendingPathComponent("other-session.jsonl"))

        #expect(!SessionFileDetector.sessionFileExists("abc-123", inDirectory: tmpDir))
    }

    @Test
    func sessionFileExistsReturnsFalseForMissingDirectory() {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        #expect(!SessionFileDetector.sessionFileExists("abc-123", inDirectory: missing))
    }

    @Test
    func parseCodexSessionMetaLineExtractsIdAndFolder() {
        let line = #"{"timestamp":"2026-04-07T19:31:38.168Z","type":"session_meta","payload":{"id":"codex-session","cwd":"/tmp/project"}}"#

        let meta = SessionFileDetector.parseCodexSessionMetaLine(line)

        #expect(meta?.id == "codex-session")
        #expect(meta?.cwd == "/tmp/project")
    }

    @Test
    func latestCodexSessionIdReturnsNewestMatchingFolder() throws {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dayDir = rootDir.appendingPathComponent("2026/04/07", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let folder = URL(fileURLWithPath: "/tmp/project-a")
        let old = dayDir.appendingPathComponent("old.jsonl")
        let new = dayDir.appendingPathComponent("new.jsonl")
        let other = dayDir.appendingPathComponent("other.jsonl")

        try #"{"type":"session_meta","payload":{"id":"old-session","cwd":"/tmp/project-a"}}"#
            .write(to: old, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.1)
        try #"{"type":"session_meta","payload":{"id":"new-session","cwd":"/tmp/project-a"}}"#
            .write(to: new, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"other-session","cwd":"/tmp/project-b"}}"#
            .write(to: other, atomically: true, encoding: .utf8)

        let result = SessionFileDetector.latestCodexSessionId(for: folder, inDirectory: rootDir)
        #expect(result == "new-session")
    }

    @Test
    func availableCodexSessionsReturnsAllMatchingSessionsNewestFirst() throws {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dayDir = rootDir.appendingPathComponent("2026/04/07", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let folder = URL(fileURLWithPath: "/tmp/project-a")
        let old = dayDir.appendingPathComponent("old.jsonl")
        let new = dayDir.appendingPathComponent("new.jsonl")
        let other = dayDir.appendingPathComponent("other.jsonl")

        try #"{"type":"session_meta","payload":{"id":"old-session","cwd":"/tmp/project-a"}}"#
            .write(to: old, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.1)
        try #"{"type":"session_meta","payload":{"id":"new-session","cwd":"/tmp/project-a"}}"#
            .write(to: new, atomically: true, encoding: .utf8)
        try #"{"type":"session_meta","payload":{"id":"other-session","cwd":"/tmp/project-b"}}"#
            .write(to: other, atomically: true, encoding: .utf8)

        let agent = Agent(
            name: "Codex",
            folder: folder,
            provider: .codex
        )
        let sessions = SessionFileDetector.availableSessions(for: agent, inCodexDirectory: rootDir)

        #expect(sessions.map(\.id) == ["new-session", "old-session"])
    }

    @Test
    func codexSessionFileExistsMatchesSessionIdInSessionMeta() throws {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let dayDir = rootDir.appendingPathComponent("2026/04/07", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let file = dayDir.appendingPathComponent("session.jsonl")
        try #"{"type":"session_meta","payload":{"id":"codex-session","cwd":"/tmp/project"}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        #expect(SessionFileDetector.codexSessionFileExists("codex-session", inDirectory: rootDir))
        #expect(!SessionFileDetector.codexSessionFileExists("other-session", inDirectory: rootDir))
    }
}
