enum AgentState: String, Hashable, Codable {
    case idle
    case active
    case needsPermission
    case awaitingInput
    case awaitingResponse
    case finished
    case error
}
