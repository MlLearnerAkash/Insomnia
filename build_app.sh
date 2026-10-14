#!/bin/zsh
#
# Builds Insomnia.app (a menu bar app) from source.
#
#   ./build_app.sh              build into build/Insomnia.app
#   ./build_app.sh --install    also copy it to /Applications
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Insomnia"
BUNDLE_ID="com.local.insomnia"
EXECUTABLE="LidKeepAwake"   # SwiftPM product name (internal)
OUT="build/${APP_NAME}.app"

echo "==> Checking toolchain"
if ! command -v swift >/dev/null 2>&1; then
  echo "error: 'swift' not found. Install the Xcode Command Line Tools:" >&2
  echo "       xcode-select --install" >&2
  exit 1
fi

echo "==> Building release binary"
swift build -c release

echo "==> Assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp ".build/release/${EXECUTABLE}" "$OUT/Contents/MacOS/${EXECUTABLE}"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --sign - "$OUT"
codesign --verify --deep --strict "$OUT" && echo "    signature OK"

# Clear the quarantine flag in case the folder arrived as a download.
xattr -dr com.apple.quarantine "$OUT" 2>/dev/null || true

echo
echo "Built ${OUT}"
echo "Run it with:  open ${OUT}"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$OUT" "/Applications/${APP_NAME}.app"
  echo "Installed /Applications/${APP_NAME}.app"
  echo "Launch it from Spotlight (${APP_NAME}) or: open -a ${APP_NAME}"
fi
