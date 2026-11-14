#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
VERSION="${1:?usage: publish_appcast.sh VERSION RELEASE_ZIP}"
ARCHIVE="${2:?provide the verified release APP ZIP}"
# Keys remain in login Keychain. Publish this feed only after all release assets are verified.
STAGING=".local/appcast-$VERSION"
mkdir "$STAGING"
ditto "$ARCHIVE" "$STAGING/$(basename "$ARCHIVE")"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account com.hectorgao.muxi-player.updates --maximum-deltas 0 \
  --download-url-prefix "https://github.com/HectorGao/muxi-player/releases/download/v$VERSION/" \
  -o "$STAGING/appcast.xml" "$STAGING"
python3 - "$STAGING/appcast.xml" <<'PY'
from pathlib import Path
import sys, xml.etree.ElementTree as ET
source = Path(sys.argv[1])
root = ET.fromstring(source.read_text())
enclosure = root.find('.//enclosure')
assert enclosure is not None and enclosure.attrib.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')
assert enclosure.attrib['url'].startswith('https://github.com/HectorGao/muxi-player/releases/download/v')
Path('appcast.xml').write_bytes(source.read_bytes())
print('Prepared signed update enclosure in appcast.xml; verify release download before committing the feed.')
PY
