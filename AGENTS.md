# SecretAgentMan

## Build & Test

```bash
just build    # xcodegen generate + xcodebuild
just test     # Run unit tests
```

IMPORTANT: Always use `just build` and `just test`, never raw `xcodebuild`. The `just` recipes run `xcodegen generate` first.

## Gotchas

- `handleSystemEvent` must NOT publish `.active` state — system events are config acks, not work indicators. Publishing `.active` there causes spurious "thinking" bubbles on permission mode changes.
- SwiftLint enforces a 1000-line file limit — `ClaudeStreamMonitor.swift` is near the limit.
