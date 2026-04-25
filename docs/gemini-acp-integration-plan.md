# Gemini CLI ACP Integration Plan

## Summary

Add Gemini as a third native agent provider using `gemini --acp` and ACP JSON-RPC over stdio. The work is feasible and is a medium lift: SecretAgentMan already has the shared provider/session architecture and normalized `SessionEvent` model needed for Gemini, but ACP still needs a new process monitor, typed protocol layer, exact permission-option UI, and provider wiring.

The ACP integration shape is most similar to Codex app-server because both are long-lived stdio JSON-RPC processes with request IDs, notifications, and streamed session events. It is less like Claude stream-json, which is mostly JSONL event parsing around one provider-specific prompt process. Gemini's underlying model API is separate from both Claude and Codex, but ACP hides most of that behind a provider-neutral client protocol.

V1 will reuse Gemini CLI authentication, Gemini's own tool execution, and the existing native chat experience. It will not implement ACP file-system or terminal proxy capabilities.

## Protocol Facts To Pin

- Gemini CLI `0.38.2` ACP mode uses JSON-RPC 2.0 over stdio with newline-delimited JSON via the bundled ACP SDK `ndJsonStream`, not LSP-style `Content-Length` framing.
- `initialize` uses protocol version `1`. SecretAgentMan should advertise `clientCapabilities` with `auth.terminal: false`, `fs.readTextFile: false`, `fs.writeTextFile: false`, and `terminal: false`.
- `messageId` on `session/prompt` is optional in ACP. SecretAgentMan should send a UUID for local user-message reconciliation and treat the response `userMessageId` as advisory, not required.
- `session/load` is optional. SecretAgentMan must check `agentCapabilities.loadSession` from `initialize` before calling it.
- `session/cancel` is a notification, not a request. Interrupt handling must be fire-and-forget and then wait for the in-flight `session/prompt` response with `stopReason: "cancelled"`.
- ACP `StopReason` values in the public schema and the local Gemini CLI bundle are `end_turn`, `max_tokens`, `max_turn_requests`, `refusal`, and `cancelled`.
- ACP references to verify during implementation:
  - https://agentclientprotocol.com/protocol/overview
  - https://agentclientprotocol.com/protocol/initialization
  - https://agentclientprotocol.com/protocol/session-setup
  - https://agentclientprotocol.com/protocol/schema
  - local Gemini CLI `0.38.2` bundle docs at `/opt/homebrew/Cellar/gemini-cli/0.38.2/libexec/lib/node_modules/@google/gemini-cli/bundle/docs/cli/acp-mode.md`

## Key Changes

- Add `.gemini` to the provider model and app wiring:
  - display metadata, icon/color, and executable name `gemini`
  - sidebar/provider selection support
  - session coordinator monitor ownership, start, send, interrupt, permission response, mode, and model routing
  - Gemini session IDs stored only after ACP returns them, matching Codex rather than Claude pre-minting
- Add a new `GeminiAcpMonitor` plus typed `GeminiAcpProtocol` models for:
  - `initialize` with protocol version `1`, `clientInfo`, and capabilities `{ auth.terminal: false, fs: false, terminal: false }`
  - `session/new`, `session/load`, `session/prompt`, `session/set_mode`, and `session/set_model` requests
  - `session/cancel` notification
  - incoming `session/update` notifications
  - incoming `session/request_permission` requests
  - JSON-RPC request, response, error, and notification envelopes
- Launch `gemini --acp` and communicate with newline-delimited JSON-RPC over stdin/stdout, following the same pending-request pattern used by the Codex app-server monitor.
- Reuse the Codex observer/process-supervision pattern for spawn, process exit, stderr capture, pending-request failure, and restart-on-next-ensure behavior. A mid-stream Gemini crash should emit normalized error state and a system transcript item, clear active prompts, and reject pending JSON-RPC requests.
- Create Gemini sessions with `{ cwd, mcpServers: [] }`.
- Load stored Gemini sessions with `{ sessionId, cwd, mcpServers: [] }` only when `initialize` advertises `agentCapabilities.loadSession == true`; otherwise create a new session, replace the stale stored session ID, and emit a system transcript item explaining that Gemini did not support loading the prior session.
- Map ACP updates into normalized session events:
  - `agent_message_chunk` -> streamed assistant transcript
  - `user_message_chunk` -> loaded-history user transcript
  - `tool_call` and `tool_call_update` -> tool activity cards and active tool state
  - `agent_thought_chunk` -> a new grouped `thought` transcript kind for explicit provider thought/explanation updates
  - `plan` -> grouped `plan` transcript items
  - `available_commands_update` -> slash command metadata
  - mode and model updates -> provider-neutral mode/model metadata
