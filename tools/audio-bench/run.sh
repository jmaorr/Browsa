#!/bin/sh
# Audio Bench: see README.md. Builds Browsa Audio Lab first if it isn't there.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
[ -x "$HOME/Developer/Browsa/derived/audio-lab/Browsa Audio Lab.app/Contents/MacOS/audiolab" ] || "$HERE/../../Spike/CallAudio/build.sh"
exec node "$HERE/bench.mjs" "$@"
