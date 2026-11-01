#!/bin/sh
# Makes Resources/AppIcon.icns from scripts/make-icon.swift. Run it once after changing the
# drawing; the .icns is committed, so builds do not need it.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/gopherwood-icon.XXXXXX")
trap 'rm -rf "$work"' EXIT
swiftc -O -o "$work/make-icon" "$here/scripts/make-icon.swift"
"$work/make-icon" "$work/AppIcon.iconset"
iconutil -c icns -o "$here/Resources/AppIcon.icns" "$work/AppIcon.iconset"
echo "Wrote $here/Resources/AppIcon.icns"
