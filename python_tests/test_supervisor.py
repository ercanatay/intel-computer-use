import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from intel_computer_use import supervisor


NOW = 1800000000


def limits(short=20, weekly=30, available=2, details=None):
    return {
        "rateLimits": {
            "limitId": "codex",
            "primary": {"usedPercent": short, "windowDurationMins": 300, "resetsAt": NOW + 600},
            "secondary": {"usedPercent": weekly, "windowDurationMins": 10080, "resetsAt": NOW + 3600},
            "rateLimitReachedType": None,
        },
        "rateLimitResetCredits": {"availableCount": available, "credits": details},
    }


class QuotaTests(unittest.TestCase):
    def decision(self, payload, ledger=None):
        quota = supervisor.parse_quota(payload, NOW)
        return supervisor.decide(quota, ledger or [], NOW)

    def test_available_quota_runs(self):
        self.assertEqual(self.decision(limits()).action, "run")

    def test_five_hour_exhaustion_waits_without_spending_credit(self):
        decision = self.decision(limits(short=100))
        self.assertEqual(decision.action, "wait")
        self.assertEqual(decision.wait_until, NOW + 600)

    def test_weekly_exhaustion_earns_one_reset_attempt(self):
        self.assertEqual(self.decision(limits(weekly=100)).action, "consume")

    def test_missing_credits_or_exhausted_lifetime_budget_waits_for_weekly_reset(self):
        for credit_summary in [None, {"availableCount": 0, "credits": None}]:
            payload = limits(weekly=100)
            payload["rateLimitResetCredits"] = credit_summary
            self.assertEqual(self.decision(payload).wait_until, NOW + 3600)
        ledger = [{"key": str(index), "status": "succeeded"} for index in range(3)]
        self.assertEqual(self.decision(limits(weekly=100), ledger).action, "wait")

    def test_natural_reset_is_observed_not_inferred_from_old_snapshot(self):
        payload = limits(weekly=100)
        payload["rateLimits"]["secondary"]["resetsAt"] = NOW
        with self.assertRaises(supervisor.SupervisorError):
            self.decision(payload)
        self.assertEqual(self.decision(limits(weekly=0)).action, "run")

    def test_multi_bucket_codex_view_is_authoritative(self):
        payload = limits()
        payload["rateLimitsByLimitId"] = {"codex": limits(weekly=100)["rateLimits"]}
        self.assertEqual(self.decision(payload).action, "consume")
        payload["rateLimitsByLimitId"] = {"other": limits()["rateLimits"]}
        with self.assertRaises(supervisor.SupervisorError):
            self.decision(payload)

    def test_expired_credit_details_are_not_selected_and_count_is_authoritative(self):
        details = [
            {"id": "expired", "status": "available", "resetType": "codexRateLimits", "grantedAt": NOW - 1000, "expiresAt": NOW},
            {"id": "valid", "status": "available", "resetType": "codexRateLimits", "grantedAt": NOW - 1000, "expiresAt": NOW + 50},
        ]
        quota = supervisor.parse_quota(limits(weekly=100, details=details), NOW)
        self.assertEqual(quota.credit_id, "valid")
        quota = supervisor.parse_quota(limits(weekly=100, details=details[:1]), NOW)
        self.assertIsNone(quota.credit_id)
        self.assertEqual(supervisor.decide(quota, [], NOW).action, "consume")
        self.assertEqual(self.decision(limits(weekly=100, available=0, details=details)).action, "wait")

    def test_uncertain_reservation_can_reconcile_with_no_remaining_credit(self):
        ledger = [{"key": "pending", "status": "pending"}, {"key": "done", "status": "succeeded"}]
        self.assertEqual(self.decision(limits(weekly=100, available=0), ledger).action, "consume")
        self.assertEqual(self.decision(limits(short=100), ledger).action, "wait")

    def test_missing_malformed_or_ambiguous_quota_fails_closed(self):
        cases = [None, {}, {"rateLimits": {}}, limits()]
        cases[-1]["rateLimits"]["secondary"] = None
        for field, bad in [("usedPercent", True), ("usedPercent", float("nan")), ("usedPercent", -1), ("windowDurationMins", 0), ("resetsAt", "tomorrow")]:
            payload = limits()
            payload["rateLimits"]["primary"][field] = bad
            cases.append(payload)
        payload = limits()
        payload["rateLimitResetCredits"]["availableCount"] = True
        cases.append(payload)
        for payload in cases:
            with self.subTest(payload=payload), self.assertRaises(supervisor.SupervisorError):
                self.decision(payload)


