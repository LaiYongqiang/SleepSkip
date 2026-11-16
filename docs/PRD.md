# SleepSkip Product Requirements Document (PRD)

> **Positioning**: An ultra-lightweight native macOS menu bar utility built for Vibe Coding and AI Agent workflows.  
> **Core Philosophy**: Give every watt of battery power to your active AI Agents and background tasks, not an idle illuminated display.

---

## 1. Background & Core Insights

Modern macOS developers frequently run long-lived engineering and AI workflows (Codex CLI, Claude Code, builds, tests, local servers, model inference) while commuting, tethering to mobile hotspots, or stepping away from their desk:

1. **Battery & Thermal Sensitivity**: On fanless MacBook Air or battery-powered MacBooks, keeping the display lit is one of the largest battery and thermal drains.
2. **Separation of Background Compute & Desktop GUI**:
   - **CLI, code generation, builds, tests, local servers, and headless browser jobs** execute cleanly while the screen is off and locked.
   - **Desktop GUI automation (Computer Use / `ScreenCaptureKit` / `CGEvent`)** requires an active, unlocked WindowServer session.
3. **Zero Idle Overhead**: The utility must avoid unnecessary background polling and wakeups. Countdown redraws run only with the popover visible. One-shot activity deadlines and the active standard closed-lid re-arm timer are explicitly scoped exceptions. Measured idle cost is documented in `docs/PERFORMANCE.md`.

---

## 2. Core Modes & Controls

### 2.1 Two Official Modes

| Mode | Underlying Assertion | Ideal Use Cases |
| :--- | :--- | :--- |
| **Background (Default)** | `/usr/bin/caffeinate -i -w <PID>` | Codex CLI, Claude Code, builds, downloads, local servers, hotspot sessions |
| **Keep Display On** | `/usr/bin/caffeinate -di -w <PID>` | Computer Use GUI agents, presentations, log monitoring, documentation reading |

### 2.2 Portable Security & Backpack Options (Under Background Mode)

1. **Lock on Start** (Enabled by default, remembered): Immediately triggers native macOS screen lock upon starting a background session.
2. **Stay Awake Lid-Closed / Backpack Mode** (Disabled by default, opt-in; strategy configurable in Preferences):
   - **Standard (default, no authorization)**: sets `kPMSetClamshellSleepState` (`IOPMrootDomain` selector `12`) paired with an event-driven `IOKit.ps` power-source observer (no background timer). Holds on steady power; reconnecting AC power while the lid is already shut sleeps after 6–9 s per `powerd` behavior.
   - **Compatibility (administrator authorization)**: requests standard macOS Touch ID / administrator authorization when started, applying `pmset -a disablesleep 1` guarded by a kernel `kqueue` watcher (`caffeinate -i -w <sentinelPID>`) paired with `trap 'pmset -a disablesleep 0' EXIT INT TERM`. Survives power-source changes, automatically restores normal sleep (`disablesleep 0`) on manual stop, expiry, or unexpected termination, and performs a one-shot `pmset -g` check on launch/show to offer instant recovery if `SleepDisabled = 1` remains set.

### 2.3 Duration Presets & Configuration Memory

- **5 Duration Presets + Custom**: `30m`, `1h`, `2h`, `4h` (default safety cap), `Indefinite`, plus an inline `Custom` field clamped to 7 days.
- **Remember Last Config + Enter to Launch**: Automatically persists mode, lock-on-start, closed-lid preference, and duration. Pressing `Enter` when idle starts immediately with the remembered configuration; pressing `Enter` or `Esc` while running closes the popover without interrupting the active session.

---

## 3. Event-Driven Architecture & Power Guardrails

1. **Bounded Scheduling**: Countdown `Timer` runs strictly while `NSPopover` is visible. Directory following schedules one-shot activity/grace deadlines; standard closed-lid mode re-arms every 5 seconds only while engaged.
2. **Lifecycle Binding**: Every `caffeinate` child carries `-w <APP_PID>`, ensuring zero orphaned processes if the app quits or crashes.
3. **Zero-Polling Low-Battery Cutoff**: Optional battery protection (`Off` / `5%` / `10%` / `15%` / `20%`, default `10%`) uses `IOKit.ps` `IOPSNotificationCreateRunLoopSource` callbacks—only activating when discharging on battery.
4. **Native macOS Integration**: Left-click status item opens Popover; right-click opens native context menu; Launch at Login uses `SMAppService.mainApp`.

