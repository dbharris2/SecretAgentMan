# Shared Session Panel Shells

## Summary

Reduce duplication between `ClaudeSessionPanelView` and `CodexSessionPanelView` by extracting the shared layout and interaction pieces into reusable shell views and helpers, while keeping two small provider-specific top-level panel wrappers.

This pass is explicitly optimizing for less duplicated logic, not for forcing the app into one canonical panel type. The shared pieces should own the common chat, composer, lifecycle, focus, and interrupt behavior. Provider wrappers should remain responsible only for provider-specific prompt cards, send actions, trailing controls, and Claude-specific slash-command behavior.

## Key Changes

- Extract a shared chat shell used by both providers:
  - wraps `SessionChatView`
  - accepts provider name, empty-state text, transcript, streaming text, thinking state, active tool, and pending-card content
  - owns no provider-specific branching
- Extract a shared composer shell used by both providers:
  - wraps `SessionComposer`
  - owns common draft state, pending-image state, focus state, send trigger wiring, and shared return-to-send behavior
  - supports pluggable trailing controls and optional suggestion content
- Extract shared panel lifecycle and keyboard helpers:
  - common `Ctrl+C` interrupt handling
  - common `focusComposer` notification behavior
  - common `onAppear` and `agent.id` change session-ensure behavior
  - shared default composer key handling
  - provider-specific key handling remains opt-in for Claude slash navigation and acceptance
- Keep two provider-specific top-level wrappers:
  - `ClaudeSessionPanelView` becomes a thin composition layer over the shared shells
  - `CodexSessionPanelView` becomes a thin composition layer over the shared shells
  - each wrapper should be reduced to provider-only state and behavior, targeting roughly “configuration plus small callbacks,” not full layout ownership
- Keep provider-specific responsibilities local:
  - Claude: slash suggestions, slash-aware key handling, permission-mode picker, approval and elicitation actions
  - Codex: collaboration-mode picker, usage ring, debug banner, approval and structured-input actions
  - prompt-card bodies stay provider-specific in this pass
- Do not introduce a broad `SessionPanelAdapter` object in this pass:
  - prefer plain subviews and a small number of focused helper closures over a large config surface
  - if a shared helper would require more than a handful of provider-specific parameters, stop and leave that logic in the wrapper instead
- Preserve current user-visible behavior:
  - Claude slash autocomplete behavior, arrow navigation, and return and escape handling
  - Codex usage ring and collaboration mode picker
  - current prompt-answer behavior for both providers
  - current image-send flows for both providers

## Interfaces

- Add a small shared view layer rather than a fat adapter abstraction. Expected additions:
  - `SessionChatShell` or equivalent shared chat container
  - `SessionComposerShell` or equivalent shared composer container
  - a small shared lifecycle or keyboard helper if needed
- Keep interfaces intentionally narrow:
  - shared shells take already-derived snapshot data and child content
  - shared shells do not own provider-specific action routing
  - provider wrappers pass closures or small child views for pending cards, suggestions, trailing controls, and send behavior
- Keyboard handling must be explicitly split:
  - shared shell handles the common `Return` send path
  - Claude wrapper owns slash-specific arrow, escape, and accept behavior
  - Codex wrapper uses the shared default path with no slash behavior
- Requirement for completion:
  - both existing provider panels remain as top-level entry points
  - duplicated layout logic should move into shared shells
  - provider wrappers should be visibly smaller and should no longer duplicate the main panel structure

## Test Plan

- Shared shell behavior:
  - both Claude and Codex render transcript, streaming text, thinking state, and empty state through the same shared chat shell
  - both use the same shared composer shell for draft and pending-image behavior
  - `Ctrl+C`, focus notifications, and session-ensure lifecycle behave identically to current behavior
- Claude-specific scenarios:
  - slash suggestions still appear only for Claude
  - arrow navigation, return-to-accept, and escape behavior still work
  - Claude elicitation and approval cards still render and dispatch the same actions
  - permission-mode picker still reflects snapshot metadata and updates Claude mode correctly
- Codex-specific scenarios:
  - Codex debug banner still renders in the same circumstances
  - Codex user-input and approval cards still render and dispatch the same actions
  - collaboration-mode picker and usage ring still appear and behave the same
- Structural regression checks:
  - the two provider panel files still exist, but they no longer duplicate the full panel layout
  - shared shells contain the common layout and interaction logic previously duplicated across both panels
  - no new broad adapter type accumulates panel-sized responsibility

## Assumptions

- Phase 3 is complete enough that both provider panels can read shared snapshot state for transcript, prompt, metadata, and streaming needs.
- This pass prioritizes reducing duplicated logic and view structure, not forcing a single top-level panel type.
- Prompt-model redesign is out of scope; provider-specific prompt-card bodies remain acceptable.
- If a shared extraction starts requiring a wide provider-specific interface, prefer keeping that behavior in the thin wrapper rather than expanding the shared shell abstraction.
