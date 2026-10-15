#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
PYTHONPATH=python python3 -m unittest discover -s python_tests -v
swift run bridge-core-checks
swift run compatibility-checks
swift build --product intel-computer-use-compat
swift build --product intel-computer-use-native
