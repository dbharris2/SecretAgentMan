import Foundation

enum SessionRunState: Equatable {
    case idle
    case running
    case needsPermission
    case needsInput
    case finished
    case error(message: String?)
}

enum TranscriptItemKind: Equatable {
    case userMessage
    case assistantMessage
    case systemMessage
    case toolActivity
    case plan
    case diffSummary
    case error
    /// Provider-emitted reasoning or "thinking" content. Views group these
    /// alongside system/tool/plan items rather than the primary assistant stream.
    case thought
}

struct TranscriptItemMetadata: Equatable {
    let toolName: String?
    let displayTitle: String?
    /// Debug-only. View and reducer logic must not branch on this value.
    let providerItemType: String?

    init(
        toolName: String? = nil,
        displayTitle: String? = nil,
        providerItemType: String? = nil
    ) {
        self.toolName = toolName
        self.displayTitle = displayTitle
        self.providerItemType = providerItemType
    }
}

struct SessionTranscriptItem: Identifiable, Equatable {
    let id: String
    let kind: TranscriptItemKind
    let text: String
    let isStreaming: Bool
    let createdAt: Date?
    let imageData: [Data]
    let metadata: TranscriptItemMetadata?

    init(
        id: String,
        kind: TranscriptItemKind,
        text: String,
        isStreaming: Bool = false,
        createdAt: Date? = nil,
        imageData: [Data] = [],
        metadata: TranscriptItemMetadata? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.imageData = imageData
        self.metadata = metadata
    }
}

struct PromptOption: Equatable, Identifiable {
    let label: String
    let description: String?

    var id: String {
        label
    }

    init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// Legal combinations:
///   options empty + allowsOther true  → free-form text input
///   options non-empty + allowsOther false → multiple choice
///   options non-empty + allowsOther true  → multiple choice with free-form escape hatch
/// options empty + allowsOther false is invalid; monitors must not emit this shape.
struct PromptQuestion: Equatable, Identifiable {
    let id: String
    let header: String
    let question: String
    let allowsOther: Bool
    let options: [PromptOption]
}

enum ApprovalActionKind: String, Equatable {
    case allowOnce
    case allowAlways
    case rejectOnce
    case rejectAlways
}

struct ApprovalAction: Equatable, Identifiable {
    let id: String
    let label: String
    let kind: ApprovalActionKind?
    let isDestructive: Bool

    init(id: String, label: String, kind: ApprovalActionKind? = nil, isDestructive: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.isDestructive = isDestructive
    }
}

struct ApprovalPrompt: Equatable, Identifiable {
    let id: String
    let title: String
    let message: String
    let actions: [ApprovalAction]

    /// True when the prompt offers real approve/decline choices. False for
    /// dismiss-only prompts (e.g. Codex `unsupportedPermissions`) where the UI
    /// can only acknowledge the request.
    var supportsDecisions: Bool {
        actions.count > 1
    }
}

struct UserInputPrompt: Equatable, Identifiable {
    let id: String
    let title: String
    let message: String
    let questions: [PromptQuestion]
}

enum SessionPromptRequest: Equatable, Identifiable {
    case approval(ApprovalPrompt)
    case userInput(UserInputPrompt)

    var id: String {
        switch self {
        case let .approval(prompt): prompt.id
        case let .userInput(prompt): prompt.id
        }
    }
}

struct SessionSlashCommand: Equatable {
    let name: String
    let description: String

    init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }
}

struct SessionModeInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?

    init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

struct SessionModelInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?

    init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

enum SessionStopReason: Equatable {
    case endTurn
    case maxTokens
    case maxTurnRequests
    case refusal
    case cancelled
    /// Unknown stop reason from a future ACP revision. Reducer treats this
    /// as end-of-turn idle so a new stopReason addition doesn't wedge sessions.
    case unknown(String)
}

struct SessionTurnCompletion: Equatable {
    let stopReason: SessionStopReason
}

