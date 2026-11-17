// Checks the timing core against two simulated devices whose clocks drift apart.
//   c++ -std=c++17 -O2 -I ../core timeline_test.cc -o /tmp/timeline_test && /tmp/timeline_test
#include "AudioTimeline.h"
#include <cstdio>
#include <random>
using namespace browsa;

// What the "speakers" play: a slow chirp, known at every instant.
static double signalAt(double speakerSeconds) { return std::sin(2 * M_PI * (300 * speakerSeconds + 12 * speakerSeconds * speakerSeconds)); }

static double run(double outPpm, double micPpm, double jitter, double seconds, bool restart) {
  const double outRate = 48000 * (1 + outPpm * 1e-6), micRate = 48000 * (1 + micPpm * 1e-6);
  std::mt19937 rng(7); std::normal_distribution<double> noise(0, jitter);
  ClockModel outClock(48000), micClock(48000); SampleRing ring; SteeredReader reader;
  const int outBuf = 512, micBuf = 480;
  double outN = 0, micN = 0, outT0 = 0.0, worst = 0, sumSq = 0; long count = 0;
  std::vector<float> block(outBuf), ref(480);
  double tOutNext = 0, tMicNext = 0.05;
  while (tMicNext < seconds) {
    if (tOutNext <= tMicNext + 0.03) {                 // speakers run a little ahead, like a real output buffer
      if (restart && outN >= 48000.0 * 20 && outN < 48000.0 * 20 + outBuf) outT0 += 0.137;   // device hiccup at 20 s
      for (int i = 0; i < outBuf; i++) block[i] = float(signalAt(outT0 + (outN + i) / outRate));
      outClock.update(outN, outT0 + outN / outRate + noise(rng));
      ring.write(block.data(), outBuf); outN += outBuf; tOutNext = outT0 + outN / outRate - 0.03;
    } else {
      const double t0 = micN / micRate + 0.05, t1 = (micN + micBuf) / micRate + 0.05;
      micClock.update(micN, t0 + noise(rng));
      const double a = micClock.timeOf(micN), b = micClock.timeOf(micN + micBuf);
      reader.read(ring, ref.data(), 480, outClock.indexAt(a), outClock.indexAt(b), 240);
      if (t0 > 5 && !(restart && t0 > 19.9 && t0 < 21)) for (int i = 0; i < 480; i++) {
        const double want = signalAt(t0 + i / micRate), e = ref[i] - want;
        sumSq += e * e; count++; if (std::fabs(e) > worst) worst = std::fabs(e);
      }
      micN += micBuf; tMicNext = t1;
    }
  }
  const double rms = std::sqrt(sumSq / count);
  printf("out %+5.0f ppm, mic %+5.0f ppm, jitter %3.0f us%s: error rms %.1f dB, worst %.1f dB, resyncs %d, misses %d, drift seen %+.1f ppm\n",
         outPpm, micPpm, jitter * 1e6, restart ? ", restart" : "", 20 * std::log10(rms + 1e-12), 20 * std::log10(worst + 1e-12), reader.resyncs, reader.misses,
         (outClock.rate() / micClock.rate() - 1) * 1e6);
  return rms;
}

int main() {
  bool ok = true;
  ok &= run(0, 0, 0, 60, false) < 0.003;
  ok &= run(100, -50, 20e-6, 120, false) < 0.02;
  ok &= run(-300, 200, 50e-6, 120, false) < 0.05;
  ok &= run(80, -40, 20e-6, 60, true) < 0.05;
  printf(ok ? "PASS\n" : "FAIL\n");
  return ok ? 0 : 1;
}
