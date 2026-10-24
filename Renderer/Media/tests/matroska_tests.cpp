// The Matroska/WebM reader against files this test assembles itself
// (mkv_builder.hpp): the frame index, key frames and seeking, SimpleBlock and
// BlockGroup, all three lacings, unknown-size Segment and Clusters, Cues present
// or absent, the EBML header checks, codec and encoding handling, and input that
// is truncated, malformed, oversized or randomly mutated must fail cleanly
// instead of reading out of bounds. Plus the VP9 uncompressed-header parser,
// checked against the first frames of real libvpx output.
#include "Media/ByteSource.hpp"
#include "Media/Matroska/Ebml.hpp"
#include "Media/Matroska/MatroskaReader.hpp"
#include "Media/Matroska/Vp9Header.hpp"

#include "mkv_builder.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <tuple>
#include <vector>

namespace wallpaper::media
{
namespace
{

using namespace testing;

constexpr std::int64_t kMs = 1000000;  // nanoseconds per millisecond

// The first 24 bytes of the first key frame of 64x48 clips encoded with libvpx-vp9.
const Bytes kVp9Profile0Key { 0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x02, 0xf6, 0x04, 0x38, 0x24,
                              0x1c, 0x18, 0x42, 0x00, 0x01, 0xb0, 0x7c, 0xb1, 0xfa, 0xdb, 0x72, 0xf4 };
const Bytes kVp9Profile1Key { 0xa2, 0x49, 0x83, 0x42, 0x00, 0x00, 0x7e, 0x00, 0x5e, 0xc0, 0x87, 0x04,
                              0x83, 0x83, 0x08, 0x40, 0x00, 0x60, 0x7c, 0xb1, 0x7a, 0xdf, 0xc9, 0x74 };
const Bytes kVp9Profile2Key { 0x92, 0x49, 0x83, 0x42, 0x00, 0x01, 0xf8, 0x01, 0x7b, 0x03, 0x1c, 0x12,
                              0x0e, 0x0c, 0x29, 0x00, 0x00, 0xe8, 0x7c, 0xb1, 0xfa, 0xdf, 0xc7, 0xf1 };
const Bytes kVp9RgbKey { 0xa2, 0x49, 0x83, 0x42, 0xe0, 0x03, 0xf0, 0x02, 0xf6, 0x08, 0x38, 0x24,
                         0x1c, 0x18, 0x42, 0x00, 0x04, 0x20, 0x7c, 0xb1, 0x7e, 0xbf, 0x9f, 0x66 };
const Bytes kVp9InterFrame { 0x86, 0x00, 0x40, 0x92, 0x9c, 0x04, 0x49, 0x40, 0x00, 0x03, 0x60, 0x00, 0x00, 0x7a, 0x36, 0x4e };

Bytes Padded(const Bytes& head, std::size_t size)
{
    Bytes out = head;
    while (out.size() < size) out.push_back(static_cast<std::uint8_t>(out.size()));
    return out;
}

TrackSpec VideoTrack(std::uint32_t number = 1, const std::string& codec = "V_VP9")
{
    TrackSpec track;
    track.number  = number;
    track.codecId = codec;
    return track;
}

TrackSpec OpusTrack(std::uint32_t number = 2)
{
    TrackSpec track;
    track.number  = number;
    track.type    = 2;
    track.codecId = "A_OPUS";
    track.codecPrivate = { 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0 };
    track.codecDelayNs     = 6500000;
    track.seekPreRollNs    = 80000000;
    track.defaultDurationNs = 20 * kMs;
    return track;
}

// Video frame `index` of a clip at 40 ms per frame: key frames every `gop`, the
// first one carrying a real VP9 key frame header.
BlockSpec VideoBlock(std::size_t index, std::size_t gop = 5, std::size_t size = 40, std::uint32_t track = 1)
{
    BlockSpec block;
    block.track = track;
    block.time  = static_cast<std::int64_t>(index) * 40;
    block.key   = index % gop == 0;
    block.frames.push_back(index == 0 ? Padded(kVp9Profile0Key, size) : FrameBytes(track, index, size));
    return block;
}

MkvSpec ClipSpec(std::size_t frames = 12, std::size_t perCluster = 5, std::size_t gop = 5)
{
    MkvSpec spec;
    spec.tracks.push_back(VideoTrack());
    for (std::size_t first = 0; first < frames; first += perCluster) {
        ClusterSpec cluster;
        cluster.timecode = static_cast<std::int64_t>(first) * 40;
        for (std::size_t index = first; index < std::min(frames, first + perCluster); ++index) cluster.blocks.push_back(VideoBlock(index, gop));
        spec.clusters.push_back(cluster);
    }
    return spec;
}

std::unique_ptr<MatroskaReader> OpenBytes(const Bytes& bytes, Error* error = nullptr, const MatroskaOptions& options = {})
{
    return MatroskaReader::Open(MakeMemoryByteSource(bytes), error, options);
}

std::unique_ptr<MatroskaReader> OpenMkv(const MkvSpec& spec, BuiltMkv* built = nullptr, Error* error = nullptr,
                                        const MatroskaOptions& options = {})
{
    BuiltMkv local = BuildMkv(spec);
    auto     reader = OpenBytes(local.bytes, error, options);
    if (built != nullptr) *built = std::move(local);
    return reader;
}

std::vector<FrameRecord> FramesOf(const BuiltMkv& built, std::uint32_t track)
{
    std::vector<FrameRecord> frames;
    for (const FrameRecord& frame : built.frames) {
        if (frame.track == track) frames.push_back(frame);
    }
    return frames;
}

std::string ErrorText(const Error& error) { return Describe(error); }

std::vector<std::tuple<std::uint64_t, std::int64_t, bool>> Shape(const MatroskaReader& reader)
{
    std::vector<std::tuple<std::uint64_t, std::int64_t, bool>> shape;
    for (const Sample& sample : reader.videoSamples()) shape.emplace_back(sample.size, sample.pts, sample.sync);
    return shape;
}

// --- The index of a plain file -----------------------------------------------------

TEST(MatroskaReader, IndexesEveryVideoFrameWithItsPlaceTimeAndKeyFlag)
{
    BuiltMkv built;
    Error    error;
    auto     reader = OpenMkv(ClipSpec(12, 5), &built, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    const std::vector<FrameRecord> frames = FramesOf(built, 1);
    ASSERT_EQ(frames.size(), 12U);
    ASSERT_EQ(reader->videoSamples().size(), 12U);
    for (std::size_t index = 0; index < 12; ++index) {
        const Sample& sample = reader->videoSamples()[index];
        EXPECT_EQ(sample.offset, frames[index].offset) << index;
        EXPECT_EQ(sample.size, frames[index].data.size()) << index;
        EXPECT_EQ(sample.pts, static_cast<std::int64_t>(index) * 40 * kMs) << index;
        EXPECT_EQ(sample.dts, sample.pts) << "no reordering: dts equals pts (" << index << ")";
        EXPECT_EQ(sample.sync, index % 5 == 0) << index;
        EXPECT_EQ(sample.duration, 40 * kMs) << index;
        Bytes payload;
        ASSERT_TRUE(reader->readSample(index, &payload, &error)) << ErrorText(error);
        EXPECT_EQ(payload, frames[index].data) << index;
    }
    const VideoStreamInfo& info = reader->videoInfo();
    EXPECT_EQ(info.codecFourcc, FourCC('v', 'p', '0', '9'));
    EXPECT_EQ(info.configFourcc, 0U) << "a WebM VP9 track has no vpcC record";
    EXPECT_TRUE(info.codecConfig.empty());
    EXPECT_EQ(info.codedWidth, 64U);
    EXPECT_EQ(info.codedHeight, 48U);
    EXPECT_EQ(info.timescale, 1000000000);
    EXPECT_EQ(info.durationTicks, 480 * kMs);
    EXPECT_EQ(info.contentEndTicks, 480 * kMs);
    EXPECT_EQ(info.minFramePeriod, MakeRational(1, 25));
    EXPECT_EQ(info.avgFramePeriod, MakeRational(1, 25));
    EXPECT_EQ(info.trackId, 1U);
    EXPECT_EQ(info.displayMatrix, kIdentityDisplayMatrix);
    EXPECT_EQ(reader->info().docType, "webm");
    EXPECT_EQ(reader->info().timecodeScale, 1000000U);
    EXPECT_EQ(reader->videoTrackIndex(), 0U);
    EXPECT_TRUE(reader->warnings().empty());
}

TEST(MatroskaReader, TheTimecodeScaleSetsTheTimeUnit)
{
    MkvSpec spec      = ClipSpec(6, 3);
    spec.timecodeScale = 500000;  // each tick is 0.5 ms
    auto reader        = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoSamples()[1].pts, 40 * 500000);
    EXPECT_EQ(reader->videoSamples()[5].pts, 200 * 500000);
}

TEST(MatroskaReader, ABlockEarlierThanItsClusterTimecodeHasANegativeOffset)
{
    MkvSpec spec = ClipSpec(1);
    ClusterSpec cluster;
    cluster.timecode = 100;
    cluster.blocks.push_back(VideoBlock(1, 1));
    cluster.blocks.back().time = 98;
    spec.clusters.push_back(cluster);
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoSamples()[1].pts, 98 * kMs);
}

TEST(MatroskaReader, TheIndexNotInfoDurationDecidesHowLongTheVideoPlays)
{
    MkvSpec spec = ClipSpec(10, 5);
    spec.infoDuration = 999999;  // a wrong header value
    auto reader       = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoInfo().durationTicks, 400 * kMs);
    EXPECT_EQ(reader->info().infoDurationNs, 999999 * kMs);
}

