#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) WindowHome.app and packages it.
#   ./scripts/build.sh            → build/WindowHome.app, dist/WindowHome.zip, dist/WindowHome.dmg
#   ./scripts/build.sh --install  → also copies the app to /Applications and launches it
#   VERSION=1.2.0 ./scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
APP="build/WindowHome.app"
FRAMEWORKS=(-framework AppKit -framework Carbon -framework ServiceManagement)

echo "▸ Building WindowHome $VERSION"
rm -rf build dist && mkdir -p build dist "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" Sources/*.swift "${FRAMEWORKS[@]}" -o "build/WindowHome-$arch"
done
lipo -create build/WindowHome-arm64 build/WindowHome-x86_64 -output "$APP/Contents/MacOS/WindowHome"
rm build/WindowHome-*

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep -s - "$APP"

echo "▸ Packaging"
ditto -c -k --keepParent "$APP" dist/WindowHome.zip
STAGE=build/dmg && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "WindowHome" -srcfolder "$STAGE" -ov -format UDZO dist/WindowHome.dmg
rm -rf "$STAGE"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x WindowHome 2>/dev/null || true
  rm -rf /Applications/WindowHome.app && cp -R "$APP" /Applications/
  open /Applications/WindowHome.app
  echo "▸ Installed to /Applications"
fi
ls -lh dist
