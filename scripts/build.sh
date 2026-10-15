#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build -c release --product intel-computer-use-native
binary_directory="$(swift build -c release --show-bin-path)"
bundle="$project_root/dist/Intel Computer Use.app"
mkdir -p "$bundle/Contents/MacOS"
install -m 755 "$binary_directory/intel-computer-use-native" "$bundle/Contents/MacOS/intel-computer-use-native"
/usr/bin/python3 - "$bundle/Contents/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "wb") as handle:
    plistlib.dump({
        "CFBundleIdentifier": "io.github.ercanatay.intel-computer-use",
        "CFBundleName": "Intel Computer Use",
        "CFBundleDisplayName": "Intel Computer Use",
        "CFBundleExecutable": "intel-computer-use-native",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "Independent community software; not affiliated with OpenAI.",
    }, handle)
PY
codesign --force --sign "${ICU_SIGNING_IDENTITY:--}" --identifier io.github.ercanatay.intel-computer-use "$bundle"
codesign --verify --strict "$bundle"
file "$bundle/Contents/MacOS/intel-computer-use-native"
printf 'Built %s\n' "$bundle"
