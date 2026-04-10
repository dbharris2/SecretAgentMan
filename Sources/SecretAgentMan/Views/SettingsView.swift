import SwiftUI

struct SettingsView: View {
    let terminalManager: TerminalManager
    let shellManager: ShellManager
    let reviewerGroupStore: ReviewerGroupStore

    var body: some View {
        TabView {
            GeneralSettingsView(terminalManager: terminalManager, shellManager: shellManager)
                .tabItem { Label("General", systemImage: "gear") }
            ReviewerGroupsSettingsView(store: reviewerGroupStore)
                .tabItem { Label("Reviewers", systemImage: "person.2") }
        }
        .frame(width: 550, height: 650)
    }
}

struct GeneralSettingsView: View {
    let terminalManager: TerminalManager
    let shellManager: ShellManager

    @AppStorage(UserDefaultsKeys.terminalTheme) private var selectedTheme = "Catppuccin Mocha"
    @AppStorage(UserDefaultsKeys.claudePluginDirectory) private var claudePluginDirectory = ""
    @AppStorage(UserDefaultsKeys.defaultAgentFolder) private var defaultAgentFolder = ""
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
                Text("Default Agent Folder")
                    .font(.headline)

                HStack {
                    TextField("Default folder path", text: $defaultAgentFolder)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            defaultAgentFolder = url.path
                        }
                    }
                }

                Text("Pre-filled when creating new agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Section {
                Text("Claude Plugins")
                    .font(.headline)

                HStack {
                    TextField("Plugin directory path", text: $claudePluginDirectory)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            claudePluginDirectory = url.path
                        }
                    }
                }

                Text("Passed as --plugin-dir to new Claude sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Section {
                Text("Codex")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Configuration is read from ~/.codex/config.toml")
                    Text("Plugins and MCP servers are discovered from ~/.codex")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            Text("App Theme")
                .font(.headline)

            HStack(spacing: 12) {
                ThemePreviewLarge(themeName: selectedTheme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTheme)
                        .scaledFont(size: 14, weight: .semibold)
                    Text("Current theme")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08))
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

struct ReviewerGroupsSettingsView: View {
    @Bindable var store: ReviewerGroupStore
    @State private var selectedGroupId: UUID?
    @State private var newReviewerText = ""

    private var selectedGroup: ReviewerGroup? {
        store.groups.first { $0.id == selectedGroupId }
    }

    var body: some View {
        HSplitView {
            // Group list
            VStack(alignment: .leading, spacing: 0) {
                List(store.groups, selection: $selectedGroupId) { group in
                    Text(group.name)
                }
                .listStyle(.inset)

                Divider()

                HStack(spacing: 4) {
                    Button(action: addGroup) {
                        Image(systemName: "plus")
                    }
                    Button(action: removeSelectedGroup) {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedGroupId == nil)
                }
                .padding(6)
            }
            .frame(minWidth: 140, idealWidth: 160)

            // Group detail
            if let index = store.groups.firstIndex(where: { $0.id == selectedGroupId }) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Group Name", text: $store.groups[index].name)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .onChange(of: store.groups[index].name) { store.save() }

                    Text("Reviewers")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    List {
                        ForEach(store.groups[index].reviewers, id: \.self) { reviewer in
                            HStack {
                                Text(reviewer)
                                Spacer()
                                Button {
                                    store.groups[index].reviewers.removeAll { $0 == reviewer }
                                    store.save()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.inset)

                    HStack {
                        TextField("GitHub username", text: $newReviewerText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addReviewer(at: index) }
                        Button("Add") { addReviewer(at: index) }
                            .disabled(newReviewerText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
            } else {
                VStack {
                    Spacer()
                    Text("Select or create a reviewer group")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
    }

    private func addGroup() {
        let group = ReviewerGroup(name: "New Group")
        store.groups.append(group)
        selectedGroupId = group.id
        store.save()
    }

    private func removeSelectedGroup() {
        guard let id = selectedGroupId else { return }
        store.groups.removeAll { $0.id == id }
        selectedGroupId = store.groups.first?.id
        store.save()
    }

    private func addReviewer(at index: Int) {
        let username = newReviewerText.trimmingCharacters(in: .whitespaces)
        guard !username.isEmpty, !store.groups[index].reviewers.contains(username) else { return }
        store.groups[index].reviewers.append(username)
        newReviewerText = ""
        store.save()
    }
}
