@testable import SecretAgentMan
import Testing

struct SessionMarkdownSegmentParserTests {
    @Test
    func plainMarkdownRemainsSingleMarkdownSegment() {
        let segments = SessionMarkdownSegmentParser.parse("One\n\nTwo")

        #expect(segments == [.markdown("One\n\nTwo")])
    }

    @Test
    func parsesFencedCodeBlockBetweenMarkdownSegments() {
        let segments = SessionMarkdownSegmentParser.parse("""
        Intro
        ```swift
        let value = 1
        ```
        Done
        """)

        #expect(segments == [
            .markdown("Intro"),
            .code(language: "swift", text: "let value = 1"),
            .markdown("Done"),
        ])
    }

    @Test
    func treatsUnclosedFenceAsStreamingCodeBlock() {
        let segments = SessionMarkdownSegmentParser.parse("""
        ```zsh
        jj log -r 'main::@'
        partial
        """)

        #expect(segments == [
            .code(language: "zsh", text: "jj log -r 'main::@'\npartial"),
        ])
    }

    @Test
    func requiresMatchingClosingFenceMarker() {
        let segments = SessionMarkdownSegmentParser.parse("""
        ```text
        still code
        ~~~
        ```
        """)

        #expect(segments == [
            .code(language: "text", text: "still code\n~~~"),
        ])
    }
}
