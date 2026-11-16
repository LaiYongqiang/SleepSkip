# SleepSkip Companion Extras

Zero-overhead templates to control or monitor SleepSkip from Raycast, Apple Shortcuts, `tmux`, and your shell prompt.

## 1. Raycast Script Commands

Point Raycast **Extensions -> Script Commands -> Add Directories** to `extras/raycast`:

- [sleepskip-status.sh](raycast/sleepskip-status.sh): Reads live state via `sleepskip status --json` (zero IPC server, zero idle polling).
- [sleepskip-toggle.sh](raycast/sleepskip-toggle.sh): Toggles the active menu bar session via `sleepskip toggle`.

Make sure the scripts are executable (`chmod +x extras/raycast/*.sh`) and `sleepskip` is installed (via Homebrew or **Preferences -> Install CLI**).

## 2. Apple Shortcuts (Zero-Dependency URL Actions)

Create a shortcut with a single **Open URLs** action (no helper app or AppleScript needed):

- Toggle keep-awake: `sleepskip://toggle`
- Start 4h background session + lock screen: `sleepskip://start?mode=background&minutes=240&lock=1`
- Start 1h display-on session: `sleepskip://start?mode=display&minutes=60&lock=0`
- Stop session: `sleepskip://stop`

## 3. Shell / `tmux` Status Snippet

```bash
# Example compact status badge (runs only when your prompt renders)
sleepskip status --json | jq -r 'if .active then "☕ awake" else empty end'
```

## 4. Claude Code Prompt-Level Hooks

Connect automatically via **Preferences -> Configure sources & folders -> Connect** or from the terminal:

```bash
sleepskip hook install
```

Remove cleanly at any time (`~/.claude/settings.json` keys and other hooks are preserved):

```bash
sleepskip hook uninstall
```
