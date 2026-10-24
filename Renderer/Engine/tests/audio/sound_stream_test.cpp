// What a scene sound decodes to, through the engine's one entry point
// (`CreateSoundStream`), whatever decoder sits behind it. The inputs are
// synthetic and in memory: WAV files written by the test, plus a few tiny
// encoded files in sound_fixture_data.hpp. The expectations were first recorded
// against the FFmpeg decoder that served scene sounds until now, so a decoder
// replacing it has to match them: lengths including a resampled tail, loop
// seams, end of file, and files that must be refused.
#include "audio/sound_fixture_data.hpp"
#include "audio/sound_test_support.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace wallpaper::audio
{
namespace
{

using namespace testing;
using namespace std::chrono_literals;

constexpr float kSqrtHalf = 0.70710678f;

std::vector<uint8_t> Mp3() { return Bytes(fixtures::kMp3Stereo48k); }
std::vector<uint8_t> Ogg() { return Bytes(fixtures::kOggStereo44k); }
std::vector<uint8_t> Flac() { return Bytes(fixtures::kFlacMono48k); }

/// Largest distance between `decoded` and the reference signal at the output
/// rate, over frames [from, frames - to).
double MaxToneError(const std::vector<float>& decoded, uint32_t channels, uint32_t rate,
                    size_t from, size_t to)
{
    double       worst  = 0.0;
    const size_t frames = decoded.size() / channels;
    for (size_t frame = from; frame + to < frames; ++frame) {
        for (uint32_t channel = 0; channel < channels; ++channel) {
            const double ideal = IdealSample(static_cast<double>(frame), channel, rate);
            worst = std::max(worst, std::fabs(static_cast<double>(decoded[frame * channels + channel]) - ideal));
        }
    }
    return worst;
}

// --- WAV: every sample format at both common rates, mono and stereo --------

TEST(SoundStreamTest, WavDecodesToTheStoredSamplesAtItsOwnRate)
{
    for (const auto format : { WavFormat::UInt8, WavFormat::Int16, WavFormat::Int24, WavFormat::Float32 }) {
        for (const uint32_t channels : { 1u, 2u }) {
            for (const uint32_t rate : { 44'100u, 48'000u }) {
                SCOPED_TRACE(::testing::Message() << "bytes " << BytesPerSample(format) << " ch "
                                                  << channels << " rate " << rate);
                const auto decoded = Decode(MakeWav(format, channels, rate, 1000), { channels, rate });
                ASSERT_EQ(decoded.size(), 1000u * channels);
                for (size_t frame = 0; frame < 1000; ++frame) {
                    for (uint32_t channel = 0; channel < channels; ++channel) {
                        const float ideal = IdealSample(static_cast<double>(frame), channel, rate);
                        ASSERT_NEAR(decoded[frame * channels + channel], StoredSample(format, ideal), 1e-6)
                            << "frame " << frame << " channel " << channel;
                    }
                }
            }
        }
    }
}

TEST(SoundStreamTest, TheChunkSizeOfTheReaderDoesNotChangeTheAudio)
{
    for (const auto [rate, device_rate] : { std::pair { 48'000u, 48'000u }, std::pair { 44'100u, 48'000u } }) {
        SCOPED_TRACE(rate);
        const auto bytes = MakeWav(WavFormat::Float32, 2, rate, 1500);
        const auto one   = Decode(bytes, { 2, device_rate }, { .loop = false }, 1);
        const auto many  = Decode(bytes, { 2, device_rate }, { .loop = false }, 97);
        const auto big   = Decode(bytes, { 2, device_rate }, { .loop = false }, 4096);
        ASSERT_FALSE(one.empty());
        EXPECT_EQ(one, many);
        EXPECT_EQ(one, big);
    }
}

TEST(SoundStreamTest, AMetadataChunkBeforeTheAudioIsSkipped)
{
    const auto plain = Decode(MakeWav(WavFormat::Int16, 2, 48'000, 400), { 2, 48'000 });
    const auto tagged =
        Decode(MakeWav(WavFormat::Int16, 2, 48'000, 400, 0, /*extra_chunk=*/true), { 2, 48'000 });
    ASSERT_EQ(plain.size(), 800u);
    EXPECT_EQ(tagged, plain);
}

TEST(SoundStreamTest, StreamPositionOnEntryDoesNotMatter)
{
    auto stream = MemoryStream(MakeWav(WavFormat::Int16, 2, 48'000, 400));
    ASSERT_TRUE(stream->SeekSet(30));
    auto sound = CreateSoundStream(stream, { 2, 48'000 }, { .loop = false });
    ASSERT_NE(sound, nullptr);
    EXPECT_EQ(ReadAll(*sound, { 2, 48'000 }).size(), 800u);
}

// --- channel layout: a sound is remixed to the device ------------------------

TEST(SoundStreamTest, MonoToStereoPlacesTheSoundInBothChannelsAtMinusThreeDecibels)
{
    const auto decoded = Decode(MakeWav(WavFormat::Float32, 1, 48'000, 480), { 2, 48'000 });
    ASSERT_EQ(decoded.size(), 960u);
    for (size_t frame = 0; frame < 480; ++frame) {
        const float source = IdealSample(static_cast<double>(frame), 0, 48'000);
        ASSERT_NEAR(decoded[2 * frame], source * kSqrtHalf, 1e-6) << frame;
        ASSERT_NEAR(decoded[2 * frame + 1], source * kSqrtHalf, 1e-6) << frame;
    }
}

TEST(SoundStreamTest, StereoToMonoSumsTheChannelsAtMinusThreeDecibels)
{
    const auto decoded = Decode(MakeWav(WavFormat::Float32, 2, 48'000, 480), { 1, 48'000 });
    ASSERT_EQ(decoded.size(), 480u);
    for (size_t frame = 0; frame < 480; ++frame) {
        const float sum = IdealSample(static_cast<double>(frame), 0, 48'000) +
                          IdealSample(static_cast<double>(frame), 1, 48'000);
        ASSERT_NEAR(decoded[frame], sum * kSqrtHalf, 1e-6) << frame;
    }
}

// --- resampling to the device rate ----------------------------------------

TEST(SoundStreamTest, ResamplingKeepsTheAuthoredDurationExactlyWhenTheRatioIsWhole)
{
    for (const auto [input_rate, output_rate, input_frames, expected_frames] :
         { std::array<uint32_t, 4> { 12'000, 48'000, 512, 2048 },
           std::array<uint32_t, 4> { 44'100, 48'000, 441, 480 },
           std::array<uint32_t, 4> { 44'100, 48'000, 44'100, 48'000 },
           std::array<uint32_t, 4> { 48'000, 44'100, 480, 441 },
           std::array<uint32_t, 4> { 22'050, 48'000, 441, 960 },
           std::array<uint32_t, 4> { 44'100, 96'000, 441, 960 },
           std::array<uint32_t, 4> { 48'000, 16'000, 441, 147 } }) {
        SCOPED_TRACE(::testing::Message() << input_rate << " -> " << output_rate);
        std::array<float, 2 * 97> output {};
        auto sound = CreateSoundStream(MemoryStream(MakeWav(WavFormat::Int16, 1, input_rate, input_frames)),
                                       { 2, output_rate }, { .loop = false });
        ASSERT_NE(sound, nullptr);
        uint64_t total = 0;
        for (int read = 0; read < 1000; ++read) {
            const auto frames = sound->NextPcmData(output.data(), 97);
            total += frames;
            if (frames == 0) break;
        }
        EXPECT_EQ(total, expected_frames);
        output.fill(1.0f);
        EXPECT_EQ(sound->NextPcmData(output.data(), 97), 0u);
        EXPECT_TRUE(std::all_of(output.begin(), output.end(), [](float s) { return s == 0.0f; }));
    }
}

TEST(SoundStreamTest, ResamplingKeepsTheAuthoredDurationToTheFrameOtherwise)
{
    // The exact length is not a whole number of frames: the tail is rounded to
    // one of its two neighbours, never cut by more.
    for (const auto [input_rate, output_rate] :
         { std::pair { 44'100u, 48'000u }, std::pair { 48'000u, 44'100u },
           std::pair { 22'050u, 48'000u }, std::pair { 48'000u, 16'000u } }) {
        for (const uint32_t frames : { 100u, 1000u, 12'345u, 44'101u }) {
            SCOPED_TRACE(::testing::Message() << input_rate << " -> " << output_rate << ", " << frames);
            const auto decoded =
                Decode(MakeWav(WavFormat::Float32, 1, input_rate, frames), { 1, output_rate });
            const double exact = static_cast<double>(frames) * output_rate / input_rate;
            EXPECT_GE(static_cast<double>(decoded.size()), std::floor(exact));
            EXPECT_LE(static_cast<double>(decoded.size()), std::ceil(exact));
        }
    }
}

TEST(SoundStreamTest, ResamplingKeepsTheToneAndStartsAndEndsWithoutLatency)
{
    struct Case {
        uint32_t input_rate, output_rate;
        double   edge_error;
    };
    for (const auto [input_rate, output_rate, edge_error] :
         { Case { 44'100, 48'000, 0.01 }, Case { 48'000, 44'100, 0.01 }, Case { 22'050, 48'000, 0.05 },
           Case { 48'000, 16'000, 0.05 }, Case { 44'100, 96'000, 0.05 } }) {
        SCOPED_TRACE(::testing::Message() << input_rate << " -> " << output_rate);
        const auto decoded =
            Decode(MakeWav(WavFormat::Float32, 2, input_rate, input_rate), { 2, output_rate });
        ASSERT_GT(decoded.size(), 2u * 1000u);
        // The body is a pure tone to better than -80 dB; the first and last
        // frames, where the filter runs out of input, stay within a few
        // percent of it, so a decoder that delays or truncates fails here.
        EXPECT_LT(MaxToneError(decoded, 2, output_rate, 64, 64), 1e-4);
        EXPECT_LT(MaxToneError(decoded, 2, output_rate, 0, 0), edge_error);
    }
}

// --- loops, end of file ----------------------------------------------------

/// The audio of one pass, then the same stream looping: every cycle, seam
/// included, must be the one pass again.
void ExpectLoopRepeatsOnePassExactly(const std::vector<uint8_t>& bytes, SoundStream::Desc desc)
{
    auto once = CreateSoundStream(MemoryStream(bytes), desc, { .loop = false });
    auto loop = CreateSoundStream(MemoryStream(bytes), desc, { .loop = true });
    ASSERT_NE(once, nullptr);
    ASSERT_NE(loop, nullptr);
    const auto pass = ReadAll(*once, desc);
    ASSERT_FALSE(pass.empty());
    const size_t pass_frames = pass.size() / desc.channels;
    const auto   cycles = ReadAll(*loop, desc, 97, pass_frames * 3 + 200);
    ASSERT_GE(cycles.size(), pass.size() * 3);
    for (size_t index = 0; index < cycles.size(); ++index) {
        ASSERT_EQ(cycles[index], pass[index % pass.size()])
            << "sample " << index << " (cycle " << index / pass.size() << ")";
    }
}

TEST(SoundStreamTest, ALoopIncludesTheCompleteResampledTail)
{
    ExpectLoopRepeatsOnePassExactly(MakeWav(WavFormat::Int16, 1, 12'000, 512), { 2, 48'000 });
    ExpectLoopRepeatsOnePassExactly(MakeWav(WavFormat::Float32, 2, 44'100, 1001), { 2, 48'000 });
    ExpectLoopRepeatsOnePassExactly(MakeWav(WavFormat::Int16, 2, 48'000, 777), { 2, 44'100 });
}

TEST(SoundStreamTest, EncodedSoundsLoopWithoutAGapOrAnOverlap)
{
    ExpectLoopRepeatsOnePassExactly(Mp3(), { 2, 48'000 });
    ExpectLoopRepeatsOnePassExactly(Mp3(), { 2, 44'100 });
    ExpectLoopRepeatsOnePassExactly(Ogg(), { 2, 44'100 });
    ExpectLoopRepeatsOnePassExactly(Ogg(), { 2, 48'000 });
    ExpectLoopRepeatsOnePassExactly(Flac(), { 2, 48'000 });
}

TEST(SoundStreamTest, ASoundThatEndsReportsEndOfFileAndStaysSilent)
{
    auto sound = CreateSoundStream(MemoryStream(MakeWav(WavFormat::Int16, 1, 12'000, 100)),
                                   { 1, 12'000 }, { .loop = false });
    ASSERT_NE(sound, nullptr);
    std::array<float, 64> output {};
    EXPECT_EQ(sound->NextPcmData(output.data(), 64), 64u);
    // The last read is short: the frames that exist, then silence.
    output.fill(1.0f);
    EXPECT_EQ(sound->NextPcmData(output.data(), 64), 36u);
    EXPECT_TRUE(std::any_of(output.begin(), output.begin() + 36, [](float s) { return s != 0.0f; }));
    EXPECT_TRUE(std::all_of(output.begin() + 36, output.end(), [](float s) { return s == 0.0f; }));
    for (int again = 0; again < 4; ++again) {
        output.fill(1.0f);
        EXPECT_EQ(sound->NextPcmData(output.data(), 64), 0u);
        EXPECT_TRUE(std::all_of(output.begin(), output.end(), [](float s) { return s == 0.0f; }));
    }
}

TEST(SoundStreamTest, ASoundWithoutAudioEndsEvenWhenLooping)
{
    auto sound = CreateSoundStream(MemoryStream(MakeWav(WavFormat::Int16, 1, 48'000, 0)),
                                   { 1, 48'000 }, { .loop = true });
    // Refused up front or empty from the first read: either way it must not spin.
    if (sound == nullptr) return;
    std::array<float, 64> output {};
    EXPECT_EQ(sound->NextPcmData(output.data(), 64), 0u);
}

// --- compressed formats ----------------------------------------------------

/// Compares a decoded fixture against the values recorded when the tests were
/// written: every 16th frame, and the last 8.
void ExpectMatchesGolden(const std::vector<float>& decoded, const std::int16_t* golden,
                         size_t golden_count, double tolerance)
{
    constexpr uint32_t channels = 2;
    const size_t       frames   = decoded.size() / channels;
    size_t             next     = 0;
    auto compare = [&](size_t frame) {
        for (uint32_t channel = 0; channel < channels; ++channel) {
            ASSERT_LT(next, golden_count);
            ASSERT_NEAR(decoded[frame * channels + channel], static_cast<double>(golden[next]) / 32768.0, tolerance)
                << "frame " << frame << " channel " << channel;
            ++next;
        }
    };
    for (size_t frame = 0; frame < frames; frame += fixtures::kGoldenStride) compare(frame);
    for (size_t frame = frames - fixtures::kGoldenTail; frame < frames; ++frame) compare(frame);
    EXPECT_EQ(next, golden_count);
}

TEST(SoundStreamTest, Mp3DecodesToItsEncodedLengthAndAlignment)
{
    // The file carries a gapless tag: the decoder delay and the padding of the
    // last frame are trimmed, so the length is the 12000 frames that were
    // encoded and the tone starts at its first frame.
    const auto decoded = Decode(Mp3(), { 2, 48'000 });
    ASSERT_EQ(decoded.size(), 2u * 12'000u);
    ExpectMatchesGolden(decoded, fixtures::kMp3Golden, std::size(fixtures::kMp3Golden), 5e-4);
    // And it is the tone that was encoded, within what a 64 kb/s encoder keeps.
    EXPECT_LT(MaxToneError(decoded, 2, 48'000, 2400, 2400), 0.04);
}

TEST(SoundStreamTest, Mp3IsRemixedAndResampledToTheDevice)
{
    EXPECT_EQ(Decode(Mp3(), { 1, 48'000 }).size(), 12'000u);
    EXPECT_EQ(Decode(Mp3(), { 2, 44'100 }).size(), 2u * 11'025u);
    const auto stereo = Decode(Mp3(), { 2, 48'000 });
    const auto mono   = Decode(Mp3(), { 1, 48'000 });
    ASSERT_EQ(mono.size() * 2, stereo.size());
    for (size_t frame = 0; frame < mono.size(); ++frame) {
        ASSERT_NEAR(mono[frame], (stereo[2 * frame] + stereo[2 * frame + 1]) * kSqrtHalf, 1e-5) << frame;
    }
}

TEST(SoundStreamTest, OggVorbisDecodesToTheLengthOfItsLastGranule)
{
    // The last Ogg page says 11072 frames. (FFmpeg decoded all of the last block,
    // 11264, which a loop would play as 192 frames of extra tail.)
    const auto decoded = Decode(Ogg(), { 2, 44'100 });
    ASSERT_EQ(decoded.size(), 2u * 11'072u);
    ExpectMatchesGolden(decoded, fixtures::kOggGolden, std::size(fixtures::kOggGolden), 5e-4);
}

TEST(SoundStreamTest, OggVorbisIsResampledToTheDevice)
{
    const auto decoded = Decode(Ogg(), { 2, 48'000 });
    const double exact = 11'072.0 * 48'000.0 / 44'100.0;
    EXPECT_GE(static_cast<double>(decoded.size() / 2), std::floor(exact));
    EXPECT_LE(static_cast<double>(decoded.size() / 2), std::ceil(exact));
}

TEST(SoundStreamTest, FlacDecodesLosslessly)
{
    const auto decoded = Decode(Flac(), { 1, 48'000 });
    ASSERT_EQ(decoded.size(), 2400u);
    // Written from the reference signal rounded to 16 bits.
    EXPECT_LT(MaxToneError(decoded, 1, 48'000, 0, 0), 5e-5);
    EXPECT_EQ(Decode(Flac(), { 2, 44'100 }).size(), 2u * 2205u);
}

// --- input that must be refused or cut short -------------------------------

TEST(SoundStreamTest, InputThatIsNotAudioIsRefused)
{
    std::vector<uint8_t> noise(4096);
    for (size_t index = 0; index < noise.size(); ++index) {
        noise[index] = static_cast<uint8_t>((index * 2'654'435'761u) >> 13u);
    }
    const auto wav = MakeWav(WavFormat::Int16, 1, 48'000, 500);
    for (const auto& bytes : { std::vector<uint8_t> {}, std::vector<uint8_t> { 1, 2, 3, 4 }, noise,
                               std::vector<uint8_t>(wav.begin(), wav.begin() + 20) }) {
        SCOPED_TRACE(bytes.size());
        EXPECT_EQ(CreateSoundStream(MemoryStream(bytes), { 2, 48'000 }), nullptr);
    }
    EXPECT_EQ(CreateSoundStream(nullptr, { 2, 48'000 }), nullptr);
}

TEST(SoundStreamTest, AFileCutShortPlaysWhatIsThere)
{
    // A WAV whose headers claim 2000 frames over 500 that exist.
    const auto cut = Decode(MakeWav(WavFormat::Int16, 1, 48'000, 500, 2000), { 1, 48'000 });
    EXPECT_EQ(cut.size(), 500u);

    auto mp3 = Mp3();
    mp3.resize(mp3.size() / 2);
    const auto half = Decode(mp3, { 2, 48'000 });
    EXPECT_GT(half.size(), 2u * 3000u);
    EXPECT_LT(half.size(), 2u * 12'000u);
}

TEST(SoundStreamTest, AnOggCutInsideItsHeadersIsRefused)
{
    auto ogg = Ogg();
    ogg.resize(ogg.size() / 2);
    EXPECT_EQ(CreateSoundStream(MemoryStream(ogg), { 2, 44'100 }), nullptr);
}

// --- through the output pipeline ---------------------------------------------

/// Forwards a decoded stream and records what the output worker pulled from it.
class TapStream final : public SoundStream {
public:
    explicit TapStream(std::unique_ptr<SoundStream> inner): m_inner(std::move(inner)) {}

    uint64_t NextPcmData(void* data, uint32_t frames) override
    {
        const auto read = m_inner->NextPcmData(data, frames);
        m_frames.fetch_add(read, std::memory_order_relaxed);
        m_calls.fetch_add(1, std::memory_order_relaxed);
        if (read == 0) m_ended.store(true, std::memory_order_relaxed);
        return read;
    }
    void PassDesc(const Desc& desc) override
    {
        m_inner->PassDesc(desc);
        std::lock_guard lock { m_mutex };
        m_desc = desc;
    }

    uint64_t Frames() const { return m_frames.load(std::memory_order_relaxed); }
    bool     Ended() const { return m_ended.load(std::memory_order_relaxed); }
    Desc     DeviceDesc() const
    {
        std::lock_guard lock { m_mutex };
        return m_desc;
    }

private:
    std::unique_ptr<SoundStream> m_inner;
    mutable std::mutex           m_mutex;
    Desc                         m_desc {};
    std::atomic<uint64_t>        m_frames { 0 };
    std::atomic<uint64_t>        m_calls { 0 };
    std::atomic<bool>            m_ended { false };
};

TEST(SoundStreamTest, TheOutputWorkerPlaysAScenesSoundOnceToItsEnd)
{
    // The worker pulls from the stream on its own thread whether or not anything
    // listens: the null backend discards the audio, so nothing is ever heard.
    for (const auto& bytes : { Mp3(), Ogg(), MakeWav(WavFormat::Int16, 1, 44'100, 9'000) }) {
        SoundManager manager(SoundManager::OutputBackend::Null);
        manager.SetMuted(true);
        auto tap = std::make_shared<TapStream>(
            CreateSoundStream(MemoryStream(bytes), { 2, 48'000 }, { .loop = false }));
        manager.MountStream(tap);
        manager.Play();
        for (int wait = 0; wait < 100 && !tap->Ended(); ++wait) std::this_thread::sleep_for(20ms);
        ASSERT_TRUE(tap->Ended());
        const auto desc = tap->DeviceDesc();
        ASSERT_GT(desc.channels, 0u);
        ASSERT_GT(desc.sampleRate, 0u);
        // Whatever device layout the null backend reports, the sound arrives
        // once, complete, at that layout's rate.
        const auto decoded = Decode(bytes, { desc.channels, desc.sampleRate });
        EXPECT_EQ(tap->Frames(), decoded.size() / desc.channels);
        EXPECT_FALSE(manager.OutputStarted());
    }
}

} // namespace
} // namespace wallpaper::audio
