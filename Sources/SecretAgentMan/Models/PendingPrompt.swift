import Foundation

struct PendingPrompt: Identifiable {
    let id: UUID
    let agentId: UUID
    let source: PromptSource
    let summary: String
    let fullPrompt: String
    let timestamp: Date

    var autoSend: Bool {
        source == .ciFailed
    }

    enum PromptSource: String {
        case ciFailed = "CI Failed"
        case changesRequested = "Changes Requested"
        case approvedWithComments = "Approved with Comments"
    }

    init(
        id: UUID = UUID(),
        agentId: UUID,
        source: PromptSource,
        summary: String,
        fullPrompt: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.agentId = agentId
        self.source = source
        self.summary = summary
        self.fullPrompt = fullPrompt
        self.timestamp = timestamp
    }
}
