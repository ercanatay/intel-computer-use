# Intel Compatibility Layer Design

Status: **Draft for user review. Not implemented.**

## Intent and approval boundary

Investigate an independently implemented, independently signed Intel service
that can communicate with the real ChatGPT desktop Computer Use client without
patching ChatGPT or weakening macOS authentication. The eventual goal remains
useful Computer Use while locked, not merely making a settings toggle look on.

The user approved preparing this English design. That approval does not approve
an implementation plan, installation, app restart, privileged changes, or a live
unlock experiment. Written-design review comes next; implementation planning
follows only after approval. Publication does not imply feature availability.

This document extends the original design's Phase 2 research direction. All
existing Phase 1 guards remain unchanged. Its reviewed implementation scope is
limited to **Phase 2A**, described below. Phases 2B and 2C are separate future
designs, not authorization to implement a full unlock stack.

## Evidence and uncertainty

[The investigation](../../locked-use.md) records a same-version comparison of
ChatGPT 26.1007.71326 (20398), the missing Intel payload, six signed ARM64-only
reference components, and the original authorization plugin's OpenAI peer-identity
requirement. That original plugin cannot simply accept our independently signed
service. No vendor binaries or proprietary source are distributed by this project.

The installed JavaScript client uses `CodexComputerUseIPC-5`. Seven throwaway
in-memory checks characterized framing, version negotiation, metadata forwarding,
deadlines, Unicode, and failure propagation. They did not contact a real service
or prove that the desktop host accepts an independent provider.

Unknowns are explicit acceptance gates: real-host routing without vendor-path
replacement; host acceptance of our independent identity; authenticated task
lifecycle; and later, safe authorization-plugin and guardian integration. None
is treated as available merely because its wire fields have been observed.

## Approaches considered

| Approach | Benefit | Limitation | Decision |
| --- | --- | --- | --- |
| Independent IPC compatibility layer | Can test Intel interoperability without changing the vendor app | Host routing and task authority remain unproven | Selected, diagnostic-only first |
| Vendor-provided Intel implementation or documented provider interface | Preserves a supported integration path | Requires an external deliverable | Keep as a fallback and upstream request |
| Patch identity checks or emulate installer success | Might change an intermediate UI state | Does not establish trusted tasks or safe unlocking | Excluded |

## Phase boundaries

### Phase 2A: Non-actuating interoperability

Build a small Swift 6 diagnostic service for macOS 14+ and a test harness. It
supports IPC version negotiation and deterministic request rejection only.
It cannot discover apps, read AX content, capture windows, launch targets, send
input, change permissions, or unlock. It has no executor connection to the
existing native helper and requires no Accessibility or Screen Recording grant.

Success means a request from the **actual desktop host** reaches this service
through a documented, reversible route while macOS is unlocked, with our real
identity visible and no vendor component replaced. Harness-only interoperability
is a useful intermediate result, not Phase 2A completion.

### Phase 2B: Authenticated task lifecycle

Only after 2A succeeds, prepare a separate design for authenticating the expected
host/relay and proving task start, approval, completion, cancellation, and
revocation. A kernel-confirmed process identity and a JSON turn identifier are
different evidence; both process authentication and task authorization are needed.
No desktop action is enabled by this document. A later unlocked-only executor
adapter needs its own reviewed scope, app-approval contract, and acceptance tests.

### Phase 2C: Locked-session integration

Only after 2B succeeds, prepare a separate authorization and guardian design with
display shielding, physical-input relock, bounded authorization, crash handling,
and a tested removal path. It needs separate approval and a disposable macOS
test account. No authorization plugin or privileged installer is part of 2A.

## Phase 2A architecture

The new service is separate from `Intel Computer Use.app`. Do not rebuild,
re-sign, replace, or reinstall that working app to develop this experiment.
The proposed identity is `io.github.ercanatay.intel-computer-use.compat`.
It must never claim an OpenAI bundle or team identity.

| Unit | Responsibility | Explicitly cannot do |
| --- | --- | --- |
| `CompatibilityProtocol` | Decode bounded frames and validate the IPC-5 JSON-RPC envelope | Read files, connect to desktop APIs, or authorize a task |
| `CompatibilityService` | Own one private Unix socket; negotiate version; deny operational requests | Delegate requests to `NativeHelper` or install persistence |
| `PeerIdentityInspector` | Obtain kernel peer credentials and inspect running-code identity where supported | Trust a caller-supplied PID, path, team string, or metadata blob |
| Compatibility harness | Exercise our service with synthetic fixtures and the installed vendor client code | Masquerade as a real approved ChatGPT task |
| Evidence report | Record which test tier actually ran, version, hashes, and denial reasons | Store credentials, raw turn metadata, captures, or private content |

