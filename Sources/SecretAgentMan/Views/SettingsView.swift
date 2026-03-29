import SwiftUI

struct SettingsView: View {
    let terminalManager: TerminalManager
    let shellManager: ShellManager

    @AppStorage("terminalTheme") private var selectedTheme = "Catppuccin Mocha"
    @AppStorage("pluginDirectory") private var pluginDirectory = ""
    @State private var searchText = ""
    @State private var allThemes: [String] = []
    @State private var listSelection: String?

    private var filteredThemes: [String] {
        if searchText.isEmpty { return allThemes }
        return allThemes.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Section {
                Text("Claude Plugins")
                    .font(.headline)

                HStack {
                    TextField("Plugin directory path", text: $pluginDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            pluginDirectory = url.path
                        }
                    }
                }

                Text("Passed as --plugin-dir to new Claude sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Terminal Theme")
                .font(.headline)

            HStack(spacing: 12) {
                ThemePreviewLarge(themeName: selectedTheme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTheme)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Current theme")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            TextField("Search themes...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(filteredThemes, id: \.self, selection: $listSelection) { theme in
                themeRow(theme)
                    .tag(theme)
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
        .frame(width: 450, height: 500)
        .onChange(of: listSelection) {
            if let theme = listSelection {
                selectedTheme = theme
            }
        }
        .onChange(of: selectedTheme) {
            terminalManager.themeName = selectedTheme
            shellManager.themeName = selectedTheme
        }
        .onAppear {
            allThemes = GhosttyThemeLoader.availableThemes()
            listSelection = selectedTheme
            terminalManager.themeName = selectedTheme
        }
    }

    private func themeRow(_ theme: String) -> some View {
        HStack {
            ThemePreview(themeName: theme)
            Text(theme)
            Spacer()
            if theme == selectedTheme {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 1)
    }
}

struct ThemePreviewLarge: View {
    let themeName: String

    var body: some View {
        HStack(spacing: 2) {
            if let theme = GhosttyThemeLoader.load(named: themeName) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: theme.background))
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                    )
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: theme.foreground))
                    .frame(width: 28, height: 28)
                ForEach([1, 2, 3, 4, 5, 6], id: \.self) { idx in
                    if let color = theme.palette[idx] {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: color))
                            .frame(width: 28, height: 28)
                    }
                }
            }
        }
    }
}

struct ThemePreview: View {
    let themeName: String

    var body: some View {
        HStack(spacing: 1) {
            if let theme = GhosttyThemeLoader.load(named: themeName) {
                colorSwatch(theme.background, bordered: true)
                colorSwatch(theme.foreground)
                ForEach([1, 2, 4, 5], id: \.self) { idx in
                    if let color = theme.palette[idx] {
                        colorSwatch(color)
                    }
                }
            }
        }
    }

    private func colorSwatch(_ color: NSColor, bordered: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(nsColor: color))
            .frame(width: 14, height: 14)
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                }
            }
    }
}
