import SwiftUI

/// A `ScrollView` that auto-scrolls to the bottom whenever its content grows,
/// but only while the user is "pinned" to the bottom (within `pinThreshold`).
///
/// The wrapper measures the live distance between the bottom of its content
/// and the bottom of the visible viewport, exposing it via `distanceFromBottom`
/// so callers can render affordances like a "go to bottom" button.
///
/// The `overlay` closure receives the current distance plus a `scrollToBottom`
/// action so the overlay can render conditionally and trigger an animated jump
/// without needing access to the internal `ScrollViewProxy`.
struct AutoScrollingScrollView<Content: View, Overlay: View, Trigger: Equatable>: View {
    let trigger: Trigger
    let pinThreshold: CGFloat
    @Binding var distanceFromBottom: CGFloat
    @ViewBuilder let content: (ScrollViewProxy) -> Content
    @ViewBuilder let overlay: (_ distance: CGFloat, _ scrollToBottom: @escaping () -> Void) -> Overlay

    private static var bottomAnchor: String {
        "auto-scrolling-bottom"
    }

    init(
        trigger: Trigger,
        pinThreshold: CGFloat = 60,
        distanceFromBottom: Binding<CGFloat>,
        @ViewBuilder content: @escaping (ScrollViewProxy) -> Content,
        @ViewBuilder overlay: @escaping (CGFloat, @escaping () -> Void) -> Overlay = { _, _ in EmptyView() }
    ) {
        self.trigger = trigger
        self.pinThreshold = pinThreshold
        self._distanceFromBottom = distanceFromBottom
        self.content = content
        self.overlay = overlay
    }

    var body: some View {
        // `.global` is the most reliable coordinate space here — preference
        // pipelines tied to the ScrollView's local space silently returned
        // zero in macOS 14 + Swift 6 strict concurrency mode.
        GeometryReader { outer in
            let scrollBottomY = outer.frame(in: .global).maxY
            let viewportHeight = outer.size.height
            ScrollViewReader { proxy in
                let scrollToBottom: () -> Void = {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            content(proxy)
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchor)
                                .background(
                                    GeometryReader { inner in
                                        // Round to whole points so subpixel
                                        // scroll deltas don't trigger a parent
                                        // re-render on every frame of inertia.
                                        let y = inner.frame(in: .global).maxY
                                        let raw = max(0, y - scrollBottomY)
                                        Color.clear.preference(
                                            key: AutoScrollDistanceKey.self,
                                            value: raw.rounded()
                                        )
                                    }
                                )
                        }
                    }
                    // `.initialOffset` gives us bottom-start on first appear
                    // without touching ongoing layout — `.sizeChanges` and the
                    // unparameterized form both leave NSScrollView's tracking
                    // areas stale on macOS (cursor freezes, left-clicks miss
                    // until any user scroll). Ongoing re-pin during MarkdownUI's
                    // multi-pass settling is handled imperatively by the
                    // `onScrollGeometryChange` handler below.
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentSize.height
                    } action: { oldHeight, newHeight in
                        if newHeight > oldHeight, distanceFromBottom <= pinThreshold {
                            scrollToBottom()
                        }
                    }
                    .onPreferenceChange(AutoScrollDistanceKey.self) { distanceFromBottom = $0 }
                    // Content-size growth covers most cases; `trigger` catches
                    // signals that don't change content size (e.g. thinking-bubble
                    // toggles that swap one bubble for another of equal height).
                    // `initial: true` also handles first appearance, since
                    // `onScrollGeometryChange` only fires on subsequent changes.
                    .onChange(of: trigger, initial: true) { _, _ in
                        if distanceFromBottom <= pinThreshold {
                            scrollToBottom()
                        }
                    }
                    // Viewport shrinks (e.g. composer growing) don't change
                    // content size, so they need their own re-scroll trigger.
                    .onChange(of: viewportHeight) { _, _ in
                        if distanceFromBottom <= pinThreshold {
                            scrollToBottom()
                        }
                    }

                    overlay(distanceFromBottom, scrollToBottom)
                }
            }
        }
    }
}

private struct AutoScrollDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
