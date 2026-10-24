// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#pragma once
#include <memory>
#include <vector>
#include <mutex>
#include <cstdint>
#include <algorithm>
#include <functional>
#include <cstring>
#include <atomic>
#include <utility>

#include "Utils/Logging.h"
#include "Core/NoCopyMove.hpp"
#include "Audio/SampleMath.h"

#define MA_NO_WASAPI
#define MA_NO_DSOUND
#define MA_NO_WINMM
#define MA_NO_ENCODING
// Only the output device is used: sounds are decoded by the project's own path
// (Renderer/Sound), so miniaudio's decoders and the resource manager, node graph and
// engine built on them are left out. The standalone miniaudio test builds the same.
#define MA_NO_DECODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include <miniaudio.h>

namespace miniaudio
{

struct DeviceDesc {
    ma_uint32              phyChannels;
    ma_uint32              sampleRate;
    static const ma_format format { ma_format_f32 };
};

class Channel : NoCopy {
public:
    Channel()          = default;
    virtual ~Channel() = default;

    virtual ma_uint64 NextPcmData(void* pData, ma_uint32 frameCount) = 0;
    virtual void      PassDeviceDesc(const DeviceDesc&)              = 0;
};

class Device : NoCopy {
public:
    // `context` lets tests run on miniaudio's null backend; nullptr keeps the
    // default system context (Core Audio on macOS). The context must outlive
    // the device.
    explicit Device(ma_context* context = nullptr): m_context(context) {}
    ~Device() { UnInit(); }

public:
    // Output IO runs only while it can be heard: at least one channel is
    // mounted, playback is running and output is not muted. The device is
    // initialized lazily by the first MountChannel and kept initialized so a
    // resume is only ma_device_start. Start/stop happen on control threads,
    // never inside data_callback. A stopped device on the default output
    // stays in miniaudio's Core Audio default-device tracking list and is
    // re-initialized on a default-device change even while stopped, so a
    // later start plays on the new default.
    //
    // The callback already produced silence without draining channels while
    // paused or muted, so stopping the device instead is output-identical.
    bool IsInited() const { return m_device.state.value != ma_device_state_uninitialized; }
    bool IsStarted() const { return ma_device_is_started(&m_device); }
    // How many times output has started; a start that failed is not counted.
    uint64_t Starts() const { return m_starts.load(std::memory_order_relaxed); }
    void Start() {
        std::lock_guard<std::mutex> control { m_control_mutex };
        m_running.store(true, std::memory_order_relaxed);
        UpdateOutputLocked();
    }
    void Stop() {
        std::lock_guard<std::mutex> control { m_control_mutex };
        m_running.store(false, std::memory_order_relaxed);
        UpdateOutputLocked();
    }
    float Volume() const { return m_volume.load(std::memory_order_relaxed); }
    bool  Muted() const { return m_muted.load(std::memory_order_relaxed); }
    void  SetMuted(bool v) {
        std::lock_guard<std::mutex> control { m_control_mutex };
        m_muted.store(v, std::memory_order_relaxed);
        UpdateOutputLocked();
    }

