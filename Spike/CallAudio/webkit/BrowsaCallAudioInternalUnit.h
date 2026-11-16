// Browsa call audio inside WebKit.
//
// WebKit's microphone capture (CoreAudioCaptureUnit, in the GPU process) talks to an "internal unit":
// Apple's voice processing unit when a page asks for echo cancellation, a plain device unit when it
// doesn't. The voice processing unit also plays the call's incoming audio, so it knows what to cancel.
//
// This is a third internal unit with the same shape. It owns a plain microphone unit and a plain
// speaker unit, plays what WebKit hands it, and runs WebRTC's audio processing (AEC3, noise
// suppression, gain: the module Chrome uses, already compiled into WebKit's libwebrtc) between them,
// with the two device clocks reconciled in host time (BrowsaAudioTimeline.h). Pages, WebRTC and the
// rest of WebKit see no difference; there are no page scripts.
//
// Included only by CoreAudioCaptureUnit.cpp. Set BROWSA_CALL_AUDIO=apple in the environment to get
// Apple's voice processing back for comparison.
//
// Tuning without a rebuild (read when a call's microphone starts; WebKit's processes see each variable
// as __XPC_<name>, which run.sh sets up):
//   BROWSA_CALL_AUDIO_REF_OFFSET_MS    the reference later (+) or earlier (-) than the clocks say, ms (default 0)
//   BROWSA_CALL_AUDIO_WARMUP           0 or 1, hold the far end's leak down while the canceller learns the room at
//                                      the start of a call (default 1; BrowsaCallGuard.h)
//   BROWSA_CALL_AUDIO_GATED_GAIN       0 or 1, Browsa's gain that is only fully applied while you talk (default 1;
//                                      BrowsaCallGuard.h); WebRTC's own gain is then off unless _AGC=1 is set too
//   BROWSA_CALL_AUDIO_AGC              0 or 1, WebRTC's adaptive digital gain (default: off with gated gain, else 1)
//   BROWSA_CALL_AUDIO_AGC_MAX_DB       its gain limit (default 30)
//   BROWSA_CALL_AUDIO_AGC_NOISE_DBFS   the noise level it may lift to (default -60)
//   BROWSA_CALL_AUDIO_NS               noise suppression 0 low .. 3 very high, or off (default 2)
//   BROWSA_CALL_AUDIO_DUMP             debug dump (below; development builds only); BROWSA_CALL_AUDIO_DUMP_MINUTES caps it (default 30)
#pragma once

#if ENABLE(MEDIA_STREAM) && PLATFORM(MAC) && USE(LIBWEBRTC)

#include "CoreAudioCaptureUnit.h"
#include "Logging.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <mach/mach_time.h>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>
#include <wtf/TZoneMallocInlines.h>

#include <pal/cf/AudioToolboxSoftLink.h>

// The timing half is shared with Spike/CallAudio/core (AudioTimeline.h), plain C++ with raw buffers.
WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
#include "BrowsaAudioTimeline.h"
#include "BrowsaCallGuard.h"
#include "BrowsaSideSpeakers.h"
// Call recording (the debug dump below) exists only in development WebKit builds: they have BrowsaCallAudioRecording.h
// next to this file (copied in from Spike/CallAudio/webkit). Built without it, as for release, the unit can't record,
// whatever the environment says.
#if __has_include("BrowsaCallAudioRecording.h")
#include "BrowsaCallAudioRecording.h"
#endif
#ifndef BROWSA_CALL_AUDIO_RECORDING
#define BROWSA_CALL_AUDIO_RECORDING 0
#endif
WTF_ALLOW_UNSAFE_BUFFER_USAGE_END

WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_BEGIN
IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")
#include <webrtc/api/audio/builtin_audio_processing_builder.h>
#include <webrtc/api/environment/environment_factory.h>
#include <webrtc/modules/audio_processing/include/audio_processing.h>
IGNORE_CLANG_WARNINGS_END
WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_END

WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN

namespace WebCore {

class BrowsaCallAudioInternalUnit final : public CoreAudioCaptureUnit::InternalUnit {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(BrowsaCallAudioInternalUnit);
public:
    static bool isEnabled()
    {
        static bool enabled = [] {
            const char* value = getenv("BROWSA_CALL_AUDIO");
            return !value || strcmp(value, "apple");
        }();
        return enabled;
    }

    BrowsaCallAudioInternalUnit()
    {
        m_micFormat = floatFormat(processingRate, 1);
        m_speakerFormat = floatFormat(processingRate, 1);
        RELEASE_LOG(WebRTC, "BrowsaCallAudioInternalUnit: WebRTC audio processing in place of Apple voice processing");
    }
    ~BrowsaCallAudioInternalUnit() final { uninitialize(); }

private:
    static constexpr double processingRate = 48000;
    static constexpr int frameSize = 480; // 10 ms
    static constexpr UInt32 outputBus = 0;
    static constexpr UInt32 inputBus = 1;
    static constexpr UInt32 maxFrames = 8192;

