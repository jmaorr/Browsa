#include "CallAudioCore.h"
#include "Apm.h"
#include "AudioTimeline.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <memory>
#include <vector>

namespace browsa {
namespace {

constexpr int kFrame = 480;          // 10 ms at 48 kHz
constexpr double kRate = 48000;
constexpr UInt32 kOutputBus = 0, kInputBus = 1;

double hostSeconds(UInt64 hostTime) {
  static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
  return double(hostTime) * tb.numer / tb.denom * 1e-9;
}
double stampSeconds(const AudioTimeStamp* ts) {
  return hostSeconds((ts->mFlags & kAudioTimeStampHostTimeValid) ? ts->mHostTime : mach_absolute_time());
}

std::string fourcc(OSStatus e) {
  char b[32]; snprintf(b, sizeof b, "%d", int(e)); return b;
}

template <class T> bool getProp(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, T* out) {
  AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
  UInt32 size = sizeof(T);
  return AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, out) == noErr;
}

std::string deviceName(AudioDeviceID d) {
  CFStringRef s = nullptr;
  if (!getProp(d, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &s) || !s) return "?";
  char buf[256] = {0};
  CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
  CFRelease(s);
  return buf;
}

int channelCount(AudioDeviceID d, AudioObjectPropertyScope scope) {
  AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(d, &a, 0, nullptr, &size) != noErr || !size) return 0;
  std::vector<char> buf(size);
  if (AudioObjectGetPropertyData(d, &a, 0, nullptr, &size, buf.data()) != noErr) return 0;
  auto* abl = reinterpret_cast<AudioBufferList*>(buf.data());
  int n = 0;
  for (UInt32 i = 0; i < abl->mNumberBuffers; i++) n += abl->mBuffers[i].mNumberChannels;
  return n;
}

AudioDeviceID findDevice(const std::string& want, bool input) {
  const auto scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
  if (want.empty()) {
    AudioDeviceID d = kAudioObjectUnknown;
    getProp(kAudioObjectSystemObject, input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal, &d);
    return d;
  }
  AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size) != noErr) return kAudioObjectUnknown;
  std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
  AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());
  auto lower = [](std::string s) { std::transform(s.begin(), s.end(), s.begin(), ::tolower); return s; };
  for (auto d : ids)
    if (channelCount(d, scope) > 0 && lower(deviceName(d)).find(lower(want)) != std::string::npos) return d;
  return kAudioObjectUnknown;
}

// Seconds between the device's timestamp and the air: device latency + safety offset + stream latency.
double deviceLatency(AudioDeviceID d, bool input) {
  const auto scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
  UInt32 latency = 0, safety = 0, stream = 0;
  Float64 rate = kRate;
  getProp(d, kAudioDevicePropertyLatency, scope, &latency);
  getProp(d, kAudioDevicePropertySafetyOffset, scope, &safety);
  getProp(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate);
  AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(d, &a, 0, nullptr, &size) == noErr && size >= sizeof(AudioStreamID)) {
    std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
    if (AudioObjectGetPropertyData(d, &a, 0, nullptr, &size, streams.data()) == noErr)
      getProp(streams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &stream);
  }
  return (latency + safety + stream) / (rate > 0 ? rate : kRate);
}

AudioStreamBasicDescription floatFormat(double rate, int channels) {
  AudioStreamBasicDescription f = {};
  f.mSampleRate = rate; f.mFormatID = kAudioFormatLinearPCM;
  f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
  f.mBitsPerChannel = 32; f.mChannelsPerFrame = channels; f.mFramesPerPacket = 1; f.mBytesPerFrame = f.mBytesPerPacket = 4;
  return f;
}

AudioUnit makeUnit(OSType subtype) {
  AudioComponentDescription d = {kAudioUnitType_Output, subtype, kAudioUnitManufacturer_Apple, 0, 0};
  AudioComponent c = AudioComponentFindNext(nullptr, &d);
  AudioUnit u = nullptr;
  if (!c || AudioComponentInstanceNew(c, &u) != noErr) return nullptr;
  return u;
}

class Core final : public CallAudioCore {
 public:
  Core(const CallAudioConfig& c, Playout p, Capture cap) : cfg_(c), playout_(std::move(p)), capture_(std::move(cap)) {}
  ~Core() override { stop(); }

