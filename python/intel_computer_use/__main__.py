import argparse
import json
from pathlib import Path
import sys

from .doctor import inspect_vendor
from .server import MCPServer, NativeBridge, ToolError, serve


def main():
    parser = argparse.ArgumentParser(description="Independent native desktop tools for Intel macOS.")
    parser.add_argument("command", choices=["serve", "doctor", "status"])
    parser.add_argument("--allow", action="append", default=[], metavar="BUNDLE_ID", help="Allow an exact bundle ID; repeat for more apps.")
    parser.add_argument("--helper", type=Path, default=Path.home() / "Applications/Intel Computer Use.app/Contents/MacOS/intel-computer-use-native")
    arguments = parser.parse_args()
    native = NativeBridge(arguments.helper, set(arguments.allow))
    if arguments.command == "serve":
        serve(MCPServer(native, set(arguments.allow)))
        return 0
    if arguments.command == "doctor":
        report = inspect_vendor()
        try:
            report["independent_helper"] = native.call("status", {})
        except ToolError as error:
            report["independent_helper"] = {"error": str(error)}
        print(json.dumps(report, indent=2))
        return 0
    try:
        print(json.dumps(native.call("status", {}), indent=2))
        return 0
    except ToolError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
