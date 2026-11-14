// Browsa Audio Lab: plays a call's far end on real speakers, optionally a stand-in near-end talker on a
// second speaker, and records what the microphone path would send. tools/audio-bench drives it and does
// the analysis; on its own it still prints the echo yardstick from tools/echo-test (level while the far
// end talks against the room's quiet level: under 3 dB good, over 10 dB the other side hears themselves).
//
//   --mode webrtc   Browsa's core: WebRTC processing on the real device clocks (the default)
//   --mode apple    Apple's voice processing unit, as WebKit and Safari use it
//   --mode raw      no processing: how loud the echo is in the room
//   --mode play     no microphone: only the talker, on schedule (for browser subjects that play the far end)
//   --far <file>    the far-end recording (any format Core Audio reads)
//   --talker <file> --talker-out <device>   the near-end stand-in and the speaker it plays from
//   --talker-volume <0..1>                  that speaker's volume for the run (restored afterwards)
//   --schedule q,f,n,d,q   seconds of quiet, far end only, near end only, both, quiet (default 4,<seconds>,0,0,3)
//   --seconds <n>   far-end-only length when there is no --schedule (45)
//   --out-dir <dir> where report.txt, meta.json and the WAVs go
//   --in <name> --out <name>   devices by name; default: the system's
//   --channels 1,2  which device inputs make up the mic (own path only; default 1,2)
//   --gain          WebRTC automatic gain on;  --no-ns   noise suppression off
//   --list-devices  print every audio device as JSON and exit
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <cmath>
#include <string>
#include <vector>
#include "CallAudioCore.h"

using namespace browsa;
static const int kRate = 48000;

