#!/usr/bin/env bash
# Contained compiler diagnostics: no package manager, GUI, or personal config.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
VALIDATION_DIR="$PWD/.build/contained-validation"
mkdir -p "$VALIDATION_DIR/module-cache"
COMPILER=(swiftc -target "$(uname -m)-apple-macosx13.0")
"${COMPILER[@]}" -parse-as-library -whole-module-optimization -emit-module -emit-object \
  -module-name LinglongtaiShared -module-cache-path "$VALIDATION_DIR/module-cache" \
  -emit-module-path "$VALIDATION_DIR/LinglongtaiShared.swiftmodule" \
  Sources/LinglongtaiShared/*.swift -o "$VALIDATION_DIR/LinglongtaiShared.o"
"${COMPILER[@]}" -parse-as-library -module-cache-path "$VALIDATION_DIR/module-cache" \
  -I "$VALIDATION_DIR" Sources/LinglongtaiAcceptance/*.swift \
  "$VALIDATION_DIR/LinglongtaiShared.o" -o "$VALIDATION_DIR/linglongtai-acceptance"
"${COMPILER[@]}" -parse-as-library -module-cache-path "$VALIDATION_DIR/module-cache" \
  -I "$VALIDATION_DIR" Sources/LinglongtaiCtl/main.swift \
  "$VALIDATION_DIR/LinglongtaiShared.o" -o "$VALIDATION_DIR/linglongtaictl"
"${COMPILER[@]}" -parse-as-library -module-cache-path "$VALIDATION_DIR/module-cache" \
  -I "$VALIDATION_DIR" Sources/LinglongtaiHUD/*.swift \
  "$VALIDATION_DIR/LinglongtaiShared.o" -o "$VALIDATION_DIR/LinglongtaiHUD"
"${COMPILER[@]}" -parse-as-library -module-cache-path "$VALIDATION_DIR/module-cache" \
  -I "$VALIDATION_DIR" Sources/LinglongtaiHUD/AgentUsageCount.swift Sources/LinglongtaiHUD/ClaudeChatObserver.swift Sources/LinglongtaiHUD/TaskStore.swift \
  Sources/LinglongtaiHUD/TaskStoreAcceptance.swift Sources/LinglongtaiHUD/ClaudeApprovalAcceptance.swift script/StoreAcceptanceMain.swift \
  "$VALIDATION_DIR/LinglongtaiShared.o" -o "$VALIDATION_DIR/store-acceptance"
"$VALIDATION_DIR/linglongtai-acceptance"
ISLAND_QA_DIRECTORY="$(mktemp -d /private/tmp/island-contained-store.XXXXXX)"
"$VALIDATION_DIR/store-acceptance" --data-dir "$ISLAND_QA_DIRECTORY"
"${COMPILER[@]}" -parse-as-library -module-cache-path "$VALIDATION_DIR/module-cache" \
  -I "$VALIDATION_DIR" Sources/LinglongtaiHUD/AgentUsageCount.swift Sources/LinglongtaiHUD/ClaudeChatObserver.swift Sources/LinglongtaiHUD/TaskStore.swift \
  Sources/LinglongtaiHUD/BackgroundStoreAcceptance.swift script/BackgroundStoreAcceptanceMain.swift \
  "$VALIDATION_DIR/LinglongtaiShared.o" -o "$VALIDATION_DIR/background-store-acceptance"
ISLAND_BG_DIRECTORY="$(mktemp -d /private/tmp/island-background-store.XXXXXX)"
"$VALIDATION_DIR/background-store-acceptance" --data-dir "$ISLAND_BG_DIRECTORY"
python3 script/check_hook_bridge.py --ctl "$VALIDATION_DIR/linglongtaictl" \
  --report "$VALIDATION_DIR/hook-report.json"
python3 -u script/check_approval_relay.py "$VALIDATION_DIR/linglongtaictl"
shasum -a 256 "$VALIDATION_DIR/LinglongtaiHUD" "$VALIDATION_DIR/linglongtaictl" > "$VALIDATION_DIR/validated.sha256"
echo "Contained validation passed. No GUI launched or personal configuration changed."
echo "Store report: $ISLAND_QA_DIRECTORY/acceptance.txt"
