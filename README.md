# Intel Computer Use

Independent native desktop tools for Intel Macs, exposed through a local MCP
server. Built for installations where ChatGPT/Codex provides browser control
but omits the native Computer Use service.

**Phase 1:** native app control while the Mac is unlocked.
**Phase 2:** investigate compatible locked-session operation separately.
This project does not currently enable ChatGPT's official **Locked Use** setting.
It is not affiliated with or endorsed by OpenAI.

## What it provides

- Exact application allowlisting by bundle ID.
- Open allowed apps and list their visible windows.
- Read a bounded Accessibility tree and capture a selected window.
- Click, type Unicode, send keyboard chords, and scroll inside that window.
- Check macOS permissions and session state without changing them.
- Diagnose missing vendor helper/installer components with `doctor`.

The bridge uses its own identity and MCP tools. It does not patch ChatGPT,
impersonate the official helper, install an unlock plugin, or alter macOS lock
settings. Terminal applications, ChatGPT/Codex, loginwindow, System Settings,
and known credential managers are protected even if allowlisted.

## Requirements

- An Intel Mac with macOS 14 or later. Apple Silicon can build the same source;
  Intel is the primary target.
- Swift 6 through Xcode or Command Line Tools, and Python 3.9 or later.
- An MCP host with local stdio-server support, such as Codex.
- User-granted Accessibility and Screen Recording permissions.

No API key, Python package installation, privileged installer, or network service
is required. The model and MCP host supply the intelligence; this project supplies
the local desktop tools.

## Build and test

```bash
git clone https://github.com/ercanatay/intel-computer-use.git
cd intel-computer-use
chmod +x scripts/icu scripts/supervisor
bash scripts/test.sh
bash scripts/build.sh
bash scripts/install.sh
```

The installer places a separate app at `~/Applications/Intel Computer Use.app`.
It refuses to overwrite an existing installation. To update, move that app aside
yourself and rerun the installer. Nothing inside ChatGPT is changed.

The default build is ad-hoc signed for local development. For a stable signing
identity across rebuilds, supply your own local code-signing certificate:

```bash
ICU_SIGNING_IDENTITY='Your local signing identity' bash scripts/build.sh
```

No certificates or private keys belong in this repository. An ad-hoc-signed
rebuild can require granting permissions again. This is not a notarized release.

## Grant macOS permissions

Run the installed helper's setup mode yourself:

```bash
open -n -a "$HOME/Applications/Intel Computer Use.app" --args --setup
```

In System Settings > Privacy & Security, grant **Accessibility** and
**Screen Recording** to Intel Computer Use. The adapter launches the bundle
through LaunchServices to retain its independent permission identity rather than
inheriting the terminal's identity. Quit and restart the MCP connection afterwards.
The server never approves prompts or resets the TCC database.

```bash
./scripts/icu status
./scripts/icu doctor
```

`status` reports the permissions actually observed by the helper. A build that
passes tests can still need these user-granted permissions before live control.

## Connect to Codex

If `codex` is on your PATH:

```bash
codex mcp add intel-computer-use -- "$PWD/scripts/icu" serve \
  --allow com.apple.calculator --allow com.apple.TextEdit
```

For another MCP host, adapt [examples/mcp.json](examples/mcp.json) using the
absolute path to your checkout. Restart the host or start a fresh task after
adding the server. The independent tools appear under **intel-computer-use**;
they do not add or repair ChatGPT's built-in Computer Use plugin or setting.

Add more `--allow` arguments for the apps you want to use. An empty allowlist
permits status checks only. No MCP tool can expand the launch-time allowlist.

Example request to your assistant:

> Use the intel-computer-use tools. Open Calculator, list its windows, take a
> snapshot, calculate 12 + 30, and take another snapshot to verify 42.

## Tools

| Tool | Purpose |
| --- | --- |
| `status` | Permission, architecture, session, and allowlist information |
| `list_apps` | Running allowlisted applications |
| `open_app` | Launch an allowlisted application |
| `list_windows` | Visible window IDs for one allowed app |
| `snapshot` | Accessibility tree plus optional PNG screenshot |
| `click` | Left/right click or double-click |
| `type_text` | Literal Unicode input, without clipboard use |
| `press_key` | Return, Tab, arrows, or chords such as cmd+a |
| `scroll` | Pixel scrolling at an observed window point |

Observe before acting and take a fresh snapshot after every action. Coordinates
are **window-relative logical points**, not desktop coordinates or Retina pixels.
The snapshot includes logical dimensions and image pixel dimensions.

## Operating limits

- Foreground control: the target app activates while input is sent. Avoid
  manipulating the computer concurrently. Input uses the foreground macOS event
  stream and can move the real pointer; this is not background per-window input.
- Desktop operations require an active, unlocked session. The helper does not
  unlock a Mac or continue through its real lock screen.
- Input stops on an observed focus or session change. This is not an atomic
  protection against every possible race with local user input.
- Ambiguous windows with identical geometry are rejected; minimized or off-screen
  windows are unsupported. Window matching uses public AX geometry, not private
  window-ID APIs.
- Screenshot and Accessibility access depend on the application and macOS.
  Secure text fields are omitted; protected or DRM content may be unavailable.
- Letter keyboard shortcuts use US physical key positions. `type_text` uses
  Unicode and does not depend on the keyboard layout.
- Screenshots and visible application text are returned to the MCP host and
  may be processed by its model provider. The bridge has no telemetry or listener.
- LaunchServices transport briefly stores requests and responses, including
  captures, in a private temporary directory (mode 0700; files 0600), then removes
  it. Cleanup is not guaranteed after a forced kill or crash; files are not securely
  erased. Do not use the bridge for sensitive windows.

## Background quota supervisor

An optional, separate supervisor monitors the account's reported five-hour and
weekly reset times through the official Codex app-server. It can continue bounded
project jobs after a reset and redeem at most **three** earned reset credits, only
when the weekly window is exhausted. It never purchases credits or bypasses limits.
See [setup, controls, and safeguards](docs/supervisor.md). This does not keep the
Mac awake or enable locked-session desktop control.

## Project phases

See [ROADMAP.md](ROADMAP.md) for delivery status and
[Locked Use investigation](docs/locked-use.md) for the Phase 2 boundary.

## Verification

`bash scripts/test.sh` runs Python protocol/integration tests, native guard checks,
and a native build. Native guard checks are a Swift executable so they work with
Command Line Tools distributions that omit XCTest and Swift Testing.

Automated tests do not grant macOS permissions. Live desktop validation is
reported separately in [VALIDATION.md](VALIDATION.md).

After granting permissions, `python3 scripts/smoke.py` opens Calculator and checks
12 + 30 = 42 through the real MCP adapter and native helper. It exits with status
2 instead of sending input when permission or the unlocked session is unavailable.
