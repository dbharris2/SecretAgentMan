import AppKit
import SwiftUI

struct SettingsView: View {
    let shellManager: ShellManager
    let codexMonitor: CodexAppServerMonitor
    let reviewerGroupStore: ReviewerGroupStore

    var body: some View {
        TabView {
            GeneralSettingsView(shellManager: shellManager, codexMonitor: codexMonitor)
                .tabItem { Label("General", systemImage: "gear") }
            ReviewerGroupsSettingsView(store: reviewerGroupStore)
                .tabItem { Label("Reviewers", systemImage: "person.2") }
        }
        .frame(minWidth: 650, idealWidth: 750, maxWidth: .infinity, minHeight: 750, idealHeight: 850, maxHeight: .infinity)
    }
}

struct GeneralSettingsView: View {
    let shellManager: ShellManager
    let codexMonitor: CodexAppServerMonitor

    @AppStorage(UserDefaultsKeys.terminalTheme) private var selectedTheme = "Catppuccin Mocha"
    @AppStorage(UserDefaultsKeys.claudePluginDirectory) private var claudePluginDirectory = ""
    @AppStorage(UserDefaultsKeys.defaultAgentFolder) private var defaultAgentFolder = ""
    @AppStorage(UserDefaultsKeys.codexModel) private var codexModelOverride: String?
    @AppStorage(UserDefaultsKeys.codexApprovalPolicy) private var codexApprovalPolicyOverride: String?
    @AppStorage(UserDefaultsKeys.codexSandboxMode) private var codexSandboxModeOverride: String?
    @AppStorage(UserDefaultsKeys.favoriteThemes) private var favoriteThemesJSON = "[]"
    @AppStorage(UserDefaultsKeys.terminalFontName) private var terminalFontName = ""
    @State private var searchText = ""
    @State private var allThemes: [String] = []
    @State private var installedFontFamilies: [String] = []
    @State private var listSelection: String?

    @State private var codexConfigDefaults = CodexConfigLoader.loadDefaults()

    private var effectiveCodexModelName: String {
        CodexModelSettings.effectiveModel(configDefaults: codexConfigDefaults)
    }

    private var codexPresetModels: [CodexAvailableModel] {
        CodexModelSettings.modelOptions(
            discoveredModels: codexMonitor.availableModels,
            currentModelName: effectiveCodexModelName
        )
    }

    private var effectiveCodexApprovalPolicy: CodexApprovalPolicy {
        if let codexApprovalPolicyOverride,
           let policy = CodexApprovalPolicy(rawValue: codexApprovalPolicyOverride) {
            return policy
        }
        return codexConfigDefaults.approvalPolicy ?? .onRequest
    }

    private var effectiveCodexSandboxMode: CodexSandboxMode {
        if let codexSandboxModeOverride,
           let mode = CodexSandboxMode(rawValue: codexSandboxModeOverride) {
            return mode
        }
        return codexConfigDefaults.sandboxMode ?? .workspaceWrite
    }

    private var codexApprovalPolicySelection: Binding<String> {
        Binding(
            get: { effectiveCodexApprovalPolicy.rawValue },
            set: { codexApprovalPolicyOverride = $0 }
        )
    }

    private var codexModelOverrideSelection: Binding<String> {
        Binding(
            get: { codexModelOverride ?? "" },
            set: { codexModelOverride = CodexModelSettings.normalized($0) }
        )
    }

    private var codexSandboxModeSelection: Binding<String> {
        Binding(
            get: { effectiveCodexSandboxMode.rawValue },
            set: { codexSandboxModeOverride = $0 }
        )
    }

    private var favoriteThemes: Set<String> {
        guard let data = favoriteThemesJSON.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }

