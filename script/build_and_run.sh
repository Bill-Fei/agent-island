#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--package-only|--package-validated|--release-package|--release-verify|--qa-empty|--qa-demo|--self-test|--qa-events) ;;
  *) echo "Unknown build/run mode: $MODE" >&2; exit 2 ;;
esac
# APP_NAME 是 SwiftPM product 名、可执行文件名，也是 pkill / pgrep 用的进程名。
# 改它会让 pkill -x 杀不掉旧进程，不要动它。
APP_NAME="LinglongtaiHUD"
# APP_BUNDLE_NAME 只决定 .app 目录名，也就是用户在 Finder / Spotlight / 启动台看到的名字。
APP_BUNDLE_NAME="Agent 灵动岛"
BUNDLE_ID="com.billfei.linglongtai.hud"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
if [[ "$MODE" == "--release-package" || "$MODE" == "--release-verify" ]]; then
  DIST_DIR="$ROOT_DIR/dist/Release"
fi
APP_BUNDLE="$DIST_DIR/$APP_BUNDLE_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ISLAND_VERSION="$(tr -d '\n' < "$ROOT_DIR/VERSION")"
if [[ ! "$ISLAND_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain a semantic version" >&2
  exit 2
fi
ISLAND_SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
  ISLAND_SOURCE_REVISION="$ISLAND_SOURCE_REVISION-dirty"
fi
# Pin a certificate fingerprint rather than an ambiguous certificate name.
SIGNING_IDENTITY="${ISLAND_SIGNING_IDENTITY:-}"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  if [[ ! "$SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "ISLAND_SIGNING_IDENTITY must be a 40-character certificate SHA-1 fingerprint" >&2
    exit 2
  fi
  SIGNING_IDENTITY="$(printf '%s' "$SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')"
  if ! /usr/bin/security find-identity -p codesigning -v | awk -v fingerprint="$SIGNING_IDENTITY" '$2 == fingerprint { found=1 } END { exit !found }'; then
    echo "ISLAND_SIGNING_IDENTITY is not a valid local codesigning identity" >&2
    exit 2
  fi
fi
SIGNING_FLAG="${SIGNING_IDENTITY:--}"
ISLAND_SOURCE_HASH="$(cd "$ROOT_DIR" && shasum -a 256 Package.swift VERSION Sources/*/*.swift | shasum -a 256 | awk '{print $1}')"
input_hash() {
  shasum -a 256 Package.swift VERSION Sources/*/*.swift Resources/AppIcon.icns script/install_hooks.py script/build_and_run.sh | shasum -a 256 | awk '{print $1}'
}
ISLAND_INPUT_HASH="$(cd "$ROOT_DIR" && input_hash)"
ISLAND_CONFIGURATION=debug
if [[ "$MODE" == "--release-package" || "$MODE" == "--release-verify" ]]; then ISLAND_CONFIGURATION=release; fi

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
# Do not let two local workflows replace/sign the same bundle concurrently.
PACKAGE_LOCK="$ROOT_DIR/.build/island-package.lock"
if ! mkdir "$PACKAGE_LOCK" 2>/dev/null; then
  echo "Another island build/package is in progress; running app left intact." >&2
  exit 2
fi
trap 'rmdir "$PACKAGE_LOCK"' EXIT
if [[ "$MODE" == "--package-validated" ]]; then
  VALIDATED_DIR="$ROOT_DIR/.build/contained-validation"
  shasum -a 256 -c "$VALIDATED_DIR/validated.sha256"
  BUILD_BINARY="$VALIDATED_DIR/$APP_NAME"
  BUILD_HELPER="$VALIDATED_DIR/linglongtaictl"
  for source_file in Sources/LinglongtaiShared/*.swift Sources/LinglongtaiHUD/*.swift; do
    if [[ "$source_file" -nt "$BUILD_BINARY" ]]; then
      echo "Source changed after validation; rerun script/check_sandbox.sh" >&2
      exit 2
    fi
  done
else
swift build --build-system swiftbuild -c "$ISLAND_CONFIGURATION"
ISLAND_BIN_DIR="$(swift build --build-system swiftbuild -c "$ISLAND_CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$ISLAND_BIN_DIR/$APP_NAME"
BUILD_HELPER="$ISLAND_BIN_DIR/linglongtaictl"
fi

ISLAND_BUILT_SOURCE_HASH="$(cd "$ROOT_DIR" && shasum -a 256 Package.swift VERSION Sources/*/*.swift | shasum -a 256 | awk '{print $1}')"
if [[ "$ISLAND_BUILT_SOURCE_HASH" != "$ISLAND_SOURCE_HASH" || "$(input_hash)" != "$ISLAND_INPUT_HASH" ]]; then
  echo "Source changed during compilation; leave running app intact and rebuild before packaging." >&2
  exit 2
fi

# Compare unsigned build inputs, not the binary modified by codesign. Verify
# the whole bundle seal before trusting its recorded build fingerprints.
ISLAND_BINARY_HASH="$(shasum -a 256 "$BUILD_BINARY" | awk '{print $1}')"
ISLAND_HELPER_HASH="$(shasum -a 256 "$BUILD_HELPER" | awk '{print $1}')"
REUSE_BUNDLE=false
if [[ -f "$INFO_PLIST" && -f "$APP_BINARY" ]]; then
  EXISTING_INPUT_HASH="$(/usr/bin/plutil -extract IslandInputSHA256 raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  EXISTING_CONFIGURATION="$(/usr/bin/plutil -extract IslandBuildConfiguration raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  EXISTING_BINARY_HASH="$(/usr/bin/plutil -extract IslandBuildBinarySHA256 raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  EXISTING_HELPER_HASH="$(/usr/bin/plutil -extract IslandBuildHelperSHA256 raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  EXISTING_SIGNER="$(/usr/bin/plutil -extract IslandSigningIdentity raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  if [[ "$EXISTING_INPUT_HASH" == "$ISLAND_INPUT_HASH" && "$EXISTING_CONFIGURATION" == "$ISLAND_CONFIGURATION" && "$EXISTING_BINARY_HASH" == "$ISLAND_BINARY_HASH" && "$EXISTING_HELPER_HASH" == "$ISLAND_HELPER_HASH" && "$EXISTING_SIGNER" == "$SIGNING_FLAG" ]] && codesign --verify --deep --strict "$APP_BUNDLE"; then
    REUSE_BUNDLE=true
    echo "Unchanged bundle: preserving existing signature"
  fi
fi

# Only stop the old app after a successful build. Retain a recoverable last build.
if [[ "$MODE" != "--package-only" && "$MODE" != "--package-validated" && "$MODE" != "--release-package" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
if [[ "$REUSE_BUNDLE" == false ]]; then
ISLAND_BUILD_ID="$(date +%Y%m%d%H%M%S)"
if [[ -f "$APP_BINARY" ]]; then
  cp "$APP_BINARY" "$DIST_DIR/$APP_NAME.previous"
fi
mkdir -p "$APP_MACOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"
mkdir -p "$APP_CONTENTS/Helpers" "$APP_CONTENTS/Resources/Integration"
cp "$BUILD_HELPER" "$APP_CONTENTS/Helpers/linglongtaictl"
cp "$ROOT_DIR/script/install_hooks.py" "$APP_CONTENTS/Resources/Integration/install_hooks.py"

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
  <string>$ISLAND_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$ISLAND_BUILD_ID</string>
  <key>IslandSourceRevision</key>
  <string>$ISLAND_SOURCE_REVISION</string>
  <key>IslandSourceSHA256</key>
  <string>$ISLAND_SOURCE_HASH</string>
  <key>IslandInputSHA256</key>
  <string>$ISLAND_INPUT_HASH</string>
  <key>IslandBuildBinarySHA256</key>
  <string>$ISLAND_BINARY_HASH</string>
  <key>IslandBuildHelperSHA256</key>
  <string>$ISLAND_HELPER_HASH</string>
  <key>IslandSigningIdentity</key>
  <string>$SIGNING_FLAG</string>
  <key>IslandBuildConfiguration</key>
  <string>$ISLAND_CONFIGURATION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>点击「打开应用」时，向对应 Agent 应用发送与点击程序坞图标相同的重新打开请求，以恢复窗口。</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Keep resources/helpers sealed without adding entitlements or weakening the
# designated requirement. Ad-hoc rebuilds may need fresh Accessibility grants.
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Signing: ad-hoc. Changed builds may require Accessibility re-authorization." >&2
fi
codesign --force --sign "$SIGNING_FLAG" "$APP_CONTENTS/Helpers/linglongtaictl"
codesign --force --sign "$SIGNING_FLAG" "$APP_BINARY"
codesign --force --sign "$SIGNING_FLAG" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
fi
# The lock protects compilation and packaging, not a long-lived log/debug UI.
rmdir "$PACKAGE_LOCK"
trap - EXIT

open_app() {
  if ((${#APP_ARGS[@]})); then
    /usr/bin/open -n "$APP_BUNDLE" --args "${APP_ARGS[@]}"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  --package-only|--package-validated|--release-package)
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
  --verify|verify|--release-verify)
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
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--package-only|--package-validated|--release-package|--release-verify]" >&2
    exit 2
    ;;
esac
