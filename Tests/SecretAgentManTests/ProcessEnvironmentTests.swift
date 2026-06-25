import Foundation
@testable import SecretAgentMan
import Testing

struct ProcessEnvironmentTests {
    @Test
    func interactiveEnvironmentAddsUserBinaryPathsAheadOfGuiPath() {
        let environment = ProcessEnvironment.interactive(base: [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin",
        ])

        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["PATH"] == [
            "/Users/tester/.local/bin",
            "/Users/tester/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":"))
    }

    @Test
    func mergedPathPreservesCustomEntriesAndDeduplicatesStandardPaths() throws {
        let path = ProcessEnvironment.mergedPath(
            currentPath: "/custom/bin:/opt/homebrew/bin:/usr/bin:/custom/bin",
            homeDirectory: "/Users/tester"
        )
        let components = path.split(separator: ":").map(String.init)
        let customIndex = try #require(components.firstIndex(of: "/custom/bin"))
        let standardIndex = try #require(components.firstIndex(of: "/usr/local/sbin"))

        #expect(components.count(where: { $0 == "/custom/bin" }) == 1)
        #expect(components.count(where: { $0 == "/opt/homebrew/bin" }) == 1)
        #expect(customIndex > standardIndex)
    }

    @Test
    func interactiveArraySortsKeysForStableLaunchEnvironment() {
        let environment = ProcessEnvironment.interactiveArray(base: [
            "PATH": "/usr/bin",
            "HOME": "/Users/tester",
            "ZZZ": "last",
        ])

        #expect(environment.first == "HOME=/Users/tester")
        #expect(environment.last == "ZZZ=last")
    }
}
