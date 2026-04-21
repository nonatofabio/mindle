#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Mindle"
BIN_NAME="mindle"
APP_BUNDLE="build/${APP_NAME}.app"
BIN="build/${BIN_NAME}"

echo "→ Compiling Swift sources…"
mkdir -p build
swiftc -O \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -framework SwiftUI -framework AppKit -framework Foundation -framework UniformTypeIdentifiers -framework WebKit \
  Sources/mindle/*.swift \
  -o "$BIN"

echo "→ Assembling app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$BIN_NAME"

# -------- Copy web resources (HTML/CSS/JS + vendor libs) --------
cp -R Resources/web "$APP_BUNDLE/Contents/Resources/web"

# -------- Icon generation from assets/logo.svg --------
if [ -f "assets/logo.svg" ]; then
  echo "→ Generating app icon…"
  ICON_TMP="$(mktemp -d)"
  ICONSET="$ICON_TMP/Mindle.iconset"
  mkdir -p "$ICONSET"

  render_svg() {
    local size="$1" out="$2"
    if command -v rsvg-convert >/dev/null 2>&1; then
      rsvg-convert -w "$size" -h "$size" "assets/logo.svg" -o "$out"
    else
      if [ ! -f "$ICON_TMP/master.png" ]; then
        /usr/bin/swift - <<SWIFTEOF > /dev/null
import Foundation
import AppKit
let svgURL = URL(fileURLWithPath: "assets/logo.svg")
guard let data = try? Data(contentsOf: svgURL),
      let image = NSImage(data: data) else { exit(1) }
let size = NSSize(width: 1024, height: 1024)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "$ICON_TMP/master.png"))
SWIFTEOF
      fi
      sips -z "$size" "$size" "$ICON_TMP/master.png" --out "$out" >/dev/null
    fi
  }

  render_svg 16    "$ICONSET/icon_16x16.png"
  render_svg 32    "$ICONSET/icon_16x16@2x.png"
  render_svg 32    "$ICONSET/icon_32x32.png"
  render_svg 64    "$ICONSET/icon_32x32@2x.png"
  render_svg 128   "$ICONSET/icon_128x128.png"
  render_svg 256   "$ICONSET/icon_128x128@2x.png"
  render_svg 256   "$ICONSET/icon_256x256.png"
  render_svg 512   "$ICONSET/icon_256x256@2x.png"
  render_svg 512   "$ICONSET/icon_512x512.png"
  render_svg 1024  "$ICONSET/icon_512x512@2x.png"

  iconutil -c icns -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$ICONSET"
  rm -rf "$ICON_TMP"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Mindle</string>
  <key>CFBundleDisplayName</key>
  <string>Mindle</string>
  <key>CFBundleExecutable</key>
  <string>mindle</string>
  <key>CFBundleIdentifier</key>
  <string>local.fnp.mindle</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Markdown Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>net.daringfireball.markdown</string>
      <key>UTTypeDescription</key>
      <string>Markdown Document</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.plain-text</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>md</string>
          <string>markdown</string>
          <string>mdown</string>
          <string>mkd</string>
        </array>
        <key>public.mime-type</key>
        <array>
          <string>text/markdown</string>
        </array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - --deep "$APP_BUNDLE" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$APP_BUNDLE" 2>/dev/null || true

echo "✓ Built $APP_BUNDLE"
echo ""
echo "Run it:"
echo "  open \"$APP_BUNDLE\""
echo "Or drag $APP_BUNDLE into /Applications."
