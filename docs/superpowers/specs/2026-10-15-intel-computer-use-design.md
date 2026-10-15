# Intel Computer Use Design

## Intended outcome

Provide working, independently implemented native desktop tools on Intel Macs
whose ChatGPT/Codex installation lacks the official Computer Use service.
All project material is in English. The project is not affiliated with OpenAI.

## Phase 1: Native app control

Implement an independent, dependency-free Python 3.9+ MCP stdio server and a
Swift 6 native helper for macOS 14+. Support status, application discovery,
opening an explicitly allowed application, window discovery, Accessibility
inspection, window screenshots, clicks, Unicode typing, keyboard chords,
and scrolling. Use public macOS frameworks and compile for the host architecture.

Keep permissions explicit: the server reads an exact application bundle-ID
allowlist from its launch arguments; no tool can expand that allowlist.
All observation and control of a target app require allowlisting. Never target
loginwindow, ChatGPT/Codex, Terminal, security settings, or credential managers.
Stop desktop operations when the session is locked, inactive, or unknown.
Validate the owning process, window identity, coordinates, and foreground state
before input. Never read, store, or handle an OS account password.

Use a separate app identity. Do not impersonate the OpenAI helper, replace
vendor binaries, patch app.asar, reset TCC, change SIP, or edit the authorization
database. Install under the user's Applications directory. Encode captures in
memory; LaunchServices request/response transport uses private temporary files
(directory 0700, files 0600), removed after each operation. Forced termination can
leave temporary files. No listener, telemetry, API key, or third-party dependency.

## Phase 2: Locked-use feasibility

Add a read-only compatibility doctor for the vendor app, missing helper,
architecture, and optional authorization installer. Document what can be
established and what requires OpenAI's signed implementation. A diagnostic
must distinguish file presence from working Locked Use. A passing Phase 1
test must never be presented as a Locked Use fix.

Do not simulate support with an always-successful installer, disable the Mac's
screen lock, collect passwords, or grant unverified local processes unlock rights.
If a supported Intel helper is unavailable, report Phase 2 as unresolved with
concrete evidence and a clear integration contract.

## Verification

Use Swift tests for policy, session guards, point validation, and key parsing.
Use Python unittest for JSON-RPC lifecycle, real stdio transport, tool schemas,
argument validation, policy, subprocess error handling, and diagnostic fixtures.
Run a release build on this Intel host, inspect the architecture and signature,
and exercise read-only native status. Live input verification uses Calculator
only and requires macOS permission; report any permission blocker explicitly.

## Distribution

Create a GitHub repository under ercanatay after local verification. Publish
source, setup scripts, English documentation, tests, and CI; exclude local
captures, credentials, user paths, and machine-specific diagnostic output.
