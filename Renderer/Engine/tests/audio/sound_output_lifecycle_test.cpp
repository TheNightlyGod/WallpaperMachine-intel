#include "Audio/SoundManager.h"

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <thread>

namespace wallpaper::audio
{
namespace
{

using namespace std::chrono_literals;

// Counts how many frames the output pipeline pulled, so the test can see
// whether playback advanced.
class CountingStream final : public SoundStream {
public:
    uint64_t NextPcmData(void* data, uint32_t frame_count) override {
        auto* out = static_cast<float*>(data);
        for (uint32_t i = 0; i < frame_count * m_channels; i++) out[i] = 0.25f;
        m_frames.fetch_add(frame_count, std::memory_order_relaxed);
        return frame_count;
    }
    void PassDesc(const Desc& desc) override { m_channels = desc.channels; }

    uint64_t Frames() const { return m_frames.load(std::memory_order_relaxed); }

private:
    uint32_t              m_channels { 0 };
    std::atomic<uint64_t> m_frames { 0 };
};

// The sound-manager calls MainHandler::loadScene makes for a scene
// (primeSoundPlayback on the first load, then UnMountAll).
void LoadScene(SoundManager& sm, bool first_load) {
    if (first_load) sm.Play();
    sm.UnMountAll();
}

// Waits until the stream stops being read (ring buffer full, nothing
// consuming it). Returns false if it keeps advancing.
bool StreamSettles(const CountingStream& stream) {
    uint64_t last = stream.Frames();
    for (int i = 0; i < 40; i++) {
        std::this_thread::sleep_for(50ms);
        const uint64_t now = stream.Frames();
        if (now == last) return true;
        last = now;
    }
    return false;
}

bool StreamAdvances(const CountingStream& stream) {
    const uint64_t start = stream.Frames();
    for (int i = 0; i < 40; i++) {
        std::this_thread::sleep_for(50ms);
        if (stream.Frames() > start) return true;
    }
    return false;
}

TEST(SoundOutputLifecycleTest, DeviceRunsOnlyWithChannelsWhilePlayingUnmuted) {
    SoundManager sm(SoundManager::OutputBackend::Null);
    EXPECT_FALSE(sm.OutputStarted()) << "after construction";

    sm.SetMuted(true);
    EXPECT_FALSE(sm.OutputStarted()) << "muted with no channels";
    sm.SetMuted(false);
    EXPECT_FALSE(sm.OutputStarted()) << "unmuted with no channels";

    LoadScene(sm, true);
    EXPECT_FALSE(sm.OutputStarted()) << "load without sound layers";

    auto stream = std::make_shared<CountingStream>();
    sm.MountStream(stream);
    EXPECT_TRUE(sm.OutputStarted()) << "mounted, playing, unmuted";
    EXPECT_TRUE(StreamAdvances(*stream));

    sm.Pause();
    EXPECT_FALSE(sm.OutputStarted()) << "paused";
    ASSERT_TRUE(StreamSettles(*stream));
    const auto paused_frames = stream->Frames();
    std::this_thread::sleep_for(150ms);
    EXPECT_EQ(stream->Frames(), paused_frames) << "stream position frozen while paused";

    sm.Play();
    EXPECT_TRUE(sm.OutputStarted()) << "resumed";
    EXPECT_TRUE(StreamAdvances(*stream));

    sm.SetMuted(true);
    EXPECT_FALSE(sm.OutputStarted()) << "muted";
    ASSERT_TRUE(StreamSettles(*stream));
    const auto muted_frames = stream->Frames();
    std::this_thread::sleep_for(150ms);
    EXPECT_EQ(stream->Frames(), muted_frames) << "stream position frozen while muted";

    sm.SetMuted(false);
    EXPECT_TRUE(sm.OutputStarted()) << "unmuted";

    sm.UnMountAll();
    EXPECT_FALSE(sm.OutputStarted()) << "after UnMountAll";
    sm.Pause();
    sm.Play();
    EXPECT_FALSE(sm.OutputStarted()) << "play with no channels";

    sm.MountStream(std::make_shared<CountingStream>());
    EXPECT_TRUE(sm.OutputStarted()) << "remount while playing";
    LoadScene(sm, false);
    EXPECT_FALSE(sm.OutputStarted()) << "reload unmounts previous layers";
}

TEST(SoundOutputLifecycleTest, MutedHostNeverStartsOutput) {
    // Lock-screen extension: muted before the scene loads.
    SoundManager sm(SoundManager::OutputBackend::Null);
    sm.SetMuted(true);
    EXPECT_FALSE(sm.OutputStarted());
    LoadScene(sm, true);
    sm.MountStream(std::make_shared<CountingStream>());
    EXPECT_FALSE(sm.OutputStarted());
    sm.Pause();
    sm.Play();
    EXPECT_FALSE(sm.OutputStarted());
}

TEST(SoundOutputLifecycleTest, PausedBeforeMountDoesNotStartOutput) {
    SoundManager sm(SoundManager::OutputBackend::Null);
    auto         stream = std::make_shared<CountingStream>();
    sm.MountStream(stream);
    EXPECT_FALSE(sm.OutputStarted()) << "never played";
    sm.Play();
    EXPECT_TRUE(sm.OutputStarted());
}

} // namespace
} // namespace wallpaper::audio
