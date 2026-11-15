// apm-replay-webkit: the same as apm-replay, but through the WebRTC audio processing compiled into the patched
// WebKit's libwebrtc, configured exactly as BrowsaCallAudioInternalUnit configures it. So replaying a unit
// dump (raw.wav + ref.wav from BROWSA_CALL_AUDIO_DUMP) with its recorded settings gives back its sent.wav,
// and other settings show what the call would have sounded like with them. No audio devices.
//
//   apm-replay-webkit --raw raw.wav --ref ref.wav --out sent.wav [--ref-shift-ms ms] [--agc 0|1]
//                     [--agc-max-db dB] [--agc-noise-dbfs dBFS] [--ns 0..3|off] [--no-aec] [--delay-hint-ms ms]
//
// Defaults are the unit's defaults (AGC on, 30 dB, -60 dBFS, noise suppression high, delay hint 10 ms).
// --ref-shift-ms moves the reference later (+) or earlier (-) against the mic, the same sense as the unit's
// BROWSA_CALL_AUDIO_REF_OFFSET_MS. Built by Spike/CallAudio/webkit/build-replay.sh.
#include <cmath>
#include <cstdlib>
#include <memory>
#include <string>
#include "wav.h"
#include <webrtc/api/audio/builtin_audio_processing_builder.h>
#include <webrtc/api/environment/environment_factory.h>
#include <webrtc/api/audio/audio_processing.h>

int main(int argc, char** argv) {
  std::string raw, ref, out;
  double shiftMs = 0, maxGain = 30, noiseDbfs = -60;
  int delayHint = 10, ns = 2;
  bool agc = true, aec = true;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
    if (a == "--raw") raw = next(); else if (a == "--ref") ref = next(); else if (a == "--out") out = next();
    else if (a == "--ref-shift-ms") shiftMs = atof(next().c_str());
    else if (a == "--agc") agc = atoi(next().c_str()) != 0;
    else if (a == "--agc-max-db") maxGain = atof(next().c_str());
    else if (a == "--agc-noise-dbfs") noiseDbfs = atof(next().c_str());
    else if (a == "--ns") { std::string v = next(); ns = v == "off" ? -1 : atoi(v.c_str()); }
    else if (a == "--no-aec") aec = false;
    else if (a == "--delay-hint-ms") delayHint = atoi(next().c_str());
    else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
  }
  std::vector<float> mic, reference;
  if (raw.empty() || ref.empty() || out.empty() || !readWav(raw.c_str(), mic) || !readWav(ref.c_str(), reference)) {
    fprintf(stderr, "usage: apm-replay-webkit --raw raw.wav --ref ref.wav --out sent.wav [options] (48 kHz WAVs)\n");
    return 2;
  }

  // As BrowsaCallAudioInternalUnit::initialize sets it up.
  webrtc::AudioProcessing::Config config;
  config.pipeline.maximum_internal_processing_rate = 48000;
  config.high_pass_filter.enabled = true;
  config.echo_canceller.enabled = aec;
  using Level = webrtc::AudioProcessing::Config::NoiseSuppression::Level;
  const Level levels[] = {Level::kLow, Level::kModerate, Level::kHigh, Level::kVeryHigh};
  config.noise_suppression.enabled = ns >= 0;
  config.noise_suppression.level = levels[ns < 0 ? 0 : ns > 3 ? 3 : ns];
  config.gain_controller2.enabled = agc;
  config.gain_controller2.adaptive_digital.enabled = agc;
  config.gain_controller2.adaptive_digital.max_gain_db = float(maxGain);
  config.gain_controller2.adaptive_digital.max_output_noise_level_dbfs = float(noiseDbfs);
  auto apm = webrtc::BuiltinAudioProcessingBuilder(config).Build(webrtc::CreateEnvironment());
  if (!apm) { fprintf(stderr, "no audio processing\n"); return 1; }

  const long shift = lround(shiftMs * 48);
  const size_t n = std::min(mic.size(), reference.size()) / 480 * 480;
  std::vector<float> sent(n);
  float frame[480], played[480];
  const webrtc::StreamConfig stream(48000, 1);
  for (size_t at = 0; at < n; at += 480) {
    for (int i = 0; i < 480; i++) {
      const long r = long(at) + i - shift;
      played[i] = r >= 0 && size_t(r) < reference.size() ? reference[r] : 0.f;
      frame[i] = mic[at + i];
    }
    float* p[1] = {played};
    float* f[1] = {frame};
    apm->ProcessReverseStream(p, stream, stream, p);
    apm->set_stream_delay_ms(delayHint);
    apm->ProcessStream(f, stream, stream, f);
    memcpy(sent.data() + at, frame, sizeof frame);
  }
  writeWav(out.c_str(), sent);
  // (No GetStatistics: WebKit's libwebrtc doesn't export AudioProcessingStats.)
  printf("{\"frames\": %zu}\n", n / 480);
  return 0;
}
