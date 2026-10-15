#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release --product intel-computer-use-compat
binary_directory="$(swift build -c release --show-bin-path)"
bundle="$project_root/dist/Intel Compatibility Diagnostic.app"
mkdir -p "$bundle/Contents/MacOS"
install -m 755 "$binary_directory/intel-computer-use-compat" "$bundle/Contents/MacOS/intel-computer-use-compat"
install -m 644 resources/compatibility/Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign "${ICU_COMPAT_SIGNING_IDENTITY:--}" --identifier io.github.ercanatay.intel-computer-use.compat "$bundle"
codesign --verify --strict "$bundle"
file "$bundle/Contents/MacOS/intel-computer-use-compat"
printf 'Built diagnostic bundle only: %s\n' "$bundle"
