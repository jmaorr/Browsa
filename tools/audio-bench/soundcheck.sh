#!/bin/sh
# Short sound check of Browsa WebKit Spike (the patched WebKit unit) with its debug dump on, then the offline
# sweep over that dump. Plays sound: run only when it's fine to. About 3 minutes of audio plus start-up.
#   tools/audio-bench/soundcheck.sh <volume 0-60> [more bench options, e.g. --far natural]
# Uses the WebKit build in WebKitBuild/Release (BROWSA_SPIKE_WEBKIT to change), unit settings from any
# BROWSA_CALL_AUDIO_* variables in the environment. The system volume is put back afterwards (the bench does it,
# and this script again on any exit). Ends with one line: current score | best setting | score at best.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 1 ] || { echo "usage: soundcheck.sh <volume 0-60> [bench options]" >&2; exit 2; }
VOL=$1; shift
V0=$(osascript -e 'output volume of (get volume settings)')
trap 'osascript -e "set volume output volume $V0" >/dev/null 2>&1 || true' EXIT INT TERM
if pgrep -f "Browsa WebKit Spike.app/Contents/MacOS/Browsa" >/dev/null; then echo "Quit Browsa WebKit Spike first (the bench starts its own)." >&2; exit 1; fi
START=$(date +%s)
# 1 = the GPU process's own cache folder: its sandbox can't write anywhere in ~/Developer.
BENCH_UNIT_DUMP=1 "$HERE/run.sh" --subjects spike --volumes "$VOL" --long 2.5 "$@" || echo "(bench exited with an error; scoring whatever the unit dumped)"
osascript -e "set volume output volume $V0" >/dev/null 2>&1 || true
exec node --input-type=module -e '
import { findDumps, afterCall } from "'"$HERE"'/aftercall.mjs";
const d = findDumps().filter((x) => x.mtime / 1000 >= '"$START"');
if (!d.length) { console.error("The unit wrote no dump: check WebKit logs (log show --predicate \"eventMessage CONTAINS \\\"BrowsaCallAudioInternalUnit\\\"\" --last 10m)."); process.exit(1); }
const r = await afterCall(d[0].dir, { sweep: true, minutes: 10 });
console.log(r.lines.join("\n"));
console.log("\n" + r.lines.find((l) => l.startsWith("Sweep")).replace(/^Sweep \([^)]*\): /, ""));
'
