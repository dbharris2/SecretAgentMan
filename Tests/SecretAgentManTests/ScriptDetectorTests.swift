import Foundation
@testable import SecretAgentMan
import Testing

struct ScriptDetectorTests {
    // MARK: - Justfile

    @Test
    func parsesJustfileRecipes() {
        let content = """
        default:
            just build

        build:
            swift build

        test *args:
            swift test {{args}}

        lint-check:
            swiftlint lint
        """
        let scripts = ScriptDetector.parseJustfileContent(content)
        #expect(scripts.count == 4)
        #expect(scripts[0].name == "default")
        #expect(scripts[0].command == "just default")
        #expect(scripts[1].name == "build")
        #expect(scripts[2].name == "test")
        #expect(scripts[3].name == "lint-check")
        #expect(scripts[0].source == .just)
    }

    @Test
    func parsesEmptyJustfile() {
        let scripts = ScriptDetector.parseJustfileContent("")
        #expect(scripts.isEmpty)
    }

    // MARK: - Makefile

    @Test
    func parsesMakefileTargets() {
        let content = """
        .PHONY: build test lint

        build: deps
        \tgo build ./...

        test:
        \tgo test ./...

        lint:
        \tgolangci-lint run

        deps:
        \tgo mod download
        """
        let scripts = ScriptDetector.parseMakefileContent(content)
        // Only .PHONY targets should be returned
        #expect(scripts.count == 3)
        #expect(scripts.map(\.name).contains("build"))
        #expect(scripts.map(\.name).contains("test"))
        #expect(scripts.map(\.name).contains("lint"))
        #expect(!scripts.map(\.name).contains("deps"))
        #expect(scripts[0].source == .make)
    }

    @Test
    func parsesMakefileWithoutPhony() {
        let content = """
        build:
        \tgo build

        test:
        \tgo test
        """
        let scripts = ScriptDetector.parseMakefileContent(content)
        #expect(scripts.count == 2)
        #expect(scripts[0].name == "build")
        #expect(scripts[0].command == "make build")
    }

    @Test
    func parsesEmptyMakefile() {
        let scripts = ScriptDetector.parseMakefileContent("")
        #expect(scripts.isEmpty)
    }

    // MARK: - pyproject.toml

    @Test
    func parsesPyprojectScripts() {
        let content = """
        [project]
        name = "myapp"

        [project.scripts]
        myapp = "myapp.cli:main"
        migrate = "myapp.db:migrate"

        [build-system]
        requires = ["setuptools"]
        """
        let scripts = ScriptDetector.parsePyprojectContent(content)
        #expect(scripts.count == 2)
        #expect(scripts[0].name == "myapp")
        #expect(scripts[1].name == "migrate")
        #expect(scripts[0].source == .python)
    }

    @Test
    func parsesEmptyPyproject() {
        let scripts = ScriptDetector.parsePyprojectContent("")
        #expect(scripts.isEmpty)
    }

    // MARK: - Missing directory

    @Test
    func detectScriptsReturnsEmptyForMissingDirectory() {
        let dir = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        let scripts = ScriptDetector.detectScripts(in: dir)
        #expect(scripts.isEmpty)
    }
}
