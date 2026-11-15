// Browsa call audio core: what happens after WebRTC's processing, before the call gets the audio.
// Portable C++, no audio APIs; used by the WebKit unit (as BrowsaCallGuard.h) and by apm-replay-webkit, so an
// offline replay of a call dump runs exactly what the call ran.
//
// Two things, both learned from the first real call (2026-11-16, MacBook mic and speakers):
//
// 1. Join warm-up. When a call starts, the echo canceller hasn't learned the room yet: for the first second or so
//    it removed only 20-27 dB of the other side's voice, and Meet heard that and decided we were in the same
//    room as them. While the far end is talking and the canceller hasn't yet shown it removes enough (35 dB over
//    the last 200 ms of far-end-only audio), what's sent is turned down 30 dB. Released as soon as it has; never
//    after the first 2 s; never while you are talking.
//
// 2. Gain only while you talk. WebRTC's adaptive gain lifted the quiet built-in mic about 14 dB, and the
//    canceller's leftovers with it: the brief leaks right after you stop talking (the canceller lets sound
//    through for ~300 ms after near-end speech) came out 14 dB louder. Here the gain follows your speech level
//    to about -26 dBFS but is only fully applied while you talk (and 300 ms after); otherwise it sits 12 dB lower.
//    "You talking" = the clean signal is well above the room, and the mic is clearly louder (6 dB) than the far
//    end's echo alone would make it, the echo level being the far end's level times a coupling learned from
//    far-end-only audio. WebRTC's own gain is off when this is on.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace browsa {

struct CallGuardOptions {
  bool warmup = true;
  double warmupAttenuationDb = 30, warmupMaxSeconds = 2, warmupConvergedDb = 35;
  bool gatedGain = true;
  double targetDbfs = -26, maxGainDb = 30, initialGainDb = 12, gateDepthDb = 12, holdSeconds = 0.3;
};

struct CallGuardStats {
  double warmupAttenuatedSeconds = 0;  // how long the warm-up held the far end's leak down
  double warmupReleasedAt = -1;        // seconds after start it released (converged), -1 if it never had to
  double gainDb = 0;                   // the gain while talking, at the end
  double couplingDb = 0;               // learned mic level of the far end's echo against the far end
  double nearSeconds = 0;              // time counted as you talking
};

class CallGuard {
 public:
  static constexpr int frameSize = 480;  // 10 ms at 48 kHz

  explicit CallGuard(const CallGuardOptions& o = CallGuardOptions()) : o_(o) { reset(); }
  void reset() {
    frames_ = 0; refEnv_ = -120; floor_ = -60; coupling_ = -6; level_ = o_.targetDbfs - o_.initialGainDb;
    gainDb_ = o_.initialGainDb; appliedDb_ = 0; holdFrames_ = 0; removalCount_ = 0; removalIndex_ = 0;
    converged_ = false; stats_ = CallGuardStats();
    for (double& r : removal_) r = 0;
    appliedDb_ = o_.gatedGain ? o_.initialGainDb - o_.gateDepthDb : 0;
  }
  // The last frame's state, for traces (apm-replay-webkit --trace).
  struct Frame { double ref, raw, clean, refEnv, floor, coupling, appliedDb; bool far, near, talking, attenuate; };
  Frame last() const { return last_; }
  const CallGuardStats& stats() const { stats_.gainDb = gainDb_; stats_.couplingDb = coupling_; return stats_; }

