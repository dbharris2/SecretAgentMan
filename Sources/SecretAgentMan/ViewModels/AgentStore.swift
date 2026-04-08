import Foundation
import SwiftUI

@MainActor
@Observable
final class AgentStore {
    var agents: [Agent] = []
    var selectedAgentId: UUID?
    var pendingPrompts: [PendingPrompt] = []

    func addPendingPrompt(_ prompt: PendingPrompt) {
        guard !pendingPrompts.contains(where: { $0.agentId == prompt.agentId && $0.source == prompt.source }) else { return }
        pendingPrompts.append(prompt)
    }

    func removePendingPrompt(id: UUID) {
        pendingPrompts.removeAll { $0.id == id }
    }

    func pendingPrompts(for agentId: UUID) -> [PendingPrompt] {
        pendingPrompts.filter { $0.agentId == agentId }
    }

    func removePendingPrompts(for agentId: UUID, source: PendingPrompt.PromptSource) {
        pendingPrompts.removeAll { $0.agentId == agentId && $0.source == source }
    }

    private static let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretAgentMan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agents.json")
    }()

    private let persistsToFile: Bool

    init(loadFromDisk: Bool = true) {
        self.persistsToFile = loadFromDisk
        if loadFromDisk {
            load()
        }
    }

    var selectedAgent: Agent? {
        agents.first { $0.id == selectedAgentId }
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
            sessionId: UUID().uuidString,
            initialPrompt: initialPrompt
        )
        agents.append(agent)
        selectedAgentId = agent.id
        save()
        return agent
    }

    func removeAgent(id: UUID) {
        agents.removeAll { $0.id == id }
        if selectedAgentId == id {
            selectedAgentId = agents.first?.id
        }
        save()
    }

    func renameAgent(id: UUID, name: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].name = name
        save()
    }

    func markLaunched(id: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].hasLaunched = true
        save()
    }

    func resetSession(id: UUID) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].sessionId = UUID().uuidString
        agents[index].hasLaunched = false
        save()
    }

    func updateSessionId(id: UUID, sessionId: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        guard agents[index].sessionId != sessionId else { return }
        agents[index].sessionId = sessionId
        save()
    }

    func updateState(id: UUID, state: AgentState) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].state = state
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
            try data.write(to: Self.saveURL, options: .atomic)
        } catch {
            print("Failed to save agents: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.saveURL),
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
        if let saved = UserDefaults.standard.string(forKey: "selectedAgentId"),
           let savedId = UUID(uuidString: saved),
           agents.contains(where: { $0.id == savedId }) {
            selectedAgentId = savedId
        } else {
            selectedAgentId = agents.first?.id
        }

        if needsSave {
            save()
        }
    }
}
