# Intel Compatibility Phase 2A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Native, sequential execution is recommended here; no workers are authorized by this document alone.

**Goal:** Build a non-actuating Intel IPC-5 diagnostic service, prove isolated interoperability, and assess real-host routing without modifying ChatGPT or enabling Locked Use.

**Architecture:** Keep a bounded wire-protocol library separate from a macOS runtime library and a minimal executable. Every operational request is denied; there is no native-helper adapter. Report synthetic tests, installed-client harness results, and actual desktop-host integration as different evidence tiers.

**Tech Stack:** Swift 6 toolchain, the package's existing Swift 5 language mode, macOS 14+, Foundation, Darwin, Security, CoreGraphics, IOKit, and AppKit. An optional Node.js 20+ built-in-only harness imports the user's installed client locally; no npm dependencies or vendor redistribution.

**Spec:** [Approved compatibility design](../specs/2026-10-15-intel-compatibility-design.md).

**Status:** Approved for native sequential execution on 2026-10-15. Tasks 1–5 implemented and locally verified; Task 6 records A3 blocked with no eligible actual-host route established. Phase 2A remains partial. No host-route change, restart or live unlock experiment is approved by this plan. See [the runbook](../../compatibility.md).

**Execution notes:** Native sequential work preserves the unborn checkout; no
local commits or branches. Readiness also accepts a same-UID connected Unix
stream because Node's built-in pipe is socketpair-backed on macOS. The harness
uses existing `plutil`/`getconf` OS tools for version and private-temp checks,
not npm dependencies. Final review is explicitly a self-review, respecting the
selected no-subagent method; independent review is still desirable.

## Global Constraints

- Phase 2A supports IPC version negotiation and deterministic request rejection only.
- No app discovery, AX reads, captures, app launches, input, permission requests, or unlocking.
- Use our identity `io.github.ercanatay.intel-computer-use.compat`; never an OpenAI identity.
- Do not rebuild, re-sign, replace, or reinstall the working `Intel Computer Use.app`.
- Do not modify ChatGPT, vendor helper paths, vendor sockets, managed policies, TCC, or authentication.
- Private runtime directory `0700`; private Unix socket `0600`; no TCP/HTTP or persistence.
- Maximum frame payload 8 MiB, nesting depth 32, frame/idle budget five monotonic seconds, service lifetime five minutes.
- One client and one pending request; no batches, replay queue, automatic restart, or task authorization.
- Never log raw metadata, identifiers of user tasks, request bodies, account information, captures, or credentials.
- Keep the quota supervisor paused. No Downloads/token/credential/transcript reads or background publication.
- No local branch, worktree, reset, staging, or commit is implicit in plan approval; preserve the existing unborn local checkout and its working files.

## Review Focus

- Wall-clock jumps and enormous deadlines must never extend the monotonic budget; Task 2 pins this.
- Boolean/fractional IDs and ambiguous duplicate keys must not change routing or authority; Task 2 pins this.
- Socket path substitution and cleanup must not remove another file; Task 3 pins this.
- Short writes, disconnects, and bursts of coalesced frames must stay bounded; Tasks 1 and 4 pin this.
- Missing audit/signature evidence and convincing-looking metadata must never imply an approved task; Tasks 3 and 5 pin this.

---

## File and Target Map

| Location | Responsibility |
| --- | --- |
| `Sources/CompatibilityProtocol/FrameCodec.swift` | Incremental length-prefixed framing and fixed limits |
| `Sources/CompatibilityProtocol/BoundedJSON.swift` | Strict, depth-bounded JSON values; preserve numeric tokens |
| `Sources/CompatibilityProtocol/DiagnosticSession.swift` | Envelope validation, budgets, version response, unconditional operational denial |
| `Sources/CompatibilityService/RuntimeDirectory.swift` | Private endpoint creation and ownership-safe cleanup |
| `Sources/CompatibilityService/PeerIdentityInspector.swift` | Kernel credentials and optional dynamic-code evidence |
| `Sources/CompatibilityService/SessionObserver.swift` | Read-only session state and sleep/lock notifications |
| `Sources/CompatibilityService/DiagnosticServer.swift` | Bounded Unix listener and connection lifecycle |
| `Sources/CompatibilityCLI/main.swift` | Production CLI wiring with real OS providers only |
| `Tests/CompatibilityChecks/` | CLT-compatible executable checks and test-only fixtures |
| `scripts/compatibility_probe.mjs` | Optional installed-client harness, always labeled A2 |
| `python_tests/test_compatibility_probe.py` | Optional-harness privacy, cleanup, and missing-dependency regressions |
| `resources/compatibility/Info.plist`, `scripts/build-compatibility.sh` | Separate diagnostic app bundle; never installs it |
| `docs/compatibility.md` | Runbook, evidence tiers, route decision, rollback |