  // raw: the mic as the canceller got it; ref: the far end it was cancelled against; clean: WebRTC's output,
  // changed in place into what is sent. All 480 samples.
  void process(const float* raw, const float* ref, float* clean) {
    const double r = dB(raw_power(ref)), m = dB(raw_power(raw)), c = dB(raw_power(clean));
    const double t = frames_ * 0.01;
    frames_++;

    // The far end's level, held across its echo tail (falls 1.5 dB per 10 ms).
    refEnv_ = std::max(r, refEnv_ - 1.5);
    const bool far = refEnv_ > -50;
    // The room as sent: starts high (so nothing counts as speech before it has seen the room), follows quiet
    // frames down at once, creeps up slowly (2 dB/s).
    if (c > -100) floor_ = c < floor_ ? std::max(c, -90.0) : floor_ + 0.02;  // digital silence (a stream starting) says nothing about the room

    const double echoAtMic = refEnv_ + coupling_;
    const bool near = c > floor_ + 12 && (!far || m > echoAtMic + 6);
    if (near) { holdFrames_ = int(o_.holdSeconds * 100); stats_.nearSeconds += 0.01; }
    // The hold bridges your pauses, not the far end coming back: the canceller leaks for a moment right after you
    // stop, exactly when the other side starts again, so that is when the gain must not stay up.
    else if (far && r > -50) holdFrames_ = 0;
    else if (holdFrames_ > 0) holdFrames_--;
    const bool talking = near || holdFrames_ > 0;

    // Far end only: learn the coupling, and how much the canceller removes.
    if (far && !talking && r > -50) {
      const double k = m - refEnv_;
      if (k > -60 && k < 10) coupling_ += 0.02 * (k - coupling_);
      removal_[removalIndex_] = m - c;
      removalIndex_ = (removalIndex_ + 1) % kRemoval;
      removalCount_ = std::min(removalCount_ + 1, kRemoval);
    }

    double targetDb = 0;
    if (o_.gatedGain) {
      // Your speech level, from frames where you talk; the gain brings it to the target, slowly (3 dB/s).
      if (near && c > floor_ + 20 && c > level_ - 10) level_ += 0.01 * (c - level_);  // speech, not its quiet tails
      const double want = std::clamp(o_.targetDbfs - level_, 0.0, o_.maxGainDb);
      gainDb_ += std::clamp(want - gainDb_, -0.03, 0.03);
      targetDb = talking ? gainDb_ : gainDb_ - o_.gateDepthDb;
    }

    // Warm-up: hold the far end's leak down until the canceller removes enough.
    bool attenuate = false;
    if (o_.warmup && !converged_ && t < o_.warmupMaxSeconds && far && !talking) {
      double sum = 0;
      for (int i = 0; i < removalCount_; i++) sum += removal_[i];
      const bool enough = removalCount_ >= kRemoval && sum / removalCount_ >= o_.warmupConvergedDb;
      if (enough) { converged_ = true; stats_.warmupReleasedAt = t; }
      else { attenuate = true; stats_.warmupAttenuatedSeconds += 0.01; }
    }
    if (attenuate) targetDb -= o_.warmupAttenuationDb;
    last_ = { r, m, c, refEnv_, floor_, coupling_, targetDb, far, near, talking, attenuate };

    // Opening is immediate (so your first syllable isn't lost); closing is 1 dB per 10 ms. Ramped across the frame.
    const double from = appliedDb_;
    appliedDb_ = targetDb > appliedDb_ ? targetDb : std::max(targetDb, appliedDb_ - 1.0);
    const double g0 = std::pow(10.0, from / 20), g1 = std::pow(10.0, appliedDb_ / 20);
    float peak = 0;
    for (int i = 0; i < frameSize; i++) {
      clean[i] = float(clean[i] * (g0 + (g1 - g0) * (i + 1) / frameSize));
      peak = std::max(peak, std::fabs(clean[i]));
    }
    // Never past -1 dBFS.
    if (peak > 0.89f) { const float s = 0.89f / peak; for (int i = 0; i < frameSize; i++) clean[i] *= s; }
  }

 private:
  static double raw_power(const float* x) { double s = 0; for (int i = 0; i < frameSize; i++) s += double(x[i]) * x[i]; return s / frameSize; }
  static double dB(double p) { return 10 * std::log10(p + 1e-12); }
  static constexpr int kRemoval = 20;  // 200 ms of far-end-only frames

  CallGuardOptions o_;
  mutable CallGuardStats stats_;
  int64_t frames_ = 0;
  double refEnv_ = -120, floor_ = -90, coupling_ = -6, level_ = -38, gainDb_ = 12, appliedDb_ = 0;
  int holdFrames_ = 0, removalCount_ = 0, removalIndex_ = 0;
  double removal_[kRemoval] = {};
  bool converged_ = false;
  Frame last_ = {};
};

}  // namespace browsa