---

## 3.1 Auto-Follow for AI Agents (default on)

Instead of asking the user to remember to start and stop a session, SleepSkip can hold the assertion exactly while a coding agent is working.

- **Signal**: FSEvents on the agents' transcript directories (`~/.claude/projects`, `~/.codex/sessions`, `~/.dsh/sessions`). Each source declares the filename suffixes that count as a write, because agents differ: Claude Code and Codex append `.jsonl`, while DeepSeek Harness writes compressed `session.v4.jsonl.zstd`. Only the fact that a transcript file changed is observed — contents are never read, parsed, or transmitted.
- **No polling**: the monitor is a kernel event stream. Measured cost: ~0.2 ms of CPU over 20 seconds while watching a live session directory, with no wakeups beyond what the status item already needs. Process polling at 1 Hz was measured at ~160 ms/30 s plus one wakeup per second and was rejected.
- **Timing rules**: a write keeps the agent active for 30 s; then a 5-minute grace period covers long tool calls that produce no output; then the assertion is released.
- **Hard ceiling**: one automatic session cannot exceed 2 hours. On hitting it, SleepSkip releases and notifies, so a chatty background process can never pin the Mac awake all night.
- **Precedence**: a manual session always wins. Auto-follow never overrides it, never switches to Keep Display, and never enables lid-closed backpack mode — those stay explicit user actions. Switching an active automatic session to Keep Display promotes it to a manual session.
- **Stopping**: pressing Stop during an automatic session ends the current session and suppresses auto-follow until the agents go quiet, preserving the global Auto-Follow preference.

---

## 3.2 CLI Signal Semantics

`sleepskip -- <command>` spawns the command as a direct child and runs `caffeinate -w <wrapperPID>` alongside it as a passive observer bound to the wrapper. Terminal foreground ownership is transferred for interactive commands and restored before the wrapper exits. This matters because `caffeinate` does not forward signals:

- `Ctrl+C` reaches the command itself (the wrapper forwards `SIGINT`/`SIGTERM` to the child), so an agent run can always be interrupted.
- The command's exit status is propagated unchanged; a death by signal is reported as `128 + signal`, matching shell convention.
- Arguments after `--` are passed through untouched, including `--version` and `--help`, which would otherwise be intercepted by SleepSkip's own flag parsing.

---

## 3.3 Duration Input Validation

User-supplied durations are sanitized at every entry point:

- Non-finite values (`inf`, `NaN`, `1e999`) are rejected rather than converted, since `Int(_:)` traps on infinity.
- Finite but excessive values are clamped to a 7-day ceiling.
- Values loaded from `UserDefaults` are sanitized on read, so a previously poisoned preference cannot crash the app on launch.
- URL parameters (`sleepskip://start?minutes=…`) go through the same validation.

---

## 4. Architectural Red Lines

1. **No process/power polling or 1Hz menu bar redraws** when the popover is hidden. Keep justified activity deadlines and active-lid rearming scoped to their owning mode.
2. **No silent or unguarded system power modifications**: `disablesleep` is strictly opt-in, Touch ID authorized, and self-healing via `kqueue` + `trap`.
3. **No synthetic mouse/keyboard jiggling** to bypass OS lock screen security policies.
4. **No `killall caffeinate`**: process management applies strictly to child handles spawned by SleepSkip.
5. **No heavy runtimes**: zero Electron, WebView, telemetry, or persistent helper daemons.

## Beta evidence boundary

Directory activity is a heuristic rather than proof of task completion. Safety cutoffs release SleepSkip assertions, not the workload. Closed-lid behavior, first-download installation and supported hardware/OS combinations require real acceptance; see [BETA.md](BETA.md). Directory auto-follow and explicit hooks have independent controls.
