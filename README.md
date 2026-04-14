# Secret Agent Man

A macOS app for managing Claude Code and Codex agent sessions with a native chat interface.

## Features

### Chat Interface
- **Real-time streaming text** — responses appear word-by-word
- **Tool approval cards** — approve, deny, or switch permission mode (Accept Edits / Auto) in one click
- **Active tool indicator** — "Running Bash...", "Running Read..." while tools execute
- **AskUserQuestion buttons** — structured options render as clickable buttons
- **Image paste** — Cmd+V to paste images with thumbnail previews; click to open in Preview
- **Slash command autocomplete** — type `/` in the composer for suggestions
- **Permission mode switching** — ctrl+m cycles through modes
- **Session persistence** — sessions survive app restarts with automatic resume

### Multi-Agent Management
- **Multiple agents** — create, switch, rename, and remove agents across project folders
- **Provider selection** — Claude or Codex per agent
- **Sidebar organization** — agents grouped by folder with collapsible sections
- **Keyboard shortcuts** — Cmd+1-9 to switch agents, Cmd+N for new agent

### Code & PR Tracking
- **Colored diff view** — unified and side-by-side with per-file filtering
- **PR status tracking** — live CI checks, reviewer avatars via `gh` CLI
- **Plans panel** — browse and read Claude Code plans
- **VCS integration** — jj or git branch info per folder

### Shell
- **Split shell** — a terminal below the agent session for running commands
- **Ghostty theme support** — 460+ themes bundled

## Requirements

- macOS 14.0+
- [Claude Code](https://claude.ai/download) CLI and/or Codex CLI installed
- [`gh` CLI](https://cli.github.com) (optional, for PR tracking)

## Setup

```bash
brew install xcodegen just
just xcode
```

## Building

```bash
just build    # Generate project + build
just run      # Build + launch app
just test     # Run unit tests
just lint     # Check formatting + linting
just format   # Auto-fix formatting
```

## Installation

Download the latest release from [Releases](https://github.com/dbharris2/SecretAgentMan/releases), extract the zip, and move **SecretAgentMan.app** to your Applications folder.

Before opening, remove the quarantine flag:

```bash
xattr -cr /Applications/SecretAgentMan.app
```

## License

MIT
