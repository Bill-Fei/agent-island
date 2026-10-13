#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift build --build-system swiftbuild
swiftc -parse-as-library -module-cache-path .build/validation-module-cache \
  -I .build/out/Products/Debug \
  Sources/LinglongtaiHUD/AgentUsageCount.swift Sources/LinglongtaiHUD/ClaudeChatObserver.swift Sources/LinglongtaiHUD/TaskVisualState.swift Sources/LinglongtaiHUD/TaskStore.swift Sources/LinglongtaiHUD/TaskStoreAcceptance.swift \
  script/StoreAcceptanceMain.swift .build/out/Products/Debug/LinglongtaiShared.o \
  -o .build/store-acceptance
ISLAND_QA_DIRECTORY="$(mktemp -d /private/tmp/island-store-check.XXXXXX)"
.build/store-acceptance --data-dir "$ISLAND_QA_DIRECTORY"
echo "Isolated report: $ISLAND_QA_DIRECTORY/acceptance.txt"
