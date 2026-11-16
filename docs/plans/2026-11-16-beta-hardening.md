# SleepSkip beta hardening — 2026-11-16

Authorized scope: implement the confirmed findings of the independent GPT-6-ASTRA audit, preserving the current working tree and native architecture. No publishing, real-home hook installation, screen locking, or real power-setting changes during tests.

Approach: targeted lifecycle corrections with shared state invariants; no wholesale rewrite. Directory auto-follow and explicit hooks remain separate controls. Standard closed-lid rearming stays until measured evidence supports its removal; documentation must describe its timer accurately. Work in the current checkout on a dedicated branch because the audited baseline includes substantial uncommitted work. Baseline copy: `/private/tmp/sleepskip-hardening-baseline`.

## Tasks and ownership

1. Core lifecycle: correct automatic-session boundaries and suppression; release only the finishing source; namespace hook IDs; consistent power preflight and notification permission; cancel/timeout/late authorization cleanup. Canonical source matching, precise hook ownership and usable hook executable path. Add meaningful regression sequences first. Own SessionManager.swift, AgentActivity.swift, and core tests.
2. CLI: preserve terminal foreground input, interruption and exit status; clean watch cancellation; safely read complete bounded hook JSON. Add actual PTY and process-lifetime regressions. Own main.swift and CLI-specific helpers/tests/scripts.
3. App/system integration: serial event ownership; filter non-write events; source reconfiguration and missing-directory discovery; multi-PID external CLI presentation; avoid duplicate-instance snapshot writes; isolate test guards and clean up only owned guards. Own AppDelegate.swift, AgentActivityMonitor.swift, SystemBridge.swift, UnprivilegedLidGuard.swift, related UI and integration probes.
4. Release and user-facing evidence: distinguish prerelease from stable; use valid numeric build metadata; state heuristic, thermal and lid limitations accurately; document beta acceptance and recovery; keep feedback claims proportional.
5. Integration: inspect patches against baseline, run full Swift tests and verify.sh, actual terminal/file-event probes, universal packaging on temporary copy, then independent review. Resolve confirmed regressions; report remaining hardware/OS acceptance gaps explicitly.

## Acceptance

No lost fresh task after manual stop; no cross-source release; per-session cap; no hook lease mismatch from long/fragmented stdin; interactive shell reads terminal; cancelled watcher leaves no assertion; authorization cancellation cannot revive session; idle isolated checks cannot clear system state owned elsewhere. Beta tags cannot update stable tap. Existing user configuration is preserved.

## Progress

- Baseline captured; original changes retained. Implementation in progress.

- Core, CLI, App/system and release/docs tasks completed. Original WIP remains preserved.
- Final verification: 71 unit tests, 12 native CLI/PTY regressions, actual-file-event + fake-power App integration, verify.sh, release metadata/syntax, universal beta packaging, codesign/DMG integrity, and isolated idle gate passed.
- Independent final review clean after resolving terminal bg/fg, serialized old/new guard cleanup/readiness, all-auto deadlines, hook expiry suppression, and pending manual authorization handoff.
- Product calls: hooks remain separate from directory switch; display-mode promotion releases owned lid suppression; standard active-lid timer retained and documented; no broad rewrite or claim of overall repository decay.
- Physical/integration acceptance remains pending as enumerated in docs/VALIDATION-2026-11-16.md. No commit, push, installation, or publication performed.