TEST(MatroskaReader, ADefaultDurationGivesTheLastFrameItsLength)
{
    MkvSpec spec = ClipSpec(4, 4);
    spec.tracks[0].defaultDurationNs = 40 * kMs;
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoSamples().back().duration, 40 * kMs);
    EXPECT_EQ(reader->videoInfo().durationTicks, 160 * kMs);
}

TEST(MatroskaReader, ASingleFrameFileTakesItsPeriodFromTheTrackDefaultDuration)
{
    MkvSpec spec = ClipSpec(1, 1);
    spec.tracks[0].defaultDurationNs = 33333333;
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoInfo().minFramePeriod, MakeRational(33333333, 1000000000));
    EXPECT_EQ(reader->videoSamples().size(), 1U);
}

TEST(MatroskaReader, ReadsHeadersOnlyWhenAskedNotToIndex)
{
    MkvSpec spec = ClipSpec(12, 5);
    spec.infoDuration = 480;
    MatroskaOptions options;
    options.buildIndex = false;
    Error error;
    auto  reader = OpenMkv(spec, nullptr, &error, options);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    EXPECT_TRUE(reader->videoSamples().empty());
    EXPECT_TRUE(reader->packets(0).empty());
    EXPECT_EQ(reader->videoInfo().codedWidth, 64U);
    EXPECT_EQ(reader->videoInfo().durationTicks, 480 * kMs) << "without an index the Info duration is all there is";
    EXPECT_FALSE(reader->findVideoKeyframeAtOrBefore(0).has_value());
}

// --- SimpleBlock, BlockGroup, key frames, decode times ----------------------------

TEST(MatroskaReader, BlockGroupsAreKeyFramesUnlessTheyReferenceAnotherFrame)
{
    MkvSpec spec;
    spec.tracks.push_back(VideoTrack());
    ClusterSpec cluster;
    for (std::size_t index = 0; index < 6; ++index) {
        BlockSpec block = VideoBlock(index, 3);
        block.group     = true;
        block.reference = ! block.key;
        block.duration  = 40;
        cluster.blocks.push_back(block);
    }
    // One plain SimpleBlock in the same cluster.
    BlockSpec simple = VideoBlock(6, 3);
    simple.key       = false;
    cluster.blocks.push_back(simple);
    spec.clusters.push_back(cluster);
    BuiltMkv built;
    auto     reader = OpenMkv(spec, &built);
    ASSERT_NE(reader, nullptr);
    std::vector<bool> keys;
    for (const Sample& sample : reader->videoSamples()) keys.push_back(sample.sync);
    EXPECT_EQ(keys, (std::vector<bool> { true, false, false, true, false, false, false }));
    EXPECT_EQ(reader->videoSamples()[0].duration, 40 * kMs) << "BlockDuration is used";
    const auto frames = FramesOf(built, 1);
    for (std::size_t index = 0; index < frames.size(); ++index) {
        EXPECT_EQ(reader->videoSamples()[index].offset, frames[index].offset) << "frame inside a BlockGroup, " << index;
    }
}

TEST(MatroskaReader, BlockAdditionsAreIgnoredSoVp9AlphaPlaysOpaque)
{
    MkvSpec plain;
    plain.tracks.push_back(VideoTrack());
    ClusterSpec cluster;
    for (std::size_t index = 0; index < 6; ++index) {
        BlockSpec block = VideoBlock(index, 3);
        block.group     = true;
        block.reference = ! block.key;
        block.duration  = 40;
        cluster.blocks.push_back(block);
    }
    plain.clusters.push_back(cluster);
    MkvSpec alpha = plain;
    for (BlockSpec& block : alpha.clusters[0].blocks) block.additions = true;
    BuiltMkv built;
    auto     without = OpenMkv(plain);
    auto     with    = OpenMkv(alpha, &built);
    ASSERT_NE(without, nullptr);
    ASSERT_NE(with, nullptr);
    EXPECT_EQ(Shape(*with), Shape(*without)) << "the alpha channel changes nothing about the colour frames";
    const auto frames = FramesOf(built, 1);
    ASSERT_EQ(frames.size(), 6U);
    for (std::size_t index = 0; index < frames.size(); ++index) {
        EXPECT_EQ(with->videoSamples()[index].offset, frames[index].offset);
        EXPECT_EQ(with->videoSamples()[index].size, frames[index].data.size());
    }
    EXPECT_TRUE(with->warnings().empty());
}

