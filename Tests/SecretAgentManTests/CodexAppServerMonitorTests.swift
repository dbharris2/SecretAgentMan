import Foundation
@testable import SecretAgentMan
import Testing

struct CodexAppServerMonitorTests {
    @Test
    func mapsIdleThreadStatusToIdleAgentState() {
        let state = CodexAppServerMonitor.agentState(fromThreadStatus: ["type": "idle"])
        #expect(state == .idle)
    }

    @Test
    func mapsActiveThreadStatusToNeedsPermission() {
        let state = CodexAppServerMonitor.agentState(fromThreadStatus: [
            "type": "active",
            "activeFlags": ["waitingOnApproval"],
        ])
        #expect(state == .needsPermission)
    }

    @Test
    func mapsActiveThreadStatusToAwaitingResponse() {
        let state = CodexAppServerMonitor.agentState(fromThreadStatus: [
            "type": "active",
            "activeFlags": ["waitingOnUserInput"],
        ])
        #expect(state == .awaitingResponse)
    }

    @Test
    func mapsActiveThreadStatusWithoutFlagsToActive() {
        let state = CodexAppServerMonitor.agentState(fromThreadStatus: [
            "type": "active",
            "activeFlags": [],
        ])
        #expect(state == .active)
    }

    @Test
    func mapsSystemErrorThreadStatusToError() {
        let state = CodexAppServerMonitor.agentState(fromThreadStatus: ["type": "systemError"])
        #expect(state == .error)
    }

    @Test
    func parsesUserInputRequestPayload() {
        let agentId = UUID()
        let request = CodexAppServerMonitor.userInputRequest(
            agentId: agentId,
            params: [
                "threadId": "thread-123",
                "turnId": "turn-123",
                "itemId": "item-123",
                "questions": [
                    [
                        "id": "alpha_beta",
                        "header": "Choice",
                        "question": "Choose one option before I continue.",
                        "isOther": true,
                        "options": [
                            [
                                "label": "Alpha",
                                "description": "Proceed with Alpha.",
                            ],
                            [
                                "label": "Beta",
                                "description": "Proceed with Beta.",
                            ],
                        ],
                    ],
                ],
            ]
        )

        #expect(request?.agentId == agentId)
        #expect(request?.threadId == "thread-123")
        #expect(request?.questions.count == 1)
        #expect(request?.questions.first?.id == "alpha_beta")
        #expect(request?.questions.first?.options.map(\.label) == ["Alpha", "Beta"])
        #expect(request?.questions.first?.allowsOther == true)
    }

    @Test
    func parsesFileChangeApprovalGrantRoot() {
        let agentId = UUID()
        let request = CodexAppServerMonitor.approvalRequest(
            agentId: agentId,
            requestId: 17,
            method: "item/fileChange/requestApproval",
            params: [
                "threadId": "thread-123",
                "turnId": "turn-123",
                "itemId": "item-123",
                "reason": "Need write access outside the workspace.",
                "grantRoot": "/tmp/shared",
            ]
        )

        #expect(request?.agentId == agentId)
        #expect(request?.requestId == 17)
        #expect(request?.kind.detail == "Need write access outside the workspace.\n\nWrite scope: /tmp/shared")
    }

    @Test
    func parsesOutputDeltaPayload() {
        let delta = CodexAppServerMonitor.outputDeltaText(params: [
            "itemId": "item-123",
            "delta": "line one\nline two",
        ])

        #expect(delta?.itemId == "item-123")
        #expect(delta?.delta == "line one\nline two")
    }

    @Test
    func ignoresEmptyOutputDeltaPayload() {
        let delta = CodexAppServerMonitor.outputDeltaText(params: [
            "itemId": "item-123",
            "delta": "",
        ])
        #expect(delta == nil)
    }

    @Test
    func buildsRunningCommandToolItem() {
        let toolItem = CodexAppServerMonitor.commandToolItem(
            fromStartedItem: [
                "id": "item-123",
                "type": "commandExecution",
                "command": ["rg", "foo"],
            ],
            isRunning: true
        )

        #expect(toolItem?.id == "command-item-123")
        #expect(toolItem?.role == .system)
        guard case let .command(detail) = toolItem?.tool else {
            Issue.record("expected command tool detail")
            return
        }
        #expect(detail.command == "rg foo")
        #expect(detail.isRunning == true)
        #expect(detail.output.isEmpty)
    }

    @Test
    func buildsCompletedCommandToolItemFromCompletedEvent() {
        let toolItem = CodexAppServerMonitor.transcriptItem(from: [
            "id": "item-123",
            "type": "commandExecution",
            "command": ["rg", "approvalPolicy"],
            "status": "completed",
            "durationMs": 456.0,
            "exitCode": 0,
            "aggregatedOutput": "match one",
        ])

        #expect(toolItem?.id == "command-item-123")
        guard case let .command(detail) = toolItem?.tool else {
            Issue.record("expected command tool detail")
            return
        }
        #expect(detail.command == "rg approvalPolicy")
        #expect(detail.output == "match one")
        #expect(detail.status == "completed")
        #expect(detail.durationMs == 456.0)
        #expect(detail.exitCode == 0)
        #expect(detail.isRunning == false)
    }

    @Test
    func buildsFileChangeToolItemFromCompletedEvent() {
        let toolItem = CodexAppServerMonitor.transcriptItem(from: [
            "id": "item-456",
            "type": "fileChange",
            "status": "completed",
            "changes": [
                ["path": "foo.txt", "kind": "modify", "diff": "@@ -1 +1 @@\n-old\n+new"],
            ],
        ])

        #expect(toolItem?.id == "file-change-item-456")
        guard case let .fileChange(detail) = toolItem?.tool else {
            Issue.record("expected file change tool detail")
            return
        }
        #expect(detail.patch.contains("+new"))
        #expect(detail.isRunning == false)
    }

