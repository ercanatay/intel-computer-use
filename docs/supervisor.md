# Quota-aware project supervisor

This optional, dependency-free Python 3.9+ component monitors the existing Codex
ChatGPT account and gates one bounded Intel Computer Use task at a time. It is
separate from the Swift native bridge and MCP server. Installation starts paused
and does not load the LaunchAgent or start model work.

## Inspect and install

Run these commands from the project directory:

```sh
./scripts/supervisor quota
./scripts/supervisor status
./scripts/supervisor install --project "$PWD"
```

`quota` makes read-only account RPCs and prints only usage percentages, window
lengths, reset Unix timestamps, and the earned reset count. It never consumes a
reset. `status` reads local state. `install` writes
`~/Library/LaunchAgents/com.intel-computer-use.supervisor.plist`, pauses work, and
does not run `launchctl`. Python can also be invoked directly:

```sh
python3 python/intel_computer_use/supervisor.py quota
```

After current interactive project work has finished, enable periodic monitoring
and work explicitly:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.intel-computer-use.supervisor.plist"
./scripts/supervisor resume --project "$PWD"
launchctl kickstart "gui/$(id -u)/com.intel-computer-use.supervisor"
```

To enable monitoring immediately but defer work and redemption, provide an
absolute Unix timestamp obtained from the current account response or another
explicit scheduling decision:

```sh
./scripts/supervisor resume --project "$PWD" --not-before 1792070066
```

That timestamp is an example from a read-only snapshot on October 15, 2026; it is
not a recurring reset time. Always obtain fresh account limits. Once the
scheduled time arrives, a fresh quota response still gates all work and credit
use. A delayed run never infers that a reset has already occurred.

The LaunchAgent checks every 60 seconds while this macOS user is logged in.
It is not a system daemon and cannot wake a sleeping computer. No bootstrap or
activation is performed by `install`. If already loaded, unload it before
reinstalling its plist:

```sh
launchctl bootout "gui/$(id -u)/com.intel-computer-use.supervisor"
```

## Pause and recovery

```sh
./scripts/supervisor pause
./scripts/supervisor status
./scripts/supervisor tick --project "$PWD"
```

Paused ticks monitor quotas without starting work or consuming credits. A manual
`tick` can start a task when work is enabled and its schedule and quota gates
allow it. A nonblocking exclusive file lock prevents overlapping supervisor
commands. If a command reports busy, an existing tick may still be running;
`pause` does not interrupt that task. Stop an active LaunchAgent task first when
necessary:

```sh
launchctl kill SIGTERM "gui/$(id -u)/com.intel-computer-use.supervisor"
./scripts/supervisor pause
```

Ordinary termination cleans up the worker process group, marks work blocked, and
requires explicit `resume`. A worker is bounded to 900 seconds, with process
group termination and a three-second grace period before a final kill. Account
RPCs have 20-second deadlines. Invalid output or a failed task pauses work;
an observed quota exhaustion after a failed task schedules a quota-gated retry.

A hard crash or forced kill can leave an interrupted run marker. The next tick
pauses it instead of starting a second worker. Inspect the project, thread, and
any surviving Codex processes before explicitly resuming. A forced kill or power
loss cannot guarantee child cleanup. The supervisor lock covers this component,
not separate interactive Codex sessions. Schedule enabled work after interactive
editing ends.

## Quota and earned-credit policy

- Both the 300-minute and weekly windows must be present and valid. A weekly
  window is identified by duration of at least 10,080 minutes, regardless of
  whether it appears as primary or secondary.
- Five-hour exhaustion alone always waits for its natural account reset.
- Only a weekly window with usage at least 100% may initiate or retry redemption.
- At most **three earned reset credits in total** may be consumed by this
  supervisor, across all runs and weeks. This is not a weekly allowance.
- Missing credit availability never authorizes redemption. The service's
  `availableCount` is authoritative, including when detail rows are omitted or
  capped. Expired detail rows are never selected explicitly; the service may
  select an available earned credit when only the count is usable.
- A UUID reservation is saved and fsynced before calling consume. `reset` and
  `alreadyRedeemed` mark that same logical attempt successful once.
  `nothingToReset` and `noCredit` do not count as consumption. Each outcome is
  followed by a fresh quota read. A still-exhausted weekly window waits for its
  natural reset instead of burning another credit in a loop.
- An uncertain attempt keeps its UUID and reserves one of the three lifetime
  slots. Retries reuse that exact key and optional credit ID. If weekly quota
  has recovered, no consume call is made merely to reconcile the ledger. The
  pending reservation remains conservative until a later exhausted weekly
  window permits safe reconciliation. It may temporarily understate available
  budget.
- Server reset timestamps determine waits. Stale timestamps, missing windows,
  invalid numbers, unsupported workspace restrictions, and malformed responses
  fail closed. Background account checks continue while a work cooldown applies.
  An account error never advances an existing scheduled start or reset wait.

There are no purchase, billing, owner-email, or quota-bypass calls. The only
account methods used are initialization, reading the current account, reading
rate limits, and the gated earned-credit consume method. Account availability and
earned resets remain subject to the service; a local schedule cannot guarantee
either.

The protocol follows the official [Codex app-server account documentation](https://learn.chatgpt.com/docs/app-server),
sections 6 and 8. The installed CLI was checked with its generated JSON schemas
and `--help`, and a live read-only JSONL account request was verified. Actual
worker inference and actual earned-credit redemption are deliberately not part
of the test suite.

## Work boundaries and stored state

Codex is located on `PATH`, with the bundled ChatGPT CLI as fallback:
`/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`.
The supervisor uses that CLI's existing ChatGPT sign-in, rejects API-key accounts,
removes API-key environment overrides, and never reads credential or token files.
It does not store the account email or raw account responses.

Each worker uses an explicit project path, `workspace-write`, approval policy
`never`, no additional writable roots, and no sandbox or hook bypass flags.
User CLI configuration is ignored for workers while existing sign-in remains
available. Sandbox network access and writable temporary roots are disabled.
The first task records its thread UUID as soon as JSONL emits it. Future tasks
use `codex exec resume` with that exact remembered UUID, never `--last`. No
arbitrary project or arbitrary initial thread can be supplied through this CLI.

The prompt reads `ROADMAP.md`, repository instructions, and `docs/WORK_QUEUE.md`
when present. It asks for one useful task, verification, and an outcome matching
`docs/supervisor-result.schema.json`: `completed`, `continue`, or `blocked`, plus
a progress/blocker summary and a cooldown of 300–86,400 seconds. Completed and
blocked work pauses automatically. External permissions, vendor components, and
human decisions are recorded as blockers. Phase 2 must never bypass the macOS
lock or fabricate supported Intel vendor unlock functionality. The supervisor
does not itself grant Accessibility, screen capture, authentication, or vendor
integration capabilities.

All supervisor state and logs are under:

```text
~/Library/Application Support/Intel Computer Use/supervisor/
```

The directory is mode `0700`; regular files are `0600`. `state.json` contains
project/thread IDs, the credit ledger, schedule, latest sanitized quota snapshot,
and task outcome. It is replaced atomically and fsynced. `events.jsonl` records
decisions without account identities or CLI transcripts and rotates at about
1 MiB into one previous file. The final structured worker result and launchd
stdout/stderr logs also stay here. CLI-owned sign-in and thread persistence stay
under Codex's own management. `~/Library/LaunchAgents` contains only the plist,
not account data.

Preserve `state.json`: deleting, replacing, or manually reducing its ledger loses
the lifetime accounting guarantee. Invalid state is rejected rather than silently
recreated. Credit usage performed elsewhere is not counted as supervisor usage.
The ledger is a local persistence guarantee, not tamper-resistant account policy.

## Tests

```sh
PYTHONPATH=python python3 -m unittest python_tests.test_supervisor -v
```

Tests use real temporary state files and fake subprocesses for the account and
worker boundaries. They cover quota gates, expiration and malformed data,
natural resets, all redemption outcomes, uncertain retries, durable reservations,
lifetime budget, paused/scheduled work, exact thread resumption, file permissions,
single-worker exclusion, process timeouts, and blocked/completed recovery.