TEST(MatroskaReader, DerivesDecodeTimesForReorderedFrames)
{
    // I P B B in decode order, shown I B B P: presentation 0, 120, 40, 80 ms.
    MkvSpec spec;
    spec.tracks.push_back(VideoTrack(1, "V_MPEG4/ISO/AVC"));
    spec.tracks[0].codecPrivate = AvcC(100, 8);
    ClusterSpec cluster;
    const std::int64_t times[] = { 0, 120, 40, 80 };
    for (std::size_t index = 0; index < 4; ++index) {
        BlockSpec block;
        block.time = times[index];
        block.key  = index == 0;
        block.frames.push_back(FrameBytes(1, index, 30));
        cluster.blocks.push_back(block);
    }
    spec.clusters.push_back(cluster);
    Error error;
    auto  reader = OpenMkv(spec, nullptr, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    std::vector<std::int64_t> pts, dts;
    for (const Sample& sample : reader->videoSamples()) {
        pts.push_back(sample.pts);
        dts.push_back(sample.dts);
    }
    EXPECT_EQ(pts, (std::vector<std::int64_t> { 0, 120 * kMs, 40 * kMs, 80 * kMs }));
    EXPECT_EQ(dts, (std::vector<std::int64_t> { -40 * kMs, 0, 40 * kMs, 80 * kMs })) << "sorted pts moved earlier by the 2-frame reorder delay";
    for (const Sample& sample : reader->videoSamples()) EXPECT_LE(sample.dts, sample.pts);
    EXPECT_EQ(reader->videoInfo().minFramePeriod, MakeRational(1, 25));
}

TEST(MatroskaReader, ExposesH264HevcAndAv1ConfigRecordsVerbatim)
{
    struct Case {
        std::string   codec;
        Bytes         config;
        std::uint32_t fourcc;
        std::uint32_t configFourcc;
        std::uint8_t  bitDepth;
    };
    const std::vector<Case> cases {
        { "V_MPEG4/ISO/AVC", AvcC(110, 10), FourCC('a', 'v', 'c', '1'), FourCC('a', 'v', 'c', 'C'), 10 },
        { "V_MPEGH/ISO/HEVC", HvcC(10), FourCC('h', 'v', 'c', '1'), FourCC('h', 'v', 'c', 'C'), 10 },
        { "V_AV1", Av1C(12), FourCC('a', 'v', '0', '1'), FourCC('a', 'v', '1', 'C'), 12 },
        { "V_AV1", {}, FourCC('a', 'v', '0', '1'), 0, 0 },
    };
    for (const Case& test : cases) {
        MkvSpec spec = ClipSpec(3, 3);
        spec.tracks[0].codecId      = test.codec;
        spec.tracks[0].codecPrivate = test.config;
        Error error;
        auto  reader = OpenMkv(spec, nullptr, &error);
        ASSERT_NE(reader, nullptr) << test.codec << ": " << ErrorText(error);
        const VideoStreamInfo& info = reader->videoInfo();
        EXPECT_EQ(info.codecFourcc, test.fourcc) << test.codec;
        EXPECT_EQ(info.configFourcc, test.configFourcc) << test.codec;
        EXPECT_EQ(info.codecConfig, test.config) << test.codec;
        EXPECT_EQ(info.bitDepth, test.bitDepth) << test.codec;
        EXPECT_EQ(reader->videoTrack().codecPrivate, test.config);
        EXPECT_FALSE(reader->vp9KeyFrame().has_value());
    }
}

TEST(MatroskaReader, TheColourElementBecomesTheColourDescription)
{
    MkvSpec spec = ClipSpec(3, 3);
    spec.tracks[0].codecId = "V_AV1";  // VP9's depth comes from its key frame instead
    spec.tracks[0].colour  = Cat(UintElement(0x55B1, 9), UintElement(0x55B2, 10), UintElement(0x55B9, 2),
                                 UintElement(0x55BA, 16), UintElement(0x55BB, 9));
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    const ColourDescription& colour = reader->videoInfo().colour;
    EXPECT_EQ(colour.source, ColourDescription::Source::Matroska);
    EXPECT_EQ(colour.matrix, 9);
    EXPECT_EQ(colour.primaries, 9);
    EXPECT_EQ(colour.transfer, 16);
    EXPECT_TRUE(colour.fullRange);
    EXPECT_EQ(reader->videoInfo().bitDepth, 10) << "BitsPerChannel states the depth";

    // For VP9 the key frame header, which is what the decoder will see, wins.
    MkvSpec vp9 = ClipSpec(3, 3);
    vp9.tracks[0].colour = Cat(UintElement(0x55B2, 10));
    reader = OpenMkv(vp9);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoInfo().bitDepth, 8);
}

TEST(MatroskaReader, DisplaySizeBecomesAPixelAspectRatio)
{
    MkvSpec spec = ClipSpec(3, 3);
    spec.tracks[0].displayWidth  = 96;
    spec.tracks[0].displayHeight = 48;
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoInfo().displayWidth, 96U);
    EXPECT_EQ(reader->videoInfo().displayHeight, 48U);
    EXPECT_EQ(reader->videoInfo().pixelAspect, MakeRational(3, 2));

    // A display aspect ratio (unit 3) of 16:9 on a 4:3 pixel grid.
    MkvSpec ratio = ClipSpec(3, 3);
    ratio.tracks[0].displayWidth  = 16;
    ratio.tracks[0].displayHeight = 9;
    ratio.tracks[0].displayUnit   = 3;
    reader = OpenMkv(ratio);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoInfo().displayWidth, 0U);
    EXPECT_EQ(reader->videoInfo().pixelAspect, MakeRational(4, 3));

    // Square pixels leave the aspect unset.
    MkvSpec square = ClipSpec(3, 3);
    square.tracks[0].displayWidth  = 64;
    square.tracks[0].displayHeight = 48;
    reader = OpenMkv(square);
    ASSERT_NE(reader, nullptr);
    EXPECT_FALSE(reader->videoInfo().pixelAspect.valid());
}

TEST(MatroskaReader, ProjectionPoseRollRotatesTheDisplayTheWayFfmpegWritesIt)
{
    // Checked against ffmpeg: a clip with display rotation 90 (counter-clockwise)
    // is stored with ProjectionPoseRoll 90 and the matrix 0 -1 / 1 0 (rotate270 here).
    struct Case {
        double      roll;
        Orientation orientation;
    };
    for (const Case& test : { Case { 0, Orientation::Identity }, Case { 90, Orientation::Rotate270 },
                              Case { 180, Orientation::Rotate180 }, Case { 270, Orientation::Rotate90 },
                              Case { -90, Orientation::Rotate90 }, Case { 360, Orientation::Identity } }) {
        MkvSpec spec = ClipSpec(3, 3);
        spec.tracks[0].poseRoll = test.roll;
        auto reader = OpenMkv(spec);
        ASSERT_NE(reader, nullptr) << test.roll;
        const auto orientation = ClassifyDisplayMatrix(reader->videoInfo().displayMatrix);
        ASSERT_TRUE(orientation.has_value()) << test.roll;
        EXPECT_EQ(*orientation, test.orientation) << "roll " << test.roll;
    }
    EXPECT_EQ(Orientation::Rotate270, *ClassifyDisplayMatrix(DisplayMatrix { 0, -65536, 0, 65536, 0, 0, 0, 0, 1 << 30 }));

    // A roll that is not a whole number of quarter turns is left alone.
    MkvSpec oblique = ClipSpec(3, 3);
    oblique.tracks[0].poseRoll = 33.0;
    auto reader = OpenMkv(oblique);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoInfo().displayMatrix, kIdentityDisplayMatrix);
}

// --- VP9 key frame header -----------------------------------------------------------

TEST(MatroskaReader, ReadsTheVp9ProfileAndBitDepthFromTheFirstKeyFrame)
{
    struct Case {
        Bytes         key;
        std::uint8_t  profile;
        std::uint8_t  bitDepth;
    };
    for (const Case& test : { Case { kVp9Profile0Key, 0, 8 }, Case { kVp9Profile1Key, 1, 8 }, Case { kVp9Profile2Key, 2, 10 }, Case { kVp9RgbKey, 1, 8 } }) {
        MkvSpec spec = ClipSpec(3, 3);
        spec.clusters[0].blocks[0].frames[0] = Padded(test.key, 40);
        auto reader = OpenMkv(spec);
        ASSERT_NE(reader, nullptr);
        ASSERT_TRUE(reader->vp9KeyFrame().has_value());
        EXPECT_EQ(reader->vp9KeyFrame()->profile, test.profile);
        EXPECT_EQ(reader->videoInfo().bitDepth, test.bitDepth);
        EXPECT_EQ(reader->vp9KeyFrame()->width, 64U);
        EXPECT_EQ(reader->vp9KeyFrame()->height, 48U);
    }
}

TEST(MatroskaReader, AnUnreadableVp9KeyFrameIsAWarningNotAFailure)
{
    MkvSpec spec = ClipSpec(3, 3);
    spec.clusters[0].blocks[0].frames[0] = Bytes(40, 0x11);  // no frame marker
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_FALSE(reader->vp9KeyFrame().has_value());
    EXPECT_FALSE(reader->warnings().empty());
}

