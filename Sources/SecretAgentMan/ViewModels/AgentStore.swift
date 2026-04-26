import Foundation
import SwiftUI

@MainActor
@Observable
final class AgentStore {
    enum SessionLaunchChoice: Equatable {
        case resume(sessionId: String)
        case newSession
    }

    var agents: [Agent] = []
    var selectedAgentId: UUID?

    static func persistenceURL(appSupportRoot: URL? = nil) -> URL {
        let dir = (appSupportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("SecretAgentMan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agents.json")
    }

    private let persistsToFile: Bool
    private let userDefaults: UserDefaults
    private let saveURL: URL

    init(
        loadFromDisk: Bool = true,
        userDefaults: UserDefaults = .standard,
        saveURL: URL = AgentStore.persistenceURL()
    ) {
        self.persistsToFile = loadFromDisk
        self.userDefaults = userDefaults
        self.saveURL = saveURL
        if loadFromDisk {
            load()
        }
    }

    var selectedAgent: Agent? {
        agents.first { $0.id == selectedAgentId }
    }

    func openSessionIds(for source: Agent) -> Set<String> {
        Set(
            agents.compactMap { agent in
                guard agent.provider == source.provider,
                      agent.folder.standardizedFileURL == source.folder.standardizedFileURL
                else { return nil }
                return agent.sessionId
            }
        )
    }

    func selectAgent(id: UUID?) {
        guard selectedAgentId != id else { return }
        selectedAgentId = id
        persistSelectedAgentId()
    }

    var agentsByFolder: [(folder: String, agents: [Agent])] {
        let grouped = Dictionary(grouping: agents) { $0.folderPath }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (folder: $0.key, agents: $0.value.sorted { $0.createdAt < $1.createdAt }) }
    }

    func addAgent(
        name: String,
        folder: URL,
        provider: AgentProvider = .claude,
        initialPrompt: String? = nil
    ) -> Agent {
        let agent = Agent(
            name: name,
            folder: folder,
            provider: provider,
            sessionId: provider == .codex ? nil : UUID().uuidString,
            initialPrompt: initialPrompt
        )
        agents.append(agent)
        selectAgent(id: agent.id)
        save()
        return agent
    }

    @discardableResult
    func addAgent(
        basedOn source: Agent,
        sessionChoice: SessionLaunchChoice
    ) -> Agent {
        let nameSuffix: String
        let sessionId: String?
        let hasLaunched: Bool

        switch sessionChoice {
        case let .resume(existingSessionId):
            nameSuffix = "Resume \(existingSessionId.prefix(8))"
            sessionId = existingSessionId
            hasLaunched = true
        case .newSession:
            nameSuffix = "New Session"
            sessionId = source.provider == .codex ? nil : UUID().uuidString
            hasLaunched = false
        }

        let agent = Agent(
            name: "\(source.name) (\(nameSuffix))",
            folder: source.folder,
            provider: source.provider,
            sessionId: sessionId,
            hasLaunched: hasLaunched
        )
        agents.append(agent)
        selectAgent(id: agent.id)
        save()
        return agent
    }

    func removeAgent(id: UUID) {
        agents.removeAll { $0.id == id }
        if selectedAgentId == id {
            selectAgent(id: agents.first?.id)
        }
        save()
    }

    func renameAgent(id: UUID, name: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].name = name
        agents[index].updatedAt = Date()
        save()
    }

    func markLaunched(id: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].hasLaunched = true
        save()
    }

    func resetSession(id: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].sessionId = agents[index].provider == .codex ? nil : UUID().uuidString
        agents[index].hasLaunched = false
        agents[index].updatedAt = Date()
        save()
    }

    func updateSessionId(id: UUID, sessionId: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        guard agents[index].sessionId != sessionId else { return }
        agents[index].sessionId = sessionId
        agents[index].updatedAt = Date()
        save()
    }

    func updateState(id: UUID, state: AgentState) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].state = state
        agents[index].updatedAt = Date()
    }

    var hasActiveAgents: Bool {
        agents.contains { $0.state == .active || $0.state == .awaitingInput }
    }

    var awaitingInputCount: Int {
        agents.count(where: { $0.state == .awaitingInput })
    }

    // MARK: - Persistence

    private func save() {
        guard persistsToFile else { return }
        do {
            let data = try JSONEncoder().encode(agents)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            print("Failed to save agents: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL),
              var loaded = try? JSONDecoder().decode([Agent].self, from: data)
        else { return }

        // Reset transient state — processes aren't running after restart
        var needsSave = false
        for i in loaded.indices {
            loaded[i].state = .idle
            // Backfill sessionId for agents created before session persistence was added
            if loaded[i].sessionId == nil {
                loaded[i].sessionId = UUID().uuidString
                loaded[i].hasLaunched = false
                needsSave = true
            }
        }

        agents = loaded
        if let saved = userDefaults.string(forKey: UserDefaultsKeys.selectedAgentId),
           let savedId = UUID(uuidString: saved),
           agents.contains(where: { $0.id == savedId }) {
            selectAgent(id: savedId)
        } else {
            selectAgent(id: agents.first?.id)
        }

        if needsSave {
            save()
        }
    }

    private func persistSelectedAgentId() {
        guard persistsToFile else { return }
        if let selectedAgentId {
            userDefaults.set(selectedAgentId.uuidString, forKey: UserDefaultsKeys.selectedAgentId)
        } else {
            userDefaults.removeObject(forKey: UserDefaultsKeys.selectedAgentId)
        }
    }
}
