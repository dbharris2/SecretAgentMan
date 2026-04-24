import Foundation
@testable import SecretAgentMan

/// Test-only helpers for replaying ordered `SessionEvent` sequences through
/// the production reducer and asserting the resulting visible snapshot.
///
/// Two flavors:
///  - `replay()` returns just the final snapshot — use this when an assertion
///    only cares about the end state.
///  - `replayWithIntermediates()` returns the snapshot after every event
///    (length = events.count + 1, including the initial empty snapshot) so a
///    failing test can pinpoint which event caused the divergence.
extension [SessionEvent] {
    /// Reduce the events into a final snapshot starting from an empty one.
    func replay(initial: AgentSessionSnapshot = AgentSessionSnapshot()) -> AgentSessionSnapshot {
        reduce(initial) { AgentSessionReducer.reduce($0, event: $1) }
    }

    /// Reduce the events and return every intermediate snapshot. The first
    /// element is the initial snapshot; each subsequent element is the result
    /// of applying the event at the same index.
    func replayWithIntermediates(
        initial: AgentSessionSnapshot = AgentSessionSnapshot()
    ) -> [AgentSessionSnapshot] {
        var snapshots: [AgentSessionSnapshot] = [initial]
        for event in self {
            snapshots.append(AgentSessionReducer.reduce(snapshots[snapshots.count - 1], event: event))
        }
        return snapshots
    }
}
