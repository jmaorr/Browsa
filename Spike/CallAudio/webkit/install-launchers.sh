#!/bin/sh
# Writes the double-click launchers for Browsa WebKit Spike into ~/Applications (nothing is started):
#   Browsa WebKit Spike.command          the meeting launcher: the frozen WebKit build (WebKitBuild/Release-meeting,
#                                         the 3a31ddd unit), default settings, debug dump on
#   Browsa WebKit Spike (tuned).command  opt-in: the current build (WebKitBuild/Release) with the best settings
#                                         from the newest sweep of a real unit dump, if its replay was faithful
# Both start the spike detached and log to ~/Library/Logs/Browsa WebKit Spike.log. The daily Browsa is never touched.
set -eu
DEST=${DEST:-$HOME/Applications}
mkdir -p "$DEST"

cat > "$DEST/Browsa WebKit Spike.command" <<'CMD'
#!/bin/sh
# Browsa WebKit Spike for a real call: patched WebKit (WebRTC processing in WebKit's capture unit),
# no Chromium call tabs, Browsa's in-page call audio script off, unit debug dump on (GPU process temp folder).
# Starts detached; this window can be closed. Your daily Browsa (~/Applications/Browsa.app) is untouched.
RUN="$HOME/Developer/Browsa/derived/webkit-spike/run.sh"
LOG="$HOME/Library/Logs/Browsa WebKit Spike.log"
if pgrep -f "Browsa WebKit Spike.app/Contents/MacOS/Browsa" >/dev/null; then
  osascript -e 'tell application id "com.orriginal.browsa.webkitspike" to activate'
  echo "Browsa WebKit Spike is already running."
  exit 0
fi
unset BROWSA_AUDIO_BENCH BROWSA_AUDIO_BENCH_URL BROWSA_AUDIO_BENCH_CALL_TABS BROWSA_AUDIO_BENCH_CALL_AUDIO BROWSA_CALL_AUDIO
mkdir -p "$(dirname "$LOG")"
echo "=== $(date) start" >>"$LOG"
# Pinned to the WebKit build of 3a31ddd (an APFS clone made before newer WebKit rebuilds); drop this to use WebKitBuild/Release.
export BROWSA_SPIKE_WEBKIT="$HOME/Developer/BrowsaWebKit/WebKitBuild/Release-meeting"
BROWSA_CALL_AUDIO_DUMP=1 nohup "$RUN" >>"$LOG" 2>&1 </dev/null &
echo "Started Browsa WebKit Spike (log: $LOG). You can close this window."
CMD

cat > "$DEST/Browsa WebKit Spike (tuned).command" <<'CMD'
#!/bin/sh
# Opt-in: Browsa WebKit Spike on the current patched WebKit build (WebKitBuild/Release) with the best settings
# from the newest sweep of a real unit dump (tools/audio-bench/sweep.mjs, via soundcheck.sh or aftercall.mjs --sweep).
# Refuses when there is no such sweep, or when its replay didn't reproduce the live call (then the "best" setting
# isn't trustworthy). Debug dump on. Your daily Browsa is untouched; the plain launcher is the fallback.
RUN="$HOME/Developer/Browsa/derived/webkit-spike/run.sh"
LOG="$HOME/Library/Logs/Browsa WebKit Spike.log"
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
unset BROWSA_AUDIO_BENCH BROWSA_AUDIO_BENCH_URL BROWSA_AUDIO_BENCH_CALL_TABS BROWSA_AUDIO_BENCH_CALL_AUDIO BROWSA_CALL_AUDIO
for kv in $SETTINGS; do case "$kv" in BROWSA_CALL_AUDIO_*=*) export "$kv";; esac; done
mkdir -p "$(dirname "$LOG")"
echo "=== $(date) start (tuned: ${SETTINGS:-defaults}; from $WHY)" >>"$LOG"
BROWSA_CALL_AUDIO_DUMP=1 nohup "$RUN" >>"$LOG" 2>&1 </dev/null &
echo "Started Browsa WebKit Spike on the current build with: ${SETTINGS:-default settings}"
echo "From: $WHY"
echo "Log: $LOG. You can close this window."
CMD

chmod +x "$DEST/Browsa WebKit Spike.command" "$DEST/Browsa WebKit Spike (tuned).command"
echo "Wrote $DEST/Browsa WebKit Spike.command and $DEST/Browsa WebKit Spike (tuned).command"
