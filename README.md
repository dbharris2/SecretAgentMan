# Secret Agent Man

A macOS app for managing multiple Claude Code agent sessions with a Slack-like interface.

## Features

- **Multi-agent management** — create, switch, rename, and remove agents across different project folders
- **Embedded terminal** — full interactive Claude Code TUI via SwiftTerm
- **Split shell** — a second terminal below Claude for running git/jj commands in the agent's directory
- **Colored diff view** — unified and side-by-side diff views with per-file filtering
- **Ghostty theme support** — 460+ terminal themes bundled with the app (no Ghostty installation required)
- **Plans panel** — browse and read Claude Code plans with full markdown rendering
- **VCS integration** — shows jj commit descriptions or git branch names per folder
- **Session persistence** — agents and sessions survive app restarts via `claude --resume`
- **Keyboard shortcuts** — Cmd+1-9 to switch agents, Cmd+N for new agent
- **Plugin support** — configurable `--plugin-dir` passed to all Claude sessions

## Requirements

- macOS 14.0+
- [Claude Code](https://claude.ai/download) CLI installed

## Setup

```bash
brew install xcodegen just   # If not already installed
just xcode                   # Generates project + opens in Xcode
```

## Building

```bash
just build    # Generate project + build
just run      # Build + launch app
just test     # Run unit tests
just lint     # Check formatting + linting
just format   # Auto-fix formatting
just clean    # Remove build artifacts
```

## Installation

Download the latest release from [Releases](https://github.com/dbharris2/SecretAgentMan/releases), extract the zip, and move **SecretAgentMan.app** to your Applications folder.

Before opening, run this in Terminal to remove the quarantine flag:

```bash
xattr -cr /Applications/SecretAgentMan.app
```

## Architecture

- **SwiftUI** with three-column `NavigationSplitView`
- **SwiftTerm** for embedded terminal emulation
- **MarkdownUI** for plan rendering
- **XcodeGen** for project generation

```
Sources/SecretAgentMan/
  SecretAgentManApp.swift          — App entry point
  Models/                          — Agent, AgentState, FileChange
  Services/                        — Process management, diff, themes, shell
  ViewModels/                      — AgentStore (observable state)
  Views/
    Sidebar/                       — Activity bar, agent list, plan list
    Center/                        — Diff views, plan detail, changes
    Terminal/                      — Claude terminal, shell terminal
    Common/                        — Status badge
```

## License

MIT
