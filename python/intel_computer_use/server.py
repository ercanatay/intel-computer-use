import base64
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


class ToolError(Exception):
    pass


APP = {"type": "string", "minLength": 3, "maxLength": 255, "description": "Exact allowlisted macOS bundle ID."}
WINDOW = {"type": "integer", "minimum": 1, "maximum": 4294967295}
POINT = {"type": "number", "minimum": 0, "maximum": 100000}


def tool(name, description, properties=None, required=None, read_only=False):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties or {}, "required": required or [], "additionalProperties": False},
            "annotations": {"readOnlyHint": read_only, "destructiveHint": not read_only, "openWorldHint": False}}


TARGET = {"bundle_id": APP, "window_id": WINDOW}
TOOLS = [
    tool("status", "Read permission and lock state without requesting permissions.", read_only=True),
    tool("list_apps", "List running allowlisted applications.", read_only=True),
    tool("open_app", "Open an explicitly allowlisted app in the foreground.", {"bundle_id": APP}, ["bundle_id"]),
    tool("list_windows", "List visible windows belonging to an allowlisted app.", {"bundle_id": APP}, ["bundle_id"], True),
    tool("snapshot", "Read Accessibility text and optionally a screenshot of a window. Coordinates are window-relative logical points. Observe again after every action.", {**TARGET, "include_screenshot": {"type": "boolean"}}, ["bundle_id", "window_id"], True),
    tool("click", "Click inside the exact window from the latest snapshot, using window-relative logical points.", {**TARGET, "x": POINT, "y": POINT, "button": {"type": "string", "enum": ["left", "right"]}, "click_count": {"type": "integer", "minimum": 1, "maximum": 2}}, ["bundle_id", "window_id", "x", "y"]),
    tool("type_text", "Type literal Unicode text without using the clipboard.", {**TARGET, "text": {"type": "string", "minLength": 1, "maxLength": 16384}}, ["bundle_id", "window_id", "text"]),
    tool("press_key", "Press Return, cmd+a, ctrl+shift+a, Left, etc. Letter shortcuts use physical US key positions.", {**TARGET, "key": {"type": "string", "minLength": 1, "maxLength": 80}}, ["bundle_id", "window_id", "key"]),
    tool("scroll", "Scroll inside the selected window at a recently observed point.", {**TARGET, "x": POINT, "y": POINT, "direction": {"type": "string", "enum": ["up", "down", "left", "right"]}, "pixels": {"type": "integer", "minimum": 1, "maximum": 2000}}, ["bundle_id", "window_id", "x", "y", "direction"]),
]
CATALOG = {entry["name"]: entry for entry in TOOLS}
PROTECTED = ("com.openai.", "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp", "com.apple.loginwindow", "com.apple.securityagent", "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.passwords", "com.agilebits.", "com.1password.", "com.bitwarden.")


def validate_arguments(name, arguments):
    if name not in CATALOG:
        raise ToolError("Unknown tool: " + str(name))
    if not isinstance(arguments, dict):
        raise ToolError("Tool arguments must be an object.")
    schema = CATALOG[name]["inputSchema"]
    if set(arguments) - set(schema["properties"]):
        raise ToolError("Unknown tool arguments.")
    if set(schema["required"]) - set(arguments):
        raise ToolError("Missing required tool arguments.")
    for field, value in arguments.items():
        rule = schema["properties"][field]
        kind = rule["type"]
        if kind == "string":
            valid = isinstance(value, str) and rule.get("minLength", 0) <= len(value) <= rule.get("maxLength", 65536)
        elif kind == "boolean":
            valid = type(value) is bool
        elif kind == "integer":
            valid = type(value) is int and rule.get("minimum", -math.inf) <= value <= rule.get("maximum", math.inf)
        else:
            valid = type(value) in (int, float) and rule.get("minimum", -math.inf) <= value <= rule.get("maximum", math.inf) and math.isfinite(value)
        if not valid or ("enum" in rule and value not in rule["enum"]):
            raise ToolError("Invalid value for " + field)
    bundle_id = arguments.get("bundle_id")
    if bundle_id is not None and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]+", bundle_id):
        raise ToolError("Invalid application bundle ID.")
    return dict(arguments)


