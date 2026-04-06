import SwiftUI

struct BranchInfoView: View {
    let branchName: String

    var body: some View {
        Text(branchName)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
