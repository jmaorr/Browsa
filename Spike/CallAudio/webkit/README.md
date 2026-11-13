# Spike C: Browsa's call audio inside WebKit

A patch for WebKit (tested against the commit in `WEBKIT_COMMIT`), three small edits plus two headers:

1. Copy `BrowsaCallAudioInternalUnit.h` and `../core/AudioTimeline.h` (as `BrowsaAudioTimeline.h`) into
   `Source/WebCore/platform/mediastream/cocoa/`.
2. Apply the edits described in `webkit.patch` (by hand; the hunks are illustrative, not line exact):
   `CoreAudioCaptureInternalUnit::create` returns the Browsa unit where it would have made Apple's
   voice processing unit, prewarming is skipped, and libwebrtc exports its audio processing builder.
3. Build with `Tools/Scripts/build-webkit --release`, then run a Browsa build against it with
   `DYLD_FRAMEWORK_PATH` and `__XPC_DYLD_FRAMEWORK_PATH` pointing at `WebKitBuild/Release`.

`BROWSA_CALL_AUDIO=apple` (passed to WebKit's processes as `__XPC_BROWSA_CALL_AUDIO=apple`) switches
back to Apple's voice processing in the same build, for A/B tests.
