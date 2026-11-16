#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cache="${SLEEPSKIP_PROBE_CACHE:-/tmp/sleepskip-hardening-app-probe-build}"
export CLANG_MODULE_CACHE_PATH="$cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache/modules"
swift build --build-system native --disable-sandbox --scratch-path "$cache" --target SleepSkipCore >/dev/null
bin="$cache/arm64-apple-macosx/debug"
if [ ! -d "$bin" ]; then bin="$cache/x86_64-apple-macosx/debug"; fi
xcrun swiftc -module-cache-path "$cache/modules" -parse-as-library -I "$bin/Modules" "$bin"/SleepSkipCore.build/*.o Sources/SleepSkip/AgentActivityMonitor.swift Sources/SleepSkip/UnprivilegedLidGuard.swift Sources/SleepSkip/SystemBridge.swift Sources/SleepSkip/AppDelegate.swift Sources/SleepSkip/PopoverViews.swift Sources/SleepSkip/StatusBarIcon.swift Sources/SleepSkip/GlobalHotKeyMonitor.swift scripts/probes/AppIntegrationProbe.swift -o "$cache/app-integration-probe"
if [ "${1:-}" != "--build-only" ]; then "$cache/app-integration-probe" --isolated; fi
