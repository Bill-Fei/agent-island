#!/usr/bin/env bash
# Read-only local release diagnosis: never signs, submits or publishes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISLAND_APP="${1:-$ROOT_DIR/dist/Release/Agent 灵动岛.app}"
ISLAND_PLIST="$ISLAND_APP/Contents/Info.plist"
test -x "$ISLAND_APP/Contents/MacOS/LinglongtaiHUD"
test -x "$ISLAND_APP/Contents/Helpers/linglongtaictl"
test -f "$ISLAND_APP/Contents/Resources/Integration/install_hooks.py"
test -f "$ISLAND_APP/Contents/Resources/AppIcon.icns"
for agent in codex claude doubao work-buddy; do test -f "$ISLAND_APP/Contents/Resources/AgentIcons/$agent.png"; done
plutil -lint "$ISLAND_PLIST"
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion IslandSourceRevision IslandSourceSHA256 IslandBuildConfiguration; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$ISLAND_PLIST"
done
otool -L "$ISLAND_APP/Contents/MacOS/LinglongtaiHUD"
if codesign --verify --deep --strict "$ISLAND_APP"; then
  codesign -dv --verbose=4 "$ISLAND_APP" 2>&1
  if codesign -dv "$ISLAND_APP" 2>&1 | rg -q 'Signature=adhoc'; then
    echo "SIGNING: LOCAL ONLY — ad-hoc integrity valid; Developer ID and hardened runtime still required for distribution."
  fi
else
  echo "SIGNING: NOT READY — local bundle only, Developer ID signature still required."
fi
if xcrun stapler validate "$ISLAND_APP"; then
  echo "NOTARIZATION: stapled ticket found."
else
  echo "NOTARIZATION: NOT VERIFIED — no valid stapled ticket."
fi
echo "Structure check complete. This does not certify public distribution or UI acceptance."
