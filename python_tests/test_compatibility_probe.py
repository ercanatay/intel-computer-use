import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts" / "compatibility_probe.mjs"
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "Node.js is optional; installed-client checks skipped")
class CompatibilityProbeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="icu-probe-test-")
        self.base = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def evaluate(self, body, timeout=6):
        source = "import * as probe from " + json.dumps(PROBE.as_uri()) + ";\n" + body
        return subprocess.run([NODE, "--input-type=module", "-e", source], capture_output=True, text=True, timeout=timeout)

    def fixture(self, source):
        executable = self.base / "inert-child"
        executable.write_text("#!" + NODE + "\n" + source, encoding="utf-8")
        executable.chmod(0o700)
        return executable

    def run_fixture(self, source, budget=2000):
        executable = self.fixture(source)
        completed = self.evaluate(
            "const result = await probe.runDiagnostic(" + json.dumps(str(executable))
            + ", async () => { throw new Error('must not exercise'); }, " + str(budget)
            + "); process.stdout.write(JSON.stringify(result));"
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout), completed

    def test_missing_client_is_skipped(self):
        completed = subprocess.run([NODE, str(PROBE), "--app", str(self.base / "absent.app"), "--service", str(self.base / "absent")], capture_output=True, text=True, timeout=5)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["outcome"], "skipped")
        self.assertEqual(completed.stderr, "")

    def test_unknown_flags_do_not_spawn(self):
        completed = subprocess.run([NODE, str(PROBE), "--trust-peer"], capture_output=True, text=True, timeout=5)
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(json.loads(completed.stdout)["reason"], "invalidArguments")

    def test_missing_executable_is_skipped(self):
        completed = self.evaluate("console.log(JSON.stringify(await probe.runDiagnostic(" + json.dumps(str(self.base / "missing")) + ", async () => ({}), 300)));")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["outcome"], "skipped")

    def test_changed_client_hash_never_imports(self):
        target = self.base / "app" / "Contents" / "Resources" / "cua_node" / "lib" / "node_modules" / "@oai" / "sky" / "dist" / "project" / "cua" / "sky_js" / "src" / "targets" / "mac"
        target.mkdir(parents=True)
        for filename in ("client.js", "native-pipe.js"):
            (target / filename).write_text("throw new Error('not imported');", encoding="utf-8")
        completed = self.evaluate("console.log(JSON.stringify(await probe.inspectClient(" + json.dumps(str(self.base / "app")) + ", async () => ({version:'26.1007.71326',build:'20398'}))));")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["reason"], "clientChanged")

    def test_unsafe_service_is_skipped_and_stderr_is_private(self):
        result, completed = self.run_fixture("process.stderr.write('SECRET_METADATA_123'); process.exit(2);")
        self.assertEqual(result["outcome"], "skipped")
        self.assertNotIn("SECRET_METADATA", completed.stdout + completed.stderr)

    def test_early_exit_is_failure(self):
        result, _ = self.run_fixture("process.exit(1);")
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(result["reason"], "serviceExited")

    def test_truncated_readiness_is_failure(self):
        result, _ = self.run_fixture("require('fs').writeSync(3, '{\"socketPath\":'); require('fs').closeSync(3); setInterval(()=>{},1000);")
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(result["reason"], "diagnosticFailed")

    def test_oversized_readiness_is_failure(self):
        result, _ = self.run_fixture("require('fs').writeSync(3, 'x'.repeat(4097)); require('fs').closeSync(3); setInterval(()=>{},1000);")
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(result["reason"], "diagnosticFailed")

    def test_timeout_terminates_owned_child(self):
        pid_file = self.base / "pid"
        result, _ = self.run_fixture("require('fs').writeFileSync(" + json.dumps(str(pid_file)) + ", String(process.pid)); setInterval(()=>{},1000);", budget=1000)
        self.assertEqual(result["reason"], "timeout")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_file.read_text()), 0)

    def test_environment_drops_tokens_and_overrides(self):
        completed = self.evaluate("const env = probe.safeEnvironment({PATH:'/usr/bin',HOME:'/home/test',GITHUB_TOKEN:'SECRET',OPENAI_API_KEY:'SECRET',SKY_CUA_SERVICE_PATH:'vendor',NODE_OPTIONS:'--inspect'}); console.log(JSON.stringify(env));")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        environment = json.loads(completed.stdout)
        self.assertEqual(environment, {"PATH": "/usr/bin", "HOME": "/home/test"})

    def test_overall_timeout_also_bounds_client_preflight(self):
        completed = self.evaluate("const start=performance.now(); const report=await probe.probe('/missing.app','/must-not-launch',{versionReader:()=>new Promise(resolve=>setTimeout(()=>resolve({version:'unknown',build:'0'}),500)),timeoutMilliseconds:50}); console.log(JSON.stringify({report,elapsed:performance.now()-start}));")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["report"]["reason"], "timeout")
        self.assertLess(result["elapsed"], 450)

    def test_timeout_terminates_owned_descendants(self):
        pid_file = self.base / "descendant"
        source = "const child=require('child_process').spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'}); require('fs').writeFileSync(" + json.dumps(str(pid_file)) + ",String(child.pid)); setInterval(()=>{},1000);"
        result, _ = self.run_fixture(source, budget=1000)
        self.assertEqual(result["reason"], "timeout")
        descendant = int(pid_file.read_text())
        for _ in range(100):
            try:
                os.kill(descendant, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            self.fail("Harness-owned descendant survived cleanup")

    def test_vendor_endpoint_is_rejected(self):
        result, _ = self.run_fixture("require('fs').writeSync(3, JSON.stringify({protocol:'CodexComputerUseIPC-5',socketPath:'/tmp/computeruse.sock'})+'\\n'); require('fs').closeSync(3); setInterval(()=>{},1000);")
        self.assertEqual(result["outcome"], "failed")

    def private_endpoint_fixture(self):
        root = subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()
        return """
const fs = require('fs'), net = require('net'), path = require('path');
const directory = fs.mkdtempSync(path.join(ROOT_PLACEHOLDER, 'icu.'));
fs.chmodSync(directory, 0o700);
const endpoint = path.join(directory, 'ipc.sock');
const server = net.createServer();
server.listen(endpoint, () => {
  fs.chmodSync(endpoint, 0o600);
  fs.writeSync(3, JSON.stringify({protocol:'CodexComputerUseIPC-5',socketPath:endpoint})+'\\n');
  fs.closeSync(3);
});
process.on('SIGTERM', () => server.close(() => {
  if (fs.existsSync(endpoint)) fs.unlinkSync(endpoint);
  fs.rmdirSync(directory); process.exit(0);
}));
""".replace("ROOT_PLACEHOLDER", json.dumps(root))

    @unittest.skipUnless(sys.platform == "darwin", "Mac private-temp readiness fixture")
    def test_real_private_readiness_accepts_system_path_alias(self):
        executable = self.fixture(self.private_endpoint_fixture())
        completed = self.evaluate("console.log(JSON.stringify(await probe.runDiagnostic(" + json.dumps(str(executable)) + ", async () => ({fixtureOnly:true}), 2000)));")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), {"outcome": "passed", "checks": {"fixtureOnly": True}})

    @unittest.skipUnless(sys.platform == "darwin", "Mac private-temp readiness fixture")
    def test_synthetic_request_exception_is_not_reflected(self):
        executable = self.fixture(self.private_endpoint_fixture())
        completed = self.evaluate("console.log(JSON.stringify(await probe.runDiagnostic(" + json.dumps(str(executable)) + ", async () => {throw new Error('SECRET_SYNTHETIC_METADATA_123');}, 2000)));")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["reason"], "diagnosticFailed")
        self.assertNotIn("SECRET_SYNTHETIC", completed.stdout + completed.stderr)
