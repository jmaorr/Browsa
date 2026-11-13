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