    @Test
    func commandToolMarkdownIncludesStatusAndExit() {
        let detail = CodexCommandToolDetail(
            command: "rg foo",
            output: "match",
            status: "completed",
            exitCode: 0,
            durationMs: 120,
            isRunning: false
        )
        let md = detail.markdownText
        #expect(md.contains("Ran command"))
        #expect(md.contains("exit: 0"))
        #expect(md.contains("```sh"))
        #expect(md.contains("Command output:"))
    }

    @Test
    func commandToolMarkdownShowsRunningWhenLive() {
        let detail = CodexCommandToolDetail(
            command: "just build",
            output: "",
            status: nil,
            exitCode: nil,
            durationMs: nil,
            isRunning: true
        )
        #expect(detail.markdownText.contains("running"))
    }

    @Test
    func fileChangeToolMarkdownShowsDiffBlock() {
        let detail = CodexFileChangeToolDetail(
            patch: "@@ -1 +1 @@\n-old\n+new",
            status: "completed",
            isRunning: false
        )
        let md = detail.markdownText
        #expect(md.contains("Applied file changes"))
        #expect(md.contains("```diff"))
        #expect(md.contains("+new"))
    }

    @Test
    func transcriptItemDisplayTextPrefersToolMarkdown() {
        let detail = CodexCommandToolDetail(
            command: "echo hi",
            output: "hi",
            status: nil,
            exitCode: 0,
            durationMs: nil,
            isRunning: false
        )
        let item = CodexTranscriptItem(
            id: "command-x",
            role: .system,
            text: "legacy text",
            tool: .command(detail)
        )
        #expect(item.displayText.contains("echo hi"))
        #expect(item.displayText.contains("legacy text") == false)
    }

    @Test
    func transcriptItemDisplayTextFallsBackToTextWithoutTool() {
        let item = CodexTranscriptItem(
            id: "sys-1",
            role: .system,
            text: "Error: something broke"
        )
        #expect(item.displayText == "Error: something broke")
    }

    @Test
    func parsesTranscriptItemFromSessionEvent() {
        let item = CodexAppServerMonitor.transcriptItem(fromSessionEvent: [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": "Hello from history",
                    ],
                ],
            ],
        ])

        #expect(item?.role == .assistant)
        #expect(item?.text == "Hello from history")
    }

    @Test
    func parsesTurnAbortedEvent() {
        let isTurnAborted = CodexAppServerMonitor.isTurnAbortedEvent([
            "type": "event_msg",
            "payload": [
                "type": "turn_aborted",
                "turn_id": "turn-123",
                "reason": "interrupted",
            ],
        ])

        #expect(isTurnAborted)
    }

    @Test
    func parsesTaskStartedEvent() {
        let isTaskStarted = CodexAppServerMonitor.isTaskStartedEvent([
            "type": "event_msg",
            "payload": [
                "type": "task_started",
                "turn_id": "turn-123",
            ],
        ])

        #expect(isTaskStarted)
    }

    @Test
    func parsesCollaborationModeFromTurnContext() {
        let mode = CodexAppServerMonitor.collaborationMode(fromSessionEvent: [
            "type": "turn_context",
            "payload": [
                "collaboration_mode": [
                    "mode": "plan",
                ],
            ],
        ])

        #expect(mode == .plan)
    }

    @Test
    func identifiesBootstrapUserContextMessage() {
        let item = CodexTranscriptItem(
            id: "1",
            role: .user,
            text: "# AGENTS.md instructions for /tmp/example\n\n<environment_context>\n</environment_context>"
        )

        #expect(CodexAppServerMonitor.isBootstrapUserContextMessage(item))
    }

    @Test
    func stillParsesUserControlPayloadAsTranscriptItemBeforeStructuredSuppression() {
        let item = CodexAppServerMonitor.transcriptItem(fromSessionEvent: [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": """
                        <turn_aborted>
                        The user interrupted the previous turn on purpose.
                        </turn_aborted>
                        """,
                    ],
                ],
            ],
        ])

        #expect(item?.role == .user)
    }

    @Test
    func parsesModelNameFromTurnContext() {
        let model = CodexAppServerMonitor.modelName(fromSessionEvent: [
            "type": "turn_context",
            "payload": ["model": "gpt-5.4"],
        ])

        #expect(model == "GPT-5.4")
    }

    @Test
    func parsesContextPercentFromTokenCountEvent() {
        let percent = CodexAppServerMonitor.contextPercentUsed(fromSessionEvent: [
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "model_context_window": 200.0,
                    "total_token_usage": [
                        "total_tokens": 50.0,
                    ],
                ],
            ],
        ])

        #expect(percent == 25.0)
    }

    @Test
    func parsesContextPercentFromRealisticTokenCountEvent() {
        let percent = CodexAppServerMonitor.contextPercentUsed(fromSessionEvent: [
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "model_context_window": 258_400.0,
                    "total_token_usage": [
                        "input_tokens": 118_031.0,
                        "cached_input_tokens": 74240.0,
                        "output_tokens": 311.0,
                        "reasoning_output_tokens": 36.0,
                        "total_tokens": 118_342.0,
                    ],
                ],
            ],
        ])

        #expect(percent != nil)
        #expect(abs((percent ?? 0) - 45.799) < 0.01)
    }
}
