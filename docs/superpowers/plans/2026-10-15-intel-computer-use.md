# Intel Computer Use Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver native app control on Intel macOS, then establish the remaining Locked Use requirements.

**Architecture:** A Python MCP stdio server validates requests and invokes a signed Swift helper. The helper uses AppKit, Accessibility, Core Graphics, and ScreenCaptureKit. The official ChatGPT installation remains untouched.

**Tech Stack:** Python 3.9+, Swift 6, macOS 14+, standard libraries only.

**Spec:** ../specs/2026-10-15-intel-computer-use-design.md

## Global Constraints

- All project material is in English.
- Explicit bundle-ID allowlist; unknown or locked sessions fail closed.
- No vendor binary changes, credential files, authorization-database changes, or automatic OS permission grants.
- Phase 1 does not claim to enable the official Locked Use setting.

## Review Focus

- Invalid JSON, notifications, initialization order, and unexpected tool arguments.
- Coordinate bounds, booleans masquerading as numbers, and Unicode input.
- Wrong-process windows, focus changes, and lock-state transitions during input.
- Missing native helper, denied macOS permissions, and subprocess timeouts.
- Installer idempotence and truthful Phase 2 diagnostics.

## Task 1: Native guardrails

- [ ] Add failing Swift tests for app policy, session state, coordinates, and key chords.
- [ ] Implement BridgeCore and run swift test.

## Task 2: MCP server and doctor

- [ ] Add failing Python tests for lifecycle, validation, subprocess failure, and vendor component fixtures.
- [ ] Implement the server, native adapter, and read-only diagnostics; run unittest.

## Task 3: Native application operations

- [ ] Implement the native helper against the tested guardrails.
- [ ] Build on Intel, verify the executable architecture, and run live status.
- [ ] Verify allowed-app listing and Calculator control where permissions permit.

## Task 4: Packaging and publication

- [ ] Add a signed per-user bundle builder, reversible setup, example MCP configuration, English README, and CI.
- [ ] Run the complete test suite, integration smoke test, release build, and final review.
- [ ] Create the GitHub repository and publish the verified source.
- [ ] Record Phase 2 findings and the precise remaining blocker.
