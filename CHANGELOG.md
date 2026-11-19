# Changelog

All notable releases of **SleepSkip · 惜眠** are documented here.

## [Unreleased] — beta hardening

- Collapse the popover into three focused scenes (`.idle`, `.following`, `.manualRunning`) with flattened Preferences, explicit promotion to manual timer, and safe return to Auto-Follow (with closed-lid handoff confirmation).
- Add configurable Auto-Follow safety ceiling (`2h`, `4h`, `8h`, `12h`, `Unlimited`), automatic handoff from expired manual timers to Auto-Follow (`handoffToAutoFollowOnExpiry`), and subprocess-aware grace extension for silent tool calls.
- Correct automatic-session boundaries, manual-stop suppression, mixed Hook / directory ownership, and authorization cancellation / cleanup.
- Unify `SessionManager` running-state transition contracts and consolidate Auto-Follow ceiling state ownership.
- Restore interactive terminal input and signal handling for CLI commands; bind assertion lifetime to their owning wrapper.
- Read bounded, complete Hook input; preserve user hooks using exact ownership, and use an absolute executable path.
- Harden directory event filtering, source changes, concurrent CLI status, duplicate launches, and isolated validation.
- Separate prerelease publication from the stable tap and keep numeric build metadata independent of release labels.
- Document actual activity-signal, thermal, closed-lid and acceptance limits in `docs/BETA.md`. Real hardware recovery and full installation acceptance remain separate from automated checks.

## [1.6.0]

### Agent Ecosystem & Hooks
- **Auto-Follow Expanded to 5 Built-In AI Agents + Custom Folders**: Watches `~/.claude/projects` (Claude Code), `~/.codex/sessions` (Codex), `~/.dsh/sessions` (DeepSeek Harness), `~/.gemini/tmp` (Gemini CLI), and `~/.local/share/opencode` (OpenCode) through a single coalesced `FSEvents` stream, plus user-added custom folders and per-source toggles in Preferences. Ignores `.git/`, `node_modules/`, `.build/`, `DerivedData/`, `.Trash/`, and `.tmp`/`.swp`/`.swo`/`~`/`.lock` noise files.
- **Instant Prompt-Level Hooks (`sleepskip hook`)**: Added `sleepskip hook start|stop [--agent <name>] [--session <id>] [--pid <pid>]` with multi-session reference counting, `stdin` `session_id` auto-detection (for Claude Code `UserPromptSubmit` / `Stop` hooks), optional `kqueue` process-exit watching, a 2-hour safety ceiling, plus `sleepskip hook install|uninstall` and a one-click **Connect** button in Preferences that safely merges `~/.claude/settings.json` without losing existing settings.

### Keyboard Flow, CLI Companion & Minimalist Design
- **Zero-Wakeup Global Shortcut (`⌃⌥S`)**: Implemented via Carbon `RegisterEventHotKey` with zero Accessibility permissions and zero idle wakeups (toggleable in Preferences).
- **Terminal & Launcher Integration**: Added `sleepskip status [--json]`, `sleepskip doctor` (on-demand `pmset -g assertions`, hook, and app diagnostics), `sleepskip stop`, `sleepskip toggle`, and `sleepskip lock`; added one-click `sleepskip` CLI symlinking into `/opt/homebrew/bin` or `/usr/local/bin`; bundled Raycast script commands, Apple Shortcuts URL examples, and `tmux` status snippets in `extras/`.
- **Built-In Thermal Safety & Zero-Config Preferences**: Automatic `Critical` thermal cutoff via `ProcessInfo.thermalStateDidChangeNotification`, collapsible `Advanced (Power, Lid & History)` drawer (with 10-entry Recent Sessions), and a crisp non-scrolling Preferences layout with distinct wake-cup template icon.

### Engineering & Release Gates
- **Automated Idle Power Gate**: Added `./scripts/bench_gate.sh` (threshold: `<= 15.0 ms` CPU and `<= 25` forced wakeups per 20 s idle window) enforced on CI and release packaging.
- **Swift Testing Suite**: Native Swift Testing test suite (`swift test --disable-build-manifest-caching`) alongside `./scripts/verify.sh`.

## [1.5.0]
- Native `caffeinate -w <PID>` engine with zero background timers or polling when closed.
- Automatic AI agent activity tracking with 5-minute grace period and 2-hour safety ceiling.
- Dual-strategy closed-lid backpack mode (Standard unprivileged `kPMSetClamshellSleepState` + Compatibility Touch ID `pmset -a disablesleep 1` with `kqueue` restore watchdog).
- Battery threshold cutoff and unplug protection via `IOKit.ps` runloop notifications.
- Universal (`arm64` + `x86_64`) `.app` / `.dmg` build script and Homebrew cask formula.
