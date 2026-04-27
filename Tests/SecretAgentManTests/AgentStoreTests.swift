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

    @Test
    func addCodexAgentBasedOnNewSessionStartsWithoutSessionId() {
        let store = AgentStore(loadFromDisk: false)
        let source = Agent(
            name: "Existing",
            folder: URL(fileURLWithPath: "/tmp/project"),
            provider: .codex,
            sessionId: "source-session"
        )
        store.agents = [source]

        let created = store.addAgent(basedOn: source, sessionChoice: .newSession)

        #expect(created.provider == .codex)
        #expect(created.sessionId == nil)
        #expect(!created.hasLaunched)
    }

    @Test
    func removeAgentKeepsFolderInStore() {
        let store = AgentStore(loadFromDisk: false)
        let folder = URL(fileURLWithPath: "/tmp/keepme")
        let agent = store.addAgent(name: "Solo", folder: folder, provider: .claude)

        store.removeAgent(id: agent.id)

        #expect(store.agents.isEmpty)
        #expect(store.folders.map(\.standardizedFileURL) == [folder.standardizedFileURL])
        let groups = store.agentsByFolder
        #expect(groups.count == 1)
        #expect(groups.first?.url.standardizedFileURL == folder.standardizedFileURL)
        #expect(groups.first?.agents.isEmpty == true)
    }

    @Test
    func addFolderCreatesEmptyFolderEntry() {
        let store = AgentStore(loadFromDisk: false)
        let folder = URL(fileURLWithPath: "/tmp/empty-from-the-start")

        store.addFolder(folder)

        #expect(store.agents.isEmpty)
        #expect(store.folders.map(\.standardizedFileURL) == [folder.standardizedFileURL])
        let groups = store.agentsByFolder
        #expect(groups.count == 1)
        #expect(groups.first?.agents.isEmpty == true)
    }

    @Test
    func addFolderIsIdempotentOnStandardizedURL() {
        let store = AgentStore(loadFromDisk: false)
        let folder = URL(fileURLWithPath: "/tmp/dedup")

        store.addFolder(folder)
        store.addFolder(URL(fileURLWithPath: "/tmp/./dedup"))

        #expect(store.folders.count == 1)
    }

    @Test
    func loadDerivesFoldersFromAgentsWhenFoldersFileMissing() throws {
        let suiteName = "AgentStoreTests.derive.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let appSupportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let saveURL = AgentStore.persistenceURL(appSupportRoot: appSupportRoot)
        let foldersURL = saveURL.deletingLastPathComponent().appendingPathComponent("folders.json")

        let folderA = URL(fileURLWithPath: "/tmp/projectA")
        let folderB = URL(fileURLWithPath: "/tmp/projectB")
        let agentA = Agent(name: "A", folder: folderA, provider: .claude, sessionId: "a")
        let agentB = Agent(name: "B", folder: folderB, provider: .codex, sessionId: "b")
        try JSONEncoder().encode([agentA, agentB]).write(to: saveURL, options: .atomic)
        // No folders.json on disk — first load after upgrade.

        let store = AgentStore(loadFromDisk: true, userDefaults: defaults, saveURL: saveURL)

        let standardized = Set(store.folders.map(\.standardizedFileURL))
        #expect(standardized == Set([folderA, folderB].map(\.standardizedFileURL)))
        #expect(FileManager.default.fileExists(atPath: foldersURL.path))
    }

    @Test
    func loadHonorsPersistedEmptyFolders() throws {
        let suiteName = "AgentStoreTests.persist.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let appSupportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let saveURL = AgentStore.persistenceURL(appSupportRoot: appSupportRoot)
        let foldersURL = saveURL.deletingLastPathComponent().appendingPathComponent("folders.json")

        let emptyFolder = URL(fileURLWithPath: "/tmp/persisted-empty")
        try JSONEncoder().encode([Agent]()).write(to: saveURL, options: .atomic)
        try JSONEncoder().encode([emptyFolder]).write(to: foldersURL, options: .atomic)

        let store = AgentStore(loadFromDisk: true, userDefaults: defaults, saveURL: saveURL)

        #expect(store.agents.isEmpty)
        #expect(store.folders.map(\.standardizedFileURL) == [emptyFolder.standardizedFileURL])
    }

    @Test
    func openSessionIdsIncludesOnlyMatchingProviderAndFolder() {
        let store = AgentStore(loadFromDisk: false)
        let folder = URL(fileURLWithPath: "/tmp/project")
        let source = Agent(
            name: "Source",
            folder: folder,
            provider: .codex,
            sessionId: "source-session"
        )
        let sameFolderAndProvider = Agent(
            name: "Match",
            folder: folder,
            provider: .codex,
            sessionId: "open-session"
        )
        let otherProvider = Agent(
            name: "Other Provider",
            folder: folder,
            provider: .claude,
            sessionId: "claude-session"
        )
        let otherFolder = Agent(
            name: "Other Folder",
            folder: URL(fileURLWithPath: "/tmp/other"),
            provider: .codex,
            sessionId: "other-folder-session"
        )
        let nilSession = Agent(
            name: "No Session",
            folder: folder,
            provider: .codex,
            sessionId: nil
        )
        store.agents = [source, sameFolderAndProvider, otherProvider, otherFolder, nilSession]

        let openSessionIds = store.openSessionIds(for: source)

        #expect(openSessionIds == ["source-session", "open-session"])
    }
}
