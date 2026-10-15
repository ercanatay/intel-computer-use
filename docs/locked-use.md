# Phase 2: Locked Use investigation

## Current result

**Unresolved.** The independent MCP helper deliberately requires an unlocked
session. It does not install a macOS authorization plugin or make the official
ChatGPT Locked Use toggle succeed.

`./scripts/icu doctor` checks known vendor helper and installer locations without
modifying them. File presence alone does not prove an official, compatible,
correctly signed, or functioning unlock implementation.

## Reproduced evidence — 2026-10-15

The installed Intel app and the public Apple Silicon reference have exactly the
same app version, **26.1007.71326 (20398)**. The reference was obtained from the
download link on [OpenAI's app documentation](https://learn.chatgpt.com/docs/app),
not from a third-party binary mirror:

`https://persistent.oaistatic.com/codex-app-prod/Codex.dmg`

The 783,674,802-byte image passed `hdiutil verify` and was mounted read-only with
`-nobrowse -noautoopen`. No application, helper, installer, or authorization
plugin from that image was executed or installed. Its SHA-256 is:

`4ab4d4569c5728ab0c6d314ce0ab0dcb84f861378a7a9bb2360100021b15a4cc`

The reference's `@oai/sky/Codex Computer Use.app` contains all six components
declared by the installed `@oai/sky` package, version 0.7.7:

| Component | Reference architecture | Signature verification |
| --- | --- | --- |
| `SkyComputerUseService` | arm64 only | Valid; OpenAI team `2DC432GLL2` |
| `SkyComputerUseClient` | arm64 only | Valid; OpenAI team `2DC432GLL2` |
| `Codex Computer Use Installer` | arm64 only | Valid; OpenAI team `2DC432GLL2` |
| `CodexComputerUseAuthorizationPluginInstallerTool` | arm64 only | Valid; OpenAI team `2DC432GLL2` |
| `CodexComputerUseAuthorizationPlugin` | arm64 only | Valid; OpenAI team `2DC432GLL2` |
| `CUALockScreenGuardian` | arm64 only | Valid; OpenAI team `2DC432GLL2` |

Each binary passed `codesign --verify --strict`. These architecture and signing
observations are specific to this downloaded release, not an assertion that
OpenAI cannot ship an Intel implementation. The matching payload is absent from
the known locations checked in the installed Intel app and local service root.

### Installer contract

The installed host resolves the nested installer under its Codex home:

`computer-use/Codex Computer Use.app/Contents/SharedSupport/Codex Computer Use Installer.app/Contents/MacOS/Codex Computer Use Installer`

It invokes `install` or `uninstall`, then invokes `status`. The host considers
the setting enabled when trimmed status output equals `OK: installed`. The
execution timeout is 120 seconds. This host-side wrapper does not itself
establish a signing requirement or prove that a locked task can run. Returning
that string without a working authorization implementation would fake success.

### Native IPC contract

The bundled Mac JavaScript is present on Intel. Its transport and client files
are byte-identical to the corresponding files in the Apple Silicon reference.
A throwaway experiment imported the installed files and replaced only the
`nodeRepl` connection with an in-memory peer. All seven characterization tests
passed; no real socket, task metadata, desktop access, or unlock was involved.

Observed client behavior:

- Frames are a four-byte little-endian byte length followed by UTF-8 JSON;
  the codec rejects payloads larger than 8 MiB.
- JSON-RPC `ping` negotiates `CodexComputerUseIPC-5`; an incompatible version
  is rejected before app requests.
- JSON-RPC `request` carries `clientApiVersion`, `codexTurnMetadata`,
  `deadlineUnixMilliseconds`, `request`, and `requestType`.
- Policy, snapshot, and input requests have distinct request types. Unicode
  input and explicit per-call metadata survive serialization.
- Metadata defaults to `nodeRepl.requestMeta["x-codex-turn-metadata"]`.
  Its presence alone is **not** proof of an active or authorized task.
- A `screenLocked` response (`-10020`) propagates to the caller; the JavaScript
  client does not independently unlock the Mac.

The ordinary native socket is under the vendor's app-group container, separate
from the authorization socket. The experiment never bound either socket or
changed a service path in the real app. It remains ignored under `dist/` and is
not a supported compatibility layer or part of the project's test-suite count.

### Confirmed authorization-plugin identity check

Read-only ARM64 disassembly, constant-string addresses, and chained-fixup
inspection establish that the reference authorization plugin obtains its
socket peer's audit token, calls `SecTaskCreateWithAuditToken`, reads the
signing and team identifiers, and compares **both** against:

- Signing identifier: `com.openai.sky.CUAService`
- Team identifier: `2DC432GLL2`

A mismatch branches to failure before the authorization response is read.
This is more than an inference from embedded log messages. In this particular
plugin, calls at `0xe78` and `0xe9c` obtain those identities, `CFEqual` calls at
`0xec4` and `0xedc` compare constants at `0x4140` and `0x4160`, and conditional
branches at `0xee0` and `0xee4` reject a mismatch. The constant references
resolve to strings at `0x1400` and `0x141a` respectively. These offsets apply
only to the hashed binary below.

Reference binary SHA-256 values:

- Service: `ac8bfe406d01a7cb43f7550c080587ae3a5f404f82fa6dcc399bf72a85cd765d`
- Authorization plugin: `71c9c0a1c8a505ceab9b0b8d8e20b7bce319e717cc0efcafb024f518461d4ba8`

An independently signed Intel service therefore cannot reuse this unmodified
authorization plugin by merely implementing its socket response. Copying the
bundle identifier does not supply OpenAI's team identity. No identity check was
patched, bypassed, or tested against the live unlock mechanism.

### What this does not establish

The complete service-side trusted-turn, caller-authentication, cancellation,
and guardian contracts have not been reconstructed or tested. An IPC handshake
is not a trusted-turn proof. The reference service exposes authorization-broker,
unlock-coordinator, physical-input, display-overlay, and guardian components;
their presence is not evidence that a replacement implements their safeguards.

The plugin's identity check proves a blocker for **reusing that vendor chain**,
not a blanket proof that a clean-room Intel implementation is impossible.
Replacing the whole chain would be a new security-sensitive implementation,
not a supported vendor integration. Its feasibility remains unresolved. It
requires a reviewed design, authenticated task-lifecycle evidence, and isolated
testing before any installation can be considered.

## External reports

Intel users report missing `SkyComputerUseService` and Locked Use installation
components, including on 2019 16-inch MacBook Pro hardware. The same-version
Apple Silicon payload has been reported as ARM64-only. These reports are user
observations, not an official architecture-support announcement:

- https://github.com/openai/codex/issues/42514
- https://github.com/openai/codex/issues/31160
- https://github.com/openai/codex/issues/44155

OpenAI describes a temporary unlock tied to an active trusted Computer Use turn,
covering all displays, relocking on local input, and falling back to manual unlock:
https://learn.chatgpt.com/docs/computer-use#locked-use

## Required integration contract

Before implementing an authorization plugin, establish and verify:

1. An x86_64 or universal payload and authorization installer with a verified
   provenance and integration contract; vendor-supported status must be explicit.
2. Its signing identity, provisioning requirements, and expected caller identities.
3. A verifiable, short-lived authorization tied to an active approved task.
4. Display shielding before access, including newly attached displays.
5. Immediate relock and suspension when physical input occurs.
6. Timeout, crash, sleep/wake, multi-user, and manual-unlock fallback behavior.
7. Preservation of login-keychain availability and normal password unlock.
8. Privileged installation, upgrade, rollback, and complete removal procedures.

The complete trust-verification contract and Intel payload are not established here.
Without them, an always-allow authorization mechanism would create a different,
unsafe product rather than restore the promised feature. This project therefore
does not write `system.login.screensaver`, retain passwords, disable screen-lock
authentication, or fabricate successful installer responses.

## Recommendation and next gate

Do not install the ARM64 reference or create a placeholder installer. The next
design decision is whether to pursue vendor cooperation or a clean-room Intel
compatibility stack. A compatibility effort must first specify how the real
host authenticates a replacement and how it supplies verifiable task start,
cancellation, completion, and revocation signals. Request metadata and a matching
API version are insufficient substitutes.

Keep any next prototype isolated, unlocked-only, and outside the vendor's real
service paths until that design is reviewed. If a supported Intel payload is
obtained, inspect its architecture and signature before considering installation.
Authentication-plugin testing requires separate approval and a disposable local
macOS account, never the user's primary login as its first test target.
