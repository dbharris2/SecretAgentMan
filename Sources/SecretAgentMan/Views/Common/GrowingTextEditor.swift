import AppKit
import SwiftUI

/// `TextEditor`-shaped view that auto-grows to fit content from
/// `lineLimit.lowerBound` to `lineLimit.upperBound` lines, then scrolls
/// internally. Wraps `NSTextView` directly because SwiftUI's `TextEditor` on
/// macOS has no usable intrinsic height — every pure-SwiftUI sizing trick
/// either pegs at maxHeight or stalls at minHeight inside a greedy parent.
struct GrowingTextEditor: View {
    @Binding var text: String
    var fontSize: CGFloat = 13
    var fontDesign: Font.Design = .default
    var lineLimit: ClosedRange<Int> = 1 ... 12
    var focused: FocusState<Bool>.Binding?

    var body: some View {
        GrowingNSTextView(
            text: $text,
            font: nsFont,
            lineLimit: lineLimit,
            focused: focused
        )
    }

    private var nsFont: NSFont {
        switch fontDesign {
        case .monospaced: .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        default: .systemFont(ofSize: fontSize)
        }
    }
}

private struct GrowingNSTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let lineLimit: ClosedRange<Int>
    let focused: FocusState<Bool>.Binding?

    private static let verticalInset: CGFloat = 16
    private static let lineFragmentPadding: CGFloat = 5

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        // swiftlint:disable:next force_cast
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset / 2)
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // `GrowingNSTextView` is a struct — the Coordinator's captured copy
        // goes stale on each re-render. Refresh so delegate callbacks see the
        // current binding.
        context.coordinator.parent = self

        // swiftlint:disable:next force_cast
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            // Only an external replacement (slash menu, clear-on-send, etc.)
            // can reach this branch — user typing arrives via `textDidChange`,
            // which writes the binding to the value already in `textView`, so
            // by the time we re-enter `updateNSView` the strings match and
            // this block is skipped. Place the caret at the end so programmatic
            // insertions land where the user expects to keep typing.
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
        if textView.font != font {
            textView.font = font
        }

        // Only grant focus on a false→true transition. Acting on every update
        // (including the symmetric `focused == false` branch) yanks first
        // responder away mid-keystroke because the FocusState binding lags
        // `textDidBeginEditing` by a render.
        guard let focused, focused.wrappedValue else { return }
        let textViewIsFirstResponder = textView.window?.firstResponder === textView
        if !textViewIsFirstResponder {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView _: NSScrollView,
        context _: Context
    ) -> CGSize? {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let minHeight = lineHeight * CGFloat(lineLimit.lowerBound) + Self.verticalInset
        let maxHeight = lineHeight * CGFloat(lineLimit.upperBound) + Self.verticalInset

        // Returning nil for an unspecified / infinite proposal would let
        // `NSScrollView`'s greedy default through, pegging us at maxHeight.
        let resolvedWidth: CGFloat = {
            guard let width = proposal.width, width > 0, width.isFinite else {
                return 200
            }
            return width
        }()

        let textWidth = max(1, resolvedWidth - 2 * Self.lineFragmentPadding)
        let measureString = text.isEmpty ? " " : text
        let bounds = NSAttributedString(
            string: measureString,
            attributes: [.font: font]
        ).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let contentHeight = ceil(bounds.height) + Self.verticalInset
        return CGSize(
            width: resolvedWidth,
            height: max(minHeight, min(contentHeight, maxHeight))
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingNSTextView

        init(parent: GrowingNSTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }

        func textDidBeginEditing(_: Notification) {
            if let focused = parent.focused, !focused.wrappedValue {
                focused.wrappedValue = true
            }
        }

        func textDidEndEditing(_: Notification) {
            if let focused = parent.focused, focused.wrappedValue {
                focused.wrappedValue = false
            }
        }
    }
}
