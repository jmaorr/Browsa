// apm-replay-webkit: the same as apm-replay, but through the WebRTC audio processing compiled into the patched
// WebKit's libwebrtc, configured exactly as BrowsaCallAudioInternalUnit configures it. So replaying a unit
// dump (raw.wav + ref.wav from BROWSA_CALL_AUDIO_DUMP) with its recorded settings gives back its sent.wav,
// and other settings show what the call would have sounded like with them. No audio devices.
//
//   apm-replay-webkit --raw raw.wav --ref ref.wav --out sent.wav [--ref-shift-ms ms] [--agc 0|1]
//                     [--agc-max-db dB] [--agc-noise-dbfs dBFS] [--ns 0..3|off] [--no-aec] [--delay-hint-ms ms]
//                     [--warmup 0|1] [--gated-gain 0|1]
//
// --warmup / --gated-gain run Browsa's stage after WebRTC (core/CallGuard.h, the same code the unit runs); gated gain
// turns WebRTC's own auto gain off. Both default off here, so plain replays stay comparable with older dumps.
//
// Defaults are the unit's defaults (AGC on, 30 dB, -60 dBFS, noise suppression high, delay hint 10 ms).
// --ref-shift-ms moves the reference later (+) or earlier (-) against the mic, the same sense as the unit's
// BROWSA_CALL_AUDIO_REF_OFFSET_MS. Built by Spike/CallAudio/webkit/build-replay.sh.
//
// BROWSA_AEC3_TRIALS (environment): WebRTC field trials for the echo canceller, in WebRTC's own format
// ("WebRTC-Aec3SuppressorNearendLfMaskTransparentOverride/0.4/WebRTC-Aec3...Override/50/"), applied the way AEC3
// applies them (echo_canceller3.cc, AdjustConfig): a way to try its settings without exporting its config from
// WebKit's libwebrtc.
#include <cmath>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>
#include "wav.h"
#include "CallGuard.h"
#include <webrtc/api/audio/builtin_audio_processing_builder.h>
#include <webrtc/api/environment/environment_factory.h>
#include <webrtc/api/audio/audio_processing.h>
#include <webrtc/api/field_trials_view.h>
#include <map>

// FieldTrialsView's default CreateCopy (inline, never called here) refers to this, which libwebrtc doesn't export.
namespace webrtc::webrtc_checks_impl { void UnreachableCodeReached(const char*, int) { abort(); } }

// Field trials from a "Key/Value/Key/Value/" string.
class Trials final : public webrtc::FieldTrialsView {
 public:
  explicit Trials(const char* text) {
    std::vector<std::string> parts;
    std::string cur;
    for (const char* c = text ? text : ""; *c; ++c) { if (*c == '/') { parts.push_back(cur); cur.clear(); } else cur += *c; }
    if (!cur.empty()) parts.push_back(cur);
    for (size_t i = 0; i + 1 < parts.size(); i += 2) values_[parts[i]] = parts[i + 1];
  }
  std::string Lookup(absl::string_view key) const override {
    auto it = values_.find(std::string(key));
    return it == values_.end() ? std::string() : it->second;
  }
  size_t size() const { return values_.size(); }
 private:
  std::map<std::string, std::string> values_;
};

