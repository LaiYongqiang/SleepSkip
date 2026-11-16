#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BIN_PATH="${1:-$ROOT_DIR/dist/SleepSkip.app/Contents/MacOS/SleepSkip}"
if [ ! -x "$BIN_PATH" ]; then
  if [ -x "$ROOT_DIR/.build/release/SleepSkip" ]; then
    BIN_PATH="$ROOT_DIR/.build/release/SleepSkip"
  elif [ -x "$ROOT_DIR/.build/debug/SleepSkip" ]; then
    BIN_PATH="$ROOT_DIR/.build/debug/SleepSkip"
  else
    echo "Error: SleepSkip binary not found. Build first or pass path as argument." >&2
    exit 2
  fi
fi

WINDOW_SECONDS="${WINDOW_SECONDS:-20}"
SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
MAX_CPU_MS="${MAX_CPU_MS:-15.0}"
MAX_WAKEUPS="${MAX_WAKEUPS:-25}"
COMPARE_BASELINE="${COMPARE_BASELINE:-0}"
MAX_WAKEUP_OVERHEAD="${MAX_WAKEUP_OVERHEAD:-25}"

TMP_DIR="$(mktemp -d)"
APP_PID=""
BASELINE_PID=""

cleanup() {
  for pid in "$APP_PID" "$BASELINE_PID"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

BENCH_BIN="$TMP_DIR/bench_idle"
swiftc "$ROOT_DIR/scripts/bench_idle.swift" -o "$BENCH_BIN"

EFFECTIVE_MAX_WAKEUPS="$MAX_WAKEUPS"

if [ "$COMPARE_BASELINE" = "1" ]; then
  BASELINE_APP="$TMP_DIR/BareStatusItem.app"
  mkdir -p "$BASELINE_APP/Contents/MacOS"
  cat > "$BASELINE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>BareStatusItem</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.laiyongqiang.SleepSkip.Baseline</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST
  cat > "$TMP_DIR/bare_status_item.swift" <<'SWIFT'
import Cocoa

final class BareDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = " "
        statusItem = item
    }
}

let app = NSApplication.shared
let delegate = BareDelegate()
app.delegate = delegate
app.run()
SWIFT
  swiftc -framework Cocoa "$TMP_DIR/bare_status_item.swift" -o "$BASELINE_APP/Contents/MacOS/BareStatusItem"

  "$BASELINE_APP/Contents/MacOS/BareStatusItem" >/dev/null 2>&1 &
  BASELINE_PID=$!
  sleep "$SETTLE_SECONDS"

  if ! kill -0 "$BASELINE_PID" 2>/dev/null; then
    echo "Error: Baseline status-item app exited during launch settling." >&2
    exit 1
  fi

  echo "==> Measuring host bare status-item baseline (${WINDOW_SECONDS}s window)..."
  BASELINE_LINE="$("$BENCH_BIN" "$BASELINE_PID" "$WINDOW_SECONDS")"
  echo "Baseline: $BASELINE_LINE"
  kill "$BASELINE_PID" 2>/dev/null || true
  wait "$BASELINE_PID" 2>/dev/null || true
  BASELINE_PID=""

  BASELINE_WAKEUPS="$(printf '%s\n' "$BASELINE_LINE" | sed -nE 's/.*wakeups=([0-9]+).*/\1/p')"
  if [ -z "$BASELINE_WAKEUPS" ]; then
    echo "Error: Failed to parse baseline wakeups from: $BASELINE_LINE" >&2
    exit 1
  fi
  OVERHEAD_LIMIT=$(( BASELINE_WAKEUPS + MAX_WAKEUP_OVERHEAD ))
  if [ "$OVERHEAD_LIMIT" -gt "$EFFECTIVE_MAX_WAKEUPS" ]; then
    EFFECTIVE_MAX_WAKEUPS="$OVERHEAD_LIMIT"
  fi
fi

# Launch in clean idle state (skip onboarding popover so the measurement covers closed-panel idle).
"$BIN_PATH" --isolated --no-auto-follow >/dev/null 2>&1 &
APP_PID=$!

# Allow AppKit launch overhead to settle before sampling the idle window.
sleep "$SETTLE_SECONDS"

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "Error: SleepSkip exited during launch settling." >&2
  exit 1
fi

echo "==> Running idle power gate (${WINDOW_SECONDS}s window, max ${MAX_CPU_MS}ms CPU, max ${EFFECTIVE_MAX_WAKEUPS} wakeups)..."
"$BENCH_BIN" "$APP_PID" "$WINDOW_SECONDS" \
  --max-cpu-ms "$MAX_CPU_MS" \
  --max-wakeups "$EFFECTIVE_MAX_WAKEUPS"
echo "IDLE POWER GATE PASSED"
