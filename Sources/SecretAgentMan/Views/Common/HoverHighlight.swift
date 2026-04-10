import SwiftUI

struct HoverHighlight: ViewModifier {
    var isSelected: Bool = false
    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fillColor)
            )
            .onHover { isHovered = $0 }
    }

    private var fillColor: Color {
        if isSelected { return theme.accent.opacity(0.2) }
        if isHovered { return theme.foreground.opacity(0.06) }
        return .clear
    }
}

extension View {
    func hoverHighlight(isSelected: Bool = false) -> some View {
        modifier(HoverHighlight(isSelected: isSelected))
    }
}
