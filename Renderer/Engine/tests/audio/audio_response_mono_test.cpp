#include "Audio/AudioResponseService.h"
#include "Audio/AudioResponseAnalyzerVdsp.hpp"
#include "support/spectrum_wait.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cmath>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

namespace wallpaper::audio
{

void StopAudioResponseWorkerAndMarkInputStaleForTesting();
void SubmitStaleMonoAudioFramesToWorkerForTesting(
    uint32_t sample_rate,
    uint32_t accepted_frame_count,
    const float* pcm_frames,
    size_t frame_count);
size_t AudioResponseRetainedFrameCountForTesting();

namespace
{

using testing::HasNonZeroAverage64Bin;
using testing::MaxAbsDifference;
using testing::WaitForGeneration;
using testing::WaitForGenerationAfter;
using testing::WaitForSilentGeneration;

constexpr uint32_t kSubmitSampleRate = kAudioResponseSampleRate;
constexpr uint32_t kWindowFrames = kAudioResponseWindowFrames;
// What the capture resampler hands over: a 60th of a second, half a window.
constexpr uint32_t kChunkFrameCount = kWindowFrames / 2u;
constexpr uint32_t kChunkSubmitCount = 2u;
constexpr uint32_t kRetainedFrameCapacity = kSubmitSampleRate * 2u;

std::vector<float> Tone(double hz, float amplitude, size_t frames = kWindowFrames) {
    std::vector<float> pcm(frames);
    for (size_t sample = 0; sample < pcm.size(); ++sample) {
        pcm[sample] = amplitude *
            static_cast<float>(std::sin(2.0 * 3.141592653589793 * hz * sample / kSubmitSampleRate));
    }
    return pcm;
}

AudioSpectrumSnapshot AnalyzeTone(double hz, float amplitude) {
    const auto pcm = Tone(hz, amplitude);
    AudioSpectrumSnapshot spectrum {};
    AnalyzeAudioResponseMonoBlock(pcm.data(), static_cast<uint32_t>(pcm.size()), &spectrum);
    return spectrum;
}

template<size_t Bands>
size_t PeakBand(const std::array<float, Bands>& bands) {
    return static_cast<size_t>(std::distance(bands.begin(), std::max_element(bands.begin(), bands.end())));
}

// Which of Wallpaper Engine's 64 bands answer an octave tone, as measured on
// it (Steam discussion 2592234299529771879): wallpapers are authored against
// this layout, roughly one 23 Hz bin per band in the bass and widening to
// about 15 kHz.
struct MeasuredBand {
    double hz;
    size_t first;
    size_t last;
};
constexpr MeasuredBand kWallpaperEngineBands[] = {
    { 42.0, 0u, 1u },      { 95.0, 2u, 4u },      { 190.0, 5u, 9u },
    { 380.0, 10u, 20u },   { 760.0, 21u, 31u },   { 1520.0, 32u, 37u },
    { 3040.0, 38u, 45u },  { 6080.0, 46u, 54u },  { 12160.0, 55u, 63u },
};

TEST(AudioResponseMonoTest, TonesLandInTheBandsWallpaperEngineMeasures) {
    for (const auto& measured : kWallpaperEngineBands) {
        SCOPED_TRACE(measured.hz);
        const auto spectrum = AnalyzeTone(measured.hz, 0.5f);
        const size_t band = PeakBand(spectrum.average64);
        EXPECT_GE(band, measured.first);
        EXPECT_LE(band, measured.last);
        // A tone at -6 dB on a 48 dB scale, give or take how it splits
        // between neighbouring one-bin bands.
        EXPECT_NEAR(spectrum.average64[band], 0.875f, 0.08f);
        if (measured.hz >= 1000.0) EXPECT_EQ(spectrum.average64.front(), 0.0f);
        for (float value : spectrum.average64) {
            EXPECT_TRUE(std::isfinite(value));
            EXPECT_GE(value, 0.0f);
        }
    }
}

TEST(AudioResponseMonoTest, LevelsSpanFortyEightDecibelsBelowAFullScaleTone) {
    // A full-scale tone reads about 1, and slightly more where a wide band
    // gathers the whole window lobe: Wallpaper Engine's values exceed 1 too.
    const auto full = AnalyzeTone(1500.0, 1.0f);
    const float full_level = full.average64[PeakBand(full.average64)];
    EXPECT_GE(full_level, 0.98f);
    EXPECT_LE(full_level, 1.1f);

    // 24 dB quieter is half the scale lower.
    const auto quieter = AnalyzeTone(1500.0, std::pow(10.0f, -24.0f / 20.0f));
    EXPECT_NEAR(full_level - quieter.average64[PeakBand(quieter.average64)], 0.5f, 0.005f);

    const auto below_floor = AnalyzeTone(1500.0, std::pow(10.0f, -54.0f / 20.0f));
    for (float value : below_floor.average64) EXPECT_EQ(value, 0.0f);
}

TEST(AudioResponseMonoTest, CoarserResolutionsCoverTheSameFrequencies) {
    for (const auto& measured : kWallpaperEngineBands) {
        SCOPED_TRACE(measured.hz);
        const auto spectrum = AnalyzeTone(measured.hz, 0.5f);
        const size_t band = PeakBand(spectrum.average64);
        EXPECT_EQ(PeakBand(spectrum.average32), band / 2u);
        EXPECT_EQ(PeakBand(spectrum.average16), band / 4u);
        EXPECT_GE(spectrum.average16[band / 4u], spectrum.average64[band]);
    }
}

TEST(AudioResponseMonoTest, EachSpectrumStandsAlone) {
    // Wallpaper Engine hands wallpapers each frame's levels as they are and
    // leaves smoothing to them, so a loud block leaves nothing behind.
    const auto loud = Tone(95.0, 1.0f);
    const auto quiet = Tone(3040.0, 0.05f);
    AudioSpectrumSnapshot carried {};
    AnalyzeAudioResponseMonoBlock(loud.data(), kWindowFrames, &carried);
    AnalyzeAudioResponseMonoBlock(quiet.data(), kWindowFrames, &carried);
    AudioSpectrumSnapshot fresh {};
    AnalyzeAudioResponseMonoBlock(quiet.data(), kWindowFrames, &fresh);
    EXPECT_LE(MaxAbsDifference(carried.average64, fresh.average64), 0.00001f);
    for (size_t band = 0; band < fresh.average16.size(); ++band) {
        EXPECT_NEAR(carried.average16[band], fresh.average16[band], 0.00001f);
    }
}

void ResetWaitingWorkerInChild(bool wait_for_stale) {
    // A lost stop wake must fail this child, not leave a joinable thread in the suite.
    alarm(2);
    ResetAudioResponseServiceForTesting();
    std::array<float, kWindowFrames> tone {};
    for (size_t index = 0; index < tone.size(); ++index) {
        tone[index] = 0.25f * std::sin(static_cast<float>(index) * 0.08f);
    }
    const uint32_t frames = wait_for_stale ? tone.size() : 200u;
    if (!SubmitMonoAudioFrames(kSubmitSampleRate, frames, tone.data(), nullptr)) {
        std::_Exit(1);
    }
    if (wait_for_stale) {
        const auto live = WaitForGeneration();
        if (!HasNonZeroAverage64Bin(live)) {
            std::_Exit(2);
        }
        const auto stale = WaitForSilentGeneration(live.generation);
        if (stale.generation <= live.generation || HasNonZeroAverage64Bin(stale)) {
            std::_Exit(3);
        }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    ResetAudioResponseServiceForTesting();
    if (!SubmitMonoAudioFrames(kSubmitSampleRate, tone.size(), tone.data(), nullptr)) {
        std::_Exit(4);
    }
    const auto resumed = WaitForGeneration();
    if (!HasNonZeroAverage64Bin(resumed) || resumed.accepted_frame_count != tone.size()) {
        std::_Exit(5);
    }
    ResetAudioResponseServiceForTesting();
    std::_Exit(0);
}

TEST(AudioResponseMonoTest, ResetInterruptsPartialInputWaitAndAcceptsFreshTone) {
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    ASSERT_EXIT(ResetWaitingWorkerInChild(false), ::testing::ExitedWithCode(0), "");
}

TEST(AudioResponseMonoTest, ResetInterruptsExpiredInputWaitAndAcceptsFreshTone) {
    GTEST_FLAG_SET(death_test_style, "threadsafe");
    ASSERT_EXIT(ResetWaitingWorkerInChild(true), ::testing::ExitedWithCode(0), "");
}

TEST(AudioResponseMonoTest, PartialSubmissionsExtendExpiryUntilACompleteBlockArrives) {
    ResetAudioResponseServiceForTesting();
    std::array<float, kWindowFrames> tone {};
    for (size_t index = 0; index < tone.size(); ++index) {
        tone[index] = 0.25f * std::sin(static_cast<float>(index) * 0.08f);
    }
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, 600, tone.data(), nullptr));
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, 600, tone.data() + 600, nullptr));
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, kWindowFrames - 1200u, tone.data() + 1200, nullptr));
    const auto combined = WaitForGeneration();
    ASSERT_GT(combined.generation, 0u);
    ASSERT_TRUE(HasNonZeroAverage64Bin(combined));

    ResetAudioResponseServiceForTesting();
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, tone.size(), tone.data(), nullptr));
    const auto fresh = WaitForGeneration();
    ASSERT_GT(fresh.generation, 0u);
    EXPECT_LT(MaxAbsDifference(combined.average64, fresh.average64), 0.00001f);
}

