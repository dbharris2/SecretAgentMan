import Foundation

struct ProjectScript: Identifiable, Hashable {
    var id: String {
        "\(source.rawValue)-\(name)"
    }

    let name: String
    let command: String
    let source: ScriptSource

    enum ScriptSource: String, Hashable, CaseIterable {
        case npm
        case yarn
        case bun
        case just
        case make
        case cargo
        case python

        var icon: String {
            switch self {
            case .npm, .yarn, .bun: "shippingbox"
            case .just: "terminal"
            case .make: "hammer"
            case .cargo: "gearshape"
            case .python: "chevron.left.forwardslash.chevron.right"
            }
        }
    }
}
