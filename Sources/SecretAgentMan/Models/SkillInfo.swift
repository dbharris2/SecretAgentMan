import Foundation

struct SkillInfo: Identifiable, Hashable {
    var id: String {
        "\(source)-\(name)"
    }

    let name: String
    let description: String
    let source: String
}
