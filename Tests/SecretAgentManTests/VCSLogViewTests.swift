import Foundation
@testable import SecretAgentMan
import Testing

struct VCSLogViewTests {
    @Test
    func commandSpecForGraphiteUsesGTLogShortWhenAvailable() {
        let spec = VCSLogView.commandSpec(for: .graphite)

        if let spec {
            #expect(spec.arguments == ["log", "short", "--no-interactive"])
        } else {
            #expect(spec == nil)
        }
    }

    @Test
    func commandSpecForGitIsUnavailable() {
        #expect(VCSLogView.commandSpec(for: .git) == nil)
    }

    @Test
    func commandSpecForNoneIsUnavailable() {
        #expect(VCSLogView.commandSpec(for: .none) == nil)
    }
}