// ---------- devices ----------
template <class T> static bool getProp(AudioObjectID o, AudioObjectPropertySelector s, AudioObjectPropertyScope sc, T* out, UInt32 el = kAudioObjectPropertyElementMain) {
  AudioObjectPropertyAddress a = {s, sc, el};
  UInt32 size = sizeof(T);
  return AudioObjectGetPropertyData(o, &a, 0, nullptr, &size, out) == noErr;
}
static NSString* devName(AudioDeviceID d) {
  CFStringRef s = nullptr;
  if (!getProp(d, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &s) || !s) return @"?";
  return CFBridgingRelease(s);
}
static int devChannels(AudioDeviceID d, bool input) {
  AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(d, &a, 0, nullptr, &size) != noErr || !size) return 0;
  std::vector<char> buf(size);
  if (AudioObjectGetPropertyData(d, &a, 0, nullptr, &size, buf.data()) != noErr) return 0;
  auto* abl = reinterpret_cast<AudioBufferList*>(buf.data());
  int n = 0;
  for (UInt32 i = 0; i < abl->mNumberBuffers; i++) n += abl->mBuffers[i].mNumberChannels;
  return n;
}
static std::vector<AudioDeviceID> allDevices() {
  AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
  std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());
  return ids;
}
static AudioDeviceID findDev(NSString* want, bool input) {
  if (!want.length) {
    AudioDeviceID d = kAudioObjectUnknown;
    getProp(kAudioObjectSystemObject, input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &d);
    return d;
  }
  for (auto d : allDevices())
    if (devChannels(d, input) > 0 && [devName(d) rangeOfString:want options:NSCaseInsensitiveSearch].location != NSNotFound) return d;
  return kAudioObjectUnknown;
}
static AudioObjectPropertyAddress volumeAddress() {
  return {kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
}
static float devVolume(AudioDeviceID d) {
  Float32 v = -1; UInt32 size = sizeof v; auto a = volumeAddress();
  if (AudioHardwareServiceGetPropertyData(d, &a, 0, nullptr, &size, &v) != noErr) return -1;
  return v;
}
static bool setDevVolume(AudioDeviceID d, float v) {
  Float32 x = v; auto a = volumeAddress();
  return AudioHardwareServiceSetPropertyData(d, &a, 0, nullptr, sizeof x, &x) == noErr;
}
static NSString* transport(AudioDeviceID d) {
  UInt32 t = 0; getProp(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &t);
  switch (t) {
    case kAudioDeviceTransportTypeBuiltIn: return @"built-in";
    case kAudioDeviceTransportTypeUSB: return @"USB";
    case kAudioDeviceTransportTypeBluetooth: case kAudioDeviceTransportTypeBluetoothLE: return @"Bluetooth";
    case kAudioDeviceTransportTypeDisplayPort: return @"DisplayPort";
    case kAudioDeviceTransportTypeHDMI: return @"HDMI";
    case kAudioDeviceTransportTypeVirtual: return @"virtual";
    case kAudioDeviceTransportTypeAggregate: return @"aggregate";
    default: return @"other";
  }
}
static NSArray* listDevices() {
  AudioDeviceID defIn = findDev(nil, true), defOut = findDev(nil, false);
  NSMutableArray* out = [NSMutableArray array];
  for (auto d : allDevices()) {
    Float64 rate = 0; getProp(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate);
    int in = devChannels(d, true), outCh = devChannels(d, false);
    [out addObject:@{ @"name": devName(d), @"inputs": @(in), @"outputs": @(outCh), @"rate": @(rate), @"transport": transport(d),
                      @"defaultInput": @(d == defIn), @"defaultOutput": @(d == defOut), @"volume": outCh ? @(devVolume(d)) : [NSNull null] }];
  }
  return out;
}

// ---------- files ----------
static std::vector<float> loadMono48k(NSString* path) {
  std::vector<float> out;
  ExtAudioFileRef f = nullptr;
  if (!path.length || ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &f) != noErr) return out;
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
// 32-bit float WAV, so quiet levels survive for the analysis.
static void writeWav(NSString* path, const std::vector<const std::vector<float>*>& ch, int rate, size_t frames) {
  FILE* f = fopen(path.fileSystemRepresentation, "wb");
  if (!f) return;
  const uint16_t nch = uint16_t(ch.size()), fmtTag = 3, bits = 32, align = uint16_t(nch * 4);
  const uint32_t dataBytes = uint32_t(frames * nch * 4), r = uint32_t(rate), byteRate = r * align, riff = 36 + dataBytes, fmtLen = 16;
  fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtLen, 4, 1, f);
  fwrite(&fmtTag, 2, 1, f); fwrite(&nch, 2, 1, f); fwrite(&r, 4, 1, f); fwrite(&byteRate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
  fwrite("data", 1, 4, f); fwrite(&dataBytes, 4, 1, f);
  std::vector<float> row(nch);
  for (size_t i = 0; i < frames; i++) {
    for (int c = 0; c < nch; c++) row[c] = i < ch[c]->size() ? (*ch[c])[i] : 0.f;
    fwrite(row.data(), 4, nch, f);
  }
  fclose(f);
}

// ---------- the schedule: quiet, far only, near only, both, quiet ----------
struct Schedule {
  size_t b[6] = {0};  // segment boundaries in 48 kHz samples
  static constexpr size_t kFade = 2400;  // 50 ms, so segments don't click
  static float fade(size_t k, size_t len) {
    if (k < kFade) return float(k) / kFade;
    if (len - k < kFade) return float(len - k) / kFade;
    return 1;
  }
  // Gain and position in the far (or near) recording for overall sample p; gain 0 when it is silent.
  float far(size_t p, size_t* pos) const {
    if (p >= b[1] && p < b[2]) { *pos = p - b[1]; return fade(p - b[1], b[2] - b[1]); }
    if (p >= b[3] && p < b[4]) { *pos = (b[2] - b[1]) + (p - b[3]); return fade(p - b[3], b[4] - b[3]); }
    return 0;
  }
  float near(size_t p, size_t* pos) const {
    if (p >= b[2] && p < b[3]) { *pos = p - b[2]; return fade(p - b[2], b[3] - b[2]); }
    if (p >= b[3] && p < b[4]) { *pos = (b[3] - b[2]) + (p - b[3]); return fade(p - b[3], b[4] - b[3]); }
    return 0;
  }
  size_t total() const { return b[5]; }
};

// A plain output unit on a named device that plays the near-end stand-in on the schedule.
struct Talker {
  AudioUnit unit = nullptr;
  const std::vector<float>* voice = nullptr;
  const Schedule* schedule = nullptr;
  std::atomic<size_t> played{0};
  static OSStatus render(void* self, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames, AudioBufferList* io) {
    auto* t = static_cast<Talker*>(self);
    size_t p = t->played.load(std::memory_order_relaxed);
    float* out0 = static_cast<float*>(io->mBuffers[0].mData);
    for (UInt32 i = 0; i < frames; i++, p++) {
      size_t pos = 0;
      const float g = t->schedule->near(p, &pos);
      out0[i] = g > 0 ? g * (*t->voice)[pos % t->voice->size()] : 0.f;
    }
    for (UInt32 b = 1; b < io->mNumberBuffers; b++) memcpy(io->mBuffers[b].mData, out0, frames * sizeof(float));
    t->played.store(p, std::memory_order_relaxed);
    return noErr;
  }
  bool start(AudioDeviceID dev, std::string* error) {
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent c = AudioComponentFindNext(nullptr, &d);
    if (!c || AudioComponentInstanceNew(c, &unit) != noErr) { *error = "no talker output unit"; return false; }
    AudioStreamBasicDescription f = {};
    f.mSampleRate = kRate; f.mFormatID = kAudioFormatLinearPCM; f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBitsPerChannel = 32; f.mChannelsPerFrame = 2; f.mFramesPerPacket = 1; f.mBytesPerFrame = f.mBytesPerPacket = 4;
    AURenderCallbackStruct cb = {&Talker::render, this};
    OSStatus e;
    if ((e = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sizeof dev)) ||
        (e = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f)) ||
        (e = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb)) ||
        (e = AudioUnitInitialize(unit)) || (e = AudioOutputUnitStart(unit))) { *error = "talker setup failed " + std::to_string(int(e)); return false; }
    return true;
  }
  void stop() {
    if (!unit) return;
    AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); unit = nullptr;
  }
};

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    NSMutableDictionary* args = [NSMutableDictionary dictionary];
    for (int i = 1; i < argc; i++) {
      NSString* a = @(argv[i]);
      if (![a hasPrefix:@"--"]) continue;
      BOOL hasValue = i + 1 < argc && strncmp(argv[i + 1], "--", 2) != 0;
      args[[a substringFromIndex:2]] = hasValue ? @(argv[++i]) : @"1";
    }
    if (args[@"list-devices"]) {
      NSData* j = [NSJSONSerialization dataWithJSONObject:listDevices() options:NSJSONWritingPrettyPrinted error:nil];
      printf("%s\n", [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding].UTF8String);
      return 0;
    }
    NSString* mode = args[@"mode"] ?: @"webrtc";
    const bool playOnly = [mode isEqual:@"play"];
    NSString* outDir = args[@"out-dir"] ?: [NSTemporaryDirectory() stringByAppendingPathComponent:@"browsa-audio-lab"];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableString* report = [NSMutableString string];
    __block AudioDeviceID talkerDev = kAudioObjectUnknown;
    __block float talkerVolumeBefore = -1;
    auto finish = ^(int code) {
      if (talkerVolumeBefore >= 0) setDevVolume(talkerDev, talkerVolumeBefore);
      [report writeToFile:[outDir stringByAppendingPathComponent:@"report.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
      printf("%s", report.UTF8String);
      exit(code);
    };

    // Schedule.
    Schedule sched;
    {
      NSArray* parts = [(args[@"schedule"] ?: [NSString stringWithFormat:@"4,%@,0,0,3", args[@"seconds"] ?: @"45"]) componentsSeparatedByString:@","];
      if (parts.count != 5) { [report appendString:@"ERROR: --schedule needs five numbers\n"]; finish(2); }
      size_t at = 0;
      for (int i = 0; i < 5; i++) { at += size_t([parts[i] doubleValue] * kRate); sched.b[i + 1] = at; }
    }
    const size_t totalN = sched.total();
    const double total = double(totalN) / kRate;

    std::vector<float> far = loadMono48k(args[@"far"]);
    std::vector<float> voice = loadMono48k(args[@"talker"]);
    const bool hasFarSegments = sched.b[4] > sched.b[3] || sched.b[2] > sched.b[1];
    const bool hasNearSegments = sched.b[3] > sched.b[2] || sched.b[4] > sched.b[3];
    if (!playOnly && hasFarSegments && far.empty()) { [report appendString:@"ERROR: could not read the --far recording\n"]; finish(2); }
    if (hasNearSegments && voice.empty()) { [report appendString:@"ERROR: the schedule has near-end time but no readable --talker recording\n"]; finish(2); }

    if (!playOnly) {
      // The microphone prompt, once, for this lab app (or nothing, when the host process already has it).
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      __block BOOL allowed = NO;
      [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok) { allowed = ok; dispatch_semaphore_signal(sem); }];
      dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
      if (!allowed) { [report appendString:@"ERROR: microphone access was not allowed\n"]; finish(2); }
    }

    // Talker.
    Talker talker;
    talker.voice = &voice; talker.schedule = &sched;
    if (!voice.empty()) {
      talkerDev = findDev(args[@"talker-out"], false);
      if (talkerDev == kAudioObjectUnknown) { [report appendFormat:@"ERROR: no output device matching %@\n", args[@"talker-out"]]; finish(2); }
      if (args[@"talker-volume"]) { talkerVolumeBefore = devVolume(talkerDev); setDevVolume(talkerDev, [args[@"talker-volume"] floatValue]); }
    }

    std::atomic<size_t> played(0);
    const std::vector<float>* farPtr = &far;
    const Schedule* sp = &sched;
    auto playout = [farPtr, sp, &played](float* out, int n) {
      size_t p = played.load(std::memory_order_relaxed);
      for (int i = 0; i < n; i++, p++) {
        size_t pos = 0;
        const float g = sp->far(p, &pos);
        out[i] = g > 0 && !farPtr->empty() ? g * (*farPtr)[pos % farPtr->size()] : 0.f;
      }
      played.store(p, std::memory_order_relaxed);
    };

    std::vector<float> raw(totalN + 2 * kRate), ref(totalN + 2 * kRate), clean(totalN + 2 * kRate);
    std::atomic<size_t> captured(0);
    std::vector<float>*rawP = &raw, *refP = &ref, *cleanP = &clean;
    std::atomic<size_t>* capturedP = &captured;
    auto capture = [rawP, refP, cleanP, capturedP](const float* r, const float* f, const float* c, int n) {
      size_t at = capturedP->load(std::memory_order_relaxed);
      if (at + n > rawP->size()) return;
      memcpy(rawP->data() + at, r, n * sizeof(float)); memcpy(refP->data() + at, f, n * sizeof(float)); memcpy(cleanP->data() + at, c, n * sizeof(float));
      capturedP->store(at + n, std::memory_order_release);
    };

    // Every device input, at the device's rate (own path only).
    static const int kMaxChannels = 8;
    std::vector<std::vector<float>> chans(kMaxChannels);
    std::atomic<size_t> chanFrames(0);
    std::atomic<int> chanCount(0);
    std::vector<std::vector<float>>* chansP = &chans;
    std::atomic<size_t>* chanFramesP = &chanFrames;
    std::atomic<int>* chanCountP = &chanCount;

    CallAudioConfig cfg;
    cfg.mode = [mode isEqual:@"apple"] ? CallAudioConfig::kAppleVoiceProcessing : [mode isEqual:@"raw"] ? CallAudioConfig::kRaw : CallAudioConfig::kWebRtc;
    cfg.inputDevice = [args[@"in"] ?: @"" UTF8String]; cfg.outputDevice = [args[@"out"] ?: @"" UTF8String];
    cfg.noiseSuppression = !args[@"no-ns"]; cfg.autoGain = args[@"gain"] != nil;
    if (args[@"lead-ms"]) cfg.referenceLeadMs = [args[@"lead-ms"] doubleValue];
    if (args[@"channels"]) {
      cfg.channelMask = 0;
      for (NSString* c in [args[@"channels"] componentsSeparatedByString:@","]) if (c.intValue > 0) cfg.channelMask |= 1u << (c.intValue - 1);
    }
    double inputRateForTap = kRate;
    {
      AudioDeviceID inDev = findDev(args[@"in"], true);
      Float64 r = kRate; getProp(inDev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &r);
      inputRateForTap = r;
      const size_t cap = size_t((total + 2) * r);
      for (auto& c : chans) c.assign(cap, 0.f);
    }
    cfg.channelTap = [chansP, chanFramesP, chanCountP](const float* const* ch, int count, int frames) {
      const int n = count < kMaxChannels ? count : kMaxChannels;
      chanCountP->store(n, std::memory_order_relaxed);
      size_t at = chanFramesP->load(std::memory_order_relaxed);
      if (at + frames > (*chansP)[0].size()) return;
      for (int c = 0; c < n; c++) memcpy((*chansP)[c].data() + at, ch[c], frames * sizeof(float));
      chanFramesP->store(at + frames, std::memory_order_release);
    };

    std::string error;
    CallAudioCore* core = nullptr;
    const double startedAt = [NSDate date].timeIntervalSince1970;
    if (!playOnly) {
      core = CallAudioCore::create(cfg, playout, capture, &error);
      if (!core->start(&error)) { [report appendFormat:@"ERROR: %s\n", error.c_str()]; finish(3); }
    }
    if (!voice.empty() && !talker.start(talkerDev, &error)) { if (core) core->stop(); [report appendFormat:@"ERROR: %s\n", error.c_str()]; finish(3); }

    NSMutableArray* timeline = [NSMutableArray array];
    for (double t = 0; t < total + 0.5; t += 1) {
      [NSThread sleepForTimeInterval:1];
      if (!core) continue;
      CallAudioStatus s = core->status();
      [timeline addObject:@{ @"t": @(t + 1), @"driftPpm": @(s.driftPpm), @"erle": @(s.erle), @"delayMs": @(s.delayMs),
                             @"resyncs": @(s.resyncs), @"misses": @(s.referenceMisses) }];
    }
    talker.stop();
    if (talkerVolumeBefore >= 0) { setDevVolume(talkerDev, talkerVolumeBefore); talkerVolumeBefore = -1; }
    if (playOnly) { [report appendFormat:@"Played the talker for %.1f s\n", total]; finish(0); }

    CallAudioStatus st = core->status();
    core->stop();
    const size_t got = captured.load();

    // The old yardstick, from the first far-end-only segment.
    const size_t q1 = sched.b[1], s0 = sched.b[1] + size_t(0.3 * kRate), s1 = sched.b[2];
    const double floorRaw = db(power(raw, kRate / 2, q1 - kRate / 4)), floorClean = db(power(clean, kRate / 2, q1 - kRate / 4));
    const double duringRaw = db(power(raw, s0, s1)), duringClean = db(power(clean, s0, s1));
    const double above = duringClean - floorClean;
    NSString* verdict = above < 3 ? @"good" : above < 10 ? @"some echo" : @"echo: the other side hears themselves";
    [report appendFormat:@"Browsa Audio Lab, mode %@\n", mode];
    [report appendFormat:@"Microphone: %s (%d ch, %.0f Hz, %.1f ms)   Speakers: %s (%.0f Hz, %.1f ms)\n", st.inputName.c_str(), st.inputChannels, st.inputRate,
                         st.inputLatencyMs, st.outputName.c_str(), st.outputRate, st.outputLatencyMs];
    if (!voice.empty()) [report appendFormat:@"Talker: %@\n", devName(talkerDev)];
    [report appendFormat:@"Captured %.1f s of %.1f s\n", double(got) / kRate, total];
    if (cfg.mode != CallAudioConfig::kAppleVoiceProcessing)
      [report appendFormat:@"In the room:      quiet %.1f dBFS, far end talking %.1f dBFS (echo %.1f dB above quiet)\n", floorRaw, duringRaw, duringRaw - floorRaw];
    [report appendFormat:@"After processing: quiet %.1f dBFS, far end talking %.1f dBFS\n", floorClean, duringClean];
    [report appendFormat:@"RESULT: echo %.1f dB above quiet: %@\n", above, verdict];
    if (cfg.mode == CallAudioConfig::kWebRtc)
      [report appendFormat:@"Echo canceller: removed %.1f dB (its own figure), delay %.0f ms, speaker/mic clock drift %+.1f ppm, resyncs %d, reference misses %d, clock resets %d\n",
                           st.erle, st.delayMs, st.driftPpm, st.resyncs, st.referenceMisses, st.clockResets];

    NSMutableArray* segs = [NSMutableArray array];
    for (int i = 0; i < 6; i++) [segs addObject:@(double(sched.b[i]) / kRate)];
    const int nch = chanCount.load();
    NSDictionary* meta = @{ @"mode": mode, @"input": @(st.inputName.c_str()), @"output": @(st.outputName.c_str()),
      @"talkerOutput": voice.empty() ? [NSNull null] : devName(talkerDev), @"inputRate": @(st.inputRate), @"inputChannels": @(st.inputChannels),
      @"inputLatencyMs": @(st.inputLatencyMs), @"outputLatencyMs": @(st.outputLatencyMs), @"outputVolume": @(devVolume(findDev(args[@"out"], false))),
      @"talkerVolume": voice.empty() ? [NSNull null] : @(devVolume(talkerDev)), @"channelMask": @(cfg.channelMask),
      @"segments": segs, @"startedAt": @(startedAt), @"capturedSeconds": @(double(got) / kRate),
      @"driftPpm": @(st.driftPpm), @"erle": @(st.erle), @"delayMs": @(st.delayMs), @"resyncs": @(st.resyncs),
      @"referenceMisses": @(st.referenceMisses), @"clockResets": @(st.clockResets),
      @"deviceChannels": @(nch), @"deviceChannelRate": @(inputRateForTap), @"timeline": timeline };
    [[NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[outDir stringByAppendingPathComponent:@"meta.json"] atomically:YES];
    // sent.wav: what would go to the other side. raw.wav: the mic before processing (own path). ref.wav: the
    // reference the canceller got. channels.wav: every device input at the device rate.
    writeWav([outDir stringByAppendingPathComponent:@"sent.wav"], {&clean}, kRate, got);
    if (cfg.mode != CallAudioConfig::kAppleVoiceProcessing) writeWav([outDir stringByAppendingPathComponent:@"raw.wav"], {&raw}, kRate, got);
    writeWav([outDir stringByAppendingPathComponent:@"ref.wav"], {&ref}, kRate, got);
    if (nch > 0) {
      std::vector<const std::vector<float>*> cs;
      for (int c = 0; c < nch; c++) cs.push_back(&chans[c]);
      writeWav([outDir stringByAppendingPathComponent:@"channels.wav"], cs, int(inputRateForTap), chanFrames.load());
    }
    finish(0);
  }
}
