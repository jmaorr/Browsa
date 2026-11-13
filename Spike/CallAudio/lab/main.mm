// Browsa Audio Lab: measures echo on real speakers and a real microphone.
//
// Plays a recording of someone talking (the far end of a call) through the speakers, listens on the
// microphone, and reports how much of the recording comes back after processing, with the same
// yardstick as tools/echo-test: level while the far end talks against the room's quiet level.
// Under 3 dB is good; over 10 dB, the other side hears themselves.
//
//   --mode webrtc   Browsa's core: WebRTC processing on the real device clocks (the default)
//   --mode apple    Apple's voice processing unit, as WebKit and Safari use it
//   --mode raw      no processing: how loud the echo is in the room
//   --far <file>    the far-end recording (any format Core Audio reads)
//   --seconds <n>   how long the far end talks (45)
//   --out-dir <dir> where report.txt, report.json and recording.wav go
//   --in <name> --out <name>   devices by name; default: the system's
//   --gain          WebRTC automatic gain on;  --no-ns   noise suppression off
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <cmath>
#include <string>
#include <vector>
#include "CallAudioCore.h"

using namespace browsa;
static const int kRate = 48000;

static std::vector<float> loadMono48k(NSString* path) {
  std::vector<float> out;
  ExtAudioFileRef f = nullptr;
  if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &f) != noErr) return out;
  AudioStreamBasicDescription fmt = {};
  fmt.mSampleRate = kRate; fmt.mFormatID = kAudioFormatLinearPCM; fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  fmt.mBitsPerChannel = 32; fmt.mChannelsPerFrame = 1; fmt.mFramesPerPacket = 1; fmt.mBytesPerFrame = fmt.mBytesPerPacket = 4;
  ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof fmt, &fmt);
  float buf[4096];
  for (;;) {
    AudioBufferList abl; abl.mNumberBuffers = 1; abl.mBuffers[0] = {1, sizeof buf, buf};
    UInt32 n = 4096;
    if (ExtAudioFileRead(f, &n, &abl) != noErr || n == 0) break;
    out.insert(out.end(), buf, buf + n);
  }
  ExtAudioFileDispose(f);
  return out;
}

static double db(double power) { return 10 * log10(power + 1e-12); }
static double power(const std::vector<float>& x, size_t a, size_t b) {
  if (b > x.size()) b = x.size();
  if (a >= b) return 0;
  double s = 0; for (size_t i = a; i < b; i++) s += double(x[i]) * x[i];
  return s / double(b - a);
}

