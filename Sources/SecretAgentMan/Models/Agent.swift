import Foundation

struct Agent: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var folder: URL
    var state: AgentState
    var sessionId: String?
    var pid: Int32?
    var initialPrompt: String?
    var createdAt: Date

    var folderName: String {
        folder.lastPathComponent
    }

    var folderPath: String {
        folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    init(
        id: UUID = UUID(),
        name: String,
        folder: URL,
        state: AgentState = .idle,
        sessionId: String? = nil,
        pid: Int32? = nil,
        initialPrompt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.state = state
        self.sessionId = sessionId
        self.pid = pid
        self.initialPrompt = initialPrompt
        self.createdAt = createdAt
    }
}
