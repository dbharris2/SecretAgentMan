import AppKit
import SwiftUI

/// Toolbar split button: left half opens the agent's folder in the last-used
/// editor; right half (chevron) opens a menu to pick a different editor.
/// Mirrors the pattern used in the Codex desktop app.
struct OpenInEditorButton: View {
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage(UserDefaultsKeys.preferredEditor) private var preferredEditorId = "com.microsoft.VSCode"

    private var installedEditors: [EditorApp] {
        EditorLauncher.installedEditors()
    }

    private var currentEditor: EditorApp? {
        installedEditors.first { $0.bundleId == preferredEditorId } ?? installedEditors.first
    }

    private var selectedFolder: URL? {
        coordinator.store.selectedAgent?.folder
    }

    var body: some View {
        Menu {
            ForEach(installedEditors) { editor in
                Button {
                    select(editor)
                } label: {
                    if let icon = EditorLauncher.icon(for: editor) {
                        Label {
                            Text(editor.displayName)
                        } icon: {
                            Image(nsImage: icon)
                        }
                    } else {
                        Text(editor.displayName)
                    }
                }
            }
        } label: {
            if let editor = currentEditor, let icon = EditorLauncher.icon(for: editor) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.badge")
                    .scaledFont(size: 14)
            }
        } primaryAction: {
            openInCurrentEditor()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(selectedFolder == nil || installedEditors.isEmpty)
        .help(helpText)
    }

    private var helpText: String {
        if selectedFolder == nil {
            return "Select an agent to open its folder"
        }
        if let editor = currentEditor {
            return "Open in \(editor.displayName) — click chevron to choose a different editor"
        }
        return "Open folder in editor"
    }

    private func openInCurrentEditor() {
        guard let folder = selectedFolder, let editor = currentEditor else { return }
        EditorLauncher.open(folder: folder, in: editor)
    }

    private func select(_ editor: EditorApp) {
        preferredEditorId = editor.bundleId
        guard let folder = selectedFolder else { return }
        EditorLauncher.open(folder: folder, in: editor)
    }
}