class FakeAccount:
    def __init__(self, payload, outcome="reset", failure=False):
        self.payload = payload
        self.outcome = outcome
        self.failure = failure
        self.calls = []
        self.before_consume = None

    def __enter__(self):
        return self

    def __exit__(self, *arguments):
        pass

    def read_quota(self):
        self.calls.append("read")
        return copy.deepcopy(self.payload)

    def consume(self, key, credit_id=None):
        self.calls.append((key, credit_id))
        if self.before_consume:
            self.before_consume(key)
        if self.failure:
            raise supervisor.SupervisorError("Uncertain transport failure")
        if self.outcome in ("reset", "alreadyRedeemed"):
            self.payload = limits(weekly=0)
        return self.outcome


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = supervisor.StateStore(Path(self.directory.name) / "state")
        self.project = supervisor.PROJECT_ROOT
        self.account = FakeAccount(limits())
        self.jobs = []

    def run_job(self, state, store, project):
        self.jobs.append(state.get("thread_id"))
        return {"outcome": "continue", "summary": "One task finished", "cooldown_seconds": 300}

    def worker(self):
        return supervisor.Supervisor(self.store, self.project, lambda: self.account, self.run_job, lambda: NOW)

    def enable(self):
        self.worker().resume()

    def test_default_paused_tick_only_monitors_without_job_or_credit(self):
        self.account.payload = limits(weekly=100)
        self.worker().tick()
        self.assertTrue(self.store.load()["paused"])
        self.assertEqual(self.jobs, [])
        self.assertEqual(self.account.calls, ["read"])

    def test_scheduled_resume_monitors_without_work_until_not_before(self):
        worker = self.worker()
        worker.resume(not_before=NOW + 600)
        self.account.payload = limits(weekly=100)
        worker.tick()
        self.assertFalse(self.store.load()["paused"])
        self.assertEqual(self.store.load()["next_action_at"], NOW + 600)
        self.assertEqual(self.account.calls, ["read"])
        self.assertEqual(self.jobs, [])
        self.account.payload = limits()
        self.account.payload["rateLimits"]["primary"]["resetsAt"] = NOW + 1200
        worker.clock = lambda: NOW + 600
        worker.tick()
        self.assertEqual(len(self.jobs), 1)

    def test_credit_is_reserved_durably_before_rpc_and_counted_once(self):
        self.enable()
        self.account.payload = limits(weekly=100)
        def check_pending(key):
            state = self.store.load()
            self.assertEqual(state["redemptions"], [{"key": key, "status": "pending", "credit_id": None}])
        self.account.before_consume = check_pending
        self.worker().tick()
        state = self.store.load()
        self.assertEqual(state["redemptions"][0]["status"], "succeeded")
        self.assertEqual(self.account.calls[0], "read")
        self.assertEqual(self.account.calls[-1], "read")
        self.assertEqual(len(self.jobs), 1)
        self.worker().tick()
        self.assertEqual(len(self.jobs), 1)
        self.assertEqual(len(state["redemptions"]), 1)

    def test_account_failure_cannot_advance_scheduled_work(self):
        worker = self.worker()
        worker.resume(not_before=NOW + 900)
        self.account.payload = {}
        worker.tick()
        self.assertEqual(self.store.load()["next_action_at"], NOW + 900)
        self.account.payload = limits(weekly=100)
        worker.clock = lambda: NOW + 300
        worker.tick()
        self.assertEqual(self.jobs, [])
        self.assertEqual(self.account.calls, ["read", "read"])
        self.assertEqual(self.store.load()["redemptions"], [])

    def test_uncertain_retry_reuses_key_and_already_redeemed_counts_once(self):
        self.enable()
        self.account.payload = limits(weekly=100)
        self.account.failure = True
        self.worker().tick()
        state = self.store.load()
        key = state["redemptions"][0]["key"]
        self.assertEqual(state["redemptions"][0]["status"], "pending")
        self.assertEqual(self.jobs, [])
        state["next_action_at"] = 0
        self.store.save(state)
        self.account.failure = False
        self.account.outcome = "alreadyRedeemed"
        self.account.payload["rateLimitResetCredits"]["availableCount"] = 0
        self.worker().tick()
        attempts = [call[0] for call in self.account.calls if isinstance(call, tuple)]
        self.assertEqual(attempts, [key, key])
        self.assertEqual([item["status"] for item in self.store.load()["redemptions"]], ["succeeded"])

    def test_no_credit_and_nothing_to_reset_do_not_spin_or_count_as_consumed(self):
        for outcome in ["noCredit", "nothingToReset"]:
            with self.subTest(outcome=outcome):
                self.store = supervisor.StateStore(Path(self.directory.name) / outcome)
                self.enable()
                self.account = FakeAccount(limits(weekly=100), outcome)
                self.worker().tick()
                self.worker().tick()
                state = self.store.load()
                self.assertEqual(state["redemptions"][0]["status"], "not_consumed")
                self.assertEqual(state["next_action_at"], NOW + 3600)
                self.assertEqual(len([call for call in self.account.calls if isinstance(call, tuple)]), 1)
                self.assertEqual(self.jobs, [])

    def test_three_successes_or_pending_reservations_block_fourth_credit(self):
        self.enable()
        state = self.store.load()
        state["redemptions"] = [{"key": str(uuid.uuid4()), "status": "succeeded", "credit_id": None} for index in range(3)]
        self.store.save(state)
        self.account.payload = limits(weekly=100)
        self.worker().tick()
        self.assertEqual(self.account.calls, ["read"])
        self.assertEqual(self.store.load()["next_action_at"], NOW + 3600)

    def test_blocked_completed_or_interrupted_work_never_auto_restarts(self):
        for outcome in ["blocked", "completed"]:
            with self.subTest(outcome=outcome):
                self.store = supervisor.StateStore(Path(self.directory.name) / outcome)
                self.enable()
                worker = self.worker()
                worker.runner = lambda *arguments: {"outcome": outcome, "summary": "External input required", "cooldown_seconds": 300}
                worker.tick()
                worker.tick()
                self.assertTrue(self.store.load()["paused"])
                self.assertEqual(self.store.load()["work_status"], outcome)
        self.store = supervisor.StateStore(Path(self.directory.name) / "interrupted")
        self.enable()
        state = self.store.load()
        state["run_in_progress"] = True
        self.store.save(state)
        self.worker().tick()
        self.assertEqual(self.store.load()["work_status"], "blocked")
        self.assertEqual(self.jobs, [])

    def test_invalid_post_redemption_quota_prevents_inference(self):
        self.enable()
        self.account.payload = limits(weekly=100)
        def break_refresh(key):
            self.account.outcome = "invalid"
        self.account.before_consume = break_refresh
        self.worker().tick()
        self.assertEqual(self.jobs, [])
        self.assertEqual(self.store.load()["redemptions"][0]["status"], "pending")

    def test_successful_credit_is_retained_when_refresh_is_malformed(self):
        self.enable()
        self.account.payload = limits(weekly=100)
        read_quota = self.account.read_quota
        def read_then_break():
            return read_quota() if not any(isinstance(call, tuple) for call in self.account.calls) else {}
        self.account.read_quota = read_then_break
        self.worker().tick()
        self.assertEqual(self.store.load()["redemptions"][0]["status"], "succeeded")
        self.assertEqual(self.jobs, [])

    def test_worker_signal_pauses_and_retains_recorded_thread(self):
        self.enable()
        worker = self.worker()
        def interrupted_job(state, store, project):
            state["thread_id"] = "11111111-1111-4111-8111-111111111111"
            store.save(state)
            raise KeyboardInterrupt
        worker.runner = interrupted_job
        with self.assertRaises(KeyboardInterrupt):
            worker.tick()
        state = self.store.load()
        self.assertTrue(state["paused"])
        self.assertFalse(state["run_in_progress"])
        self.assertEqual(state["work_status"], "blocked")
        self.assertEqual(state["thread_id"], "11111111-1111-4111-8111-111111111111")

    def test_worker_quota_failure_waits_while_other_worker_errors_pause(self):
        self.enable()
        worker = self.worker()
        def failed_job(*arguments):
            self.account.payload = limits(short=100)
            raise supervisor.JobFailed("Quota interrupted the turn")
        worker.runner = failed_job
        worker.tick()
        state = self.store.load()
        self.assertFalse(state["paused"])
        self.assertEqual(state["next_action_at"], NOW + 600)
        self.account.payload = limits()
        state["next_action_at"] = 0
        self.store.save(state)
        worker.runner = lambda *arguments: {"outcome": "continue", "summary": "Missing cooldown"}
        worker.tick()
        self.assertTrue(self.store.load()["paused"])

    def test_project_restriction_rejects_another_directory(self):
        with self.assertRaises(supervisor.SupervisorError):
            supervisor.Supervisor(self.store, Path(self.directory.name))

    def test_symlinked_state_is_not_followed(self):
        self.store.prepare()
        target = Path(self.directory.name) / "other.json"
        target.write_text("private")
        self.store.path.symlink_to(target)
        with self.assertRaises(supervisor.SupervisorError):
            self.store.load()
        self.assertEqual(target.read_text(), "private")

    def test_state_permissions_corruption_and_single_worker_lock(self):
        self.store.save(self.store.load())
        self.assertEqual(self.store.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        with self.store.lock():
            with self.assertRaises(supervisor.WorkerBusy):
                with self.store.lock():
                    pass
        self.store.path.write_text("{}")
        with self.assertRaises(supervisor.SupervisorError):
            self.store.load()

    def test_install_writes_disabled_agent_without_bootstrapping(self):
        destination = Path(self.directory.name) / "agent.plist"
        supervisor.install_agent(self.project, self.store, destination)
        agent = plistlib.loads(destination.read_bytes())
        self.assertEqual(agent["StartInterval"], 60)
        self.assertFalse(agent.get("RunAtLoad", False))
        self.assertEqual(agent["WorkingDirectory"], str(self.project))
        self.assertIn("tick", agent["ProgramArguments"])
        self.assertTrue(self.store.load()["paused"])


class SubprocessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def fake(self, body):
        script = self.root / "fake-codex"
        script.write_text("#!" + sys.executable + "\n" + body)
        script.chmod(0o700)
        return str(script)

    def test_real_jsonl_transport_initializes_and_filters_account_identity(self):
        executable = self.fake('''import json, sys
initialized = False
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    if method == "initialized":
        initialized = True
        continue
    if method == "initialize":
        result = {"userAgent": "fake"}
    elif method == "account/read" and initialized and request["params"] == {"refreshToken": False}:
        result = {"account": {"type": "chatgpt", "email": "private@example.com", "planType": "pro"}, "requiresOpenaiAuth": True}
    elif method == "account/rateLimits/read" and initialized:
        result = ''' + repr(limits()) + '''
    else:
        raise RuntimeError("Unexpected request")
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
''')
        with supervisor.AccountClient(executable=executable, timeout=2) as client:
            self.assertEqual(client.read_quota(), limits())

    def test_api_key_sign_in_is_rejected_without_reading_quotas(self):
        executable = self.fake('''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    result = {} if request["method"] == "initialize" else {"account": {"type": "apiKey"}}
    print(json.dumps({"id": request["id"], "result": result}), flush=True)
''')
        with self.assertRaises(supervisor.SupervisorError):
            with supervisor.AccountClient(executable=executable, timeout=2) as client:
                client.read_quota()

    def test_rpc_timeout_terminates_child(self):
        executable = self.fake("import time\ntime.sleep(60)\n")
        client = supervisor.AccountClient(executable=executable, timeout=0.05)
        with self.assertRaises(supervisor.SupervisorError):
            with client:
                pass
        self.assertIsNotNone(client.process.poll())

    def test_job_persists_thread_and_resumes_that_exact_thread(self):
        transcript = self.root / "arguments.json"
        executable = self.fake('''import json, pathlib, sys
arguments = sys.argv[1:]
pathlib.Path(''' + repr(str(transcript)) + ''').write_text(json.dumps(arguments))
sys.stdin.read()
print(json.dumps({"type": "thread.started", "thread_id": "11111111-1111-4111-8111-111111111111"}), flush=True)
output = arguments[arguments.index("--output-last-message") + 1]
pathlib.Path(output).write_text(json.dumps({"outcome": "continue", "summary": "Verified one item", "cooldown_seconds": 300}))
''')
        store = supervisor.StateStore(self.root / "state")
        state = store.load()
        runner = supervisor.JobRunner(executable=executable, timeout=2)
        result = runner(state, store, supervisor.PROJECT_ROOT)
        self.assertEqual(result["outcome"], "continue")
        self.assertEqual(store.load()["thread_id"], "11111111-1111-4111-8111-111111111111")
        runner(store.load(), store, supervisor.PROJECT_ROOT)
        arguments = json.loads(transcript.read_text())
        self.assertIn("resume", arguments)
        self.assertIn("11111111-1111-4111-8111-111111111111", arguments)
        self.assertNotIn("--last", arguments)
        self.assertIn("workspace-write", arguments)
        self.assertIn("approval_policy=\"never\"", arguments)
        self.assertIn("sandbox_mode=\"workspace-write\"", arguments)
        self.assertIn(str(supervisor.PROJECT_ROOT), arguments)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", arguments)

    def test_timeout_keeps_thread_for_manual_recovery_and_kills_process_group(self):
        executable = self.fake('''import json, time
print(json.dumps({"type": "thread.started", "thread_id": "11111111-1111-4111-8111-111111111111"}), flush=True)
time.sleep(60)
''')
        store = supervisor.StateStore(self.root / "state")
        runner = supervisor.JobRunner(executable=executable, timeout=1)
        with self.assertRaises(supervisor.SupervisorError):
            runner(store.load(), store, supervisor.PROJECT_ROOT)
        self.assertIsNotNone(runner.process.poll())
        self.assertEqual(store.load()["thread_id"], "11111111-1111-4111-8111-111111111111")

    def test_provider_credentials_are_not_forwarded_to_codex(self):
        environment = supervisor.codex_environment({"PATH": "/bin", "OPENAI_API_KEY": "secret", "CODEX_API_KEY": "secret", "AZURE_OPENAI_API_KEY": "secret"})
        self.assertEqual(environment, {"PATH": "/bin"})


if __name__ == "__main__":
    unittest.main()
