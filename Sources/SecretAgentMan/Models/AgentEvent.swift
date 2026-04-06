import Foundation

enum AgentEvent: CustomStringConvertible {
    case agentIdle(agentId: UUID)
    case agentActive(agentId: UUID)
    case diffChanged(folder: URL)
    case branchChanged(folder: URL)
    case changesRequested(folder: URL)
    case checksFailed(folder: URL)
    case approvedWithComments(folder: URL)

    var description: String {
        switch self {
        case let .agentIdle(id): "agent.idle(\(id.uuidString.prefix(8)))"
        case let .agentActive(id): "agent.active(\(id.uuidString.prefix(8)))"
        case let .diffChanged(url): "diff.changed(\(url.lastPathComponent))"
        case let .branchChanged(url): "branch.changed(\(url.lastPathComponent))"
        case let .changesRequested(url): "pr.changesRequested(\(url.lastPathComponent))"
        case let .checksFailed(url): "pr.checksFailed(\(url.lastPathComponent))"
        case let .approvedWithComments(url): "pr.approvedWithComments(\(url.lastPathComponent))"
        }
    }
}

enum EventTrigger: Codable, Equatable {
    case agentIdle(agentId: UUID)
    case agentActive(agentId: UUID)
    case diffChanged(folder: URL)
    case branchChanged(folder: URL)
    case changesRequested(folder: URL)
    case checksFailed(folder: URL)
    case anyAgentIdle
    case anyDiffChanged

    func matches(_ event: AgentEvent) -> Bool {
        switch (self, event) {
        case let (.agentIdle(id), .agentIdle(eventId)): id == eventId
        case let (.agentActive(id), .agentActive(eventId)): id == eventId
        case let (.diffChanged(url), .diffChanged(eventUrl)):
            url.standardizedFileURL == eventUrl.standardizedFileURL
        case let (.branchChanged(url), .branchChanged(eventUrl)):
            url.standardizedFileURL == eventUrl.standardizedFileURL
        case let (.changesRequested(url), .changesRequested(eventUrl)):
            url.standardizedFileURL == eventUrl.standardizedFileURL
        case let (.checksFailed(url), .checksFailed(eventUrl)):
            url.standardizedFileURL == eventUrl.standardizedFileURL
        case (.anyAgentIdle, .agentIdle): true
        case (.anyDiffChanged, .diffChanged): true
        default: false
        }
    }
}

struct EventSubscription: Identifiable, Codable {
    let id: UUID
    var trigger: EventTrigger
    var targetAgentId: UUID
    var promptTemplate: String
    var cooldownSeconds: TimeInterval
    var maxChainDepth: Int
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        trigger: EventTrigger,
        targetAgentId: UUID,
        promptTemplate: String,
        cooldownSeconds: TimeInterval = 30,
        maxChainDepth: Int = 3,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.trigger = trigger
        self.targetAgentId = targetAgentId
        self.promptTemplate = promptTemplate
        self.cooldownSeconds = cooldownSeconds
        self.maxChainDepth = maxChainDepth
        self.isEnabled = isEnabled
    }
}

struct EventLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let event: AgentEvent
    let triggeredSubscription: UUID?
    let chainDepth: Int
}