- Add an explicit normalized turn-completion signal rather than introducing a Gemini-specific runtime-state dictionary. The Gemini monitor should emit it from the `session/prompt` response `stopReason` after finalizing any still-open stream item. For a prompt turn, `turnCompleted` is the only turn-end transition; the monitor must not also emit `runStateChanged(.idle)` for the same completion.
- Extend shared session metadata with parallel dynamic mode and model state instead of overloading Claude's `permissionMode` or Codex's `collaborationMode` strings:
  - available modes with ID, display name, and optional description
  - current mode ID
  - available models with ID, display name, and optional description
  - current model ID
- Generalize approval prompts with typed actions as a real cross-provider refactor, not a Gemini-only detail. Claude and Codex approval mappers and all approval-card views must keep their existing visible behavior while mapping into the new action shape.
- Render Gemini ACP permission options exactly as provided, including `allow_once`, `allow_always`, `reject_once`, and `reject_always`, and return the selected ACP `optionId`.
- Add `GeminiSessionPanelView` using the existing Codex-style native chat layout, composer, transcript, image attachments, mode/model pills, slash-command suggestions, interrupt button, and permission cards.
- For auth failures, show a clear session error telling the user to authenticate Gemini CLI in a terminal. Do not build in-app OAuth or API-key setup in v1.

## Interfaces

The Gemini monitor should emit only provider-neutral app events after parsing ACP. Gemini-specific protocol details should stay inside the new monitor/protocol layer.

Conceptual protocol surface:

```swift
struct GeminiAcpInitializeParams: Encodable {
    let protocolVersion: Int
    let clientInfo: GeminiAcpClientInfo
    let clientCapabilities: GeminiAcpClientCapabilities
}

struct GeminiAcpNewSessionParams: Encodable {
    let cwd: String
    let mcpServers: [GeminiAcpMCPServer]
}

struct GeminiAcpLoadSessionParams: Encodable {
    let sessionId: String
    let cwd: String
    let mcpServers: [GeminiAcpMCPServer]
}

struct GeminiAcpPromptParams: Encodable {
    let sessionId: String
    let prompt: [GeminiAcpContentBlock]
    let messageId: String?
}

enum GeminiAcpSessionUpdate {
    case userMessageChunk(GeminiAcpMessageChunk)
    case agentMessageChunk(GeminiAcpMessageChunk)
    case agentThoughtChunk(GeminiAcpMessageChunk)
    case toolCall(GeminiAcpToolCall)
    case toolCallUpdate(GeminiAcpToolCall)
    case plan(GeminiAcpPlan)
    case availableCommandsUpdate([GeminiAcpCommand])
    case currentModeUpdate(GeminiAcpModeState)
    case configOptionUpdate(GeminiAcpConfigOption)
    case sessionInfoUpdate(GeminiAcpSessionInfo)
    case usageUpdate(GeminiAcpUsage)
    case unknown(type: String)
}
```

Shared contract additions:

```swift
struct ApprovalAction: Equatable, Identifiable {
    let id: String
    let label: String
    let kind: ApprovalActionKind?
    let isDestructive: Bool
}

enum ApprovalActionKind: String, Equatable {
    case allowOnce
    case allowAlways
    case rejectOnce
    case rejectAlways
}

struct SessionModeInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
}

struct SessionModelInfo: Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
}

enum SessionStopReason: Equatable {
    case endTurn
    case maxTokens
    case maxTurnRequests
    case refusal
    case cancelled
    case unknown(String)
}

struct SessionTurnCompletion: Equatable {
    let stopReason: SessionStopReason
}
```

Expected session coordinator additions:

- Ensure Gemini sessions by starting `gemini --acp`, running `initialize`, then either capability-gated `session/load` or `session/new`.
- Send user text and image attachments through `session/prompt`.
- Reply to ACP permission requests with the exact selected option ID.
- Interrupt in-flight work by sending a `session/cancel` notification and waiting for the pending prompt response to report cancellation.
- Update Gemini mode/model through `session/set_mode` and `session/set_model`.

