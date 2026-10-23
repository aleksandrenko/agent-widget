#!/bin/bash
# Renders the README screenshots from the demo data in docs/demo (no live data involved).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
BIN=$(ls -d /Applications/BirdWatcher.app ~/Applications/BirdWatcher.app 2>/dev/null | head -1)/Contents/MacOS/BirdWatcher
[ -x "$BIN" ] || ./build.sh
TMP=$(mktemp -d)
for demo in docs/demo/*/; do
    name=$(basename "$demo")
    "$BIN" --demo "$PWD/$demo" --snapshot "$TMP/$name.png"
    swift tools/compose.swift "$TMP/$name.png" "docs/screenshots/$name.png"
    echo "docs/screenshots/$name.png"
done