Proposed source locations are `Sources/CompatibilityProtocol/`,
`Sources/CompatibilityService/`, and `Tests/CompatibilityChecks/`, with a
dedicated executable-check target matching the existing CLT-compatible test
pattern. Future Python CLI integration is not required for 2A. No package target,
runtime command, or launch agent is added by this design-only change.

### Data flow and denial policy

1. An explicit local invocation creates a fresh private runtime directory and
   socket. The process runs as the current user, never root.
2. The listener obtains peer credentials from the OS. A different user or an
   unavailable peer identity causes connection rejection. Same-user access is
   not task approval; a same-user diagnostic peer can negotiate a version only.
3. The codec reads a complete bounded frame, then validates JSON-RPC shape,
   method, request identifier, API version, and any request deadline.
4. A valid `ping` returns only `serverApiVersion: CodexComputerUseIPC-5`.
   This advertises protocol support, never successful installation or unlocking.
5. A well-formed operational `request` returns `noActiveSession` (`-10011`).
   Neither supplied metadata nor a successful peer-identity inspection can
   change that result in 2A. Unknown methods return `-32601`, invalid request
   envelopes return `-32600`, and an incompatible API returns `-10013`.
6. Disconnect, timeout, lock, sleep, or shutdown closes the connection and
   discards pending work. There is no replay queue and no automatic restart.

Request IDs must be non-negative JSON safe integers, never booleans. Valid
notifications receive no reply and cause no operation; malformed input without
a usable ID closes the transport. The later plan must specify exact method
schemas and parser behavior before code. The service handles one client and one
request at a time, rejects duplicate in-flight IDs, and does not support JSON-RPC
batches. It closes malformed or oversized transports rather than guessing a
compatible request.

### Resource bounds

- Four-byte little-endian frame length and UTF-8 JSON; reject lengths above
  8 MiB before allocating the claimed payload.
- At most one buffered frame, with incremental handling of concatenated frames;
  reject nesting deeper than 32 levels and malformed UTF-8 or JSON.
- Frame receipt and idle connections expire after five monotonic seconds.
- An operational request needs a finite future wall-clock deadline. Clamp its
  processing budget to five monotonic seconds; expiry always denies the request.
- The diagnostic service has a maximum lifetime of five minutes. Bounds are
  project limits, not claims about vendor defaults. Expiry never triggers unlock.

## Peer identity and signing

Use kernel-provided peer identity, not an environment variable or a self-reported
field. Investigate an audit-token-based dynamic-code lookup with macOS Security
APIs and an explicit code-signing validity check. Availability and failure modes
must be verified on the deployment target; missing evidence fails closed. A
process name, bundle identifier, filesystem path, PID alone, parent process name,
or a signed ancestor alone is insufficient task authorization.

The service and controlled harness use our own signing identity. Ad-hoc signing
may support isolated development and hash-pinned fixtures; it is not proof of a
trusted vendor process and is not a production trust policy. Never enumerate or
export private keys or claim OpenAI's team identifier. A stable release-signing
identity and distribution policy remain outside this diagnostic milestone.

Process identity, signature validity, expected relay relationships, host-approved
task authority, and per-app approval must ultimately be checked independently.
A verified signature alone must not mint a task capability. The later broker
starts with no authority; observed metadata cannot transition it to authorized.
Stale, canceled, completed, disconnected, or unverifiable tasks must be denied.

## Routing experiment and evidence tiers

| Tier | Experiment | What it proves |
| --- | --- | --- |
| A1 | Our codec and diagnostic service with synthetic peers | Our implementation obeys its local contract |
| A2 | Installed vendor JavaScript client in an isolated harness, routed to our private socket | That client version can speak to our service; not desktop integration |
| A3 | Actual ChatGPT desktop task reaching the service through an existing, reversible provider route | Real-host diagnostic routing and response compatibility for that release |

Do not relabel a shell-launched harness, copied metadata, or synthetic IDs as A3.
The known service-path environment names are research leads, not proof that the
packaged desktop permits their use. Inspect route eligibility read-only first.
No environment override, feature flag, or user configuration is changed until
the concrete route and rollback are reviewed and explicitly approved.

The route must keep our app identity and private socket, leave the vendor bundle,
canonical helper paths, app-group sockets, and authorization socket untouched,
and restore prior behavior without overwriting user files. No host restart or
private data access is implicit in approving a test. If those constraints cannot
be met, report A3 as blocked with the specific observed constraint. Do not patch
the host or substitute a successful-looking installer to make the test pass.