struct SessionMetadataSnapshot: Equatable {
    var sessionId: String?
    var displayModelName: String?
    var rawModelName: String?
    var contextPercentUsed: Double?
    var permissionMode: String?
    var collaborationMode: String?
    var activeToolName: String?
    var slashCommands: [SessionSlashCommand]?
    var availableModes: [SessionModeInfo]?
    var currentModeId: String?
    var availableModels: [SessionModelInfo]?
    var currentModelId: String?
}

enum MetadataFieldUpdate<Value: Equatable>: Equatable {
    case unchanged
    case set(Value)
    case clear
}

struct SessionMetadataUpdate: Equatable {
    var displayModelName: MetadataFieldUpdate<String> = .unchanged
    var rawModelName: MetadataFieldUpdate<String> = .unchanged
    var contextPercentUsed: MetadataFieldUpdate<Double> = .unchanged
    var permissionMode: MetadataFieldUpdate<String> = .unchanged
    var collaborationMode: MetadataFieldUpdate<String> = .unchanged
    var activeToolName: MetadataFieldUpdate<String> = .unchanged
    var slashCommands: MetadataFieldUpdate<[SessionSlashCommand]> = .unchanged
    var availableModes: MetadataFieldUpdate<[SessionModeInfo]> = .unchanged
    var currentModeId: MetadataFieldUpdate<String> = .unchanged
    var availableModels: MetadataFieldUpdate<[SessionModelInfo]> = .unchanged
    var currentModelId: MetadataFieldUpdate<String> = .unchanged
}

/// Monitors emit these; the reducer consumes them.
/// Ordering contract:
///   - `transcriptDelta` requires a prior `transcriptUpsert` with `isStreaming = true` for the same id.
///     The reducer drops deltas for unknown ids in release and asserts in debug.
///   - `transcriptFinished` is the authoritative way to flip `isStreaming` to false.
///   - A second `sessionReady` with a different sessionId is a session-replacement event.
///     Same sessionId is a no-op.
///   - `turnCompleted` is the authoritative end-of-turn signal for providers that
///     emit one. Monitors must emit all final `transcriptFinished`, tool-state,
///     prompt-resolution, and metadata events first, then emit `turnCompleted`
///     last. It does not replace `transcriptFinished`.
enum SessionEvent: Equatable {
    case sessionReady(sessionId: String)
    case runStateChanged(SessionRunState)
    case transcriptUpsert(SessionTranscriptItem)
    case transcriptDelta(id: String, appendedText: String)
    case transcriptFinished(id: String)
    case promptPresented(SessionPromptRequest)
    case promptResolved(id: String)
    case metadataUpdated(SessionMetadataUpdate)
    case turnCompleted(SessionTurnCompletion)
}

struct AgentSessionSnapshot: Equatable {
    var runState: SessionRunState = .idle
    var transcript: [SessionTranscriptItem] = []
    var activePrompt: SessionPromptRequest?
    var queuedPrompts: [SessionPromptRequest] = []
    var metadata: SessionMetadataSnapshot = .init()
    var hasUnread: Bool = false
}

extension AgentSessionSnapshot {
    /// Text of the most recent still-streaming assistant message, if any.
    /// Views render this separately from `finalizedTranscript` as a live bubble.
    /// Filters to `.assistantMessage` specifically so streaming `.thought`
    /// content doesn't get promoted into the primary live-response bubble.
    var streamingAssistantText: String? {
        transcript.last { $0.isStreaming && $0.kind == .assistantMessage }?.text
    }

    /// Transcript items excluding any still-streaming placeholder.
    /// Pair with `streamingAssistantText` to avoid rendering the same item twice.
    var finalizedTranscript: [SessionTranscriptItem] {
        transcript.filter { !$0.isStreaming }
    }

    /// The active approval prompt, or nil if the active prompt is a user-input
    /// request (or no prompt is active).
    var approvalPrompt: ApprovalPrompt? {
        if case let .approval(prompt) = activePrompt { return prompt }
        return nil
    }

    /// The active user-input prompt, or nil if the active prompt is an approval
    /// (or no prompt is active).
    var userInputPrompt: UserInputPrompt? {
        if case let .userInput(prompt) = activePrompt { return prompt }
        return nil
    }
}
