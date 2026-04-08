import Foundation
@testable import SecretAgentMan
import Testing

@MainActor
struct AgentStoreTests {
    @Test
    func selectAgentPersistsSelectionToUserDefaults() throws {
        let suiteName = "AgentStoreTests.select.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let appSupportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = AgentStore(
            loadFromDisk: true,
            userDefaults: defaults,
            saveURL: AgentStore.persistenceURL(appSupportRoot: appSupportRoot)
        )
        let agent = Agent(
            name: "Agent",
            folder: URL(fileURLWithPath: "/tmp/project"),
            provider: .claude,
            sessionId: "session"
        )
        store.agents = [agent]

        store.selectAgent(id: agent.id)

        #expect(store.selectedAgentId == agent.id)
        #expect(
            defaults.string(forKey: UserDefaultsKeys.selectedAgentId) == agent.id.uuidString
        )
    }

    @Test
    func selectAgentNilRemovesPersistedSelection() throws {
        let suiteName = "AgentStoreTests.clear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let appSupportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = AgentStore(
            loadFromDisk: true,
            userDefaults: defaults,
            saveURL: AgentStore.persistenceURL(appSupportRoot: appSupportRoot)
        )
        let agent = Agent(
            name: "Agent",
            folder: URL(fileURLWithPath: "/tmp/project"),
            provider: .claude,
            sessionId: "session"
        )
        store.agents = [agent]
        store.selectAgent(id: agent.id)

        store.selectAgent(id: nil)

        #expect(store.selectedAgentId == nil)
        #expect(defaults.string(forKey: UserDefaultsKeys.selectedAgentId) == nil)
    }

    @Test
    func loadRestoresPersistedSelectionWhenAgentExists() throws {
        let suiteName = "AgentStoreTests.restore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let appSupportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let saveURL = AgentStore.persistenceURL(appSupportRoot: appSupportRoot)

        let selectedAgent = Agent(
            name: "Selected",
            folder: URL(fileURLWithPath: "/tmp/selected"),
            provider: .claude,
            sessionId: "selected-session"
        )
        let otherAgent = Agent(
            name: "Other",
            folder: URL(fileURLWithPath: "/tmp/other"),
            provider: .codex,
            sessionId: "other-session"
        )
        let data = try JSONEncoder().encode([selectedAgent, otherAgent])
        try data.write(to: saveURL, options: .atomic)
        defaults.set(selectedAgent.id.uuidString, forKey: UserDefaultsKeys.selectedAgentId)

        let store = AgentStore(loadFromDisk: true, userDefaults: defaults, saveURL: saveURL)

        #expect(store.selectedAgentId == selectedAgent.id)
    }

    @Test
    func addAgentBasedOnResumeCreatesSelectedAgentThatLaunchesInResumeMode() {
        let store = AgentStore(loadFromDisk: false)
        let source = Agent(
            name: "Existing",
            folder: URL(fileURLWithPath: "/tmp/project"),
            provider: .codex,
            sessionId: "source-session"
        )
        store.agents = [source]
        store.selectAgent(id: source.id)

        let created = store.addAgent(basedOn: source, sessionChoice: .resume(sessionId: "resume-session"))

        #expect(created.folder == source.folder)
        #expect(created.provider == source.provider)
        #expect(created.sessionId == "resume-session")
        #expect(created.hasLaunched)
        #expect(store.selectedAgentId == created.id)
    }

    @Test
    func addAgentBasedOnNewSessionCreatesFreshSelectedAgent() throws {
        let store = AgentStore(loadFromDisk: false)
        let source = Agent(
            name: "Existing",
            folder: URL(fileURLWithPath: "/tmp/project"),
            provider: .claude,
            sessionId: "source-session"
        )
        store.agents = [source]

        let created = store.addAgent(basedOn: source, sessionChoice: .newSession)

        let sessionId = try #require(created.sessionId)
        #expect(created.folder == source.folder)
        #expect(created.provider == source.provider)
        #expect(created.id != source.id)
        #expect(!created.hasLaunched)
        #expect(!sessionId.isEmpty)
        #expect(store.selectedAgentId == created.id)
    }
}
