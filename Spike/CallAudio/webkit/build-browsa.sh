#!/bin/sh
# Builds "Browsa WebKit Spike" (com.orriginal.browsa.webkitspike): a Debug BrowsaMac that runs calls on
# WebKit with Browsa's in-page call audio script off, so the
# patched WebKit's capture unit is the only processing. Hardened runtime is off so DYLD_FRAMEWORK_PATH
# reaches the app. Also writes run.sh, which starts it against a WebKit build.
#   Spike/CallAudio/webkit/build-browsa.sh
# Env: OUT (default ~/Developer/Browsa/derived/webkit-spike), WEBKIT (default ~/Developer/Browsa/webkit/source),
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OUT=${OUT:-$HOME/Developer/Browsa/derived/webkit-spike}
WEBKIT=${WEBKIT:-$HOME/Developer/Browsa/webkit/source}
BUNDLE=com.orriginal.browsa.webkitspike

cd "$ROOT"
xcodegen generate --quiet
xcodebuild -project Browsa.xcodeproj -scheme BrowsaMac -configuration Debug \
  -derivedDataPath "$OUT/DerivedData" \
  PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE BROWSA_APP_NAME="Browsa WebKit Spike" \
  ENABLE_HARDENED_RUNTIME=NO \
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
# BROWSA_SPIKE_WEBKIT=<folder> runs against another WebKit build folder (e.g. WebKitBuild/Release-meeting).
# Every BROWSA_CALL_AUDIO* variable is passed on to WebKit's processes (as __XPC_...), among them:
#   BROWSA_CALL_AUDIO_DUMP=<folder> or 1   debug dump (raw.wav, ref.wav, sent.wav, meta.json) for offline replay;
#                                          1 = the GPU process's own cache folder, the one place its sandbox can write
#   BROWSA_CALL_AUDIO_DUMP_MINUTES         dump length cap per call (default 30)
#   BROWSA_CALL_AUDIO_REF_OFFSET_MS        reference later (+) or earlier (-) than measured, ms (default 0)
#   BROWSA_CALL_AUDIO_AGC (0/1), BROWSA_CALL_AUDIO_AGC_MAX_DB (default 30), BROWSA_CALL_AUDIO_AGC_NOISE_DBFS (default -60)
#   BROWSA_CALL_AUDIO_NS (0-3, or off; default 2 = high)
set -eu
FW="\${BROWSA_SPIKE_WEBKIT:-$WEBKIT/WebKitBuild/Release}"
[ -d "\$FW/WebKit.framework" ] || { echo "No WebKit build at \$FW" >&2; exit 1; }
export DYLD_FRAMEWORK_PATH="\$FW" __XPC_DYLD_FRAMEWORK_PATH="\$FW"
export DYLD_LIBRARY_PATH="\$FW" __XPC_DYLD_LIBRARY_PATH="\$FW"
if [ "\${1:-}" = apple ]; then export BROWSA_CALL_AUDIO=apple; fi
for v in \$(env | sed -n 's/^\(BROWSA_CALL_AUDIO[A-Z0-9_]*\)=.*/\1/p'); do eval "export __XPC_\$v=\"\\\$\$v\""; done
exec "$OUT/Browsa WebKit Spike.app/Contents/MacOS/Browsa"
EOF
chmod +x "$OUT/run.sh"
echo "Built $OUT/Browsa WebKit Spike.app and $OUT/run.sh"
