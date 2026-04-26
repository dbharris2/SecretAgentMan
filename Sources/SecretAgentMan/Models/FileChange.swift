import Foundation

struct FileChange: Identifiable, Hashable {
    let id: String
    let path: String
    let insertions: Int
    let deletions: Int
    let status: ChangeStatus

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
}
