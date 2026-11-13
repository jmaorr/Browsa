# Browsa Call Spike (Chromium call tab)

Spike, 2026-11-13. Not part of Browsa. The question: does running call sites (Meet) in an embedded Chromium
(CEF, Alloy style) inside a Browsa window fix call echo the way Arc and Chrome do?

Answer, from the hands-on test with Josh: yes.

The setup:
- Meet ran in this app on the Creative Stage SE speakers and the Scarlett mic.
- A plain Chrome guest played standup.wav as its mic and played its output to AirPods, standing in for
  the far end's ears.

The result:
- The guest heard only Josh's voice, network-delayed. None of the stand-up playing from the speakers came
  back, apart from a trace in the first second or two while Chromium's AEC3 adapted. WebKit Browsa failed
  this same scenario on real calls.
- Switching to the WebKit tab mid-call kept call audio going. The Chromium view is removed from the window
  when that happens, as Browsa does.

## Build

- Needs CEF 156.0.15 (chromium 156.0.8078.80), the minimal macOS arm64 build, from
  https://cef-builds.spotifycdn.com. Unpack it at ~/Developer/CEF/cef and build libcef_dll_wrapper:
  `mkdir build && cd build && cmake -G Xcode -DPROJECT_ARCH=arm64 .. && xcodebuild -target libcef_dll_wrapper -configuration Release`.
- Build the target: `xcodegen generate && xcodebuild -scheme BrowsaCallSpike`. Mac/Chromium/embed-cef.sh
  copies the framework and helper apps into the app bundle.
- Environment variables:
  - `BROWSA_CALL_URL`: the start page.
  - `BROWSA_CALL_RECORD=<file.jsonl>`: saves recorder chunks every 10 s.
  - `BROWSA_CALL_SWITCH=<s>`: switches tabs automatically every s seconds.
- Logs go to ~/Library/Logs/Browsa/call-spike.log.

## Facts

- App size: 331 MB. The CEF framework is 327 MB of that, about 117 MB as .tar.bz2.
- On a Meet call: 8 processes, about 1.3 GB RSS, about 24% CPU (one sample). For comparison, Arc with all
  its tabs was 2.8 GB.
- What had to be added:
  - Permission handling. Meet's camera and mic requests come through OnShowPermissionPrompt. Answering it
    ourselves tripped a CEF check, so the spike uses `--use-fake-ui-for-media-stream`, which auto-accepts
    and still uses the real devices.
  - An Edit menu, for copy and paste.
  - NSBluetoothAlwaysUsageDescription. Without it, TCC kills the app during Google's phone-passkey sign-in.
- Sign-in is separate: the Chromium profile's Google sign-in is its own, not shared with WebKit tabs.
- Recorder caveat: the page-side recorder caught a raw mic copy with echo cancellation off, not the
  processed track Meet sends. So the verdict above comes from listening at the far end, not from levels.
- Not tested yet:
  - Screen sharing (getDisplayMedia needs a picker in Alloy).
  - Notifications.
  - H.264, which isn't in standard CEF builds; Meet uses VP8, VP9 and AV1.
  - Memory on a long call.
