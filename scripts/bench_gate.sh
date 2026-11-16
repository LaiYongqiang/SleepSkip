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
MAX_CPU_MS="${MAX_CPU_MS:-15.0}"
MAX_WAKEUPS="${MAX_WAKEUPS:-25}"

# Launch in clean idle state (skip onboarding popover so the measurement covers closed-panel idle).
"$BIN_PATH" --isolated --no-auto-follow >/dev/null 2>&1 &
APP_PID=$!

cleanup() {
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Allow AppKit launch overhead to settle before sampling the idle window.
sleep 3

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "Error: SleepSkip exited during launch settling." >&2
  exit 1
fi

echo "==> Running idle power gate (${WINDOW_SECONDS}s window, max ${MAX_CPU_MS}ms CPU, max ${MAX_WAKEUPS} wakeups)..."
swift "$ROOT_DIR/scripts/bench_idle.swift" "$APP_PID" "$WINDOW_SECONDS" \
  --max-cpu-ms "$MAX_CPU_MS" \
  --max-wakeups "$MAX_WAKEUPS"
echo "IDLE POWER GATE PASSED"