TEST(AudioResponseMonoTest, OversizedMonoSubmitIsAcceptedAndAnalyzed) {
    ResetAudioResponseServiceForTesting();

    constexpr uint32_t oversized_frame_count = kRetainedFrameCapacity + 200u;
    std::vector<float> samples(oversized_frame_count, 0.0f);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = std::sin(static_cast<float>(index) * 0.03f);
    }

    std::string error;
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, oversized_frame_count, samples.data(), &error))
        << error;

    auto snapshot = WaitForGeneration();
    EXPECT_EQ(snapshot.sample_rate, kAudioResponseSampleRate);
    EXPECT_EQ(snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(snapshot.accepted_frame_count, oversized_frame_count);
    EXPECT_GT(snapshot.generation, 0u);
    EXPECT_TRUE(HasNonZeroAverage64Bin(snapshot));
}

TEST(AudioResponseMonoTest, StereoSubmitKeepsLeftAndRightSpectraApart) {
    ResetAudioResponseServiceForTesting();

    // Left carries a bass tone, right a treble tone, so a channel collapse
    // would show up as two identical spectra peaking in the same band.
    const auto& bass = kWallpaperEngineBands[1];
    const auto& treble = kWallpaperEngineBands[6];
    constexpr std::size_t kFrames = kWindowFrames;
    const auto left = Tone(bass.hz, 0.25f, kFrames);
    const auto right = Tone(treble.hz, 0.25f, kFrames);
    std::vector<float> stereo(kFrames * 2u, 0.0f);
    for (std::size_t frame = 0; frame < kFrames; ++frame) {
        stereo[frame * 2u] = left[frame];
        stereo[(frame * 2u) + 1u] = right[frame];
    }

    std::string error;
    for (uint32_t submit = 0; submit < 4u; ++submit) {
        ASSERT_TRUE(SubmitAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(kFrames), stereo.data(), &error))
            << error;
    }

    const auto snapshot = WaitForGeneration();
    ASSERT_GT(snapshot.generation, 0u);
    EXPECT_TRUE(snapshot.stereo);
    EXPECT_TRUE(CurrentAudioSpectrumIsStereo());
    EXPECT_NE(snapshot.left64, snapshot.right64);

    const auto left_peak = std::max_element(snapshot.left64.begin(), snapshot.left64.end());
    const auto right_peak = std::max_element(snapshot.right64.begin(), snapshot.right64.end());
    EXPECT_GT(*left_peak, 0.1f);
    EXPECT_GT(*right_peak, 0.1f);
    const auto left_band = static_cast<size_t>(std::distance(snapshot.left64.begin(), left_peak));
    const auto right_band = static_cast<size_t>(std::distance(snapshot.right64.begin(), right_peak));
    EXPECT_GE(left_band, bass.first);
    EXPECT_LE(left_band, bass.last);
    EXPECT_GE(right_band, treble.first);
    EXPECT_LE(right_band, treble.last);

    for (std::size_t band = 0; band < snapshot.average64.size(); ++band) {
        EXPECT_NEAR(
            snapshot.average64[band],
            0.5f * (snapshot.left64[band] + snapshot.right64[band]),
            0.000001f);
    }
}