TEST(Vp9Header, ParsesRealKeyFrames)
{
    Vp9FrameHeader header;
    Error          error;
    ASSERT_TRUE(ParseVp9UncompressedHeader(kVp9Profile0Key.data(), kVp9Profile0Key.size(), &header, &error)) << ErrorText(error);
    EXPECT_EQ(header.profile, 0);
    EXPECT_TRUE(header.keyFrame);
    EXPECT_TRUE(header.showFrame);
    EXPECT_FALSE(header.showExistingFrame);
    EXPECT_TRUE(header.hasColourConfig);
    EXPECT_EQ(header.bitDepth, 8);
    EXPECT_EQ(header.colourSpace, 0);
    EXPECT_FALSE(header.fullRange);
    EXPECT_EQ(header.subsamplingX, 1);
    EXPECT_EQ(header.subsamplingY, 1);
    EXPECT_EQ(header.width, 64U);
    EXPECT_EQ(header.height, 48U);

    ASSERT_TRUE(ParseVp9UncompressedHeader(kVp9Profile1Key.data(), kVp9Profile1Key.size(), &header, &error));
    EXPECT_EQ(header.profile, 1);
    EXPECT_EQ(header.bitDepth, 8);
    EXPECT_EQ(header.subsamplingX, 0);
    EXPECT_EQ(header.subsamplingY, 0);  // 4:4:4
    EXPECT_EQ(header.width, 64U);

    ASSERT_TRUE(ParseVp9UncompressedHeader(kVp9Profile2Key.data(), kVp9Profile2Key.size(), &header, &error));
    EXPECT_EQ(header.profile, 2);
    EXPECT_EQ(header.bitDepth, 10);
    EXPECT_EQ(header.subsamplingX, 1);
    EXPECT_EQ(header.height, 48U);

    ASSERT_TRUE(ParseVp9UncompressedHeader(kVp9RgbKey.data(), kVp9RgbKey.size(), &header, &error));
    EXPECT_EQ(header.profile, 1);
    EXPECT_EQ(header.colourSpace, 7);
    EXPECT_TRUE(header.fullRange);
    EXPECT_EQ(header.subsamplingX, 0);
    EXPECT_EQ(header.width, 64U);
    EXPECT_EQ(header.height, 48U);
}

TEST(Vp9Header, AnInterFrameHasNoColourConfiguration)
{
    Vp9FrameHeader header;
    Error          error;
    ASSERT_TRUE(ParseVp9UncompressedHeader(kVp9InterFrame.data(), kVp9InterFrame.size(), &header, &error)) << ErrorText(error);
    EXPECT_FALSE(header.keyFrame);
    EXPECT_FALSE(header.intraOnly);
    EXPECT_TRUE(header.showFrame);
    EXPECT_FALSE(header.hasColourConfig);
    EXPECT_EQ(header.width, 0U);
}

// A tiny MSB-first bit writer for hand-made headers.
struct Bits {
    Bytes         bytes;
    std::size_t   used { 0 };
    Bits& put(std::uint32_t value, int count)
    {
        for (int index = count - 1; index >= 0; --index) {
            if (used % 8 == 0) bytes.push_back(0);
            if ((value >> index) & 1U) bytes.back() |= static_cast<std::uint8_t>(0x80U >> (used % 8));
            ++used;
        }
        return *this;
    }
};

TEST(Vp9Header, HandMadeHeadersCoverTheOtherBranches)
{
    Vp9FrameHeader header;
    Error          error;
    {
        // profile 3, 12-bit, 4:4:0 (subsampling x 0, y 1), key frame, limited range.
        Bits bits;
        bits.put(2, 2).put(1, 1).put(1, 1).put(0, 1).put(0, 1).put(0, 1).put(1, 1).put(0, 1);
        bits.put(0x49, 8).put(0x83, 8).put(0x42, 8);
        bits.put(1, 1).put(2, 3).put(0, 1).put(0, 1).put(1, 1).put(0, 1);
        bits.put(1919, 16).put(1079, 16);
        ASSERT_TRUE(ParseVp9UncompressedHeader(bits.bytes.data(), bits.bytes.size(), &header, &error)) << ErrorText(error);
        EXPECT_EQ(header.profile, 3);
        EXPECT_EQ(header.bitDepth, 12);
        EXPECT_EQ(header.colourSpace, 2);
        EXPECT_EQ(header.subsamplingX, 0);
        EXPECT_EQ(header.subsamplingY, 1);
        EXPECT_EQ(header.width, 1920U);
        EXPECT_EQ(header.height, 1080U);
    }
    {
        // show_existing_frame: nothing else follows.
        Bits bits;
        bits.put(2, 2).put(0, 1).put(0, 1).put(1, 1).put(5, 3);
        ASSERT_TRUE(ParseVp9UncompressedHeader(bits.bytes.data(), bits.bytes.size(), &header, &error));
        EXPECT_TRUE(header.showExistingFrame);
        EXPECT_FALSE(header.keyFrame);
        EXPECT_FALSE(header.hasColourConfig);
    }
    {
        // Intra-only frame, profile 0: colour config implied (8-bit BT.601 4:2:0), size present.
        Bits bits;
        bits.put(2, 2).put(0, 1).put(0, 1).put(0, 1).put(1, 1).put(0, 1).put(0, 1);  // non-key, not shown, error resilient 0
        bits.put(1, 1);                                                              // intra_only
        bits.put(0, 2);                                                              // reset_frame_context
        bits.put(0x49, 8).put(0x83, 8).put(0x42, 8);
        bits.put(0xFF, 8);                                                           // refresh_frame_flags
        bits.put(639, 16).put(359, 16);
        ASSERT_TRUE(ParseVp9UncompressedHeader(bits.bytes.data(), bits.bytes.size(), &header, &error)) << ErrorText(error);
        EXPECT_TRUE(header.intraOnly);
        EXPECT_TRUE(header.hasColourConfig);
        EXPECT_EQ(header.bitDepth, 8);
        EXPECT_EQ(header.colourSpace, 1);
        EXPECT_EQ(header.width, 640U);
        EXPECT_EQ(header.height, 360U);
    }
}

TEST(Vp9Header, MalformedHeadersFailWithTheRightKind)
{
    Vp9FrameHeader header;
    Error          error;
    auto fails = [&](const Bytes& bytes, ErrorKind kind) {
        EXPECT_FALSE(ParseVp9UncompressedHeader(bytes.data(), bytes.size(), &header, &error));
        EXPECT_EQ(error.kind, kind) << ErrorText(error);
    };
    Bytes badMarker = kVp9Profile0Key;
    badMarker[0]    = 0x42;
    fails(badMarker, ErrorKind::Corrupt);
    Bytes badSync = kVp9Profile0Key;
    badSync[2]    = 0x00;
    fails(badSync, ErrorKind::Corrupt);
    {
        Bits bits;  // profile 3 with its reserved bit set
        bits.put(2, 2).put(1, 1).put(1, 1).put(1, 1);
        fails(bits.bytes, ErrorKind::Corrupt);
    }
    {
        Bits bits;  // RGB in profile 0 is not allowed
        bits.put(2, 2).put(0, 1).put(0, 1).put(0, 1).put(0, 1).put(1, 1).put(0, 1);
        bits.put(0x49, 8).put(0x83, 8).put(0x42, 8).put(7, 3).put(0, 8);
        fails(bits.bytes, ErrorKind::Corrupt);
    }
    {
        Bits bits;  // a reserved bit set in a profile 1 colour config
        bits.put(2, 2).put(1, 1).put(0, 1).put(0, 1).put(0, 1).put(1, 1).put(0, 1);
        bits.put(0x49, 8).put(0x83, 8).put(0x42, 8).put(2, 3).put(0, 1).put(0, 1).put(0, 1).put(1, 1).put(0, 16);
        fails(bits.bytes, ErrorKind::Corrupt);
    }
    // Every shorter prefix of a real key frame ends inside the header.
    for (std::size_t length = 0; length < 9; ++length) {
        EXPECT_FALSE(ParseVp9UncompressedHeader(kVp9Profile0Key.data(), length, &header, &error)) << length;
        EXPECT_EQ(error.kind, ErrorKind::Truncated) << length;
    }
    EXPECT_TRUE(ParseVp9UncompressedHeader(kVp9Profile0Key.data(), 9, &header, &error));
}

// --- Lacing -------------------------------------------------------------------------

