// The Ogg Vorbis decoder (stb_vorbis) over an in-memory file: the layout it
// reports, exactly the granule's length however the reads are chunked, a rewind
// that repeats the sound, files cut off at every stage, and the channel order.
#include "Sound/Vorbis/VorbisDecoder.hpp"

#include "vorbis_fixture_data.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace wallpaper::sound
{
namespace
{

constexpr double kPi = 3.14159265358979323846;

std::vector<std::uint8_t> Tone() { return { std::begin(fixtures::kOggTone), std::end(fixtures::kOggTone) }; }

std::unique_ptr<PcmDecoder> Open(std::vector<std::uint8_t> bytes, std::string* error = nullptr)
{
    return OpenVorbisDecoder(media::MakeMemoryByteSource(std::move(bytes)), error);
}

// The fixture's own layout: the identification header alone on the first page, then a
// page whose first packet is the comment header and the rest the setup header.
constexpr std::size_t kSecondPage = 58;

void Append32(std::vector<std::uint8_t>& out, std::uint32_t value)
{
    for (int shift = 0; shift < 32; shift += 8) out.push_back(static_cast<std::uint8_t>(value >> shift));
}

/// A comment header with the given vendor string length and comments, each written as
/// stated (the lengths here are claims, not measured, so a test can lie).
std::vector<std::uint8_t> CommentHeader(std::uint32_t vendorClaim, std::size_t vendorBytes, std::uint32_t countClaim,
                                        const std::vector<std::pair<std::uint32_t, std::size_t>>& comments,
                                        std::uint8_t framing = 1)
{
    std::vector<std::uint8_t> out { 3, 'v', 'o', 'r', 'b', 'i', 's' };
    Append32(out, vendorClaim);
    out.insert(out.end(), vendorBytes, 'v');
    Append32(out, countClaim);
    for (const auto& [length, bytes] : comments) {
        Append32(out, length);
        out.insert(out.end(), bytes, 'c');
    }
    out.push_back(framing);
    return out;
}

std::vector<std::uint8_t> CommentHeader(std::size_t vendor, const std::vector<std::size_t>& comments)
{
    std::vector<std::pair<std::uint32_t, std::size_t>> list;
    for (const auto length : comments) list.emplace_back(static_cast<std::uint32_t>(length), length);
    return CommentHeader(static_cast<std::uint32_t>(vendor), vendor, static_cast<std::uint32_t>(comments.size()), list);
}

void AppendPage(std::vector<std::uint8_t>& out, std::uint8_t flags, const std::vector<std::uint8_t>& table,
                const std::uint8_t* body, std::size_t bodyBytes, const std::vector<std::uint8_t>& original)
{
    const std::uint8_t header[] = { 'O', 'g', 'g', 'S', 0, flags };
    out.insert(out.end(), std::begin(header), std::end(header));
    out.insert(out.end(), 8, 0);                                                    // granule position
    out.insert(out.end(), original.begin() + 14, original.begin() + 18);          // serial number
    out.insert(out.end(), 8, 0);                                                    // sequence number and checksum
    out.push_back(static_cast<std::uint8_t>(table.size()));
    out.insert(out.end(), table.begin(), table.end());
    out.insert(out.end(), body, body + bodyBytes);
}

/// The fixture with its comment header replaced. A comment of 255 bytes or more is
/// laced over several segments; with `split` it also continues on a second page.
std::vector<std::uint8_t> WithComment(const std::vector<std::uint8_t>& comment, bool split = false)
{
    const auto original = Tone();
    const std::size_t segments = original[kSecondPage + 26];
    const std::uint8_t* table = original.data() + kSecondPage + 27;
    const std::size_t   rest_segments = segments - 1;
    const std::size_t   old_comment = table[0];
    const std::uint8_t* rest = table + segments + old_comment;
    std::size_t         rest_bytes = 0;
    for (std::size_t i = 1; i < segments; ++i) rest_bytes += table[i];
    const std::size_t after = kSecondPage + 27 + segments + old_comment + rest_bytes;

    std::vector<std::uint8_t> lacing(comment.size() / 255, 255);
    lacing.push_back(static_cast<std::uint8_t>(comment.size() % 255));
    std::vector<std::uint8_t> out(original.begin(), original.begin() + static_cast<std::ptrdiff_t>(kSecondPage));
    std::vector<std::uint8_t> tail(table + 1, table + 1 + rest_segments);
    if (split && lacing.size() > 1) {
        AppendPage(out, 0, { lacing.begin(), lacing.begin() + 1 }, comment.data(), 255, original);
        std::vector<std::uint8_t> second(lacing.begin() + 1, lacing.end());
        second.insert(second.end(), tail.begin(), tail.end());
        std::vector<std::uint8_t> body(comment.begin() + 255, comment.end());
        body.insert(body.end(), rest, rest + rest_bytes);
        AppendPage(out, 1, second, body.data(), body.size(), original);
    } else {
        std::vector<std::uint8_t> all(lacing);
        all.insert(all.end(), tail.begin(), tail.end());
        std::vector<std::uint8_t> body(comment);
        body.insert(body.end(), rest, rest + rest_bytes);
        AppendPage(out, 0, all, body.data(), body.size(), original);
    }
    out.insert(out.end(), original.begin() + static_cast<std::ptrdiff_t>(after), original.end());
    return out;
}

std::vector<float> ReadAll(PcmDecoder& decoder, std::size_t chunk)
{
    const auto         channels = decoder.format().channels;
    std::vector<float> all;
    std::vector<float> block(chunk * channels);
    while (const auto frames = decoder.read(block.data(), chunk)) {
        all.insert(all.end(), block.begin(), block.begin() + static_cast<std::ptrdiff_t>(frames * channels));
    }
    return all;
}

TEST(VorbisDecoder, ReportsTheFileLayoutAndTheLengthOfItsLastGranule)
{
    std::string error;
    auto        decoder = Open(Tone(), &error);
    ASSERT_NE(decoder, nullptr) << error;
    EXPECT_EQ(decoder->format(), (PcmFormat { 2, 44'100 }));
    const auto samples = ReadAll(*decoder, 512);
    EXPECT_EQ(samples.size(), 2u * 11'072u);
    EXPECT_FALSE(decoder->failed());
    float scratch[8];
    EXPECT_EQ(decoder->read(scratch, 4), 0u);
}

TEST(VorbisDecoder, TheChunkSizeDoesNotChangeTheAudioAndTheToneIsRight)
{
    auto decoder = Open(Tone());
    ASSERT_NE(decoder, nullptr);
    const auto reference = ReadAll(*decoder, 4096);
    for (const std::size_t chunk : { std::size_t { 1 }, std::size_t { 97 }, std::size_t { 1000 } }) {
        ASSERT_TRUE(decoder->rewind());
        EXPECT_EQ(ReadAll(*decoder, chunk), reference) << "chunk " << chunk;
    }
    // Both channels are 440 Hz: the left at 0.5 and the right at half that, in phase.
    double worst = 0.0;
    for (std::size_t frame = 1500; frame + 1500 < 11'072; ++frame) {
        const double left = reference[2 * frame];
        const double right = reference[2 * frame + 1];
        const double ideal = 0.5 * std::sin(2.0 * kPi * 440.0 * static_cast<double>(frame) / 44'100.0);
        worst = std::max({ worst, std::fabs(left - ideal), std::fabs(right - ideal / 2.0) });
    }
    EXPECT_LT(worst, 0.03) << "a 64 kb/s encoder keeps the tone to a few percent";
}

TEST(VorbisDecoder, ARewindRepeatsTheSoundFromItsFirstFrame)
{
    auto decoder = Open(Tone());
    ASSERT_NE(decoder, nullptr);
    std::vector<float> first(2 * 100), skipped(2 * 3000), again(2 * 100);
    ASSERT_EQ(decoder->read(first.data(), 100), 100u);
    ASSERT_EQ(decoder->read(skipped.data(), 3000), 3000u);
    ASSERT_TRUE(decoder->rewind());
    ASSERT_EQ(decoder->read(again.data(), 100), 100u);
    EXPECT_EQ(first, again);
}

TEST(VorbisDecoder, FilesThatAreNotOggVorbisAreRefusedWithAReason)
{
    std::vector<std::uint8_t> noise(4096);
    for (std::size_t index = 0; index < noise.size(); ++index) {
        noise[index] = static_cast<std::uint8_t>((index * 2'654'435'761u) >> 13);
    }
    std::vector<std::uint8_t> ogg_then_noise { 'O', 'g', 'g', 'S' };
    ogg_then_noise.insert(ogg_then_noise.end(), noise.begin(), noise.end());
    for (const auto& bytes : { std::vector<std::uint8_t> {}, std::vector<std::uint8_t> { 'O', 'g', 'g', 'S' }, noise,
                               ogg_then_noise }) {
        std::string error;
        EXPECT_EQ(Open(bytes, &error), nullptr) << bytes.size();
        EXPECT_FALSE(error.empty());
    }
    std::string error;
    EXPECT_EQ(OpenVorbisDecoder(nullptr, &error), nullptr);
    EXPECT_FALSE(error.empty());
}

TEST(VorbisDecoder, AFileCutInsideItsHeadersIsRefused)
{
    auto bytes = Tone();
    for (const std::size_t keep : { std::size_t { 20 }, std::size_t { 80 }, std::size_t { 1500 }, std::size_t { 3000 } }) {
        std::string error;
        EXPECT_EQ(Open({ bytes.begin(), bytes.begin() + static_cast<std::ptrdiff_t>(keep) }, &error), nullptr) << keep;
        EXPECT_FALSE(error.empty());
    }
}

TEST(VorbisDecoder, AFileCutInItsAudioPlaysWhatIsThereAndEndsWithoutFailing)
{
    const auto bytes = Tone();
    std::size_t previous = 0;
    // The setup headers end at 3405 bytes; the audio page follows.
    for (const std::size_t keep : { std::size_t { 3405 }, std::size_t { 3415 }, std::size_t { 3600 }, std::size_t { 4200 },
                                    bytes.size() - 1 }) {
        auto decoder = Open({ bytes.begin(), bytes.begin() + static_cast<std::ptrdiff_t>(keep) });
        ASSERT_NE(decoder, nullptr) << keep;
        const auto frames = ReadAll(*decoder, 700).size() / 2;
        EXPECT_LE(frames, 11'072u) << keep;
        EXPECT_GE(frames, previous) << "more of the file plays at least as much";
        EXPECT_FALSE(decoder->failed()) << keep << ": " << decoder->failure();
        previous = frames;
    }
}

TEST(VorbisDecoder, DamagedFilesNeverCrashAndNeverProduceNonFiniteSamples)
{
    // A fixed pseudo-random walk over the file: one byte changed per run, at every
    // position class (page headers, setup, audio), then decoded to the end.
    const auto bytes = Tone();
    std::uint32_t state = 2024;
    const auto next = [&] { state = state * 1664525u + 1013904223u; return state >> 8; };
    for (int run = 0; run < 600; ++run) {
        auto damaged = bytes;
        damaged[next() % damaged.size()] = static_cast<std::uint8_t>(next());
        if (run % 3 == 0) damaged[next() % damaged.size()] = static_cast<std::uint8_t>(next());
        auto decoder = Open(damaged);
        if (decoder == nullptr) continue;
        std::vector<float> block(2 * 512);
        std::size_t        total = 0;
        while (const auto frames = decoder->read(block.data(), 512)) {
            for (std::size_t i = 0; i < frames * 2; ++i) ASSERT_TRUE(std::isfinite(block[i])) << "run " << run;
            total += frames;
            ASSERT_LT(total, 1'000'000u) << "run " << run << " does not end";
        }
    }
}

TEST(VorbisDecoder, WellFormedCommentHeadersOfAnyShapeStillOpen)
{
    const auto expected = ReadAll(*Open(Tone()), 512).size();
    struct Case {
        const char*               what;
        std::vector<std::uint8_t> comment;
        bool                      split;
    };
    const std::vector<Case> cases {
        { "no comments, no vendor", CommentHeader(0, {}), false },
        { "a vendor and three comments", CommentHeader(11, { 0, 7, 40 }), false },
        { "a comment longer than a lacing segment", CommentHeader(5, { 1000 }), false },
        { "a header of exactly 255 bytes", CommentHeader(0, { 255 - 7 - 4 - 4 - 4 - 1 }), false },
        { "a header continued on the next page", CommentHeader(20, { 3000 }), true },
    };
    for (const auto& item : cases) {
        std::string error;
        auto        decoder = Open(WithComment(item.comment, item.split), &error);
        ASSERT_NE(decoder, nullptr) << item.what << ": " << error;
        EXPECT_EQ(ReadAll(*decoder, 512).size(), expected) << item.what;
    }
}

TEST(VorbisDecoder, ACommentHeaderThatLiesAboutItsLengthsIsRefusedWithoutDecoding)
{
    // stb_vorbis allocates and copies by these numbers as the file states them: two
    // billion comments would crash it, so the decoder checks them against the bytes first.
    struct Case {
        const char*               what;
        std::vector<std::uint8_t> comment;
    };
    const std::vector<Case> cases {
        { "two billion comments", CommentHeader(0, 0, 0x7fffffffu, {}) },
        { "four billion comments", CommentHeader(0, 0, 0xffffffffu, {}) },
        { "sixteen million comments", CommentHeader(0, 0, 0x00ffffffu, {}) },
        { "more comments than it holds", CommentHeader(0, 0, 3, { { 1, 1 }, { 1, 1 } }) },
        { "a vendor string of four billion bytes", CommentHeader(0xffffffffu, 4, 0, {}) },
        { "a vendor string longer than the header", CommentHeader(500, 10, 0, {}) },
        { "a comment of two billion bytes", CommentHeader(0, 0, 1, { { 0x7fffffffu, 5 } }) },
        { "a comment longer than the header", CommentHeader(0, 0, 1, { { 50, 5 } }) },
        { "no framing bit", CommentHeader(0, 0, 0, {}, 0) },
    };
    for (const auto& item : cases) {
        std::string error;
        EXPECT_EQ(Open(WithComment(item.comment), &error), nullptr) << item.what;
        EXPECT_FALSE(error.empty()) << item.what;
    }
    // The same lies in place, in the fixture's own comment header: its comment count
    // is the 4 bytes after the 12-byte vendor string.
    auto bytes = Tone();
    const std::size_t count_at = kSecondPage + 27 + bytes[kSecondPage + 26] + 7 + 4 + 12;
    for (const std::uint32_t claim : { 0x7fffffffu, 0xffffffffu, 0x00ffffffu, 2u }) {
        auto lying = bytes;
        for (int i = 0; i < 4; ++i) lying[count_at + static_cast<std::size_t>(i)] = static_cast<std::uint8_t>(claim >> (8 * i));
        EXPECT_EQ(Open(lying), nullptr) << claim;
    }
}

TEST(VorbisDecoder, DamagedHeadersNeverCrash)
{
    // The first 200 bytes hold the identification header and the comment header, the
    // part stb_vorbis parses by lengths the file states. Several bytes at a time, and
    // inserts and cuts, which move the lengths against their text.
    const auto bytes = Tone();
    std::uint32_t state = 77;
    const auto next = [&] { state = state * 1664525u + 1013904223u; return state >> 8; };
    for (int run = 0; run < 4000; ++run) {
        auto damaged = bytes;
        const int edits = 1 + run % 4;
        for (int edit = 0; edit < edits; ++edit) {
            const std::size_t at = next() % 200;
            switch (next() % 4) {
            case 0: damaged[at] = static_cast<std::uint8_t>(next()); break;
            case 1: damaged[at] = 0xff; break;
            case 2: damaged.insert(damaged.begin() + static_cast<std::ptrdiff_t>(at), static_cast<std::uint8_t>(next())); break;
            default: damaged.erase(damaged.begin() + static_cast<std::ptrdiff_t>(at)); break;
            }
        }
        auto decoder = Open(damaged);
        if (decoder == nullptr) continue;
        std::vector<float> block(8 * 256);
        for (int blocks = 0; blocks < 8; ++blocks) {
            if (decoder->read(block.data(), 256) == 0) break;
        }
    }
}

TEST(VorbisDecoder, ASampleRateThatNoAudioFormatUsesIsRefused)
{
    // The rate comes from the file. A huge one would make the resampler's filter
    // enormous, so the decoder refuses what no real format carries.
    constexpr std::size_t rate_at = 27 + 1 + 7 + 4 + 1;
    for (const std::uint32_t rate : { 768'001u, 4'000'000'001u, 0xffffffffu }) {
        auto bytes = Tone();
        for (int i = 0; i < 4; ++i) bytes[rate_at + static_cast<std::size_t>(i)] = static_cast<std::uint8_t>(rate >> (8 * i));
        std::string error;
        EXPECT_EQ(Open(bytes, &error), nullptr) << rate;
        EXPECT_FALSE(error.empty());
    }
    auto bytes = Tone();
    for (int i = 0; i < 4; ++i) bytes[rate_at + static_cast<std::size_t>(i)] = static_cast<std::uint8_t>(768'000u >> (8 * i));
    const auto decoder = Open(bytes);
    ASSERT_NE(decoder, nullptr);
    EXPECT_EQ(decoder->format().sampleRate, 768'000u);
}

TEST(VorbisDecoder, ChannelOrderIsRearrangedToTheOrderOfWav)
{
    // Vorbis: 5.1 is left, centre, right, left surround, right surround, low
    // frequency. WAV and the remix after it: left, right, centre, low frequency,
    // left surround, right surround.
    EXPECT_EQ(VorbisToNativeOrder(6), (std::vector<int> { 0, 2, 1, 5, 3, 4 }));
    EXPECT_EQ(VorbisToNativeOrder(3), (std::vector<int> { 0, 2, 1 }));
    EXPECT_EQ(VorbisToNativeOrder(5), (std::vector<int> { 0, 2, 1, 3, 4 }));
    EXPECT_EQ(VorbisToNativeOrder(7), (std::vector<int> { 0, 2, 1, 6, 5, 3, 4 }));
    EXPECT_EQ(VorbisToNativeOrder(8), (std::vector<int> { 0, 2, 1, 7, 5, 6, 3, 4 }));
    for (const std::uint32_t same : { 1u, 2u, 4u }) EXPECT_TRUE(VorbisToNativeOrder(same).empty());
}

} // namespace
} // namespace wallpaper::sound
