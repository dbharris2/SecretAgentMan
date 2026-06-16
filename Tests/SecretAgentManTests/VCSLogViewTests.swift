import Foundation
@testable import SecretAgentMan
import Testing

struct VCSLogViewTests {
    @Test
    func commandSpecForGraphiteUsesGTLogWhenAvailable() {
        let spec = VCSLogView.commandSpec(for: .graphite)

        if let spec {
            #expect(spec.arguments == ["log", "--no-interactive"])
        } else {
            #expect(spec == nil)
        }
    }

    @Test
    func commandSpecForGitIsUnavailable() {
        #expect(VCSLogView.commandSpec(for: .git) == nil)
    }

    @Test
    func graphiteCommandEnvironmentForcesColor() {
        let spec = VCSLogView.CommandSpec(
            executablePath: "/bin/echo",
            arguments: [],
            perfLabel: "graphite"
        )

        let env = VCSLogView.commandEnvironment(
            for: spec,
            base: ["TERM": "dumb", "NO_COLOR": "1"]
        )

        #expect(env["TERM"] == "xterm-256color")
        #expect(env["FORCE_COLOR"] == "1")
        #expect(env["NO_COLOR"] == nil)
    }

    @Test
    func jjCommandEnvironmentUsesDumbTerminal() {
        let spec = VCSLogView.CommandSpec(
            executablePath: "/bin/echo",
            arguments: [],
            perfLabel: "jj"
        )

        let env = VCSLogView.commandEnvironment(
            for: spec,
            base: ["TERM": "xterm-256color"]
        )

        #expect(env["TERM"] == "dumb")
        #expect(env["FORCE_COLOR"] == nil)
    }

    @Test
    func commandSpecForNoneIsUnavailable() {
        #expect(VCSLogView.commandSpec(for: .none) == nil)
    }
}
