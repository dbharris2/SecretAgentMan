import SwiftUI

/// A `ScrollView` that auto-scrolls to the bottom whenever `trigger` changes,
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
                    // `MarkdownUI` settles bubble heights across multiple
                    // layout passes after mount. An imperative initial
                    // `scrollTo(.bottom)` races that growth and lands short.
                    // `defaultScrollAnchor(.bottom)` makes SwiftUI keep the
                    // content's bottom pinned to the viewport's bottom on
                    // every content-size change, so the panel opens flush
                    // at the bottom and stays there as layout settles —
                    // without fighting user-driven scrolls.
                    .defaultScrollAnchor(.bottom)
                    .onPreferenceChange(AutoScrollDistanceKey.self) { distanceFromBottom = $0 }
                    .onChange(of: trigger) { _, _ in
                        if distanceFromBottom <= pinThreshold {
                            scrollToBottom()
                        }
                    }
                    // `defaultScrollAnchor` only reacts to content-size
                    // changes, not viewport shrinks (e.g. composer growing).
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
