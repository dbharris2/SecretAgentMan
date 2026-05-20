import AppKit
import SwiftUI

struct DiffScrollRequest: Equatable {
    let path: String
    let token: UUID
}

struct ChangesView: View {
    let changes: [FileChange]
    let fullDiff: String

    @State private var selectedFile: String?
    @State private var scrollRequest: DiffScrollRequest?
    @AppStorage(UserDefaultsKeys.diffViewMode) private var diffMode: String = "unified"
    @Environment(\.appTheme) private var theme

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
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm)
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
                            SideBySideDiffView(diffText: fullDiff, scrollRequest: scrollRequest)
                        } else {
                            DiffView(diffText: fullDiff, scrollRequest: scrollRequest)
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
        .onChange(of: changes) { _, newChanges in
            if let selected = selectedFile, !newChanges.contains(where: { $0.path == selected }) {
                selectedFile = nil
            }
        }
    }

    private var fileList: some View {
        List {
            Section {
                ForEach(changes) { change in
                    HStack(spacing: Spacing.lg) {
                        Text(change.status.label)
                            .scaledFont(size: 11, weight: .medium, design: .monospaced)
                            .foregroundStyle(statusColor(change.status, theme: theme))
                            .frame(width: 14, alignment: .center)

                        Text(change.path)
                            .scaledFont(size: 12, design: .monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        HStack(spacing: Spacing.md) {
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
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, 3)
                    .hoverHighlight(isSelected: selectedFile == change.path, cornerRadius: 0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedFile = change.path
                        scrollRequest = DiffScrollRequest(path: change.path, token: UUID())
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
                    .listRowInsets(EdgeInsets())
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
