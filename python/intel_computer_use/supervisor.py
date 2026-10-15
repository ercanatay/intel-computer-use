"""A local, opt-in quota gate for bounded project work using Codex sign-in."""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import math
import os
from pathlib import Path
import plistlib
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid


PROJECT_ROOT = Path(__file__).resolve().parents[2]
STATE_ROOT = Path.home() / "Library/Application Support/Intel Computer Use/supervisor"
BUNDLED_CODEX = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
AGENT_LABEL = "com.intel-computer-use.supervisor"
CREDIT_BUDGET = 3
RETRY_SECONDS = 300
MAX_LINE_BYTES = 1024 * 1024


class SupervisorError(Exception):
    pass


class WorkerBusy(SupervisorError):
    pass


class JobFailed(SupervisorError):
    pass


def integer(value, minimum=0):
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def identifier(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except ValueError:
        return False


@dataclass(frozen=True)
class Window:
    used_percent: float
    duration_minutes: int
    resets_at: int

    @property
    def exhausted(self):
        return self.used_percent >= 100

    def as_dict(self):
        return {"used_percent": self.used_percent, "duration_minutes": self.duration_minutes, "resets_at": self.resets_at}


@dataclass(frozen=True)
class Quota:
    five_hour: Window
    weekly: Window
    available_credits: object
    credit_id: object

    def as_dict(self):
        return {"five_hour": self.five_hour.as_dict(), "weekly": self.weekly.as_dict(), "available_reset_credits": self.available_credits}


@dataclass(frozen=True)
class Decision:
    action: str
    reason: str
    wait_until: int = 0


def parse_quota(payload, now):
    if not isinstance(payload, dict):
        raise SupervisorError("Missing account quota response")
    buckets = payload.get("rateLimitsByLimitId")
    if buckets is not None:
        if not isinstance(buckets, dict) or "codex" not in buckets:
            raise SupervisorError("Missing Codex quota bucket")
        bucket = buckets["codex"]
    else:
        bucket = payload.get("rateLimits")
    if not isinstance(bucket, dict) or bucket.get("limitId") not in (None, "codex"):
        raise SupervisorError("Invalid Codex quota bucket")
    windows = []
    for name in ("primary", "secondary"):
        raw = bucket.get(name)
        if not isinstance(raw, dict):
            raise SupervisorError("Both five-hour and weekly quota windows are required")
        used = raw.get("usedPercent")
        duration = raw.get("windowDurationMins")
        reset = raw.get("resetsAt")
        if isinstance(used, bool) or not isinstance(used, (int, float)):
            raise SupervisorError("Invalid quota usage")
        try:
            valid_usage = math.isfinite(used) and used >= 0
        except OverflowError:
            valid_usage = False
        if not valid_usage or not integer(duration, 1) or not integer(reset, 1):
            raise SupervisorError("Invalid quota window")
        if reset <= now:
            raise SupervisorError("Stale quota reset timestamp; a fresh server snapshot is required")
        windows.append(Window(used, duration, reset))
    short = [window for window in windows if window.duration_minutes == 300]
    weekly = [window for window in windows if window.duration_minutes >= 10080]
    if len(short) != 1 or len(weekly) != 1:
        raise SupervisorError("Cannot identify five-hour and weekly quota windows")
    reached = bucket.get("rateLimitReachedType")
    if reached not in (None, "rate_limit_reached"):
        raise SupervisorError("Account reports an unsupported workspace usage or credit restriction")
    if reached == "rate_limit_reached" and not any(window.exhausted for window in windows):
        raise SupervisorError("Account limit status conflicts with its quota windows")
    summary = payload.get("rateLimitResetCredits")
    available = None
    credit_id = None
    if summary is not None:
        if not isinstance(summary, dict) or not integer(summary.get("availableCount")):
            raise SupervisorError("Invalid earned reset credit count")
        available = summary["availableCount"]
        details = summary.get("credits")
        if details is not None:
            if not isinstance(details, list):
                raise SupervisorError("Invalid earned reset credit details")
            eligible = []
            for credit in details:
                if not isinstance(credit, dict):
                    raise SupervisorError("Invalid earned reset credit")
                expiry = credit.get("expiresAt")
                if expiry is not None and not integer(expiry, 1):
                    raise SupervisorError("Invalid earned reset credit expiry")
                if credit.get("status") == "available" and credit.get("resetType") == "codexRateLimits":
                    if not isinstance(credit.get("id"), str) or not credit["id"]:
                        raise SupervisorError("Invalid earned reset credit identifier")
                    if expiry is None or expiry > now:
                        eligible.append((expiry if expiry is not None else math.inf, credit["id"]))
            if available and eligible:
                credit_id = min(eligible)[1]
    return Quota(short[0], weekly[0], available, credit_id)


def decide(quota, ledger, now):
    pending = [entry for entry in ledger if entry["status"] == "pending"]
    consumed = sum(entry["status"] == "succeeded" for entry in ledger)
    if quota.weekly.exhausted:
        if pending and consumed + len(pending) <= CREDIT_BUDGET:
            return Decision("consume", "Reconcile the existing weekly reset attempt")
        if consumed < CREDIT_BUDGET and quota.available_credits is not None and quota.available_credits > 0:
            return Decision("consume", "Weekly quota exhausted; earned reset available")
        exhausted = [window.resets_at for window in (quota.five_hour, quota.weekly) if window.exhausted]
        return Decision("wait", "Wait for the account's natural quota reset", max(exhausted))
    if quota.five_hour.exhausted:
        return Decision("wait", "Five-hour quota exhausted; no earned credit may be used", quota.five_hour.resets_at)
    return Decision("run", "Both account quota windows have capacity")


def codex_environment(source=None):
    environment = dict(os.environ if source is None else source)
    for name in ("OPENAI_API_KEY", "CODEX_API_KEY", "AZURE_OPENAI_API_KEY", "OPENAI_ACCESS_TOKEN"):
        environment.pop(name, None)
    return environment


def locate_codex():
    executable = shutil.which("codex")
    if executable:
        return executable
    if BUNDLED_CODEX.is_file() and os.access(BUNDLED_CODEX, os.X_OK):
        return str(BUNDLED_CODEX)
    raise SupervisorError("Codex CLI is unavailable on PATH and at the bundled ChatGPT location")


def terminate_process(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def json_lines(process, deadline):
    pending = b""
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise SupervisorError("Codex subprocess timed out")
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                if pending:
                    raise SupervisorError("Codex returned an incomplete JSONL response")
                return
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                if len(line) > MAX_LINE_BYTES:
                    raise SupervisorError("Codex response exceeded the size bound")
                if line.strip():
                    try:
                        message = json.loads(line)
                    except (ValueError, UnicodeError):
                        raise SupervisorError("Codex returned malformed JSONL") from None
                    if not isinstance(message, dict):
                        raise SupervisorError("Codex returned a non-object response")
                    yield message
            if len(pending) > MAX_LINE_BYTES:
                raise SupervisorError("Codex response exceeded the size bound")
    finally:
        selector.close()


class AccountClient:
    def __init__(self, executable=None, timeout=20):
        self.executable = executable or locate_codex()
        self.timeout = timeout
        self.process = None
        self.request_id = 0
        self.messages = None

    def __enter__(self):
        arguments = [self.executable, "-c", 'forced_login_method="chatgpt"', "-c", 'model_provider="openai"', "app-server", "--listen", "stdio://"]
        try:
            self.process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=codex_environment(), start_new_session=True)
            self.rpc("initialize", {"clientInfo": {"name": "intel_computer_use_supervisor", "version": "1"}, "capabilities": {"experimentalApi": True}})
            self.send({"method": "initialized"})
            account = self.rpc("account/read", {"refreshToken": False})
            identity = account.get("account")
            if not isinstance(identity, dict) or identity.get("type") != "chatgpt":
                raise SupervisorError("Existing Codex ChatGPT sign-in is required; API-key accounts are not supported")
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *arguments):
        if self.messages is not None:
            self.messages.close()
            self.messages = None
        terminate_process(self.process)
        if self.process is not None:
            self.process.stdin.close()
            self.process.stdout.close()

    def send(self, message):
        try:
            self.process.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            raise SupervisorError("Codex account connection closed") from None

    def rpc(self, method, params=None):
        self.request_id += 1
        request = {"id": self.request_id, "method": method}
        if params is not None:
            request["params"] = params
        self.send(request)
        if self.messages is not None:
            self.messages.close()
        self.messages = json_lines(self.process, time.monotonic() + self.timeout)
        for message in self.messages:
            if "method" in message:
                if "id" in message:
                    self.send({"id": message["id"], "error": {"code": -32601, "message": "Unsupported server request"}})
                continue
            if message.get("id") != self.request_id:
                raise SupervisorError("Unexpected Codex account response identifier")
            if "error" in message or not isinstance(message.get("result"), dict):
                raise SupervisorError("Codex account request failed: " + method)
            return message["result"]
        raise SupervisorError("Codex account subprocess exited before replying")

    def read_quota(self):
        return self.rpc("account/rateLimits/read", {"supportsLunaReserve": False})

    def consume(self, key, credit_id=None):
        if not identifier(key):
            raise SupervisorError("A persisted UUID is required for reset redemption")
        params = {"idempotencyKey": key}
        if credit_id is not None:
            params["creditId"] = credit_id
        result = self.rpc("account/rateLimitResetCredit/consume", params)
        outcome = result.get("outcome")
        if outcome not in ("reset", "alreadyRedeemed", "nothingToReset", "noCredit"):
            raise SupervisorError("Unknown earned reset outcome; reservation retained")
        return outcome


