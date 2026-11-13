#!/bin/sh
# Puts Chromium into the built app for call tabs: the CEF framework and the helper apps CEF starts its
# renderer, GPU and other processes from, signed like the app (hardened runtime, with the helper
# entitlements V8 and media capture need). Runs as a build phase of BrowsaMac.
# CEF comes from tools/fetch-cef.sh (.cef/cef, or CEF_ROOT).
set -eu

CEF="${CEF_ROOT:-$SRCROOT/.cef/cef}"
[ -d "$CEF/Release/Chromium Embedded Framework.framework" ] || { echo "error: CEF missing at $CEF: run tools/fetch-cef.sh" >&2; exit 1; }
FRAMEWORKS="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
SIGN="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$SIGN" ] || SIGN="-"
NAME="Browsa Helper"
ENTITLEMENTS="$SRCROOT/Mac/Chromium/Helper/helper.entitlements"
# Hardened runtime whenever there's a real identity; a secure timestamp (needs Apple's server) only for
# Release, which notarisation checks.
if [ "$SIGN" = "-" ]; then RUNTIME=""; elif [ "${CONFIGURATION:-}" = "Release" ]; then RUNTIME="--options runtime --timestamp"; else RUNTIME="--options runtime --timestamp=none"; fi
mkdir -p "$FRAMEWORKS"

# CEF ships a flat framework (Resources/Info.plist at the top), which Xcode's product validation
# rejects; lay it out as a standard versioned framework instead.
FW="$FRAMEWORKS/Chromium Embedded Framework.framework"
if [ -d "$FW/Resources" ] && [ ! -L "$FW/Resources" ]; then rm -rf "$FW"; fi
mkdir -p "$FW/Versions/A"
rsync -a --delete "$CEF/Release/Chromium Embedded Framework.framework/" "$FW/Versions/A/"
ln -sfn A "$FW/Versions/Current"
for ITEM in "Chromium Embedded Framework" Libraries Resources; do ln -sfn "Versions/Current/$ITEM" "$FW/$ITEM"; done

HELPER="$DERIVED_FILE_DIR/cef-helper"
if [ ! -f "$HELPER" ] || [ "$SRCROOT/Mac/Chromium/Helper/helper.mm" -nt "$HELPER" ]; then
  xcrun clang++ -std=c++20 -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=26.0 \
    -I"$CEF" "$SRCROOT/Mac/Chromium/Helper/helper.mm" \
    "$CEF/build/libcef_dll_wrapper/Release/libcef_dll_wrapper.a" \
    -framework Foundation -o "$HELPER"
fi

# The old spike name, if a previous build left it.
rm -rf "$FRAMEWORKS/Browsa Chromium Helper"*.app
for SUFFIX in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  APP="$FRAMEWORKS/$NAME$SUFFIX.app"
  ID_SUFFIX=$(echo "$SUFFIX" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')
  mkdir -p "$APP/Contents/MacOS"
  cp "$HELPER" "$APP/Contents/MacOS/$NAME$SUFFIX"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME$SUFFIX</string>
  <key>CFBundleIdentifier</key><string>$PRODUCT_BUNDLE_IDENTIFIER.helper${ID_SUFFIX:+.$ID_SUFFIX}</string>
  <key>CFBundleName</key><string>$NAME$SUFFIX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><string>1</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Calls you join can use the microphone.</string>
  <key>NSCameraUsageDescription</key><string>Calls you join can use the camera.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Sign-ins can use a passkey on your phone nearby.</string>
</dict>
</plist>
PLIST
  codesign --force --sign "$SIGN" $RUNTIME --entitlements "$ENTITLEMENTS" "$APP"
done

codesign --force --sign "$SIGN" $RUNTIME "$FW/Versions/A/Libraries/"*.dylib
codesign --force --sign "$SIGN" $RUNTIME "$FW"
