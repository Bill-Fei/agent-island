#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
# APP_NAME 是 SwiftPM product 名、可执行文件名，也是 pkill / pgrep 用的进程名。
# 改它会让 pkill -x 杀不掉旧进程，不要动它。
APP_NAME="LinglongtaiHUD"
# APP_BUNDLE_NAME 只决定 .app 目录名，也就是用户在 Finder / Spotlight / 启动台看到的名字。
APP_BUNDLE_NAME="Agent 灵动岛"
BUNDLE_ID="com.billfei.linglongtai.hud"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

APP_ARGS=()
if [[ "$MODE" == "--qa-empty" || "$MODE" == "--qa-demo" ]]; then
  APP_ARGS+=("$MODE")
fi
if [[ "$MODE" == "--self-test" || "$MODE" == "--qa-events" ]]; then
  if [[ -z "${2:-}" || "$2" != /private/tmp/* && "$2" != /tmp/* ]]; then
    echo "This mode requires an explicit isolated /tmp directory" >&2
    exit 2
  fi
  APP_ARGS=("--data-dir" "$2")
  if [[ "$MODE" == "--self-test" ]]; then APP_ARGS+=("--self-test"); fi
fi

cd "$ROOT_DIR"
export SWIFT_MODULECACHE_PATH="$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
mkdir -p "$SWIFT_MODULECACHE_PATH" "$CLANG_MODULE_CACHE_PATH"
if [[ "$MODE" == "--package-validated" ]]; then
  VALIDATED_DIR="$ROOT_DIR/.build/contained-validation"
  shasum -a 256 -c "$VALIDATED_DIR/validated.sha256"
  BUILD_BINARY="$VALIDATED_DIR/$APP_NAME"
  for source_file in Sources/LinglongtaiShared/*.swift Sources/LinglongtaiHUD/*.swift; do
    if [[ "$source_file" -nt "$BUILD_BINARY" ]]; then
      echo "Source changed after validation; rerun script/check_sandbox.sh" >&2
      exit 2
    fi
  done
else
swift build --build-system swiftbuild --product "$APP_NAME"
BUILD_BINARY="$(swift build --build-system swiftbuild --show-bin-path)/$APP_NAME"
fi

# Only stop the old app after a successful build. Retain a recoverable last build.
if [[ "$MODE" != "--package-only" && "$MODE" != "--package-validated" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
if [[ -f "$APP_BINARY" ]]; then
  cp "$APP_BINARY" "$DIST_DIR/$APP_NAME.previous"
fi
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Agent 灵动岛</string>
  <key>CFBundleDisplayName</key>
  <string>Agent 灵动岛</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3</string>
  <key>CFBundleVersion</key>
  <string>20261006.7</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  if ((${#APP_ARGS[@]})); then
    /usr/bin/open -n "$APP_BUNDLE" --args "${APP_ARGS[@]}"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  --package-only|--package-validated)
    echo "Packaged: $APP_BUNDLE (not launched; running app unchanged)"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --qa-empty|--qa-demo)
    open_app "$MODE"
    ;;
  --self-test)
    /usr/bin/open -n -W "$APP_BUNDLE" --args "${APP_ARGS[@]}"
    ;;
  --qa-events)
    open_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--package-only|--package-validated]" >&2
    exit 2
    ;;
esac
