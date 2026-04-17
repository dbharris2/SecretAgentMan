import SwiftUI

enum StatusTone: Equatable {
    case neutral
    case success
    case info
    case warning
    case danger
    case orange
    case queued
    case merged
}

extension StatusTone {
    func color(in theme: AppTheme) -> Color {
        switch self {
        case .neutral: theme.foreground.opacity(0.5)
        case .success: theme.green
        case .info: theme.blue
        case .warning: theme.yellow
        case .danger: theme.red
        case .orange: theme.orange
        case .queued: theme.yellow.opacity(0.8)
        case .merged: theme.magenta
        }
    }
}

struct AgentStatePresentation: Equatable {
    let label: String
    let systemImage: String
    let tone: StatusTone
}

struct PRCheckStatusPresentation: Equatable {
    let label: String
    let tone: StatusTone
}

extension AgentState {
    var presentation: AgentStatePresentation {
        switch self {
        case .idle:
            AgentStatePresentation(label: "Idle", systemImage: "circle", tone: .neutral)
        case .active:
            AgentStatePresentation(label: "Working", systemImage: "bolt.fill", tone: .info)
        case .needsPermission:
            AgentStatePresentation(
                label: "Needs Approval",
                systemImage: "hand.raised.fill",
                tone: .orange
            )
        case .awaitingInput:
            AgentStatePresentation(label: "Ready", systemImage: "circle.fill", tone: .success)
        case .awaitingResponse:
            AgentStatePresentation(
                label: "Needs Input",
                systemImage: "questionmark.bubble.fill",
                tone: .warning
            )
        case .finished:
            AgentStatePresentation(label: "Done", systemImage: "checkmark.circle", tone: .neutral)
        case .error:
            AgentStatePresentation(
                label: "Error",
                systemImage: "xmark.octagon.fill",
                tone: .danger
            )
        }
    }
}

extension PRState {
    var tone: StatusTone {
        switch self {
        case .draft: .neutral
        case .changesRequested: .danger
        case .needsReview: .warning
        case .approved: .success
        case .inMergeQueue: .queued
        case .merged: .merged
        }
    }
}

extension PRCheckStatus {
    var presentation: PRCheckStatusPresentation {
        switch self {
        case .pass:
            PRCheckStatusPresentation(label: "Checks passed", tone: .success)
        case .fail:
            PRCheckStatusPresentation(label: "Checks failed", tone: .danger)
        case .pending:
            PRCheckStatusPresentation(label: "Checks running", tone: .warning)
        case .none:
            PRCheckStatusPresentation(label: "No checks", tone: .neutral)
        }
    }
}
