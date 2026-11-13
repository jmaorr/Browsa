#!/bin/sh
# Builds "Browsa Audio Lab.app" (bundle com.orriginal.browsa.audiolab): the call audio core plus the
# echo measuring tool. Needs Xcode's command line tools, git and Python 3.10+ (for Meson).
#   Spike/CallAudio/build.sh [output dir, default ~/Developer/Browsa/derived/audio-lab]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HOME/Developer/Browsa/derived/audio-lab}
WORK=${WORK:-$HOME/Library/Caches/browsa-call-audio}
TAG=${APM_TAG:-v1.3}
mkdir -p "$WORK" "$OUT" && cd "$WORK"

if [ -z "${PYTHON:-}" ]; then
  for p in python3.13 python3.12 python3.11 python3.10; do command -v $p >/dev/null && PYTHON=$(command -v $p) && break; done
  [ -z "${PYTHON:-}" ] && command -v uv >/dev/null && PYTHON=$(uv python find '>=3.10' 2>/dev/null || true)
fi
[ -n "${PYTHON:-}" ] || { echo "Needs Python 3.10+ (set PYTHON=...)" >&2; exit 1; }
[ -x venv/bin/meson ] && [ -x venv/bin/ninja ] || { rm -rf venv; "$PYTHON" -m venv venv && venv/bin/pip install -q meson ninja; }
export PATH="$WORK/venv/bin:$PATH"

# WebRTC's audio processing, native this time (the WebAssembly build shares the same checkout).
[ -d apm ] || git clone --depth 1 --branch "$TAG" https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git apm
if [ ! -f build-native/build.ninja ]; then
  meson setup build-native apm --default-library=static --buildtype=release
fi
ninja -C build-native

INC="-I apm -I apm/webrtc -I build-native"
for d in build-native/subprojects/abseil-cpp* apm/subprojects/abseil-cpp*; do [ -d "$d" ] && INC="$INC -I $d"; done
LIBS=$(find build-native -name '*.a' | sort | tr '\n' ' ')

c++ -std=c++17 -O2 -I "$HERE/core" "$HERE/test/timeline_test.cc" -o "$OUT/timeline_test" && "$OUT/timeline_test"

APP="$OUT/Browsa Audio Lab.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$HERE/lab/Info.plist" "$APP/Contents/Info.plist"
clang++ -std=c++17 -O2 -fobjc-arc -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_APM_DEBUG_DUMP=0 -Wno-deprecated-declarations \
  -I "$HERE/core" $INC "$HERE/core/Apm.cc" "$HERE/core/CallAudioCore.mm" "$HERE/lab/main.mm" \
  $LIBS \
  -framework Foundation -framework AVFoundation -framework AudioToolbox -framework CoreAudio \
  -o "$APP/Contents/MacOS/audiolab"
codesign --force --sign - "$APP"
echo "Built $APP"
