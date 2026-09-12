#!/bin/bash
set -e

APP_NAME="Forms PDF Reader"
BINARY_NAME="PDFReader"

# Build the .app into the folder that CONTAINS this script's folder
# e.g. if the script is at ~/Downloads/PDFReader/build.sh,
#      the app is built to ~/Downloads/Forms PDF Reader.app
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/${APP_NAME}.app"

echo "==> Cleaning previous build..."
rm -rf "${APP_DIR}"

echo "==> Creating bundle structure..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

echo "==> Compiling Swift source..."
swiftc -parse-as-library \
    "${SCRIPT_DIR}/PDFReader.swift" \
    -o "${APP_DIR}/Contents/MacOS/${BINARY_NAME}" \
    -framework SwiftUI \
    -framework PDFKit \
    -framework Cocoa \
    -framework UniformTypeIdentifiers

echo "==> Generating app icon..."
# Look for an icon file — try common names in order
ICON_SRC=""
for candidate in icon.png Icon.png app_icon.png AppIcon.png pdf_reader_icon_1024_3.png; do
    if [ -f "${SCRIPT_DIR}/${candidate}" ]; then
        ICON_SRC="${SCRIPT_DIR}/${candidate}"
        break
    fi
done

if [ -n "${ICON_SRC}" ]; then
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"
    for size in 16 32 64 128 256 512; do
        sips -z ${size} ${size} "${ICON_SRC}" --out "${ICONSET_DIR}/icon_${size}x${size}.png"    > /dev/null 2>&1
        double=$((size * 2))
        sips -z ${double} ${double} "${ICON_SRC}" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" > /dev/null 2>&1
    done
    iconutil -c icns "${ICONSET_DIR}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
    rm -rf "${ICONSET_DIR}"
    echo "    Icon generated from: $(basename "${ICON_SRC}")"
else
    echo "    No icon PNG found in ${SCRIPT_DIR} — skipping (app will use default macOS icon)"
    echo "    To add an icon: drop any 1024×1024 PNG into the PDFReader folder named 'icon.png'"
fi

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
    <string>com.local.formspdfreader</string>
    <key>CFBundleName</key>
    <string>Forms PDF Reader</string>
    <key>CFBundleDisplayName</key>
    <string>Forms PDF Reader</string>
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
