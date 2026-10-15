# Validation

This document separates executable tests from live desktop evidence.

## Automated

- Python protocol, policy, native transport, stdio, and supervisor tests: 58 passing.
- Swift policy, session, deadline, coordinate, and keyboard checks: 41 passing.
- Native debug/release build: successful on x86_64 with Swift 6.
- Installed independent bundle: strict code-signature verification successful;
  executable matches the release artifact.

## Live desktop

Permission status and allowed-application discovery are checked separately from
input. A successful build or a mock adapter is not proof of click/type control.
LaunchServices launch was verified to preserve the independent helper's granted
Accessibility identity; direct shell launch inherited the terminal's identity.
An earlier PID-targeted event implementation returned success without changing
Calculator's display. Foreground event routing, hit-test ownership checks, and
post-event permission preflight replaced it.

The final ad-hoc-signed rebuild reports Accessibility, event-posting, and Screen
Recording permission unavailable. The live smoke test exits with status 2 without
sending input in this state. **Live input and screenshots remain unverified**
until the user grants permissions again. Do not interpret automated tests as a
completed Phase 1 acceptance test.

## Background supervisor

Read-only real account quota requests succeed using existing Codex ChatGPT
sign-in, without reading credential files. The LaunchAgent was installed and
loaded, with a successful scheduled read-only tick and 60-second interval. Initial
work is deferred until the account-reported five-hour reset; every run rechecks
both account windows. Source tests verify the lifetime three-credit budget,
durable UUID reservations, uncertain retries, and scheduled-time preservation
after account errors.

No real reset credit was consumed. Actual model-worker execution and thread
resumption have not yet run; their transport and lifecycle are tested with fake
subprocesses. Real redemption semantics remain subject to the account service.

## Locked Use

Not implemented or verified. See [Phase 2](docs/locked-use.md).
