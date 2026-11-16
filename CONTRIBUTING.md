# Contributing to SleepSkip

Thank you for helping keep SleepSkip fast, native, and honest about power usage.

## Prerequisites

- macOS 13+
- Swift 5.10+ for the application; the Swift Testing suite requires a Swift 6+ toolchain with its Testing macro plugin. If Command Line Tools lacks that plugin, select an installed full Xcode toolchain via `DEVELOPER_DIR` for tests.

## Development & Verification

Run the unit test suite (`Swift Testing`) and behavioral verification suite:

```bash
swift test
./scripts/verify.sh
```

Build the Swift package:

```bash
swift build
```

Before a beta candidate, also run `bash scripts/verify_release.sh`, the actual terminal/CLI checks in `scripts/verify_cli.py`, and `bash scripts/probe_app_integration.sh`. See [beta acceptance](docs/BETA.md) for the full matrix and unverified hardware behavior.

Run the automated idle-power release gate against the built binary (or pass a custom path as the first argument):

```bash
chmod +x scripts/bench_gate.sh
./scripts/bench_gate.sh .build/debug/SleepSkip
```

The gate launches an isolated instance (`--isolated`) with the popover closed, waits 3 seconds for AppKit startup to settle, samples `proc_pid_rusage` for 20 seconds via `scripts/bench_idle.swift`, and fails if idle CPU exceeds `15.0 ms` or forced wakeups exceed `25`.

To build a release Universal `.app`, ZIP, and `.dmg` in `./dist/`:

```bash
chmod +x scripts/build_app.sh
./scripts/build_app.sh
```

To regenerate preview screenshots in `docs/images/`:

```bash
mkdir -p .build/verify
sed 's/^import SleepSkipCore$//' Sources/SleepSkip/PopoverViews.swift > .build/verify/PopoverViews.swift
sed 's/^import SleepSkipCore$//' Sources/SleepSkip/SystemBridge.swift > .build/verify/SystemBridge.swift
swiftc -O Sources/SleepSkipCore/*.swift .build/verify/PopoverViews.swift .build/verify/SystemBridge.swift Sources/SleepSkip/StatusBarIcon.swift scripts/render_screenshots.swift -o .build/verify/render_screenshots
.build/verify/render_screenshots docs/images
rm -rf .build/verify
```

## Architectural Guardrails

Pull requests must preserve all five guardrails:

1. **Avoid unnecessary periodic wakeups**: Keep countdown redraws inside the visible popover and use kernel events for passive monitoring. One-shot activity deadlines are allowed. Standard closed-lid suppression has a 5-second re-arm timer only while engaged; keep that exception bounded and measure it separately. Do not add process or power-command polling.
2. **Recoverable system changes**: System sleep modifications (`pmset -a disablesleep 1`) require explicit opt-in and an automatic restoration watchdog.
3. **Respect OS security**: Never simulate mouse/keyboard input to bypass screen lock.
4. **Own only our assertions**: Never run `killall caffeinate` or terminate assertions owned by other apps; bind assertions with `caffeinate -w <PID>`.
5. **Stay lean & native**: Swift + AppKit/SwiftUI + native system frameworks only.

## Adding a New AI Agent Source

Auto-follow watches transcript directories via `FSEvents` without reading file contents. To add support for another coding agent:

1. Register an `AgentSource` entry in `AgentSource.defaults(homeDirectory:)` inside `Sources/SleepSkipCore/AgentActivity.swift` with:
   - `id`: stable identifier (e.g., `"claude-code"`)
   - `displayName`: user-facing name (e.g., `"Claude Code"`)
   - `path`: directory receiving transcript writes (e.g., `~/.claude/projects`)
   - `fileSuffixes`: filename suffixes that indicate activity (defaults to `[".jsonl"]`)
2. Verify `AgentSource.matches(filePath:)` avoids prefix collisions and non-transcript noise files.
3. Add assertions covering the new source in `scripts/verify.sh` and `Tests/SleepSkipTests/SleepSkipCoreTests.swift`, then run `./scripts/verify.sh` and `./scripts/bench_gate.sh`.
