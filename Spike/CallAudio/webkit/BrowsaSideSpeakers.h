/*
 * Browsa call audio: call audio WebKit plays on a speaker the engine doesn't drive.
 *
 * The engine (BrowsaCallAudioInternalUnit.h) plays the call on the Mac's default output and uses exactly
 * what it played as the echo canceller's reference. When a page picks another speaker (setSinkId, e.g.
 * Meet's speaker menu), WebKit plays the call itself on that device
 * (AudioMediaStreamTrackRendererInternalUnit.cpp), outside the engine, and without this the canceller
 * would never hear it. That renderer copies what it plays here, stamped with the host time it meets the
 * air, and the engine adds it to the reference at the moments each microphone frame covers. Host time
 * reconciles the two device clocks, as it does for the engine's own speakers (BrowsaAudioTimeline.h).
 *
 * Only while the engine runs (listening), and one renderer at a time (the first to claim it; WebKit uses
 * one renderer per output device, and a call plays on one).
 */
#pragma once

#if PLATFORM(MAC)

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <algorithm>
#include <atomic>
#include <mach/mach_time.h>

// Plain C++ on raw audio buffers, like the rest of Browsa's call audio.
WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN

#include "BrowsaAudioTimeline.h"

namespace browsa {

class SideSpeakers {
public:
    static SideSpeakers& shared()
    {
        static SideSpeakers& instance = *new SideSpeakers; // never destroyed: audio threads may outlive exit
        return instance;
    }

    // ---------- the engine ----------
    void setListening(bool on) { m_listening.store(on, std::memory_order_release); }
    bool listening() const { return m_listening.load(std::memory_order_acquire); }
    const SampleRing& ring() const { return m_ring; }
    const ClockModel& clock() const { return m_clock; }
    // Whether anything played on a side speaker around `time` (host seconds): the newest sample written
    // meets the air no more than a second before it.
    bool playedAround(double time) const
    {
        if (!m_clock.valid())
            return false;
        return m_clock.timeOf(static_cast<double>(m_ring.written())) > time - 1.0;
    }

    // ---------- WebKit's renderer for a chosen speaker ----------
    // Main thread, when it starts playing. False when another renderer already has it.
    bool claim(const void* owner, AudioDeviceID device, double sampleRate)
    {
        const void* expected = nullptr;
        if (!m_owner.compare_exchange_strong(expected, owner))
            return expected == owner;
        m_latency = outputLatency(device);
        m_clock.reset(sampleRate);
        return true;
    }
    // Main thread, once its audio unit has stopped (no render callback still running).
    void release(const void* owner)
    {
        const void* expected = owner;
        m_owner.compare_exchange_strong(expected, nullptr);
    }
    bool owns(const void* owner) const { return listening() && m_owner.load(std::memory_order_acquire) == owner; }

    // The render thread: what it just handed its device, `frames` samples, the first stamped `stamp`.
    // Float32 only (WebKit's renderer format on the Mac); anything else is left out.
    void write(const AudioBufferList& list, const AudioStreamBasicDescription& format, const AudioTimeStamp& stamp, UInt32 frames, bool silent)
    {
        if (!(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32 || !list.mNumberBuffers)
            return;
        const bool interleaved = !(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
        const UInt32 channels = std::max<UInt32>(1, format.mChannelsPerFrame);
        const double air = hostSeconds((stamp.mFlags & kAudioTimeStampHostTimeValid) ? stamp.mHostTime : mach_absolute_time()) + m_latency;
        m_clock.update(static_cast<double>(m_ring.written()), air);
        float mono[chunk];
        for (UInt32 done = 0; done < frames; ) {
            const UInt32 n = std::min<UInt32>(chunk, frames - done);
            if (silent)
                std::fill(mono, mono + n, 0.f);
            else if (interleaved) {
                const float* samples = static_cast<const float*>(list.mBuffers[0].mData);
                if (!samples || list.mBuffers[0].mDataByteSize < (done + n) * channels * sizeof(float))
                    return;
                for (UInt32 i = 0; i < n; ++i) {
                    float sum = 0;
                    for (UInt32 c = 0; c < channels; ++c)
                        sum += samples[(done + i) * channels + c];
                    mono[i] = sum / channels;
                }
            } else {
                std::fill(mono, mono + n, 0.f);
                for (UInt32 b = 0; b < list.mNumberBuffers; ++b) {
                    const float* samples = static_cast<const float*>(list.mBuffers[b].mData);
                    if (!samples || list.mBuffers[b].mDataByteSize < (done + n) * sizeof(float))
                        return;
                    for (UInt32 i = 0; i < n; ++i)
                        mono[i] += samples[done + i] / list.mNumberBuffers;
                }
            }
            m_ring.write(mono, n);
            done += n;
        }
    }

    // Seconds between a device's output timestamp and the air (0: the default output).
    static double outputLatency(AudioDeviceID device)
    {
        if (!device && !property(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, &device))
            return 0;
        const auto scope = kAudioObjectPropertyScopeOutput;
        UInt32 latency = 0, safety = 0, stream = 0;
        Float64 rate = 48000;
        property(device, kAudioDevicePropertyLatency, scope, &latency);
        property(device, kAudioDevicePropertySafetyOffset, scope, &safety);
        property(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate);
        AudioObjectPropertyAddress address = { kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain };
        AudioStreamID streams[16];
        UInt32 size = sizeof(streams);
        if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, streams) == noErr && size >= sizeof(AudioStreamID))
            property(streams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &stream);
        return (latency + safety + stream) / (rate > 0 ? rate : 48000);
    }

private:
    static constexpr UInt32 chunk = 1024;

    template<typename T> static bool property(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, T* out)
    {
        AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
        UInt32 size = sizeof(T);
        return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, out) == noErr;
    }
    static double hostSeconds(uint64_t hostTime)
    {
        static mach_timebase_info_data_t timebase = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
        return static_cast<double>(hostTime) * timebase.numer / timebase.denom * 1e-9;
    }

    std::atomic<bool> m_listening { false };
    std::atomic<const void*> m_owner { nullptr };
    double m_latency { 0 };
    ClockModel m_clock;
    SampleRing m_ring;
};

} // namespace browsa

WTF_ALLOW_UNSAFE_BUFFER_USAGE_END

#endif // PLATFORM(MAC)
