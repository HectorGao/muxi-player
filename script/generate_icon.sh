#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ICONSET=".local/brand/AppIcon.iconset"
mkdir -p "$ICONSET" Resources
# Preserve the selected PNG; only resize it into macOS's standard representations.
while read -r name size; do
  sips -z "$size" "$size" docs/brand/icon-c-fullbleed.png --out "$ICONSET/$name.png" >/dev/null
done <<'SIZES'
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
SIZES
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
