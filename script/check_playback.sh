#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p .local
# Compile the real engine/controller into a muted test harness; start smoke_server.py first.
swift build --build-system native --target MuxiCore
BUILD_DIR="$(swift build --build-system native --show-bin-path)"
MPV_LIB_DIR="$(python3 script/bundle_mpv_runtime.py --print-lib-dir)"
swiftc -parse-as-library -I "$BUILD_DIR/Modules" -I Sources/CMPV/include \
  script/PlaybackCheck.swift Sources/MuxiPlayer/Playback/MPVEngine.swift \
  Sources/MuxiPlayer/Stores/PlaybackController.swift "$BUILD_DIR"/MuxiCore.build/*.o \
  -L "$MPV_LIB_DIR" -lmpv.2 -Xlinker -rpath -Xlinker "$MPV_LIB_DIR" \
  -o .local/playback-check
.local/playback-check
