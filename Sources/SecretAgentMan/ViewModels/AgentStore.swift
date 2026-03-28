import Foundation
import SwiftUI

@MainActor
@Observable
final class AgentStore {
    var agents: [Agent] = []
    var selectedAgentId: UUID?

    private static let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretAgentMan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agents.json")
    }()

    init() {
        load()
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

    func addAgent(name: String, folder: URL, initialPrompt: String? = nil) -> Agent {
        let agent = Agent(name: name, folder: folder, initialPrompt: initialPrompt)
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

    func updateState(id: UUID, state: AgentState) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].state = state
    }

    func updatePid(id: UUID, pid: Int32) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].pid = pid
    }

    var hasActiveAgents: Bool {
        agents.contains { $0.state == .active || $0.state == .awaitingInput }
    }

    var awaitingInputCount: Int {
        agents.filter { $0.state == .awaitingInput }.count
    }

    // MARK: - Persistence

    private func save() {
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
        for i in loaded.indices {
            loaded[i].state = .idle
            loaded[i].pid = nil
        }

        agents = loaded
        selectedAgentId = agents.first?.id
    }
}
