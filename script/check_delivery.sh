#!/usr/bin/env bash
# Mandatory local delivery gate for every loop iteration.
# Builds a fresh App, runs independent acceptance, packages it, then checks the
# resulting bundle and the feature under test. It never publishes or uploads.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/linglongtai-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/linglongtai-swift-cache}"
export ISLAND_DISABLE_SANDBOX="${ISLAND_DISABLE_SANDBOX:-1}"
export BUILD_SYSTEM="${BUILD_SYSTEM:-native}"

APP="$ROOT_DIR/dist/Agent 灵动岛.app"
ACCEPTANCE="$ROOT_DIR/.build/out/Products/Debug/linglongtai-acceptance"

echo "[1/5] build all targets"
swift build --disable-sandbox --build-system "$BUILD_SYSTEM" -c debug

echo "[2/5] independent acceptance"
"$ACCEPTANCE" | tee /tmp/linglongtai-delivery-acceptance.log

echo "[3/5] package fresh app"
./script/build_and_run.sh --package-only

if [[ "${DELIVERY_SMOKE_INSTALL:-}" == "1" ]]; then
  echo "[3.5/5] install smoke target"
  ditto "$APP" "/Applications/Agent 灵动岛.app"
fi

echo "[4/5] bundle structure and signature"
bash ./script/check_release.sh "$APP"

echo "[5/5] Grok Bot smoke check"
test -x "$APP/Contents/MacOS/LinglongtaiHUD"
test -f "$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$(tr -d '\n' < VERSION)"
strings "$APP/Contents/MacOS/LinglongtaiHUD" > /tmp/linglongtai-delivery-strings.log
rg -q 'Grok Bot' /tmp/linglongtai-delivery-strings.log
rg -q 'com.anysphere.sand' /tmp/linglongtai-delivery-strings.log

echo "DELIVERY_GATE: PASS — current source built, acceptance passed, package checked, Grok Bot symbols present"
