import SwiftUI

struct PRMetadataView: View {
    let prInfo: PRInfo

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(prInfo.state.color)
                .frame(width: 3, height: 14)
            Link(destination: prInfo.url) {
                Text(verbatim: "#\(prInfo.number)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.blue)
            Text(verbatim: "+\(prInfo.additions)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.green)
            Text(verbatim: "-\(prInfo.deletions)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.red)
            if prInfo.checkStatus != .none {
                Image(systemName: "flask.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(prInfo.checkStatus.color)
                    .help(prInfo.checkStatus.label)
            }
            ForEach(prInfo.reviewers, id: \.self) { reviewer in
                AsyncImage(url: reviewer.avatarURL) { image in
                    image.resizable()
                } placeholder: {
                    Text(verbatim: String(reviewer.login.prefix(2)))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 16, height: 16)
                .background(Color.secondary.opacity(0.6))
                .clipShape(Circle())
                .help(reviewer.login)
            }
        }
    }
}
