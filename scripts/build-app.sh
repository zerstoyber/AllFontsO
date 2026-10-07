#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export MACOSX_DEPLOYMENT_TARGET=14.0
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  swift build -c release --triple "${arch}-apple-macosx14.0" --sdk "$sdk" --scratch-path "$root/.build/${arch}" >/dev/null
done
arm_bin="$(swift build -c release --triple arm64-apple-macosx14.0 --sdk "$sdk" --scratch-path "$root/.build/arm64" --show-bin-path)/Fontso"
x86_bin="$(swift build -c release --triple x86_64-apple-macosx14.0 --sdk "$sdk" --scratch-path "$root/.build/x86_64" --show-bin-path)/Fontso"
mkdir -p "$root/.build/universal"
lipo -create "$arm_bin" "$x86_bin" -output "$root/.build/universal/Fontso"
bin="$root/.build/universal"

iconset="$root/Support/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
src="$root/Support/AppIcon.png"
sips -s format png -z 16 16 "$src" --out "$iconset/icon_16x16.png" >/dev/null
sips -s format png -z 32 32 "$src" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -s format png -z 32 32 "$src" --out "$iconset/icon_32x32.png" >/dev/null
sips -s format png -z 64 64 "$src" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -s format png -z 128 128 "$src" --out "$iconset/icon_128x128.png" >/dev/null
sips -s format png -z 256 256 "$src" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -s format png -z 256 256 "$src" --out "$iconset/icon_256x256.png" >/dev/null
sips -s format png -z 512 512 "$src" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -s format png -z 512 512 "$src" --out "$iconset/icon_512x512.png" >/dev/null
sips -s format png -z 1024 1024 "$src" --out "$iconset/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset" -o "$root/Support/AppIcon.icns"
rm -rf "$iconset"

app="$root/Fontso.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Fontso" "$app/Contents/MacOS/Fontso"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"
cp "$root/Support/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app" >/dev/null

echo "Fertig: $app"
