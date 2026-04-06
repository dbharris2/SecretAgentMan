import SwiftUI

struct HoverHighlight: ViewModifier {
    var isSelected: Bool = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fillColor)
            )
            .onHover { isHovered = $0 }
    }

    private var fillColor: Color {
        if isSelected { return Color.accentColor.opacity(0.2) }
        if isHovered { return Color.secondary.opacity(0.1) }
        return .clear
    }
}

extension View {
    func hoverHighlight(isSelected: Bool = false) -> some View {
        modifier(HoverHighlight(isSelected: isSelected))
    }
}
