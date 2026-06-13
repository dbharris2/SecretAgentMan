import SwiftUI

struct BranchInfoView: View {
    let branchName: String?
    let vcsType: DiffService.VCSType?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let vcsType, vcsType != .none {
                Text(vcsType.displayName)
                    .scaledFont(size: 10, weight: .medium)
                    .foregroundStyle(theme.foreground.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(theme.foreground.opacity(0.12))
                    )
            }

            if let branchName {
                Text(branchName)
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

private extension DiffService.VCSType {
    var displayName: String {
        switch self {
        case .jj:
            "JJ"
        case .graphite:
            "Graphite"
        case .git:
            "Git"
        case .none:
            ""
        }
    }
}
