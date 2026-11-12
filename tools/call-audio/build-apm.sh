#!/bin/sh
# Builds WebRTC's audio processing module (echo canceller, noise suppressor, gain controller) to
# WebAssembly for Browsa's call audio: Packages/BrowserKit/Sources/WebKitEngine/Resources/call-audio-apm.wasm.
#
# Sources: the freedesktop.org webrtc-audio-processing release (BSD-3-Clause, see its COPYING),
# pinned below. Needs git and Python 3.10+ (set PYTHON, or have uv or python3.1x on PATH); installs
# Emscripten, Meson and Ninja under $WORK.
set -eu
TAG=${APM_TAG:-v1.3}
EMSDK_VERSION=${EMSDK_VERSION:-latest}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$HOME/Library/Caches/browsa-call-audio}
OUT="$REPO/Packages/BrowserKit/Sources/WebKitEngine/Resources/call-audio-apm.wasm"
mkdir -p "$WORK" && cd "$WORK"

# Emscripten needs Python 3.10+; macOS's python3 is 3.9.
if [ -z "${PYTHON:-}" ]; then
  for p in python3.13 python3.12 python3.11 python3.10; do command -v $p >/dev/null && PYTHON=$(command -v $p) && break; done
  [ -z "${PYTHON:-}" ] && command -v uv >/dev/null && PYTHON=$(uv python find '>=3.10' 2>/dev/null || true)
fi
[ -n "${PYTHON:-}" ] || { echo "Needs Python 3.10+ (set PYTHON=...)" >&2; exit 1; }
[ -x venv/bin/meson ] && [ -x venv/bin/ninja ] || { rm -rf venv; "$PYTHON" -m venv venv && venv/bin/pip install -q meson ninja; }
export PATH="$WORK/venv/bin:$PATH" EMSDK_PYTHON="$WORK/venv/bin/python3"

[ -d emsdk ] || git clone --depth 1 https://github.com/emscripten-core/emsdk.git
(cd emsdk && ./emsdk install "$EMSDK_VERSION" && ./emsdk activate "$EMSDK_VERSION") >/dev/null
. ./emsdk/emsdk_env.sh >/dev/null 2>&1

[ -d apm ] || git clone --depth 1 --branch "$TAG" https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git apm

cat > cross.txt <<CROSS
[binaries]
c = 'emcc'
cpp = 'em++'
ar = 'emar'
ranlib = 'emranlib'
[host_machine]
system = 'emscripten'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
[built-in options]
c_args = ['-O3', '-DWEBRTC_POSIX']
cpp_args = ['-O3', '-DWEBRTC_POSIX', '-fno-exceptions']
CROSS

rm -rf build
venv/bin/meson setup build apm --cross-file cross.txt --default-library=static --buildtype=release \
  -Dc_args=-DWEBRTC_POSIX -Dcpp_args=-DWEBRTC_POSIX
ninja -C build

INC="-I apm -I apm/webrtc -I build"
for d in build/subprojects/abseil-cpp* apm/subprojects/abseil-cpp*; do [ -d "$d" ] && INC="$INC -I $d"; done
LIBS=$(find build -name '*.a' | sort | tr '\n' ' ')
em++ -O3 -std=c++17 -fno-exceptions -DWEBRTC_POSIX $INC "$HERE/apm_wasm.cc" -Wl,--start-group $LIBS -Wl,--end-group \
  -sSTANDALONE_WASM --no-entry -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=8MB \
  -sEXPORTED_FUNCTIONS=_apm_create,_apm_configure,_apm_set,_apm_stat,_apm_mic,_apm_ref,_apm_process,_apm_destroy,_malloc,_free \
  -o "$OUT"
echo "Built $OUT ($(wc -c < "$OUT") bytes)"
