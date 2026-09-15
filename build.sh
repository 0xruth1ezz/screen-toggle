#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
app_dir="$project_dir/build/Screen Toggle.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

iconset_dir="$project_dir/build/AppIcon.iconset"
mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$project_dir/Assets/AppIcon.png" \
        --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$project_dir/Assets/AppIcon.png" \
        --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"

xcrun clang -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=13.0 \
    -framework AppKit -framework Carbon -framework CoreGraphics \
    "$project_dir/main.m" -o "$app_dir/Contents/MacOS/ScreenToggle"
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/README.md" "$app_dir/Contents/Resources/README.md"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
/usr/bin/codesign --force --sign - "$app_dir"
touch "$app_dir"
printf 'Built: %s\n' "$app_dir"
