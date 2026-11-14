#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p .local
swift build --build-system native --target MuxiCore
BUILD_DIR="$(swift build --build-system native --show-bin-path)"
swiftc -parse-as-library -I "$BUILD_DIR/Modules" script/IndexCheck.swift \
  Sources/MuxiPlayer/Stores/LibraryStore.swift Sources/MuxiPlayer/Stores/LibraryIndexCache.swift \
  "$BUILD_DIR"/MuxiCore.build/*.o -o .local/index-check
.local/index-check