TEST(AudioResponseMonoTest, MonoSubmitAfterStereoClearsTheStereoFlagAndRejoinsChannels) {
    ResetAudioResponseServiceForTesting();

    constexpr std::size_t kFrames = 2048u;
    std::vector<float> stereo(kFrames * 2u, 0.0f);
    for (std::size_t frame = 0; frame < kFrames; ++frame) {
        const float value = 0.25f * std::sin(static_cast<float>(frame) * 0.08f);
        stereo[frame * 2u] = value;
        stereo[(frame * 2u) + 1u] = -value;
    }

    std::string error;
    ASSERT_TRUE(SubmitAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(kFrames), stereo.data(), &error))
        << error;
    const auto stereo_snapshot = WaitForGeneration();
    ASSERT_GT(stereo_snapshot.generation, 0u);
    ASSERT_TRUE(stereo_snapshot.stereo);

    std::vector<float> mono(kFrames, 0.0f);
    for (std::size_t frame = 0; frame < kFrames; ++frame) {
        mono[frame] = 0.25f * std::sin(static_cast<float>(frame) * 0.08f);
    }
    ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, static_cast<uint32_t>(kFrames), mono.data(), &error))
        << error;

    const auto mono_snapshot = WaitForGenerationAfter(stereo_snapshot.generation, std::chrono::milliseconds(500));
    ASSERT_GT(mono_snapshot.generation, stereo_snapshot.generation);
    EXPECT_FALSE(mono_snapshot.stereo);
    EXPECT_FALSE(CurrentAudioSpectrumIsStereo());
    EXPECT_EQ(mono_snapshot.left64, mono_snapshot.average64);
    EXPECT_EQ(mono_snapshot.right64, mono_snapshot.average64);
    EXPECT_EQ(mono_snapshot.left32, mono_snapshot.average32);
    EXPECT_EQ(mono_snapshot.right32, mono_snapshot.average32);
    EXPECT_EQ(mono_snapshot.left16, mono_snapshot.average16);
    EXPECT_EQ(mono_snapshot.right16, mono_snapshot.average16);
}

