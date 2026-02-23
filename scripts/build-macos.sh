#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="PixelCrusher"
APP_EXECUTABLE="PixelCrusher"
SWIFT_PRODUCT="PixelCrusherMac"
BUNDLE_NAME="${APP_NAME}.app"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$BUNDLE_NAME"
ZIP_PATH="$DIST_DIR/${APP_NAME}.zip"
DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
DMG_STAGING_DIR="$DIST_DIR/dmg-staging"
ICON_SOURCE_PNG="$ROOT_DIR/src-tauri/icons/icon.png"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICNS_PATH="$APP_DIR/Contents/Resources/AppIcon.icns"
BUNDLED_TOOLS_DIR="$APP_DIR/Contents/Resources/BundledTools"
SWIFT_BINARY="$ROOT_DIR/.build/release/$SWIFT_PRODUCT"
RUST_CLI_BINARY="$ROOT_DIR/crates/pixelcrusher-core/target/release/pixelcrusher-cli"

cargo test --manifest-path crates/pixelcrusher-core/Cargo.toml
swift test

cargo build --manifest-path crates/pixelcrusher-core/Cargo.toml --release --bin pixelcrusher-cli
swift build -c release --product "$SWIFT_PRODUCT"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$SWIFT_BINARY" "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE"
cp "$RUST_CLI_BINARY" "$APP_DIR/Contents/MacOS/pixelcrusher-cli"
chmod +x "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE" "$APP_DIR/Contents/MacOS/pixelcrusher-cli"

"$ROOT_DIR/scripts/build_bundled_tools.sh" "$BUNDLED_TOOLS_DIR"

if [[ -f "$ICON_SOURCE_PNG" ]]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  cp "$ICON_SOURCE_PNG" "$ICONSET_DIR/icon_512x512@2x.png"
  sips -z 16 16   "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32   "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32   "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64   "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>com.lubo.pixelcrusher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PNG Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.png</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>JPEG Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.jpeg</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>GIF Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.compuserve.gif</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>SVG Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.svg-image</string>
            </array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

PIXELCRUSHER_APP_BUNDLE_UNDER_TEST="$APP_DIR" swift test --filter PackagingBundleChecksTests
"$ROOT_DIR/scripts/smoke_check_bundle_tools.sh" "$APP_DIR"

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

rm -f "$DMG_PATH"
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/$BUNDLE_NAME"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

echo "Built artifacts:"
echo "  App: $APP_DIR"
echo "  Zip: $ZIP_PATH"
echo "  Dmg: $DMG_PATH"
