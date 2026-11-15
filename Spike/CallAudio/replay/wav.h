// 48 kHz mono WAV in and out for the replay tools (float or 16-bit in, float out).
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static inline bool readWav(const char* path, std::vector<float>& out) {
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
static inline void writeWav(const char* path, const std::vector<float>& x) {
  FILE* f = fopen(path, "wb");
  if (!f) return;
  const uint32_t data = uint32_t(x.size() * 4), rate = 48000, byteRate = rate * 4, riff = 36 + data, fmtLen = 16;
  const uint16_t tag = 3, ch = 1, align = 4, bits = 32;
  fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtLen, 4, 1, f);
  fwrite(&tag, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&byteRate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
  fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f); fwrite(x.data(), 4, x.size(), f);
  fclose(f);
}

