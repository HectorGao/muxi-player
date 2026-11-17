#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p .local
swift build --build-system native --target MuxiCore
BUILD_DIR="$(swift build --build-system native --show-bin-path)"
swiftc -parse-as-library -I "$BUILD_DIR/Modules" \
  script/SiteCheck.swift Sources/MuxiPlayer/Stores/ConnectionStore.swift \
  Sources/MuxiPlayer/Stores/ViewingSiteStore.swift Sources/MuxiPlayer/Views/WebsiteView.swift \
  Sources/MuxiPlayer/App/ViewState.swift Sources/MuxiPlayer/App/PlayerWindow.swift "$BUILD_DIR"/MuxiCore.build/*.o \
  -framework WebKit -framework SwiftUI -o .local/site-check
.local/site-check "$@"
