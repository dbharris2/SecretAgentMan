import SwiftUI

enum AgentState: String, Hashable {
    case idle
    case active
    case needsPermission
    case awaitingInput
    case finished
    case error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .active: "Working"
        case .needsPermission: "Needs Approval"
        case .awaitingInput: "Ready"
        case .finished: "Done"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .active: .orange
        case .needsPermission: .red
        case .awaitingInput: .green
        case .finished: .secondary
        case .error: .red
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .active: "bolt.circle.fill"
        case .needsPermission: "exclamationmark.circle.fill"
        case .awaitingInput: "circle.fill"
        case .finished: "checkmark.circle"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}
