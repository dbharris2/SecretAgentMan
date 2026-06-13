# SecretAgentMan

## Setup (one-time)

```bash
brew install mint xcodegen   # if not already installed
just bootstrap               # mint bootstrap — installs pinned SwiftLint/SwiftFormat from Mintfile
```

## Common commands

```bash
just build       # xcodegen generate + xcodebuild
just test        # Run unit tests
just run         # Build and launch the app
just format      # Auto-fix formatting (mint run swiftformat)
just lint        # Check formatting + linting (mint run swiftformat/swiftlint)
just lint-fix    # Auto-fix lint issues (mint run swiftlint --fix)
just periphery   # Scan for unused code (Periphery)
just bootstrap   # Install/refresh pinned tools from Mintfile
just clean       # Clear build artifacts
just xcode       # Open the project in Xcode
```

IMPORTANT: Always use the `just` recipes, never raw `xcodebuild`. They run `xcodegen generate` first so the `.xcodeproj` stays in sync with `project.yml` (the project file is gitignored and regenerated each invocation). SwiftLint/SwiftFormat versions are pinned in `Mintfile` (the single source of truth): locally `just bootstrap` installs them via `mint`; CI parses `Mintfile` and `curl`s the prebuilt binaries from each tool's GitHub releases. Same versions, different install paths — mint compiles from source which is too slow on every CI run.

## Gotchas

- This repo (`SecretAgentMan`) uses Jujutsu for its own history. Other repos monitored by the app may use Jujutsu, Graphite, or plain Git.
- Supported agent providers are Claude and Codex only. Gemini support has been removed.
- `handleSystemEvent` must NOT publish `.active` state — system events are config acks, not work indicators. Publishing `.active` there causes spurious "thinking" bubbles on permission mode changes.
- SwiftLint enforces a 1000-line file limit — `ClaudeStreamMonitor.swift` is near the limit.
