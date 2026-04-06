import Foundation
import OSLog

@MainActor
@Observable
final class AgentEventBus {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.secretagentman",
        category: "EventBus"
    )

    var subscriptions: [EventSubscription] = []
    private(set) var eventLog: [EventLogEntry] = []

    private var lastFired: [UUID: Date] = [:]
    private var currentChainDepth = 0
    private let maxLogEntries = 200

    /// Called when a subscription fires and needs to send input to an agent.
    var onSendPrompt: ((UUID, String) -> Void)?

    private static let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretAgentMan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("subscriptions.json")
    }()

    init(loadFromDisk: Bool = true) {
        if loadFromDisk {
            loadSubscriptions()
        }
    }

    func publish(_ event: AgentEvent) {
        let entry = EventLogEntry(
            timestamp: Date(),
            event: event,
            triggeredSubscription: nil,
            chainDepth: currentChainDepth
        )
        appendLog(entry)

        for subscription in subscriptions where subscription.isEnabled {
            guard subscription.trigger.matches(event) else { continue }

            // Prevent self-triggering: don't let an agent's own events prompt itself
            if case let .agentIdle(agentId) = event, agentId == subscription.targetAgentId { continue }
            if case let .agentActive(agentId) = event, agentId == subscription.targetAgentId { continue }

            // Cooldown check
            if let last = lastFired[subscription.id],
               Date().timeIntervalSince(last) < subscription.cooldownSeconds {
                Self.logger.debug("Skipping \(subscription.id) — cooldown")
                continue
            }

            // Chain depth check
            if currentChainDepth >= subscription.maxChainDepth {
                Self.logger.warning("Skipping \(subscription.id) — chain depth \(self.currentChainDepth)")
                continue
            }

            // Fire the subscription
            lastFired[subscription.id] = Date()
            let logEntry = EventLogEntry(
                timestamp: Date(),
                event: event,
                triggeredSubscription: subscription.id,
                chainDepth: currentChainDepth
            )
            appendLog(logEntry)

            Self.logger.info("Firing subscription \(subscription.id) → agent \(subscription.targetAgentId)")

            currentChainDepth += 1
            onSendPrompt?(subscription.targetAgentId, subscription.promptTemplate)
            currentChainDepth -= 1
        }
    }

    func addSubscription(_ subscription: EventSubscription) {
        subscriptions.append(subscription)
        saveSubscriptions()
    }

    func removeSubscription(id: UUID) {
        subscriptions.removeAll { $0.id == id }
        lastFired.removeValue(forKey: id)
        saveSubscriptions()
    }

    func toggleSubscription(id: UUID) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].isEnabled.toggle()
        saveSubscriptions()
    }

    func clearLog() {
        eventLog.removeAll()
    }

    // MARK: - Private

    private func appendLog(_ entry: EventLogEntry) {
        eventLog.append(entry)
        if eventLog.count > maxLogEntries {
            eventLog.removeFirst()
        }
    }

    private func saveSubscriptions() {
        do {
            let data = try JSONEncoder().encode(subscriptions)
            try data.write(to: Self.saveURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save subscriptions: \(error)")
        }
    }

    private func loadSubscriptions() {
        guard let data = try? Data(contentsOf: Self.saveURL),
              let loaded = try? JSONDecoder().decode([EventSubscription].self, from: data)
        else { return }
        subscriptions = loaded
    }
}
