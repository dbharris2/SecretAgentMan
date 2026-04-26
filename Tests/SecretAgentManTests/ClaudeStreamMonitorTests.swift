import Foundation
@testable import SecretAgentMan
import Testing

struct ClaudeStreamMonitorTests {
    // MARK: - Approval Request Parsing

    @Test
    func parsesApprovalRequestFromPermissionRequest() {
        let agentId = UUID()
        let request = ClaudeStreamMonitor.approvalRequest(
            agentId: agentId,
            requestId: "req-123",
            permission: ClaudeProtocol.PermissionRequest(
                toolName: "Write",
                displayName: "Write",
                input: .object([
                    "file_path": .string("/tmp/test.txt"),
                    "content": .string("hello"),
                ])
            )
        )

        #expect(request.agentId == agentId)
        #expect(request.requestId == "req-123")
        #expect(request.toolName == "Write")
        #expect(request.displayName == "Write")
        #expect(request.inputDescription.contains("file_path") == true)
        #expect(request.inputDescription.contains("/tmp/test.txt") == true)
    }

    @Test
    func fallsBackToToolNameWhenDisplayNameMissing() {
        let request = ClaudeStreamMonitor.approvalRequest(
            agentId: UUID(),
            requestId: "req-789",
            permission: ClaudeProtocol.PermissionRequest(
                toolName: "Bash",
                displayName: nil,
                input: .object([:])
            )
        )

        #expect(request.displayName == "Bash")
        #expect(request.inputDescription == "")
    }

    // MARK: - Assistant Event Parsing

