// Browsa call audio core: owns the microphone and the speakers for a call, the way Chrome's audio
// stack does, and runs WebRTC's processing between them.
//
//   far-end audio --> [playout] --> speakers
//                        | exactly what was played, stamped with when it reaches the air
//                        v
//   microphone ----> [echo canceller, noise suppressor] --> clean 48 kHz mono, 10 ms frames
//
// macOS only (Core Audio). See AudioTimeline.h for how the two device clocks are reconciled.
#pragma once
#include <functional>
#include <string>

namespace browsa {

struct CallAudioConfig {
  enum Mode { kWebRtc, kRaw, kAppleVoiceProcessing } mode = kWebRtc;
  std::string inputDevice, outputDevice;    // name contains; empty = system default
  bool noiseSuppression = true, autoGain = false;
  double referenceLeadMs = 10;              // how far ahead of the microphone the reference is fed
  unsigned channelMask = 0x3;               // device inputs that make up the mic (bit 0 = input 1); own path only
  // Every device input as captured, at the device's rate, before mixing. Own path only (not Apple's
  // voice processing, which keeps its inputs to itself). Called on the input audio thread.
  std::function<void(const float* const* channels, int count, int frames)> channelTap;
};

struct CallAudioStatus {
  std::string inputName, outputName;
  double inputRate = 0, outputRate = 0; int inputChannels = 0;
  double inputLatencyMs = 0, outputLatencyMs = 0;
  double driftPpm = 0;                      // speaker clock against microphone clock
  int resyncs = 0, referenceMisses = 0, clockResets = 0;
  double erle = -1, delayMs = -1, residualLikelihood = -1;
};

class CallAudioCore {
 public:
  // Fills `frames` mono 48 kHz samples of far-end audio to play. Called on the output audio thread.
  using Playout = std::function<void(float* mono, int frames)>;
  // One 10 ms frame: the raw microphone, the reference it was cancelled against, and the result.
  // Called on the input audio thread.
  using Capture = std::function<void(const float* raw, const float* reference, const float* clean, int frames)>;

  static CallAudioCore* create(const CallAudioConfig&, Playout, Capture, std::string* error);
  virtual ~CallAudioCore() {}
  virtual bool start(std::string* error) = 0;
  virtual void stop() = 0;
  virtual CallAudioStatus status() = 0;
};

}  // namespace browsa
