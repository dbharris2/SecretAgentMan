import Foundation
@testable import SecretAgentMan
import Testing

struct AgentEventBusTests {
    // MARK: - EventTrigger matching

    @Test
    func triggerMatchesSpecificAgentIdle() {
        let id = UUID()
        let trigger = EventTrigger.agentIdle(agentId: id)
        #expect(trigger.matches(.agentIdle(agentId: id)))
        #expect(!trigger.matches(.agentIdle(agentId: UUID())))
        #expect(!trigger.matches(.agentActive(agentId: id)))
    }

    @Test
    func triggerMatchesAnyAgentIdle() {
        let trigger = EventTrigger.anyAgentIdle
        #expect(trigger.matches(.agentIdle(agentId: UUID())))
        #expect(trigger.matches(.agentIdle(agentId: UUID())))
        #expect(!trigger.matches(.agentActive(agentId: UUID())))
    }

    @Test
    func triggerMatchesDiffChanged() {
        let folder = URL(fileURLWithPath: "/tmp/repo")
        let trigger = EventTrigger.diffChanged(folder: folder)
        #expect(trigger.matches(.diffChanged(folder: folder)))
        #expect(!trigger.matches(.diffChanged(folder: URL(fileURLWithPath: "/tmp/other"))))
    }

    @Test
    func triggerMatchesAnyDiffChanged() {
        let trigger = EventTrigger.anyDiffChanged
        #expect(trigger.matches(.diffChanged(folder: URL(fileURLWithPath: "/tmp/a"))))
        #expect(trigger.matches(.diffChanged(folder: URL(fileURLWithPath: "/tmp/b"))))
        #expect(!trigger.matches(.branchChanged(folder: URL(fileURLWithPath: "/tmp/a"))))
    }

    // MARK: - EventBus publish/subscribe

    @Test
    @MainActor
    func publishFiresMatchingSubscription() {
        let bus = AgentEventBus(loadFromDisk: false)
        let sourceAgent = UUID()
        let targetAgent = UUID()
        var receivedPrompt: (UUID, String)?

        bus.onSendPrompt = { agentId, prompt in
            receivedPrompt = (agentId, prompt)
        }

        bus.addSubscription(EventSubscription(
            trigger: .agentIdle(agentId: sourceAgent),
            targetAgentId: targetAgent,
            promptTemplate: "Review changes"
        ))

        bus.publish(.agentIdle(agentId: sourceAgent))

        #expect(receivedPrompt?.0 == targetAgent)
        #expect(receivedPrompt?.1 == "Review changes")
    }

    @Test
    @MainActor
    func publishSkipsNonMatchingSubscription() {
        let bus = AgentEventBus(loadFromDisk: false)
        var promptSent = false

        bus.onSendPrompt = { _, _ in promptSent = true }

        bus.addSubscription(EventSubscription(
            trigger: .agentIdle(agentId: UUID()),
            targetAgentId: UUID(),
            promptTemplate: "test"
        ))

        bus.publish(.agentIdle(agentId: UUID()))

        #expect(!promptSent)
    }

    @Test
    @MainActor
    func preventsSelfTriggering() {
        let bus = AgentEventBus(loadFromDisk: false)
        let agentId = UUID()
        var promptSent = false

        bus.onSendPrompt = { _, _ in promptSent = true }

        bus.addSubscription(EventSubscription(
            trigger: .anyAgentIdle,
            targetAgentId: agentId,
            promptTemplate: "test"
        ))

        // Agent's own idle event should not trigger itself
        bus.publish(.agentIdle(agentId: agentId))

        #expect(!promptSent)
    }

    @Test
    @MainActor
    func cooldownPreventsRapidFiring() {
        let bus = AgentEventBus(loadFromDisk: false)
        let sourceAgent = UUID()
        let targetAgent = UUID()
        var fireCount = 0

        bus.onSendPrompt = { _, _ in fireCount += 1 }

        bus.addSubscription(EventSubscription(
            trigger: .agentIdle(agentId: sourceAgent),
            targetAgentId: targetAgent,
            promptTemplate: "test",
            cooldownSeconds: 60
        ))

        bus.publish(.agentIdle(agentId: sourceAgent))
        bus.publish(.agentIdle(agentId: sourceAgent))
        bus.publish(.agentIdle(agentId: sourceAgent))

        #expect(fireCount == 1)
    }

    @Test
    @MainActor
    func disabledSubscriptionDoesNotFire() {
        let bus = AgentEventBus(loadFromDisk: false)
        let sourceAgent = UUID()
        var promptSent = false

        bus.onSendPrompt = { _, _ in promptSent = true }

        bus.addSubscription(EventSubscription(
            trigger: .agentIdle(agentId: sourceAgent),
            targetAgentId: UUID(),
            promptTemplate: "test",
            isEnabled: false
        ))

        bus.publish(.agentIdle(agentId: sourceAgent))

        #expect(!promptSent)
    }

    @Test
    @MainActor
    func eventLogRecordsEvents() {
        let bus = AgentEventBus(loadFromDisk: false)
        let agentId = UUID()

        bus.publish(.agentIdle(agentId: agentId))
        bus.publish(.agentActive(agentId: agentId))

        #expect(bus.eventLog.count == 2)
    }

    @Test
    @MainActor
    func removeSubscriptionStopsTriggering() {
        let bus = AgentEventBus(loadFromDisk: false)
        let sourceAgent = UUID()
        var promptSent = false

        bus.onSendPrompt = { _, _ in promptSent = true }

        let sub = EventSubscription(
            trigger: .agentIdle(agentId: sourceAgent),
            targetAgentId: UUID(),
            promptTemplate: "test",
            cooldownSeconds: 0
        )
        bus.addSubscription(sub)
        bus.removeSubscription(id: sub.id)

        bus.publish(.agentIdle(agentId: sourceAgent))

        #expect(!promptSent)
    }

    @Test
    @MainActor
    func toggleSubscriptionDisablesAndEnables() {
        let bus = AgentEventBus(loadFromDisk: false)
        let sub = EventSubscription(
            trigger: .anyAgentIdle,
            targetAgentId: UUID(),
            promptTemplate: "test"
        )
        bus.addSubscription(sub)

        #expect(bus.subscriptions.first?.isEnabled == true)

        bus.toggleSubscription(id: sub.id)
        #expect(bus.subscriptions.first?.isEnabled == false)

        bus.toggleSubscription(id: sub.id)
        #expect(bus.subscriptions.first?.isEnabled == true)
    }
}
