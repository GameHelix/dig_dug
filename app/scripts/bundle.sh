#!/bin/sh
# Assembles Gopherwood.app from a built binary and signs it ad hoc.
# Usage: app/scripts/bundle.sh <binary> <app path>   (make app runs it)
set -eu

binary=$1
app=$2
here=$(cd "$(dirname "$0")/.." && pwd)

if [ ! -x "$binary" ]; then
	echo "bundle.sh: $binary is not an executable; build it first (make app)" >&2
	exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Gopherwood"
cp "$here/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$here/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

# Resource bundles SwiftPM puts next to the binary (GRDB's privacy manifest).
for bundle in "$(dirname "$binary")"/*.bundle; do
	if [ -e "$bundle" ]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
done

codesign --force --sign - --timestamp=none "$app"
echo "Built $app"
