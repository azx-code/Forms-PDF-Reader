#!/bin/bash
set -e

APP_NAME="PDF Reader"
BINARY_NAME="PDFReader"
APP_DIR="/Users/ahnafzaman/Desktop/Projects/${APP_NAME}.app"

echo "==> Cleaning previous build..."
rm -rf "${APP_DIR}"

echo "==> Creating bundle structure..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

echo "==> Compiling Swift source..."
swiftc -parse-as-library \
    -O \
    PDFReader.swift \
    -o "${APP_DIR}/Contents/MacOS/${BINARY_NAME}" \
    -framework SwiftUI \
    -framework PDFKit \
    -framework Cocoa \
    -framework UniformTypeIdentifiers

echo "==> Generating app icon..."
ICON_SRC="pdf_reader_icon_1024_3.png"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
for size in 16 32 64 128 256 512; do
    sips -z ${size} ${size} "${ICON_SRC}" --out "${ICONSET_DIR}/icon_${size}x${size}.png"    > /dev/null 2>&1
    double=$((size * 2))
    sips -z ${double} ${double} "${ICON_SRC}" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" > /dev/null 2>&1
done
iconutil -c icns "${ICONSET_DIR}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
rm -rf "${ICONSET_DIR}"

echo "==> Writing Info.plist..."
cat > "${APP_DIR}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PDFReader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.pdfreader</string>
    <key>CFBundleName</key>
    <string>PDF Reader</string>
    <key>CFBundleDisplayName</key>
    <string>PDF Reader</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array><string>pdf</string></array>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo ""
echo "✓ Build complete: ${APP_DIR}"
echo ""
echo "To open the app:"
echo "  open '${APP_DIR}'"
echo ""
echo "If macOS blocks it (unidentified developer), right-click → Open."
