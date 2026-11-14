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

## The guest's ear

The headline columns score echo the way the other person on the call meets it: their own voice coming back.
Echo loss is the far end's level arriving at Browsa against the far-end-correlated level Browsa sends back;
with the G.107 default SLR + RLR (8 + 2 dB) that gives a TELR, judged by ITU-T G.131's rule
`f = TELR − 40·log10((1 + T/10)/(1 + T/150)) + 6·e^(−0.3T²)` (f ≥ 14 acceptable, f ≤ 8 annoying), with T the
one-way delay (`--one-way-ms`, default 300) plus half of Browsa's own echo path. It is also scored in 200 ms
blocks of their speech: how much of it would carry audible echo, the worst moment, the first 5 s against the
rest. Talk-over fits the sent audio to both known voices together, so your voice doesn't hide the echo;
figures shown as "≥" hit the measurement limit.

The score picks candidates; your ear decides. `node listen.mjs <run folder> <out folder> [subject ids]` makes
small AAC clips per subject (what comes back while only they talk, the same +30 dB, and talk-over) and a
`listen.html` laying them out with the scores. These are recordings of your room: they stay in `derived/`,
never in git.

Far-end stimuli: `--far natural` (the standup voice cut into phrases with pauses and quiet and loud phrases,
so word onsets after silence get tested) or `--far <file>`, e.g. a recording of your own voice, since people
are most sensitive to their own. `--prepare-stimuli` makes the files and stops.

## A real Meet call, with a robot guest

`meet` is a real call through Google's servers and Opus, scored from what the guest receives: exactly what
another participant hears.

1. In the build under test (your Browsa, or Browsa WebKit Spike via `derived/webkit-spike/run.sh`, signed in to
   Google), start a Meet and copy its link. Leave the speakers at call volume and the mic as usual.
2. `tools/audio-bench/run.sh --subjects meet --meet-url https://meet.google.com/abc-defg-hij --host "spike patched" --volumes same`
   (`--volumes same` leaves the system volume alone; `--long 15` for a 15 minute soak).
3. A guest called "Echo guest" asks to join: admit it. It waits up to 10 minutes (`--wait-min`).
4. Then stay quiet. The guest talks with the far-end recording (its "mic" is generated in its page; its own
   sound is muted), the bench plays the stand-in "you" on the MacBook speakers, and the guest records what
   comes back. It leaves by itself.

The guest's voice must come from the recording. Don't let anyone speak as "the guest" in the same room: the
host's mic would pick that up directly, and that isn't echo.

To include tab switching mid-call, start the Browsa build with `BROWSA_AUDIO_BENCH=1
BROWSA_AUDIO_BENCH_TAB_SWITCH=20` (test builds only): every 20 s it shows a blank tab for 2 s and goes back.

`node guest.mjs --selftest --far <wav> --near <wav> --out-dir <dir>` checks the guest silently (no Meet, no
devices): a local host page sends back the guest's voice 40 dB down and 120 ms late, plus a talker. The
analysis reads that as 43 dB (far end only) and 41 dB (talk-over): about 1 to 3 dB optimistic through two Opus legs.
