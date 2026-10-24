// The audio-response service: what the analysis thread publishes for submitted audio,
// how it treats silence, stalls and oversized input, and how it refuses bad arguments.
// The service is process-wide, so every test resets it first (and again on the way out).
// No audio device is involved: samples are synthesized in memory.
#include "Audio/AudioResponseService.h"
#include "support/allocation_tracking.hpp"
#include "support/spectrum_wait.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

// Test-only entry points of the service (compiled under WESCENE_BUILD_TESTS).
namespace wallpaper::audio
{
void   StopAudioResponseWorkerAndMarkInputStaleForTesting();
void   SubmitStaleMonoAudioFramesToWorkerForTesting(uint32_t sample_rate, uint32_t accepted_frame_count,
                                                    const float* pcm_frames, size_t frame_count);
size_t AudioResponseRetainedFrameCountForTesting();
} // namespace wallpaper::audio

namespace wallpaper::audio
{
namespace
{

using namespace std::chrono_literals;
using testing::HasNonZeroAverage64Bin;
using testing::MaxAbsDifference;
using testing::WaitForGeneration;
using testing::WaitForGenerationAfter;
using testing::WaitForSilentGeneration;

// Resets the service when the test starts and again when it ends, so no analysis thread or
// queued audio outlives the test that made it.
struct CleanService {
    CleanService() { ResetAudioResponseServiceForTesting(); }
    ~CleanService() { ResetAudioResponseServiceForTesting(); }
};

// `count` samples of amplitude * sin(radians_per_sample * i), i counting from `first`.
std::vector<float> Sine(std::size_t count, double radians_per_sample, double amplitude = 1.0,
                        std::size_t first = 0)
{
    std::vector<float> samples(count);
    for (std::size_t i = 0; i < count; ++i) {
        samples[i] = static_cast<float>(amplitude * std::sin(radians_per_sample * double(first + i)));
    }
    return samples;
}

// Submits `samples` as mono in pieces of at most `piece` frames; true if all were accepted.
bool SubmitMonoInPieces(const std::vector<float>& samples, std::size_t piece)
{
    for (std::size_t at = 0; at < samples.size(); at += piece) {
        const auto n = static_cast<uint32_t>(std::min(piece, samples.size() - at));
        if (! SubmitMonoAudioFrames(kAudioResponseSampleRate, n, samples.data() + at, nullptr)) return false;
    }
    return true;
}

// The common test signal: 1600 loud frames, delivered in two halves.
void SubmitLoudWindow()
{
    ASSERT_TRUE(SubmitMonoInPieces(Sine(1600, 0.05), 800));
}

void ExpectChannelsEqualAverage(const AudioSpectrumSnapshot& s)
{
    EXPECT_EQ(s.left64, s.average64);
    EXPECT_EQ(s.right64, s.average64);
    EXPECT_EQ(s.left32, s.average32);
    EXPECT_EQ(s.right32, s.average32);
    EXPECT_EQ(s.left16, s.average16);
    EXPECT_EQ(s.right16, s.average16);
}

// A later signal must not inherit anything from audio that stopped arriving: after
// `before_stall` was fed and the input went quiet, the quiet-then-resumed spectrum of
// `next` has to equal what a service that never saw `before_stall` publishes for it.
void ExpectResumeIgnoresStalledAudio(const std::vector<float>& before_stall, std::size_t piece)
{
    CleanService service;
    ASSERT_TRUE(SubmitMonoInPieces(before_stall, piece));
    const AudioSpectrumSnapshot live = WaitForGeneration();
    ASSERT_GT(live.generation, 0u);
    ASSERT_TRUE(HasNonZeroAverage64Bin(live));
    const AudioSpectrumSnapshot stale = WaitForSilentGeneration(live.generation);
    ASSERT_GT(stale.generation, live.generation);

    const std::vector<float> next = Sine(1600, 0.08, 0.05);
    ASSERT_TRUE(SubmitMonoAudioFrames(kAudioResponseSampleRate, 1600, next.data(), nullptr));
    const AudioSpectrumSnapshot resumed = WaitForGenerationAfter(stale.generation, 500ms);
    EXPECT_GT(resumed.generation, stale.generation);

    ResetAudioResponseServiceForTesting();
    ASSERT_TRUE(SubmitMonoAudioFrames(kAudioResponseSampleRate, 1600, next.data(), nullptr));
    const AudioSpectrumSnapshot fresh = WaitForGeneration();
    EXPECT_GT(fresh.generation, 0u);

    EXPECT_LT(MaxAbsDifference(resumed.average64, fresh.average64), 1e-5f);
}

} // namespace

TEST(AudioResponseMonoTest, MonoSubmitPublishesSnapshotWithMatchingBookkeeping)
{
    CleanService service;
    SubmitLoudWindow();

    const AudioSpectrumSnapshot s = WaitForGeneration();

    EXPECT_EQ(s.sample_rate, 48000u);
    EXPECT_EQ(s.last_submit_sample_rate, 48000u);
    EXPECT_EQ(s.accepted_frame_count, 1600u);
    EXPECT_GT(s.generation, 0u);
    EXPECT_TRUE(HasNonZeroAverage64Bin(s));
    EXPECT_FALSE(s.stereo);
    EXPECT_FALSE(CurrentAudioSpectrumIsStereo());
    ExpectChannelsEqualAverage(s);
}

TEST(AudioResponseMonoTest, InputThatStopsIsPublishedAsSilenceOnce)
{
    CleanService service;
    SubmitLoudWindow();
    const AudioSpectrumSnapshot live = WaitForGeneration();
    ASSERT_GT(live.generation, 0u);
    ASSERT_TRUE(HasNonZeroAverage64Bin(live));

    const AudioSpectrumSnapshot stale = WaitForSilentGeneration(live.generation);

    EXPECT_EQ(stale.generation, live.generation + 1u);
    EXPECT_FALSE(HasNonZeroAverage64Bin(stale));
    ExpectChannelsEqualAverage(stale);
}

TEST(AudioResponseMonoTest, NonFiniteSamplesAreTreatedAsSilence)
{
    CleanService service;
    std::vector<float> junk(1600);
    for (std::size_t i = 0; i < junk.size(); ++i) {
        junk[i] = (i % 2 == 0) ? std::numeric_limits<float>::quiet_NaN()
                               : std::numeric_limits<float>::infinity();
    }
    ASSERT_TRUE(SubmitMonoInPieces(junk, 800));

    const AudioSpectrumSnapshot s = WaitForGeneration();

    EXPECT_GT(s.generation, 0u);
    EXPECT_FALSE(HasNonZeroAverage64Bin(s));
    EXPECT_EQ(s.left64, s.average64);
    EXPECT_EQ(s.right64, s.average64);
}

TEST(AudioResponseMonoTest, DigitalSilenceAfterSignalClearsTheBands)
{
    CleanService service;
    SubmitLoudWindow();
    const AudioSpectrumSnapshot live = WaitForGeneration();
    ASSERT_GT(live.generation, 0u);
    ASSERT_TRUE(HasNonZeroAverage64Bin(live));

    ASSERT_TRUE(SubmitMonoInPieces(std::vector<float>(1600, 0.0f), 800));
    const AudioSpectrumSnapshot quiet = WaitForSilentGeneration(live.generation);

    // The window of zeros itself is the next publication; the stall path is not needed.
    EXPECT_EQ(quiet.generation, live.generation + 1u);
    EXPECT_FALSE(HasNonZeroAverage64Bin(quiet));
    EXPECT_EQ(quiet.left64, quiet.average64);
    EXPECT_EQ(quiet.right64, quiet.average64);
}

TEST(AudioResponseMonoTest, StalledInputLeavesNothingQueuedForTheNextSignal)
{
    // 2300 loud frames: one window is analysed and 700 stay queued when the input stops.
    ExpectResumeIgnoresStalledAudio(Sine(2300, 0.05), 2300);
}

TEST(AudioResponseMonoTest, StalledInputWithNothingQueuedStillResumesCleanly)
{
    ExpectResumeIgnoresStalledAudio(Sine(1600, 0.05), 800);
}

TEST(AudioResponseMonoTest, PartialBlockBeforeAStallIsNotMixedIntoTheResume)
{
    CleanService service;
    const std::vector<float> partial = Sine(1400, 0.75);
    ASSERT_TRUE(SubmitMonoAudioFrames(kAudioResponseSampleRate, 1400, partial.data(), nullptr));
    StopAudioResponseWorkerAndMarkInputStaleForTesting();

    const std::vector<float> next = Sine(1600, 0.08, 0.05);
    ASSERT_TRUE(SubmitMonoAudioFrames(kAudioResponseSampleRate, 1600, next.data(), nullptr));
    const AudioSpectrumSnapshot resumed = WaitForGeneration();
    EXPECT_GT(resumed.generation, 0u);

    ResetAudioResponseServiceForTesting();
    ASSERT_TRUE(SubmitMonoAudioFrames(kAudioResponseSampleRate, 1600, next.data(), nullptr));
    const AudioSpectrumSnapshot fresh = WaitForGeneration();
    EXPECT_GT(fresh.generation, 0u);

    EXPECT_LT(MaxAbsDifference(resumed.average64, fresh.average64), 1e-5f);
}

TEST(AudioResponseMonoTest, WorkerDropsAStaleFullQueueWithoutAnalysingIt)
{
    CleanService service;
    const std::vector<float> tone = Sine(1600, 0.09);

    SubmitStaleMonoAudioFramesToWorkerForTesting(48000, 1600, tone.data(), tone.size());
    const AudioSpectrumSnapshot s = WaitForGenerationAfter(0, 500ms);

    EXPECT_EQ(s.generation, 0u);
    EXPECT_FALSE(HasNonZeroAverage64Bin(s));
    EXPECT_EQ(AudioResponseRetainedFrameCountForTesting(), 0u);
    EXPECT_EQ(s.last_submit_sample_rate, 48000u);
    EXPECT_EQ(s.accepted_frame_count, 1600u);
}

TEST(AudioResponseMonoTest, ChunkSizeDoesNotChangeWhatIsPublished)
{
    CleanService service;
    const std::vector<float> block = Sine(64, 0.15);
    for (int piece = 0; piece < 25; ++piece) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kAudioResponseSampleRate, 64, block.data(), nullptr));
    }

    const AudioSpectrumSnapshot s = WaitForGeneration();

    EXPECT_GT(s.generation, 0u);
    EXPECT_TRUE(HasNonZeroAverage64Bin(s));
    ExpectChannelsEqualAverage(s);
}