int main(int argc, char** argv) {
  std::string raw, ref, out, trace;
  std::vector<std::string> guardSets;
  double shiftMs = 0, maxGain = 30, noiseDbfs = -60;
  int delayHint = 10, ns = 2;
  bool agc = true, aec = true, warmup = false, gatedGain = false;
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
    else if (a == "--warmup") warmup = atoi(next().c_str()) != 0;
    else if (a == "--gated-gain") gatedGain = atoi(next().c_str()) != 0;
    else if (a == "--trace") trace = next();
    else if (a == "--guard") guardSets.push_back(next());  // name=value, a CallGuardOptions field (tuning)
    else if (a == "--delay-hint-ms") delayHint = atoi(next().c_str());
    else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
  }
  std::vector<float> mic, reference;
  if (raw.empty() || ref.empty() || out.empty() || !readWav(raw.c_str(), mic) || !readWav(ref.c_str(), reference)) {
    fprintf(stderr, "usage: apm-replay-webkit --raw raw.wav --ref ref.wav --out sent.wav [options] (48 kHz WAVs)\n");
    return 2;
  }

  if (gatedGain) agc = false;
  browsa::CallGuardOptions go;
  go.warmup = warmup;
  go.gatedGain = gatedGain;
  for (const auto& kv : guardSets) {
    const auto eq = kv.find('=');
    if (eq == std::string::npos) { fprintf(stderr, "--guard name=value\n"); return 2; }
    const std::string k = kv.substr(0, eq); const double v = atof(kv.c_str() + eq + 1);
    double* f = k == "targetDbfs" ? &go.targetDbfs : k == "maxGainDb" ? &go.maxGainDb : k == "minGainDb" ? &go.minGainDb
      : k == "initialGainDb" ? &go.initialGainDb : k == "initialLevelDbfs" ? &go.initialLevelDbfs : k == "levelWindowDb" ? &go.levelWindowDb : k == "holdSeconds" ? &go.holdSeconds : k == "farGateDepthDb" ? &go.farGateDepthDb
      : k == "farReleaseDbPerFrame" ? &go.farReleaseDbPerFrame : k == "pauseGateDepthDb" ? &go.pauseGateDepthDb
      : k == "pauseReleaseDbPerFrame" ? &go.pauseReleaseDbPerFrame : k == "fastSpeechSeconds" ? &go.fastSpeechSeconds
      : k == "fastUpDbPerFrame" ? &go.fastUpDbPerFrame : k == "fastDownDbPerFrame" ? &go.fastDownDbPerFrame : k == "slowUpDbPerFrame" ? &go.slowUpDbPerFrame
      : k == "slowDownDbPerFrame" ? &go.slowDownDbPerFrame : nullptr;
    if (!f) { fprintf(stderr, "unknown guard option %s\n", k.c_str()); return 2; }
    *f = v;
  }
  browsa::CallGuard guard(go);
  const bool guarding = warmup || gatedGain;
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
  static Trials trials(getenv("BROWSA_AEC3_TRIALS"));
  if (trials.size()) fprintf(stderr, "AEC3 field trials: %zu\n", trials.size());
  auto apm = webrtc::BuiltinAudioProcessingBuilder(config).Build(trials.size() ? webrtc::CreateEnvironment(&trials) : webrtc::CreateEnvironment());
  if (!apm) { fprintf(stderr, "no audio processing\n"); return 1; }

  FILE* tr = trace.empty() ? nullptr : fopen(trace.c_str(), "w");
  if (tr) fprintf(tr, "t,ref,raw,clean,refEnv,floor,coupling,targetDb,far,near,talking,attenuate\n");
  const long shift = lround(shiftMs * 48);
  const size_t n = std::min(mic.size(), reference.size()) / 480 * 480;
  std::vector<float> sent(n);
  float frame[480], played[480], rawFrame[480], refFrame[480];
  const webrtc::StreamConfig stream(48000, 1);
  for (size_t at = 0; at < n; at += 480) {
    for (int i = 0; i < 480; i++) {
      const long r = long(at) + i - shift;
      played[i] = r >= 0 && size_t(r) < reference.size() ? reference[r] : 0.f;
      frame[i] = mic[at + i];
    }
    memcpy(rawFrame, frame, sizeof rawFrame);
    memcpy(refFrame, played, sizeof refFrame);
    float* p[1] = {played};
    float* f[1] = {frame};
    apm->ProcessReverseStream(p, stream, stream, p);
    apm->set_stream_delay_ms(delayHint);
    apm->ProcessStream(f, stream, stream, f);
    if (guarding) {
      guard.process(rawFrame, refFrame, frame);
      if (tr) { const auto f = guard.last(); fprintf(tr, "%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d,%d,%d,%d\n", at / 48000.0, f.ref, f.raw, f.clean, f.refEnv, f.floor, f.coupling, f.appliedDb, f.far, f.near, f.talking, f.attenuate); }
    }
    memcpy(sent.data() + at, frame, sizeof frame);
  }
  if (tr) fclose(tr);
  writeWav(out.c_str(), sent);
  // (No GetStatistics: WebKit's libwebrtc doesn't export AudioProcessingStats.)
  const auto gs = guard.stats();
  printf("{\"frames\": %zu, \"warmupAttenuatedSeconds\": %.2f, \"warmupReleasedAt\": %.2f, \"gainDb\": %.1f, \"couplingDb\": %.1f, \"nearSeconds\": %.1f}\n",
         n / 480, gs.warmupAttenuatedSeconds, gs.warmupReleasedAt, gs.gainDb, gs.couplingDb, gs.nearSeconds);
  return 0;
}