Add library targets `CompatibilityProtocol` and `CompatibilityRuntime` (the
latter's path is `Sources/CompatibilityService`, dependencies `BridgeCore` and
`CompatibilityProtocol`). Add executable targets/products `CompatibilityCLI` /
`intel-computer-use-compat` and `CompatibilityChecks` / `compatibility-checks`.
The checks depend on both libraries. Do not use XCTest or Swift Testing, absent
from this host's CLT distribution. Do not link `NativeHelper` into these targets.

## Execution Preflight

- [x] Obtain written plan approval and the execution-method choice. Check applicable `AGENTS.md` files again. Read the spec and this plan together.
- [x] Record `git status --short` and `git rev-parse --verify HEAD`; a missing local HEAD is the known baseline, not permission to recreate history or overwrite files. Ask before any requested worktree/branch operation.
- [x] Run `bash scripts/test.sh`. The last verified baseline was 59 Python tests, 53 Swift checks, and a native build; record the fresh result rather than hard-coding success.
- [x] Record only the installed helper's executable SHA-256 and code-directory hash, using its known app path. Do not launch it, enumerate signing keys, or inspect account files.

Use a red-green test cycle within every task. The executable check runner accepts
one named group (`framing`, `protocol`, `runtime`, or `server`) and defaults to
all groups. Helpers live only in `Tests/CompatibilityChecks/CheckSupport.swift`:
`expect(_ condition: Bool, _ message: String) throws` and
`expectFailure(_ operation: () throws -> Void) throws`. A failed check exits
nonzero; success prints a count and group. No test framework dependency is added.
Task checkpoints mean reviewable local diffs, not automatic commits or publication.
Verification commands must exit `0`: the new runner prints
`Passed <count> compatibility checks (<group>).`, Python discovery ends in `OK`,
and Swift builds report completion. Harness exit `2` is a skipped/blocked result,
never a passing live check. Record the actual counts rather than inventing them.

### Task 1: Bounded Frame Codec

**Files:** Create `FrameCodec.swift`, `Tests/CompatibilityChecks/CheckSupport.swift`,
`Tests/CompatibilityChecks/main.swift`, and `Tests/CompatibilityChecks/FrameChecks.swift`;
modify `Package.swift` for the protocol library and check executable initially.

**Interfaces:** `WireLimits.maxPayloadBytes = 8_388_608`;
`FrameCodec.encode(_ payload: Data) throws -> Data`;
`FrameDecoder.init()`;
`FrameDecoder.consume(_ chunk: Data, emit: (Data) throws -> Void) throws`;
`FrameDecoder.bufferedByteCount: Int`. Define `ProtocolFailure: Error` with a
fixed `reason` enum, never input-dependent error text. Initial reasons are
`emptyFrame`, `oversizedFrame`, and `invalidFrame`.

- [x] **Write failing framing checks.** Include these assertions, using real codec calls:

```swift
let payload = Data("Türkçe + 42".utf8)
let encoded = try FrameCodec.encode(payload)
try expect(encoded.count == payload.count + 4, "UTF-8 byte length")
try expect(Array(encoded.prefix(4)) == [13, 0, 0, 0], "Little-endian length")
var decoder = FrameDecoder()
var received: [Data] = []
try decoder.consume(encoded.prefix(3)) { received.append($0) }
try expect(received.isEmpty, "Incomplete header")
try decoder.consume(encoded.dropFirst(3)) { received.append($0) }
try expect(received == [payload], "Fragmented frame")
```

- [x] Add checks for byte-at-a-time input, two coalesced frames, partial next headers, an empty frame, and a header claiming `8_388_609` bytes. Assert oversize rejection before a body allocation and `bufferedByteCount <= 8_388_612`; an `emit` failure stops consumption immediately. Verify the maximum accepted payload boundary separately.
- [x] Run `swift run compatibility-checks framing`; confirm the missing codec fails the tests before implementing it.
- [x] Implement the interfaces with a four-byte header buffer and one bounded payload buffer. Consume input incrementally; do not concatenate an entire untrusted chunk onto pending data. Invoke `emit` per complete frame; do not retain a list of frames.
- [x] Run `swift run compatibility-checks framing`, then `bash scripts/test.sh`. Review only the Task 1 diff and record the checkpoint.

