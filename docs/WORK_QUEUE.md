# Continuation queue

This file is the handoff for bounded background work. Read `ROADMAP.md` and
`VALIDATION.md` first. Do not interpret a quota reset as permission to invent
new project scope or repeatedly retry an external blocker.

## Next useful task

The foreground-input review and live Phase 1 acceptance are complete. All 74
Python tests, 53 native guards and 178 compatibility checks pass. Calculator click, 12+30=42 through MCP,
and PNG capture were verified after the user refreshed permissions.
See `VALIDATION.md` for evidence and the installed-binary/source distinction.

No further autonomous task is queued. Do not repeat the resolved permission
blocker or rebuild/reinstall the ad-hoc helper merely for verification, as this
can invalidate granted permissions. Exact-thread worker resumption remains
unverified; background jobs must not launch other workers themselves. Phase 2
depends on the vendor implementation and trust contract below; record new
external evidence before resuming that work.

The user approved the [written independent-compatibility design](superpowers/specs/2026-10-15-intel-compatibility-design.md)
and then the [implementation plan](superpowers/plans/2026-10-15-intel-compatibility-phase-2a.md)
for native sequential execution. Diagnostic A1/A2 work is implemented and
locally verified; [A3 is blocked](compatibility.md) by the absence of an eligible
actual-host provider route. No further autonomous task is queued. Do not
unpause the supervisor, retry indefinitely, or change host routing. A newly
evidenced exact route needs separate approval; quota resets do not bypass it.

[A3 integration issue #1](https://github.com/ercanatay/intel-computer-use/issues/1)
now records the reproduction, external references and route approval/restoration
checklist. The 2026-10-15 documentation/upstream review did not validate a route.
The tracking/documentation step is complete, not authorization for a host
experiment or a newly queued background task. Keep the supervisor paused.

## Human-dependent validation

Live input needs user-granted Accessibility permission. Window capture also
needs Screen Recording. The independent helper must report both permissions;
do not change TCC, click permission dialogs, or grant permissions automatically.
Use only Calculator for the existing smoke test while the session is unlocked.
Do not open private documents or inspect other apps to obtain test evidence.

## Phase 2 boundary

The official Locked Use toggle is not repaired by this independent server.
The installed vendor unlock service/installer and a complete Intel trust
contract are missing. A read-only same-version ARM64 reference inspection and
seven isolated IPC checks are now recorded in `docs/locked-use.md`. The original
authorization plugin checks the service's OpenAI team and signing identity;
reusing it with an independently signed service is not a viable integration.
A clean-room replacement remains an unproven design, not a queued implementation task
or an authorized installation. See `docs/locked-use.md`. Do not install an authorization
plugin, weaken authentication, store an OS password, patch ChatGPT, or fabricate
an installer response. Once useful local work is exhausted, return `blocked`
with that specific external dependency instead of spending quota indefinitely.

## Publication

Background jobs do not commit or publish changes. A human or the interactive
assistant reviews and publishes verified source. Never read Downloads, token
files, credential stores, or private CLI session transcripts.
