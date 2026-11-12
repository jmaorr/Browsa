// A tiny C interface to WebRTC's audio processing module (the echo canceller, noise suppressor and
// gain controller Chrome uses) for Browsa's call audio script. Built to standalone WebAssembly by
// build-apm.sh. One instance per processed mic; mono, 48 kHz, 10 ms frames.
#include <cstdint>
#include <cstring>
#include "modules/audio_processing/include/audio_processing.h"

#define EXPORT extern "C" __attribute__((used, visibility("default")))

namespace {
constexpr int kRate = 48000;
constexpr int kFrame = kRate / 100;

struct Instance {
  webrtc::AudioProcessing* apm = nullptr;
  float mic[kFrame];
  float ref[kFrame];
};

enum Flags { kEcho = 1, kNoise = 2, kGain = 4 };

void Apply(Instance* in, int flags) {
  webrtc::AudioProcessing::Config c;
  c.pipeline.maximum_internal_processing_rate = kRate;
  c.high_pass_filter.enabled = true;
  c.echo_canceller.enabled = flags & kEcho;
  c.echo_canceller.mobile_mode = false;
  c.noise_suppression.enabled = flags & kNoise;
  c.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;
  c.gain_controller2.enabled = flags & kGain;
  c.gain_controller2.adaptive_digital.enabled = true;
  in->apm->ApplyConfig(c);
}
}  // namespace

EXPORT Instance* apm_create(int flags) {
  auto* in = new Instance();
  std::memset(in->mic, 0, sizeof in->mic);
  std::memset(in->ref, 0, sizeof in->ref);
  in->apm = webrtc::AudioProcessingBuilder().Create();
  if (!in->apm) { delete in; return nullptr; }
  Apply(in, flags);
  in->apm->Initialize();
  return in;
}

EXPORT void apm_configure(Instance* in, int flags) { Apply(in, flags); }
EXPORT float* apm_mic(Instance* in) { return in->mic; }
EXPORT float* apm_ref(Instance* in) { return in->ref; }

// Reference (what the speakers played) first, then the mic frame, processed in place.
EXPORT int apm_process(Instance* in, int delay_ms) {
  const webrtc::StreamConfig sc(kRate, 1);
  float* ref[1] = {in->ref};
  int r = in->apm->ProcessReverseStream(ref, sc, sc, ref);
  if (r != 0) return r;
  in->apm->set_stream_delay_ms(delay_ms);
  float* mic[1] = {in->mic};
  return in->apm->ProcessStream(mic, sc, sc, mic);
}

EXPORT void apm_destroy(Instance* in) {
  if (!in) return;
  delete in->apm;
  delete in;
}