def private_descriptor(path, flags):
    descriptor = os.open(path, flags | os.O_NOFOLLOW, 0o600)
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise SupervisorError("Supervisor files must be regular files")
    os.fchmod(descriptor, 0o600)
    return descriptor


class StateStore:
    def __init__(self, root=None):
        self.root = Path(root) if root is not None else STATE_ROOT
        self.path = self.root / "state.json"

    def prepare(self):
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.root.is_symlink() or not self.root.is_dir():
            raise SupervisorError("Supervisor state directory must not be a symlink")
        self.root.chmod(0o700)

    def load(self):
        self.prepare()
        if not self.path.exists() and not self.path.is_symlink():
            return {"version": 1, "project": None, "paused": True, "thread_id": None, "work_status": "idle", "run_in_progress": False, "redemptions": [], "next_action_at": 0, "quota": None, "last_event": "Awaiting explicit resume", "last_checked_at": None}
        try:
            with os.fdopen(private_descriptor(self.path, os.O_RDONLY), "r", encoding="utf-8") as stream:
                state = json.loads(stream.read(MAX_LINE_BYTES))
            self.validate(state)
            return state
        except (OSError, ValueError, KeyError, TypeError):
            raise SupervisorError("Supervisor state is invalid; refusing to reset its credit ledger") from None

    def validate(self, state):
        if not isinstance(state, dict) or state.get("version") != 1:
            raise ValueError("version")
        for field in ("paused", "run_in_progress"):
            if not isinstance(state[field], bool):
                raise ValueError(field)
        if state["project"] is not None and state["project"] != str(PROJECT_ROOT):
            raise ValueError("project")
        if state["thread_id"] is not None and not identifier(state["thread_id"]):
            raise ValueError("thread")
        if state["work_status"] not in ("idle", "continue", "blocked", "completed") or not integer(state["next_action_at"]):
            raise ValueError("work")
        ledger = state["redemptions"]
        if not isinstance(ledger, list) or len(ledger) > 10000:
            raise ValueError("ledger")
        keys = set()
        for entry in ledger:
            if not isinstance(entry, dict) or not identifier(entry["key"]) or entry["key"] in keys:
                raise ValueError("redemption key")
            keys.add(entry["key"])
            if entry["status"] not in ("pending", "succeeded", "not_consumed"):
                raise ValueError("redemption status")
            if entry.get("credit_id") is not None and (not isinstance(entry["credit_id"], str) or not entry["credit_id"]):
                raise ValueError("credit identifier")
        pending = sum(entry["status"] == "pending" for entry in ledger)
        reserved = sum(entry["status"] in ("pending", "succeeded") for entry in ledger)
        if pending > 1 or reserved > CREDIT_BUDGET:
            raise ValueError("credit budget")

    def save(self, state):
        self.prepare()
        self.validate(state)
        descriptor, temporary = tempfile.mkstemp(prefix=".state-", dir=str(self.root))
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                os.fchmod(stream.fileno(), 0o600)
                json.dump(state, stream, indent=2, allow_nan=False)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            directory = os.open(self.root, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def event(self, state, message, now):
        state["last_event"] = message
        self.save(state)
        path = self.root / "events.jsonl"
        descriptor = private_descriptor(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
        with os.fdopen(descriptor, "a", encoding="utf-8") as stream:
            if os.fstat(stream.fileno()).st_size >= MAX_LINE_BYTES:
                stream.close()
                os.replace(path, self.root / "events.previous.jsonl")
                descriptor = private_descriptor(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
                with os.fdopen(descriptor, "a", encoding="utf-8") as fresh:
                    fresh.write(json.dumps({"at": now, "event": message}) + "\n")
            else:
                stream.write(json.dumps({"at": now, "event": message}) + "\n")

    @contextmanager
    def lock(self):
        self.prepare()
        descriptor = private_descriptor(self.root / "worker.lock", os.O_RDWR | os.O_CREAT)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise WorkerBusy("Another supervisor command is active") from None
            yield
        finally:
            os.close(descriptor)


def validate_project(project):
    project = Path(project).expanduser().resolve()
    if project != PROJECT_ROOT or not (project / "ROADMAP.md").is_file():
        raise SupervisorError("The supervisor is restricted to this Intel Computer Use project")
    return project


def validate_outcome(result):
    if not isinstance(result, dict) or set(result) != {"outcome", "summary", "cooldown_seconds"}:
        raise SupervisorError("Worker did not return the required structured outcome")
    if result["outcome"] not in ("completed", "continue", "blocked"):
        raise SupervisorError("Worker returned an unsupported outcome")
    if not isinstance(result["summary"], str) or not result["summary"].strip() or len(result["summary"]) > 2000:
        raise SupervisorError("Worker returned an invalid summary")
    if not integer(result["cooldown_seconds"], 300) or result["cooldown_seconds"] > 86400:
        raise SupervisorError("Worker cooldown must be between 300 and 86400 seconds")
    return result


class JobRunner:
    def __init__(self, executable=None, timeout=900):
        self.executable = executable or locate_codex()
        self.timeout = timeout
        self.process = None

    def __call__(self, state, store, project):
        project = validate_project(project)
        output = store.root / "last-result.json"
        descriptor = private_descriptor(output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        os.close(descriptor)
        configuration = ["-c", 'approval_policy="never"', "-c", 'sandbox_mode="workspace-write"', "-c", 'forced_login_method="chatgpt"', "-c", 'model_provider="openai"', "-c", "sandbox_workspace_write.writable_roots=[]", "-c", "sandbox_workspace_write.network_access=false", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true", "-c", "sandbox_workspace_write.exclude_slash_tmp=true"]
        arguments = [self.executable, "exec", "--sandbox", "workspace-write", "--cd", str(project), "--ignore-user-config"] + configuration
        if state["thread_id"] is not None:
            arguments.extend(["resume", "--ignore-user-config"] + configuration)
        arguments.extend(["--json", "--output-schema", str(project / "docs/supervisor-result.schema.json"), "--output-last-message", str(output)])
        if state["thread_id"] is not None:
            arguments.append(state["thread_id"])
        arguments.append("-")
        prompt = (
            "Work only on Intel Computer Use in " + str(project) + ". Read ROADMAP.md and repository instructions. "
            "Read docs/WORK_QUEUE.md when present and follow its current task order and blockers. "
            "Complete one bounded, verifiable task, then return the required JSON outcome. "
            "Keep all prose and new documentation in English. Preserve unrelated work. "
            "Do not commit, publish, deploy, send messages or email, purchase anything, consume credits, "
            "change account settings, modify supervisor state or configuration, or spawn background workers. "
            "Do not read credentials, token files, password stores, or Downloads. "
            "Respect the workspace-write sandbox and never approval policy. "
            "Phase 2 requires a supported Intel-compatible vendor unlock implementation and trust contract. "
            "Never bypass the macOS lock, fabricate vendor unlock support, or infer that native app control proves locked-session operation. "
            "If external permissions, vendor components, or human decisions are required, record the concrete blocker "
            "in ROADMAP.md and return blocked. Do not repeatedly retry a blocker. "
            "Return completed only when the remaining project goal is achieved, continue only if a specific useful "
            "task can proceed, and blocked otherwise. Use a cooldown of at least 300 seconds. "
            "Summary must contain progress/blockers only, without credentials or private account information."
        )
        deadline = time.monotonic() + self.timeout
        try:
            self.process = subprocess.Popen(arguments, cwd=str(project), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=codex_environment(), start_new_session=True)
            self.process.stdin.write(prompt.encode("utf-8"))
            self.process.stdin.close()
            for message in json_lines(self.process, deadline):
                if message.get("type") == "thread.started":
                    thread_id = message.get("thread_id")
                    if not identifier(thread_id) or state["thread_id"] not in (None, thread_id):
                        raise SupervisorError("Worker returned an unexpected thread identifier")
                    state["thread_id"] = thread_id
                    store.save(state)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SupervisorError("Codex subprocess timed out")
            try:
                exit_code = self.process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                raise SupervisorError("Codex subprocess timed out") from None
            if exit_code != 0:
                raise JobFailed("Codex worker failed; account quotas must be checked before any retry")
            if state["thread_id"] is None:
                raise SupervisorError("Worker did not provide a resumable thread identifier")
            with os.fdopen(private_descriptor(output, os.O_RDONLY), "r", encoding="utf-8") as stream:
                try:
                    result = json.loads(stream.read(16384))
                except ValueError:
                    raise SupervisorError("Worker did not return valid structured JSON") from None
            return validate_outcome(result)
        finally:
            terminate_process(self.process)
            if self.process is not None:
                if not self.process.stdin.closed:
                    self.process.stdin.close()
                self.process.stdout.close()
            if output.exists() and not output.is_symlink():
                output.chmod(0o600)


class Supervisor:
    def __init__(self, store, project, account_factory=None, runner=None, clock=None):
        self.store = store
        self.project = validate_project(project)
        self.account_factory = account_factory or AccountClient
        self.runner = runner
        self.clock = clock or time.time

    def bind(self, state):
        if state["project"] not in (None, str(self.project)):
            raise SupervisorError("Supervisor state belongs to a different project")
        state["project"] = str(self.project)

    def resume(self, not_before=0):
        if not integer(not_before):
            raise SupervisorError("The resume time must be a nonnegative Unix timestamp")
        with self.store.lock():
            state = self.store.load()
            self.bind(state)
            if state["run_in_progress"]:
                raise SupervisorError("An interrupted worker needs recovery; run tick to record the blocker first")
            state.update(paused=False, work_status="continue", next_action_at=not_before)
            self.store.event(state, "Project work explicitly enabled", int(self.clock()))
            return state

    def pause(self):
        with self.store.lock():
            state = self.store.load()
            state["paused"] = True
            self.store.event(state, "Project work paused; account monitoring remains read-only", int(self.clock()))
            return state

    def tick(self):
        with self.store.lock():
            state = self.store.load()
            self.bind(state)
            now = int(self.clock())
            if state["run_in_progress"]:
                state.update(paused=True, run_in_progress=False, work_status="blocked")
                self.store.event(state, "Interrupted worker detected; inspect project and processes before explicit resume", now)
                return state
            try:
                with self.account_factory() as account:
                    quota = parse_quota(account.read_quota(), int(self.clock()))
                    state["quota"] = quota.as_dict()
                    state["last_checked_at"] = int(self.clock())
                    if state["paused"]:
                        self.store.event(state, "Paused; account quota monitored without work or redemption", now)
                        return state
                    if state["next_action_at"] > int(self.clock()):
                        self.store.event(state, "Monitoring account quota until the scheduled next action", now)
                        return state
                    decision = decide(quota, state["redemptions"], int(self.clock()))
                    if decision.action == "consume":
                        pending = next((entry for entry in state["redemptions"] if entry["status"] == "pending"), None)
                        if pending is None:
                            pending = {"key": str(uuid.uuid4()), "status": "pending", "credit_id": quota.credit_id}
                            state["redemptions"].append(pending)
                            self.store.save(state)
                        outcome = account.consume(pending["key"], pending["credit_id"])
                        if outcome not in ("reset", "alreadyRedeemed", "nothingToReset", "noCredit"):
                            raise SupervisorError("Unknown earned reset outcome; reservation retained")
                        pending["status"] = "succeeded" if outcome in ("reset", "alreadyRedeemed") else "not_consumed"
                        self.store.event(state, "Earned weekly reset outcome: " + outcome, int(self.clock()))
                        quota = parse_quota(account.read_quota(), int(self.clock()))
                        state["quota"] = quota.as_dict()
                        state["last_checked_at"] = int(self.clock())
                        decision = decide(quota, state["redemptions"], int(self.clock()))
                        if decision.action == "consume":
                            state["next_action_at"] = quota.weekly.resets_at
                            self.store.event(state, "Weekly quota still exhausted after redemption response; wait for natural reset", now)
                            return state
                    if decision.action == "wait":
                        state["next_action_at"] = decision.wait_until
                        self.store.event(state, decision.reason, now)
                        return state
            except (SupervisorError, OSError):
                state["next_action_at"] = max(state["next_action_at"], int(self.clock()) + RETRY_SECONDS)
                self.store.event(state, "Account quota unavailable or redemption uncertain; fail closed and retry later", int(self.clock()))
                return state
            state["run_in_progress"] = True
            self.store.event(state, "Starting one bounded project task", int(self.clock()))
            try:
                runner = self.runner or JobRunner()
                result = validate_outcome(runner(state, self.store, self.project))
                state["work_status"] = result["outcome"]
                state["summary"] = result["summary"]
                state["paused"] = result["outcome"] != "continue"
                state["next_action_at"] = int(self.clock()) + result["cooldown_seconds"]
                message = "Project task outcome: " + result["outcome"]
            except JobFailed:
                state.update(paused=True, work_status="blocked")
                message = "Worker failed; inspect the recorded project thread before explicit resume"
                try:
                    with self.account_factory() as account:
                        quota = parse_quota(account.read_quota(), int(self.clock()))
                        state["quota"] = quota.as_dict()
                        state["last_checked_at"] = int(self.clock())
                        decision = decide(quota, state["redemptions"], int(self.clock()))
                        if decision.action != "run":
                            state.update(paused=False, work_status="continue", next_action_at=decision.wait_until or int(self.clock()) + RETRY_SECONDS)
                            message = "Worker interrupted with exhausted account quota; wait for the quota gate"
                except (SupervisorError, OSError):
                    pass
            except (SupervisorError, OSError):
                state.update(paused=True, work_status="blocked")
                message = "Worker timed out or returned invalid output; inspect project before explicit resume"
            except BaseException:
                state.update(paused=True, work_status="blocked")
                message = "Worker interrupted; inspect project and recorded thread before explicit resume"
                raise
            finally:
                state["run_in_progress"] = False
                self.store.event(state, locals().get("message", "Worker interrupted; explicit recovery required"), int(self.clock()))
            return state


def install_agent(project, store, destination=None):
    project = validate_project(project)
    if destination is None:
        destination = Path.home() / "Library/LaunchAgents" / (AGENT_LABEL + ".plist")
    destination = Path(destination)
    with store.lock():
        state = store.load()
        state.update(project=str(project), paused=True)
        store.event(state, "LaunchAgent installed paused; activation is explicit", int(time.time()))
        agent = {
            "Label": AGENT_LABEL,
            "ProgramArguments": [sys.executable, str(Path(__file__).resolve()), "tick", "--project", str(project)],
            "WorkingDirectory": str(project),
            "StartInterval": 60,
            "RunAtLoad": False,
            "ProcessType": "Background",
            "ExitTimeOut": 10,
            "StandardOutPath": str(store.root / "launchd.stdout.log"),
            "StandardErrorPath": str(store.root / "launchd.stderr.log"),
            "EnvironmentVariables": {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")},
        }
        for filename in ("launchd.stdout.log", "launchd.stderr.log"):
            os.close(private_descriptor(store.root / filename, os.O_WRONLY | os.O_CREAT))
        destination.parent.mkdir(parents=True, exist_ok=True)
        descriptor = private_descriptor(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        with os.fdopen(descriptor, "wb") as stream:
            plistlib.dump(agent, stream)
        return destination


def status_summary(state):
    succeeded = sum(entry["status"] == "succeeded" for entry in state["redemptions"])
    pending = sum(entry["status"] == "pending" for entry in state["redemptions"])
    return {name: state.get(name) for name in ("paused", "project", "thread_id", "work_status", "run_in_progress", "next_action_at", "last_checked_at", "quota", "last_event", "summary")} | {"reset_budget": {"maximum_total": CREDIT_BUDGET, "confirmed_consumed": succeeded, "uncertain_reserved": pending, "remaining_unreserved": CREDIT_BUDGET - succeeded - pending}}


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("status", "quota", "pause"):
        commands.add_parser(command)
    for command in ("resume", "tick", "install"):
        subparser = commands.add_parser(command)
        subparser.add_argument("--project", type=Path, required=True)
        if command == "resume":
            subparser.add_argument("--not-before", type=int, default=0, help="Earliest work/redemption time, as Unix seconds; monitoring continues")
    args = parser.parse_args(argv)
    store = StateStore()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if args.command == "quota":
            with AccountClient() as account:
                quota = parse_quota(account.read_quota(), time.time())
            result = quota.as_dict()
        elif args.command == "status":
            with store.lock():
                result = status_summary(store.load())
        elif args.command == "install":
            result = {"launch_agent": str(install_agent(args.project, store)), "loaded": False, "paused": True}
        else:
            worker = Supervisor(store, getattr(args, "project", PROJECT_ROOT))
            state = worker.resume(not_before=args.not_before) if args.command == "resume" else getattr(worker, args.command)()
            result = status_summary(state)
        print(json.dumps(result, indent=2, allow_nan=False))
        return 0
    except WorkerBusy:
        print(json.dumps({"status": "busy", "message": "Another supervisor command is active"}))
        return 0 if args.command == "tick" else 1
    except (SupervisorError, OSError):
        print(json.dumps({"status": "error", "message": "Supervisor refused the operation; check CLI sign-in, quota availability, project path, and private state integrity"}), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(json.dumps({"status": "interrupted", "message": "Supervisor stopped; review status before resuming"}), file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
