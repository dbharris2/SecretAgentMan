import Foundation

struct FileChange: Identifiable, Hashable {
    let id: String
    let path: String
    let insertions: Int
    let deletions: Int
    let status: ChangeStatus
    let locations: Set<ChangeLocation>

    init(
        id: String,
        path: String,
        insertions: Int,
        deletions: Int,
        status: ChangeStatus,
        locations: Set<ChangeLocation> = []
    ) {
        self.id = id
        self.path = path
        self.insertions = insertions
        self.deletions = deletions
        self.status = status
        self.locations = locations
    }

    enum ChangeStatus: String, Hashable {
        case added
        case modified
        case deleted
        case renamed

        var label: String {
            switch self {
            case .added: "A"
            case .modified: "M"
            case .deleted: "D"
            case .renamed: "R"
            }
        }
    }

    enum ChangeLocation: String, Hashable, CaseIterable {
        case staged
        case unstaged
        case untracked

        var label: String {
            switch self {
            case .staged: "Staged"
            case .unstaged: "Unstaged"
            case .untracked: "Untracked"
            }
        }
    }

    var locationLabel: String? {
        guard !locations.isEmpty else { return nil }
        if locations == [.staged, .unstaged] {
            return "Staged + unstaged"
        }
        return Self.orderedLocations
            .filter { locations.contains($0) }
            .map(\.label)
            .joined(separator: " + ")
    }

    private static let orderedLocations: [ChangeLocation] = [.staged, .unstaged, .untracked]
}
