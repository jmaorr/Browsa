#!/bin/sh
# Puts Chromium into the built app: the CEF framework and the helper apps CEF starts its
# renderer, GPU and other processes from. Runs as a build phase of BrowsaMacChromium.
# CEF_ROOT is an unpacked CEF binary distribution with libcef_dll_wrapper built (see docs/engines.md).
set -eu

CEF="${CEF_ROOT:-$HOME/Developer/CEF/cef}"
FRAMEWORKS="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
SIGN="${EXPANDED_CODE_SIGN_IDENTITY:--}"
NAME="Browsa Chromium Helper"
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
  <key>CFBundleIdentifier</key><string>com.orriginal.browsa.chromium.helper${ID_SUFFIX:+.$ID_SUFFIX}</string>
  <key>CFBundleName</key><string>$NAME$SUFFIX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><string>1</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
  codesign --force --sign "$SIGN" --timestamp=none "$APP"
done

codesign --force --sign "$SIGN" --timestamp=none "$FRAMEWORKS/Chromium Embedded Framework.framework"
