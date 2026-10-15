# Validation

This document separates executable tests from live desktop evidence.

## Automated

- Python protocol, policy, native transport, stdio, supervisor, smoke, and optional-harness tests: 74 passing on this Mac.
- Swift policy, session, deadline, coordinate, keyboard, and foreground-input checks: 53 passing.
- Separate compatibility executable: 178 framing, strict JSON/policy, runtime,
  peer-evidence, real-socket and simulated-lifecycle checks passing.
- Native debug/release build: successful on x86_64 with Swift 6.
- Installed independent bundle: strict code-signature verification successful;
  executable matches the release artifact.

### Foreground-input review — 2026-10-15

Extracted the existing foreground-process and pointer-owner decisions into
`ForegroundInputPolicy`, used by the native helper at its existing guard sites.
Twelve new checks cover the expected process, a different process, and missing
process evidence, combined with termination or window-ownership evidence.
They verify that another window of the same app is rejected and that matching
window evidence cannot override a failed process lookup. Failure codes remain
`focus_changed` and `point_occluded`.

The Python protocol and supervisor suite passed all 58 tests using test fixtures;
the Swift guard executable passed all 53 checks, and the native helper debug
build succeeded. Swift validation used the Command Line Tools toolchain with
workspace-local temporary, module-cache, and SwiftPM paths. These checks do not
exercise macOS focus acquisition, Accessibility hit testing, actual event
delivery, or locked-session operation. No live desktop input was attempted and
the installed bundle was not rebuilt or replaced during this review.

## Live desktop

Permission status and allowed-application discovery are checked separately from
input. A successful build or a mock adapter is not proof of click/type control.
LaunchServices launch was verified to preserve the independent helper's granted
Accessibility identity; direct shell launch inherited the terminal's identity.
An earlier PID-targeted event implementation returned success without changing
Calculator's display. Foreground event routing, hit-test ownership checks, and
post-event permission preflight replaced it.

After the user removed and re-added the installed app in Accessibility, the
helper reports Accessibility, event-posting, and Screen Recording available.
Read-only TCC diagnostics identified an obsolete signing requirement on the old
entry. No TCC records were modified by the bridge or assistant.

Live verification on the unlocked Intel Mac succeeded:

- Clicked the observed Calculator 7 button and verified its Accessibility value.
- Ran the real MCP smoke test: digit/Return keys and Unicode `+` produced 42.
- Received a PNG window screenshot through MCP and visually confirmed 12+30=42.

The smoke test previously assumed `shift+equal` produced `+`; on this keyboard
layout it did not. It now types the literal Unicode operator and has a regression
test for this non-US layout case. The installed helper was not rebuilt for this
correction, preserving permissions. Its release binary predates the source-only
foreground-policy extraction described above.

## Background supervisor

Read-only real account quota requests succeed using existing Codex ChatGPT
sign-in, without reading credential files. The LaunchAgent was installed and
loaded, with a successful scheduled read-only tick and 60-second interval. Initial
work is deferred until the account-reported five-hour reset; every run rechecks
both account windows. Source tests verify the lifetime three-credit budget,
durable UUID reservations, uncertain retries, and scheduled-time preservation
after account errors.

No real reset credit was consumed. The first scheduled model worker completed
the foreground-policy review, saved its thread ID, and returned a blocked
outcome. Exact-thread resumption and real redemption remain unverified; their
transport and lifecycle are tested with fake subprocesses.

## Locked Use

Not implemented or verified. See [Phase 2](docs/locked-use.md).

## Compatibility diagnostic — 2026-10-15

The separate independently signed x86_64 diagnostic builds and verifies.
The installed Phase 1 executable is unchanged: SHA-256
`7bab5305979b7407a0a0a52ea4121164b71f6b4c75596746f846e57292824b82`,
code-directory hash `1ecefd17f0d56f2ad33a0661492f0c6ac75dde04`.
No permissions were requested or changed.

A1 uses real Unix sockets but fake clocks/session events and failure fixtures.
A2 imports the hash-pinned installed client from ChatGPT 26.1007.71326 (20398),
negotiates IPC-5 and observes `-10011` on a synthetic Calculator policy request;
no app content is accessed. Three consecutive A2 runs passed after an earlier
unexplained generic failure. A3 is blocked: no eligible actual-host provider
route is established. No host override or restart was attempted. Phase 2A
remains partial. See the [runbook and limits](docs/compatibility.md), including
cold-start uncertainty. No live lock/sleep/wake or unlock test was performed.
