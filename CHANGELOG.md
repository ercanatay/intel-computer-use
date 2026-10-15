# Changelog

Notable development changes are recorded here. No tagged or packaged release
has been published yet; the current project version is a development build.

## Unreleased

### Added

- Public A3 integration tracker with a bounded A2 reproduction, upstream
  references and explicit real-host route evidence, approval and restoration gates.
- Separate independently signed denial-only IPC-5 diagnostic bundle with strict
  bounded parsing, kernel peer evidence and real-session checks.
- Optional hash-pinned installed-client A2 harness with private readiness,
  sanitized reports and owned child-group cleanup; 178 compatibility checks
  and fifteen optional Node-harness regressions. No vendor code redistribution.
- Compatibility runbook: A1/A2 observed, A3 blocked; Phase 2A remains partial
  and does not enable Locked Use.
- Independent Swift native helper for Intel Macs running macOS 14 or later.
- Dependency-free Python MCP server with app/window discovery, Accessibility
  snapshots, window screenshots, clicking, Unicode typing, key chords, and scrolling.
- Exact application allowlists, protected targets, window ownership checks,
  foreground/session checks, secure-field filtering, and request deadlines.
- Read-only diagnostics for missing official Computer Use and Locked Use components.
- Local build/install scripts, MCP configuration example, and macOS permission setup.
- Optional quota-aware background supervisor using existing Codex ChatGPT sign-in.
  Five-hour exhaustion waits for a natural reset; weekly exhaustion may use at
  most three earned reset credits in total, with durable idempotency reservations.
- Python integration/regression tests, Swift guard checks, and GitHub Actions CI.
- Public GitHub repository accepting community issues and pull requests.
- Draft English architecture for an independently signed Intel compatibility
  layer, with diagnostic-only interoperability, authenticated-task, and isolated
  locked-use gates. The complete locked-use layer remains unimplemented.
- Diagnostic-only Phase 2A implementation plan with explicit interfaces,
  red-green checks, private transport, peer evidence, bounded lifecycle, and
  separate A1/A2/A3 acceptance. The design is approved for planning; execution
  was subsequently approved for native sequential diagnostic-only execution.

### Changed

- Extracted foreground-process and pointer-window ownership policies into
  independently testable guards, adding twelve native regression checks.
- Recorded successful live Calculator click, keyboard/Unicode input, and PNG
  screenshot verification separately from automated test results.
- Compared the same-version official Apple Silicon distribution read-only;
  documented six ARM64-only components, verified signatures, the installer and
  IPC-5 contracts, and the authorization plugin's service-identity check.
- Recorded seven passing throwaway client-characterization checks separately
  from the maintained suite; no real native service or unlock was exercised.

### Fixed

- Launch the native app through LaunchServices so its macOS permissions are
  attributed to the independent helper rather than the launching terminal.
- Type the Calculator smoke test's `+` operator as Unicode instead of assuming
  the US-layout `shift+equal` shortcut; add a non-US-layout regression test.
- Document how to refresh a stale Accessibility entry after an ad-hoc-signed rebuild.
- Preserve scheduled start/reset waits after transient account quota errors.

### Security and limitations

- The bridge does not patch ChatGPT, retain OS passwords, alter TCC records,
  disable screen-lock authentication, or purchase quota credits.
- LaunchServices transport uses private temporary request/response files;
  forced termination can leave those files behind. Avoid sensitive windows.
- Native desktop control currently requires an unlocked macOS session.
- ChatGPT's official Locked Use setting is **not enabled** by this project.
  That separate Phase 2 integration remains planned and unverified; see
  [the roadmap](ROADMAP.md) and [integration requirements](docs/locked-use.md).
- Builds are intended for local development and are not notarized releases.
