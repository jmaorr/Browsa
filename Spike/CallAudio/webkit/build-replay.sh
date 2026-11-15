#!/bin/sh
# Builds apm-replay-webkit (../replay/webkit_main.cc) against the patched WebKit's libwebrtc, so offline replays
# of a unit dump run the exact processing the call ran. Output: ~/Developer/Browsa/derived/audio-lab/apm-replay-webkit.
# Env: WEBKIT (default ~/Developer/BrowsaWebKit), FW (default $WEBKIT/WebKitBuild/Release), OUT.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
WEBKIT=${WEBKIT:-$HOME/Developer/BrowsaWebKit}
FW=${FW:-$WEBKIT/WebKitBuild/Release}
OUT=${OUT:-$HOME/Developer/Browsa/derived/audio-lab}
SRC="$WEBKIT/Source/ThirdParty/libwebrtc/Source"
mkdir -p "$OUT"
# libwebrtc.dylib only lets WebKit's own frameworks link to it, so link against a text stub of the few symbols
# used (same library, loaded from $FW at run time through the rpath).
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/libwebrtc.tbd" <<TBD
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-macos, x86_64-macos ]
install-name: '@rpath/libwebrtc.dylib'
exports:
  - targets: [ arm64-macos, x86_64-macos ]
    symbols: [ __ZN6webrtc29BuiltinAudioProcessingBuilder5BuildERKNS_11EnvironmentE,
               __ZNK6webrtc18EnvironmentFactory6CreateEv, __ZTVN6webrtc29BuiltinAudioProcessingBuilderE ]
...
TBD
xcrun clang++ -std=c++20 -O2 -w \
  -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_WEBKIT_BUILD -DABSL_ALLOCATOR_NOTHROW -DWEBRTC_APM_DEBUG_DUMP=0 \
  -I "$HERE/../replay" -I "$HERE/../core" -I "$FW/usr/local/include" -I "$FW/usr/local/include/webrtc" \
  -I "$SRC" -I "$SRC/webrtc" -I "$SRC/third_party/abseil-cpp" \
  "$HERE/../replay/webkit_main.cc" -L "$STUB" -lwebrtc -Wl,-rpath,"$FW" -o "$OUT/apm-replay-webkit"
echo "Built $OUT/apm-replay-webkit (libwebrtc from $FW)"
