#!/bin/sh
# Builds "Browsa WebKit Spike" (com.orriginal.browsa.webkitspike): a Debug BrowsaMac that runs calls on
# WebKit (no Chromium call tabs for this bundle ID) with Browsa's in-page call audio script off, so the
# patched WebKit's capture unit is the only processing. Hardened runtime is off so DYLD_FRAMEWORK_PATH
# reaches the app. Also writes run.sh, which starts it against a WebKit build.
#   Spike/CallAudio/webkit/build-browsa.sh
# Env: OUT (default ~/Developer/Browsa/derived/webkit-spike), WEBKIT (default ~/Developer/BrowsaWebKit),
#      CEF_ROOT (CEF is still embedded by the build phase; default .cef/cef in this checkout).
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OUT=${OUT:-$HOME/Developer/Browsa/derived/webkit-spike}
WEBKIT=${WEBKIT:-$HOME/Developer/BrowsaWebKit}
CEF_ROOT=${CEF_ROOT:-$ROOT/.cef/cef}
BUNDLE=com.orriginal.browsa.webkitspike

cd "$ROOT"
xcodegen generate --quiet
xcodebuild -project Browsa.xcodeproj -scheme BrowsaMac -configuration Debug \
  -derivedDataPath "$OUT/DerivedData" \
  PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE BROWSA_APP_NAME="Browsa WebKit Spike" \
  ENABLE_HARDENED_RUNTIME=NO CEF_ROOT="$CEF_ROOT" \
  build | grep -E "error:|warning: .*Browsa|BUILD (SUCCEEDED|FAILED)" || true

APP="$OUT/DerivedData/Build/Products/Debug/Browsa.app"
[ -x "$APP/Contents/MacOS/Browsa" ] || { echo "Build failed: no app in $OUT/DerivedData" >&2; exit 1; }
rm -rf "$OUT/Browsa WebKit Spike.app" && cp -R "$APP" "$OUT/Browsa WebKit Spike.app"

# Browsa's own in-page call audio off (Mac/Sources/State/Browser.swift reads this switch).
defaults write $BUNDLE callAudioProcessing -bool NO

cat > "$OUT/run.sh" <<EOF
#!/bin/sh
# Starts Browsa WebKit Spike on the patched WebKit at $WEBKIT/WebKitBuild/Release.
#   run.sh          Browsa's call audio (WebRTC processing in WebKit's capture unit)
#   run.sh apple    Apple's voice processing, same build, for A/B
set -eu
FW="$WEBKIT/WebKitBuild/Release"
[ -d "\$FW/WebKit.framework" ] || { echo "No WebKit build at \$FW" >&2; exit 1; }
export DYLD_FRAMEWORK_PATH="\$FW" __XPC_DYLD_FRAMEWORK_PATH="\$FW"
export DYLD_LIBRARY_PATH="\$FW" __XPC_DYLD_LIBRARY_PATH="\$FW"
if [ "\${1:-}" = apple ]; then export BROWSA_CALL_AUDIO=apple __XPC_BROWSA_CALL_AUDIO=apple; fi
# BROWSA_CALL_AUDIO_DUMP=<folder> (or 1): the patched unit writes raw.wav, ref.wav, sent.wav and meta.json there
# when a call's mic stops, for offline replay (tools/audio-bench/replay.mjs).
if [ -n "\${BROWSA_CALL_AUDIO_DUMP:-}" ]; then export __XPC_BROWSA_CALL_AUDIO_DUMP="\$BROWSA_CALL_AUDIO_DUMP"; fi
exec "$OUT/Browsa WebKit Spike.app/Contents/MacOS/Browsa"
EOF
chmod +x "$OUT/run.sh"
echo "Built $OUT/Browsa WebKit Spike.app and $OUT/run.sh"
