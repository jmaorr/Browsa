#!/bin/sh
# Installs open-spike.sh and the camera/mic check page into ~/Developer/Browsa/derived/webkit-spike, and writes the
# double-click launchers to ~/Applications (nothing is started):
#   Browsa WebKit Spike.command                  for meetings: the frozen WebKit build (WebKitBuild/Release-meeting,
#                                                the 3a31ddd unit), default settings, debug dump on
#   Browsa WebKit Spike (tuned).command          opt-in: the current build (WebKitBuild/Release) with the best settings
#                                                from the newest sweep of a real unit dump, if its replay was faithful
#   Browsa WebKit Spike (camera & mic check).command
#                                                opens a local page that asks for the camera and mic, so the
#                                                permissions are granted before a meeting
# All start the spike through LaunchServices (open-spike.sh), so macOS asks about the camera and mic for the spike
# itself. The daily Browsa is never touched.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DERIVED="$HOME/Developer/Browsa/derived/webkit-spike"
DEST=${DEST:-$HOME/Applications}
mkdir -p "$DEST" "$DERIVED/preflight"
cp "$HERE/open-spike.sh" "$DERIVED/open-spike.sh" && chmod +x "$DERIVED/open-spike.sh"
cp "$HERE/preflight/index.html" "$DERIVED/preflight/index.html"

cat > "$DEST/Browsa WebKit Spike.command" <<'CMD'
#!/bin/sh
# Browsa WebKit Spike for a real call: patched WebKit (WebRTC processing in WebKit's capture unit), no Chromium call
# tabs, Browsa's in-page call audio script off, unit debug dump on. Started through LaunchServices so macOS asks
# about the camera and mic for the spike itself. Your daily Browsa (~/Applications/Browsa.app) is untouched.
OPEN="$HOME/Developer/Browsa/derived/webkit-spike/open-spike.sh"
if pgrep -f "Browsa WebKit Spike.app/Contents/MacOS/Browsa" >/dev/null; then
  osascript -e 'tell application id "com.orriginal.browsa.webkitspike" to activate'
  echo "Browsa WebKit Spike is already running."
  exit 0
fi
unset BROWSA_AUDIO_BENCH BROWSA_AUDIO_BENCH_URL BROWSA_AUDIO_BENCH_CALL_TABS BROWSA_AUDIO_BENCH_CALL_AUDIO BROWSA_CALL_AUDIO
# Pinned to the WebKit build of 3a31ddd (an APFS clone made before newer WebKit rebuilds); drop this to use WebKitBuild/Release.
export BROWSA_SPIKE_WEBKIT="$HOME/Developer/Browsa/webkit/source/WebKitBuild/Release-meeting"
export BROWSA_CALL_AUDIO_DUMP=1
echo "=== $(date) start (meeting)" >>"$HOME/Library/Logs/Browsa WebKit Spike.log"
"$OPEN" >/dev/null && echo "Started Browsa WebKit Spike. You can close this window."
CMD

