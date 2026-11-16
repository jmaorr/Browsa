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
for a 10 minute far-end/double-talk soak that catches drift and gain creep). `--no-talker`: far end only (quiet, 80 s
of far end, quiet; `--long N` for N minutes), nothing on the MacBook speakers: the echo figures, without talk-over.

- **Far end**: the call's incoming voice (`tools/echo-test/standup.mp3`) on the call speakers (default output,
  or `--out`).
- **You**: a stand-in talker, macOS's "Daniel" voice reading `talker.txt`, played from a second speaker
  (`--talker-out`, default MacBook Pro Speakers, at `--talker-volume`, default 0.5, capped at 0.5). Different
  voice, different speaker, so the analysis can tell the two apart.

## Subjects

| name | what it is |
|---|---|
| `webrtc` | Browsa's native call audio core (`Spike/CallAudio`): WebRTC processing on the real device clocks |
| `apple` | Apple's voice processing unit set up as WebKit sets it up |
| `raw` | the mic with no processing: how much echo the room gives |
| `chrome` | Google Chrome, throwaway profile, the bench page (below) |
| `spike`, `spike-apple` | Browsa WebKit Spike on the patched WebKit (`Spike/CallAudio/webkit`), and the same build with Apple's processing |
| `inpage` | the earlier route: the same test build on system WebKit with Browsa's in-page call audio script |
| `meet` | a real Meet call scored by a robot guest (below) |
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

## Unit dumps: after a real call, and offline tuning

The patched WebKit unit (Browsa WebKit Spike) can dump a call (`BROWSA_CALL_AUDIO_DUMP=1`, see
`Spike/CallAudio/webkit/README.md`). Three tools work from a dump, nothing played:

```sh
node tools/audio-bench/aftercall.mjs [dump folder] [--sweep]   # newest spike dump if none given
node tools/audio-bench/sweep.mjs <dump folder> [--minutes 10] [--offsets -40:40:5] [--quick]
tools/audio-bench/soundcheck.sh <volume> [bench options]          # plays sound: bench run of the spike + sweep
```

`aftercall.mjs` copies the dump to `derived/audio-bench/call-<time>/` and writes `report.txt`, `score.json` and
clips (`guest-hears.m4a`, `guest-hears-plus30dB.m4a`, `you-sent.m4a`). A real call has no known talker, so
`dumpscore.mjs` finds the stretches itself from 2 s blocks: **far only** (the far end in `ref.wav` active and the
mic mostly explained by it, or hearing nothing above the room), **you only** (far end silent, mic 10 dB over the
room), quiet, and mixed. Meaningful figures: the guest's-ear echo scores (far-only stretches only), your send
level and how much of your voice was kept (you-only), the room as sent. Not measurable: talk-over and gain
pumping (use the bench). On the bench schedule the detection finds the far-only and you-only segments to within
about half a second, and leaves double talk out.

`sweep.mjs` replays the dump through `apm-replay-webkit` (`Spike/CallAudio/webkit/build-replay.sh`: the exact
processing the unit runs) with the reference offset from -40 to +40 ms in 5 ms steps, then at the best offset
auto gain off, gain limit 20/40 dB, noise ceiling -50/-70 dBFS and noise suppression 1/3. Rank: G.131 margin
capped at 20, less 0.25 per % of their speech with audible echo, less 0.5 per dB the send level is more than 6 dB
from -26 dBFS. Ties within 0.5 go to the fewest changes. It also replays the recorded settings and compares with
what was sent live (a faithful replay is about -30 dB or lower). Checked on the 2026-11-14 native recordings
converted to the dump layout (`derived/audio-bench/validate-2026-11-14/`): 0 ms comes out best, +30 ms leaves
audible echo in 12-25% of the guest's speech and +35 ms is annoying.

`bench.mjs`: `BENCH_UNIT_DUMP=1` sends the spike subject's dump to the GPU process folder (the default, a folder
in the run, is outside the GPU sandbox).

Both `aftercall.mjs` and `sweep.mjs` also write `report.html` next to their clips (playable in place), with the
offset curve and every variant's scores.

What sent audio alone can't tell: the 2026-11-14 spike run kept only `sent.wav` (no raw mic or reference), so it
can't be replayed. Checked whether the shape of its leftover echo could still show a late reference: calibrated
on native replays with known shifts, AEC3 doesn't leave a clean "first X ms uncancelled" residue (a late reference
raises leftovers across the response while the main peak stays suppressed), and the spike's leftover shape matched
every shift from -80 to +60 ms about equally (correlation 0.6 to 0.8, the plain room response 0.67). So that
recording neither supports nor rules out a late reference; what it does show is about 20 dB more linear echo than
the native core (-57 against -77 dBFS coherent), concentrated at the main echo path. A unit dump answers it.

## Clock drift (spike runs)

The `spike` subject records the unit's own dump (raw mic, reference, sent, clock figures) in WebKit's GPU process
cache folder, the one place its sandbox lets it write, and the bench copies it into the subject's `unit-dump/`
afterwards. `drift.mjs` (run by the bench, or `node tools/audio-bench/drift.mjs <dump folder>`) then reports, in the
report's notes and `drift.json`:

- the clocks: the speakers' and the microphone's real rate against their nominal one (ppm) and the gap between them
  (10 ppm is 0.6 ms a minute);
- the echo path, reference to microphone, in 10 s windows: it should hold still however the clocks drift (the unit
  reads the reference in host time); a slope is drift the canceller has to chase.

For drift over a call's length without the stand-in talker: `--no-talker --long 10` (10 minutes of far end only).
