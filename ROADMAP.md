# Roadmap

## Phase 1 — Native app control

- [x] Independent Swift helper and dependency-free Python MCP server.
- [x] Explicit app allowlist, protected targets, session and focus checks.
- [x] App/window discovery, Accessibility inspection, window screenshot, input.
- [x] Local bundle builder, installer, status, and diagnostic command.
- [x] Live Calculator click, keyboard/Unicode calculation, and PNG verification.

## Background continuation

- [x] Read-only five-hour and weekly account monitoring with real reset timestamps.
- [x] Natural-reset waits, bounded resumable jobs, and single-worker exclusion.
- [x] At most three lifetime earned resets, only on exhausted weekly quota.
- [x] Private persisted state and macOS LaunchAgent setup.
- [x] Scheduled activation and live read-only LaunchAgent tick.
- [ ] First actual bounded model job and exact-thread continuation verification.

## Phase 2 — Locked Use

Target: enable ChatGPT's official **Locked Use** ("Use while locked") setting on
Intel Macs through a verified, supported integration. Independent MCP control
does not activate that setting. This is planned work, not an available feature.

- [ ] Verify that the official setting can be enabled and persists on an Intel Mac.
- [x] Read-only vendor payload and installer diagnostics.
- [x] Document missing-component evidence and integration requirements.
- [x] Compare the same-version public Apple Silicon payload read-only; verify
  six ARM64-only native components and their signatures.
- [x] Characterize the installed IPC-5 client with seven isolated, in-memory
  checks; confirm the vendor authorization plugin's peer-identity check.
- [ ] Obtain a supported Intel-compatible unlock implementation and trust contract.
- [ ] Validate trusted-turn authorization, display shielding, physical-input relock,
  manual-unlock fallback, and login-keychain behavior on a disposable test account.
- [ ] Enable locked-session operation only after the complete path is verified.

The phase order is intentional. Native app control and macOS authentication
integration are separate deliverables; neither is used as proof of the other.

## Current handoff — 2026-10-15

The foreground-input review and live Phase 1 acceptance are complete. The full
suite passes 59 Python tests and 53 Swift checks; the native debug build passes.
See `VALIDATION.md` for the installed-binary/source distinction and live evidence.

Remaining acceptance work is blocked by external dependencies:

- The first scheduled model job ran and saved its thread ID. Exact-thread
  continuation verification remains pending. Background jobs must not launch
  other workers or consume credits themselves.
- Phase 2 has a verified blocker for reusing the original authorization plugin:
  it checks the service's OpenAI signing and team identifiers. A supported Intel
  payload is still missing. A clean-room replacement is not proven impossible,
  but its complete trust and task-lifecycle contract remains unverified and needs
  a separately reviewed design. The isolated IPC experiment and native guard
  tests do not establish locked-session support.
