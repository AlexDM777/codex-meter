#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/macos"
APP="$BUILD/CodexMeter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos13.0" -sdk "$SDK" -framework AppKit -framework WebKit -framework ServiceManagement -framework CryptoKit -framework ImageIO "$ROOT"/macos/*.swift -o "$BUILD/CodexMeter-$ARCH"
done
lipo -create "$BUILD/CodexMeter-arm64" "$BUILD/CodexMeter-x86_64" -output "$APP/Contents/MacOS/CodexMeter"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/macos/ui.html" "$ROOT/macos/strings.json" "$ROOT/SkinGuide.md" "$ROOT/macos/MACOS.md" "$APP/Contents/Resources/"
ditto "$ROOT/skins" "$APP/Contents/Resources/skins"
ICON="$BUILD/AppIcon.iconset"
mkdir -p "$ICON"
sips -s format png "$ROOT/icon-67-512.webp" --out "$BUILD/icon-source.png" >/dev/null
for N in 16 32 128 256 512; do
  sips -z "$N" "$N" "$BUILD/icon-source.png" --out "$ICON/icon_${N}x${N}.png" >/dev/null
  DOUBLE=$((N*2))
  sips -z "$DOUBLE" "$DOUBLE" "$BUILD/icon-source.png" --out "$ICON/icon_${N}x${N}@2x.png" >/dev/null
done
iconutil -c icns "$ICON" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign "${CODE_SIGN_IDENTITY:--}" --identifier com.alexdm777.codexmeter "$APP"
codesign --verify --deep --strict "$APP"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP" "$ROOT/dist/CodexMeter-macOS-universal.zip"
mkdir -p "$BUILD/dmg"
ditto "$APP" "$BUILD/dmg/CodexMeter.app"
if [ ! -L "$BUILD/dmg/Applications" ]; then ln -s /Applications "$BUILD/dmg/Applications"; fi
hdiutil create -volname CodexMeter -srcfolder "$BUILD/dmg" -ov -format UDZO "$ROOT/dist/CodexMeter-4.0-macOS-universal.dmg" >/dev/null
(cd "$ROOT/dist" && shasum -a 256 CodexMeter-macOS-universal.zip CodexMeter-4.0-macOS-universal.dmg > SHA256SUMS-macOS.txt)
echo "Built universal macOS app (Apple Silicon + Intel)"
