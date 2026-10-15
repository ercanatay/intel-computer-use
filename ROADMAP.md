# Roadmap

## Phase 1 — Native app control

- [x] Independent Swift helper and dependency-free Python MCP server.
- [x] Explicit app allowlist, protected targets, session and focus checks.
- [x] App/window discovery, Accessibility inspection, window screenshot, input.
- [x] Local bundle builder, installer, status, and diagnostic command.
- [ ] Live Calculator verification with user-granted macOS permissions.

## Background continuation

- [x] Read-only five-hour and weekly account monitoring with real reset timestamps.
- [x] Natural-reset waits, bounded resumable jobs, and single-worker exclusion.
- [x] At most three lifetime earned resets, only on exhausted weekly quota.
- [x] Private persisted state and macOS LaunchAgent setup.
- [x] Scheduled activation and live read-only LaunchAgent tick.
- [ ] First actual bounded model job and exact-thread continuation verification.

## Phase 2 — Locked Use

- [x] Read-only vendor payload and installer diagnostics.
- [x] Document missing-component evidence and integration requirements.
- [ ] Obtain a supported Intel-compatible unlock implementation and trust contract.
- [ ] Validate trusted-turn authorization, display shielding, physical-input relock,
  manual-unlock fallback, and login-keychain behavior on a disposable test account.
- [ ] Enable locked-session operation only after the complete path is verified.

The phase order is intentional. Native app control and macOS authentication
integration are separate deliverables; neither is used as proof of the other.
