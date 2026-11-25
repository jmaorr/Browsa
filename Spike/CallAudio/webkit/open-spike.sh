#!/bin/sh
# Starts Browsa WebKit Spike through LaunchServices (open -n -a), so macOS treats the spike itself as the app
# using the camera and microphone: it gets its own "would like to access the camera" prompt. Started from a
# shell instead (run.sh), the shell's app (Terminal, Claude) is held responsible, and a camera it isn't allowed
# is refused without any prompt. That is what stopped the 2026-11-16 meeting attempt.
#   open-spike.sh [apple] [url]
# Env: BROWSA_SPIKE_WEBKIT (WebKit build folder, default WebKitBuild/Release), BROWSA_SPIKE_LOG (app output,
# default ~/Library/Logs/Browsa WebKit Spike.log). Every BROWSA_CALL_AUDIO* variable goes to the app and, as
# __XPC_*, to WebKit's processes; BROWSA_AUDIO_BENCH* and BROWSA_CALL_TEST_HOSTS go to the app (test hooks).
# Prints the app's pid. Exit 3: already running; 4: started, but not on the patched WebKit (see the message).
set -eu
APP="$HOME/Developer/Browsa/derived/webkit-spike/Browsa WebKit Spike.app"
BIN="$APP/Contents/MacOS/Browsa"
FW="${BROWSA_SPIKE_WEBKIT:-$HOME/Developer/Browsa/webkit/source/WebKitBuild/Release}"
LOG="${BROWSA_SPIKE_LOG:-$HOME/Library/Logs/Browsa WebKit Spike.log}"
[ -d "$FW/WebKit.framework" ] || { echo "No WebKit build at $FW" >&2; exit 1; }
[ -x "$BIN" ] || { echo "No app at $APP (Spike/CallAudio/webkit/build-browsa.sh)" >&2; exit 1; }
if pgrep -f "$BIN" >/dev/null; then echo "Browsa WebKit Spike is already running (pid $(pgrep -f "$BIN" | head -1))." >&2; exit 3; fi
if [ "${1:-}" = apple ]; then export BROWSA_CALL_AUDIO=apple; shift; fi
URL="${1:-}"

set -- --env "DYLD_FRAMEWORK_PATH=$FW" --env "__XPC_DYLD_FRAMEWORK_PATH=$FW" --env "DYLD_LIBRARY_PATH=$FW" --env "__XPC_DYLD_LIBRARY_PATH=$FW"
for v in $(env | sed -n 's/^\(BROWSA_CALL_AUDIO[A-Z0-9_]*\)=.*/\1/p'); do
  eval "val=\$$v"
  set -- "$@" --env "$v=$val" --env "__XPC_$v=$val"
done
for v in $(env | sed -n -E 's/^(BROWSA_AUDIO_BENCH[A-Z0-9_]*|BROWSA_CALL_TEST_HOSTS)=.*/\1/p'); do
  eval "val=\$$v"
  set -- "$@" --env "$v=$val"
done
mkdir -p "$(dirname "$LOG")"
# BROWSA_SPIKE_DRY_RUN=1: print the open command and stop (for checking the environment it would pass).
if [ "${BROWSA_SPIKE_DRY_RUN:-}" = 1 ]; then printf '%s\n' open -n -a "$APP" "$@" --stdout "$LOG" --stderr "$LOG" ${URL:+"$URL"}; exit 0; fi
if [ -n "$URL" ]; then open -n -a "$APP" "$@" --stdout "$LOG" --stderr "$LOG" "$URL"; else open -n -a "$APP" "$@" --stdout "$LOG" --stderr "$LOG"; fi

PID=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do PID=$(pgrep -nf "$BIN" || true); [ -n "$PID" ] && break; sleep 1; done
[ -n "$PID" ] || { echo "Browsa WebKit Spike didn't start (see $LOG)" >&2; exit 1; }
echo "$PID"

# The spike can come up with no window (seen on the first launch of a new WebKit build): a "reopen" makes it open
# one, and does nothing more when a window is up. Sent only to the running spike.
( sleep 8; pgrep -f "$BIN" >/dev/null && osascript -e 'tell application id "com.orriginal.browsa.webkitspike" to reopen' ) </dev/null >/dev/null 2>&1 &

# Did LaunchServices pass DYLD_FRAMEWORK_PATH on? If not, the app runs on the system WebKit: a working browser,
# but without Browsa's call audio.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if lsof -p "$PID" -Fn 2>/dev/null | grep -q "^n$FW/WebKit.framework/"; then echo "patched WebKit: $FW" >&2; exit 0; fi
  sleep 1
done
echo "WARNING: Browsa WebKit Spike is running on the system WebKit, not $FW (DYLD_FRAMEWORK_PATH didn't reach it)." >&2
exit 4