### Task 2: Strict Envelope and Denial-Only Policy

**Files:** Create `BoundedJSON.swift`, `DiagnosticSession.swift`,
`Tests/CompatibilityChecks/ProtocolChecks.swift`; extend the check-runner group map.

**Interfaces:** `JSONValue` cases are `object([String: JSONValue])`,
`array([JSONValue])`, `string(String)`, `number(String)`, `bool(Bool)`, and `null`.
`BoundedJSON.decode(_ payload: Data) throws -> JSONValue` retains number tokens.
`ClockSample` contains `wallUnixMilliseconds: Double` and
`instant: ContinuousClock.Instant`.
`DiagnosticReply` contains `requestID: UInt64`, `payload: Data`, and
`expiresAt: ContinuousClock.Instant`.
`DiagnosticDisposition` is `reply(DiagnosticReply)`, `silent`, or `close`.
`DiagnosticSession.init()`,
`DiagnosticSession.receive(_ payload: Data, clock: ClockSample) -> DiagnosticDisposition`
and `didSendReply(requestID: UInt64) throws` manage one pending reply.
`CloseReason` in this module defines fixed categories `invalidInput`, `busy`,
`duplicateID`, `deadline`, `peer`, `session`, `power`, `lifetime`, `io`, and `shutdown`.
Extend `ProtocolFailure.reason` with `invalidJSON`, `nestingLimit`, `valueLimit`,
`duplicateKey`, and `invalidEnvelope` for deterministic parser checks.

- [x] **Write failing parser/policy checks** with the following exact expectations:

| Check | Assertions |
| --- | --- |
| `pingNegotiatesOnlyVersion` | ID `1`, method `ping`, version `CodexComputerUseIPC-5` returns exactly a JSON-RPC result containing that `serverApiVersion` |
| `operationalRequestsAlwaysDenied` | `request` with each observed request type and missing, forged, fresh-looking, stale, or replayed metadata returns error `-10011`; never a success result |
| `invalidIDsNeverCoerce` | `true`, `null`, negative values, fractions, exponent-form literals, and values above `9_007_199_254_740_991` close the connection; `0` and that maximum integer literal round-trip exactly |
| `strictJSONAndDepth` | Invalid UTF-8, malformed numbers/escapes, trailing JSON, duplicate decoded keys including escaped aliases, and depth `33` fail; depth `32` and brackets inside strings are handled correctly |
| `deadlineBudgetCannotGrow` | A 120-second future deadline has `expiresAt <= sample.instant.advanced(by: .seconds(5))`; expired/non-finite deadlines deny; a later wall-clock jump does not extend this instant |
| `pendingRequestIsNotReplayed` | Receiving an ID again before `didSendReply` closes; a second different outstanding ID closes; acknowledging the reply permits the next sequential request |
| `notificationsAndErrors` | Valid no-ID notifications are silent and side-effect-free; unknown methods return `-32601`, incompatible API `-10013`, and invalid envelopes with a usable ID `-32600` |

- [x] Run `swift run compatibility-checks protocol`; observe failures before adding these types and behaviors.
- [x] Implement a UTF-8 JSON parser with depth measured from root container `1`, decoded-key uniqueness, and a maximum of **16,384 values including containers** (keys are not extra values). This additional plan-level resource bound prevents a shallow array from exhausting memory; test acceptance at 16,384 and rejection at 16,385. Parse numeric tokens without lossy floating-point coercion; IDs accept integer-literal syntax only. Use Foundation's string decoding for quoted string tokens if needed, not a whole-document parser before the depth/value checks.
- [x] Enforce schemas: root object, `jsonrpc == "2.0"`, nonempty method string, optional safe-integer ID, object `params`. `ping.params` requires the exact API string. `request.params` requires the exact API string, nonempty `requestType` string, object `request`, and finite future numeric `deadlineUnixMilliseconds`; optional metadata is ignored as authority. Unknown extra bounded fields are ignored. Invalid input without a usable ID closes, never guesses an ID from text.
- [x] Compute reply expiry once from the monotonic instant, clamped to five seconds; validate an operational wall-clock deadline before replying. Encode fixed messages through Foundation JSON serialization with no request content in errors. Every valid operational request returns `-10011`, regardless of process-signature or metadata appearance. There is no executor or authorization callback.
- [x] Run `swift run compatibility-checks protocol`, `swift run compatibility-checks framing`, and `bash scripts/test.sh`; review the checkpoint.