TEST(AudioResponseMonoTest, BadArgumentsAreRefusedAndNameTheArgument)
{
    CleanService service;
    const std::vector<float> mono(800, 0.0f);
    const std::vector<float> stereo(1600, 0.0f);

    using Submit = bool (*)(uint32_t, uint32_t, const float*, std::string*);
    struct Entry {
        const char*              name;
        Submit                   submit;
        const std::vector<float>* buffer;
        uint32_t                 frames;
    };
    const Entry entries[] = {
        { "mono", &SubmitMonoAudioFrames, &mono, 800 },
        { "stereo", &SubmitAudioFrames, &stereo, 800 },
    };

    for (const Entry& entry : entries) {
        const float* pcm = entry.buffer->data();
        {
            SCOPED_TRACE(std::string(entry.name) + " zero rate");
            std::string error;
            EXPECT_FALSE(entry.submit(0, entry.frames, pcm, &error));
            EXPECT_NE(error.find("sample_rate"), std::string::npos) << error;
            EXPECT_EQ(CurrentAudioSpectrumSnapshot().accepted_frame_count, 0u);
        }
        {
            SCOPED_TRACE(std::string(entry.name) + " zero frames");
            std::string error;
            EXPECT_FALSE(entry.submit(48000, 0, pcm, &error));
            EXPECT_NE(error.find("frame_count"), std::string::npos) << error;
            EXPECT_EQ(CurrentAudioSpectrumSnapshot().accepted_frame_count, 0u);
        }
        {
            SCOPED_TRACE(std::string(entry.name) + " null buffer");
            std::string error;
            EXPECT_FALSE(entry.submit(48000, entry.frames, nullptr, &error));
            EXPECT_NE(error.find("pcm_frames"), std::string::npos) << error;
            EXPECT_EQ(CurrentAudioSpectrumSnapshot().accepted_frame_count, 0u);
        }
        {
            SCOPED_TRACE(std::string(entry.name) + " no error sink");
            EXPECT_FALSE(entry.submit(0, entry.frames, pcm, nullptr));
            EXPECT_FALSE(entry.submit(48000, 0, pcm, nullptr));
            EXPECT_FALSE(entry.submit(48000, entry.frames, nullptr, nullptr));
            EXPECT_EQ(CurrentAudioSpectrumSnapshot().accepted_frame_count, 0u);
        }
    }
}

