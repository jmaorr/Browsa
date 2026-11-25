# DRM streaming

Browsa plays DRM-protected video (Apple TV+, BritBox and other services that support Safari) through **FairPlay
Streaming**, the only DRM system WebKit has. It has no Widevine or PlayReady, so a service that only supports
Chrome, Edge or Firefox won't play protected video.

There is no DRM code in this repository, and none is needed: WebKit implements Encrypted Media Extensions for
`com.apple.fps` on top of macOS's own FairPlay (AVFoundation's content key session), and Browsa neither adds to it
nor turns it off.

## Browsa's own WebKit build has it too

On Apple silicon the released app runs on a WebKit that Browsa builds and bundles
(`Contents/Frameworks/WebKit-26` or `WebKit-27`; `Spike/CallAudio/webkit/BUNDLING.md`), so Safari working doesn't
settle the question. This was checked on that engine, not the system one:

| | |
|---|---|
| App | Browsa 1.3 (build 744), the notarised download from browsa.app |
| Engine | the bundled `WebKit-26`, confirmed from the running processes' paths |
| macOS | 26.7.3, Apple silicon |
| `com.apple.fps` (FairPlay) | offered to pages; `MediaKeys` created; H.264 and HEVC video, AAC audio; `sinf`, `skd` and `cenc` init data |
| `com.widevine.alpha`, `com.microsoft.playready` | not offered (`NotSupportedError`), as expected on WebKit |

The check is a page anyone can run: [`tools/drm-check`](../tools/drm-check/README.md). The full answer from that
run is in [`tools/drm-check/results/mac-1.3-744-webkit-26.json`](../tools/drm-check/results/mac-1.3-744-webkit-26.json).
It shows the engine offers FairPlay. It doesn't show a film playing, which needs an account; that's the next table.

## Services played

Played by hand by the maker, signed in, in Browsa for Mac: a protected title played.

| Service | Result | Checked |
|---|---|---|
| Apple TV+ (tv.apple.com) | Plays | November 2026 |
| BritBox | Plays | November 2026 |

Screen recordings of protected video are black by design (that is FairPlay working), so there is no screen
capture to show here.

Not DRM, so not evidence either way: ordinary YouTube videos (they play, but unprotected).

## Adding a service

Play a protected title, not a trailer, in a release build on Apple silicon, and add a row with the month. If it
fails, add the row anyway with what happened.