## Runtime, privacy, and rollback

Use a fresh directory under the current user's temporary root, mode `0700`, and
a socket with mode `0600`. Validate Unix socket path length, ownership, file type,
and symlink safety before binding. An occupied path is an error, not a reason to
unlink it. Do not bind to a vendor socket or expose TCP/HTTP endpoints.

Reports contain test tier, app/client version, source hashes, coarse identity
verification outcomes, request type, and error category only. Do not log request
bodies, raw metadata, session/thread identifiers, signing secrets, usernames,
screenshots, or AX contents. Runtime artifacts stay ignored under `dist/` or in
the private temporary directory; upstream binaries are never published.
Request-type logging uses a fixed known-name allowlist; unknown or malformed
values are recorded only as a constant category, never as caller-supplied text.

Exit closes only the service's own connections and removes only its verified
owned runtime artifacts. A crash may leave a private directory; a later cleanup
must verify ownership and never follow symlinks. No launchd entry, login item,
configuration migration, TCC change, authorization-database edit, or privileged
removal procedure is needed for 2A. The quota supervisor stays paused; a quota
reset does not authorize implementation, live routing, or automatic retries.

## Threat model and exclusions

Treat app content, request bodies, and all metadata as untrusted. Consider local
same-user impersonators, replayed frames, PID reuse, relay confusion, stalled
clients, malformed input, oversized payloads, and crashes. Root/kernel compromise
is outside the model, but is never a reason to weaken ordinary login security.

Do not disable SIP, AMFI, Gatekeeper, screen-lock authentication, or certificate
validation. Do not forge signing identities, retain OS passwords, change managed
policy, bypass approvals, install a permissive authorization mechanism, or inject
code into ChatGPT. Do not reuse the original unlock plugin with a spoofed peer.
Do not automate ChatGPT or security dialogs to approve this project itself.

## Acceptance and stopping criteria

The implementation plan must include these checks before claiming 2A complete:

- Framing: fragmented/coalesced frames, Unicode byte lengths, size/depth limits,
  invalid UTF-8/JSON, malformed envelopes, duplicate IDs, and unsupported methods.
- Transport: peer-credential failure, wrong user, path collision/symlink refusal,
  stalled input, disconnect, cleanup, concurrency bounds, and lifetime expiry.
- Authority: forged, missing, valid-looking, stale, and replayed metadata all
  receive operational denials. No target app opens, capture occurs, or input is
  sent, including after any successful `ping`.
- Lifecycle: actual lock, unknown session state, sleep/wake, timeout, process
  restart, and host disconnect never preserve an authorization or queued action.
- Compatibility: record A1, A2, and A3 separately, including failed evidence.
  A3 needs an observed real-host request and denial in an unlocked, user-approved
  test session; no mock identity or fabricated approval may satisfy it.
- Regression: run the existing project suite and verify that the installed
  Phase 1 app and its permission identity are unchanged.

Stop and report the evidence if real routing needs identity spoofing, vendor-path
replacement, app patching, private credentials, an unavailable host extension,
or weakened protections. Stop at a missing task-authority contract before 2B;
do not turn request metadata into permission. Future unlock work also stops
without a disposable account and a reviewed rollback procedure.

This design creates no claim that official Locked Use can be enabled. Even A3
success would prove diagnostic routing only, not task authorization, app control,
display protection, password/keychain behavior, or safe temporary unlocking.

## Review checklist

- [ ] User approves this written design and its diagnostic-only scope.
- [ ] A separate Phase 2A implementation plan is written and approved.
- [ ] A concrete real-host route and rollback receive approval before use.
- [ ] Phase 2B and 2C receive separate designs and approvals if earlier gates pass.

No live compatibility implementation or unlock test has been performed under
this design. The next deliverable after written-design approval is the 2A
implementation plan, not an authorization plugin.

## Sources

- [Local read-only evidence and binary hashes](../../locked-use.md).
- [Original project design](2026-10-15-intel-computer-use-design.md).
- [OpenAI Computer Use: Locked Use](https://learn.chatgpt.com/docs/computer-use#locked-use):
  the feature requires active trusted work, limited authorization, display
  shielding, and relock on local input; not a general-purpose remote unlock.
- [Apple Code Signing Services: guest attributes](https://developer.apple.com/documentation/security/guest-attribute-dictionary-keys)
  and [dynamic guest-code lookup](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)):
  API research references, not evidence that the proposed peer-authentication
  implementation already exists or works on this host.
