// Browsa call audio core: the timing half. Portable C++, no audio APIs.
//
// An echo canceller only works when it is told exactly what the speakers played, lined up against
// what the microphone heard. Speakers and microphone are usually two devices with two clocks
// (a Scarlett interface and USB speakers drift apart by tens of samples a minute), so "the same
// number of samples" is not "the same moment". Everything here works in host time instead:
// every buffer either device hands over carries the host clock time it meets the air, and the
// reference is read back at the moments the microphone frame covers, resampled to hide the drift.
#pragma once
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace browsa {

struct SpinLock {
  std::atomic_flag f = ATOMIC_FLAG_INIT;
  void lock() { while (f.test_and_set(std::memory_order_acquire)) {} }
  void unlock() { f.clear(std::memory_order_release); }
};

// Sample index <-> host time (seconds) for one device stream, learned from the (index, time) pair
// each audio callback reports. The rate comes from a long baseline (up to 20 s) so it is steady to a
// few parts per million; the offset follows the newest callbacks.
class ClockModel {
 public:
  explicit ClockModel(double nominalRate = 48000) { reset(nominalRate); }
  void reset(double nominalRate) {
    lock_.lock();
    nominal_ = rate_ = nominalRate; count_ = 0; updates_ = 0; head_ = 0; valid_ = false; lastPoint_ = -1e18; resets_ = 0;
    lock_.unlock();
  }
  // `index`: position of a buffer's first sample; `t`: host time that sample is played or was captured.
  void update(double index, double t) {
    lock_.lock();
    if (!valid_) { n_ = index; t_ = t; valid_ = true; push(index, t); lock_.unlock(); return; }
    const double predicted = t_ + (index - n_) / rate_;
    const double e = t - predicted;
    if (std::fabs(e) > 0.02) {              // the device stopped, restarted or skipped: start again
      count_ = 0; head_ = 0; updates_ = 0; rate_ = nominal_; n_ = index; t_ = t; lastPoint_ = -1e18; resets_++;
      push(index, t); lock_.unlock(); return;
    }
    // A running average at first, then a slow follower: callback timestamps jitter by a sample or so,
    // and the echo canceller wants a reference that doesn't wobble.
    updates_++;
    const double a = updates_ < 100 ? 1.0 / (updates_ + 1) : 0.01;
    n_ = index; t_ = predicted + a * e;
    if (t - lastPoint_ >= 0.2) {
      push(index, t);
      const Point& oldest = pts_[(head_ + kPoints - count_) % kPoints];
      if (t - oldest.t >= 2.0) {
        const double r = (index - oldest.n) / (t - oldest.t);
        if (std::fabs(r / nominal_ - 1) < 0.01) rate_ = r;   // real devices are within 0.1%; ignore nonsense
      }
    }
    lock_.unlock();
  }
  bool valid() const { lock_.lock(); bool v = valid_; lock_.unlock(); return v; }
  double timeOf(double index) const { lock_.lock(); double r = t_ + (index - n_) / rate_; lock_.unlock(); return r; }
  double indexAt(double t) const { lock_.lock(); double r = n_ + (t - t_) * rate_; lock_.unlock(); return r; }
  double rate() const { lock_.lock(); double r = rate_; lock_.unlock(); return r; }
  int resets() const { lock_.lock(); int r = resets_; lock_.unlock(); return r; }

 private:
  struct Point { double n, t; };
  static constexpr int kPoints = 100;
  void push(double n, double t) { pts_[head_] = {n, t}; head_ = (head_ + 1) % kPoints; if (count_ < kPoints) count_++; lastPoint_ = t; }
  mutable SpinLock lock_;
  Point pts_[kPoints];
  int head_ = 0, count_ = 0, resets_ = 0, updates_ = 0;
  bool valid_ = false;
  double nominal_ = 48000, rate_ = 48000, n_ = 0, t_ = 0, lastPoint_ = -1e18;
};

// Mono samples addressed by an ever-growing index. One writer thread, one reader thread.
class SampleRing {
 public:
  explicit SampleRing(size_t pow2 = 1 << 18) : buf_(pow2, 0.f), mask_(pow2 - 1) {}
  void write(const float* s, size_t n) {
    uint64_t w = written_.load(std::memory_order_relaxed);
    for (size_t i = 0; i < n; i++) buf_[(w + i) & mask_] = s[i];
    written_.store(w + n, std::memory_order_release);
  }
  uint64_t written() const { return written_.load(std::memory_order_acquire); }
  size_t capacity() const { return buf_.size(); }
  // The sample at a fractional position (4-point Hermite). False when it isn't in the ring (yet, or any more).
  bool at(double pos, float* out) const {
    const uint64_t w = written();
    const double lo = w > buf_.size() - 4 ? double(w - buf_.size() + 4) : 1.0;
    if (pos < lo || pos + 2 >= double(w)) { *out = 0; return false; }
    const uint64_t i = uint64_t(pos);
    const float f = float(pos - double(i));
    const float y0 = buf_[(i - 1) & mask_], y1 = buf_[i & mask_], y2 = buf_[(i + 1) & mask_], y3 = buf_[(i + 2) & mask_];
    const float c1 = 0.5f * (y2 - y0), c2 = y0 - 2.5f * y1 + 2 * y2 - 0.5f * y3, c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
    *out = ((c3 * f + c2) * f + c1) * f + y1;
    return true;
  }
 private:
  std::vector<float> buf_;
  size_t mask_;
  std::atomic<uint64_t> written_{0};
};

// Reads a ring along a moving target position without clicks: small errors are steered out by
// playing up to 0.5% fast or slow, large ones (a device restarted) by jumping.
class SteeredReader {
 public:
  int resyncs = 0, misses = 0;
  // Fills `n` samples covering ring positions [targetStart, targetEnd). `jump`: how far off (in ring
  // samples) before giving up on steering.
  void read(const SampleRing& ring, float* out, int n, double targetStart, double targetEnd, double jump) {
    const double nominal = (targetEnd - targetStart) / n;
    if (!started_ || std::fabs(targetStart - pos_) > jump) { pos_ = targetStart; if (started_) resyncs++; started_ = true; }
    double step = (targetEnd - pos_) / n;
    const double lo = nominal * 0.995, hi = nominal * 1.005;
    step = step < lo ? lo : step > hi ? hi : step;
    bool ok = true;
    for (int i = 0; i < n; i++) { ok &= ring.at(pos_, &out[i]); pos_ += step; }
    if (!ok) misses++;
  }
  double position() const { return pos_; }
 private:
  bool started_ = false;
  double pos_ = 0;
};

}  // namespace browsa
