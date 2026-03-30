# SecretAgentMan

A macOS app for managing multiple Claude Code agent sessions with a Slack-like interface.

## Tech Stack

- SwiftUI with NavigationSplitView (macOS 14+)
- SwiftTerm for embedded terminal emulation
- XcodeGen for project generation
- Swift Testing framework for unit tests
- SwiftLint + SwiftFormat enforced via build phases

## Setup

```bash
brew install xcodegen just   # If not already installed
just xcode                   # Generates project + opens in Xcode
```

## Project Structure

- `Sources/SecretAgentMan/` - Main app source code
  - `SecretAgentManApp.swift` - App entry point with three-column layout
  - `Models/` - Data models (Agent, AgentState, FileChange, PRCheckStatus/PRInfo/PRState)
  - `Services/` - AgentProcessManager, DiffService, PRService, TerminalManager, ShellManager, GhosttyThemeLoader
  - `ViewModels/` - AgentStore (observable state, persists to ~/Library/Application Support/SecretAgentMan/agents.json)
  - `Views/` - SwiftUI views organized by panel (Sidebar, Center, Terminal, Common)
- `Resources/` - Info.plist, entitlements, assets, bundled Ghostty themes
- `Tests/SecretAgentManTests/` - Unit tests for PRService, DiffService, GhosttyThemeLoader
- `project.yml` - XcodeGen project specification

## Common Commands

```bash
just build    # Generate project + build
just run      # Build + launch app
just test     # Run unit tests
just lint     # Check formatting + linting
just format   # Auto-fix formatting
just clean    # Remove build artifacts
just xcode    # Open in Xcode
```

## Key Patterns

- **Polling timers**: Diffs/branches refresh every 5s, PR status every 30s (also triggers on branch change)
- **Session persistence**: Agents store a sessionId; on launch, `--resume <id>` or `--session-id <id>` is passed to Claude Code. Stale sessions are auto-detected and restarted with a fresh session.
- **Theme loading**: 460+ Ghostty themes bundled in Resources/Themes. GhosttyThemeLoader checks the bundle first, falls back to /Applications/Ghostty.app if a theme isn't found.
- **PR tracking**: PRService shells out to `gh` CLI. Handles both GitHub CheckRun and StatusContext API shapes. Gracefully no-ops if `gh` is not installed.
- **PersistentSplitView**: NSViewRepresentable wrapping NSSplitView with autosaveName so divider positions persist across restarts.

## Testing

Tests use Swift Testing (`@Test`, `#expect`). Test the parsing/logic layers — PRService JSON parsing, DiffService diff parsing, GhosttyThemeLoader theme parsing. Use `@testable import SecretAgentMan` for internal access.

```bash
just test     # or: xcodebuild test -scheme SecretAgentMan -destination 'platform=macOS'
```
