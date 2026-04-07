import Foundation

struct ReviewerGroup: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var reviewers: [String] // GitHub usernames

    init(id: UUID = UUID(), name: String, reviewers: [String] = []) {
        self.id = id
        self.name = name
        self.reviewers = reviewers
    }
}

@Observable
final class ReviewerGroupStore {
    var groups: [ReviewerGroup] = []

    private static let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SecretAgentMan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reviewer_groups.json")
    }()

    init() {
        load()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: Self.saveURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.saveURL),
              let decoded = try? JSONDecoder().decode([ReviewerGroup].self, from: data)
        else { return }
        groups = decoded
    }
}
