// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "Audio/SoundManager.h"
#include "Audio/SoundStreamFactory.hpp"
#include "miniaudio-wrapper.hpp"
#include "Fs/IBinaryStream.h"
#include "Core/Literals.hpp"
#include "Utils/Logging.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

using namespace wallpaper;
using namespace wallpaper::audio;

// One mounted stream, decoded ahead of the device on its own worker so a slow or failing
// stream never delays the audio thread or the other streams. The decoded audio waits in a
// small set of equal blocks (together just under half a second at the device rate). The
// worker fills a block that nobody reads and then publishes it; the audio thread consumes
// published blocks from the front. Neither side waits for the other.
class Channel_Impl : public miniaudio::Channel {
    static constexpr size_t kBlockCount   = 12;
    static constexpr size_t kBlocksPerSec = 25; // a block is 1/25 s of device time

public:
    explicit Channel_Impl(std::shared_ptr<SoundStream> stream): m_ss { std::move(stream) } {}
    ~Channel_Impl() override { HaltWorker(); }

    ma_uint64 NextPcmData(void* pData, ma_uint32 frameCount) override {
        const size_t width = m_width.load(std::memory_order_relaxed);
        if (pData == nullptr || frameCount == 0 || width == 0) return frameCount;
        float* const dst = static_cast<float*>(pData);

        // The layout owner (PassDeviceDesc) may be rebuilding the blocks: play silence then.
        std::unique_lock<std::mutex> layout { m_layout_mutex, std::try_to_lock };
        size_t                       copied = 0;
        if (layout.owns_lock() && m_width_laid_out == width) copied = Drain(dst, frameCount, width);
        std::fill(dst + copied * width, dst + static_cast<size_t>(frameCount) * width, 0.0f);
        // A block was freed (or the buffer ran dry): wake the sleeping worker. Every cycle
        // that finds room tries again, so a notification skipped because the worker held
        // the mutex is made up one device cycle later.
        if (m_ready.load(std::memory_order_acquire) < kBlockCount) WakeWorker();
        return frameCount;
    }

    void PassDeviceDesc(const miniaudio::DeviceDesc& desc) override {
        HaltWorker();
        if (m_ss) m_ss->PassDesc({ desc.phyChannels, desc.sampleRate });
        const bool usable = desc.phyChannels != 0 && desc.sampleRate != 0;
        {
            std::lock_guard<std::mutex> layout { m_layout_mutex };
            m_ready.store(0, std::memory_order_relaxed);
            m_read_block = m_write_block = m_read_offset = 0;
            m_width_laid_out                            = desc.phyChannels;
            m_block_frames = usable ? std::max<size_t>(desc.sampleRate / kBlocksPerSec, 1) : 0;
            m_storage.assign(usable ? kBlockCount * m_block_frames * desc.phyChannels : 0, 0.0f);
        }
        m_width.store(desc.phyChannels, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> wake { m_wake_mutex };
            m_halt = false;
        }
        if (usable && m_ss) m_worker = std::thread([this] { DecodeBlocks(); });
    }

private:
    // Audio side. Moves up to `want` buffered frames into dst; returns how many.
    size_t Drain(float* dst, size_t want, size_t width) {
        size_t got = 0;
        while (got < want && m_ready.load(std::memory_order_acquire) > 0) {
            const float* src   = m_storage.data() + m_read_block * m_block_frames * width;
            const size_t avail = m_block_frames - m_read_offset;
            const size_t n     = std::min(avail, want - got);
            std::memcpy(dst + got * width, src + m_read_offset * width, n * width * sizeof(float));
            got += n;
            m_read_offset += n;
            if (m_read_offset == m_block_frames) {
                m_read_offset = 0;
                m_read_block  = (m_read_block + 1) % kBlockCount;
                m_ready.fetch_sub(1, std::memory_order_release);
            }
        }
        return got;
    }

    // Never blocks: if the worker holds the mutex it is about to look at the count anyway,
    // and the next audio cycle asks again.
    void WakeWorker() {
        std::unique_lock<std::mutex> wake { m_wake_mutex, std::try_to_lock };
        if (wake.owns_lock()) {
            wake.unlock();
            m_wake.notify_one();
        }
    }

    void HaltWorker() {
        {
            std::lock_guard<std::mutex> wake { m_wake_mutex };
            m_halt = true;
        }
        m_wake.notify_all();
        if (m_worker.joinable()) m_worker.join();
    }

