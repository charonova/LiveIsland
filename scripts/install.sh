#!/bin/bash
# Builds LiveIsland and installs it to ~/Applications, replacing any running copy.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
DEST="$HOME/Applications/LiveIsland.app"
mkdir -p "$HOME/Applications"
osascript -e 'tell application id "com.aissam.liveisland" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
cp -R build/LiveIsland.app "$DEST"
open "$DEST"
echo "Installed $DEST"
