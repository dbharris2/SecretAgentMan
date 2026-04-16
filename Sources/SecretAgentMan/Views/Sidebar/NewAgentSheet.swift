import SwiftUI

struct NewAgentSheet: View {
    let store: AgentStore
    @Binding var isPresented: Bool
    @Binding var prefillFolder: URL?

    @AppStorage(UserDefaultsKeys.defaultAgentFolder) private var defaultAgentFolder = ""
    @State private var name = ""
    @State private var selectedFolder: URL?
    @State private var selectedProvider: AgentProvider = .claude
    @State private var initialPrompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Agent")
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Provider", selection: $selectedProvider) {
                ForEach(AgentProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text(selectedFolder?.path ?? "No folder selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Choose...") {
                    chooseFolder()
                }
            }

            TextField("Initial prompt (optional)", text: $initialPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3 ... 5)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    createAgent()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || selectedFolder == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if let folder = prefillFolder {
                selectedFolder = folder
                if name.isEmpty {
                    name = folder.lastPathComponent
                }
            } else if !defaultAgentFolder.isEmpty {
                let url = URL(fileURLWithPath: defaultAgentFolder)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    selectedFolder = url
                    if name.isEmpty {
                        name = url.lastPathComponent
                    }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder for the agent"

        if panel.runModal() == .OK {
            selectedFolder = panel.url
            if name.isEmpty, let folder = panel.url {
                name = folder.lastPathComponent
            }
        }
    }

    private func createAgent() {
        guard let folder = selectedFolder else { return }
        _ = store.addAgent(
            name: name,
            folder: folder,
            provider: selectedProvider,
            initialPrompt: initialPrompt.isEmpty ? nil : initialPrompt
        )
        isPresented = false
    }
}