static void writeWav(NSString* path, const std::vector<float>* ch[], int channels, size_t frames) {
  FILE* f = fopen(path.fileSystemRepresentation, "wb");
  if (!f) return;
  const uint32_t dataBytes = uint32_t(frames * channels * 2), rate = kRate, byteRate = rate * channels * 2;
  const uint16_t pcm = 1, nch = uint16_t(channels), align = uint16_t(channels * 2), bits = 16;
  const uint32_t riff = 36 + dataBytes, fmtLen = 16;
  fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtLen, 4, 1, f);
  fwrite(&pcm, 2, 1, f); fwrite(&nch, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&byteRate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
  fwrite("data", 1, 4, f); fwrite(&dataBytes, 4, 1, f);
  std::vector<int16_t> row(channels);
  for (size_t i = 0; i < frames; i++) {
    for (int c = 0; c < channels; c++) { float v = (*ch[c])[i]; v = v > 1 ? 1 : v < -1 ? -1 : v; row[c] = int16_t(lrintf(v * 32767)); }
    fwrite(row.data(), 2, channels, f);
  }
  fclose(f);
}

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    NSMutableDictionary* args = [NSMutableDictionary dictionary];
    for (int i = 1; i < argc; i++) {
      NSString* a = @(argv[i]);
      if (![a hasPrefix:@"--"]) continue;
      BOOL hasValue = i + 1 < argc && strncmp(argv[i + 1], "--", 2) != 0;
      args[[a substringFromIndex:2]] = hasValue ? @(argv[++i]) : @"1";
    }
    NSString* mode = args[@"mode"] ?: @"webrtc";
    NSString* outDir = args[@"out-dir"] ?: [NSTemporaryDirectory() stringByAppendingPathComponent:@"browsa-audio-lab"];
    const double speech = [args[@"seconds"] ?: @"45" doubleValue], lead = 4, tail = 3;
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableString* report = [NSMutableString string];
    auto finish = ^(int code) {
      [report writeToFile:[outDir stringByAppendingPathComponent:@"report.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
      printf("%s", report.UTF8String);
      exit(code);
    };

    // The microphone prompt, once, for this lab app.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL allowed = NO;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok) { allowed = ok; dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (!allowed) { [report appendString:@"ERROR: microphone access was not allowed\n"]; finish(2); }

    std::vector<float> far = loadMono48k(args[@"far"] ?: @"");
    if (far.empty()) { [report appendString:@"ERROR: could not read the --far recording\n"]; finish(2); }
    const size_t leadN = size_t(lead * kRate), speechN = size_t(speech * kRate), totalN = leadN + speechN + size_t(tail * kRate);

    std::atomic<size_t> played(0);
    const std::vector<float>* farPtr = &far;
    auto playout = [farPtr, leadN, speechN, &played](float* out, int n) {
      size_t p = played.load(std::memory_order_relaxed);
      for (int i = 0; i < n; i++, p++) {
        if (p < leadN || p >= leadN + speechN) { out[i] = 0; continue; }
        const size_t k = p - leadN;
        float v = (*farPtr)[k % farPtr->size()];
        // 50 ms fades so the start and end don't click.
        const size_t fade = 2400;
        if (k < fade) v *= float(k) / fade; else if (speechN - k < fade) v *= float(speechN - k) / fade;
        out[i] = v;
      }
      played.store(p, std::memory_order_relaxed);
    };

    std::vector<float> raw(totalN + kRate), ref(totalN + kRate), clean(totalN + kRate);
    std::atomic<size_t> captured(0);
    std::vector<float>*rawP = &raw, *refP = &ref, *cleanP = &clean;
    std::atomic<size_t>* capturedP = &captured;
    auto capture = [rawP, refP, cleanP, capturedP](const float* r, const float* f, const float* c, int n) {
      size_t at = capturedP->load(std::memory_order_relaxed);
      if (at + n > rawP->size()) return;
      memcpy(rawP->data() + at, r, n * sizeof(float)); memcpy(refP->data() + at, f, n * sizeof(float)); memcpy(cleanP->data() + at, c, n * sizeof(float));
      capturedP->store(at + n, std::memory_order_release);
    };

    CallAudioConfig cfg;
    cfg.mode = [mode isEqual:@"apple"] ? CallAudioConfig::kAppleVoiceProcessing : [mode isEqual:@"raw"] ? CallAudioConfig::kRaw : CallAudioConfig::kWebRtc;
    cfg.inputDevice = [args[@"in"] ?: @"" UTF8String]; cfg.outputDevice = [args[@"out"] ?: @"" UTF8String];
    cfg.noiseSuppression = !args[@"no-ns"]; cfg.autoGain = args[@"gain"] != nil;
    if (args[@"lead-ms"]) cfg.referenceLeadMs = [args[@"lead-ms"] doubleValue];
    std::string error;
    CallAudioCore* core = CallAudioCore::create(cfg, playout, capture, &error);
    if (!core->start(&error)) { [report appendFormat:@"ERROR: %s\n", error.c_str()]; finish(3); }

    NSMutableArray* timeline = [NSMutableArray array];
    const double total = lead + speech + tail;
    for (double t = 0; t < total + 0.5; t += 1) {
      [NSThread sleepForTimeInterval:1];
      CallAudioStatus s = core->status();
      [timeline addObject:@{ @"t": @(t + 1), @"driftPpm": @(s.driftPpm), @"erle": @(s.erle), @"delayMs": @(s.delayMs),
                             @"resyncs": @(s.resyncs), @"misses": @(s.referenceMisses) }];
    }
    CallAudioStatus st = core->status();
    core->stop();
    const size_t got = captured.load();

    // Quiet level: seconds 1 to 3.5, before the far end talks. Then the far end's whole turn, and 5 s windows of it.
    const size_t s0 = leadN + size_t(0.3 * kRate), s1 = leadN + speechN;
    const double floorRaw = db(power(raw, kRate, size_t(3.5 * kRate))), floorClean = db(power(clean, kRate, size_t(3.5 * kRate)));
    const double duringRaw = db(power(raw, s0, s1)), duringClean = db(power(clean, s0, s1));
    NSMutableArray* windows = [NSMutableArray array];
    double worstAfterStart = -200, firstWindow = -200;
    for (size_t a = s0; a + 5 * kRate <= s1; a += 5 * kRate) {
      const double above = db(power(clean, a, a + 5 * kRate)) - floorClean;
      [windows addObject:@(round(above * 10) / 10)];
      if (a == s0) firstWindow = above; else worstAfterStart = fmax(worstAfterStart, above);
    }
    const double above = duringClean - floorClean;
    NSString* verdict = above < 3 ? @"good" : above < 10 ? @"some echo" : @"echo: the other side hears themselves";

    [report appendFormat:@"Browsa Audio Lab, mode %@\n", mode];
    [report appendFormat:@"Microphone: %s (%d ch, %.0f Hz, %.1f ms)   Speakers: %s (%.0f Hz, %.1f ms)\n", st.inputName.c_str(), st.inputChannels, st.inputRate,
                         st.inputLatencyMs, st.outputName.c_str(), st.outputRate, st.outputLatencyMs];
    [report appendFormat:@"Captured %.1f s of %.1f s\n", double(got) / kRate, total];
    if (cfg.mode != CallAudioConfig::kAppleVoiceProcessing)
      [report appendFormat:@"In the room:      quiet %.1f dBFS, far end talking %.1f dBFS (echo %.1f dB above quiet)\n", floorRaw, duringRaw, duringRaw - floorRaw];
    [report appendFormat:@"After processing: quiet %.1f dBFS, far end talking %.1f dBFS\n", floorClean, duringClean];
    [report appendFormat:@"RESULT: echo %.1f dB above quiet: %@\n", above, verdict];
    [report appendFormat:@"5 s windows (dB above quiet): %@\n", [windows componentsJoinedByString:@"  "]];
    [report appendFormat:@"First 5 s %.1f dB, worst later window %.1f dB\n", firstWindow, worstAfterStart];
    if (cfg.mode == CallAudioConfig::kWebRtc)
      [report appendFormat:@"Echo canceller: removed %.1f dB (its own figure), delay %.0f ms, speaker/mic clock drift %+.1f ppm, resyncs %d, reference misses %d, clock resets %d\n",
                           st.erle, st.delayMs, st.driftPpm, st.resyncs, st.referenceMisses, st.clockResets];

    NSDictionary* json = @{ @"mode": mode, @"input": @(st.inputName.c_str()), @"output": @(st.outputName.c_str()), @"inputRate": @(st.inputRate),
      @"inputChannels": @(st.inputChannels), @"inputLatencyMs": @(st.inputLatencyMs), @"outputLatencyMs": @(st.outputLatencyMs),
      @"floorRawDb": @(floorRaw), @"duringRawDb": @(duringRaw), @"floorCleanDb": @(floorClean), @"duringCleanDb": @(duringClean),
      @"echoAboveQuietDb": @(above), @"verdict": verdict, @"windows5s": windows, @"firstWindowDb": @(firstWindow), @"worstLaterWindowDb": @(worstAfterStart),
      @"driftPpm": @(st.driftPpm), @"erle": @(st.erle), @"delayMs": @(st.delayMs), @"resyncs": @(st.resyncs), @"referenceMisses": @(st.referenceMisses),
      @"timeline": timeline };
    [[NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[outDir stringByAppendingPathComponent:@"report.json"] atomically:YES];
    const std::vector<float>* ch[3] = {&raw, &ref, &clean};
    writeWav([outDir stringByAppendingPathComponent:@"recording.wav"], ch, 3, got);
    finish(0);
  }
}