  bool start(std::string* error) override {
    inDev_ = findDevice(cfg_.inputDevice, true);
    outDev_ = findDevice(cfg_.outputDevice, false);
    if (inDev_ == kAudioObjectUnknown || outDev_ == kAudioObjectUnknown) { *error = "audio device not found"; return false; }
    status_.inputName = deviceName(inDev_); status_.outputName = deviceName(outDev_);
    Float64 r = kRate;
    getProp(outDev_, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &r); status_.outputRate = r;
    getProp(inDev_, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &r); status_.inputRate = micRate_ = r;
    inLatency_ = deviceLatency(inDev_, true); outLatency_ = deviceLatency(outDev_, false);
    status_.inputLatencyMs = inLatency_ * 1000; status_.outputLatencyMs = outLatency_ * 1000;
    mono_.assign(8192, 0); frameFill_ = 0;
    return cfg_.mode == CallAudioConfig::kAppleVoiceProcessing ? startVoiceProcessing(error) : startOwn(error);
  }

  void stop() override {
    for (AudioUnit* u : {&inUnit_, &outUnit_}) {
      if (!*u) continue;
      AudioOutputUnitStop(*u); AudioUnitUninitialize(*u); AudioComponentInstanceDispose(*u); *u = nullptr;
    }
    apm_.reset();
  }

  CallAudioStatus status() override {
    CallAudioStatus s = status_;
    s.driftPpm = (outClock_.rate() / kRate) / (micClock_.rate() / micRate_) * 1e6 - 1e6;
    s.resyncs = refReader_.resyncs; s.referenceMisses = refReader_.misses;
    s.clockResets = outClock_.resets() + micClock_.resets();
    if (apm_) { auto a = apm_->stats(); s.erle = a.erle; s.delayMs = a.delayMs; s.residualLikelihood = a.residualLikelihood; }
    return s;
  }

