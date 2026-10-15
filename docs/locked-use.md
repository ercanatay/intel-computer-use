# Phase 2: Locked Use investigation

## Current result

**Unresolved.** The independent MCP helper deliberately requires an unlocked
session. It does not install a macOS authorization plugin or make the official
ChatGPT Locked Use toggle succeed.

`./scripts/icu doctor` checks known vendor helper and installer locations without
modifying them. File presence alone does not prove an official, compatible,
correctly signed, or functioning unlock implementation.

## Evidence

Intel users report missing `SkyComputerUseService` and Locked Use installation
components, including on 2019 16-inch MacBook Pro hardware. The same-version
Apple Silicon payload has been reported as ARM64-only. These reports are user
observations, not an official architecture-support announcement:

- https://github.com/openai/codex/issues/42514
- https://github.com/openai/codex/issues/31160
- https://github.com/openai/codex/issues/44155

The installed client invokes a nested **Codex Computer Use Installer** with an
`install` argument when the toggle is enabled. A missing executable prevents
that path from succeeding. Implementing an unrelated MCP server cannot supply
that vendor-specific installation contract.

OpenAI describes a temporary unlock tied to an active trusted Computer Use turn,
covering all displays, relocking on local input, and falling back to manual unlock:
https://learn.chatgpt.com/docs/computer-use#locked-use

## Required integration contract

Before implementing an authorization plugin, establish and verify:

1. A supported x86_64 or universal native payload and authorization installer.
2. Its signing identity, provisioning requirements, and expected caller identities.
3. A verifiable, short-lived authorization tied to an active approved task.
4. Display shielding before access, including newly attached displays.
5. Immediate relock and suspension when physical input occurs.
6. Timeout, crash, sleep/wake, multi-user, and manual-unlock fallback behavior.
7. Preservation of login-keychain availability and normal password unlock.
8. Privileged installation, upgrade, rollback, and complete removal procedures.

The trust-verification contract and Intel payload are not established here.
Without them, an always-allow authorization mechanism would create a different,
unsafe product rather than restore the promised feature. This project therefore
does not write `system.login.screensaver`, retain passwords, disable screen-lock
authentication, or fabricate successful installer responses.

## Next useful experiment

When an official Intel-compatible helper becomes available, inspect its
architecture and signature without installing it. Test installation and unlock
behavior in a disposable local macOS account, then verify every item above.
Do not test authentication plugins first on a user's primary login account.
