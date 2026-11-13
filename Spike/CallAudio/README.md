# Call audio spikes

Can Browsa get Chrome's call audio (no echo on open speakers) without running calls on Chromium?
Chrome's answer is WebRTC's audio processing (AEC3 echo canceller, noise suppressor) sitting directly
between the two audio devices. These spikes put the same thing under WebKit instead of inside the page.

- `core/` the audio core: owns the microphone and speakers, lines the two device clocks up in host
  time, and runs WebRTC's processing with an exact copy of what was played. `test/` checks the timing
  half with simulated drifting devices (runs anywhere).
- `lab/` Browsa Audio Lab (`com.orriginal.browsa.audiolab`): plays a far-end recording and measures the
  echo that comes back, for Browsa's core, Apple's voice processing (what WebKit uses) and no
  processing, on the same yardstick as `tools/echo-test`.

Build with `Spike/CallAudio/build.sh`, then for example:

    open -W -n "$HOME/Developer/Browsa/derived/audio-lab/Browsa Audio Lab.app" --args \
      --mode webrtc --far "$PWD/tools/echo-test/standup.mp3" --out-dir /tmp/lab-webrtc
    cat /tmp/lab-webrtc/report.txt
