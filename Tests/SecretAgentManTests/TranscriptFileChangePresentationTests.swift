@testable import SecretAgentMan
import Testing

struct TranscriptFileChangePresentationTests {
    @Test func fileNameUsesOnlyTheLastPathComponent() {
        #expect(
            TranscriptFileChangePresentation.fileName(
                from: "/Users/devonharris/code/SecretAgentMan/Sources/SessionEvent.swift"
            ) == "SessionEvent.swift"
        )
    }

    @Test func fileNameLeavesBareNamesUntouched() {
        #expect(TranscriptFileChangePresentation.fileName(from: "SessionEvent.swift") == "SessionEvent.swift")
    }
}