TEST(AudioResponseMonoTest, StereoSubmitWithIdenticalChannelsMatchesMonoAnalysis) {
    ResetAudioResponseServiceForTesting();

    std::array<float, kChunkFrameCount * 2u> stereo {};
    for (std::size_t frame = 0; frame < kChunkFrameCount; ++frame) {
        stereo[frame * 2u] = 0.5f;
        stereo[(frame * 2u) + 1u] = 0.5f;
    }

    std::string error;
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitAudioFrames(kSubmitSampleRate, kChunkFrameCount, stereo.data(), &error))
            << error;
    }

    auto stereo_snapshot = WaitForGeneration();

    ResetAudioResponseServiceForTesting();

    std::array<float, kChunkFrameCount> mono {};
    mono.fill(0.5f);

    error.clear();
    for (uint32_t submit = 0; submit < kChunkSubmitCount; ++submit) {
        ASSERT_TRUE(SubmitMonoAudioFrames(kSubmitSampleRate, kChunkFrameCount, mono.data(), &error))
            << error;
    }

    auto mono_snapshot = WaitForGeneration();
    EXPECT_EQ(stereo_snapshot.sample_rate, kAudioResponseSampleRate);
    EXPECT_EQ(stereo_snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(stereo_snapshot.accepted_frame_count, kChunkFrameCount * kChunkSubmitCount);
    EXPECT_GT(stereo_snapshot.generation, 0u);
    EXPECT_EQ(mono_snapshot.sample_rate, kAudioResponseSampleRate);
    EXPECT_EQ(mono_snapshot.last_submit_sample_rate, kSubmitSampleRate);
    EXPECT_EQ(mono_snapshot.accepted_frame_count, kChunkFrameCount * kChunkSubmitCount);
    EXPECT_GT(mono_snapshot.generation, 0u);
    // Two identical channels are still two channels, so the flag stays set even
    // though the analysed spectra coincide.
    EXPECT_TRUE(stereo_snapshot.stereo);
    EXPECT_FALSE(mono_snapshot.stereo);
    EXPECT_EQ(stereo_snapshot.left64, stereo_snapshot.right64);
    EXPECT_EQ(stereo_snapshot.average64, mono_snapshot.average64);
    EXPECT_EQ(mono_snapshot.left64, mono_snapshot.average64);
    EXPECT_EQ(mono_snapshot.right64, mono_snapshot.average64);
}

