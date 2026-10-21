#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p .local
swiftc -parse-as-library Sources/MuxiPlayer/App/PlayerWindow.swift script/WindowCheck.swift -o .local/window-check
.local/window-check