Reducer and UI semantics:

- Add `TranscriptItemKind.thought` and group it in `SessionChatView` with system/tool/plan items so Gemini reasoning/explanations never render as assistant-visible prose. Do not retro-map existing Claude or Codex transcript behavior in this PR; the new kind is provider-neutral for future explicit thought streams, but Gemini is the only v1 producer.
- Add `SessionEvent.turnCompleted(SessionTurnCompletion)`. It should not replace `transcriptFinished`; monitors still finish known streaming transcript IDs explicitly, and `turnCompleted` represents the provider turn boundary and stop reason.
- `turnCompleted` ordering is strict: monitor emits all final `transcriptFinished`, tool, prompt-resolution, and metadata events first, then emits `turnCompleted` last. The reducer maps `turnCompleted(.endTurn)`, `.maxTokens`, `.maxTurnRequests`, and `.cancelled` to idle, and `.refusal` to an error/system-visible terminal for that prompt. Coordinator terminal/process `.idle` events are suppressed while a prompt response is in flight for that agent.
- Add `availableModes/currentModeId` and `availableModels/currentModelId` fields to `SessionMetadataSnapshot` and matching `SessionMetadataUpdate` fields. Existing `permissionMode` and `collaborationMode` remain for Claude/Codex compatibility.
- Replace `ApprovalPrompt.options: [String]` with `ApprovalPrompt.actions: [ApprovalAction]` in one coordinated refactor. Update Claude and Codex approval mappers, reducer tests, replay tests, parity tests, and approval-card views in the same PR so there is no dual-field compatibility window.
- Keep local user-message reconciliation provider-local. Gemini should mirror Codex's pending-local-message pattern inside `GeminiAcpMonitor`; ACP `messageId` and prompt-response `userMessageId` must not appear in `SessionTurnCompletion` or the shared reducer contract.

## Out Of Scope For V1

- ACP `fs/read_text_file`, `fs/write_text_file`, and `terminal/*` proxy support.
- In-app Gemini login or API-key management.
- Gemini session picker from `session/list` or `gemini --list-sessions`.
- Account-level rate-limit UI from ACP `usage_update`.
- Reworking Claude or Codex protocol behavior beyond the minimum shared metadata, turn-completion, transcript-kind, and approval-action generalization needed for Gemini.

## Test Plan

- Add protocol parsing tests for ACP initialize/session responses, session updates, permission requests, mode/model updates, and unknown update types.
- Add monitor mapping tests with fake JSON-RPC streams for:
  - new session readiness and stored session ID update
  - streamed assistant response finalization
  - loaded user/assistant history
  - tool call lifecycle and active tool clearing
  - exact permission option display and response payload
  - auth-required/error handling
  - fire-and-forget cancellation via `session/cancel` notification and final `stopReason: "cancelled"` handling
  - `loadSession` capability false fallback to a new session
  - `agent_thought_chunk` grouping as `thought`, not assistant text
  - process start failure, stderr capture, mid-stream crash, pending request rejection, prompt cleanup, and restart-on-next-ensure
- Add coordinator/provider tests proving Gemini is routed through the shared snapshot reducer without affecting Claude or Codex behavior.
- Add a Gemini parity suite, matching `CodexAppServerMonitorParityTests`, that replays recorded ACP-style fixtures through raw update mapping, normalized events, and the snapshot reducer.
- Update shared reducer/replay tests for `turnCompleted` ordering, dynamic mode/model metadata, `thought` transcript grouping, and coordinated typed approval actions.
- Manually verify with installed `gemini-cli 0.38.2`:
  - create a Gemini agent
  - send text
  - send an image attachment
  - approve and reject a tool request
  - switch mode/model if available
  - interrupt a running prompt
  - reopen a stored Gemini session
- Run `just build`.
- Run `just test`.

## Assumptions

- Gemini CLI `0.38.2` ACP behavior is the target.
- V1 relies on the user's existing Gemini CLI auth state.
- Empty `mcpServers: []` is acceptable for SecretAgentMan-managed sessions.
- Gemini tool execution remains owned by Gemini CLI; the app only displays ACP tool updates and answers permission requests.
- Local Gemini CLI source inspection remains part of implementation, because `gemini-cli` ships the ACP SDK and its practical transport details.