### Task 3: Private Runtime and Kernel Peer Evidence

**Files:** Create `RuntimeDirectory.swift`, `PeerIdentityInspector.swift`,
`Tests/CompatibilityChecks/RuntimeChecks.swift`; add the `CompatibilityRuntime`
library target and its check dependency to `Package.swift`.

**Interfaces:** `RuntimeDirectory.create(under base: URL) throws -> RuntimeDirectory`,
`socketURL: URL`, `cleanup() throws`; it owns its directory descriptor and inode
evidence. `PeerIdentity` contains `userID: UInt32`,
`signature: SignatureEvidence` (`valid`, `invalid`, `unavailable`), and optional
`signingIdentifier`, `teamIdentifier`, and `codeDirectoryHash`.
`PeerInspecting.inspect(socketFD: Int32) throws -> PeerIdentity` is a protocol;
`PeerIdentityInspector` supplies the real implementation.
`PeerPolicy.permitsDiagnosticPeer(_ identity: PeerIdentity, currentUID: UInt32) -> Bool`
checks user equality only, never grants operational authority.

- [x] **Write failing runtime checks.** Use a real private temporary directory and connected Unix sockets. Assert directory mode `0700`, socket mode `0600`, current kernel UID, and refusal of unsafe/overlong paths. Assert that cleanup leaves a substituted inode, occupied path, symlink, foreign-owned fixture, and unrelated sentinel file untouched. Assert wrong-user policy denial and that signature `invalid`/`unavailable` never creates task authority.
- [x] Run `swift run compatibility-checks runtime` and observe the missing implementation failures.
- [x] Implement private child creation with `mkdtemp`, canonicalized/validated user-temp base, directory descriptors, `lstat`/`fstat` ownership checks, and no-follow operations. Check `sockaddr_un.sun_path` byte capacity before bind, including the terminator. Never remove an occupied endpoint to retry; cleanup only verified owned socket/directory inodes, never recursive arbitrary paths.
- [x] Obtain UID/GID with `getpeereid`. Attempt `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` with an exactly sized audit token, then `SecCodeCopyGuestWithAttributes` using `kSecGuestAttributeAudit` and `SecCodeCheckValidity`. Use `SecCodeCopyStaticCode` before static signing-information lookup rather than unsafe reference casts. Constants are supplied by the SDK, not guessed numeric values. Missing peer credentials reject the connection; missing audit/signature evidence is recorded as unavailable and cannot authorize anything. Do not fall back to a caller-supplied PID or a process-name/parent-name match.
- [x] Add narrowly injected failure providers in test utilities for credential, audit-token, and Security API failures. Keep the real socket credential check as a separate check; do not call fixture results live authentication evidence. Never persist or print raw tokens or the full signing-information dictionary.
- [x] Run `swift run compatibility-checks runtime`, all compatibility groups, and `bash scripts/test.sh`; review the checkpoint.

### Task 4: Bounded Diagnostic Server and Lifecycle

**Files:** Create `SessionObserver.swift`, `DiagnosticServer.swift`,
`Sources/CompatibilityCLI/main.swift`, `Tests/CompatibilityChecks/ServerChecks.swift`,
`Tests/CompatibilityChecks/SessionFixtures.swift`; finish the executable target in
`Package.swift` and wire `compatibility-checks` into `scripts/test.sh` and macOS CI.

**Interfaces:** `SessionObserving` exposes `currentState() -> SessionState`,
`start(onUnsafe: @escaping () -> Void)`, and `stop()`; `MacSessionObserver`
uses real OS evidence. `ClockProviding.sample() -> ClockSample` has a real
`SystemClock` and test-only fake implementations.
`DiagnosticServer.init(runtime: RuntimeDirectory, session: any SessionObserving,
peerInspector: any PeerInspecting, clock: any ClockProviding)`;
`run(onReady: (URL) throws -> Void) throws`;
`stop(reason: CloseReason)`. A stopped instance cannot be restarted.

