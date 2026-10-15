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
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp ".build/release/${EXECUTABLE}" "$OUT/Contents/MacOS/${EXECUTABLE}"

# The privileged helper travels inside the bundle so the app can offer a
# one-time "install helper" button without needing the source folder.
cp helper/insomnia-helper helper/install_helper.sh helper/uninstall_helper.sh \
   "$OUT/Contents/Resources/"
chmod 755 "$OUT/Contents/Resources/insomnia-helper" \
          "$OUT/Contents/Resources/install_helper.sh" \
          "$OUT/Contents/Resources/uninstall_helper.sh"

echo "==> Checking helper script syntax"
for script in helper/insomnia-helper helper/install_helper.sh helper/uninstall_helper.sh; do
  sh -n "$script" || { echo "error: $script has a syntax error" >&2; exit 1; }
done

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
  echo "==> Installing to /Applications and setting up the privileged helper"
  echo "    (one admin password prompt — nothing else will ask again)"
  # Single sudo invocation so the password is asked exactly once.
  sudo sh -c "rm -rf /Applications/${APP_NAME}.app && cp -R '${OUT}' '/Applications/${APP_NAME}.app' && ./helper/install_helper.sh"
  echo
  echo "Installed /Applications/${APP_NAME}.app"
  echo "Helper installed — toggling no longer asks for a password."
  echo "Launch it from Spotlight (${APP_NAME}) or: open -a ${APP_NAME}"
fi