TEST(AudioResponseMonoTest, CompactedFifoPreservesEveryStereoWindow) {
    ResetAudioResponseServiceForTesting();

    // Chunks that do not divide a window, so windows straddle submissions and
    // the FIFO keeps compacting around a partial window.
    constexpr uint32_t kChunk = 700u;
    constexpr uint32_t kChunks = 49u;
    constexpr uint32_t kTotalFrames = kChunk * kChunks;
    std::vector<float> left(kTotalFrames);
    std::vector<float> right(kTotalFrames);
    std::vector<float> stereo(kTotalFrames * 2u);
    for (uint32_t frame = 0; frame < kTotalFrames; ++frame) {
        const double phase = 2.0 * 3.141592653589793 * frame / kSubmitSampleRate;
        left[frame] = static_cast<float>(0.25 * std::sin(phase * 187.5));
        right[frame] = static_cast<float>(0.25 * std::cos(phase * 1500.0));
        stereo[frame * 2u] = left[frame];
        stereo[frame * 2u + 1u] = right[frame];
    }

    AudioSpectrumSnapshot snapshot {};
    std::string error;
    uint64_t windows = 0u;
    for (uint32_t chunk = 0; chunk < kChunks; ++chunk) {
        ASSERT_TRUE(SubmitAudioFrames(
            kSubmitSampleRate, kChunk, stereo.data() + static_cast<size_t>(chunk) * kChunk * 2u, &error))
            << error;
        if ((chunk + 1u) * kChunk / kWindowFrames == windows) continue;
        SCOPED_TRACE(windows);
        AudioSpectrumSnapshot reference {};
        AnalyzeAudioResponseStereoBlock(left.data() + windows * kWindowFrames,
                                        right.data() + windows * kWindowFrames,
                                        kWindowFrames,
                                        &reference);
        snapshot = WaitForGenerationAfter(windows, std::chrono::milliseconds(500));
        ++windows;
        ASSERT_EQ(snapshot.generation, windows);
        EXPECT_TRUE(snapshot.stereo);
        EXPECT_LE(MaxAbsDifference(snapshot.left64, reference.left64), 0.00001f);
        EXPECT_LE(MaxAbsDifference(snapshot.right64, reference.right64), 0.00001f);
        EXPECT_LE(MaxAbsDifference(snapshot.average64, reference.average64), 0.00001f);
    }

    EXPECT_EQ(windows, 21u);
    EXPECT_EQ(CurrentAudioSpectrumSnapshot().accepted_frame_count, kTotalFrames);
    EXPECT_EQ(AudioResponseRetainedFrameCountForTesting(), kTotalFrames - 21u * kWindowFrames);
}

TEST(AudioResponseMonoTest, StereoCompatibilityWrapperRejectsNonAnalysisSampleRate) {
    ResetAudioResponseServiceForTesting();

    std::array<float, kChunkFrameCount * 2u> stereo {};
    std::string error;

    EXPECT_FALSE(SubmitAudioFrames(12'000u, kChunkFrameCount, stereo.data(), &error));
    EXPECT_NE(error.find("sample_rate"), std::string::npos);
    EXPECT_NE(error.find(std::to_string(kAudioResponseSampleRate)), std::string::npos);
}

} // namespace
} // namespace wallpaper::audio