TEST(AudioResponseMonoTest, OtherSampleRatesAreRefusedWithTheRequiredRateNamed)
{
    CleanService service;
    const std::vector<float> zeros(800, 0.0f);
    std::string              error;

    EXPECT_FALSE(SubmitMonoAudioFrames(12000, 800, zeros.data(), &error));

    EXPECT_NE(error.find("sample_rate"), std::string::npos) << error;
    EXPECT_NE(error.find("48000"), std::string::npos) << error;
    EXPECT_EQ(CurrentAudioSpectrumSnapshot().accepted_frame_count, 0u);
}

TEST(AudioResponseMonoTest, OversizedStereoSubmitKeepsTheNewestSecondsWithoutAStagingCopy)
{
    CleanService service;
    constexpr std::size_t kKept  = 2u * kAudioResponseSampleRate;   // frames the queue can hold
    constexpr std::size_t kExtra = 400;
    constexpr std::size_t kTotal = kKept + kExtra;

    const auto left_at  = [](std::size_t f) { return static_cast<float>(std::sin(0.03 * double(f))); };
    const auto right_at = [](std::size_t f) { return static_cast<float>(std::cos(0.04 * double(f))); };

    std::vector<float> oversized(kTotal * 2, 0.0f);   // the first kExtra frames are silent
    for (std::size_t f = kExtra; f < kTotal; ++f) {
        oversized[f * 2]     = left_at(f);
        oversized[f * 2 + 1] = right_at(f);
    }

    {
        we_test::AllocationTrackingScope tracking;
        ASSERT_TRUE(SubmitAudioFrames(kAudioResponseSampleRate, static_cast<uint32_t>(kTotal),
                                      oversized.data(), nullptr));
    }
    const std::size_t largest = we_test::LargestTrackedAllocation();
    EXPECT_LE(AudioResponseRetainedFrameCountForTesting(), kKept);

    const AudioSpectrumSnapshot first = WaitForGenerationAfter(59, 500ms);
    EXPECT_EQ(first.generation, 60u);
    EXPECT_EQ(first.sample_rate, 48000u);
    EXPECT_EQ(first.last_submit_sample_rate, 48000u);
    EXPECT_EQ(first.accepted_frame_count, kTotal);
    EXPECT_TRUE(first.stereo);
    EXPECT_TRUE(HasNonZeroAverage64Bin(first));
    EXPECT_EQ(AudioResponseRetainedFrameCountForTesting(), kKept % kAudioResponseWindowFrames);
    // A staged copy of the whole interleaved input would be twice this size.
    EXPECT_LT(largest, kTotal * sizeof(float));

    // The same newest frames, submitted alone, must end on the same final window.
    ResetAudioResponseServiceForTesting();
    const std::vector<float> newest(oversized.begin() + kExtra * 2, oversized.end());
    ASSERT_TRUE(SubmitAudioFrames(kAudioResponseSampleRate, static_cast<uint32_t>(kKept), newest.data(),
                                  nullptr));
    EXPECT_LE(AudioResponseRetainedFrameCountForTesting(), kKept);
    const AudioSpectrumSnapshot second = WaitForGenerationAfter(59, 500ms);
    EXPECT_EQ(second.generation, 60u);
    EXPECT_EQ(second.accepted_frame_count, kKept);
    EXPECT_EQ(AudioResponseRetainedFrameCountForTesting(), 0u);
    EXPECT_EQ(second.left64, first.left64);
    EXPECT_EQ(second.right64, first.right64);
}

} // namespace wallpaper::audio
