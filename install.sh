#!/bin/zsh
# One-line installer for WindowHome:
#   curl -fsSL https://raw.githubusercontent.com/mohamedhadia/WindowHome/main/install.sh | zsh
set -euo pipefail

URL="https://github.com/mohamedhadia/WindowHome/releases/latest/download/WindowHome.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading WindowHome…"
curl -fsSL "$URL" -o "$TMP/WindowHome.zip"
ditto -x -k "$TMP/WindowHome.zip" "$TMP"

pkill -x WindowHome 2>/dev/null || true
DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/WindowHome.app"
cp -R "$TMP/WindowHome.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/WindowHome.app" 2>/dev/null || true

open "$DEST/WindowHome.app"
echo "✓ Installed to $DEST/WindowHome.app"
echo "  Allow it under System Settings → Privacy & Security → Accessibility when asked."
