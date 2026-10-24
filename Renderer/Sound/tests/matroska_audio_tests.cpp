// The audio of Matroska and WebM files as PCM: Opus, AAC and Vorbis tracks of real
// encoder output, the Ogg framing Vorbis needs, Opus trimming and refusals. Nothing
// plays: samples are read from the decoder and measured.
#include "Sound/Matroska/MatroskaAudio.hpp"
#include "Sound/Matroska/OggVorbisFraming.hpp"
#include "Sound/Vorbis/VorbisDecoder.hpp"

#include "Media/tests/mkv_builder.hpp"
#include "matroska_fixture_data.hpp"
#include "vorbis_fixture_data.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper::sound
{
namespace
{

using media::testing::Bytes;

template <std::size_t N>
std::shared_ptr<media::MatroskaReader> OpenClip(const unsigned char (&clip)[N])
{
    media::Error error;
    auto         reader = media::MatroskaReader::Open(
        media::MakeMemoryByteSource(std::vector<std::uint8_t>(std::begin(clip), std::end(clip))), &error);
    EXPECT_NE(reader, nullptr) << media::Describe(error);
    return reader;
}

std::size_t AudioTrackOf(const media::MatroskaReader& reader)
{
    for (std::size_t index = 0; index < reader.tracks().size(); ++index) {
        if (reader.tracks()[index].type == media::MatroskaTrackType::Audio) return index;
    }
    ADD_FAILURE() << "the clip has no audio track";
    return 0;
}

struct Decoded {
    PcmFormat          format;
    std::vector<float> samples;  // interleaved
    std::size_t        frames() const { return format.channels == 0 ? 0 : samples.size() / format.channels; }
};

Decoded DecodeAll(PcmDecoder& decoder, std::size_t chunk = 1000)
{
    Decoded out;
    out.format = decoder.format();
    std::vector<float> buffer(chunk * out.format.channels);
    for (;;) {
        const std::size_t got = decoder.read(buffer.data(), chunk);
        if (got == 0) break;
        out.samples.insert(out.samples.end(), buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(got * out.format.channels));
    }
    return out;
}

/// The frequency of channel 0 from its zero crossings over frames [from, to).
double ToneHz(const Decoded& decoded, std::size_t from, std::size_t to)
{
    std::size_t crossings = 0;
    for (std::size_t at = from + 1; at < to; ++at) {
        const float before = decoded.samples[(at - 1) * decoded.format.channels];
        const float after  = decoded.samples[at * decoded.format.channels];
        if ((before < 0) != (after < 0)) ++crossings;
    }
    return static_cast<double>(crossings) / 2.0 / (static_cast<double>(to - from) / decoded.format.sampleRate);
}

float Peak(const Decoded& decoded, std::size_t from, std::size_t to)
{
    float peak = 0;
    for (std::size_t at = from * decoded.format.channels; at < to * decoded.format.channels; ++at) peak = std::max(peak, std::fabs(decoded.samples[at]));
    return peak;
}

// --- Opus packet durations -----------------------------------------------------

TEST(OpusPacketFramesTest, ReadsTheTableOfContents)
{
    const auto frames = [](std::vector<std::uint8_t> packet) { return OpusPacketFrames(packet.data(), packet.size()); };
    EXPECT_EQ(frames({ 0xFC, 0 }), 960u);          // CELT 20 ms, one frame
    EXPECT_EQ(frames({ 0xE0, 0 }), 120u);          // CELT 2.5 ms (config 28)
    EXPECT_EQ(frames({ 0x78, 0 }), 960u);          // hybrid 20 ms (config 15)
    EXPECT_EQ(frames({ 0x00, 0 }), 480u);          // SILK narrowband 10 ms
    EXPECT_EQ(frames({ 0x18, 0 }), 2880u);         // SILK narrowband 60 ms (config 3)
    EXPECT_EQ(frames({ 0xFD, 0, 0 }), 1920u);      // code 1: two frames of 20 ms
    EXPECT_EQ(frames({ 0xFE, 0, 0 }), 1920u);      // code 2: two frames of different size
    EXPECT_EQ(frames({ 0xFF, 3, 0 }), 2880u);      // code 3 with three frames of 20 ms
    EXPECT_EQ(frames({ 0xFF, 0, 0 }), 0u);         // code 3 with no frames is not a packet
    EXPECT_EQ(frames({ 0xFF }), 0u);               // code 3 cut off before its count
    EXPECT_EQ(frames({ 0xFF, 49, 0 }), 0u);        // 49 frames of 20 ms is past 120 ms
    EXPECT_EQ(frames({}), 0u);
}

// --- Opus -----------------------------------------------------------------------

TEST(MatroskaAudioTest, DecodesAnOpusTrackToItsLengthAndTone)
{
    auto reader = OpenClip(fixtures::kOpusWebm);
    ASSERT_NE(reader, nullptr);
    std::string error;
    auto        decoder = OpenMatroskaAudio(reader, AudioTrackOf(*reader), &error);
    ASSERT_NE(decoder, nullptr) << error;
    EXPECT_EQ(decoder->format(), (PcmFormat { 2, 48000 }));

    const Decoded decoded = DecodeAll(*decoder);
    // Half a second: the pre-skip is dropped from the start and the padding from the end.
    EXPECT_NEAR(static_cast<double>(decoded.frames()), 24000.0, 1000.0);
    EXPECT_NEAR(ToneHz(decoded, 2000, 22000), 440.0, 8.0);
    EXPECT_GT(Peak(decoded, 2000, 22000), 0.08f);
    EXPECT_LT(Peak(decoded, 0, decoded.frames()), 0.2f);
    EXPECT_FALSE(decoder->failed()) << decoder->failure();
}

TEST(MatroskaAudioTest, ARewoundOpusTrackDecodesTheSameFramesAgain)
{
    auto reader = OpenClip(fixtures::kOpusWebm);
    ASSERT_NE(reader, nullptr);
    auto decoder = OpenMatroskaAudio(reader, AudioTrackOf(*reader), nullptr);
    ASSERT_NE(decoder, nullptr);
    const Decoded first = DecodeAll(*decoder);
    ASSERT_TRUE(decoder->rewind());
    const Decoded second = DecodeAll(*decoder, 777);
    ASSERT_EQ(first.frames(), second.frames());
    EXPECT_EQ(first.samples, second.samples);
}

TEST(MatroskaAudioTest, TrimsOpusToThePreSkipAndPadding)
{
    // A track whose packets are silence: every decoded frame is zero, so only the count
    // is in question. Fifty 20 ms packets, a pre-skip of 312 frames, 5 ms of padding
    // on the last block.
    const Bytes silence { 0xFC, 0xFF, 0xFE };  // a CELT 20 ms packet of silence
    media::testing::MkvSpec spec;
    media::testing::TrackSpec video;
    video.codecId = "V_VP9";
    spec.tracks.push_back(video);
    media::testing::TrackSpec audio;
    audio.number  = 2;
    audio.type    = 2;
    audio.codecId = "A_OPUS";
    audio.codecPrivate = { 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0 };
    spec.tracks.push_back(audio);
    // The video block carries a real VP9 key frame header so the reader accepts the track.
    const Bytes key { 0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x02, 0xf6, 0x04, 0x38, 0x24,
                      0x1c, 0x18, 0x42, 0x00, 0x01, 0xb0, 0x7c, 0xb1, 0xfa, 0xdb, 0x72, 0xf4 };
    media::testing::ClusterSpec cluster;
    media::testing::BlockSpec   videoBlock;
    videoBlock.frames.push_back(key);
    cluster.blocks.push_back(videoBlock);
    for (int index = 0; index < 50; ++index) {
        media::testing::BlockSpec block;
        block.track = 2;
        block.time  = index * 20;
        block.group = index == 49;
        if (block.group) {
            block.duration         = 20;
            block.discardPaddingNs = 5000000;
        }
        block.frames.push_back(silence);
        cluster.blocks.push_back(block);
    }
    spec.clusters.push_back(cluster);
    auto built  = media::testing::BuildMkv(spec);
    media::Error error;
    auto reader = std::shared_ptr<media::MatroskaReader>(
        media::MatroskaReader::Open(media::MakeMemoryByteSource(built.bytes), &error));
    ASSERT_NE(reader, nullptr) << media::Describe(error);
    std::string why;
    auto        decoder = OpenMatroskaAudio(reader, AudioTrackOf(*reader), &why);
    ASSERT_NE(decoder, nullptr) << why;
    const Decoded decoded = DecodeAll(*decoder);
    // 50 packets of 960 frames, less the pre-skip (312) and 5 ms of padding (240).
    EXPECT_EQ(decoded.frames(), 50u * 960u - 312u - 240u);
}

TEST(MatroskaAudioTest, RefusesOpusWithAChannelMappingThisDoesNotDecode)
{
    media::testing::MkvSpec spec;
    spec.tracks.push_back({});
    media::testing::TrackSpec audio;
    audio.number  = 2;
    audio.type    = 2;
    audio.codecId = "A_OPUS";
    // Six channels with mapping family 1.
    audio.codecPrivate = { 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 6, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 1, 4, 2, 0, 4, 1, 2, 3, 5 };
    spec.tracks.push_back(audio);
    const Bytes key { 0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x02, 0xf6, 0x04, 0x38, 0x24,
                      0x1c, 0x18, 0x42, 0x00, 0x01, 0xb0, 0x7c, 0xb1, 0xfa, 0xdb, 0x72, 0xf4 };
    media::testing::ClusterSpec cluster;
    media::testing::BlockSpec   videoBlock;
    videoBlock.frames.push_back(key);
    cluster.blocks.push_back(videoBlock);
    media::testing::BlockSpec audioBlock;
    audioBlock.track = 2;
    audioBlock.frames.push_back({ 0xFC, 0xFF, 0xFE });
    cluster.blocks.push_back(audioBlock);
    spec.clusters.push_back(cluster);
    auto built = media::testing::BuildMkv(spec);
    media::Error error;
    auto reader = std::shared_ptr<media::MatroskaReader>(
        media::MatroskaReader::Open(media::MakeMemoryByteSource(built.bytes), &error));
    ASSERT_NE(reader, nullptr) << media::Describe(error);
    std::string why;
    EXPECT_EQ(OpenMatroskaAudio(reader, AudioTrackOf(*reader), &why), nullptr);
    EXPECT_NE(why.find("6 channels"), std::string::npos) << why;
}

// --- AAC ------------------------------------------------------------------------

TEST(MatroskaAudioTest, DecodesAnAacTrack)
{
    auto reader = OpenClip(fixtures::kAacMatroska);
    ASSERT_NE(reader, nullptr);
    std::string error;
    auto        decoder = OpenMatroskaAudio(reader, AudioTrackOf(*reader), &error);
    ASSERT_NE(decoder, nullptr) << error;
    EXPECT_EQ(decoder->format(), (PcmFormat { 2, 44100 }));
    const Decoded decoded = DecodeAll(*decoder);
    EXPECT_NEAR(static_cast<double>(decoded.frames()), 22050.0, 2500.0);
    EXPECT_NEAR(ToneHz(decoded, 4000, 20000), 440.0, 10.0);
}

TEST(MatroskaAudioTest, DecodesAnMp3Track)
{
    auto reader = OpenClip(fixtures::kMp3Matroska);
    ASSERT_NE(reader, nullptr);
    std::string error;
    auto        decoder = OpenMatroskaAudio(reader, AudioTrackOf(*reader), &error);
    ASSERT_NE(decoder, nullptr) << error;
    EXPECT_EQ(decoder->format(), (PcmFormat { 2, 44100 }));
    const Decoded decoded = DecodeAll(*decoder);
    EXPECT_NEAR(static_cast<double>(decoded.frames()), 22050.0, 2500.0);
    EXPECT_NEAR(ToneHz(decoded, 4000, 20000), 440.0, 10.0);
}

// --- Vorbis ---------------------------------------------------------------------

TEST(MatroskaAudioTest, DecodesAVorbisTrackThroughOggFraming)
{
    auto reader = OpenClip(fixtures::kVorbisWebm);
    ASSERT_NE(reader, nullptr);
    std::string error;
    auto        decoder = OpenMatroskaAudio(reader, AudioTrackOf(*reader), &error);
    ASSERT_NE(decoder, nullptr) << error;
    EXPECT_EQ(decoder->format(), (PcmFormat { 2, 44100 }));
    const Decoded decoded = DecodeAll(*decoder);
    EXPECT_NEAR(static_cast<double>(decoded.frames()), 22050.0, 1500.0);
    EXPECT_NEAR(ToneHz(decoded, 3000, 19000), 440.0, 10.0);
    ASSERT_TRUE(decoder->rewind());
    EXPECT_EQ(DecodeAll(*decoder).samples, decoded.samples);
}

/// The packets of the Ogg Vorbis fixture: split the pages' segments into packets.
std::vector<std::vector<std::uint8_t>> OggPackets(const std::uint8_t* data, std::size_t size)
{
    std::vector<std::vector<std::uint8_t>> packets;
    std::vector<std::uint8_t>              open;
    std::size_t                            at = 0;
    while (at + 27 <= size) {
        const std::size_t segments = data[at + 26];
        std::size_t       body     = at + 27 + segments;
        for (std::size_t index = 0; index < segments; ++index) {
            const std::uint8_t lace = data[at + 27 + index];
            open.insert(open.end(), data + body, data + body + lace);
            body += lace;
            if (lace < 255) {
                packets.push_back(std::move(open));
                open.clear();
            }
        }
        at = body;
    }
    return packets;
}

TEST(MatroskaAudioTest, VorbisPacketsInMatroskaDecodeLikeTheOggFileTheyCameFrom)
{
    const auto packets = OggPackets(fixtures::kOggTone, sizeof(fixtures::kOggTone));
    ASSERT_GT(packets.size(), 4u);
    // The identification header gives the codec private record its three headers, laced.
    Bytes priv { 2 };
    for (int index = 0; index < 2; ++index) {
        std::size_t size = packets[static_cast<std::size_t>(index)].size();
        while (size >= 255) { priv.push_back(255); size -= 255; }
        priv.push_back(static_cast<std::uint8_t>(size));
    }
    for (int index = 0; index < 3; ++index) priv.insert(priv.end(), packets[static_cast<std::size_t>(index)].begin(), packets[static_cast<std::size_t>(index)].end());

    media::testing::MkvSpec spec;
    media::testing::TrackSpec video;
    video.codecId = "V_VP9";
    spec.tracks.push_back(video);
    media::testing::TrackSpec audio;
    audio.number       = 2;
    audio.type         = 2;
    audio.codecId      = "A_VORBIS";
    audio.codecPrivate = priv;
    audio.sampleRate   = 44100;
    spec.tracks.push_back(audio);
    const Bytes key { 0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x02, 0xf6, 0x04, 0x38, 0x24,
                      0x1c, 0x18, 0x42, 0x00, 0x01, 0xb0, 0x7c, 0xb1, 0xfa, 0xdb, 0x72, 0xf4 };
    media::testing::ClusterSpec cluster;
    media::testing::BlockSpec   videoBlock;
    videoBlock.frames.push_back(key);
    cluster.blocks.push_back(videoBlock);
    // 11072 frames at 44.1 kHz over the audio packets, spaced evenly (the file's block
    // sizes are not known here, so the times only have to be close).
    const std::size_t audioPackets = packets.size() - 3;
    for (std::size_t index = 0; index < audioPackets; ++index) {
        media::testing::BlockSpec block;
        block.track = 2;
        block.time  = static_cast<std::int64_t>(index * 251 / audioPackets);
        block.frames.push_back(packets[3 + index]);
        cluster.blocks.push_back(block);
    }
    spec.clusters.push_back(cluster);
    auto built = media::testing::BuildMkv(spec);
    media::Error error;
    auto reader = std::shared_ptr<media::MatroskaReader>(
        media::MatroskaReader::Open(media::MakeMemoryByteSource(built.bytes), &error));
    ASSERT_NE(reader, nullptr) << media::Describe(error);
    std::string why;
    auto        wrapped = OpenMatroskaAudio(reader, AudioTrackOf(*reader), &why);
    ASSERT_NE(wrapped, nullptr) << why;
    auto direct = OpenVorbisDecoder(media::MakeMemoryByteSource(std::vector<std::uint8_t>(std::begin(fixtures::kOggTone), std::end(fixtures::kOggTone))), &why);
    ASSERT_NE(direct, nullptr) << why;

    const Decoded a = DecodeAll(*wrapped);
    const Decoded b = DecodeAll(*direct);
    ASSERT_EQ(a.format, b.format);
    // The same packets through the same decoder: every frame both produce is the same.
    const std::size_t common = std::min(a.samples.size(), b.samples.size());
    ASSERT_GT(common, 10000u);
    EXPECT_TRUE(std::equal(a.samples.begin(), a.samples.begin() + static_cast<std::ptrdiff_t>(common), b.samples.begin()));
    // And the length agrees to within the few milliseconds the block times round to.
    EXPECT_NEAR(static_cast<double>(a.frames()), static_cast<double>(b.frames()), 300.0);
}

// --- The Ogg framing -----------------------------------------------------------

TEST(OggVorbisFramingTest, SplitsACodecPrivateRecord)
{
    Bytes priv { 2, 30, 4 };
    Bytes ident { 1, 'v', 'o', 'r', 'b', 'i', 's' };
    ident.resize(30, 0);
    priv.insert(priv.end(), ident.begin(), ident.end());
    priv.insert(priv.end(), { 3, 'v', 'o', 'r' });
    priv.insert(priv.end(), { 5, 'v', 'o', 'r', 'b' });
    VorbisHeaders headers;
    std::string   error;
    ASSERT_TRUE(SplitVorbisCodecPrivate(priv, &headers, &error)) << error;
    EXPECT_EQ(headers[0].size(), 30u);
    EXPECT_EQ(headers[1], (Bytes { 3, 'v', 'o', 'r' }));
    EXPECT_EQ(headers[2], (Bytes { 5, 'v', 'o', 'r', 'b' }));
}

TEST(OggVorbisFramingTest, RefusesRecordsThatAreNotThreeHeaders)
{
    VorbisHeaders headers;
    std::string   error;
    EXPECT_FALSE(SplitVorbisCodecPrivate({}, &headers, &error));
    EXPECT_FALSE(SplitVorbisCodecPrivate({ 1, 30, 1, 2, 3 }, &headers, &error));  // a count of two packets is needed
    EXPECT_FALSE(SplitVorbisCodecPrivate({ 2, 255, 255 }, &headers, &error));     // sizes run off the record
    EXPECT_FALSE(SplitVorbisCodecPrivate({ 2, 30, 4, 1, 2, 3 }, &headers, &error));  // headers cut short
    Bytes priv { 2, 30, 4 };
    priv.resize(3 + 30 + 4 + 5, 7);                                                  // the wrong packet types
    EXPECT_FALSE(SplitVorbisCodecPrivate(priv, &headers, &error));
}

TEST(OggVorbisFramingTest, PagesCarryAValidChecksumAndOnlyTheLastOneAPosition)
{
    const auto packets = OggPackets(fixtures::kOggTone, sizeof(fixtures::kOggTone));
    VorbisHeaders headers { packets[0], packets[1], packets[2] };
    OggVorbisWriter writer;
    writer.writeHeaders(headers);
    for (std::size_t index = 3; index < packets.size(); ++index) writer.writePacket(packets[index].data(), packets[index].size());
    writer.finish(11072);
    const auto bytes = writer.take();

    // Re-split what was written: the same packets come back, in order.
    EXPECT_EQ(OggPackets(bytes.data(), bytes.size()), packets);
    // Walk the pages: sequence numbers count up, only the first is marked first and
    // only the last marked last and given a position.
    std::size_t at = 0;
    std::uint32_t sequence = 0;
    std::size_t   pages = 0;
    while (at + 27 <= bytes.size()) {
        ASSERT_EQ(std::string(bytes.begin() + static_cast<std::ptrdiff_t>(at), bytes.begin() + static_cast<std::ptrdiff_t>(at) + 4), "OggS");
        const std::uint8_t flags = bytes[at + 5];
        std::uint64_t      granule = 0;
        for (int index = 7; index >= 0; --index) granule = granule << 8 | bytes[at + 6 + static_cast<std::size_t>(index)];
        std::uint32_t seq = 0;
        for (int index = 3; index >= 0; --index) seq = seq << 8 | bytes[at + 18 + static_cast<std::size_t>(index)];
        EXPECT_EQ(seq, sequence++);
        EXPECT_EQ((flags & 2) != 0, pages == 0);
        const std::size_t segments = bytes[at + 26];
        std::size_t       body = 0;
        for (std::size_t index = 0; index < segments; ++index) body += bytes[at + 27 + index];
        const std::size_t end = at + 27 + segments + body;
        const bool last = end == bytes.size();
        EXPECT_EQ((flags & 4) != 0, last);
        if (pages >= 2 && !last) EXPECT_EQ(granule, ~std::uint64_t { 0 });
        if (last) EXPECT_EQ(granule, 11072u);
        // The checksum of the page with its own field zeroed.
        std::vector<std::uint8_t> page(bytes.begin() + static_cast<std::ptrdiff_t>(at), bytes.begin() + static_cast<std::ptrdiff_t>(end));
        const std::uint32_t stored = static_cast<std::uint32_t>(page[22]) | static_cast<std::uint32_t>(page[23]) << 8 |
                                     static_cast<std::uint32_t>(page[24]) << 16 | static_cast<std::uint32_t>(page[25]) << 24;
        page[22] = page[23] = page[24] = page[25] = 0;
        std::uint32_t crc = 0;
        for (const std::uint8_t byte : page) {
            crc ^= static_cast<std::uint32_t>(byte) << 24;
            for (int bit = 0; bit < 8; ++bit) crc = (crc & 0x80000000U) != 0 ? (crc << 1) ^ 0x04C11DB7U : crc << 1;
        }
        EXPECT_EQ(stored, crc);
        ++pages;
        at = end;
    }
    EXPECT_EQ(at, bytes.size());
}

TEST(OggVorbisFramingTest, APacketLongerThanAPageContinuesOnTheNext)
{
    VorbisHeaders headers { OggPackets(fixtures::kOggTone, sizeof(fixtures::kOggTone))[0], { 3, 'v' }, { 5, 'v' } };
    OggVorbisWriter writer;
    writer.writeHeaders(headers);
    const std::vector<std::uint8_t> huge(70000, 0x5A);  // 275 segments: two pages
    writer.writePacket(huge.data(), huge.size());
    writer.finish(1);
    const auto packets = OggPackets(writer.bytes().data(), writer.bytes().size());
    ASSERT_EQ(packets.size(), 4u);
    EXPECT_EQ(packets[3], huge);
}

} // namespace
} // namespace wallpaper::sound
