#!/bin/bash
# Builds Packlight.app and packs it into build/Packlight.dmg (drag-to-Applications installer).
#   ./make-dmg.sh
# The file name stays the same for every release so the README can link to
# https://github.com/efeshinkawa/packlight/releases/latest/download/Packlight.dmg
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --no-install

STAGE=build/dmg
DMG=build/Packlight.dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Packlight.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Packlight" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created: $DMG ($(du -h "$DMG" | cut -f1))"
