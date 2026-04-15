import AppKit
import Foundation

/// Known editor/terminal/file-browser apps that can open a project folder.
struct EditorApp: Identifiable, Hashable {
    let bundleId: String
    let displayName: String

    var id: String {
        bundleId
    }
}

enum EditorLauncher {
    /// Curated list of common editors, terminals, and file browsers on macOS.
    /// Ordering here defines the order in the picker menu.
    static let knownEditors: [EditorApp] = [
        .init(bundleId: "com.microsoft.VSCode", displayName: "VS Code"),
        .init(bundleId: "com.todesktop.230313mzl4w4u92", displayName: "Cursor"),
        .init(bundleId: "dev.zed.Zed", displayName: "Zed"),
        .init(bundleId: "com.google.Antigravity", displayName: "Antigravity"),
        .init(bundleId: "com.sublimetext.4", displayName: "Sublime Text"),
        .init(bundleId: "com.panic.Nova", displayName: "Nova"),
        .init(bundleId: "com.jetbrains.intellij", displayName: "IntelliJ IDEA"),
        .init(bundleId: "com.jetbrains.pycharm", displayName: "PyCharm"),
        .init(bundleId: "com.google.android.studio", displayName: "Android Studio"),
        .init(bundleId: "com.apple.dt.Xcode", displayName: "Xcode"),
        .init(bundleId: "com.apple.finder", displayName: "Finder"),
        .init(bundleId: "com.apple.Terminal", displayName: "Terminal"),
        .init(bundleId: "com.mitchellh.ghostty", displayName: "Ghostty"),
        .init(bundleId: "com.googlecode.iterm2", displayName: "iTerm"),
        .init(bundleId: "dev.warp.Warp-Stable", displayName: "Warp"),
    ]

    /// Subset of `knownEditors` that are actually installed on this machine.
    /// Finder and Terminal are system apps and effectively always present.
    static func installedEditors() -> [EditorApp] {
        knownEditors.filter { applicationURL(for: $0) != nil }
    }

    static func applicationURL(for editor: EditorApp) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleId)
    }

    static func icon(for editor: EditorApp) -> NSImage? {
        guard let appURL = applicationURL(for: editor) else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    /// Opens `folder` in `editor`. Does nothing if the app can't be resolved.
    static func open(folder: URL, in editor: EditorApp) {
        guard let appURL = applicationURL(for: editor) else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: config)
    }
}
