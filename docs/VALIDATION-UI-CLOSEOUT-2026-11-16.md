# UI review closeout — 2026-11-16

This closes the final authorization-failure finding on top of `21720d6` on
`fix/ui-audit-polish`. It is not a release or a claim of complete hardware acceptance.

## Final correction

When administrator authorization succeeds but the subsequent wake assertion cannot
start, both failure exits now synchronize the displayed Hook protection state and
notify the host. This includes a failed process launch and rejection by the repeated
power/thermal preflight. The UI no longer retains a stale waiting-for-authorization
state after authorization has ended.

An older manual or automatic session remains active with its existing deadline when
the replacement fails. The correction does not start another session, extend its
lifetime, or lock the screen.

## Verification

- Added `authorizedLaunchFailurePublishesActualHookProtection`: no prior session,
  manual session, and automatic session, each combined with spawn, battery, and
  thermal failure (nine scenarios).
- Before the correction the new test failed on 18 status/callback assertions.
- After the correction the complete suite passed: 72 Swift Testing + 6 XCTest,
  78 tests total.
- `scripts/verify.sh` passed. Existing SDK macro warnings remain non-fatal.
- `scripts/probe_app_integration.sh` passed its three groups: real FSEvents,
  isolated app/session ownership, and production guard scripts using fake power
  commands. No real power configuration was changed.
- Focused independent review found no actionable issue in the final delta.

## Acceptance scope

Previous native-view checks covered explicit confirmation before dropping lid
protection, cancellation preserving the lid session, paused Hook labels, and
500-point constrained layouts with scrolling and accessible authorization cancel.
The last state-mapping/copy changes distinguish pending authorization with no
protection from pending replacement while an existing session remains active;
these and the final failure exits are covered by current core regression tests.

Real administrator authorization, actual lid-close/power restoration, real Hook
installation, full VoiceOver/keyboard navigation, and multi-display/small-screen
coverage remain separate release acceptance tasks. This closeout does not claim
that those previously unverified scenarios have passed.
