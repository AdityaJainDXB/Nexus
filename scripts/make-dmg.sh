#!/bin/zsh
# Packages dist/Nexus.app into dist/Nexus-<version>.dmg with a styled drag-to-Applications window (via dmgbuild).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-1.0.0}
APP=dist/Nexus.app
[[ -d $APP ]] || { echo "Build first: scripts/build-app.sh"; exit 1; }
DMG=dist/Nexus-$VERSION.dmg
VENV=${DMGBUILD_VENV:-.build/dmgvenv}
[[ -x $VENV/bin/dmgbuild ]] || { python3 -m venv $VENV && $VENV/bin/pip -q install dmgbuild; }
echo "▸ Rendering background"
swift scripts/make-dmg-background.swift dist/background.png
tiffutil -cathidpicheck dist/background.png dist/background@2x.png -out dist/background.tiff >/dev/null
rm -f "$DMG"
echo "▸ Building $DMG"
$VENV/bin/dmgbuild -s scripts/dmg-settings.py -D app="$APP" -D background=dist/background.tiff "Nexus" "$DMG"
rm -f dist/background.png dist/background@2x.png
shasum -a 256 "$DMG" | tee "$DMG.sha256"
du -h "$DMG" | awk '{print "✓ " $2 " (" $1 ")"}'
