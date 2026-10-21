#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SWIFT_BIN="$(xcrun -f swiftc)"
TESTING_PLUGIN="$(dirname "$SWIFT_BIN")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
EXTRA_FLAGS=()
# CLT 27 ships the Testing plugin but Swift Build does not discover it automatically.
if [[ -f "$TESTING_PLUGIN" ]]; then
  EXTRA_FLAGS=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
fi
swift test --disable-xctest "${EXTRA_FLAGS[@]}"