cat > "$DEST/Browsa WebKit Spike (camera & mic check).command" <<'CMD'
#!/bin/sh
# Opens a local page in Browsa WebKit Spike that asks for the camera and microphone and shows the camera and a mic
# level (nothing recorded, nothing played). Allow both when Browsa and macOS ask; then meetings won't stall on it.
DIR="$HOME/Developer/Browsa/derived/webkit-spike/preflight"
OPEN="$HOME/Developer/Browsa/derived/webkit-spike/open-spike.sh"
PORT=8791
URL="http://127.0.0.1:$PORT/index.html"
# A local web server for 15 minutes (localhost counts as secure, so the page may ask for the camera).
if ! curl -s -o /dev/null "$URL"; then
  ( cd "$DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  SERVER=$!
  ( sleep 900; kill "$SERVER" ) >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "$URL" && break; sleep 0.3; done
fi
if pgrep -f "Browsa WebKit Spike.app/Contents/MacOS/Browsa" >/dev/null; then
  open -a "$HOME/Developer/Browsa/derived/webkit-spike/Browsa WebKit Spike.app" "$URL"
else
  unset BROWSA_AUDIO_BENCH BROWSA_AUDIO_BENCH_URL BROWSA_CALL_AUDIO
  export BROWSA_SPIKE_WEBKIT="$HOME/Developer/Browsa/webkit/source/WebKitBuild/Release-meeting"
  echo "=== $(date) start (camera & mic check)" >>"$HOME/Library/Logs/Browsa WebKit Spike.log"
  "$OPEN" "$URL" >/dev/null
fi
echo "Opened the camera & mic check in Browsa WebKit Spike: allow the camera and microphone when asked."
CMD

cat > "$DEST/Browsa WebKit Spike (tuned).command" <<'CMD'
#!/bin/sh
# Opt-in: Browsa WebKit Spike on the current patched WebKit build (WebKitBuild/Release) with the best settings
# from the newest sweep of a real unit dump (tools/audio-bench/sweep.mjs, via soundcheck.sh or aftercall.mjs --sweep).
# Refuses when there is no such sweep, or when its replay didn't reproduce the live call (then the "best" setting
# isn't trustworthy). Debug dump on. Your daily Browsa is untouched; the plain launcher is the fallback.
OPEN="$HOME/Developer/Browsa/derived/webkit-spike/open-spike.sh"
if pgrep -f "Browsa WebKit Spike.app/Contents/MacOS/Browsa" >/dev/null; then
  echo "Browsa WebKit Spike is already running: quit it first to start it with tuned settings."
  exit 1
fi
PICK=$(node --input-type=module -e '
import fs from "node:fs"; import path from "node:path"; import os from "node:os";
const root = path.join(os.homedir(), "Developer/Browsa/derived/audio-bench"), found = [];
const walk = (d, depth) => { let es = []; try { es = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
  for (const e of es) { const p = path.join(d, e.name); if (e.isDirectory() && depth < 3) walk(p, depth + 1); else if (e.name === "sweep.json") found.push(p); } };
walk(root, 0);
const ok = found.map((p) => { try { return { p, r: JSON.parse(fs.readFileSync(p, "utf8")), t: fs.statSync(p).mtimeMs }; } catch { return null; } })
  .filter((x) => x && x.r.dumpMode === "webkit-unit").sort((a, b) => b.t - a.t);
if (!ok.length) { console.log("NONE\tNo sweep of a real unit dump yet: run the sound check or aftercall.mjs --sweep first."); process.exit(0); }
const { p, r } = ok[0];
if (!(r.replayVsLiveDb <= -20)) { console.log(`NONE\tNewest sweep (${p}) did not reproduce the live call (replay vs live ${r.replayVsLiveDb} dB): not applying its settings.`); process.exit(0); }
console.log(`${r.bestEnv === "(defaults)" ? "" : r.bestEnv}\t${p}: ${r.line}`);
')
SETTINGS=$(printf '%s' "$PICK" | cut -f1)
WHY=$(printf '%s' "$PICK" | cut -f2-)
if [ "$SETTINGS" = NONE ]; then echo "$WHY"; echo "Use the plain Browsa WebKit Spike launcher instead."; exit 1; fi
unset BROWSA_AUDIO_BENCH BROWSA_AUDIO_BENCH_URL BROWSA_AUDIO_BENCH_CALL_TABS BROWSA_AUDIO_BENCH_CALL_AUDIO BROWSA_CALL_AUDIO BROWSA_SPIKE_WEBKIT
for kv in $SETTINGS; do case "$kv" in BROWSA_CALL_AUDIO_*=*) export "$kv";; esac; done
export BROWSA_CALL_AUDIO_DUMP=1
echo "=== $(date) start (tuned: ${SETTINGS:-defaults}; from $WHY)" >>"$HOME/Library/Logs/Browsa WebKit Spike.log"
"$OPEN" >/dev/null || exit $?
echo "Started Browsa WebKit Spike on the current build with: ${SETTINGS:-default settings}"
echo "From: $WHY"
echo "You can close this window."
CMD

chmod +x "$DEST/Browsa WebKit Spike.command" "$DEST/Browsa WebKit Spike (tuned).command" "$DEST/Browsa WebKit Spike (camera & mic check).command"
echo "Installed $DERIVED/open-spike.sh and the launchers in $DEST"