- [x] **Write failing server checks** against real Unix connections and the real protocol reducer. Assert a ping response, unconditional operational `-10011`, wrong-user/credential-failure rejection, second-client rejection, partial read/write handling, disconnect cleanup, and no retained request after restart. Inject short-writing I/O only in test utilities; preserve a separate real-socket test.
- [x] Add deterministic lifecycle checks at `4.999` versus `5` seconds for idle/partial-frame expiry, five seconds for pending-response expiry, and `299.999` versus `300` seconds for service lifetime. Simulated lock, inactive/unknown session, sleep/wake, or stop discards pending output and closes owned connections. After a ping, forged metadata still cannot produce an operational success.
- [x] Run `swift run compatibility-checks server`; confirm each missing behavior fails before implementing it.
- [x] Implement nonblocking Darwin sockets with `SO_NOSIGPIPE`, process-local umask `0077`, and readiness sources on one serial queue. Check the session before bind, before dispatch, and before writes; check monotonic deadlines on each event plus a timer. A partial frame's five-second budget starts at its first byte and never resets on a trickle of additional bytes; test this slow-client case. Do not buffer more than one frame and one reply. Coalesced codec input is supported, but more than one unacknowledged request closes rather than creating an unbounded response queue. Handle EINTR, EAGAIN, short writes, EOF, and I/O failure without replay.
- [x] Implement session reading from `CGSessionCopyCurrentDictionary` and `IOConsoleLocked`, matching the existing helper's fail-closed resolution without editing that helper. Observe NSWorkspace sleep/wake/session-resign events and poll lock state every 100 ms on the serialized lifecycle path; any unsafe/unknown state closes. Use `ContinuousClock` for budgets and lifetime, not wall time. Unit events are not presented as an actual Mac lock test.
- [x] CLI accepts only `--diagnostic --ready-fd N` (required inherited pipe FD at least `3`). It uses the real peer/session/clock providers and the validated per-user temporary root. Send the owned socket path only to this private pipe, not to logs. Reject unknown flags and root execution; expose no fake-session, trusted-caller, operational-enable, persistence, or vendor-path switch. SIGINT/SIGTERM stop cleanly.
- [x] Run all compatibility groups and `bash scripts/test.sh`; verify CI runs the new executable checks on macOS without requiring Node, permissions, or a desktop unlock. CI may run deterministic session fixtures; a real-session-unavailable service start is a safe refusal, not an environment bypass. Review the checkpoint.

### Task 5: Installed-Client Harness and Separate Bundle

**Files:** Create `scripts/compatibility_probe.mjs`, `resources/compatibility/Info.plist`,
`scripts/build-compatibility.sh`, `python_tests/test_compatibility_probe.py`, and
`docs/compatibility.md`. Do not modify the Phase 1 installer or build script.

**Interfaces:** `node scripts/compatibility_probe.mjs --app PATH --service PATH`
starts only our supplied diagnostic executable and connects the installed client
code to its private socket through an in-process `nodeRepl.nativePipe` shim.
Its single sanitized JSON report contains `tier: "A2"`, `outcome` (`passed`,
`skipped`, `failed`), client/app version, the two client-source hashes, and fixed
boolean/version/denial checks. Exit `0` means A2 passed, `2` means a documented
missing dependency or unsafe/unknown session, and `1` means failure.

- [x] **Write failing harness regression tests** for missing Node/client/executable, a changed client hash, unsafe session refusal, truncated ready-pipe data, early process exit, timeout, and secret-looking synthetic metadata never appearing in output. Use inert child fixtures, not a real task or an account file. Node-dependent tests explicitly skip if Node is absent; no install is attempted.
- [x] Run `PYTHONPATH=python python3 -m unittest discover -s python_tests -p test_compatibility_probe.py -v`; observe failures before implementing the harness. If Node is unavailable, record that blocker rather than claim harness verification.
- [x] Implement with Node built-ins only, explicit CLI paths, a private ready pipe capped at 4,096 bytes containing one JSON readiness record, and a 15-second overall timeout. Terminate only the harness-owned child process group in `finally`, escalating from SIGTERM to SIGKILL after one second. Construct child environments from the small required OS/runtime variables only; do not forward API keys, GitHub tokens, or unrelated overrides. The shim connects only to the owned endpoint and cannot invoke LaunchServices or host-service startup. Metadata is synthetic, never copied from this conversation or another task.
- [x] Import the installed `@oai/sky` client locally only after version/hash checks. For 26.1007.71326 (20398), expected SHA-256 values are `2f1bcc0b4cd013ef3d267f6d93bd2aa29770712687c8db087d55ec9d173380e8` for `native-pipe.js` and `ae51951e7087203d473127ccee7725fc61528682f6866d60595a963ef6da56c9` for `client.js`. Unknown versions/hashes require read-only re-characterization, not fallback imports or downloads.
- [x] Test negotiation with the actual imported `MacComputerUseClient` and a policy request targeting the public Calculator bundle identifier; expect `-10011`, never app access. Treat this as A2 even if the JavaScript is official and the native peer signature verifies. Verify no original metadata or request bodies are emitted in stdout/stderr; store only the sanitized report under ignored `dist/` if requested.
- [x] Build a separate `.app` with executable `intel-computer-use-compat`, our own bundle ID, `LSUIElement = true`, and no permission-prompt descriptions or unlock entitlements. Default to explicit ad-hoc development signing; an optional `ICU_COMPAT_SIGNING_IDENTITY` selects a user-provided identity without enumerating certificates. Sign/verify only the new bundle. Do not install or launch ChatGPT.
- [x] Run the harness regressions, full project suite, and `bash scripts/build-compatibility.sh`; inspect the new executable's architecture/signature. Run the A2 harness only while the real session is unlocked, and record its actual outcome. Verify the installed Phase 1 executable/code-directory hashes still match preflight. Review the checkpoint.

