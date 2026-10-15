#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$project_root/dist/Intel Computer Use.app"
destination="$HOME/Applications/Intel Computer Use.app"
if [ ! -d "$bundle" ]; then
    bash "$project_root/scripts/build.sh"
fi
codesign --verify --strict "$bundle"
mkdir -p "$HOME/Applications"
if [ -e "$destination" ]; then
    printf 'Already exists: %s\nKeep it or move it aside before installing this build.\n' "$destination" >&2
    exit 1
fi
ditto "$bundle" "$destination"
codesign --verify --strict "$destination"
printf 'Installed %s\n' "$destination"
printf 'Next: run the helper with --setup, then grant macOS permissions yourself.\n'