    private var filteredThemes: [String] {
        if searchText.isEmpty { return allThemes }
        return allThemes.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var favoriteThemesSorted: [String] {
        let favs = favoriteThemes
        return allThemes.filter { favs.contains($0) }
    }

    private var nonFavoriteThemes: [String] {
        let favs = favoriteThemes
        return allThemes.filter { !favs.contains($0) }
    }

    private var terminalFontStatus: String {
        let requestedName = terminalFontName.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = ShellManager.terminalFont()
        let displayName = font.displayName ?? font.fontName

        guard !requestedName.isEmpty else {
            return "Current: \(displayName)."
        }

        if ShellManager.resolveFont(named: requestedName, size: 13) == nil {
            return "Font not found; using \(displayName)."
        }

        return "Current: \(displayName)."
    }

    private func toggleFavorite(_ theme: String) {
        var favs = favoriteThemes
        if favs.contains(theme) {
            favs.remove(theme)
        } else {
            favs.insert(theme)
        }
        if let data = try? JSONEncoder().encode(Array(favs).sorted()),
           let json = String(data: data, encoding: .utf8) {
            favoriteThemesJSON = json
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
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

                    VStack(alignment: .leading, spacing: Spacing.md) {
                        HStack {
                            TextField("Model ID override", text: codexModelOverrideSelection)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)

                            Menu("Presets") {
                                ForEach(codexPresetModels) { model in
                                    Button(model.displayTitle) {
                                        codexModelOverride = model.model
                                    }
                                }
                            }

                            Button("Use Config Default") {
                                codexModelOverride = nil
                            }
                            .disabled(codexModelOverride == nil)
                        }

                        Text("Active model: \(effectiveCodexModelName)")
                    }

                    VStack(alignment: .leading, spacing: Spacing.md) {
                        HStack {
                            Picker("Approval Policy", selection: codexApprovalPolicySelection) {
                                ForEach(CodexApprovalPolicy.allCases, id: \.rawValue) { policy in
                                    Text(policy.label).tag(policy.rawValue)
                                }
                            }
                            .pickerStyle(.menu)

                            Button("Use Config Default") {
                                codexApprovalPolicyOverride = nil
                            }
                            .disabled(codexApprovalPolicyOverride == nil)
                        }

                        Text(effectiveCodexApprovalPolicy.settingsDescription)
                    }

                    VStack(alignment: .leading, spacing: Spacing.md) {
                        HStack {
                            Picker("Sandbox Mode", selection: codexSandboxModeSelection) {
                                ForEach(CodexSandboxMode.allCases, id: \.rawValue) { mode in
                                    Text(mode.label).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.menu)

                            Button("Use Config Default") {
                                codexSandboxModeOverride = nil
                            }
                            .disabled(codexSandboxModeOverride == nil)
                        }

                        Text(effectiveCodexSandboxMode.settingsDescription)
                    }

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Defaults come from ~/.codex/config.toml when present.")
                        Text("Plugins and MCP servers are discovered from ~/.codex")
                        Text("Selections here become app-specific overrides for new Codex turns and future session starts.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()

                Section {
                    Text("Terminal Font")
                        .font(.headline)

                    HStack {
                        TextField("Font family or PostScript name", text: $terminalFontName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)

                        Menu("Installed Fonts") {
                            ForEach(installedFontFamilies, id: \.self) { family in
                                Button(family) {
                                    terminalFontName = family
                                }
                            }
                        }

                        Button("Use Default") {
                            terminalFontName = ""
                        }
                        .disabled(terminalFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text(terminalFontStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("App Theme")
                    .font(.headline)

                HStack(spacing: Spacing.xxl) {
                    ThemePreviewLarge(themeName: selectedTheme)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(selectedTheme)
                            .scaledFont(size: 14, weight: .semibold)
                        Text("Current theme")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(Spacing.xl)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                TextField("Search themes...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                List(selection: $listSelection) {
                    if searchText.isEmpty, !favoriteThemesSorted.isEmpty {
                        Section("Favorites") {
                            ForEach(favoriteThemesSorted, id: \.self) { theme in
                                themeRow(theme).tag(theme)
                            }
                        }
                        Section("All Themes") {
                            ForEach(nonFavoriteThemes, id: \.self) { theme in
                                themeRow(theme).tag(theme)
                            }
                        }
                    } else {
                        ForEach(filteredThemes, id: \.self) { theme in
                            themeRow(theme).tag(theme)
                        }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(height: 320)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: listSelection) {
            if let theme = listSelection {
                selectedTheme = theme
            }
        }
        .onChange(of: selectedTheme) {
            shellManager.themeName = selectedTheme
        }
        .onChange(of: terminalFontName) {
            shellManager.applyFontToAll()
        }
        .onAppear {
            allThemes = GhosttyThemeLoader.availableThemes()
            installedFontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
            listSelection = selectedTheme
            shellManager.themeName = selectedTheme
            codexConfigDefaults = CodexConfigLoader.loadDefaults()
            codexMonitor.refreshAvailableModels()
        }
    }

    private func themeRow(_ theme: String) -> some View {
        let isFavorite = favoriteThemes.contains(theme)
        return HStack {
            ThemePreview(themeName: theme)
            Text(theme)
            Spacer()
            if theme == selectedTheme {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
            }
            Button {
                toggleFavorite(theme)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.vertical, 1)
    }
}

struct ThemePreviewLarge: View {
    let themeName: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
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

    var body: some View {
        HSplitView {
            // Group list
            VStack(alignment: .leading, spacing: 0) {
                List(store.groups, selection: $selectedGroupId) { group in
                    Text(group.name)
                }
                .listStyle(.inset)

                Divider()

                HStack(spacing: Spacing.sm) {
                    Button(action: addGroup) {
                        Image(systemName: "plus")
                    }
                    Button(action: removeSelectedGroup) {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedGroupId == nil)
                }
                .padding(Spacing.md)
            }
            .frame(minWidth: 160, idealWidth: 320, maxWidth: 400)

            // Group detail
            if let index = store.groups.firstIndex(where: { $0.id == selectedGroupId }) {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
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
                .padding(Spacing.xxl)
                .frame(minWidth: 320, idealWidth: 360, maxWidth: .infinity)
            } else {
                VStack {
                    Spacer()
                    Text("Select or create a reviewer group")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: .infinity)
            }
        }
        .padding(Spacing.xxl)
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
