import SwiftUI

struct SkillsPopover: View {
    let skills: [SkillInfo]
    var onSend: ((SkillInfo) -> Void)?

    private var grouped: [(source: String, skills: [SkillInfo])] {
        let dict = Dictionary(grouping: skills) { $0.source }
        return dict.keys.sorted { lhs, rhs in
            // "local" sorts first, then alphabetical
            if lhs == "local" { return true }
            if rhs == "local" { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }.compactMap { source in
            guard let items = dict[source] else { return nil }
            return (source: source, skills: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Skills")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Divider()

            if skills.isEmpty {
                Text("No skills available")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(grouped, id: \.source) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: group.source == "local" ? "folder" : "puzzlepiece.extension")
                                        .font(.system(size: 9))
                                    Text(group.source)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)

                                ForEach(group.skills) { skill in
                                    SkillRow(skill: skill, onSend: onSend)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(10)
        .frame(minWidth: 240)
    }
}

private struct SkillRow: View {
    let skill: SkillInfo
    var onSend: ((SkillInfo) -> Void)?

    var body: some View {
        Button {
            onSend?(skill)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("/\(skill.name)")
                        .font(.system(size: 12, weight: .medium))
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}