 private:
  // ---------- Browsa's own path: two plain device units and WebRTC's processing ----------
  bool startOwn(std::string* error) {
    OSStatus e;
    UInt32 on = 1, off = 0;
    // Speakers.
    outUnit_ = makeUnit(kAudioUnitSubType_HALOutput);
    if (!outUnit_) { *error = "no output unit"; return false; }
    auto outFormat = floatFormat(kRate, 2);
    AURenderCallbackStruct render = {&Core::renderThunk, this};
    if ((e = AudioUnitSetProperty(outUnit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outDev_, sizeof outDev_)) ||
        (e = AudioUnitSetProperty(outUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &outFormat, sizeof outFormat)) ||
        (e = AudioUnitSetProperty(outUnit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, kOutputBus, &render, sizeof render)) ||
        (e = AudioUnitInitialize(outUnit_))) { *error = "output setup failed " + fourcc(e); return false; }

    // Microphone, unprocessed, every channel the device has, at the device's own rate.
    inUnit_ = makeUnit(kAudioUnitSubType_HALOutput);
    if (!inUnit_) { *error = "no input unit"; return false; }
    if ((e = AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &on, sizeof on)) ||
        (e = AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &off, sizeof off)) ||
        (e = AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inDev_, sizeof inDev_))) {
      *error = "input device setup failed " + fourcc(e); return false;
    }
    AudioStreamBasicDescription dev = {};
    UInt32 size = sizeof dev;
    AudioUnitGetProperty(inUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kInputBus, &dev, &size);
    micChannels_ = std::max<int>(1, std::min<int>(8, dev.mChannelsPerFrame));
    if (dev.mSampleRate > 0) micRate_ = dev.mSampleRate;
    status_.inputRate = micRate_; status_.inputChannels = micChannels_;
    auto inFormat = floatFormat(micRate_, micChannels_);
    AURenderCallbackStruct input = {&Core::inputThunk, this};
    if ((e = AudioUnitSetProperty(inUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &inFormat, sizeof inFormat)) ||
        (e = AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &input, sizeof input)) ||
        (e = AudioUnitInitialize(inUnit_))) { *error = "input setup failed " + fourcc(e); return false; }
    micBuffers_.assign(micChannels_, std::vector<float>(8192));

    micClock_.reset(micRate_); outClock_.reset(kRate);
    micStep_ = micRate_ / kRate; micPos_ = 2;
    // The reference a microphone frame needs has to have been handed to the speakers already. Their
    // buffers give that much head start; where they don't, hold the microphone back a touch instead.
    lead_ = cfg_.referenceLeadMs / 1000;
    const double headStart = inLatency_ + outLatency_;
    holdSamples_ = std::max(0.0, lead_ - headStart + 0.003) * micRate_;
    if (cfg_.mode == CallAudioConfig::kWebRtc) {
      ApmOptions o; o.noise = cfg_.noiseSuppression; o.gain = cfg_.autoGain;
      apm_.reset(Apm::create(o));
    }
    if ((e = AudioOutputUnitStart(outUnit_)) || (e = AudioOutputUnitStart(inUnit_))) { *error = "start failed " + fourcc(e); return false; }
    return true;
  }

  static OSStatus renderThunk(void* self, AudioUnitRenderActionFlags*, const AudioTimeStamp* ts, UInt32, UInt32 frames, AudioBufferList* io) {
    return static_cast<Core*>(self)->render(ts, frames, io);
  }
  OSStatus render(const AudioTimeStamp* ts, UInt32 frames, AudioBufferList* io) {
    if (frames > mono_.size()) frames = UInt32(mono_.size());
    playout_(mono_.data(), int(frames));
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) memcpy(io->mBuffers[b].mData, mono_.data(), frames * sizeof(float));
    // Exactly these samples, and the moment the first of them leaves the speakers.
    outClock_.update(double(outIndex_), stampSeconds(ts) + outLatency_);
    refRing_.write(mono_.data(), frames);
    outIndex_ += frames;
    return noErr;
  }

  static OSStatus inputThunk(void* self, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus, UInt32 frames, AudioBufferList*) {
    return static_cast<Core*>(self)->input(flags, ts, bus, frames);
  }
  OSStatus input(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus, UInt32 frames) {
    if (frames > 8192) return noErr;
    char storage[sizeof(AudioBufferList) + 8 * sizeof(AudioBuffer)];
    auto* abl = reinterpret_cast<AudioBufferList*>(storage);
    abl->mNumberBuffers = micChannels_;
    for (int c = 0; c < micChannels_; c++) abl->mBuffers[c] = {1, UInt32(frames * sizeof(float)), micBuffers_[c].data()};
    if (OSStatus e = AudioUnitRender(inUnit_, flags, ts, bus, frames, abl)) return e;
    if (cfg_.channelTap) {
      const float* channels[8];
      for (int c = 0; c < micChannels_; c++) channels[c] = micBuffers_[c].data();
      cfg_.channelTap(channels, micChannels_, int(frames));
    }
    // By default the first two inputs summed: a mic on input 2 of an interface counts as much as one on
    // input 1. Later channels are left out; on interfaces like the Scarlett they are loopback of the
    // computer's sound.
    float mix[8192];
    for (UInt32 i = 0; i < frames; i++) {
      float m = 0;
      for (int c = 0; c < micChannels_; c++) if (cfg_.channelMask & (1u << c)) m += micBuffers_[c][i];
      mix[i] = m;
    }
    micClock_.update(double(micIndex_), stampSeconds(ts) - inLatency_);
    micRing_.write(mix, frames);
    micIndex_ += frames;

    while (micPos_ + kFrame * micStep_ + 3 + holdSamples_ <= double(micIndex_)) {
      for (int i = 0; i < kFrame; i++) micRing_.at(micPos_ + i * micStep_, &raw_[i]);
      // The moments this frame was in the air, and the speaker samples that were in the air just after.
      const double t0 = micClock_.timeOf(micPos_), t1 = micClock_.timeOf(micPos_ + kFrame * micStep_);
      if (outClock_.valid()) refReader_.read(refRing_, ref_, kFrame, outClock_.indexAt(t0 + lead_), outClock_.indexAt(t1 + lead_), 0.005 * kRate);
      else memset(ref_, 0, sizeof ref_);
      memcpy(clean_, raw_, sizeof clean_);
      if (apm_) {
        float played[kFrame]; memcpy(played, ref_, sizeof played);
        apm_->played(played);
        apm_->process(clean_, int(lead_ * 1000));
      }
      capture_(raw_, ref_, clean_, kFrame);
      micPos_ += kFrame * micStep_;
    }
    return noErr;
  }

  // ---------- Apple's voice processing unit, set up the way WebKit sets it up, for comparison ----------
  bool startVoiceProcessing(std::string* error) {
    OSStatus e;
    UInt32 on = 1;
    inUnit_ = makeUnit(kAudioUnitSubType_VoiceProcessingIO);
    if (!inUnit_) { *error = "no voice processing unit"; return false; }
    auto format = floatFormat(kRate, 1);
    AURenderCallbackStruct render = {&Core::vpRenderThunk, this}, input = {&Core::vpInputThunk, this};
    if ((e = AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, kInputBus, &on, sizeof on)) ||
        (e = AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, kOutputBus, &on, sizeof on))) {
      *error = "voice processing io failed " + fourcc(e); return false;
    }
    if (!cfg_.inputDevice.empty()) AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, kInputBus, &inDev_, sizeof inDev_);
    if (!cfg_.outputDevice.empty()) AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, kOutputBus, &outDev_, sizeof outDev_);
    if ((e = AudioUnitSetProperty(inUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, kInputBus, &format, sizeof format)) ||
        (e = AudioUnitSetProperty(inUnit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, kOutputBus, &format, sizeof format)) ||
        (e = AudioUnitSetProperty(inUnit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, kOutputBus, &render, sizeof render)) ||
        (e = AudioUnitSetProperty(inUnit_, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &input, sizeof input)) ||
        (e = AudioUnitInitialize(inUnit_)) || (e = AudioOutputUnitStart(inUnit_))) { *error = "voice processing setup failed " + fourcc(e); return false; }
    status_.inputChannels = 1;
    return true;
  }
  static OSStatus vpRenderThunk(void* self, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames, AudioBufferList* io) {
    auto* c = static_cast<Core*>(self);
    if (frames > c->mono_.size()) frames = UInt32(c->mono_.size());
    c->playout_(c->mono_.data(), int(frames));
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) memcpy(io->mBuffers[b].mData, c->mono_.data(), frames * sizeof(float));
    c->refRing_.write(c->mono_.data(), frames);
    return noErr;
  }
  static OSStatus vpInputThunk(void* self, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus, UInt32 frames, AudioBufferList*) {
    auto* c = static_cast<Core*>(self);
    if (frames > 8192) return noErr;
    float buf[8192];
    AudioBufferList abl; abl.mNumberBuffers = 1; abl.mBuffers[0] = {1, UInt32(frames * sizeof(float)), buf};
    if (OSStatus e = AudioUnitRender(c->inUnit_, flags, ts, bus, frames, &abl)) return e;
    for (UInt32 i = 0; i < frames; i++) {
      c->clean_[c->frameFill_++] = buf[i];
      if (c->frameFill_ == kFrame) {
        // No raw microphone or aligned reference to show in this mode: the unit keeps those to itself.
        const uint64_t w = c->refRing_.written();
        for (int k = 0; k < kFrame; k++) c->refRing_.at(double(w) - 3 - kFrame + k, &c->ref_[k]);
        c->capture_(c->clean_, c->ref_, c->clean_, kFrame);
        c->frameFill_ = 0;
      }
    }
    return noErr;
  }

  CallAudioConfig cfg_;
  Playout playout_;
  Capture capture_;
  CallAudioStatus status_;
  AudioDeviceID inDev_ = kAudioObjectUnknown, outDev_ = kAudioObjectUnknown;
  AudioUnit inUnit_ = nullptr, outUnit_ = nullptr;
  std::unique_ptr<Apm> apm_;
  ClockModel outClock_{kRate}, micClock_{kRate};
  SampleRing refRing_, micRing_;
  SteeredReader refReader_;
  std::vector<float> mono_;
  std::vector<std::vector<float>> micBuffers_;
  uint64_t outIndex_ = 0, micIndex_ = 0;
  int micChannels_ = 1, frameFill_ = 0;
  double micRate_ = kRate, micStep_ = 1, micPos_ = 2, inLatency_ = 0, outLatency_ = 0, lead_ = 0.01, holdSamples_ = 0;
  float raw_[kFrame] = {0}, ref_[kFrame] = {0}, clean_[kFrame] = {0};
};

}  // namespace

CallAudioCore* CallAudioCore::create(const CallAudioConfig& c, Playout p, Capture cap, std::string*) {
  return new Core(c, std::move(p), std::move(cap));
}

}  // namespace browsa