    // Worker thread: runs while the layout is usable. It sleeps, with no timer, while every
    // block is full.
    void DecodeBlocks() {
        const size_t width = m_width_laid_out;
        for (;;) {
            {
                std::unique_lock<std::mutex> wake { m_wake_mutex };
                m_wake.wait(wake, [this] {
                    return m_halt || m_ready.load(std::memory_order_acquire) < kBlockCount;
                });
                if (m_halt) return;
                if (m_ready.load(std::memory_order_acquire) >= kBlockCount) continue;
            }
            float* const slot = m_storage.data() + m_write_block * m_block_frames * width;
            // Whatever the stream does not deliver (a short read, an ended, empty or
            // failing stream) stays silence, and the block still counts as decoded time.
            const size_t read = std::min<size_t>(
                m_ss->NextPcmData(slot, static_cast<uint32_t>(m_block_frames)), m_block_frames);
            std::fill(slot + read * width, slot + m_block_frames * width, 0.0f);
            m_write_block = (m_write_block + 1) % kBlockCount;
            m_ready.fetch_add(1, std::memory_order_release);
        }
    }

    std::shared_ptr<SoundStream> m_ss;

    std::thread m_worker;

    // Wake-up of the worker (stop request and "a block was freed").
    std::mutex              m_wake_mutex;
    std::condition_variable m_wake;
    bool                    m_halt { false };

    // Layout and storage: rebuilt only while the worker is joined.
    std::mutex                m_layout_mutex;
    std::vector<float>        m_storage;
    size_t                    m_block_frames { 0 };
    size_t                    m_width_laid_out { 0 };
    std::atomic<size_t>       m_width { 0 };

    // Block cursors: the reader owns read_*, the worker owns write_block, `ready` links them.
    std::atomic<size_t> m_ready { 0 };
    size_t              m_read_block { 0 };
    size_t              m_read_offset { 0 };
    size_t              m_write_block { 0 };
};

std::unique_ptr<SoundStream>
wallpaper::audio::CreateSoundStream(std::shared_ptr<wallpaper::fs::IBinaryStream> stream,
                                    const SoundStream::Desc&                      desc,
                                    SoundStream::Options options) {
    std::string error;
    auto        sound = CreateSceneSoundStream(std::move(stream), &error, options);
    if (sound == nullptr) {
        LOG_ERROR("failed to create sound stream: %s", error.c_str());
        return nullptr;
    }
    sound->PassDesc(desc);
    return sound;
}

class SoundManager::impl : NoCopy, NoMove {
public:
    explicit impl(OutputBackend backend) {
        if (backend == OutputBackend::Null) {
            const ma_backend backends[] = { ma_backend_null };
            if (ma_context_init(backends, 1, nullptr, &context) == MA_SUCCESS) {
                context_inited = true;
            } else {
                LOG_ERROR("can't init null audio context");
            }
        }
        device.emplace(context_inited ? &context : nullptr);
    }
    ~impl() {
        device.reset();
        if (context_inited) ma_context_uninit(&context);
    }
    ma_context                       context {};
    bool                             context_inited { false };
    std::optional<miniaudio::Device> device;
};

SoundManager::SoundManager(OutputBackend backend): pImpl(std::make_unique<impl>(backend)) {}
SoundManager::~SoundManager() {}

void SoundManager::MountStream(std::unique_ptr<SoundStream>&& ss) {
    MountStream(std::shared_ptr<SoundStream>(std::move(ss)));
}

void SoundManager::MountStream(std::shared_ptr<SoundStream> ss) {
    pImpl->device->MountChannel(std::make_unique<Channel_Impl>(std::move(ss)));
}

void SoundManager::Play() { pImpl->device->Start(); }
void SoundManager::Pause() { pImpl->device->Stop(); }

void  SoundManager::UnMountAll() { pImpl->device->UnmountAll(); }
float SoundManager::Volume() const { return pImpl->device->Volume(); }

bool SoundManager::Muted() const { return pImpl->device->Muted(); }
void SoundManager::SetMuted(bool v) { pImpl->device->SetMuted(v); }
void SoundManager::SetVolume(float v) { pImpl->device->SetVolume(v); }
bool SoundManager::OutputStarted() const { return pImpl->device->IsStarted(); }
uint64_t SoundManager::OutputStarts() const { return pImpl->device->Starts(); }
