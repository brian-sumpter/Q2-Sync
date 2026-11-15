#!/bin/zsh
#
#  make-app-icon.sh
#  Q2-Sync › Scripts
#
#  PURPOSE
#  Regenerates the app icon: draws it with make-app-icon.swift, then
#  resizes it into every size macOS needs inside
#  Q2-Sync/Assets.xcassets/AppIcon.appiconset.
#
#  USAGE (from the repository root)
#      Scripts/make-app-icon.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="Q2-Sync/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift Scripts/make-app-icon.swift "$TMP/icon-1024.png"

# Pixel sizes needed: 16, 32, 64, 128, 256, 512 and 1024.
for px in 16 32 64 128 256 512 1024; do
  sips -z $px $px "$TMP/icon-1024.png" --out "$ICONSET/icon-$px.png" >/dev/null
done

cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon-32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon-32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon-64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon-128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon-256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon-256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon-512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon-512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon-1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "App icon written to $ICONSET"
