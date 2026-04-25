import Foundation
@testable import SecretAgentMan
import Testing

/// Unit tests for the static ACP→SessionEvent mappers in
/// `GeminiAcpMonitor+SessionEvents.swift`.
@MainActor
struct GeminiAcpMonitorSessionEventTests {
    // MARK: - mapStopReason

    @Test func mapStopReasonForEachKnownValue() {
        let pairs: [(GeminiAcpProtocol.StopReason, SessionStopReason)] = [
            (.endTurn, .endTurn),
            (.maxTokens, .maxTokens),
            (.maxTurnRequests, .maxTurnRequests),
            (.refusal, .refusal),
            (.cancelled, .cancelled),
        ]
        for (acp, expected) in pairs {
            #expect(GeminiAcpMonitor.mapStopReason(acp, unknown: nil) == expected)
        }
    }

    @Test func mapStopReasonPreservesUnknownRawValue() {
        let result = GeminiAcpMonitor.mapStopReason(nil, unknown: "future_reason")
        #expect(result == .unknown("future_reason"))
    }

    @Test func mapStopReasonNilFallsBackToEmptyUnknown() {
        let result = GeminiAcpMonitor.mapStopReason(nil, unknown: nil)
        #expect(result == .unknown(""))
    }

    // MARK: - mapApprovalAction

    @Test func mapApprovalActionMarksRejectAsDestructive() {
        let actions = [
            GeminiAcpProtocol.PermissionOption(optionId: "ao", name: "Allow", kind: .allowOnce),
            GeminiAcpProtocol.PermissionOption(optionId: "ro", name: "Deny", kind: .rejectOnce),
            GeminiAcpProtocol.PermissionOption(optionId: "ra", name: "Always Deny", kind: .rejectAlways),
        ].map(GeminiAcpMonitor.mapApprovalAction)

        #expect(actions[0].isDestructive == false)
        #expect(actions[0].kind == .allowOnce)
        #expect(actions[1].isDestructive)
        #expect(actions[1].kind == .rejectOnce)
        #expect(actions[2].isDestructive)
        #expect(actions[2].kind == .rejectAlways)
    }

    @Test func mapApprovalActionPreservesOptionIdAndLabel() {
        let action = GeminiAcpMonitor.mapApprovalAction(
            GeminiAcpProtocol.PermissionOption(optionId: "yes", name: "Allow once", kind: .allowOnce)
        )
        #expect(action.id == "yes")
        #expect(action.label == "Allow once")
    }

    // MARK: - mapMode / mapModel

    @Test func mapModePreservesIdNameDescription() {
        let mode = GeminiAcpProtocol.SessionMode(id: "auto", name: "Auto", description: "Auto-approve")
        let mapped = GeminiAcpMonitor.mapMode(mode)
        #expect(mapped.id == "auto")
        #expect(mapped.name == "Auto")
        #expect(mapped.description == "Auto-approve")
    }

    @Test func mapModelMapsModelIdToId() {
        let model = GeminiAcpProtocol.ModelInfo(
            modelId: "gemini-2.5-pro",
            name: "Gemini 2.5 Pro",
            description: nil
        )
        let mapped = GeminiAcpMonitor.mapModel(model)
        #expect(mapped.id == "gemini-2.5-pro")
        #expect(mapped.name == "Gemini 2.5 Pro")
    }

    // MARK: - extractText

    @Test func extractTextForTextBlock() {
        let block = GeminiAcpProtocol.ContentBlock.text(
            GeminiAcpProtocol.TextContent(text: "hello")
        )
        #expect(GeminiAcpMonitor.extractText(block) == "hello")
    }

    @Test func extractTextForImageReturnsPlaceholder() {
        let block = GeminiAcpProtocol.ContentBlock.image(
            GeminiAcpProtocol.ImageContent(data: "BASE64", mimeType: "image/png")
        )
        #expect(GeminiAcpMonitor.extractText(block) == "[image]")
    }

    @Test func extractTextForUnknownReturnsTypeLabel() {
        let block = GeminiAcpProtocol.ContentBlock.unknown(type: "future", raw: .null)
        #expect(GeminiAcpMonitor.extractText(block) == "[future content]")
    }

    // MARK: - summarizeToolContent

    @Test func summarizeToolContentWithDiffLabelsByPath() {
        let content: [GeminiAcpProtocol.ToolCallContent] = [
            .diff(GeminiAcpProtocol.Diff(path: "/repo/src/foo.swift", oldText: nil, newText: "x")),
        ]
        #expect(GeminiAcpMonitor.summarizeToolContent(content) == "Edit: /repo/src/foo.swift")
    }

    @Test func summarizeToolContentWithTerminalLabelsById() {
        let content: [GeminiAcpProtocol.ToolCallContent] = [
            .terminal(GeminiAcpProtocol.Terminal(terminalId: "term-1")),
        ]
        #expect(GeminiAcpMonitor.summarizeToolContent(content) == "Terminal term-1")
    }

    @Test func summarizeToolContentSkipsEmptyText() {
        let content: [GeminiAcpProtocol.ToolCallContent] = [
            .content(.text(GeminiAcpProtocol.TextContent(text: ""))),
            .content(.text(GeminiAcpProtocol.TextContent(text: "non-empty"))),
        ]
        #expect(GeminiAcpMonitor.summarizeToolContent(content) == "non-empty")
    }

    @Test func summarizeToolContentEmptyArrayReturnsEmpty() {
        #expect(GeminiAcpMonitor.summarizeToolContent([]) == "")
        #expect(GeminiAcpMonitor.summarizeToolContent(nil) == "")
    }

    // MARK: - formatPlan

    @Test func formatPlanRendersStatusMarkers() {
        let plan = GeminiAcpProtocol.Plan(entries: [
            GeminiAcpProtocol.PlanEntry(content: "alpha", priority: .high, status: .completed),
            GeminiAcpProtocol.PlanEntry(content: "beta", priority: .medium, status: .inProgress),
            GeminiAcpProtocol.PlanEntry(content: "gamma", priority: .low, status: .pending),
        ])
        let formatted = GeminiAcpMonitor.formatPlan(plan)
        #expect(formatted.contains("[x] alpha"))
        #expect(formatted.contains("[~] beta"))
        #expect(formatted.contains("[ ] gamma"))
    }

    // MARK: - mapToolItem

    @Test func mapToolItemPreservesToolMetadata() {
        let snapshot = ToolCallSnapshot(
            toolCallId: "tc1",
            title: "Read file",
            kind: .read,
            status: .inProgress,
            locations: [],
            contentSummary: "file body"
        )
        let item = GeminiAcpMonitor.mapToolItem(snapshot, agentId: UUID())
        #expect(item.id == "gemini-tool-tc1")
        #expect(item.kind == .toolActivity)
        #expect(item.text.contains("Read file"))
        #expect(item.text.contains("(running)"))
        #expect(item.text.contains("file body"))
        #expect(item.metadata?.toolName == "read")
    }

    @Test func mapToolItemFailedStatusIsLabeled() {
        let snapshot = ToolCallSnapshot(
            toolCallId: "tc1",
            title: "Run cmd",
            kind: .execute,
            status: .failed,
            locations: [],
            contentSummary: ""
        )
        let item = GeminiAcpMonitor.mapToolItem(snapshot, agentId: UUID())
        #expect(item.text.contains("(failed)"))
    }
}