    struct Settings {
        double referenceOffsetMs { 0 };
        bool gain { true };
        double gainMaxDb { 30 };
        double gainNoiseDbfs { -60 };
        int noiseLevel { 2 }; // 0 low .. 3 very high, -1 off
        bool warmup { true };
        bool gatedGain { true };
    };
    static double environmentNumber(const char* name, double fallback, double low, double high)
    {
        const char* value = getenv(name);
        if (!value || !*value)
            return fallback;
        char* end = nullptr;
        const double number = strtod(value, &end);
        if (end == value || !std::isfinite(number))
            return fallback;
        return std::min(high, std::max(low, number));
    }
    static Settings readSettings()
    {
        Settings settings;
        settings.referenceOffsetMs = environmentNumber("BROWSA_CALL_AUDIO_REF_OFFSET_MS", 0, -100, 100);
        settings.warmup = environmentNumber("BROWSA_CALL_AUDIO_WARMUP", 1, 0, 1) >= 0.5;
        settings.gatedGain = environmentNumber("BROWSA_CALL_AUDIO_GATED_GAIN", 1, 0, 1) >= 0.5;
        settings.gain = environmentNumber("BROWSA_CALL_AUDIO_AGC", settings.gatedGain ? 0 : 1, 0, 1) >= 0.5;
        // libwebrtc's defaults allow 50 dB of gain and room noise up to -50 dBFS; on an open-speaker call that
        // lifts the room and the canceller's leftovers too. Calls need a voice brought up, not a room.
        settings.gainMaxDb = environmentNumber("BROWSA_CALL_AUDIO_AGC_MAX_DB", 30, 0, 50);
        settings.gainNoiseDbfs = environmentNumber("BROWSA_CALL_AUDIO_AGC_NOISE_DBFS", -60, -90, -30);
        const char* noise = getenv("BROWSA_CALL_AUDIO_NS");
        settings.noiseLevel = noise && !strcmp(noise, "off") ? -1 : static_cast<int>(environmentNumber("BROWSA_CALL_AUDIO_NS", 2, 0, 3));
        return settings;
    }

    static AudioStreamBasicDescription floatFormat(double rate, int channels)
    {
        AudioStreamBasicDescription format = { };
        format.mSampleRate = rate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
        format.mBitsPerChannel = 32;
        format.mChannelsPerFrame = channels;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = format.mBytesPerPacket = 4;
        return format;
    }

    static double hostSeconds(UInt64 hostTime)
    {
        static mach_timebase_info_data_t timebase = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
        return static_cast<double>(hostTime) * timebase.numer / timebase.denom * 1e-9;
    }
    static UInt64 hostTicks(double seconds)
    {
        static mach_timebase_info_data_t timebase = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
        return static_cast<UInt64>(seconds * 1e9 * timebase.denom / timebase.numer);
    }
    static double stampSeconds(const AudioTimeStamp* stamp)
    {
        return hostSeconds((stamp->mFlags & kAudioTimeStampHostTimeValid) ? stamp->mHostTime : mach_absolute_time());
    }

    template<typename T> static bool deviceProperty(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, T* out)
    {
        AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
        UInt32 size = sizeof(T);
        return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, out) == noErr;
    }