TEST(MatroskaReader, IndexesEveryFrameOfXiphEbmlAndFixedLacedAudio)
{
    MkvSpec spec;
    spec.tracks.push_back(VideoTrack());
    spec.tracks.push_back(OpusTrack());
    ClusterSpec cluster;
    for (std::size_t index = 0; index < 5; ++index) cluster.blocks.push_back(VideoBlock(index));
    auto audio = [](std::int64_t time, Lacing lacing, std::vector<std::size_t> sizes, std::size_t seed) {
        BlockSpec block;
        block.track  = 2;
        block.time   = time;
        block.lacing = lacing;
        for (std::size_t index = 0; index < sizes.size(); ++index) block.frames.push_back(FrameBytes(2, seed + index, sizes[index]));
        return block;
    };
    cluster.blocks.push_back(audio(0, Lacing::Xiph, { 5, 300, 17 }, 0));
    cluster.blocks.push_back(audio(60, Lacing::Ebml, { 10, 200, 7, 7 }, 10));
    cluster.blocks.push_back(audio(140, Lacing::Fixed, { 12, 12, 12 }, 20));
    spec.clusters.push_back(cluster);
    BuiltMkv built;
    Error    error;
    auto     reader = OpenMkv(spec, &built, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);

    const auto expected = FramesOf(built, 2);
    ASSERT_EQ(expected.size(), 10U);
    const auto& packets = reader->packets(1);
    ASSERT_EQ(packets.size(), 10U);
    for (std::size_t index = 0; index < packets.size(); ++index) {
        EXPECT_EQ(packets[index].offset, expected[index].offset) << index;
        EXPECT_EQ(packets[index].size, expected[index].data.size()) << index;
        EXPECT_EQ(packets[index].ptsNs, static_cast<std::int64_t>(index) * 20 * kMs) << "frames of a laced block are one default duration apart (" << index << ")";
        EXPECT_EQ(packets[index].durationNs, 20 * kMs) << index;
        EXPECT_TRUE(packets[index].keyframe);
        Bytes payload;
        ASSERT_TRUE(reader->readPacket(1, index, &payload, &error)) << ErrorText(error);
        EXPECT_EQ(payload, expected[index].data) << index;
    }
    const MatroskaTrack& track = reader->tracks()[1];
    EXPECT_EQ(track.codec, MatroskaCodec::Opus);
    EXPECT_TRUE(track.supported);
    EXPECT_EQ(track.type, MatroskaTrackType::Audio);
    EXPECT_EQ(track.codecPrivate, spec.tracks[1].codecPrivate);
    EXPECT_EQ(track.codecDelayNs, 6500000);
    EXPECT_EQ(track.seekPreRollNs, 80000000);
    EXPECT_EQ(track.channels, 2U);
    EXPECT_EQ(track.samplingFrequency, 48000.0);
    EXPECT_EQ(reader->videoSamples().size(), 5U) << "audio frames are not video samples";
}

TEST(MatroskaReader, ALacedBlocksDurationIsSplitAcrossItsFrames)
{
    MkvSpec spec = ClipSpec(1, 1);
    TrackSpec audio = OpusTrack();
    audio.defaultDurationNs = 0;
    spec.tracks.push_back(audio);
    BlockSpec block;
    block.track    = 2;
    block.group    = true;
    block.duration = 60;  // three frames in 60 ms
    block.lacing   = Lacing::Xiph;
    for (std::size_t index = 0; index < 3; ++index) block.frames.push_back(FrameBytes(2, index, 20));
    spec.clusters[0].blocks.push_back(block);
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    ASSERT_EQ(reader->packets(1).size(), 3U);
    EXPECT_EQ(reader->packets(1)[1].durationNs, 20 * kMs);
    EXPECT_EQ(reader->packets(1)[2].ptsNs, 40 * kMs);
}

