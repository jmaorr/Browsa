// Offline check of BrowsaSideSpeakers.h: a page's chosen speaker (its own clock, its own buffer size)
// writes what it plays; the engine reads it back at the moments its microphone frames cover, the way
// BrowsaCallAudioInternalUnit::addSideSpeakers does. Nothing is played or recorded.
//   clang++ -std=c++20 -O2 -I.. -I../../core tests/side-speakers-test.cpp -framework CoreAudio -framework AudioToolbox -o /tmp/side && /tmp/side
// (run from Spike/CallAudio/webkit; BrowsaAudioTimeline.h is ../core/AudioTimeline.h in the WebKit tree)
#define PLATFORM(X) 1
#define WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
#define WTF_ALLOW_UNSAFE_BUFFER_USAGE_END
#include <cmath>
#include <cstdio>
#include <random>
#include <string>
#include <vector>
#include "BrowsaSideSpeakers.h"

static int failures = 0;
static void check(bool ok, const char* what)
{
    std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok)
        failures++;
}

// A signal defined at any moment (host seconds): a few tones plus band-limited noise, like speech-ish audio.
struct Signal {
    std::vector<double> f, a, p;
    Signal()
    {
        std::mt19937 rng(7);
        std::uniform_real_distribution<double> freq(80, 3500), amp(0.02, 0.1), phase(0, 6.283);
        for (int i = 0; i < 40; i++) { f.push_back(freq(rng)); a.push_back(amp(rng)); p.push_back(phase(rng)); }
    }
    double at(double t) const
    {
        double s = 0;
        for (size_t i = 0; i < f.size(); i++)
            s += a[i] * std::sin(6.283185307179586 * f[i] * t + p[i]);
        return s;
    }
};

static uint64_t ticks(double seconds)
{
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return static_cast<uint64_t>(seconds * 1e9 * tb.denom / tb.numer);
}

struct Result { double errorDb; int resyncs, misses; uint64_t frames; };

// For an echo check with WebRTC's canceller (apm-replay-webkit): the microphone hearing the chosen speaker
// through a room, the reference as the engine builds it, and the exact one.
struct Wavs { std::vector<float> raw, ref, ideal; };
static void writeWav(const std::string& path, const std::vector<float>& x)
{
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f)
        return;
    auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
    std::fwrite("RIFF", 1, 4, f); u32(36 + x.size() * 4); std::fwrite("WAVEfmt ", 1, 8, f);
    u32(16); u16(3); u16(1); u32(48000); u32(48000 * 4); u16(4); u16(32);
    std::fwrite("data", 1, 4, f); u32(x.size() * 4); std::fwrite(x.data(), 4, x.size(), f);
    std::fclose(f);
}

// side: the chosen speaker's true rate, buffer size and timestamp jitter. Reads 10 ms frames on a microphone
// clock running at micRate for `seconds`, and compares with the signal at the moments asked for.
static Result run(double sideRate, int sideBuffer, double jitter, double micRate, double seconds, bool stereoInterleaved, Wavs* wavs = nullptr)
{
    static int instance = 0;
    auto& side = browsa::SideSpeakers::shared();
    const void* owner = &instance; instance++;
    side.setListening(true);
    side.claim(owner, 0xFFFFFF, 48000); // no such device: latency 0, so the stamp is the moment in the air
    Signal x;
    std::mt19937 rng(11);
    std::uniform_real_distribution<double> wobble(-jitter, jitter);
    const double t0 = 1000.0 + instance * 100.0;
    double written = t0; // air time of the next sample the speaker plays
    AudioStreamBasicDescription format { };
    format.mSampleRate = 48000;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | (stereoInterleaved ? 0 : kAudioFormatFlagIsNonInterleaved);
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = stereoInterleaved ? 2 : 1;
    std::vector<float> buffer(sideBuffer * 2);

    browsa::SteeredReader reader;
    const int frameSize = 480;
    const double lead = 0.010;
    double sumErr = 0, sumSig = 0;
    uint64_t frames = 0;
    for (double start = t0 + 0.2; start < t0 + seconds; start += frameSize / micRate) {
        const double end = start + frameSize / micRate;
        while (written < end + lead + 0.05) { // the speaker is ahead of the microphone, as on a real Mac
            for (int i = 0; i < sideBuffer; i++) {
                float v = static_cast<float>(x.at(written + i / sideRate));
                if (stereoInterleaved) { buffer[2 * i] = v; buffer[2 * i + 1] = v; } else buffer[i] = v;
            }
            AudioBufferList list;
            list.mNumberBuffers = 1;
            list.mBuffers[0] = { format.mChannelsPerFrame, static_cast<UInt32>(sideBuffer * format.mChannelsPerFrame * sizeof(float)), buffer.data() };
            AudioTimeStamp stamp { };
            stamp.mHostTime = ticks(written + wobble(rng));
            stamp.mFlags = kAudioTimeStampHostTimeValid;
            if (side.owns(owner))
                side.write(list, format, stamp, sideBuffer, false);
            written += sideBuffer / sideRate;
        }
        if (!side.playedAround(start))
            continue;
        float got[frameSize];
        const auto& clock = side.clock();
        reader.read(side.ring(), got, frameSize, clock.indexAt(start + lead), clock.indexAt(end + lead), 0.005 * clock.rate());
        frames++;
        if (wavs) {
            for (int i = 0; i < frameSize; i++) {
                const double t = start + i * (end - start) / frameSize;
                // Speech-like: the far end talks in 1.5 s bursts with pauses. A room: direct sound and two reflections.
                auto far = [&](double u) { return std::fmod(u - t0, 2.5) < 1.5 ? x.at(u) : 0.0; };
                wavs->raw.push_back(static_cast<float>(0.5 * far(t - 0.004) + 0.25 * far(t - 0.009) + 0.1 * far(t - 0.023)));
                // The far end's gaps are in the reference too.
                wavs->ref.push_back(std::fmod(t + lead - t0, 2.5) < 1.5 ? got[i] : 0.f);
                wavs->ideal.push_back(static_cast<float>(far(t + lead)));
            }
        }
        if (start < t0 + 10) // the clock settles
            continue;
        for (int i = 0; i < frameSize; i++) {
            const double want = x.at(start + lead + i * (end - start) / frameSize);
            sumErr += (got[i] - want) * (got[i] - want);
            sumSig += want * want;
        }
    }
    side.release(owner);
    return { 10 * std::log10(sumErr / sumSig + 1e-20), reader.resyncs, reader.misses, frames };
}

