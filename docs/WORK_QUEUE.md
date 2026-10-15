# Continuation queue

This file is the handoff for bounded background work. Read `ROADMAP.md` and
`VALIDATION.md` first. Do not interpret a quota reset as permission to invent
new project scope or repeatedly retry an external blocker.

## Next useful task

Review the native foreground-input guards and add focused regression coverage
where it can be tested without controlling the user's desktop. Verify the
Python protocol and supervisor suite and the Swift guard executable. Record
new evidence in `VALIDATION.md`; report concrete findings rather than assuming
that compilation proves live behavior. Preserve any uncommitted user work.

## Human-dependent validation

Live input needs user-granted Accessibility permission. Window capture also
needs Screen Recording. The independent helper must report both permissions;
do not change TCC, click permission dialogs, or grant permissions automatically.
Use only Calculator for the existing smoke test while the session is unlocked.
Do not open private documents or inspect other apps to obtain test evidence.

## Phase 2 boundary

The official Locked Use toggle is not repaired by this independent server.
The installed vendor unlock service/installer and a supported Intel trust
contract are missing. See `docs/locked-use.md`. Do not install an authorization
plugin, weaken authentication, store an OS password, patch ChatGPT, or fabricate
an installer response. Once useful local work is exhausted, return `blocked`
with that specific external dependency instead of spending quota indefinitely.

## Publication

Background jobs do not commit or publish changes. A human or the interactive
assistant reviews and publishes verified source. Never read Downloads, token
files, credential stores, or private CLI session transcripts.