    @Test
    func parsesTextFromAssistantEvent() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "type": "assistant",
            "uuid": "evt-001",
            "message": [
                "content": [
                    ["type": "text", "text": "Hello from Claude"],
                ],
            ],
        ])

        #expect(items.count == 1)
        #expect(items.first?.role == .assistant)
        #expect(items.first?.text == "Hello from Claude")
    }

    @Test
    func parsesTextAndToolUseFromAssistantEvent() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "type": "assistant",
            "uuid": "evt-002",
            "message": [
                "content": [
                    ["type": "text", "text": "Let me check."],
                    ["type": "tool_use", "name": "Bash", "input": ["command": "git status"]],
                    ["type": "text", "text": "Done."],
                ],
            ],
        ])

        #expect(items.count == 3)
        #expect(items[0].role == .assistant)
        #expect(items[0].text == "Let me check.")
        #expect(items[1].role == .system)
        #expect(items[1].text.contains("Bash"))
        #expect(items[1].text.contains("git status"))
        #expect(items[2].role == .assistant)
        #expect(items[2].text == "Done.")
    }

    @Test
    func parsesToolUseOnlyAssistantEvent() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "type": "assistant",
            "uuid": "evt-003",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "Write", "input": ["file_path": "/tmp/x"]],
                ],
            ],
        ])

        #expect(items.count == 1)
        #expect(items.first?.role == .system)
        #expect(items.first?.text.contains("Write") == true)
    }

    @Test
    func returnsEmptyForAssistantEventWithNoContent() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "type": "assistant",
            "uuid": "evt-empty",
            "message": [
                "content": [] as [[String: Any]],
            ],
        ])
        #expect(items.isEmpty)
    }

    @Test
    func returnsEmptyForMalformedAssistantEvent() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "type": "assistant",
        ])
        #expect(items.isEmpty)
    }

    // MARK: - Tool Use Summaries

    @Test
    func toolUseSummaryForBash() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "uuid": "evt-bash",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "Bash", "input": ["command": "ls -la"]],
                ],
            ],
        ])
        #expect(items.first?.text == "💻 **Bash**: `ls -la`")
    }

    @Test
    func toolUseSummaryForRead() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "uuid": "evt-read",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "Read", "input": ["file_path": "/tmp/foo.swift"]],
                ],
            ],
        ])
        #expect(items.first?.text == "👀 **Read**: /tmp/foo.swift")
    }

    @Test
    func toolUseSummaryForAskUserQuestion() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "uuid": "evt-ask",
            "message": [
                "content": [
                    [
                        "type": "tool_use",
                        "name": "AskUserQuestion",
                        "input": [
                            "questions": [
                                ["question": "What color?", "header": "Color"],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        #expect(items.first?.text == "❓ **Question**: What color?")
    }

    @Test
    func toolUseSummaryForToolSearch() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "uuid": "evt-ts",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "ToolSearch", "input": ["query": "select:AskUserQuestion"]],
                ],
            ],
        ])
        #expect(items.first?.text == "🧰 **ToolSearch**: `select:AskUserQuestion`")
    }

    @Test
    func toolUseSummaryForUnknownToolShowsInput() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "uuid": "evt-unknown",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "CustomTool", "input": ["foo": "bar"]],
                ],
            ],
        ])
        #expect(items.first?.text.contains("CustomTool") == true)
        #expect(items.first?.text.contains("foo") == true)
    }

    // MARK: - Transcript Hydration

    @Test
    func hydratesUserAndAssistantMessages() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-hydrate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = "test-session"
        let lines = [
            // Queue operation (should be skipped)
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            // User message
            #"{"type":"user","uuid":"u1","userType":"external","message":{"role":"user","content":"hello"}}"#,
            // Assistant message
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Hi there!"}]}}"#,
            // Successful tool result (should be suppressed)
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"content":"file written","is_error":false,"tool_use_id":"t1"}]}}"#,
            // Error tool result (should be shown)
            #"{"type":"user","uuid":"u4","message":{"role":"user","content":[{"content":"Permission denied","is_error":true,"tool_use_id":"t2"}]}}"#,
            // Another user message
            #"{"type":"user","uuid":"u3","userType":"external","message":{"role":"user","content":"thanks"}}"#,
        ]

        let content = lines.joined(separator: "\n")
        let filePath = dir.appendingPathComponent("\(sessionId).jsonl")
        try content.write(to: filePath, atomically: true, encoding: .utf8)

        let items = ClaudeStreamMonitor.hydrateTranscriptItems(
            sessionDir: dir,
            sessionId: sessionId
        )

        let userItems = items.filter { $0.role == .user }
        let assistantItems = items.filter { $0.role == .assistant }
        let systemItems = items.filter { $0.role == .system }

        #expect(userItems.count == 2)
        #expect(userItems[0].text == "hello")
        #expect(userItems[1].text == "thanks")
        #expect(assistantItems.count == 1)
        #expect(assistantItems[0].text == "Hi there!")
        // Only error tool results shown, successful ones suppressed
        #expect(systemItems.count == 1)
        #expect(systemItems[0].text.contains("Permission denied"))
    }

    @Test
    func hydrateReturnsEmptyForMissingFile() {
        let items = ClaudeStreamMonitor.hydrateTranscriptItems(
            sessionDir: URL(fileURLWithPath: "/nonexistent"),
            sessionId: "no-such-session"
        )
        #expect(items.isEmpty)
    }

    @Test
    func hydrateCollapsesSlashCommandWrappersAndSkipsSkillBody() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-hydrate-slash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = "slash-test"
        // Each line must be standalone JSON — embedded newlines go through as \n escapes.
        let slashWrapper = #"{"type":"user","uuid":"u1","userType":"external","message":{"role":"user","content":"<command-message>dev:reflect</command-message>\n<command-name>/dev:reflect</command-name>"}}"#
        let skillBody = #"{"type":"user","uuid":"u2","userType":"external","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /tmp/reflect\n\n# Reflection body"}]}}"#
        let followup = #"{"type":"user","uuid":"u3","userType":"external","message":{"role":"user","content":"just a regular follow up"}}"#

        let filePath = dir.appendingPathComponent("\(sessionId).jsonl")
        try [slashWrapper, skillBody, followup]
            .joined(separator: "\n")
            .write(to: filePath, atomically: true, encoding: .utf8)

        let items = ClaudeStreamMonitor.hydrateTranscriptItems(
            sessionDir: dir, sessionId: sessionId
        )

        let userItems = items.filter { $0.role == .user }
        #expect(userItems.count == 2)
        #expect(userItems[0].text == "/dev:reflect")
        #expect(userItems[1].text == "just a regular follow up")
    }

    @Test
    func unwrapSlashCommandPassesPlainTextThrough() {
        #expect(ClaudeStreamMonitor.unwrapSlashCommand("hello there") == "hello there")
        #expect(ClaudeStreamMonitor.unwrapSlashCommand("") == "")
        // Malformed wrapper with no command-name falls back to the raw text.
        let malformed = "<command-message>foo</command-message>"
        #expect(ClaudeStreamMonitor.unwrapSlashCommand(malformed) == malformed)
    }

    @Test
    func hydrateSkipsNonMessageLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-hydrate-skip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let lines = [
            #"{"type":"queue-operation"}"#,
            #"{"type":"attachment"}"#,
            #"not json at all"#,
            #"{"type":"user","uuid":"u1","userType":"external","message":{"role":"user","content":"only this"}}"#,
        ]

        let filePath = dir.appendingPathComponent("skip-test.jsonl")
        try lines.joined(separator: "\n").write(to: filePath, atomically: true, encoding: .utf8)

        let items = ClaudeStreamMonitor.hydrateTranscriptItems(
            sessionDir: dir, sessionId: "skip-test"
        )

        #expect(items.count == 1)
        #expect(items[0].text == "only this")
    }

    // MARK: - Elicitation Answer Injection

    @Test
    func toolUseSummaryForAskUserQuestionWithNestedQuestions() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "uuid": "evt-nested",
            "message": [
                "content": [
                    [
                        "type": "tool_use",
                        "name": "AskUserQuestion",
                        "input": [
                            "questions": [
                                [
                                    "question": "What framework?",
                                    "header": "Framework",
                                    "options": [
                                        ["label": "SwiftUI", "description": "Apple's declarative UI"],
                                        ["label": "UIKit", "description": "Apple's imperative UI"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])
        #expect(items.first?.text == "❓ **Question**: What framework?")
    }

    @Test
    func toolUseSummaryForAskUserQuestionWithEmptyQuestions() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: [
            "uuid": "evt-empty-q",
            "message": [
                "content": [
                    [
                        "type": "tool_use",
                        "name": "AskUserQuestion",
                        "input": [
                            "questions": [] as [[String: Any]],
                        ],
                    ],
                ],
            ],
        ])
        #expect(items.first?.text == "❓ **Question**")
    }
}
