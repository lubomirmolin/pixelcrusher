#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

npx tauri build --bundles app

APP_PATH="src-tauri/target/release/bundle/macos/PixelCrusher.app"
DMG_PATH="src-tauri/target/release/bundle/dmg/PixelCrusher_0.1.0_aarch64.dmg"

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

hdiutil create -volname PixelCrusher -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"

echo "macOS artifacts:"
echo "- $APP_PATH"
echo "- $DMG_PATH"
