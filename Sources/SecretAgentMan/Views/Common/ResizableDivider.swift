import SwiftUI

struct ResizableDivider: View {
    @Binding var size: Double
    let minSize: Double
    let axis: Axis
    @Environment(\.appTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.accent.opacity(0.6))
            .frame(width: axis == .vertical ? 3 : nil, height: axis == .horizontal ? 3 : nil)
            .contentShape(hitArea)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let delta = axis == .horizontal
                            ? -value.translation.height
                            : -value.translation.width
                        size = max(minSize, size + delta)
                    }
            )
            .onHover { hovering in
                if hovering {
                    (axis == .horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private var hitArea: some Shape {
        axis == .horizontal
            ? Rectangle().size(width: 1000, height: 12)
            : Rectangle().size(width: 12, height: 1000)
    }
}
