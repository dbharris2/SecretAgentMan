import AppKit
@testable import SecretAgentMan
import SwiftUI
import Testing

@MainActor
struct GrowingTextEditorLayoutTests {
    /// Mirrors the real `SessionPanelShell` + `SessionComposer` layout —
    /// greedy ScrollView sibling, divider, composer with padding/background.
    /// Simpler harnesses passed while the app was still broken; the modifier
    /// chain changes what SwiftUI proposes to the NSViewRepresentable.
    private func renderedHeight(
        text: String,
        outerWidth: CGFloat = 600,
        outerHeight: CGFloat = 700,
        lineLimit: ClosedRange<Int> = 1 ... 12,
        fontSize: CGFloat = 13
    ) -> CGFloat {
        final class Sink {
            var height: CGFloat = -1
        }
        let sink = Sink()

        let view = VStack(spacing: 0) {
            ScrollView { Text("placeholder transcript") }
                .frame(maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    GrowingTextEditor(
                        text: .constant(text),
                        fontSize: fontSize,
                        fontDesign: .monospaced,
                        lineLimit: lineLimit
                    )
                    .background(
                        GeometryReader { geo -> Color in
                            sink.height = geo.size.height
                            return .clear
                        }
                    )
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack {
                        Text("status")
                        Spacer()
                    }
                }
                .padding(16)
                .background(Color.gray.opacity(0.05))
            }
        }
        .frame(width: outerWidth, height: outerHeight)

        // Real NSWindow + runloop tick: SwiftUI's layout pipeline takes
        // different code paths without a window, and the GeometryReader side
        // channel needs at least one runloop iteration to fire.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: outerWidth, height: outerHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: outerWidth, height: outerHeight)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        return sink.height
    }

    private func singleLineHeight(fontSize: CGFloat = 13) -> CGFloat {
        let nsFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return NSLayoutManager().defaultLineHeight(for: nsFont)
    }

    @Test
    func emptyComposerIsOneLineTall() {
        let height = renderedHeight(text: "")
        let line = singleLineHeight()
        #expect(height > 0, "GeometryReader never reported a size")
        #expect(
            height < line * 2 + 24,
            "empty composer should be ~1 line in a greedy parent; got \(height)"
        )
    }

    @Test
    func growsWithExplicitNewlines() {
        let one = renderedHeight(text: "x")
        let three = renderedHeight(text: "x\nx\nx")
        let six = renderedHeight(text: "x\nx\nx\nx\nx\nx")
        #expect(one > 0)
        #expect(three > one + 20, "3 lines should be taller than 1; got 1=\(one) 3=\(three)")
        #expect(six > three + 20, "6 lines should be taller than 3; got 3=\(three) 6=\(six)")
    }

    @Test
    func growsMonotonicallyAcrossNewlineCount() {
        let one = renderedHeight(text: "x")
        let five = renderedHeight(text: "1\n2\n3\n4\n5")
        let ten = renderedHeight(text: "1\n2\n3\n4\n5\n6\n7\n8\n9\n10")
        #expect(one > 0)
        #expect(five > one + 30, "expected growth 1→5, got 1=\(one) 5=\(five)")
        #expect(ten > five + 30, "expected growth 5→10, got 5=\(five) 10=\(ten)")
    }

    @Test
    func capsAtMaxLinesForOverflowingContent() {
        let twentyLines = (1 ... 20).map { "line \($0)" }.joined(separator: "\n")
        let height = renderedHeight(text: twentyLines, lineLimit: 1 ... 12)
        let line = singleLineHeight()
        #expect(height > 0)
        #expect(
            height < line * 13 + 24,
            "20-line draft should cap near 12 lines; got \(height)"
        )
    }

    @Test
    func respectsCustomLineLimitUpperBound() {
        let manyLines = (1 ... 30).map { _ in "x" }.joined(separator: "\n")
        let cap5 = renderedHeight(text: manyLines, lineLimit: 1 ... 5)
        let cap10 = renderedHeight(text: manyLines, lineLimit: 1 ... 10)
        let line = singleLineHeight()
        #expect(cap5 > 0 && cap10 > 0)
        #expect(cap5 < line * 6 + 24, "lineLimit 1...5 should cap near 5 lines; got \(cap5)")
        #expect(cap10 > cap5 + line * 3, "lineLimit 1...10 should be taller than 1...5; got 5=\(cap5) 10=\(cap10)")
    }

    @Test
    func wrapsLongUnbrokenLineAcrossMultipleVisualLines() {
        let longLine = String(repeating: "a", count: 200)
        let height = renderedHeight(text: longLine, outerWidth: 400, lineLimit: 1 ... 30)
        let line = singleLineHeight()
        #expect(
            height >= line * 3,
            "200-char line at 400pt-wide should wrap to ≥3 visual lines; got \(height)"
        )
    }

    @Test
    func growsWhenAvailableWidthShrinks() {
        let longLine = String(repeating: "a", count: 200)
        let wide = renderedHeight(text: longLine, outerWidth: 800, lineLimit: 1 ... 30)
        let narrow = renderedHeight(text: longLine, outerWidth: 400, lineLimit: 1 ... 30)
        let line = singleLineHeight()
        #expect(
            narrow > wide + line,
            "narrower composer should be ≥1 line taller; got wide=\(wide) narrow=\(narrow)"
        )
    }

    @Test
    func rendersAtCorrectAbsoluteHeightForPrepopulatedText() {
        // Relative-growth tests still pass if the absolute height is wrong;
        // this pins the absolute floor for first-render with multi-line text.
        let height = renderedHeight(text: "1\n2\n3\n4\n5")
        let line = singleLineHeight()
        #expect(
            height >= line * 5,
            "5-line draft should render at ≥5 line-heights on first layout; got \(height)"
        )
    }
}