    // Seconds between a device's timestamp and the air.
    static double deviceLatency(AudioDeviceID device, bool input)
    {
        auto scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
        UInt32 latency = 0, safety = 0, stream = 0;
        Float64 rate = processingRate;
        deviceProperty(device, kAudioDevicePropertyLatency, scope, &latency);
        deviceProperty(device, kAudioDevicePropertySafetyOffset, scope, &safety);
        deviceProperty(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate);
        AudioObjectPropertyAddress address = { kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain };
        UInt32 size = 0;
        if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) == noErr && size >= sizeof(AudioStreamID)) {
            std::vector<AudioStreamID> streams(size / sizeof(AudioStreamID));
            if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, streams.data()) == noErr)
                deviceProperty(streams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &stream);
        }
        return (latency + safety + stream) / (rate > 0 ? rate : processingRate);
    }

    static AudioUnit makeHALUnit()
    {
        AudioComponentDescription description = { kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0 };
        AudioComponent component = PAL::AudioComponentFindNext(nullptr, &description);
        AudioUnit unit = nullptr;
        if (!component || PAL::AudioComponentInstanceNew(component, &unit) != noErr)
            return nullptr;
        return unit;
    }

    // ---------- the audio unit WebKit thinks it is talking to ----------
    OSStatus set(AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, const void* value, UInt32 size) final
    {
        switch (property) {
        case kAudioOutputUnitProperty_EnableIO:
            return noErr;
        case kAudioOutputUnitProperty_CurrentDevice:
            if (size != sizeof(AudioDeviceID))
                return kAudioUnitErr_InvalidPropertyValue;
            (element == inputBus ? m_inputDevice : m_outputDevice) = *static_cast<const AudioDeviceID*>(value);
            return noErr;
        case kAudioUnitProperty_StreamFormat:
            if (size != sizeof(AudioStreamBasicDescription))
                return kAudioUnitErr_InvalidPropertyValue;
            if (scope == kAudioUnitScope_Output && element == inputBus)
                m_micFormat = *static_cast<const AudioStreamBasicDescription*>(value);
            else if (scope == kAudioUnitScope_Input && element == outputBus)
                m_speakerFormat = *static_cast<const AudioStreamBasicDescription*>(value);
            return noErr;
        case kAudioOutputUnitProperty_SetInputCallback:
            m_micCallback = value ? *static_cast<const AURenderCallbackStruct*>(value) : AURenderCallbackStruct { };
            return noErr;
        case kAudioUnitProperty_SetRenderCallback:
            m_speakerCallback = value ? *static_cast<const AURenderCallbackStruct*>(value) : AURenderCallbackStruct { };
            return noErr;
        case kAUVoiceIOProperty_MuteOutput:
            m_muted = value && *static_cast<const UInt32*>(value);
            return noErr;
        default:
            return kAudioUnitErr_InvalidProperty;
        }
    }

    OSStatus get(AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, void* value, UInt32* size) final
    {
        switch (property) {
        case kAudioUnitProperty_StreamFormat:
            if (!size || *size < sizeof(AudioStreamBasicDescription))
                return kAudioUnitErr_InvalidPropertyValue;
            *static_cast<AudioStreamBasicDescription*>(value) = (scope == kAudioUnitScope_Output && element == inputBus) ? m_micFormat : m_speakerFormat;
            *size = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioOutputUnitProperty_CurrentDevice:
            if (!size || *size < sizeof(AudioDeviceID))
                return kAudioUnitErr_InvalidPropertyValue;
            *static_cast<AudioDeviceID*>(value) = element == inputBus ? m_inputDevice : m_outputDevice;
            return noErr;
        default:
            return kAudioUnitErr_InvalidProperty;
        }
    }

    OSStatus defaultInputDevice(uint32_t* device) final
    {
        return deviceProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, device) ? noErr : -1;
    }
    OSStatus defaultOutputDevice(uint32_t* device) final
    {
        return deviceProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, device) ? noErr : -1;
    }
    bool setVoiceActivityDetection(bool) final { return false; }
    bool canRenderAudio() const final { return true; }

    OSStatus initialize() final
    {
        if (m_initialized)
            return noErr;
        if (!m_inputDevice)
            defaultInputDevice(&m_inputDevice);
        if (!m_outputDevice)
            defaultOutputDevice(&m_outputDevice);

        UInt32 on = 1, off = 0;
        OSStatus error = noErr;

        // Speakers: WebKit's own format, converted by the unit to whatever the device runs at.
        m_outUnit = makeHALUnit();
        if (!m_outUnit)
            return kAudioUnitErr_FailedInitialization;
        AURenderCallbackStruct render = { speakerThunk, this };
        if ((error = PAL::AudioUnitSetProperty(m_outUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &m_outputDevice, sizeof(m_outputDevice)))
            || (error = PAL::AudioUnitSetProperty(m_outUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, outputBus, &m_speakerFormat, sizeof(m_speakerFormat)))
            || (error = PAL::AudioUnitSetProperty(m_outUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, outputBus, &render, sizeof(render)))
            || (error = PAL::AudioUnitInitialize(m_outUnit))) {
            RELEASE_LOG_ERROR(WebRTC, "BrowsaCallAudioInternalUnit speaker setup failed, error %d", (int)error);
            uninitialize();
            return error;
        }

        // Microphone: unprocessed, every channel, at the device's own rate.
        m_inUnit = makeHALUnit();
        if (!m_inUnit) {
            uninitialize();
            return kAudioUnitErr_FailedInitialization;
        }
        if ((error = PAL::AudioUnitSetProperty(m_inUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &on, sizeof(on)))
            || (error = PAL::AudioUnitSetProperty(m_inUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputBus, &off, sizeof(off)))
            || (error = PAL::AudioUnitSetProperty(m_inUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &m_inputDevice, sizeof(m_inputDevice)))) {
            RELEASE_LOG_ERROR(WebRTC, "BrowsaCallAudioInternalUnit microphone device setup failed, error %d", (int)error);
            uninitialize();
            return error;
        }
        AudioStreamBasicDescription deviceFormat = { };
        UInt32 size = sizeof(deviceFormat);
        PAL::AudioUnitGetProperty(m_inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &deviceFormat, &size);
        m_deviceChannels = std::max<int>(1, std::min<int>(8, deviceFormat.mChannelsPerFrame));
        m_deviceRate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : processingRate;
        auto captureFormat = floatFormat(m_deviceRate, m_deviceChannels);
        AURenderCallbackStruct input = { microphoneThunk, this };
        if ((error = PAL::AudioUnitSetProperty(m_inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &captureFormat, sizeof(captureFormat)))
            || (error = PAL::AudioUnitSetProperty(m_inUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &input, sizeof(input)))
            || (error = PAL::AudioUnitInitialize(m_inUnit))) {
            RELEASE_LOG_ERROR(WebRTC, "BrowsaCallAudioInternalUnit microphone setup failed, error %d", (int)error);
            uninitialize();
            return error;
        }

        m_deviceBuffers.assign(m_deviceChannels, std::vector<float>(maxFrames));
        m_speakerMono.assign(maxFrames, 0);
        m_inputLatency = deviceLatency(m_inputDevice, true);
        m_outputLatency = deviceLatency(m_outputDevice, false);
        m_micClock.reset(m_deviceRate);
        m_speakerClock.reset(m_speakerFormat.mSampleRate);
        m_micStep = m_deviceRate / processingRate;
        m_micPosition = 2;
        m_micIndex = m_speakerIndex = 0;
        m_sideReader = { };
        m_sideFrames = 0;
        m_deliverStep = processingRate / m_micFormat.mSampleRate;
        m_deliverPosition = 2;
        m_deliveredFrames = 0;
        m_settings = readSettings();
        // A later reference (positive offset) is read from speaker samples that were in the air earlier.
        m_referenceLead = referenceLead - m_settings.referenceOffsetMs / 1000;
        // The reference a microphone frame needs must already have been handed to the speakers. Their
        // buffering gives that much head start; where it doesn't, hold the microphone back a touch.
        m_holdSamples = std::max(0.0, m_referenceLead - (m_inputLatency + m_outputLatency) + 0.003) * m_deviceRate;

        webrtc::AudioProcessing::Config config;
        config.pipeline.maximum_internal_processing_rate = 48000;
        config.high_pass_filter.enabled = true;
        config.echo_canceller.enabled = true;
        using NoiseLevel = webrtc::AudioProcessing::Config::NoiseSuppression::Level;
        static constexpr NoiseLevel noiseLevels[] = { NoiseLevel::kLow, NoiseLevel::kModerate, NoiseLevel::kHigh, NoiseLevel::kVeryHigh };
        config.noise_suppression.enabled = m_settings.noiseLevel >= 0;
        config.noise_suppression.level = noiseLevels[std::min(3, std::max(0, m_settings.noiseLevel))];
        config.gain_controller2.enabled = m_settings.gain;
        config.gain_controller2.adaptive_digital.enabled = m_settings.gain;
        config.gain_controller2.adaptive_digital.max_gain_db = static_cast<float>(m_settings.gainMaxDb);
        config.gain_controller2.adaptive_digital.max_output_noise_level_dbfs = static_cast<float>(m_settings.gainNoiseDbfs);
        browsa::CallGuardOptions guardOptions;
        guardOptions.warmup = m_settings.warmup;
        guardOptions.gatedGain = m_settings.gatedGain;
        m_guard = browsa::CallGuard(guardOptions);
        m_processing = webrtc::BuiltinAudioProcessingBuilder(config).Build(webrtc::CreateEnvironment());
        if (!m_processing) {
            uninitialize();
            return kAudioUnitErr_FailedInitialization;
        }

        RELEASE_LOG(WebRTC, "BrowsaCallAudioInternalUnit ready: microphone %.0f Hz x%d (latency %.1f ms), speakers %.0f Hz x%d (latency %.1f ms), WebKit microphone format %.0f Hz",
            m_deviceRate, m_deviceChannels, m_inputLatency * 1000, m_speakerFormat.mSampleRate, (int)m_speakerFormat.mChannelsPerFrame, m_outputLatency * 1000, m_micFormat.mSampleRate);
        RELEASE_LOG(WebRTC, "BrowsaCallAudioInternalUnit settings: reference offset %.1f ms, gain %d (max %.0f dB, noise %.0f dBFS), noise suppression %d, warm-up %d, gated gain %d",
            m_settings.referenceOffsetMs, (int)m_settings.gain, m_settings.gainMaxDb, m_settings.gainNoiseDbfs, m_settings.noiseLevel, (int)m_settings.warmup, (int)m_settings.gatedGain);
        m_initialized = true;
        browsa::SideSpeakers::shared().setListening(true);
        startDump();
        return noErr;
    }

    OSStatus uninitialize() final
    {
        stop();
        browsa::SideSpeakers::shared().setListening(false);
        finishDump();
        for (AudioUnit* unit : { &m_inUnit, &m_outUnit }) {
            if (!*unit)
                continue;
            PAL::AudioUnitUninitialize(*unit);
            PAL::AudioComponentInstanceDispose(*unit);
            *unit = nullptr;
        }
        m_processing = nullptr;
        m_initialized = false;
        return noErr;
    }

    OSStatus start() final
    {
        if (!m_initialized)
            return kAudioUnitErr_Uninitialized;
        if (m_started)
            return noErr;
        if (auto error = PAL::AudioOutputUnitStart(m_outUnit))
            return error;
        if (auto error = PAL::AudioOutputUnitStart(m_inUnit)) {
            PAL::AudioOutputUnitStop(m_outUnit);
            return error;
        }
        m_started = true;
        return noErr;
    }

    OSStatus stop() final
    {
        if (!m_started)
            return noErr;
        PAL::AudioOutputUnitStop(m_inUnit);
        PAL::AudioOutputUnitStop(m_outUnit);
        m_started = false;
        return noErr;
    }

    // ---------- speakers ----------
    static OSStatus speakerThunk(void* self, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* stamp, UInt32, UInt32 frames, AudioBufferList* data)
    {
        return static_cast<BrowsaCallAudioInternalUnit*>(self)->renderSpeakers(flags, stamp, frames, data);
    }

    OSStatus renderSpeakers(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* stamp, UInt32 frames, AudioBufferList* data)
    {
        for (UInt32 i = 0; i < data->mNumberBuffers; ++i)
            memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
        AudioUnitRenderActionFlags producerFlags = 0;
        if (m_speakerCallback.inputProc)
            m_speakerCallback.inputProc(m_speakerCallback.inputProcRefCon, &producerFlags, stamp, outputBus, frames, data);
        UNUSED_PARAM(flags);

        // Exactly what goes to the speakers, as one channel, stamped with when it reaches the air.
        if (frames > maxFrames)
            frames = maxFrames;
        const bool isFloat = m_speakerFormat.mFormatFlags & kAudioFormatFlagIsFloat;
        const bool interleaved = !(m_speakerFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
        const UInt32 channels = std::max<UInt32>(1, m_speakerFormat.mChannelsPerFrame);
        float* mono = m_speakerMono.data();
        if ((producerFlags & kAudioUnitRenderAction_OutputIsSilence) || !isFloat || m_speakerFormat.mBitsPerChannel != 32)
            memset(mono, 0, frames * sizeof(float));
        else if (interleaved) {
            const float* samples = static_cast<const float*>(data->mBuffers[0].mData);
            for (UInt32 i = 0; i < frames; ++i) {
                float sum = 0;
                for (UInt32 c = 0; c < channels; ++c)
                    sum += samples[i * channels + c];
                mono[i] = sum / channels;
            }
        } else {
            memset(mono, 0, frames * sizeof(float));
            for (UInt32 b = 0; b < data->mNumberBuffers; ++b) {
                const float* samples = static_cast<const float*>(data->mBuffers[b].mData);
                for (UInt32 i = 0; i < frames; ++i)
                    mono[i] += samples[i] / data->mNumberBuffers;
            }
        }
        m_speakerCallbacks++;
        if (producerFlags & kAudioUnitRenderAction_OutputIsSilence)
            m_speakerSilentCallbacks++;
        m_speakerClock.update(static_cast<double>(m_speakerIndex), stampSeconds(stamp) + m_outputLatency);
        m_speakerRing.write(mono, frames);
        m_speakerIndex += frames;
        return noErr;
    }

    // ---------- microphone ----------
    static OSStatus microphoneThunk(void* self, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* stamp, UInt32 bus, UInt32 frames, AudioBufferList*)
    {
        return static_cast<BrowsaCallAudioInternalUnit*>(self)->captureMicrophone(flags, stamp, bus, frames);
    }

    OSStatus captureMicrophone(AudioUnitRenderActionFlags* flags, const AudioTimeStamp* stamp, UInt32 bus, UInt32 frames)
    {
        if (frames > maxFrames)
            return noErr;
        char storage[sizeof(AudioBufferList) + 8 * sizeof(AudioBuffer)];
        auto* list = reinterpret_cast<AudioBufferList*>(storage);
        list->mNumberBuffers = m_deviceChannels;
        for (int c = 0; c < m_deviceChannels; ++c)
            list->mBuffers[c] = { 1, static_cast<UInt32>(frames * sizeof(float)), m_deviceBuffers[c].data() };
        if (auto error = PAL::AudioUnitRender(m_inUnit, flags, stamp, bus, frames, list))
            return error;

        // The first two inputs summed, so a microphone on input 2 of an interface counts. Later channels
        // are left out: on interfaces like the Scarlett they are loopback of the computer's sound.
        float mix[maxFrames];
        const int used = std::min(m_deviceChannels, 2);
        for (UInt32 i = 0; i < frames; ++i) {
            float sum = 0;
            for (int c = 0; c < used; ++c)
                sum += m_deviceBuffers[c][i];
            mix[i] = sum;
        }
        m_micClock.update(static_cast<double>(m_micIndex), stampSeconds(stamp) - m_inputLatency);
        m_micRing.write(mix, frames);
        m_micIndex += frames;

        while (m_micPosition + frameSize * m_micStep + 3 + m_holdSamples <= static_cast<double>(m_micIndex)) {
            float clean[frameSize], reference[frameSize];
            for (int i = 0; i < frameSize; ++i)
                m_micRing.at(m_micPosition + i * m_micStep, &clean[i]);
            // The moments this frame was in the air, and the speaker samples in the air just after.
            const double start = m_micClock.timeOf(m_micPosition), end = m_micClock.timeOf(m_micPosition + frameSize * m_micStep);
            if (m_speakerClock.valid())
                m_referenceReader.read(m_speakerRing, reference, frameSize, m_speakerClock.indexAt(start + m_referenceLead), m_speakerClock.indexAt(end + m_referenceLead), 0.005 * m_speakerFormat.mSampleRate);
            else
                memset(reference, 0, sizeof(reference));
            addSideSpeakers(reference, start, end);

            float rawCopy[frameSize], referenceCopy[frameSize];
            const bool dumping = !m_dumpRing[0].empty();
            memcpy(rawCopy, clean, sizeof(rawCopy));
            memcpy(referenceCopy, reference, sizeof(referenceCopy));
            const webrtc::StreamConfig stream(48000, 1);
            float* referenceChannels[1] = { reference };
            float* cleanChannels[1] = { clean };
            m_processing->ProcessReverseStream(referenceChannels, stream, stream, referenceChannels);
            m_processing->set_stream_delay_ms(static_cast<int>(referenceLead * 1000));
            m_processing->ProcessStream(cleanChannels, stream, stream, cleanChannels);
            if (m_settings.warmup || m_settings.gatedGain)
                m_guard.process(rawCopy, referenceCopy, clean);
            if (m_muted)
                memset(clean, 0, sizeof(clean));
            if (dumping)
                dumpFrame(rawCopy, referenceCopy, clean);
            m_cleanRing.write(clean, frameSize);
            m_cleanStart[m_cleanFrames++ % cleanStartCount] = start;
            m_micPosition += frameSize * m_micStep;

            // Hand WebKit 10 ms at a time, in the format it asked for.
            const UInt32 deliver = static_cast<UInt32>(m_micFormat.mSampleRate / 100);
            while (m_deliverPosition + deliver * m_deliverStep + 3 <= static_cast<double>(m_cleanRing.written())) {
                if (m_micCallback.inputProc) {
                    AudioTimeStamp out = { };
                    out.mSampleTime = static_cast<Float64>(m_deliveredFrames);
                    out.mHostTime = hostTicks(start);
                    out.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
                    AudioUnitRenderActionFlags outFlags = 0;
                    m_pendingDeliver = deliver;
                    m_micCallback.inputProc(m_micCallback.inputProcRefCon, &outFlags, &out, inputBus, deliver, nullptr);
                }
                m_deliverPosition += deliver * m_deliverStep;
                m_deliveredFrames += deliver;
            }
        }
        return noErr;
    }

    // Call audio WebKit plays itself on a speaker the page chose (BrowsaSideSpeakers.h): added to the
    // reference, lined up the same way. Silence when nothing plays there.
    void addSideSpeakers(float* reference, double start, double end)
    {
        auto& side = browsa::SideSpeakers::shared();
        if (!side.playedAround(start))
            return;
        float extra[frameSize];
        const auto& clock = side.clock();
        m_sideReader.read(side.ring(), extra, frameSize, clock.indexAt(start + m_referenceLead), clock.indexAt(end + m_referenceLead), 0.005 * clock.rate());
        for (int i = 0; i < frameSize; ++i)
            reference[i] += extra[i];
        m_sideFrames++;
    }

    // WebKit's microphone callback pulls the samples it was just told about.
    OSStatus render(AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames, AudioBufferList* list) final
    {
        if (!list || !list->mNumberBuffers)
            return kAudio_ParamError;
        const UInt32 channels = std::max<UInt32>(1, m_micFormat.mChannelsPerFrame);
        const bool interleaved = !(m_micFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
        for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
            float* out = static_cast<float*>(list->mBuffers[b].mData);
            const UInt32 perFrame = interleaved ? channels : 1;
            if (list->mBuffers[b].mDataByteSize < frames * perFrame * sizeof(float))
                return kAudio_ParamError;
            for (UInt32 i = 0; i < frames; ++i) {
                float sample = 0;
                m_cleanRing.at(m_deliverPosition + i * m_deliverStep, &sample);
                for (UInt32 c = 0; c < perFrame; ++c)
                    out[i * perFrame + c] = sample;
            }
            list->mBuffers[b].mDataByteSize = frames * perFrame * sizeof(float);
        }
        return noErr;
    }

    // ---------- debug dump (BROWSA_CALL_AUDIO_DUMP; WebKit's processes see it as __XPC_BROWSA_CALL_AUDIO_DUMP) ----------
    // The raw mic, the reference each 10 ms of it was cancelled against, and what was sent, 48 kHz float WAVs
    // plus meta.json (what WebKit negotiated, the settings), in the replay format of tools/audio-bench. Value: a
    // folder, or 1 for the GPU process's own cache folder, the only place its sandbox lets it write
    // (com.apple.WebKit.GPU.sb: DARWIN_USER_CACHE_DIR and DARWIN_USER_TEMP_DIR, both private to the process).
    // Written as the call goes: the audio thread only copies into a ring, a writer thread appends to the files
    // every half second and keeps their headers valid, so a crash or quit loses at most that half second.
    // Capped at BROWSA_CALL_AUDIO_DUMP_MINUTES (default 30) per call: about 11 MB a minute.
    static constexpr size_t dumpRingFrames = 30 * 48000; // a multiple of frameSize
    static constexpr int dumpStreams = 3;

    static const char* dumpSetting()
    {
#if BROWSA_CALL_AUDIO_RECORDING
        const char* value = getenv("BROWSA_CALL_AUDIO_DUMP");
        return value && *value && strcmp(value, "0") ? value : nullptr;
#else
        return nullptr;  // a WebKit built for release can't record
#endif
    }
    static void writeWavHeader(FILE* f, uint64_t frames)
    {
        const uint32_t bytes = static_cast<uint32_t>(std::min<uint64_t>(frames * 4, 0xFFFFFF00u)), rate = 48000, byteRate = rate * 4, riff = 36 + bytes, fmtLength = 16;
        const uint16_t tag = 3, channels = 1, align = 4, bits = 32;
        fseek(f, 0, SEEK_SET);
        fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtLength, 4, 1, f);
        fwrite(&tag, 2, 1, f); fwrite(&channels, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&byteRate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&bytes, 4, 1, f);
        fseek(f, 0, SEEK_END);
    }
    void startDump()
    {
        const char* setting = dumpSetting();
        if (!setting)
            return;
        std::string folder = setting;
        if (folder == "1") {
            char cache[PATH_MAX] = { };
            confstr(_CS_DARWIN_USER_CACHE_DIR, cache, sizeof(cache));
            folder = cache;
        }
        // WebKit can tear a unit down and make a new one within the same second (it did on the first real run):
        // a per-process counter keeps their folders apart.
        static std::atomic<unsigned> dumpCount { 0 };
        folder += "/browsa-call-audio-" + std::to_string(getpid()) + "-" + std::to_string(time(nullptr)) + "-" + std::to_string(++dumpCount);
        if (mkdir(folder.c_str(), 0755)) {
            RELEASE_LOG_ERROR(WebRTC, "BrowsaCallAudioInternalUnit: can't write the dump to %s (errno %d)", folder.c_str(), errno);
            return;
        }
        m_dumpFolder = folder;
        m_dumpLimitFrames = static_cast<uint64_t>(environmentNumber("BROWSA_CALL_AUDIO_DUMP_MINUTES", 30, 1, 120) * 60 * processingRate);
        static constexpr const char* names[dumpStreams] = { "raw.wav", "ref.wav", "sent.wav" };
        for (int s = 0; s < dumpStreams; ++s) {
            m_dumpRing[s].assign(dumpRingFrames, 0.f);
            m_dumpFiles[s] = fopen((folder + "/" + names[s]).c_str(), "wb");
            if (m_dumpFiles[s])
                writeWavHeader(m_dumpFiles[s], 0);
        }
        m_dumpWritten.store(0);
        m_dumpRead.store(0);
        m_dumpDropped.store(0);
        m_speakerCallbacks = 0;
        m_speakerSilentCallbacks = 0;
        m_dumpStartedAt = time(nullptr);
        m_dumpStop = false;
        writeDumpMeta(false);
        m_dumpThread = std::thread([this] { dumpLoop(); });
        RELEASE_LOG(WebRTC, "BrowsaCallAudioInternalUnit: dumping to %s", folder.c_str());
    }
    // Audio thread: one 10 ms frame of each stream into the ring. Never blocks or allocates.
    void dumpFrame(const float* mic, const float* reference, const float* sent)
    {
        const uint64_t written = m_dumpWritten.load(std::memory_order_relaxed);
        if (written >= m_dumpLimitFrames)
            return;
        if (written + frameSize - m_dumpRead.load(std::memory_order_acquire) > dumpRingFrames) {
            m_dumpDropped.fetch_add(frameSize, std::memory_order_relaxed);
            return;
        }
        const size_t at = static_cast<size_t>(written % dumpRingFrames);
        memcpy(m_dumpRing[0].data() + at, mic, frameSize * sizeof(float));
        memcpy(m_dumpRing[1].data() + at, reference, frameSize * sizeof(float));
        memcpy(m_dumpRing[2].data() + at, sent, frameSize * sizeof(float));
        m_dumpWritten.store(written + frameSize, std::memory_order_release);
    }
    void dumpLoop()
    {
        unsigned ticks = 0;
        std::unique_lock<std::mutex> lock(m_dumpMutex);
        while (!m_dumpStop) {
            m_dumpWake.wait_for(lock, std::chrono::milliseconds(500));
            lock.unlock();
            drainDump();
            if (!(++ticks % 20))
                writeDumpMeta(false);
            lock.lock();
        }
    }
    // Writer thread (or the stopping thread once the writer has gone): ring to files, headers kept valid.
    void drainDump()
    {
        const uint64_t written = m_dumpWritten.load(std::memory_order_acquire);
        uint64_t read = m_dumpRead.load(std::memory_order_relaxed);
        while (read < written) {
            const size_t at = static_cast<size_t>(read % dumpRingFrames);
            const size_t count = static_cast<size_t>(std::min<uint64_t>(written - read, dumpRingFrames - at));
            for (int s = 0; s < dumpStreams; ++s) {
                if (m_dumpFiles[s])
                    fwrite(m_dumpRing[s].data() + at, sizeof(float), count, m_dumpFiles[s]);
            }
            read += count;
        }
        m_dumpRead.store(read, std::memory_order_release);
        for (int s = 0; s < dumpStreams; ++s) {
            if (!m_dumpFiles[s])
                continue;
            writeWavHeader(m_dumpFiles[s], read);
            fflush(m_dumpFiles[s]);
        }
    }
    void writeDumpMeta(bool final)
    {
        if (m_dumpFolder.empty())
            return;
        auto describe = [](const AudioStreamBasicDescription& d) {
            char text[200];
            snprintf(text, sizeof(text), "{\"rate\": %.0f, \"channels\": %u, \"bits\": %u, \"float\": %s, \"interleaved\": %s}", d.mSampleRate, (unsigned)d.mChannelsPerFrame,
                (unsigned)d.mBitsPerChannel, (d.mFormatFlags & kAudioFormatFlagIsFloat) ? "true" : "false", (d.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? "false" : "true");
            return std::string(text);
        };
        // The reader and clock figures belong to the audio threads; they are only read once those have stopped.
        char timing[400] = "";
        if (final) {
            snprintf(timing, sizeof(timing), " \"referenceResyncs\": %d, \"referenceMisses\": %d, \"speakerClockRate\": %.3f, \"micClockRate\": %.3f,\n"
                " \"sideSpeakerFrames\": %llu, \"sideSpeakerResyncs\": %d, \"sideSpeakerMisses\": %d,\n",
                m_referenceReader.resyncs, m_referenceReader.misses, m_speakerClock.rate(), m_micClock.rate(),
                (unsigned long long)m_sideFrames, m_sideReader.resyncs, m_sideReader.misses);
        }
        const std::string path = m_dumpFolder + "/meta.json", temporary = path + ".tmp";
        FILE* f = fopen(temporary.c_str(), "w");
        if (!f)
            return;
        const uint64_t frames = m_dumpRead.load(std::memory_order_acquire);
        fprintf(f, "{\"mode\": \"webkit-unit\", \"dumpVersion\": 2, \"complete\": %s, \"startedAt\": %lld,\n"
            " \"settings\": {\"referenceOffsetMs\": %.1f, \"agc\": %s, \"agcMaxDb\": %.1f, \"agcNoiseDbfs\": %.1f, \"ns\": %d, \"warmup\": %s, \"gatedGain\": %s},\n"
            " \"inputRate\": %.0f, \"inputChannels\": %d, \"inputLatencyMs\": %.2f, \"outputLatencyMs\": %.2f,\n"
            " \"webkitMicFormat\": %s,\n \"webkitSpeakerFormat\": %s,\n \"holdSamples\": %.1f, \"referenceLeadMs\": %.1f, \"streamDelayHintMs\": %.0f,\n"
            " \"speakerCallbacks\": %llu, \"speakerSilentCallbacks\": %llu,\n%s"
            " \"droppedFrames\": %llu, \"limitSeconds\": %.0f, \"capturedSeconds\": %.2f}\n",
            final ? "true" : "false", (long long)m_dumpStartedAt,
            m_settings.referenceOffsetMs, m_settings.gain ? "true" : "false", m_settings.gainMaxDb, m_settings.gainNoiseDbfs, m_settings.noiseLevel,
            m_settings.warmup ? "true" : "false", m_settings.gatedGain ? "true" : "false",
            m_deviceRate, m_deviceChannels, m_inputLatency * 1000, m_outputLatency * 1000, describe(m_micFormat).c_str(), describe(m_speakerFormat).c_str(),
            m_holdSamples, m_referenceLead * 1000, referenceLead * 1000,
            (unsigned long long)m_speakerCallbacks.load(), (unsigned long long)m_speakerSilentCallbacks.load(), timing,
            (unsigned long long)m_dumpDropped.load(), m_dumpLimitFrames / processingRate, frames / processingRate);
        fclose(f);
        rename(temporary.c_str(), path.c_str());
    }
    void finishDump()
    {
        if (!m_dumpThread.joinable())
            return;
        {
            std::lock_guard<std::mutex> lock(m_dumpMutex);
            m_dumpStop = true;
        }
        m_dumpWake.notify_all();
        m_dumpThread.join();
        drainDump();
        writeDumpMeta(true);
        for (int s = 0; s < dumpStreams; ++s) {
            if (m_dumpFiles[s])
                fclose(m_dumpFiles[s]);
            m_dumpFiles[s] = nullptr;
            std::vector<float>().swap(m_dumpRing[s]);
        }
        RELEASE_LOG(WebRTC, "BrowsaCallAudioInternalUnit: dump finished in %s (%.1f s)", m_dumpFolder.c_str(), m_dumpRead.load() / processingRate);
        m_dumpFolder.clear();
    }

    std::vector<float> m_dumpRing[dumpStreams];
    FILE* m_dumpFiles[dumpStreams] { nullptr, nullptr, nullptr };
    std::string m_dumpFolder;
    std::thread m_dumpThread;
    std::mutex m_dumpMutex;
    std::condition_variable m_dumpWake;
    bool m_dumpStop { false };
    std::atomic<uint64_t> m_dumpWritten { 0 };
    std::atomic<uint64_t> m_dumpRead { 0 };
    std::atomic<uint64_t> m_dumpDropped { 0 };
    uint64_t m_dumpLimitFrames { 0 };
    time_t m_dumpStartedAt { 0 };
    std::atomic<uint64_t> m_speakerCallbacks { 0 };
    std::atomic<uint64_t> m_speakerSilentCallbacks { 0 };
    Settings m_settings;
    browsa::CallGuard m_guard;
    double m_referenceLead { 0.010 };

    static constexpr double referenceLead = 0.010;
    static constexpr int cleanStartCount = 16;

    AudioDeviceID m_inputDevice { 0 };
    AudioDeviceID m_outputDevice { 0 };
    AudioStreamBasicDescription m_micFormat { };
    AudioStreamBasicDescription m_speakerFormat { };
    AURenderCallbackStruct m_micCallback { };
    AURenderCallbackStruct m_speakerCallback { };
    AudioUnit m_inUnit { nullptr };
    AudioUnit m_outUnit { nullptr };
    bool m_initialized { false };
    bool m_started { false };
    std::atomic<bool> m_muted { false };

    webrtc::scoped_refptr<webrtc::AudioProcessing> m_processing;
    browsa::ClockModel m_speakerClock { processingRate };
    browsa::ClockModel m_micClock { processingRate };
    browsa::SampleRing m_speakerRing;
    browsa::SampleRing m_micRing;
    browsa::SampleRing m_cleanRing;
    browsa::SteeredReader m_referenceReader;
    browsa::SteeredReader m_sideReader;
    uint64_t m_sideFrames { 0 };
    std::vector<std::vector<float>> m_deviceBuffers;
    std::vector<float> m_speakerMono;
    int m_deviceChannels { 1 };
    double m_deviceRate { processingRate };
    double m_inputLatency { 0 };
    double m_outputLatency { 0 };
    double m_micStep { 1 };
    double m_micPosition { 2 };
    double m_holdSamples { 0 };
    double m_deliverStep { 1 };
    double m_deliverPosition { 2 };
    uint64_t m_micIndex { 0 };
    uint64_t m_speakerIndex { 0 };
    uint64_t m_deliveredFrames { 0 };
    uint64_t m_cleanFrames { 0 };
    UInt32 m_pendingDeliver { 0 };
    double m_cleanStart[cleanStartCount] { };
};

} // namespace WebCore

WTF_ALLOW_UNSAFE_BUFFER_USAGE_END

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(MAC) && USE(LIBWEBRTC)