class NativeBridge:
    def __init__(self, executable, allowed, launcher="/usr/bin/open"):
        self.executable = Path(executable)
        self.allowed = set(allowed)
        self.launcher = str(launcher)

    def launch_bundle(self, bundle, payload):
        with tempfile.TemporaryDirectory(prefix="intel-computer-use-") as directory:
            root = Path(directory)
            request, response, errors = root / "request.json", root / "response.json", root / "stderr"
            for path in (request, response, errors):
                descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                os.close(descriptor)
            request.write_text(payload, encoding="utf-8")
            completed = subprocess.run([self.launcher, "-n", "-W", "-g", "-a", str(bundle), "--stdin", str(request), "--stdout", str(response), "--stderr", str(errors), "--env", "ICU_ALLOWED_BUNDLE_IDS=" + ",".join(sorted(self.allowed))], capture_output=True, text=True, timeout=25)
            if completed.returncode:
                raise ToolError("LaunchServices could not start Intel Computer Use. Rebuild and reinstall the separate helper app.")
            if response.stat().st_size > 24 * 1024 * 1024:
                raise ToolError("Native helper response exceeded the size limit.")
            return subprocess.CompletedProcess(completed.args, 0, response.read_text(encoding="utf-8"), "")

    def call(self, command, arguments):
        if not self.executable.is_file():
            raise ToolError("Native helper is missing. Run ./scripts/build.sh first.")
        environment = dict(os.environ, ICU_ALLOWED_BUNDLE_IDS=",".join(sorted(self.allowed)))
        payload = json.dumps({"command": command, **arguments, "deadline_unix_milliseconds": int((time.time() + 20) * 1000)}, ensure_ascii=True)
        try:
            bundle = self.executable.parent.parent.parent
            if bundle.suffix == ".app" and bundle.is_dir():
                completed = self.launch_bundle(bundle, payload)
            else:
                completed = subprocess.run([str(self.executable)], input=payload, capture_output=True, text=True, env=environment, timeout=25)
        except subprocess.TimeoutExpired:
            raise ToolError("Native helper timed out. Check macOS permissions and the target application's responsiveness.") from None
        except OSError as error:
            raise ToolError("Unable to launch the native helper: " + str(error)) from None
        if len(completed.stdout) > 24 * 1024 * 1024:
            raise ToolError("Native helper response exceeded the size limit.")
        try:
            response = json.loads(completed.stdout)
        except (ValueError, TypeError):
            raise ToolError("Native helper returned invalid JSON (exit status %s)." % completed.returncode) from None
        if not isinstance(response, dict) or type(response.get("ok")) is not bool:
            raise ToolError("Native helper returned an invalid response envelope.")
        if completed.returncode != 0 or not response["ok"]:
            error = response.get("error", {})
            raise ToolError(error.get("message", "Native operation failed.") if isinstance(error, dict) else "Native operation failed.")
        if not isinstance(response.get("data"), dict):
            raise ToolError("Native helper returned invalid result data.")
        return response["data"]


class MCPServer:
    def __init__(self, native, allowed):
        self.native = native
        self.allowed = set(allowed)
        self.initialized = False
        self.ready = False

    @staticmethod
    def error(request_id, code, message):
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}

    def handle(self, request):
        if not isinstance(request, dict):
            return self.error(None, -32600, "Invalid Request")
        request_id = request.get("id")
        if request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str) or not isinstance(request.get("params", {}), dict) or ("id" in request and type(request_id) not in (int, str)):
            return self.error(None, -32600, "Invalid Request")
        method = request["method"]
        params = request.get("params", {})
        if "id" not in request:
            if method == "notifications/initialized" and self.initialized:
                self.ready = True
            return None
        if method == "initialize":
            if self.initialized:
                return self.error(request_id, -32600, "Already initialized")
            self.initialized = True
            versions = {"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}
            version = params.get("protocolVersion", "")
            result = {"protocolVersion": version if isinstance(version, str) and version in versions else "2025-11-25", "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": "intel-computer-use", "version": "0.1.0"}, "instructions": "Independent native tools. Only allowlisted apps are accessible. The Mac must remain unlocked. Take a fresh snapshot after every action. This does not enable official Locked Use."}
        elif method == "ping":
            result = {}
        elif not self.ready:
            return self.error(request_id, -32002, "Initialize the server first")
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            try:
                name = params.get("name")
                if not isinstance(name, str):
                    raise ToolError("Tool name must be a string.")
                arguments = validate_arguments(name, params.get("arguments", {}))
                bundle_id = arguments.get("bundle_id")
                if bundle_id and (bundle_id not in self.allowed or bundle_id.lower().startswith(PROTECTED)):
                    raise ToolError("Application is not allowed by this server's launch policy.")
                data = self.native.call(name, arguments)
                screenshot = data.pop("screenshot_base64", None)
                content = [{"type": "text", "text": json.dumps(data, ensure_ascii=True)}]
                if screenshot:
                    try:
                        decoded = base64.b64decode(screenshot, validate=True)
                    except (ValueError, TypeError):
                        raise ToolError("Native helper returned an invalid screenshot.") from None
                    if not decoded.startswith(b"\x89PNG\r\n\x1a\n") or len(decoded) > 16 * 1024 * 1024:
                        raise ToolError("Native helper returned an invalid or oversized PNG.")
                    content.append({"type": "image", "data": screenshot, "mimeType": "image/png"})
                result = {"content": content, "isError": False}
            except ToolError as error:
                result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
        else:
            return self.error(request_id, -32601, "Method not found")
        return {"jsonrpc": "2.0", "id": request_id, "result": result}


def serve(server):
    limit = 1024 * 1024
    while True:
        line = sys.stdin.buffer.readline(limit + 1)
        if not line:
            return
        if len(line) > limit:
            while line and not line.endswith(b"\n"):
                line = sys.stdin.buffer.readline(limit + 1)
            response = server.error(None, -32700, "Message exceeds the 1 MiB limit")
        else:
            try:
                request = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
                response = server.handle(request)
            except (ValueError, UnicodeError, RecursionError):
                response = server.error(None, -32700, "Parse error")
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=True, allow_nan=False) + "\n")
            sys.stdout.flush()
