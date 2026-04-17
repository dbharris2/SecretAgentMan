import AppKit
import SwiftUI

struct ChangesView: View {
    let changes: [FileChange]
    let fullDiff: String

    @State private var selectedFile: String?
    @AppStorage(UserDefaultsKeys.diffViewMode) private var diffMode: String = "unified"
    @Environment(\.appTheme) private var theme

    private var visibleDiff: String {
        guard let selected = selectedFile else { return fullDiff }
        return filterDiff(fullDiff, forFile: selected)
    }

    var body: some View {
        ZStack {
            PersistentSplitView(
                autosaveName: "ChangesSplit",
                topMinHeight: 80,
                bottomMinHeight: 200,
                defaultTopFraction: 0.25
            ) {
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
                    .background(theme.surface)
                }
            } bottom: {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(theme.accent.opacity(0.6))
                        .frame(height: 3)
                    Group {
                        if diffMode == "sideBySide" {
                            SideBySideDiffView(diffText: visibleDiff)
                        } else {
                            DiffView(diffText: visibleDiff)
                        }
                    }
                }
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
        List {
            Section {
                ForEach(changes) { change in
                    HStack(spacing: 8) {
                        Text(change.status.label)
                            .scaledFont(size: 11, weight: .medium, design: .monospaced)
                            .foregroundStyle(statusColor(change.status, theme: theme))
                            .frame(width: 14, alignment: .center)

                        Text(change.path)
                            .scaledFont(size: 12, design: .monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        HStack(spacing: 6) {
                            if change.insertions > 0 {
                                Text("+\(change.insertions)")
                                    .scaledFont(size: 11, weight: .medium, design: .monospaced)
                                    .foregroundStyle(theme.green)
                            }
                            if change.deletions > 0 {
                                Text("-\(change.deletions)")
                                    .scaledFont(size: 11, weight: .medium, design: .monospaced)
                                    .foregroundStyle(theme.red)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .hoverHighlight(isSelected: selectedFile == change.path)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedFile == change.path {
                            selectedFile = nil
                        } else {
                            selectedFile = change.path
                        }
                    }
                    .contextMenu {
                        Button("Copy File Name") {
                            copyToPasteboard((change.path as NSString).lastPathComponent)
                        }
                        Button("Copy Path") {
                            copyToPasteboard(change.path)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
            } header: {
                HStack {
                    Text("Changed Files (\(changes.count))")
                        .scaledFont(size: 12, weight: .medium)
                    Spacer()
                    Text("+\(changes.reduce(0) { $0 + $1.insertions })")
                        .scaledFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundStyle(theme.green)
                    Text("-\(changes.reduce(0) { $0 + $1.deletions })")
                        .scaledFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundStyle(theme.red)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(theme.surface)
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

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func statusColor(_ status: FileChange.ChangeStatus, theme: AppTheme) -> Color {
        switch status {
        case .added: theme.green
        case .modified: theme.yellow
        case .deleted: theme.red
        case .renamed: theme.blue
        }
    }
}
