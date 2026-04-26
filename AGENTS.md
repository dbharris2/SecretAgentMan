# SecretAgentMan

## Common commands

```bash
just build       # xcodegen generate + xcodebuild
just test        # Run unit tests
just run         # Build and launch the app
just format      # Auto-fix formatting (SwiftFormat)
just lint        # Check formatting + linting (SwiftFormat + SwiftLint)
just lint-fix    # Auto-fix lint issues (SwiftLint)
just periphery   # Scan for unused code (Periphery)
just clean       # Clear build artifacts
just xcode       # Open the project in Xcode
```

IMPORTANT: Always use the `just` recipes, never raw `xcodebuild`. They run `xcodegen generate` first so the `.xcodeproj` stays in sync with `project.yml` (the project file is gitignored and regenerated each invocation).

## Gotchas

- `handleSystemEvent` must NOT publish `.active` state — system events are config acks, not work indicators. Publishing `.active` there causes spurious "thinking" bubbles on permission mode changes.
- SwiftLint enforces a 1000-line file limit — `ClaudeStreamMonitor.swift` is near the limit.
