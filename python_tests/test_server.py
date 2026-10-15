import json
import math
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest

from intel_computer_use.server import MCPServer, NativeBridge, ToolError, validate_arguments
from intel_computer_use.doctor import inspect_vendor, macho_architectures


class RecordingNative:
    def __init__(self):
        self.calls = []

    def call(self, command, arguments):
        self.calls.append((command, arguments))
        return {"command": command, "session": "unlocked"}


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.native = RecordingNative()
        self.server = MCPServer(self.native, {"com.apple.calculator"})

    def request(self, method, params=None, request_id=1):
        return self.server.handle({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})

    def initialize(self):
        self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
        self.server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def test_native_tools_cannot_run_before_initialization(self):
        response = self.request("tools/call", {"name": "list_apps"})
        self.assertIn("error", response)
        self.assertEqual(self.native.calls, [])

    def test_initialize_negotiates_version_without_native_access(self):
        response = self.request("initialize", {"protocolVersion": "future"})
        self.assertEqual(response["result"]["protocolVersion"], "2025-11-25")
        self.assertIn("tools", response["result"]["capabilities"])
        self.assertEqual(self.native.calls, [])

    def test_notifications_never_receive_a_response(self):
        self.assertIsNone(self.server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        self.assertIsNone(self.server.handle({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 2}}))

    def test_duplicate_initialization_is_rejected(self):
        self.initialize()
        self.assertIn("error", self.request("initialize", {"protocolVersion": "2025-11-25"}))

    def test_boolean_request_id_is_rejected(self):
        self.assertEqual(self.request("ping", request_id=True)["error"]["code"], -32600)

    def test_malformed_request_is_rejected(self):
        for request in [[], None, {"jsonrpc": "1.0", "id": 1, "method": "ping"}, {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": []}]:
            with self.subTest(request=request):
                self.assertEqual(self.server.handle(request)["error"]["code"], -32600)

    def test_tool_catalog_exposes_native_control(self):
        self.initialize()
        tools = self.request("tools/list")["result"]["tools"]
        names = {tool["name"] for tool in tools}
        self.assertTrue({"snapshot", "click", "type_text", "press_key", "scroll", "open_app"} <= names)
        self.assertNotIn("unlock", names)
        for tool in tools:
            self.assertFalse(tool["inputSchema"]["additionalProperties"])

    def test_denied_app_never_reaches_native_helper(self):
        self.initialize()
        response = self.request("tools/call", {"name": "snapshot", "arguments": {"bundle_id": "com.apple.TextEdit", "window_id": 10}})
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(self.native.calls, [])

    def test_allowlisted_terminal_is_still_blocked(self):
        self.server.allowed.add("com.apple.Terminal")
        self.initialize()
        response = self.request("tools/call", {"name": "open_app", "arguments": {"bundle_id": "com.apple.Terminal"}})
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(self.native.calls, [])

    def test_allowlisted_apple_passwords_is_still_blocked(self):
        self.server.allowed.add("com.apple.Passwords")
        self.initialize()
        response = self.request("tools/call", {"name": "open_app", "arguments": {"bundle_id": "com.apple.Passwords"}})
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(self.native.calls, [])

    def test_allowed_tool_reaches_helper_with_exact_arguments(self):
        self.initialize()
        arguments = {"bundle_id": "com.apple.calculator", "window_id": 10, "x": 0, "y": 12}
        response = self.request("tools/call", {"name": "click", "arguments": arguments})
        self.assertFalse(response["result"].get("isError", False))
        self.assertEqual(self.native.calls, [("click", arguments)])

    def test_unknown_tool_and_unknown_method_have_correct_error_layers(self):
        self.initialize()
        self.assertTrue(self.request("tools/call", {"name": "unlock"})["result"]["isError"])
        self.assertEqual(self.request("not/a/method")["error"]["code"], -32601)


class ValidationTests(unittest.TestCase):
    def test_malformed_numbers_are_rejected(self):
        for value in [True, "1", -1, math.nan, math.inf, 10 ** 400]:
            with self.subTest(value=value):
                with self.assertRaises(ToolError):
                    validate_arguments("click", {"bundle_id": "com.apple.calculator", "window_id": 1, "x": value, "y": 0})

    def test_non_positive_or_boolean_window_ids_are_rejected(self):
        for value in [0, -1, True, 1.2]:
            with self.assertRaises(ToolError):
                validate_arguments("snapshot", {"bundle_id": "com.apple.calculator", "window_id": value})

    def test_unknown_arguments_are_rejected(self):
        with self.assertRaises(ToolError):
            validate_arguments("status", {"allow_all": True})

    def test_text_size_is_bounded(self):
        with self.assertRaises(ToolError):
            validate_arguments("type_text", {"bundle_id": "com.apple.calculator", "window_id": 1, "text": "a" * 16385})

    def test_unicode_text_is_preserved(self):
        arguments = {"bundle_id": "com.apple.TextEdit", "window_id": 1, "text": "İstanbul 🧿\nhello"}
        self.assertEqual(validate_arguments("type_text", arguments)["text"], "İstanbul 🧿\nhello")


class NativeAdapterTests(unittest.TestCase):
    def test_app_bundle_uses_launchservices_and_private_temporary_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "Intel Computer Use.app/Contents/MacOS/native"
            helper.parent.mkdir(parents=True)
            helper.write_bytes(b"not directly executable")
            launcher = root / "open"
            launcher.write_text("#!/usr/bin/env python3\nimport json,os,pathlib,stat,sys\nargs=sys.argv[1:]\nrequest=pathlib.Path(args[args.index('--stdin')+1])\nresponse=pathlib.Path(args[args.index('--stdout')+1])\npayload=json.loads(request.read_text())\nassert stat.S_IMODE(request.parent.stat().st_mode)==0o700\nassert stat.S_IMODE(request.stat().st_mode)==0o600\nassert '--env' in args\nassert args[args.index('--env')+1]=='ICU_ALLOWED_BUNDLE_IDS=com.apple.calculator'\nresponse.write_text(json.dumps({'ok':True,'data':{'received':payload,'temporary_directory':str(request.parent)}}))\n")
            launcher.chmod(0o755)
            result = NativeBridge(helper, {"com.apple.calculator"}, launcher=launcher).call("status", {})
            self.assertEqual(result["received"]["command"], "status")
            self.assertFalse(Path(result["temporary_directory"]).exists())

    def test_missing_helper_returns_actionable_error(self):
        with self.assertRaisesRegex(ToolError, "build"):
            NativeBridge(Path("/nonexistent/icu-helper"), set()).call("status", {})

    def test_real_subprocess_receives_json_and_allowlist_without_shell(self):
        with tempfile.TemporaryDirectory(prefix="icu test ") as directory:
            helper = Path(directory) / "native helper"
            helper.write_text("#!/usr/bin/env python3\nimport json,os,sys\npayload=json.load(sys.stdin)\nprint(json.dumps({'ok':True,'data':{'received':payload,'allow':os.environ.get('ICU_ALLOWED_BUNDLE_IDS')}}))\n")
            helper.chmod(0o755)
            result = NativeBridge(helper, {"com.apple.calculator"}).call("type_text", {"text": "$(touch should-not-exist)"})
            self.assertEqual(result["received"]["text"], "$(touch should-not-exist)")
            self.assertEqual(result["received"]["command"], "type_text")
            self.assertEqual(result["allow"], "com.apple.calculator")
            self.assertFalse((Path(directory) / "should-not-exist").exists())

    def test_native_errors_remain_tool_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            helper = Path(directory) / "helper"
            helper.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"ok":false,"error":{"code":"permission_denied","message":"Enable Accessibility"}}\'\n')
            helper.chmod(0o755)
            with self.assertRaisesRegex(ToolError, "Accessibility"):
                NativeBridge(helper, set()).call("status", {})