int main(int argc, char** argv)
{
    auto& side = browsa::SideSpeakers::shared();

    // Ownership: one renderer at a time; writes count only while the engine listens.
    int a = 0, b = 0;
    side.setListening(false);
    check(side.claim(&a, 0xFFFFFF, 48000), "first renderer claims the side speaker");
    check(!side.claim(&b, 0xFFFFFF, 48000), "a second renderer is turned away");
    check(!side.owns(&a), "nothing is written while the engine isn't running");
    side.setListening(true);
    check(side.owns(&a) && !side.owns(&b), "the first renderer writes once the engine runs");
    side.release(&b);
    check(side.owns(&a), "a renderer that never claimed can't release it");
    side.release(&a);
    check(side.claim(&b, 0xFFFFFF, 48000), "released: the next renderer can claim it");
    side.release(&b);

    struct Case { const char* name; double sideRate; int buffer; double jitter; double micRate; bool stereo; };
    const Case cases[] = {
        { "same clock, 512-sample buffers", 48000, 512, 0, 48000, false },
        { "speaker 120 ppm fast, mic 80 ppm slow, 20 us jitter", 48000 * 1.00012, 512, 20e-6, 48000 * 0.99992, false },
        { "USB speaker style: 480-sample buffers, stereo interleaved, 50 us jitter", 48000 * 0.99985, 480, 50e-6, 48000 * 1.00005, true },
        { "Bluetooth style: 1024-sample buffers, 200 ppm apart", 48000 * 1.0001, 1024, 30e-6, 48000 * 0.9999, false },
    };
    for (auto& c : cases) {
        auto r = run(c.sideRate, c.buffer, c.jitter, c.micRate, 60, c.stereo);
        std::printf("      %s: reference error %.1f dB below the signal, %llu frames, %d resyncs, %d misses\n", c.name, -r.errorDb, (unsigned long long)r.frames, r.resyncs, r.misses);
        // AEC3 needs the reference to match what played closely; -30 dB error leaves the canceller plenty.
        // Once settled, timing to a few microseconds: the same accuracy as the engine's own speakers (the same code).
        check(r.errorDb < -25, c.name);
        check(r.resyncs == 0 && r.misses == 0, "  no jumps or gaps");
    }

    // Stale: once the speaker stops, the engine stops adding it (after a second).
    {
        int c = 0;
        side.claim(&c, 0xFFFFFF, 48000);
        std::vector<float> buf(480, 0.1f);
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0] = { 1, 480 * sizeof(float), buf.data() };
        AudioStreamBasicDescription format { };
        format.mSampleRate = 48000; format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved; format.mBitsPerChannel = 32; format.mChannelsPerFrame = 1;
        for (int i = 0; i < 100; i++) {
            AudioTimeStamp stamp { };
            stamp.mHostTime = ticks(5000 + i * 0.01);
            stamp.mFlags = kAudioTimeStampHostTimeValid;
            side.write(list, format, stamp, 480, false);
        }
        check(side.playedAround(5001.0), "playing: the engine adds it");
        check(!side.playedAround(5003.0), "stopped for over a second: the engine leaves it out");
        side.release(&c);
    }

    // Echo check: argv[1] = folder for raw.wav (microphone), ref.wav (as the engine builds it), ideal.wav, none.wav.
    if (argc > 1) {
        Wavs w;
        run(48000 * 1.00012, 512, 20e-6, 48000 * 0.99992, 60, true, &w);
        const std::string dir = argv[1];
        writeWav(dir + "/raw.wav", w.raw);
        writeWav(dir + "/ref.wav", w.ref);
        writeWav(dir + "/ideal.wav", w.ideal);
        writeWav(dir + "/none.wav", std::vector<float>(w.raw.size(), 0.f));
        std::printf("wrote %s/{raw,ref,ideal,none}.wav (%zu samples)\n", dir.c_str(), w.raw.size());
    }

    std::printf("%s\n", failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
