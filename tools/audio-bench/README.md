# Audio Bench

Runs several call audio paths ("subjects") through the same scenario with nobody in the room, and writes
one report: echo leak, send level, talk-over and noise, side by side.

```sh
tools/audio-bench/run.sh                                  # native: Browsa core, Apple voice processing, raw mic
tools/audio-bench/run.sh --volumes 12,25,40               # sweep the system output volume (never above 40)
tools/audio-bench/run.sh --subjects webrtc,chrome         # add a browser
tools/audio-bench/run.sh --reanalyze <run folder>         # analysis and report again, nothing played
```

Output: `~/Developer/Browsa/derived/audio-bench/<timestamp>/` with `report.html`, `results.json` and each
subject's WAVs; the newest report is also copied to `…/audio-bench/latest/`.

## Scenario

quiet 4 s | far end only 20 s | you only 15 s | both 20 s | quiet 3 s (`--schedule q,f,n,d,q`; `--long 10`
for a 10 minute far-end/double-talk soak that catches drift and gain creep).

- **Far end**: the call's incoming voice (`tools/echo-test/standup.mp3`) on the call speakers (default output,
  or `--out`).
- **You**: a stand-in talker, macOS's "Daniel" voice reading `talker.txt`, played from a second speaker
  (`--talker-out`, default MacBook Pro Speakers, at `--talker-volume`, default 0.3, capped at 0.4). Different
  voice, different speaker, so the analysis can tell the two apart.

## Subjects

| name | what it is |
|---|---|
| `webrtc` | Browsa's native call audio core (`Spike/CallAudio`): WebRTC processing on the real device clocks |
| `apple` | Apple's voice processing unit set up as WebKit sets it up |
| `raw` | the mic with no processing: how much echo the room gives |
| `chrome` | Google Chrome, throwaway profile, the bench page (below) |
| `spike`, `spike-apple` | Browsa WebKit Spike on the patched WebKit (`Spike/CallAudio/webkit`), and the same build with Apple's processing |
| `safari` | manual: needs one click (`--manual`) |

Native subjects run `Browsa Audio Lab` (built by `Spike/CallAudio/build.sh`). Run from a terminal (or
Claude) that already has microphone access, it records with no prompt.

Browser subjects open `page/bench.html` from the bench's local server (first free port from 8777). The page asks for the
mic with Meet's constraints (echo cancellation, noise suppression, auto gain), plays the far end through a
loopback `RTCPeerConnection` into an audio element (as a call does; WebKit only hands MediaStream audio to its
echo canceller), records the processed mic track and posts it back. The bench starts the talker when the page
says its schedule has started.

A subject that can't get the mic or hangs on a prompt is marked "skipped" and the run goes on. Only one bench
runs at a time. The system volume is always put back.

## Measurements

The same for every subject, from what would be sent plus the known stimuli. Each source is found in the
recording by coherence, so start-up offsets don't matter.

- **Echo (level above quiet)**: far end only, sent level against the sent quiet level (the `tools/echo-test`
  yardstick: under 3 dB good, over 10 dB heard). Also in 5 s windows. **Leftover follows far end** says
  whether a rise there is echo (follows the far end's rhythm, even distorted) or room noise.
- **Echo vs your voice (correlated)**: how much of the sent signal is the far-end recording (magnitude-squared
  coherence, 100 Hz to 7 kHz), against your speech level. Room noise can't fake it or hide it.
- **Echo while both talk** and **your voice kept in talk-over**: the same split during double-talk, and your
  voice there against your voice alone (0 dB untouched; below -8 dB you get chopped).
- **Send level** (active speech, a light P.56), **peak**, **clipped**, **gain pumping** (how much the sent level
  wanders against the talker's own level, 1 s windows), **noise floor sent**.
- Native: the canceller's delay, drift, resyncs and misses, how much correlated echo it removed, and every
  device input's level and whether it follows the far end, the talker, or neither (spots loopback inputs).
