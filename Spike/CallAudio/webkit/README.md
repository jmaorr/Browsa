# Spike C: Browsa's call audio inside WebKit

A patch for WebKit (builds against the commit in `WEBKIT_COMMIT`), small edits plus two headers.
`webkit.patch` is a real `git diff` from that tree (it includes `BrowsaCallAudioInternalUnit.h`), so
`git apply` works; `BrowsaAudioTimeline.h` still comes from `../core/AudioTimeline.h`:

1. Copy `BrowsaCallAudioInternalUnit.h` and `../core/AudioTimeline.h` (as `BrowsaAudioTimeline.h`) into
   `Source/WebCore/platform/mediastream/cocoa/`.
2. Apply the edits described in `webkit.patch` (by hand; the hunks are illustrative, not line exact):
   `CoreAudioCaptureInternalUnit::create` returns the Browsa unit where it would have made Apple's
   voice processing unit, prewarming is skipped, and libwebrtc exports its audio processing builder
   (two symbols in `libwebrtc.exp`, and `builtin_audio_processing_builder.h` marked Public in
   `libwebrtc.xcodeproj` so WebCore can include it).
3. Build with `Tools/Scripts/build-webkit --release`, then run a Browsa build against it with
   `DYLD_FRAMEWORK_PATH` and `__XPC_DYLD_FRAMEWORK_PATH` pointing at `WebKitBuild/Release`.

`BROWSA_CALL_AUDIO=apple` (passed to WebKit's processes as `__XPC_BROWSA_CALL_AUDIO=apple`) switches
back to Apple's voice processing in the same build, for A/B tests.

`build-browsa.sh` builds the app to test with: "Browsa WebKit Spike" (`com.orriginal.browsa.webkitspike`),
a Debug BrowsaMac with hardened runtime off (so `DYLD_FRAMEWORK_PATH` applies), Meet, Zoom and Teams on
WebKit (no Chromium call tabs for that bundle ID) and Browsa's in-page call audio off. It writes
`~/Developer/Browsa/derived/webkit-spike/run.sh`; `run.sh apple` sets `__XPC_BROWSA_CALL_AUDIO=apple`.

## Tuning without rebuilding WebKit

The unit reads these when a call's microphone starts (run.sh passes every `BROWSA_CALL_AUDIO*` variable on to
WebKit's processes as `__XPC_...`):

| variable | default | |
|---|---|---|
| `BROWSA_CALL_AUDIO_REF_OFFSET_MS` | 0 | reference later (+) or earlier (-) than the clocks say, ±100 ms |
| `BROWSA_CALL_AUDIO_AGC` | 1 | WebRTC's adaptive digital gain on/off |
| `BROWSA_CALL_AUDIO_AGC_MAX_DB` | 30 | its gain limit (libwebrtc's own default is 50) |
| `BROWSA_CALL_AUDIO_AGC_NOISE_DBFS` | -60 | the noise level it may lift to (libwebrtc's default -50) |
| `BROWSA_CALL_AUDIO_NS` | 2 | noise suppression 0 low .. 3 very high, or `off` |
| `BROWSA_CALL_AUDIO_DUMP` | off | debug dump, below |
| `BROWSA_CALL_AUDIO_DUMP_MINUTES` | 30 | dump length cap per call (about 11 MB a minute) |

`BROWSA_SPIKE_WEBKIT=<folder>` makes run.sh use another WebKit build folder.

## Debug dump

`BROWSA_CALL_AUDIO_DUMP=1` writes `raw.wav` (the mic), `ref.wav` (the reference each 10 ms of it was cancelled
against), `sent.wav` and `meta.json` (settings, formats, latencies) to a `browsa-call-audio-<pid>-<time>` folder
in the GPU process's private cache folder, `$(getconf DARWIN_USER_CACHE_DIR)com.apple.WebKit.GPU+com.orriginal.browsa.webkitspike/`.
That and its temp folder are the only places the GPU process sandbox lets it write (`com.apple.WebKit.GPUProcess.sb`:
`DARWIN_USER_CACHE_DIR`, `DARWIN_USER_TEMP_DIR`), so a folder in `~/Developer` fails. The files are written as the
call goes (a writer thread every half second, headers kept valid); `meta.json` says `"complete": true` once the
call's mic stopped cleanly.

## Offline replay and tuning

`build-replay.sh` builds `apm-replay-webkit`: WebKit's own libwebrtc (linked through a text stub, since the
dylib only allows WebKit's frameworks as clients), configured exactly as the unit configures it. So replaying a
dump with its recorded settings gives back its `sent.wav`, and other settings show what the call would have
sounded like. Then, in `tools/audio-bench`:

- `node aftercall.mjs [dump] [--sweep]`: scores the newest dump (or a given one) by the guest's ear, writes clips.
- `node sweep.mjs <dump>`: reference offset -40..+40 ms, auto gain off / 20 / 40 dB, noise ceiling, noise
  suppression levels, ranked; prints the best setting as variables for run.sh.
- `soundcheck.sh <volume>`: a short bench run of the spike with the dump on, then the sweep (plays sound).

## Launchers

Start the spike through LaunchServices, never from a shell. `open-spike.sh` does `open -n -a … --env
DYLD_FRAMEWORK_PATH=…` (plus every `BROWSA_CALL_AUDIO*` as `__XPC_*`), so macOS treats the spike as the app
using the camera and mic and asks for it by name. Started from a shell (`run.sh`), the shell's app (Terminal,
the Claude app) is held responsible: on 2026-11-16 that app had mic access but not camera, so Meet got the mic and
the camera was refused with no prompt. `run.sh` stays for debugging only.

`open-spike.sh` checks the result: it prints the pid and exits 4 with a warning if the running app hasn't got the
patched `WebKit.framework` mapped (LaunchServices didn't pass `DYLD_FRAMEWORK_PATH` on). The spike isn't hardened
(no runtime flag, `get-task-allow`), so dyld honours the variable when it arrives. It also sends a "reopen" after
8 s, in case the app came up without a window (seen once on a new WebKit build).

`install-launchers.sh` copies `open-spike.sh` and the check page into `derived/webkit-spike/` and writes three
double-click launchers to `~/Applications` (it starts nothing):

- `Browsa WebKit Spike.command`: for meetings. The frozen WebKit build `WebKitBuild/Release-meeting` (an APFS
  clone of the 3a31ddd unit), default settings, dump on.
- `Browsa WebKit Spike (camera & mic check).command`: run once before a meeting. Serves `preflight/index.html` on
  127.0.0.1:8791 for 15 minutes and opens it in the spike; the page asks for camera and mic, shows the camera and a
  mic level, records and plays nothing. Allow both in Browsa and in the macOS prompts.
- `Browsa WebKit Spike (tuned).command`: opt-in. The current build `WebKitBuild/Release` with the best settings
  from the newest sweep of a real unit dump (`sweep.json` with `dumpMode: webkit-unit`). It refuses when there is
  none, or when that sweep's replay didn't reproduce the live call (replay vs live above -20 dB).

The bench starts its `spike` subjects through `open-spike.sh` too, so the tested launch is the meeting launch.
Because the spike is then its own app for permissions, run the camera & mic check once before the first bench
run: an unanswered macOS mic prompt would stall it.

Move the meeting launcher onto the current build only once a sound check has confirmed it.
