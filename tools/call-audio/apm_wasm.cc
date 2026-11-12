// A tiny C interface to WebRTC's audio processing module (the echo canceller, noise suppressor and
// gain controller Chrome uses) for Browsa's call audio script. Built to standalone WebAssembly by
// build-apm.sh. One instance per processed mic; mono, 48 kHz, 10 ms frames.
#include <cmath>
#include <cstdint>
#include <cstring>
#include "modules/audio_processing/include/audio_processing.h"

#define EXPORT extern "C" __attribute__((used, visibility("default")))

namespace {
constexpr int kRate = 48000;
constexpr int kFrame = kRate / 100;

enum Flags { kEcho = 1, kNoise = 2, kGain = 4 };

// Tuning from Browsa's Audio settings, set with apm_set. Keys match call-audio.js.
enum Key {
  kNoiseLevel = 1,       // -1 off, 0 low, 1 moderate, 2 high, 3 very high
  kDelayMs = 2,          // speaker-to-mic delay hint for the echo canceller
  kPreGainDb = 3,        // mic level before any processing, -20..+20 dB
  kGainSpeed = 4,        // auto gain: max change in dB per second
  kNoiseCeilingDb = 5,   // auto gain: never lift background noise above this (dBFS)
  kHighPass = 6,         // 0/1: rumble filter
  kTransient = 7,        // 0/1: typing and click remover
  kFixedGainDb = 8,      // extra gain after processing, 0..+20 dB
};

struct Instance {
  webrtc::AudioProcessing* apm = nullptr;
  float mic[kFrame];
  float ref[kFrame];
  int flags = 0;
  int noise_level = 2;
  int delay_ms = 0;
  float pre_gain_db = 0;
  float gain_speed = 3;
  float noise_ceiling_db = -50;
  bool high_pass = true;
  bool transient = false;
  float fixed_gain_db = 0;
};

void Apply(Instance* in) {
  using Config = webrtc::AudioProcessing::Config;
  Config c;
  c.pipeline.maximum_internal_processing_rate = kRate;
  c.pre_amplifier.enabled = in->pre_gain_db != 0;
  c.pre_amplifier.fixed_gain_factor = std::pow(10.f, in->pre_gain_db / 20.f);
  c.high_pass_filter.enabled = in->high_pass;
  c.echo_canceller.enabled = in->flags & kEcho;
  c.echo_canceller.mobile_mode = false;
  c.noise_suppression.enabled = (in->flags & kNoise) && in->noise_level >= 0;
  c.noise_suppression.level = static_cast<Config::NoiseSuppression::Level>(in->noise_level < 0 ? 0 : in->noise_level > 3 ? 3 : in->noise_level);
  c.transient_suppression.enabled = in->transient;
  c.gain_controller2.enabled = (in->flags & kGain) || in->fixed_gain_db != 0;
  c.gain_controller2.fixed_digital.gain_db = in->fixed_gain_db;
  c.gain_controller2.adaptive_digital.enabled = in->flags & kGain;
  c.gain_controller2.adaptive_digital.max_gain_change_db_per_second = in->gain_speed;
  c.gain_controller2.adaptive_digital.max_output_noise_level_dbfs = in->noise_ceiling_db;
  c.residual_echo_detector.enabled = true;
  in->apm->ApplyConfig(c);
}
}  // namespace

EXPORT Instance* apm_create(int flags) {
  auto* in = new Instance();
  std::memset(in->mic, 0, sizeof in->mic);
  std::memset(in->ref, 0, sizeof in->ref);
  in->flags = flags;
  in->apm = webrtc::AudioProcessingBuilder().Create();
  if (!in->apm) { delete in; return nullptr; }
  Apply(in);
  in->apm->Initialize();
  return in;
}

EXPORT void apm_configure(Instance* in, int flags) { in->flags = flags; Apply(in); }

EXPORT void apm_set(Instance* in, int key, float value) {
  switch (key) {
    case kNoiseLevel: in->noise_level = static_cast<int>(value); break;
    case kDelayMs: in->delay_ms = static_cast<int>(value); return;   // used per frame, no reconfigure
    case kPreGainDb: in->pre_gain_db = value; break;
    case kGainSpeed: in->gain_speed = value; break;
    case kNoiseCeilingDb: in->noise_ceiling_db = value; break;
    case kHighPass: in->high_pass = value != 0; break;
    case kTransient: in->transient = value != 0; break;
    case kFixedGainDb: in->fixed_gain_db = value; break;
    default: return;
  }
  Apply(in);
}

// Statistics for the settings readout. NaN when WebRTC has no value yet.
// 1 echo return loss enhancement (dB removed by the echo canceller), 2 echo return loss (dB),
// 3 delay the echo canceller measured (ms), 4 residual echo likelihood (0..1), 5 its recent max.
EXPORT double apm_stat(Instance* in, int which) {
  const auto s = in->apm->GetStatistics(true);
  switch (which) {
    case 1: return s.echo_return_loss_enhancement.value_or(NAN);
    case 2: return s.echo_return_loss.value_or(NAN);
    case 3: return s.delay_ms ? *s.delay_ms : NAN;
    case 4: return s.residual_echo_likelihood.value_or(NAN);
    case 5: return s.residual_echo_likelihood_recent_max.value_or(NAN);
    default: return NAN;
  }
}

EXPORT float* apm_mic(Instance* in) { return in->mic; }
EXPORT float* apm_ref(Instance* in) { return in->ref; }

// Reference (what the speakers played) first, then the mic frame, processed in place.
EXPORT int apm_process(Instance* in, int delay_ms) {
  const webrtc::StreamConfig sc(kRate, 1);
  float* ref[1] = {in->ref};
  int r = in->apm->ProcessReverseStream(ref, sc, sc, ref);
  if (r != 0) return r;
  in->apm->set_stream_delay_ms(delay_ms > 0 ? delay_ms : in->delay_ms);
  float* mic[1] = {in->mic};
  return in->apm->ProcessStream(mic, sc, sc, mic);
}

EXPORT void apm_destroy(Instance* in) {
  if (!in) return;
  delete in->apm;
  delete in;
}
