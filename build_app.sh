#!/bin/zsh
#
# Builds Insomnia.app (a menu bar app) from source.
#
#   ./build_app.sh              build into build/Insomnia.app
#   ./build_app.sh --dmg        also package build/Insomnia-<version>.dmg
#   ./build_app.sh --install    also copy it to /Applications (+ privileged helper)
#
# Flags can be combined: ./build_app.sh --dmg --install
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Insomnia"
BUNDLE_ID="com.local.insomnia"
EXECUTABLE="LidKeepAwake"   # SwiftPM product name (internal)
VERSION="1.0"
OUT="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"

WANT_DMG=0
WANT_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dmg)     WANT_DMG=1 ;;
    --install) WANT_INSTALL=1 ;;
    -h|--help) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option: $arg (try --dmg, --install)" >&2; exit 1 ;;
  esac
done

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
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
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

if (( WANT_DMG )); then
  echo
  echo "==> Packaging ${DMG}"
  # A staging folder gives the DMG the usual drag-to-Applications layout:
  # the app, plus a symlink that looks like the Applications folder.
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$OUT" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"

  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"

  # Verify the image mounts and really contains the app and the symlink.
  MOUNT=$(hdiutil attach -nobrowse -readonly "$DMG" | awk '/\/Volumes\//{for (i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}')
  if [[ -d "$MOUNT/${APP_NAME}.app" && -L "$MOUNT/Applications" ]]; then
    echo "    image OK: ${APP_NAME}.app + Applications symlink present"
  else
    echo "    warning: image contents look wrong" >&2
  fi
  hdiutil detach -quiet "$MOUNT"

  echo "    ${DMG} ($(du -h "$DMG" | awk '{print $1}'))"
  echo
  echo "Unsigned build: tell users to right-click the app → Open the first time."
  echo "Release it with:  gh release create v${VERSION} ${DMG} --title \"${APP_NAME} v${VERSION}\""
fi

if (( WANT_INSTALL )); then
  echo
  echo "==> Installing to /Applications and setting up the privileged helper"
  echo "    (one admin password prompt — nothing else will ask again)"
  # Single sudo invocation so the password is asked exactly once.
  sudo sh -c "rm -rf /Applications/${APP_NAME}.app && cp -R '${OUT}' '/Applications/${APP_NAME}.app' && ./helper/install_helper.sh"
  echo
  echo "Installed /Applications/${APP_NAME}.app"
  echo "Helper installed — toggling no longer asks for a password."
  echo "Launch it from Spotlight (${APP_NAME}) or: open -a ${APP_NAME}"
fi
