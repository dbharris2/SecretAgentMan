import SwiftUI

struct ChangesView: View {
    let changes: [FileChange]
    let fullDiff: String

    @State private var selectedFile: String?

    private var visibleDiff: String {
        guard let selected = selectedFile else { return fullDiff }
        return filterDiff(fullDiff, forFile: selected)
    }

    var body: some View {
        if changes.isEmpty {
            ContentUnavailableView(
                "No Changes",
                systemImage: "doc.text",
                description: Text("No file changes detected in this directory")
            )
        } else {
            VSplitView {
                fileList
                    .frame(minHeight: 80, idealHeight: 120)

                DiffView(diffText: visibleDiff)
                    .frame(minHeight: 200)
            }
        }
    }

    private var fileList: some View {
        List(selection: $selectedFile) {
            Section("Changed Files (\(changes.count))") {
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
            }
        }
        .listStyle(.inset)
    }

    /// Extract only the diff hunks for a specific file from the full unified diff.
    private func filterDiff(_ diff: String, forFile path: String) -> String {
        let lines = diff.components(separatedBy: "\n")
        var result: [String] = []
        var inTargetFile = false

        for line in lines {
            if line.hasPrefix("diff --git") {
                // Check if this diff block is for our target file
                // Format: "diff --git a/path b/path"
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