class DoctorTests(unittest.TestCase):
    def test_distinguishes_intel_and_arm_only_native_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "helper"
            binary.write_bytes(struct.pack("<IIIIIIII", 0xFEEDFACF, 0x01000007, 3, 2, 0, 0, 0, 0))
            self.assertEqual(macho_architectures(binary), ["x86_64"])
            binary.write_bytes(struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0))
            self.assertEqual(macho_architectures(binary), ["arm64"])

    def test_universal_payload_reports_both_architectures(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "helper"
            binary.write_bytes(struct.pack(">II", 0xCAFEBABE, 2) + struct.pack(">IIIII", 0x01000007, 3, 4096, 100, 12) + struct.pack(">IIIII", 0x0100000C, 0, 8192, 100, 12))
            self.assertEqual(macho_architectures(binary), ["arm64", "x86_64"])

    def test_invalid_binary_is_not_reported_as_intel_compatible(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "helper"
            binary.write_bytes(b"not a Mach-O payload")
            self.assertEqual(macho_architectures(binary), [])

    def test_missing_vendor_helper_does_not_claim_locked_use_support(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = inspect_vendor(root / "ChatGPT.app", root / "codex")
            self.assertFalse(report["vendor_app_present"])
            self.assertFalse(report["official_helper_present"])
            self.assertEqual(report["locked_use"], "unverified")

    def test_helper_presence_is_not_confused_with_working_locked_use(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"
            helper.parent.mkdir(parents=True)
            helper.write_bytes(b"not a real executable")
            report = inspect_vendor(root / "ChatGPT.app", root / "codex")
            self.assertTrue(report["official_helper_present"])
            self.assertEqual(report["locked_use"], "unverified")


class StdioTests(unittest.TestCase):
    def test_real_stdio_survives_invalid_json_and_handles_eof(self):
        requests = '\n'.join([
            '{broken',
            json.dumps({"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {"protocolVersion": "2025-11-25"}}),
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json.dumps({"jsonrpc": "2.0", "id": 0, "method": "tools/list"})
        ]) + '\n'
        completed = subprocess.run([sys.executable, "-m", "intel_computer_use", "serve"], input=requests, text=True, capture_output=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        responses = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[0]["error"]["code"], -32700)
        self.assertEqual(responses[1]["id"], "init")
        self.assertEqual(responses[2]["id"], 0)
        self.assertIn("tools", responses[2]["result"])


if __name__ == "__main__":
    unittest.main()