    void SetVolume(float v) {
        m_volume.store(wallpaper::audio::ClampVolume(v), std::memory_order_relaxed);
    }
    void MountChannel(std::shared_ptr<Channel> chn) {
        std::lock_guard<std::mutex> control { m_control_mutex };
        if (! IsInited()) InitLocked({});
        if (chn) {
            // The stream learns the layout before the mix can read it; a device that did
            // not open reports zeros, which keeps the stream from starting.
            chn->PassDeviceDesc(GetDesc());
            std::unique_lock<std::mutex> lock { m_mutex };
            m_channels.push_back(std::move(chn));
        }
        UpdateOutputLocked();
    }
    void UnmountAll() {
        std::lock_guard<std::mutex> control { m_control_mutex };
        UnmountAllLocked();
        UpdateOutputLocked();
    }
    DeviceDesc GetDesc() const {
        if (! IsInited()) return { 0, 0 };
        return { m_device.playback.channels, m_device.sampleRate };
    }

private:
    void InitLocked(const DeviceDesc& d) {
        auto config = GenMaDeviceConfig(d);
        if (ma_device_init(m_context, &config, &m_device) != MA_SUCCESS) {
            LOG_ERROR("can't init sound device");
            m_device = {};
            return;
        }
        if (m_device.playback.format != ma_format_f32) {
            LOG_ERROR("wrong playback format");
            ma_device_uninit(&m_device);
            m_device = {};
            return;
        }
        LOG_INFO("sound device inited");
    }
    void UnInit() {
        std::lock_guard<std::mutex> control { m_control_mutex };
        if (IsInited()) {
            LOG_INFO("uninit sound device");
        }
        UnmountAllLocked();
        ma_device_uninit(&m_device); // always do it
    }
    void UnmountAllLocked() {
        std::unique_lock<std::mutex> lock { m_mutex };
        m_channels.clear();
    }
    void UpdateOutputLocked() {
        if (! IsInited()) return;
        bool has_channels = false;
        {
            std::unique_lock<std::mutex> lock { m_mutex };
            has_channels = ! m_channels.empty();
        }
        const bool want = has_channels && m_running.load(std::memory_order_relaxed) &&
                          ! m_muted.load(std::memory_order_relaxed);
        const bool started = IsStarted();
        if (want && ! started) {
            if (ma_device_start(&m_device) != MA_SUCCESS) {
                LOG_ERROR("can't start sound device");
            } else {
                m_starts.fetch_add(1, std::memory_order_relaxed);
            }
        } else if (! want && started) {
            if (ma_device_stop(&m_device) != MA_SUCCESS) {
                LOG_ERROR("can't stop sound device");
            }
        }
    }


private:
    static void data_callback(ma_device* pMaDevice, void* pOutput, const void* pInput,
                              ma_uint32 frameCount) {
        if (pMaDevice == nullptr) return;
        auto* self = static_cast<Device*>(pMaDevice->pUserData);
        if (self != nullptr) self->data_callback(pOutput, pInput, frameCount);
    }
    // One cycle: the output holds silence unless the host is playing, unmuted and the
    // stream list could be read without waiting; MixStreams only adds on top of silence.
    void data_callback(void* pOutput, const void* pInput, ma_uint32 frameCount) {
        (void)pInput;
        if (pOutput == nullptr || ! IsInited()) return;
        const std::size_t width = m_device.playback.channels;
        if (width == 0) return;
        auto* dst = static_cast<float*>(pOutput);
        wallpaper::audio::ClearInterleavedF32(dst, static_cast<std::size_t>(frameCount) * width);
        if (! m_running.load(std::memory_order_relaxed) || m_muted.load(std::memory_order_relaxed))
            return;
        MixStreams(dst, frameCount, width);
    }
    // Adds every mounted stream to dst (already silent). Returns without waiting when a
    // control thread owns the list. Streams that deliver nothing are dropped afterwards.
    void MixStreams(float* dst, ma_uint32 frames, std::size_t width) {
        std::unique_lock<std::mutex> list_lock { m_mutex, std::try_to_lock };
        if (! list_lock.owns_lock() || m_channels.empty()) return;

        const std::size_t samples = static_cast<std::size_t>(frames) * width;
        if (m_scratch.size() < samples) m_scratch.resize(samples);
        float*      tmp  = m_scratch.data();
        const float gain = m_volume.load(std::memory_order_relaxed);

        std::size_t kept = 0;
        for (std::size_t i = 0; i < m_channels.size(); ++i) {
            wallpaper::audio::ClearInterleavedF32(tmp, samples);
            const ma_uint64 delivered = m_channels[i]->NextPcmData(tmp, frames);
            if (delivered == 0) continue; // finished: not carried over
            const std::size_t used = static_cast<std::size_t>(std::min<ma_uint64>(delivered, frames));
            wallpaper::audio::MixInterleavedF32(dst, tmp, used * width, gain);
            if (kept != i) m_channels[kept] = std::move(m_channels[i]);
            ++kept;
        }
        m_channels.resize(kept);
    }
    ma_device_config GenMaDeviceConfig(const DeviceDesc& d) {
        ma_device_config config = ma_device_config_init(ma_device_type_playback);
        // 0 channels and rate 0 mean the system's default output as it is.
        config.playback.format   = DeviceDesc::format;
        config.playback.channels = d.phyChannels;
        config.sampleRate        = d.sampleRate;
        config.dataCallback      = &Device::data_callback;
        config.pUserData         = this;
        return config;
    }

private:
    ma_context*       m_context { nullptr };
    ma_device         m_device {}; // must init c struct
    std::mutex        m_mutex;     // for operating channel vector
    std::mutex        m_control_mutex; // serializes control-thread state changes
    std::atomic<bool> m_running { false };
    std::atomic<uint64_t> m_starts { 0 };

    std::atomic<float> m_volume { 1.0f };
    std::atomic<bool>  m_muted { false };

    std::vector<std::shared_ptr<Channel>> m_channels;
    std::vector<float>                    m_scratch; // one stream's cycle, grown on demand
};

} // namespace miniaudio
