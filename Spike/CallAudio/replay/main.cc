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

static bool readWav(const char* path, std::vector<float>& out) {
  FILE* f = fopen(path, "rb");
  if (!f) return false;
  char id[4]; uint32_t len; uint16_t tag = 0, ch = 0, bits = 0; uint32_t rate = 0;
  if (fread(id, 1, 4, f) != 4 || memcmp(id, "RIFF", 4)) { fclose(f); return false; }
  fseek(f, 8, SEEK_CUR);
  while (fread(id, 1, 4, f) == 4 && fread(&len, 4, 1, f) == 1) {
    if (!memcmp(id, "fmt ", 4)) {
      fread(&tag, 2, 1, f); fread(&ch, 2, 1, f); fread(&rate, 4, 1, f); fseek(f, 6, SEEK_CUR); fread(&bits, 2, 1, f);
      fseek(f, len - 16, SEEK_CUR);
    } else if (!memcmp(id, "data", 4)) {
      const int bytes = bits / 8; const size_t frames = len / (bytes * ch);
      out.resize(frames);
      std::vector<char> buf(len);
      fread(buf.data(), 1, len, f);
      for (size_t i = 0; i < frames; i++) {
        const char* p = buf.data() + i * bytes * ch;
        out[i] = (tag == 3 || tag == 0xfffe) && bits == 32 ? *reinterpret_cast<const float*>(p) : bits == 16 ? *reinterpret_cast<const int16_t*>(p) / 32768.f : 0.f;
      }
      fclose(f);
      return rate == 48000;
    } else fseek(f, len + (len & 1), SEEK_CUR);
  }
  fclose(f);
  return false;
}
static void writeWav(const char* path, const std::vector<float>& x) {
  FILE* f = fopen(path, "wb");
  if (!f) return;
  const uint32_t data = uint32_t(x.size() * 4), rate = 48000, byteRate = rate * 4, riff = 36 + data, fmtLen = 16;
  const uint16_t tag = 3, ch = 1, align = 4, bits = 32;
  fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtLen, 4, 1, f);
  fwrite(&tag, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&byteRate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
  fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f); fwrite(x.data(), 4, x.size(), f);
  fclose(f);
}

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
