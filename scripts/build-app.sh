#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
configuration=${1:-release}
case "$configuration" in debug|release) ;; *) echo 'Usage: build-app.sh [debug|release]' >&2; exit 2;; esac
swift build --package-path "$root/Apps/Loffo" -c "$configuration"
bin=$(swift build --package-path "$root/Apps/Loffo" -c "$configuration" --show-bin-path)
app="$root/build/Loffo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Loffo" "$app/Contents/MacOS/Loffo"
# Grammar packages may ship SwiftPM resource bundles beside their executable.
for bundle in "$bin"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$app/Contents/Resources/"
done
if [ -f "$root/designs/brand/loffo-symbol-transparent.png" ]; then
    iconset="$root/build/Loffo.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$root/designs/brand/loffo-symbol-transparent.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        retina=$((size * 2))
        sips -z "$retina" "$retina" "$root/designs/brand/loffo-symbol-transparent.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/Loffo.icns"
    sips -Z 256 "$root/designs/brand/loffo-symbol-transparent.png" --out "$app/Contents/Resources/LoffoMark.png" >/dev/null
fi
cp "$root/Apps/Loffo/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null
printf '%s\n' "$app"
