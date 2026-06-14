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
    @State private var isPinnedToBottom = true

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
                    }
                }
                // `.initialOffset` gives us bottom-start on first appear
                // without touching ongoing layout — `.sizeChanges` and the
                // unparameterized form both leave NSScrollView's tracking
                // areas stale on macOS (cursor freezes, left-clicks miss
                // until any user scroll).
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    ScrollMetrics(
                        contentHeight: geometry.contentSize.height,
                        contentOffsetY: geometry.contentOffset.y,
                        viewportHeight: geometry.containerSize.height
                    )
                } action: { oldMetrics, newMetrics in
                    let oldDistance = oldMetrics.distanceFromBottom
                    let newDistance = newMetrics.distanceFromBottom.rounded()
                    let contentGrew = newMetrics.contentHeight > oldMetrics.contentHeight
                    let viewportShrank = newMetrics.viewportHeight < oldMetrics.viewportHeight
                    let wasPinned = isPinnedToBottom || oldDistance <= pinThreshold

                    distanceFromBottom = newDistance

                    if contentGrew || viewportShrank, wasPinned {
                        scrollToBottom()
                        isPinnedToBottom = true
                    } else {
                        isPinnedToBottom = newDistance <= pinThreshold
                    }
                }
                // `trigger` catches equal-height swaps such as thinking/pending
                // state changes where the content-height callback does not fire.
                .onChange(of: trigger, initial: true) { _, _ in
                    if isPinnedToBottom {
                        scrollToBottom()
                    }
                }

                overlay(distanceFromBottom, scrollToBottom)
            }
        }
    }
}

private struct ScrollMetrics: Equatable {
    let contentHeight: CGFloat
    let contentOffsetY: CGFloat
    let viewportHeight: CGFloat

    var distanceFromBottom: CGFloat {
        max(0, contentHeight - (contentOffsetY + viewportHeight))
    }
}
