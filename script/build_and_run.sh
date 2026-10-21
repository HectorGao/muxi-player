#!/usr/bin/env bash
set -euo pipefail

MODE="run"
VERSION="0.1.0"
BUILD_NUMBER="1"
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    run|--build-only|--verify|--debug|--logs|--telemetry) MODE="$1"; shift ;;
    --version|--build-number|--output)
      [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        --version) VERSION="$2" ;;
        --build-number) BUILD_NUMBER="$2" ;;
        --output) OUTPUT="$2" ;;
      esac
      shift 2 ;;
    -h|--help)
      echo "usage: $0 [run|--build-only|--verify|--debug|--logs|--telemetry] [--version 0.1.0-alpha.1] [--build-number 1] [--output /path/MuxiPlayer.app]"
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || { echo "Invalid release version" >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Build number must be a positive integer" >&2; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="MuxiPlayer"
BUNDLE_ID="com.hectorgao.muxi-player"
APP_BUNDLE="${OUTPUT:-$ROOT_DIR/dist/$APP_NAME.app}"
[[ "$APP_BUNDLE" = /* ]] || APP_BUNDLE="$ROOT_DIR/$APP_BUNDLE"
[[ "$APP_BUNDLE" == *.app ]] || { echo "Output must end in .app" >&2; exit 2; }
MUXI_MPV_LIB_DIR="$(python3 "$ROOT_DIR/script/bundle_mpv_runtime.py" --print-lib-dir)"
export MUXI_MPV_LIB_DIR

if [[ "$MODE" != "--build-only" ]]; then
  if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e 'tell application id "com.hectorgao.muxi-player" to quit'
    for attempt in {1..50}; do
      if ! pgrep -x "$APP_NAME" >/dev/null; then break; fi
      sleep 1
    done
    if pgrep -x "$APP_NAME" >/dev/null; then echo "The app is still closing; retry after it finishes syncing." >&2; exit 1; fi
  fi
fi

CONFIGURATION="release"
[[ "$MODE" != "--debug" ]] || CONFIGURATION="debug"
swift build -c "$CONFIGURATION"
BUILD_BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME.next"
mv "$APP_BUNDLE/Contents/MacOS/$APP_NAME.next" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
python3 - "$APP_BUNDLE/Contents/Info.plist" "$VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib, subprocess, sys
info = {
    'CFBundleExecutable': 'MuxiPlayer', 'CFBundleIdentifier': 'com.hectorgao.muxi-player',
    'CFBundleName': '幕汐播放器', 'CFBundleDisplayName': '幕汐播放器', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': sys.argv[2].split('-')[0], 'CFBundleVersion': sys.argv[3],
    'MuxiReleaseVersion': sys.argv[2],
    'MuxiBuildCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'LSMinimumSystemVersion': '14.0', 'NSPrincipalClass': 'NSApplication',
    'NSHighResolutionCapable': True,
    'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
    'NSLocalNetworkUsageDescription': '连接你配置的局域网 Emby 或 Jellyfin 服务器以浏览和播放媒体。',
}
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump(info, stream)
PY
python3 "$ROOT_DIR/script/bundle_mpv_runtime.py" --app-bundle "$APP_BUNDLE"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

case "$MODE" in
  --build-only) echo "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|--telemetry)
    open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --verify)
    open -n "$APP_BUNDLE"
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    echo "Launched $APP_BUNDLE" ;;
  run) open -n "$APP_BUNDLE" ;;
esac
