#!/bin/bash
# Renders the README screenshots from the demo data in docs/demo (no live data involved).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
BIN="$HOME/Applications/Agent Widget.app/Contents/MacOS/AgentWidget"
[ -x "$BIN" ] || ./build.sh
TMP=$(mktemp -d)
for demo in docs/demo/*/; do
    name=$(basename "$demo")
    "$BIN" --demo "$PWD/$demo" --snapshot "$TMP/$name.png"
    swift tools/compose.swift "$TMP/$name.png" "docs/screenshots/$name.png"
    echo "docs/screenshots/$name.png"
done