TEST(MatroskaReader, LacedFramePayloadDoesNotCountAgainstTheHeaderBudget)
{
    // 300 Xiph-laced blocks of 2 x 30000 bytes: 18 MB of audio, more than the 16 MiB header
    // budget, yet only the few bytes of each lace table are header bytes.
    MkvSpec spec = ClipSpec(5, 5);
    spec.tracks.push_back(OpusTrack());
    for (std::size_t index = 0; index < 300; ++index) {
        BlockSpec block;
        block.track  = 2;
        block.time   = static_cast<std::int64_t>(index) * 40;
        block.lacing = Lacing::Xiph;
        block.frames.push_back(FrameBytes(2, index * 2, 30000));
        block.frames.push_back(FrameBytes(2, index * 2 + 1, 30000));
        spec.clusters[0].blocks.push_back(block);
    }
    Error error;
    auto  reader = OpenMkv(spec, nullptr, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    EXPECT_EQ(reader->packets(1).size(), 600U);
    EXPECT_GT(reader->packets(1).size() * 30000U, MatroskaLimits().maxMetadataBytes);
}

TEST(MatroskaReader, DiscardPaddingAndTheInvisibleFlagAreCarriedOnThePacket)
{
    MkvSpec spec = ClipSpec(1, 1);
    spec.tracks.push_back(OpusTrack());
    BlockSpec block;
    block.track            = 2;
    block.group            = true;
    block.discardPaddingNs = 3500000;
    block.invisible        = true;
    block.frames.push_back(FrameBytes(2, 0, 10));
    spec.clusters[0].blocks.push_back(block);
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    ASSERT_EQ(reader->packets(1).size(), 1U);
    EXPECT_EQ(reader->packets(1)[0].discardPaddingNs, 3500000);
    EXPECT_TRUE(reader->packets(1)[0].invisible);
}

TEST(MatroskaReader, BrokenLacingInTheMiddleOfTheFileKeepsTheFramesBeforeIt)
{
    MkvSpec spec = ClipSpec(5, 5);
    spec.tracks.push_back(OpusTrack());
    BlockSpec bad;
    bad.track  = 2;
    bad.time   = 200;
    bad.lacing = Lacing::Fixed;
    for (std::size_t size : std::vector<std::size_t> { 10, 11, 13 }) bad.frames.push_back(FrameBytes(2, size, size));  // 34 bytes: not divisible by 3
    spec.clusters[0].blocks.push_back(bad);
    spec.clusters[0].blocks.push_back(VideoBlock(5));  // after the damage: must not be indexed
    Error error;
    auto  reader = OpenMkv(spec, nullptr, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    EXPECT_EQ(reader->videoSamples().size(), 5U);
    EXPECT_FALSE(reader->warnings().empty());
}

TEST(MatroskaReader, BrokenLacingBeforeAnyKeyFrameFailsTheOpen)
{
    MkvSpec spec = ClipSpec(5, 5);
    spec.tracks.push_back(OpusTrack());
    BlockSpec bad;
    bad.track  = 2;
    bad.time   = 0;
    bad.lacing = Lacing::Fixed;
    for (std::size_t size : std::vector<std::size_t> { 10, 11, 13 }) bad.frames.push_back(FrameBytes(2, size, size));
    spec.clusters[0].blocks.insert(spec.clusters[0].blocks.begin(), bad);
    Error error;
    EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
}

TEST(MatroskaReader, LaceTablesThatContradictTheBlockAreCorrupt)
{
    auto build = [](Bytes payload, std::uint8_t flags) {
        MkvSpec spec = ClipSpec(1, 1);
        spec.tracks.push_back(OpusTrack());
        BlockSpec block;
        block.track      = 2;
        block.lacing     = flags == 0x02 ? Lacing::Xiph : Lacing::Ebml;
        block.rawPayload = std::move(payload);
        spec.clusters[0].blocks.insert(spec.clusters[0].blocks.begin(), block);
        return spec;
    };
    // Xiph, 3 frames, sizes 200 and 200 in a 10-byte block.
    Error error;
    EXPECT_EQ(OpenMkv(build(Bytes { 2, 200, 200, 1, 2, 3, 4, 5 }, 0x02), nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    // Xiph, a size that never ends (all 255s) running off the block.
    EXPECT_EQ(OpenMkv(build(Bytes { 1, 255, 255, 255 }, 0x02), nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    // EBML: the first size alone exceeds the block.
    EXPECT_EQ(OpenMkv(build(Bytes { 2, 0xFF - 0x80 + 0x80, 0, 0 }, 0x06), nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    // EBML: a difference that makes a size negative: sizes 2, then 2 + (-5).
    EXPECT_EQ(OpenMkv(build(Bytes { 3, 0x82, 0xBA, 0, 0, 0, 0, 0 }, 0x06), nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
}

TEST(MatroskaReader, TooManyLacedFramesIsALimitNotCorruption)
{
    MkvSpec spec = ClipSpec(5, 5);
    spec.tracks.push_back(OpusTrack());
    BlockSpec block;
    block.track  = 2;
    block.time   = 0;
    block.lacing = Lacing::Xiph;
    for (std::size_t index = 0; index < 5; ++index) block.frames.push_back(FrameBytes(2, index, 8));
    spec.clusters[0].blocks.push_back(block);
    MatroskaOptions options;
    options.limits.maxLaceFrames = 3;
    Error error;
    EXPECT_EQ(OpenMkv(spec, nullptr, &error, options), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded) << "even after a key frame, a limit refuses the file";
}

// --- Segment and Cluster shapes ----------------------------------------------------

TEST(MatroskaReader, UnknownSizeSegmentAndClustersAreFollowedToTheirEnd)
{
    MkvSpec reference = ClipSpec(12, 5);
    reference.writeCues = true;
    reference.tagsAfter = true;
    auto known = OpenMkv(reference);
    ASSERT_NE(known, nullptr);

    MkvSpec live = reference;
    live.segmentUnknownSize = true;
    for (ClusterSpec& cluster : live.clusters) cluster.unknownSize = true;
    BuiltMkv built;
    Error    error;
    auto     reader = OpenMkv(live, &built, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    EXPECT_EQ(Shape(*reader), Shape(*known));
    const auto frames = FramesOf(built, 1);
    for (std::size_t index = 0; index < frames.size(); ++index) EXPECT_EQ(reader->videoSamples()[index].offset, frames[index].offset);

    // The last cluster of a live file simply ends with the file.
    live.writeCues = false;
    live.tagsAfter = false;
    reader = OpenMkv(live, nullptr, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    EXPECT_EQ(reader->videoSamples().size(), 12U);
    EXPECT_TRUE(reader->warnings().empty());
}

TEST(MatroskaReader, CuesPresentAbsentOrFirstDoNotChangeTheIndex)
{
    MkvSpec plain = ClipSpec(15, 5);
    auto    base  = OpenMkv(plain);
    ASSERT_NE(base, nullptr);
    for (int variant = 0; variant < 3; ++variant) {
        MkvSpec spec    = plain;
        spec.writeCues  = true;
        spec.cuesFirst  = variant == 1;
        spec.voidBefore = variant == 2;
        spec.writeSeekHead = variant == 2;
        auto reader = OpenMkv(spec);
        ASSERT_NE(reader, nullptr) << variant;
        EXPECT_EQ(Shape(*reader), Shape(*base)) << variant;
        EXPECT_EQ(reader->findVideoKeyframeAtOrBefore(250 * kMs), base->findVideoKeyframeAtOrBefore(250 * kMs));
    }
}

TEST(MatroskaReader, SeekFindsTheLastKeyFrameAtOrBeforeATimeWithoutCues)
{
    auto reader = OpenMkv(ClipSpec(15, 5));  // key frames at samples 0, 5, 10: 0, 200, 400 ms
    ASSERT_NE(reader, nullptr);
    auto seek = [&](std::int64_t ns) { return reader->findVideoKeyframeAtOrBefore(ns); };
    EXPECT_EQ(seek(-1), std::optional<std::size_t> { 0 });
    EXPECT_EQ(seek(0), std::optional<std::size_t> { 0 });
    EXPECT_EQ(seek(199 * kMs), std::optional<std::size_t> { 0 });
    EXPECT_EQ(seek(200 * kMs), std::optional<std::size_t> { 5 });
    EXPECT_EQ(seek(399 * kMs), std::optional<std::size_t> { 5 });
    EXPECT_EQ(seek(400 * kMs), std::optional<std::size_t> { 10 });
    EXPECT_EQ(seek(std::numeric_limits<std::int64_t>::max()), std::optional<std::size_t> { 10 });
}

TEST(MatroskaReader, TracksAfterTheClustersAreRefused)
{
    MkvSpec spec = ClipSpec(6, 3);
    spec.tracksAfterClusters = true;
    Error error;
    EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
}

TEST(MatroskaReader, ABlockForAnUnknownTrackIsSkippedWithAWarning)
{
    MkvSpec spec = ClipSpec(5, 5);
    BlockSpec stray = VideoBlock(9, 5, 40, 9);
    spec.clusters[0].blocks.push_back(stray);
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoSamples().size(), 5U);
    EXPECT_FALSE(reader->warnings().empty());
}

TEST(MatroskaReader, ADuplicateTrackNumberIsIgnoredWithAWarning)
{
    MkvSpec spec = ClipSpec(5, 5);
    TrackSpec twin = VideoTrack(1, "V_AV1");
    spec.tracks.push_back(twin);
    auto reader = OpenMkv(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->tracks().size(), 1U);
    EXPECT_FALSE(reader->warnings().empty());
}

TEST(MatroskaReader, ASegmentLongerThanTheFileWarnsAndKeepsWhatIsThere)
{
    BuiltMkv built = BuildMkv(ClipSpec(12, 5));
    // The Segment size is the second vint after the EBML header; bump it past the end.
    Bytes bytes = built.bytes;
    const std::size_t at = FindBytes(bytes, { 0x18, 0x53, 0x80, 0x67 });
    ASSERT_LT(at, bytes.size());
    const std::size_t sizeLength = static_cast<std::size_t>(ebml::VintLength(bytes[at + 4]));
    ASSERT_GT(sizeLength, 0U);
    // Rebuild with an eight-byte size that claims far more than the file holds.
    Bytes patched(bytes.begin(), bytes.begin() + static_cast<std::ptrdiff_t>(at + 4));
    Append(patched, Vint(1ULL << 40, 8));
    patched.insert(patched.end(), bytes.begin() + static_cast<std::ptrdiff_t>(at + 4 + sizeLength), bytes.end());
    Error error;
    auto  reader = OpenBytes(patched, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    EXPECT_EQ(reader->videoSamples().size(), 12U);
    EXPECT_FALSE(reader->warnings().empty());
}

// --- EBML header, tracks and encodings ---------------------------------------------

TEST(MatroskaReader, ChecksTheEbmlHeader)
{
    MkvSpec spec = ClipSpec(3, 3);
    Error   error;
    EXPECT_NE(OpenMkv(spec, nullptr, &error), nullptr) << ErrorText(error);
    spec.docType = "matroska";
    auto reader  = OpenMkv(spec, nullptr, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    EXPECT_EQ(reader->info().docType, "matroska");

    spec.docType = "ogg";
    EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);

    spec = ClipSpec(3, 3);
    spec.docReadVersion = 5;
    EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    spec = ClipSpec(3, 3);
    spec.maxIdLength = 5;
    EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    spec = ClipSpec(3, 3);
    spec.maxSizeLength = 9;
    EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
}

TEST(MatroskaReader, NonMatroskaInputIsNotThisFormat)
{
    Error error;
    EXPECT_EQ(OpenBytes({}, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);
    EXPECT_EQ(OpenBytes(Bytes { 0x1A, 0x45, 0xDF }, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);
    const std::string text = "plain text, not an EBML file at all";
    EXPECT_EQ(OpenBytes(Bytes(text.begin(), text.end()), &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);
    Mp4Spec mp4;
    mp4.samples = Samples(2);
    EXPECT_EQ(OpenBytes(BuildMp4(mp4).bytes, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);
    EXPECT_EQ(MatroskaReader::Open(nullptr, &error), nullptr);

    // An EBML header and nothing else: there is no Segment.
    const Bytes headerOnly = BuildMkv(ClipSpec(3, 3)).bytes;
    const std::size_t headerEnd = FindBytes(headerOnly, { 0x18, 0x53, 0x80, 0x67 });
    EXPECT_EQ(OpenBytes(Bytes(headerOnly.begin(), headerOnly.begin() + static_cast<std::ptrdiff_t>(headerEnd)), &error), nullptr);
    EXPECT_NE(error.kind, ErrorKind::None);
}

TEST(MatroskaReader, CodecsItDoesNotPlayAreUnsupportedAndNamed)
{
    auto errorFor = [](MkvSpec spec) {
        Error error;
        EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
        return error;
    };
    MkvSpec vp8 = ClipSpec(3, 3);
    vp8.tracks[0].codecId = "V_VP8";
    Error error = errorFor(vp8);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("V_VP8"), std::string::npos) << error.message;

    MkvSpec vfw = ClipSpec(3, 3);
    vfw.tracks[0].codecId = "V_MS/VFW/FOURCC";
    error = errorFor(vfw);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("V_MS/VFW/FOURCC"), std::string::npos) << error.message;

    MkvSpec audioOnly;
    audioOnly.tracks.push_back(OpusTrack(1));
    error = errorFor(audioOnly);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("no video track"), std::string::npos);

    MkvSpec disabledOnly = ClipSpec(3, 3);
    disabledOnly.tracks[0].enabled = false;
    // A lone disabled but supported video track is still the video track.
    EXPECT_NE(OpenMkv(disabledOnly), nullptr);

    // The first supported enabled video track wins over an earlier unsupported one.
    MkvSpec second = ClipSpec(3, 3);
    second.tracks.insert(second.tracks.begin(), VideoTrack(7, "V_VP8"));
    auto reader = OpenMkv(second);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->videoTrack().number, 1U);
    EXPECT_FALSE(reader->tracks()[0].supported);
    EXPECT_NE(reader->tracks()[0].unsupportedReason.find("V_VP8"), std::string::npos);

    // An unsupported audio codec does not stop the video from opening.
    MkvSpec withVoice = ClipSpec(3, 3);
    TrackSpec voice   = OpusTrack();
    voice.codecId     = "A_AC3";
    withVoice.tracks.push_back(voice);
    reader = OpenMkv(withVoice);
    ASSERT_NE(reader, nullptr);
    EXPECT_FALSE(reader->tracks()[1].supported);
    EXPECT_NE(reader->tracks()[1].unsupportedReason.find("A_AC3"), std::string::npos);
}

TEST(MatroskaReader, VideoTracksMissingWhatTheirCodecNeedsAreCorrupt)
{
    auto errorKind = [](MkvSpec spec) {
        Error error;
        EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
        return error.kind;
    };
    MkvSpec noAvcC = ClipSpec(3, 3);
    noAvcC.tracks[0].codecId = "V_MPEG4/ISO/AVC";
    EXPECT_EQ(errorKind(noAvcC), ErrorKind::Corrupt);
    MkvSpec shortHvcC = ClipSpec(3, 3);
    shortHvcC.tracks[0].codecId      = "V_MPEGH/ISO/HEVC";
    shortHvcC.tracks[0].codecPrivate = Bytes(8, 1);
    EXPECT_EQ(errorKind(shortHvcC), ErrorKind::Corrupt);
    MkvSpec badAv1 = ClipSpec(3, 3);
    badAv1.tracks[0].codecId      = "V_AV1";
    badAv1.tracks[0].codecPrivate = Bytes { 0x01, 0, 0, 0 };
    EXPECT_EQ(errorKind(badAv1), ErrorKind::Corrupt);
    MkvSpec noSize = ClipSpec(3, 3);
    noSize.tracks[0].width = 0;
    EXPECT_EQ(errorKind(noSize), ErrorKind::Corrupt);
    MkvSpec noFrames = ClipSpec(3, 3);
    noFrames.clusters.clear();
    EXPECT_EQ(errorKind(noFrames), ErrorKind::Corrupt);
    MkvSpec noKey = ClipSpec(3, 3, 100);
    noKey.clusters[0].blocks[0].key = false;
    EXPECT_EQ(errorKind(noKey), ErrorKind::Corrupt);
}

TEST(MatroskaReader, HeaderStrippingIsUndoneWhenAFrameIsRead)
{
    MkvSpec spec = ClipSpec(4, 4);
    spec.tracks[0].headerStrip = { 0x00, 0x00, 0x01, 0xB3 };
    BuiltMkv built;
    Error    error;
    auto     reader = OpenMkv(spec, &built, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    const auto frames = FramesOf(built, 1);
    EXPECT_EQ(reader->videoSamples()[1].size, frames[1].data.size()) << "the index holds the stored size";
    Bytes payload;
    ASSERT_TRUE(reader->readSample(1, &payload, &error));
    Bytes expected = spec.tracks[0].headerStrip;
    Append(expected, frames[1].data);
    EXPECT_EQ(payload, expected);
    ASSERT_TRUE(reader->readPacket(0, 2, &payload, &error));
    expected = spec.tracks[0].headerStrip;
    Append(expected, frames[2].data);
    EXPECT_EQ(payload, expected);
    EXPECT_EQ(reader->videoTrack().headerStrip, spec.tracks[0].headerStrip);
}

TEST(MatroskaReader, EncryptedAndCompressedTracksAreUnsupportedWithAReason)
{
    MkvSpec encrypted = ClipSpec(3, 3);
    encrypted.tracks[0].encrypted = true;
    Error error;
    EXPECT_EQ(OpenMkv(encrypted, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("encrypted"), std::string::npos) << error.message;

    MkvSpec zlib = ClipSpec(3, 3);
    zlib.tracks[0].compressionAlgo = 0;
    zlib.tracks[0].headerStrip     = { 1, 2, 3 };
    EXPECT_EQ(OpenMkv(zlib, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("zlib"), std::string::npos) << error.message;
}

TEST(MatroskaReader, ReadsAreRefusedForAnOutOfRangeIndexAndAnOversizedFrame)
{
    MatroskaOptions options;
    options.limits.maxReadBytes = 20;
    Bytes payload;
    Error error;
    auto  reader = OpenMkv(ClipSpec(3, 3), nullptr, &error, options);
    ASSERT_NE(reader, nullptr);
    EXPECT_FALSE(reader->readSample(3, &payload, &error));
    EXPECT_FALSE(reader->readPacket(4, 0, &payload, &error));
    EXPECT_FALSE(reader->readPacket(0, 99, &payload, &error));
    EXPECT_FALSE(reader->readSample(0, &payload, &error));
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
}

// --- Limits and untrusted input -----------------------------------------------------

TEST(MatroskaReader, ConfiguredLimitsRefuseWhatExceedsThem)
{
    const BuiltMkv built = BuildMkv(ClipSpec(12, 5));
    Error error;
    {
        MatroskaOptions options;
        options.limits.maxPackets = 5;
        EXPECT_EQ(OpenBytes(built.bytes, &error, options), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
    }
    {
        MatroskaOptions options;
        options.limits.maxScanTime = std::chrono::milliseconds(0);
        EXPECT_EQ(OpenBytes(built.bytes, &error, options), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
    }
    {
        MatroskaOptions options;
        options.limits.maxMetadataBytes = 16;
        EXPECT_EQ(OpenBytes(built.bytes, &error, options), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
    }
    {
        MatroskaOptions options;
        options.limits.maxTracks = 0;
        EXPECT_EQ(OpenBytes(built.bytes, &error, options), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
    }
    {
        MkvSpec spec = ClipSpec(3, 3);
        spec.tracks[0].codecId      = "V_AV1";
        spec.tracks[0].codecPrivate = Av1C(8);
        MatroskaOptions options;
        options.limits.maxCodecPrivateBytes = 2;
        EXPECT_EQ(OpenBytes(BuildMkv(spec).bytes, &error, options), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
    }
}

TEST(MatroskaReader, AFrameLargerThanTheTrackAllowsIsCorrupt)
{
    // The very first (key) frame is bigger than the video track's 64x48x4 (at least 64 KiB) allowance.
    MkvSpec spec = ClipSpec(3, 3);
    spec.clusters[0].blocks[0].frames[0] = Padded(kVp9Profile0Key, 70000);
    Error error;
    EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);

    // Later in the file it ends the index instead.
    MkvSpec later = ClipSpec(6, 6);
    later.clusters[0].blocks[4].frames[0] = Bytes(70000, 1);
    auto reader = OpenMkv(later, nullptr, &error);
    ASSERT_NE(reader, nullptr) << ErrorText(error);
    EXPECT_EQ(reader->videoSamples().size(), 4U);
    EXPECT_FALSE(reader->warnings().empty());
}

TEST(MatroskaReader, TimestampsThatOverflowAreCorrupt)
{
    MkvSpec spec = ClipSpec(3, 3);
    spec.clusters[0].timecode = std::int64_t { 1 } << 62;
    spec.clusters[0].blocks.clear();
    BlockSpec block = VideoBlock(0, 1);
    block.time      = spec.clusters[0].timecode;
    spec.clusters[0].blocks.push_back(block);
    Error error;
    EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
}

TEST(MatroskaReader, MalformedElementsFailCleanly)
{
    const BuiltMkv good = BuildMkv(ClipSpec(8, 4));
    ASSERT_NE(OpenBytes(good.bytes), nullptr);
    auto find = [&](const Bytes& pattern) { return FindBytes(good.bytes, pattern); };
    Error error;
    {
        // An element id that starts with a zero byte (longer than 4 bytes).
        Bytes bytes = good.bytes;
        bytes[find({ 0x16, 0x54, 0xAE, 0x6B })] = 0x00;  // the Tracks id
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr);
        EXPECT_NE(error.kind, ErrorKind::None);
    }
    {
        // The Tracks size claims more than the file holds.
        Bytes bytes = good.bytes;
        const std::size_t at = find({ 0x16, 0x54, 0xAE, 0x6B });
        bytes[at + 4] = 0x01;  // an 8-byte size ...
        bytes.insert(bytes.begin() + static_cast<std::ptrdiff_t>(at + 5), { 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr);
        EXPECT_NE(error.kind, ErrorKind::None);
    }
    {
        // TimecodeScale of zero.
        MkvSpec spec = ClipSpec(4, 4);
        spec.timecodeScale = 0;
        EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    }
    {
        // A track with number 0.
        MkvSpec spec = ClipSpec(4, 4);
        spec.tracks[0].number = 0;
        EXPECT_EQ(OpenMkv(spec, nullptr, &error), nullptr);
        EXPECT_NE(error.kind, ErrorKind::None);
    }
}

TEST(MatroskaReader, EveryTruncationOfAFileEndsInACleanResult)
{
    MkvSpec spec = ClipSpec(12, 4);
    spec.tracks.push_back(OpusTrack());
    BlockSpec laced;
    laced.track  = 2;
    laced.time   = 0;
    laced.lacing = Lacing::Xiph;
    for (std::size_t index = 0; index < 3; ++index) laced.frames.push_back(FrameBytes(2, index, 30 + index));
    spec.clusters[0].blocks.push_back(laced);
    spec.writeCues = true;
    const BuiltMkv built = BuildMkv(spec);
    std::size_t    opened = 0;
    for (std::size_t length = 0; length < built.bytes.size(); ++length) {
        Bytes prefix(built.bytes.begin(), built.bytes.begin() + static_cast<std::ptrdiff_t>(length));
        Error error;
        auto  reader = OpenBytes(prefix, &error);
        if (reader == nullptr) {
            EXPECT_TRUE(error) << length;
            continue;
        }
        ++opened;
        ASSERT_FALSE(reader->videoSamples().empty()) << length;
        for (const Sample& sample : reader->videoSamples()) EXPECT_LE(sample.offset + sample.size, length) << length;
        EXPECT_TRUE(reader->videoSamples().front().sync) << length;
    }
    EXPECT_GT(opened, 50U) << "a cut in the middle of the media still leaves a playable prefix";
}

// A deterministic stand-in for a fuzzer (run under -fsanitize=address,undefined to
// make out-of-bounds reads observable): thousands of mutations of valid files.
TEST(MatroskaReader, RandomMutationsNeverCrashOrDescribeBytesOutsideTheFile)
{
    MkvSpec rich = ClipSpec(20, 6);
    rich.tracks.push_back(OpusTrack());
    rich.tracks[0].colour = Cat(UintElement(0x55B1, 1), UintElement(0x55B9, 1));
    rich.writeCues = true;
    rich.tagsAfter = true;
    for (ClusterSpec& cluster : rich.clusters) {
        BlockSpec audio;
        audio.track  = 2;
        audio.time   = cluster.timecode;
        audio.lacing = Lacing::Ebml;
        for (std::size_t index = 0; index < 4; ++index) audio.frames.push_back(FrameBytes(2, index, 10 + 3 * index));
        cluster.blocks.push_back(audio);
    }
    MkvSpec live = ClipSpec(12, 4);
    live.segmentUnknownSize = true;
    for (ClusterSpec& cluster : live.clusters) {
        cluster.unknownSize = true;
        for (BlockSpec& block : cluster.blocks) {
            block.group     = true;
            block.reference = ! block.key;
            block.duration  = 40;
        }
    }
    MkvSpec stripped = ClipSpec(8, 4);
    stripped.tracks[0].headerStrip = { 1, 2, 3 };

    std::uint32_t state = 0xBADC0DE;
    auto next = [&state]() {
        state = state * 1664525U + 1013904223U;
        return state >> 8;
    };
    std::size_t opened = 0;
    for (const MkvSpec* spec : { &rich, &live, &stripped }) {
        const Bytes original = BuildMkv(*spec).bytes;
        for (int round = 0; round < 3000; ++round) {
            Bytes bytes = original;
            switch (next() % 4) {
            case 0:
                for (std::uint32_t count = 1 + next() % 4; count > 0; --count) bytes[next() % bytes.size()] ^= static_cast<std::uint8_t>(1U << (next() % 8));
                break;
            case 1:
                for (std::uint32_t count = 1 + next() % 3; count > 0; --count) bytes[next() % bytes.size()] = static_cast<std::uint8_t>(next());
                break;
            case 2: {
                const std::size_t at  = next() % bytes.size();
                const std::size_t run = std::min<std::size_t>(1 + next() % 8, bytes.size() - at);
                std::fill_n(bytes.begin() + static_cast<std::ptrdiff_t>(at), run, (next() & 1U) != 0 ? 0xFF : 0x00);
                break;
            }
            default: bytes.resize(next() % bytes.size()); break;
            }
            Error error;
            auto  reader = OpenBytes(bytes, &error);
            if (reader == nullptr) {
                ASSERT_TRUE(error) << "a refusal must say why (round " << round << ")";
                continue;
            }
            ++opened;
            ASSERT_FALSE(reader->videoSamples().empty());
            for (const Sample& sample : reader->videoSamples()) ASSERT_LE(sample.offset + sample.size, bytes.size()) << "round " << round;
            for (std::size_t track = 0; track < reader->tracks().size(); ++track) {
                for (const MatroskaPacket& packet : reader->packets(track)) ASSERT_LE(packet.offset + packet.size, bytes.size()) << "round " << round;
            }
            reader->findVideoKeyframeAtOrBefore(0);
            reader->findVideoKeyframeAtOrBefore(std::numeric_limits<std::int64_t>::max());
            reader->findVideoKeyframeAtOrBefore(std::numeric_limits<std::int64_t>::min());
            Bytes payload;
            EXPECT_TRUE(reader->readSample(reader->videoSamples().size() - 1, &payload, &error)) << ErrorText(error);
        }
    }
    EXPECT_GT(opened, 300U) << "the mutations should leave many files readable, or the loop proves little";
}

} // namespace
} // namespace wallpaper::media
