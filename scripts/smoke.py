#!/usr/bin/env python3
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from intel_computer_use.server import MCPServer, NativeBridge, ToolError


def main():
    helper = Path.home() / "Applications/Intel Computer Use.app/Contents/MacOS/intel-computer-use-native"
    allowed = {"com.apple.calculator"}
    server = MCPServer(NativeBridge(helper, allowed), allowed)
    server.handle({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}})
    server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
    request_id = 0

    def call(name, **arguments):
        nonlocal request_id
        request_id += 1
        response = server.handle({"jsonrpc": "2.0", "id": request_id, "method": "tools/call", "params": {"name": name, "arguments": arguments}})["result"]
        if response.get("isError"):
            raise ToolError(response["content"][0]["text"])
        return json.loads(response["content"][0]["text"])

    status = call("status")
    if not status["accessibility"] or status["session"] != "unlocked":
        print("Live input test requires an unlocked session and user-granted Accessibility permission.")
        return 2
    call("open_app", bundle_id="com.apple.calculator")
    windows = []
    for attempt in range(20):
        windows = call("list_windows", bundle_id="com.apple.calculator")["windows"]
        if windows:
            break
        time.sleep(0.1)
    if not windows:
        raise ToolError("Calculator did not expose a visible window.")
    window = max(windows, key=lambda entry: entry["width"] * entry["height"])
    target = {"bundle_id": "com.apple.calculator", "window_id": window["window_id"]}
    call("snapshot", **target, include_screenshot=False)
    for key in ["Escape", "1", "2", "shift+equal", "3", "0", "Return"]:
        call("press_key", **target, key=key)
        time.sleep(0.08)
        call("snapshot", **target, include_screenshot=False)
    result = call("snapshot", **target, include_screenshot=False)
    values = [str(node.get("value", "")) for node in result["nodes"]]
    titles = [str(node.get("title", "")) for node in result["nodes"]]
    if not any("42" in value for value in values + titles):
        raise ToolError("Calculator input completed, but the Accessibility result did not verify 42.")
    print("Verified live Calculator through MCP: 12 + 30 = 42.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ToolError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
