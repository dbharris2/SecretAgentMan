import SwiftUI

struct ChangesView: View {
    let changes: [FileChange]
    let fullDiff: String

    @State private var selectedFile: String?
    @AppStorage(UserDefaultsKeys.diffViewMode) private var diffMode: String = "unified"

    private var visibleDiff: String {
        guard let selected = selectedFile else { return fullDiff }
        return filterDiff(fullDiff, forFile: selected)
    }

    var body: some View {
        ZStack {
            VSplitView {
                VStack(spacing: 0) {
                    fileList

                    HStack {
                        Spacer()
                        Picker("", selection: $diffMode) {
                            Image(systemName: "list.bullet").tag("unified")
                            Image(systemName: "rectangle.split.2x1").tag("sideBySide")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 80)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
                .frame(minHeight: 80, idealHeight: 140)

                Group {
                    if diffMode == "sideBySide" {
                        SideBySideDiffView(diffText: visibleDiff)
                    } else {
                        DiffView(diffText: visibleDiff)
                    }
                }
                .frame(minHeight: 200)
            }
            .opacity(changes.isEmpty ? 0 : 1)

            if changes.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "doc.text",
                    description: Text("No file changes detected in this directory")
                )
            }
        }
    }

    private var fileList: some View {
        List(selection: $selectedFile) {
            Section {
                ForEach(changes) { change in
                    HStack(spacing: 8) {
                        Text(change.status.label)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(statusColor(change.status))
                            .frame(width: 14, alignment: .center)

                        Text(change.path)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        HStack(spacing: 6) {
                            if change.insertions > 0 {
                                Text("+\(change.insertions)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                            if change.deletions > 0 {
                                Text("-\(change.deletions)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .tag(change.path)
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("Changed Files (\(changes.count))")
                    Spacer()
                    Text("+\(changes.reduce(0) { $0 + $1.insertions })")
                        .foregroundStyle(.green)
                    Text("-\(changes.reduce(0) { $0 + $1.deletions })")
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.inset)
    }

    private func filterDiff(_ diff: String, forFile path: String) -> String {
        let lines = diff.components(separatedBy: "\n")
        var result: [String] = []
        var inTargetFile = false

        for line in lines {
            if line.hasPrefix("diff --git") {
                inTargetFile = line.contains("b/\(path)")
            }
            if inTargetFile {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    private func statusColor(_ status: FileChange.ChangeStatus) -> Color {
        switch status {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        }
    }
}
