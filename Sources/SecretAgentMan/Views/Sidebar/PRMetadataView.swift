import SwiftUI

struct PRMetadataView: View {
    let prInfo: PRInfo
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(prInfo.state.tone.color(in: theme))
                .frame(width: 3, height: 14)
            Link(destination: prInfo.url) {
                Text(verbatim: "#\(prInfo.number)")
            }
            .scaledFont(size: 11)
            .foregroundStyle(theme.blue)
        }
    }
}
