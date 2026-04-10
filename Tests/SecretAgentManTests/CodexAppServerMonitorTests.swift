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
