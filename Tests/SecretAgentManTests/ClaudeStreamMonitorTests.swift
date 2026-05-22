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
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "type": "assistant",
            "uuid": "evt-001",
            "message": [
                "content": [
                    ["type": "text", "text": "Hello from Claude"],
                ],
            ],
        ]))

        #expect(items.count == 1)
        #expect(items.first?.role == .assistant)
        #expect(items.first?.text == "Hello from Claude")
    }

    @Test
    func parsesTextAndToolUseFromAssistantEvent() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "type": "assistant",
            "uuid": "evt-002",
            "message": [
                "content": [
                    ["type": "text", "text": "Let me check."],
                    ["type": "tool_use", "name": "Bash", "input": ["command": "git status"]],
                    ["type": "text", "text": "Done."],
                ],
            ],
        ]))

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
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "type": "assistant",
            "uuid": "evt-003",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "Write", "input": ["file_path": "/tmp/x"]],
                ],
            ],
        ]))

        #expect(items.count == 1)
        #expect(items.first?.role == .system)
        #expect(items.first?.text.contains("Write") == true)
    }

    @Test
    func returnsEmptyForAssistantEventWithNoContent() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "type": "assistant",
            "uuid": "evt-empty",
            "message": [
                "content": [] as [[String: Any]],
            ],
        ]))
        #expect(items.isEmpty)
    }

    @Test
    func returnsEmptyForMalformedAssistantEvent() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "type": "assistant",
        ]))
        #expect(items.isEmpty)
    }

    // MARK: - Tool Use Summaries

    @Test
    func toolUseSummaryForBash() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "uuid": "evt-bash",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "Bash", "input": ["command": "ls -la"]],
                ],
            ],
        ]))
        #expect(items.first?.text == "💻 **Bash**: `ls -la`")
    }

    @Test
    func toolUseSummaryForRead() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "uuid": "evt-read",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "Read", "input": ["file_path": "/tmp/foo.swift"]],
                ],
            ],
        ]))
        #expect(items.first?.text == "👀 **Read**: /tmp/foo.swift")
    }

    @Test
    func toolUseSummaryForAskUserQuestion() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
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
        ]))
        #expect(items.first?.text == "❓ **Question**: What color?")
    }

    @Test
    func toolUseSummaryForToolSearch() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "uuid": "evt-ts",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "ToolSearch", "input": ["query": "select:AskUserQuestion"]],
                ],
            ],
        ]))
        #expect(items.first?.text == "🧰 **ToolSearch**: `select:AskUserQuestion`")
    }

    @Test
    func toolUseSummaryForUnknownToolShowsInput() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
            "uuid": "evt-unknown",
            "message": [
                "content": [
                    ["type": "tool_use", "name": "CustomTool", "input": ["foo": "bar"]],
                ],
            ],
        ]))
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
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","content":"file written","is_error":false,"tool_use_id":"t1"}]}}"#,
            // Error tool result (should be shown)
            #"{"type":"user","uuid":"u4","message":{"role":"user","content":[{"type":"tool_result","content":"Permission denied","is_error":true,"tool_use_id":"t2"}]}}"#,
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
    func stripANSIRemovesEscapeSequencesAndPreservesText() {
        // Color + reset, common in `claude` CLI stderr.
        let colored = "\u{001B}[31mAPI Error: 529\u{001B}[0m service unavailable"
        #expect(ClaudeStreamMonitor.stripANSI(colored) == "API Error: 529 service unavailable")
        // Cursor / clear-line escapes — also stripped.
        let cursor = "\u{001B}[2KRetrying in 1s · attempt 4/10"
        #expect(ClaudeStreamMonitor.stripANSI(cursor) == "Retrying in 1s · attempt 4/10")
        // Plain text passes through unchanged.
        #expect(ClaudeStreamMonitor.stripANSI("plain") == "plain")
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
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
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
        ]))
        #expect(items.first?.text == "❓ **Question**: What framework?")
    }

    @Test
    func toolUseSummaryForAskUserQuestionWithEmptyQuestions() {
        let items = ClaudeStreamMonitor.transcriptItems(fromAssistantEvent: assistantMessage([
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
        ]))
        #expect(items.first?.text == "❓ **Question**")
    }

    // MARK: - Helpers

    /// Builds a `MessageEvent` from the same `[String: Any]` shape the legacy
    /// dict-based tests used. JSONSerialization → JSONDecoder so the test
    /// dispatch matches what production sees off the wire.
    private func assistantMessage(_ json: [String: Any]) -> ClaudeProtocol.MessageEvent {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: json)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ClaudeProtocol.MessageEvent.self, from: data)
    }

    // MARK: - State Transition Ordering

    /// Regression: a partial-message `assistant` event arriving after a
    /// `control_request` for tool approval must NOT republish `.active` and
    /// overwrite the `.needsPermission` state. Claude's
    /// `--include-partial-messages` emits one `assistant` event per tool_use
    /// block sharing a single `msg_id`, so the last chunk can land in the
    /// same buffer batch as (or after) the approval request.
    @Test
    func assistantEventAfterApprovalRequestPreservesNeedsPermission() {
        let agent = Agent(name: "test", folder: URL(fileURLWithPath: "/tmp"))
        var states: [AgentState] = []
        let delegate = captureDelegate { _, state in states.append(state) }
        let observer = ClaudeObserver(agent: agent, delegate: delegate)

        // 1. First partial-message chunk: assistant tool_use → .active
        observer.handleLineForTesting(assistantToolUseLine(
            msgId: "msg-1", toolUseId: "toolu_1", toolName: "Write", filePath: "/tmp/a.txt"
        ))
        #expect(states == [.active])

        // 2. SDK asks for permission → .needsPermission
        observer.handleLineForTesting(canUseToolLine(
            requestId: "req-1", toolName: "Write", filePath: "/tmp/a.txt"
        ))
        #expect(states == [.active, .needsPermission])

        // 3. Another partial-message chunk for the SAME msg_id arrives.
        // Before the fix this overwrote `.needsPermission` with `.active`.
        observer.handleLineForTesting(assistantToolUseLine(
            msgId: "msg-1", toolUseId: "toolu_2", toolName: "Write", filePath: "/tmp/b.txt"
        ))
        #expect(states == [.active, .needsPermission])
    }

    /// Stream events (content_block_start, text_delta, message_stop) arriving
    /// after a control_request are also guarded — this test pins down that
    /// existing behavior so it doesn't regress alongside the assistant-event fix.
    @Test
    func streamEventAfterApprovalRequestPreservesNeedsPermission() {
        let agent = Agent(name: "test", folder: URL(fileURLWithPath: "/tmp"))
        var states: [AgentState] = []
        let delegate = captureDelegate { _, state in states.append(state) }
        let observer = ClaudeObserver(agent: agent, delegate: delegate)

        observer.handleLineForTesting(canUseToolLine(
            requestId: "req-1", toolName: "Write", filePath: "/tmp/a.txt"
        ))
        #expect(states == [.needsPermission])

        observer.handleLineForTesting(streamMessageStopLine())
        #expect(states == [.needsPermission])
    }

    private func captureDelegate(
        stateChanged: @escaping (UUID, AgentState) -> Void
    ) -> ClaudeObserverDelegate {
        ClaudeObserverDelegate(
            stateChanged: stateChanged,
            sessionReady: { _, _ in },
            transcriptItem: { _, _ in },
            approvalRequest: { _, _ in },
            approvalResolved: { _ in },
            elicitationRequest: { _, _ in },
            elicitationResolved: { _ in },
            streamingText: { _, _ in },
            streamingFinished: { _ in },
            activeToolChanged: { _, _ in },
            permissionModeChanged: { _, _ in },
            modelInfo: { _, _, _ in },
            slashCommands: { _ in },
            sessionConflict: { _ in }
        )
    }

    private func assistantToolUseLine(
        msgId: String, toolUseId: String, toolName: String, filePath: String
    ) -> String {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "uuid": UUID().uuidString,
            "message": [
                "id": msgId,
                "stop_reason": "tool_use",
                "content": [
                    [
                        "type": "tool_use",
                        "id": toolUseId,
                        "name": toolName,
                        "input": ["file_path": filePath, "content": "x"],
                    ],
                ],
            ],
        ])
        return String(data: data, encoding: .utf8)!
    }

    private func canUseToolLine(
        requestId: String, toolName: String, filePath: String
    ) -> String {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: [
            "type": "control_request",
            "request_id": requestId,
            "request": [
                "subtype": "can_use_tool",
                "tool_name": toolName,
                "input": ["file_path": filePath, "content": "x"],
            ],
        ])
        return String(data: data, encoding: .utf8)!
    }

    private func streamMessageStopLine() -> String {
        #"{"type":"stream_event","event":{"type":"message_stop"}}"#
    }
}
