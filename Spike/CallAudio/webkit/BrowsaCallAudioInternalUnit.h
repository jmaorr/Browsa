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
#pragma once

#if ENABLE(MEDIA_STREAM) && PLATFORM(MAC) && USE(LIBWEBRTC)

#include "CoreAudioCaptureUnit.h"
#include "Logging.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <wtf/TZoneMallocInlines.h>

#include <pal/cf/AudioToolboxSoftLink.h>

// The timing half is shared with Spike/CallAudio/core (AudioTimeline.h), plain C++ with raw buffers.
WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
#include "BrowsaAudioTimeline.h"
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
        m_deliverStep = processingRate / m_micFormat.mSampleRate;
        m_deliverPosition = 2;
        m_deliveredFrames = 0;
        // The reference a microphone frame needs must already have been handed to the speakers. Their
        // buffering gives that much head start; where it doesn't, hold the microphone back a touch.
        m_holdSamples = std::max(0.0, referenceLead - (m_inputLatency + m_outputLatency) + 0.003) * m_deviceRate;

        webrtc::AudioProcessing::Config config;
        config.pipeline.maximum_internal_processing_rate = 48000;
        config.high_pass_filter.enabled = true;
        config.echo_canceller.enabled = true;
        config.noise_suppression.enabled = true;
        config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;
        config.gain_controller2.enabled = true;
        config.gain_controller2.adaptive_digital.enabled = true;
        // libwebrtc's defaults allow 50 dB of gain and room noise up to -50 dBFS; on an open-speaker call that
        // lifts the room and the canceller's leftovers too. Calls need a voice brought up, not a room.
        config.gain_controller2.adaptive_digital.max_gain_db = 30;
        config.gain_controller2.adaptive_digital.max_output_noise_level_dbfs = -60;
        m_processing = webrtc::BuiltinAudioProcessingBuilder(config).Build(webrtc::CreateEnvironment());
        if (!m_processing) {
            uninitialize();
            return kAudioUnitErr_FailedInitialization;
        }

        RELEASE_LOG(WebRTC, "BrowsaCallAudioInternalUnit ready: microphone %.0f Hz x%d (latency %.1f ms), speakers %.0f Hz x%d (latency %.1f ms), WebKit microphone format %.0f Hz",
            m_deviceRate, m_deviceChannels, m_inputLatency * 1000, m_speakerFormat.mSampleRate, (int)m_speakerFormat.mChannelsPerFrame, m_outputLatency * 1000, m_micFormat.mSampleRate);
        m_initialized = true;
        startDump();
        return noErr;
    }

    OSStatus uninitialize() final
    {
        stop();
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
                m_referenceReader.read(m_speakerRing, reference, frameSize, m_speakerClock.indexAt(start + referenceLead), m_speakerClock.indexAt(end + referenceLead), 0.005 * m_speakerFormat.mSampleRate);
            else
                memset(reference, 0, sizeof(reference));

            dump(clean, reference);
            const webrtc::StreamConfig stream(48000, 1);
            float* referenceChannels[1] = { reference };
            float* cleanChannels[1] = { clean };
            m_processing->ProcessReverseStream(referenceChannels, stream, stream, referenceChannels);
            m_processing->set_stream_delay_ms(static_cast<int>(referenceLead * 1000));
            m_processing->ProcessStream(cleanChannels, stream, stream, cleanChannels);
            if (m_muted)
                memset(clean, 0, sizeof(clean));
            dumpClean(clean);
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
    // The raw mic, the reference and what was sent, 48 kHz, plus what WebKit negotiated, written when the unit
    // stops, so a call can be replayed offline (tools/audio-bench, apm-replay). Value: a folder, or 1 for the
    // process's temporary folder. Up to the first 10 minutes of each session.
    static const char* dumpSetting()
    {
        const char* value = getenv("BROWSA_CALL_AUDIO_DUMP");
        return value && *value && strcmp(value, "0") ? value : nullptr;
    }
    void startDump()
    {
        if (!dumpSetting())
            return;
        const size_t capacity = 600 * 48000;
        for (auto* v : { &m_dumpMic, &m_dumpRef, &m_dumpClean })
            v->assign(capacity, 0.f);
        m_dumpFrames = 0;
        m_dumpCleanFrames = 0;
        m_speakerCallbacks = 0;
        m_speakerSilentCallbacks = 0;
    }
    void dump(const float* mic, const float* reference)
    {
        if (m_dumpMic.empty() || m_dumpFrames + frameSize > m_dumpMic.size())
            return;
        memcpy(m_dumpMic.data() + m_dumpFrames, mic, frameSize * sizeof(float));
        memcpy(m_dumpRef.data() + m_dumpFrames, reference, frameSize * sizeof(float));
        m_dumpFrames += frameSize;
    }
    void dumpClean(const float* clean)
    {
        if (m_dumpClean.empty() || m_dumpCleanFrames + frameSize > m_dumpClean.size())
            return;
        memcpy(m_dumpClean.data() + m_dumpCleanFrames, clean, frameSize * sizeof(float));
        m_dumpCleanFrames += frameSize;
    }
    static void writeFloatWav(const std::string& path, const std::vector<float>& data, size_t frames)
    {
        FILE* f = fopen(path.c_str(), "wb");
        if (!f)
            return;
        const uint32_t bytes = static_cast<uint32_t>(frames * 4), rate = 48000, byteRate = rate * 4, riff = 36 + bytes, fmtLength = 16;
        const uint16_t tag = 3, channels = 1, align = 4, bits = 32;
        fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtLength, 4, 1, f);
        fwrite(&tag, 2, 1, f); fwrite(&channels, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&byteRate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&bytes, 4, 1, f); fwrite(data.data(), 4, frames, f);
        fclose(f);
    }
    void finishDump()
    {
        const char* setting = dumpSetting();
        if (!setting || m_dumpMic.empty() || !m_dumpFrames)
            return;
        std::string folder = setting;
        if (folder == "1") {
            char temp[PATH_MAX] = { };
            confstr(_CS_DARWIN_USER_TEMP_DIR, temp, sizeof(temp));
            folder = temp;
        }
        folder += "/browsa-call-audio-" + std::to_string(getpid()) + "-" + std::to_string(time(nullptr));
        if (mkdir(folder.c_str(), 0755)) {
            RELEASE_LOG_ERROR(WebRTC, "BrowsaCallAudioInternalUnit: can't write the dump to %s (errno %d)", folder.c_str(), errno);
            return;
        }
        // ref.wav is the reference each 10 ms of raw.wav was cancelled against: the bench's replay format.
        writeFloatWav(folder + "/raw.wav", m_dumpMic, m_dumpFrames);
        writeFloatWav(folder + "/ref.wav", m_dumpRef, m_dumpFrames);
        writeFloatWav(folder + "/sent.wav", m_dumpClean, m_dumpCleanFrames);
        auto describe = [](const AudioStreamBasicDescription& d) {
            char text[200];
            snprintf(text, sizeof(text), "{\"rate\": %.0f, \"channels\": %u, \"bits\": %u, \"float\": %s, \"interleaved\": %s}", d.mSampleRate, (unsigned)d.mChannelsPerFrame,
                (unsigned)d.mBitsPerChannel, (d.mFormatFlags & kAudioFormatFlagIsFloat) ? "true" : "false", (d.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? "false" : "true");
            return std::string(text);
        };
        if (FILE* f = fopen((folder + "/meta.json").c_str(), "w")) {
            fprintf(f, "{\"mode\": \"webkit-unit\", \"inputRate\": %.0f, \"inputChannels\": %d, \"inputLatencyMs\": %.2f, \"outputLatencyMs\": %.2f,\n"
                " \"webkitMicFormat\": %s,\n \"webkitSpeakerFormat\": %s,\n \"holdSamples\": %.1f, \"referenceLeadMs\": %.1f,\n"
                " \"speakerCallbacks\": %llu, \"speakerSilentCallbacks\": %llu, \"referenceResyncs\": %d, \"referenceMisses\": %d,\n"
                " \"speakerClockRate\": %.3f, \"micClockRate\": %.3f, \"capturedSeconds\": %.2f}\n",
                m_deviceRate, m_deviceChannels, m_inputLatency * 1000, m_outputLatency * 1000, describe(m_micFormat).c_str(), describe(m_speakerFormat).c_str(),
                m_holdSamples, referenceLead * 1000, (unsigned long long)m_speakerCallbacks.load(), (unsigned long long)m_speakerSilentCallbacks.load(),
                m_referenceReader.resyncs, m_referenceReader.misses, m_speakerClock.rate(), m_micClock.rate(),
                m_dumpFrames / 48000.0);
            fclose(f);
        }
        RELEASE_LOG(WebRTC, "BrowsaCallAudioInternalUnit: dump written to %s", folder.c_str());
        for (auto* v : { &m_dumpMic, &m_dumpRef, &m_dumpClean })
            std::vector<float>().swap(*v);
    }

    std::vector<float> m_dumpMic, m_dumpRef, m_dumpClean;
    size_t m_dumpFrames { 0 };
    size_t m_dumpCleanFrames { 0 };
    std::atomic<uint64_t> m_speakerCallbacks { 0 };
    std::atomic<uint64_t> m_speakerSilentCallbacks { 0 };

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