### Task 6: Read-Only Route Assessment and Honest Handoff

**Files:** Extend `docs/compatibility.md`, `VALIDATION.md`, `ROADMAP.md`,
`docs/WORK_QUEUE.md`, and `CHANGELOG.md`; reference the updated runbook from `README.md`.
No additional executable or unlock component is introduced by this task.

**Consumes:** Task 5's sanitized A2 report and the investigation's observed route
names. **Produces:** An A1/A2/A3 evidence table and either a concrete route proposal
awaiting user approval or an A3 blocked result with one specific constraint.

- [x] Run A1 and A2 verification again; record app/client versions, source hashes, test counts, and actual outcomes. Verify reports contain no endpoint path, raw peer token, raw metadata, task IDs, request body, or sensitive content. Do not add synthetic tests to the live-validation count.
- [x] Inspect only relevant installed host/client code for existing provider-route eligibility. Treat `SKY_CUA_SERVICE_PATH` and `SKY_CUA_SERVICE_NATIVE_PIPE_PATH` as research leads, not supported overrides. Never edit the packaged app, feature flags, managed configuration, real service root, or vendor sockets to test a hypothesis.
- [ ] If a route exists within the approved constraints, write its exact prerequisites, target process, proposed narrowly scoped change, own identity/socket, readiness observation, restoration steps, and required user action. Stop for approval before any restart, environment/configuration change, or live desktop-host request. A plan approval does not replace route approval.
- [ ] Only after that concrete route receives approval, execute its single bounded real-host diagnostic check, observe both delivery to our service and the expected denial, and restore the approved route immediately. Verify restoration before reporting A3. The exact action comes from the approved route record, not guessed flags or synthetic metadata; if the observed host request cannot be established, report A3 unverified.
- [x] If no eligible route is established, mark A3 blocked and Phase 2A partial. Retain the independently testable diagnostic software; do not manufacture a route, repeat the same blocker at each quota reset, or begin 2B/2C. A working local harness is not host integration or a Locked Use fix.
- [x] Publish only reviewed project source/docs through the already authorized repository workflow. Do not publish vendor files, local reports with private fields, temporary artifacts, or credentials. Record any unsatisfied acceptance item by name.

## Completion and Execution Handoff

- [x] User reviews this plan and selects native sequential or subagent-driven execution before Task 1.
- [x] Each implemented task passes its specific red-green cycle and the full suite; new failures are reported, not silently excluded.
- [ ] A1/A2 software can be complete while A3 remains blocked. Phase 2A as a whole is not complete until the approved real-host diagnostic acceptance is observed.
- [ ] Any future actual lock/sleep/wake acceptance is user-coordinated; never lock or disrupt the user's live session automatically. Deterministic lifecycle tests alone do not establish that live behavior.
- [ ] Phases 2B/2C, operational adapters, authorization plugins, and official-toggle changes remain unimplemented and separately gated.

Selected method: **native sequential execution**. The protocol, peer-evidence,
and server-lifecycle tasks share tightly coupled interfaces; keeping one
implementer avoids repeated context loading. A final independent review, if
authorized through the selected workflow, checks the whole change before live
route approval. Execution approval does not replace approval for a specific host route.
