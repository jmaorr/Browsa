// WebRTC's audio processing module (the echo canceller, noise suppressor and gain controller Chrome
// uses) behind a tiny interface: mono, 48 kHz, 10 ms (480 sample) frames.
#pragma once
namespace browsa {
struct ApmOptions {
  bool echo = true, noise = true, gain = false, highPass = true;
  int noiseLevel = 2;                    // 0 low, 1 moderate, 2 high, 3 very high
  float gainMaxChangeDbPerSecond = 3;    // auto gain: how fast it may move
  float gainMaxNoiseDbfs = -50;          // auto gain: never lifts noise above this
};
struct ApmStats { double erle = -1, erl = -1, delayMs = -1, residualLikelihood = -1; };
class Apm {
 public:
  static Apm* create(const ApmOptions&);
  virtual ~Apm() {}
  virtual void played(float* frame480) = 0;                       // what the speakers are playing
  virtual bool process(float* frame480, int delayHintMs) = 0;     // the microphone, cleaned in place
  virtual ApmStats stats() = 0;
};
}
