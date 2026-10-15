# Intel Compatibility Diagnostic

**A1 implemented; A2 observed; A3 blocked. Phase 2A remains partial.**
This independent diagnostic cannot enable ChatGPT's Locked Use setting or
control apps. It is not an OpenAI provider or authorization plugin.

## Evidence — 2026-10-15

| Tier | Meaning | Observed result |
| --- | --- | --- |
| A1 | Our parser, policy, Unix sockets and simulated lifecycle | 178 compatibility checks, 73 Python tests, 53 existing native guards passed |
| A2 | Installed client in an isolated Node harness | IPC-5 negotiation and operational error `-10011` observed with synthetic metadata |
| A3 | A request from the actual desktop host reaches our service | Blocked: no eligible, approved provider route established; native computer APIs disabled in this session |

A2 is not ChatGPT's trusted runtime. Same-UID/signature evidence never grants
task authority. Simulated lifecycle events are not actual lock/sleep/wake tests.
No disruptive live test, input, capture, shielding or unlock was performed.

The inspected installation is ChatGPT **26.1007.71326 (20398)**, `@oai/sky`
**0.7.7**, on Intel. A2 pins these local files, not their whole dependency tree:

| File | SHA-256 |
| --- | --- |
| `native-pipe.js` | `2f1bcc0b4cd013ef3d267f6d93bd2aa29770712687c8db087d55ec9d173380e8` |
| `client.js` | `ae51951e7087203d473127ccee7725fc61528682f6866d60595a963ef6da56c9` |

Unknown versions/hashes are skipped before import. Vendor code stays in the
user's installation; it is not redistributed.

## Build and run

Requires macOS 14+, Swift 6, Python 3.9+ for tests and optional Node.js 20+.
No npm packages, downloads, API keys or TCC permission requests. The harness
uses Node built-ins and macOS `plutil`/`getconf` utilities.

```bash
bash scripts/test.sh
bash scripts/build-compatibility.sh
node scripts/compatibility_probe.mjs \
  --app /Applications/ChatGPT.app \
  --service "$PWD/dist/Intel Compatibility Diagnostic.app/Contents/MacOS/intel-computer-use-compat"
```

Run only while the real session is unlocked. The harness starts only our
diagnostic executable, not ChatGPT or Calculator. The actual imported
`MacComputerUseClient` negotiates IPC-5 and requests Calculator's policy; our
service denies it before app access. One sanitized JSON report contains the
tier/outcome, fixed reason, version/build/hashes and boolean checks. Exit `0`
means A2 passed, `2` means skipped/unavailable, `1` means failed. Never count a
skip as a pass. No endpoint, metadata, request body, audit token, task/account
identifier or child stdout/stderr is printed.

Development runs exposed Node socket-backed readiness and macOS temporary-path
alias mismatches; regressions cover both. One later A2 run still failed
generically before three consecutive successful runs; its cause was not
established. Cold-start and long-running reliability are not proven. Do not
automatically retry to hide a failure.

The separate bundle uses `io.github.ercanatay.intel-computer-use.compat`,
`LSUIElement=true`, no permission descriptions and no unlock entitlements.
Signing defaults explicitly to ad-hoc; optionally supply your existing
`ICU_COMPAT_SIGNING_IDENTITY`. No certificates are enumerated. The builder
creates only `dist/Intel Compatibility Diagnostic.app`; it does not install,
rebuild, re-sign or replace the working Phase 1 app.

## Runtime contract

- Private per-user temp child `0700`, Unix socket `0600`; no TCP, HTTP,
  privileged listener, persistence or launch agent.
- Four-byte little-endian framing, 8 MiB payload limit, strict UTF-8 JSON,
  depth 32 and 16,384 values. Reject duplicate decoded keys, batches and
  ambiguous IDs. IDs are integer literals `0` through `9_007_199_254_740_991`.
- One client and pending reply. Five-second monotonic input/frame/reply
  budgets, no trickle extension; five-minute lifetime. No replay/restart queue.
- Only `ping` succeeds; every valid operational `request` returns `-10011`.
  There is no executor, native-helper adapter, authorization callback, AX,
  capture, app launch or input code, regardless of metadata/signature appearance.
- Kernel peer UID is required; audit-token/dynamic-signature evidence is
  attempted but cannot authorize operations. Wrong-user/missing credentials close.
- Real CoreGraphics/`IOConsoleLocked` session evidence, workspace events,
  100 ms lock polling and checks before dispatch/write fail closed. Unknown or
  unsafe session, sleep/wake/resign, signals, deadlines and EOF discard output.
  Polling is not an atomic authentication boundary and never permits locked use.
- Inode/type/UID checks refuse substituted cleanup paths and unrelated contents.
  This is not isolation from a malicious same-user process; no operations are
  enabled in any case. Forced termination may leave a private temp directory.

CLI: only `--diagnostic --ready-fd N`, `N >= 3`, non-root, real OS providers.
Readiness uses a writable inherited FIFO or same-UID connected Unix stream
(Node's built-in pipe), not a network socket. One JSON record is capped at
4,096 bytes. No fake-session, trusted-peer, vendor-path or enable-actions switch.
The harness has a 15-second overall timeout, forwards a small OS-variable
allowlist and terminates only its owned child group, escalating after one second.

## A3 assessment and next gate

Read-only inspection of installed `.vite/build/main-CwxgTOle.js` and the Mac
client found `SKY_CUA_SERVICE_PATH` and `SKY_CUA_SERVICE_NATIVE_PIPE_PATH`.
These are research leads, not established public provider APIs. A service-app
path alone cannot start our CLI: it requires a private readiness descriptor
and never binds the vendor's default endpoint.

One per-thread builder defaults to forwarding private process environment;
the plugin-configuration path explicitly disables that forwarding and propagates
the native-pipe override only for Dev. Computer-surface selection also depends
on feature/plugin availability and a resolved service path. Finding a variable
does not establish a route in the active packaged host, whose native computer
APIs are disabled here. This current blocker is not proof of impossibility
on all versions/configurations.

**A3 was not run. No host override, feature flag, configuration, packaged file,
vendor socket/path, managed policy or restart was changed.** The original
authorization plugin also requires the OpenAI signing/team identity, not ours;
see [the investigation](locked-use.md).

Next work needs new evidence of an eligible route. Document exact target
process/prerequisites, narrow change, own identity/endpoint, private readiness,
bounded denial-only request, restoration steps and required user action. Obtain
separate approval before changing or restarting anything. Observe actual host
delivery and restoration before claiming A3. Never fake installer success,
impersonate the vendor, weaken authentication or treat metadata as authority.
Phases 2B/2C remain unimplemented and separately gated.

## Stop and rollback

The harness stops its own service in `finally`; the service handles signals and
expires after five minutes. Nothing is installed into the host or background.
The generated diagnostic bundle may be removed manually; leave the working
Phase 1 app unchanged. Never delete unverified/substituted temp paths. Keep
the quota supervisor paused: a reset is not route approval or reason to retry
the same blocker indefinitely.
