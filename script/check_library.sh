#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p .local
# Compile the actual store against the loopback fixture; start smoke_server.py first.
swift build --build-system native --target MuxiCore
BUILD_DIR="$(swift build --build-system native --show-bin-path)"
swiftc -parse-as-library -I "$BUILD_DIR/Modules" \
  script/LibraryCheck.swift Sources/MuxiPlayer/Stores/LibraryStore.swift \
  "$BUILD_DIR"/MuxiCore.build/*.o -o .local/library-check
.local/library-check
