import SwiftUI

struct PRMetadataView: View {
    let prInfo: PRInfo

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(prInfo.state.color)
                .frame(width: 3, height: 14)
            Link(destination: prInfo.url) {
                Text(verbatim: "#\(prInfo.number)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.blue)
        }
    }
}
