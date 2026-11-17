// apm-replay: runs a recorded call through WebRTC's audio processing again, offline, with chosen settings.
// No audio devices. Input: a Browsa Audio Lab run's raw.wav (the mic, 48 kHz mono, already lined up in 10 ms
// frames) and ref.wav (exactly the reference each frame was cancelled against). Output: sent.wav.
//
//   apm-replay --raw raw.wav --ref ref.wav --out sent.wav [--no-aec] [--no-ns] [--ns 0..3] [--gain]
//              [--gain-speed dB/s] [--gain-noise dBFS] [--ref-shift-ms ms] [--delay-hint-ms ms]
//
// --ref-shift-ms moves the reference later (+) or earlier (-) against the mic, to test how sensitive the
// canceller is to the reference lead.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include "Apm.h"
#include "wav.h"

int main(int argc, char** argv) {
  std::string raw, ref, out;
  browsa::ApmOptions o;
  double shiftMs = 0; int delayHint = 10;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
    if (a == "--raw") raw = next(); else if (a == "--ref") ref = next(); else if (a == "--out") out = next();
    else if (a == "--no-aec") o.echo = false; else if (a == "--no-ns") o.noise = false; else if (a == "--ns") o.noiseLevel = atoi(next().c_str());
    else if (a == "--gain") o.gain = true; else if (a == "--gain-speed") o.gainMaxChangeDbPerSecond = atof(next().c_str());
    else if (a == "--gain-noise") o.gainMaxNoiseDbfs = atof(next().c_str());
    else if (a == "--ref-shift-ms") shiftMs = atof(next().c_str()); else if (a == "--delay-hint-ms") delayHint = atoi(next().c_str());
    else { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
  }
  std::vector<float> mic, reference;
  if (raw.empty() || ref.empty() || out.empty() || !readWav(raw.c_str(), mic) || !readWav(ref.c_str(), reference)) {
    fprintf(stderr, "usage: apm-replay --raw raw.wav --ref ref.wav --out sent.wav [options] (48 kHz WAVs)\n");
    return 2;
  }
  const long shift = lround(shiftMs * 48);
  std::unique_ptr<browsa::Apm> apm(browsa::Apm::create(o));
  const size_t n = std::min(mic.size(), reference.size()) / 480 * 480;
  std::vector<float> sent(n);
  float frame[480], played[480];
  for (size_t at = 0; at < n; at += 480) {
    for (int i = 0; i < 480; i++) {
      const long r = long(at) + i - shift;
      played[i] = r >= 0 && size_t(r) < reference.size() ? reference[r] : 0.f;
      frame[i] = mic[at + i];
    }
    apm->played(played);
    apm->process(frame, delayHint);
    memcpy(sent.data() + at, frame, sizeof frame);
  }
  writeWav(out.c_str(), sent);
  const auto st = apm->stats();
  printf("{\"frames\": %zu, \"erle\": %.2f, \"delayMs\": %.0f}\n", n / 480, st.erle, st.delayMs);
  return 0;
}
