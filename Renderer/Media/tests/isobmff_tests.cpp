// The ISO-BMFF reader against files this test assembles itself (mp4_builder.hpp):
// sample tables, edit lists, composition offsets, every stsd codec entry, all
// eight display orientations, keyframe seeking, and an input that is truncated,
// junk, oversized or randomly mutated must fail cleanly instead of reading out
// of bounds.
#include "Media/ByteSource.hpp"
#include "Media/DisplayMatrix.hpp"
#include "Media/IsoBmff/IsoBmffReader.hpp"

#include "mp4_builder.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper::media
{
namespace
{

using namespace testing;

std::unique_ptr<IsoBmffReader> OpenBytes(const Bytes& bytes, Error* error = nullptr,
                                         const IsoBmffLimits& limits = {})
{
    return IsoBmffReader::Open(MakeMemoryByteSource(bytes), error, limits);
}

std::unique_ptr<IsoBmffReader> OpenSpec(const Mp4Spec& spec, BuiltMp4* built = nullptr, Error* error = nullptr)
{
    BuiltMp4 local = BuildMp4(spec);
    auto     reader = OpenBytes(local.bytes, error);
    if (built != nullptr) *built = std::move(local);
    return reader;
}

// The offset of the first box of `type` (its 4 type bytes), or npos.
std::size_t FindBox(const Bytes& bytes, const std::string& type)
{
    const auto at = std::search(bytes.begin(), bytes.end(), type.begin(), type.end());
    return at == bytes.end() ? std::string::npos : static_cast<std::size_t>(at - bytes.begin());
}

void PatchU32(Bytes& bytes, std::size_t at, std::uint32_t value)
{
    for (int index = 0; index < 4; ++index) bytes[at + static_cast<std::size_t>(index)] = static_cast<std::uint8_t>(value >> (24 - 8 * index));
}

void ExpectSamplesMatch(const IsoBmffReader& reader, const BuiltMp4& built)
{
    ASSERT_EQ(reader.samples().size(), built.offsets.size());
    for (std::size_t index = 0; index < built.offsets.size(); ++index) {
        EXPECT_EQ(reader.samples()[index].offset, built.offsets[index]) << "sample " << index;
        EXPECT_EQ(reader.samples()[index].size, built.payloads[index].size()) << "sample " << index;
        Bytes payload;
        Error error;
        ASSERT_TRUE(reader.readSample(index, &payload, &error)) << Describe(error);
        EXPECT_EQ(payload, built.payloads[index]) << "sample " << index;
    }
}

std::vector<std::int64_t> Dts(const IsoBmffReader& reader)
{
    std::vector<std::int64_t> values;
    for (const Sample& sample : reader.samples()) values.push_back(sample.dts);
    return values;
}

std::vector<std::int64_t> Pts(const IsoBmffReader& reader)
{
    std::vector<std::int64_t> values;
    for (const Sample& sample : reader.samples()) values.push_back(sample.pts);
    return values;
}

// --- A plain file ------------------------------------------------------------------

TEST(IsoBmffReader, ReadsTheSampleTableAndStreamDescriptionOfAPlainFile)
{
    Mp4Spec spec;
    spec.samples  = Samples(5, 100, 40, 3);
    spec.chunking = { 2, 3 };
    BuiltMp4 built;
    Error    error;
    auto     reader = OpenSpec(spec, &built, &error);
    ASSERT_NE(reader, nullptr) << Describe(error);

    ExpectSamplesMatch(*reader, built);
    EXPECT_EQ(Dts(*reader), (std::vector<std::int64_t> { 0, 40, 80, 120, 160 }));
    EXPECT_EQ(Pts(*reader), Dts(*reader));
    std::vector<bool> sync;
    for (const Sample& sample : reader->samples()) {
        sync.push_back(sample.sync);
        EXPECT_EQ(sample.duration, 40);
    }
    EXPECT_EQ(sync, (std::vector<bool> { true, false, false, true, false }));

    const VideoStreamInfo& info = reader->info();
    EXPECT_EQ(info.codecFourcc, FourCC('a', 'v', 'c', '1'));
    EXPECT_EQ(info.configFourcc, FourCC('a', 'v', 'c', 'C'));
    EXPECT_EQ(info.codecConfig, AvcC(100, 8));
    EXPECT_EQ(info.bitDepth, 8);
    EXPECT_EQ(info.codedWidth, 640U);
    EXPECT_EQ(info.codedHeight, 360U);
    EXPECT_EQ(info.displayWidth, 640U);
    EXPECT_EQ(info.displayHeight, 360U);
    EXPECT_EQ(info.timescale, 1000);
    EXPECT_EQ(info.durationTicks, 200);
    EXPECT_EQ(info.contentEndTicks, 200);
    EXPECT_EQ(info.trackId, 1U);
    EXPECT_EQ(info.minFramePeriod, MakeRational(1, 25));
    EXPECT_EQ(info.avgFramePeriod, MakeRational(1, 25));
    EXPECT_FALSE(info.colour.present());
    EXPECT_FALSE(info.pixelAspect.valid());
    EXPECT_EQ(info.displayMatrix, kIdentityDisplayMatrix);
    EXPECT_EQ(reader->majorBrand(), FourCC('i', 's', 'o', 'm'));
    EXPECT_TRUE(reader->warnings().empty());
}

TEST(IsoBmffReader, FrameRatesStayExactFractions)
{
    Mp4Spec ntsc;
    ntsc.mediaTimescale = 30000;
    ntsc.samples        = Samples(10, 20, 1001, 5);
    auto reader         = OpenSpec(ntsc);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().minFramePeriod, MakeRational(1001, 30000));
    EXPECT_EQ(reader->info().avgFramePeriod, MakeRational(1001, 30000));
    EXPECT_NE(reader->info().minFramePeriod, MakeRational(1, 30)) << "the period is not 1/30 s";

    Mp4Spec variable;
    variable.samples = Samples(3, 20, 1000, 3);
    variable.samples[2].delta = 2000;
    reader = OpenSpec(variable);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().minFramePeriod, MakeRational(1, 1));
    EXPECT_EQ(reader->info().avgFramePeriod, MakeRational(4, 3));
}

// --- Chunk, size and box layouts ---------------------------------------------------

TEST(IsoBmffReader, EveryChunkingLayoutLocatesTheSameSamples)
{
    for (const std::vector<std::uint32_t>& chunking :
         { std::vector<std::uint32_t> {}, std::vector<std::uint32_t> { 1 }, std::vector<std::uint32_t> { 3 },
           std::vector<std::uint32_t> { 2, 5 }, std::vector<std::uint32_t> { 7 }, std::vector<std::uint32_t> { 20 } }) {
        Mp4Spec spec;
        spec.samples  = Samples(7, 30, 40, 3);
        spec.chunking = chunking;
        BuiltMp4 built;
        Error    error;
        auto     reader = OpenSpec(spec, &built, &error);
        ASSERT_NE(reader, nullptr) << Describe(error);
        ExpectSamplesMatch(*reader, built);
    }
}

TEST(IsoBmffReader, EverySizeTableAndOffsetWidthIsUnderstood)
{
    struct Case {
        std::uint32_t sizeTable;
        std::uint32_t size;
        bool          varying;
        bool          co64;
    };
    for (const Case& test : { Case { 0, 100, true, false }, Case { 1, 77, false, false }, Case { 4, 9, true, false },
                              Case { 8, 200, true, false }, Case { 16, 300, true, false }, Case { 0, 100, true, true },
                              Case { 8, 50, true, true } }) {
        Mp4Spec spec;
        spec.sizeTable = test.sizeTable;
        spec.co64      = test.co64;
        spec.samples   = Samples(7, test.size, 40, 3);
        if (test.sizeTable == 4) {
            for (std::size_t index = 0; index < spec.samples.size(); ++index) spec.samples[index].size = 1 + static_cast<std::uint32_t>(index) * 2;
        } else if (! test.varying) {
            for (auto& sample : spec.samples) sample.size = test.size;
        } else if (test.sizeTable == 8) {
            for (std::size_t index = 0; index < spec.samples.size(); ++index) spec.samples[index].size = test.size + static_cast<std::uint32_t>(index);
        }
        BuiltMp4 built;
        Error    error;
        auto     reader = OpenSpec(spec, &built, &error);
        ASSERT_NE(reader, nullptr) << "size table " << test.sizeTable << ": " << Describe(error);
        ExpectSamplesMatch(*reader, built);
    }
}

TEST(IsoBmffReader, BoxOrderAndSizeFormsDoNotMatter)
{
    auto check = [](Mp4Spec spec) {
        spec.samples = Samples(6, 40, 40, 3);
        BuiltMp4 built;
        Error    error;
        auto     reader = OpenSpec(spec, &built, &error);
        ASSERT_NE(reader, nullptr) << Describe(error);
        ExpectSamplesMatch(*reader, built);
    };
    Mp4Spec moovLast;
    moovLast.moovFirst = false;
    check(moovLast);
    Mp4Spec largeMdat;
    largeMdat.largeMdat = true;
    check(largeMdat);
    Mp4Spec largeMoovLast;
    largeMoovLast.largeMdat = true;
    largeMoovLast.moovFirst = false;
    check(largeMoovLast);
    Mp4Spec toEnd;
    toEnd.mdatToEndOfFile = true;
    check(toEnd);
    Mp4Spec padded;
    padded.freeBox = true;
    check(padded);
    Mp4Spec noFtyp;
    noFtyp.writeFtyp = false;
    check(noFtyp);
}

TEST(IsoBmffReader, AMissingFtypIsTolerated)
{
    Mp4Spec spec;
    spec.writeFtyp = false;
    spec.samples   = Samples(3);
    auto reader    = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->majorBrand(), 0U);
}

TEST(IsoBmffReader, WithoutAStssEverySampleIsASyncSample)
{
    Mp4Spec spec;
    spec.writeStss = false;
    spec.samples   = Samples(5, 20, 40, 3);
    auto reader    = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    for (const Sample& sample : reader->samples()) EXPECT_TRUE(sample.sync);
    EXPECT_EQ(reader->findKeyframeAtOrBefore(95), std::optional<std::size_t> { 2 });
}

// --- Codec sample entries ----------------------------------------------------------

TEST(IsoBmffReader, ExposesEachCodecsConfigRecordAsRawBytes)
{
    struct Case {
        std::string   entry;
        Bytes         config;
        std::string   configBox;
        std::uint8_t  bitDepth;
    };
    const std::vector<Case> cases {
        { "avc1", AvcC(100, 8), "avcC", 8 },   { "avc1", AvcC(110, 10), "avcC", 10 }, { "avc1", AvcC(66, 8), "avcC", 8 },
        { "avc3", AvcC(122, 10), "avcC", 10 }, { "hvc1", HvcC(8), "hvcC", 8 },        { "hev1", HvcC(10), "hvcC", 10 },
        { "av01", Av1C(8), "av1C", 8 },        { "av01", Av1C(10), "av1C", 10 },      { "av01", Av1C(12), "av1C", 12 },
        { "vp09", VpcC(8, false, 1, 1, 1), "vpcC", 8 },
        { "vp09", VpcC(10, true, 9, 16, 9), "vpcC", 10 },
    };
    for (const Case& test : cases) {
        Mp4Spec spec;
        spec.entry   = test.entry;
        spec.config  = test.config;
        spec.samples = Samples(3);
        Error error;
        auto  reader = OpenSpec(spec, nullptr, &error);
        ASSERT_NE(reader, nullptr) << test.entry << ": " << Describe(error);
        const VideoStreamInfo& info = reader->info();
        EXPECT_EQ(FourCCString(info.codecFourcc), test.entry);
        EXPECT_EQ(FourCCString(info.configFourcc), test.configBox);
        EXPECT_EQ(info.codecConfig, test.config) << test.entry << " config must be the box payload verbatim";
        EXPECT_EQ(info.bitDepth, test.bitDepth) << test.entry;
    }
}

TEST(IsoBmffReader, AVp9RecordSuppliesTheColourDescriptionWhenNoColrBoxDoes)
{
    Mp4Spec spec;
    spec.entry   = "vp09";
    spec.config  = VpcC(10, true, 9, 16, 9);
    spec.samples = Samples(3);
    auto reader  = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    const ColourDescription& colour = reader->info().colour;
    EXPECT_EQ(colour.source, ColourDescription::Source::CodecConfig);
    EXPECT_EQ(colour.primaries, 9);
    EXPECT_EQ(colour.transfer, 16);
    EXPECT_EQ(colour.matrix, 9);
    EXPECT_TRUE(colour.fullRange);

    // A colr box in the entry is the container's statement and wins.
    spec.entryChildren = { ColrNclx(1, 1, 1, false) };
    reader             = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().colour.source, ColourDescription::Source::ContainerNclx);
    EXPECT_EQ(reader->info().colour.transfer, 1);
}

TEST(IsoBmffReader, ReadsColrNclxNclcAndPasp)
{
    Mp4Spec spec;
    spec.samples       = Samples(3);
    spec.entryChildren = { ColrNclx(9, 16, 9, true), Pasp(4, 3) };
    auto reader        = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    ColourDescription colour = reader->info().colour;
    EXPECT_EQ(colour.source, ColourDescription::Source::ContainerNclx);
    EXPECT_EQ(colour.primaries, 9);
    EXPECT_EQ(colour.transfer, 16);
    EXPECT_EQ(colour.matrix, 9);
    EXPECT_TRUE(colour.fullRange);
    EXPECT_EQ(reader->info().pixelAspect, MakeRational(4, 3));

    spec.entryChildren = { ColrNclc(6, 1, 6) };
    reader             = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    colour = reader->info().colour;
    EXPECT_EQ(colour.source, ColourDescription::Source::ContainerNclc);
    EXPECT_EQ(colour.primaries, 6);
    EXPECT_FALSE(colour.fullRange);

    // An nclx box beats an nclc box wherever it appears.
    spec.entryChildren = { ColrNclx(1, 1, 1, false), ColrNclc(6, 1, 6) };
    reader             = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().colour.source, ColourDescription::Source::ContainerNclx);
    EXPECT_EQ(reader->info().colour.primaries, 1);

    // A pixel aspect with a zero side is not an aspect.
    spec.entryChildren = { Pasp(0, 3) };
    reader             = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_FALSE(reader->info().pixelAspect.valid());
}

TEST(IsoBmffReader, AnUnfamiliarVideoEntryIsReportedByTypeOnly)
{
    Mp4Spec spec;
    spec.entry   = "apcn";
    spec.samples = Samples(3);
    auto reader  = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(FourCCString(reader->info().codecFourcc), "apcn");
    EXPECT_EQ(reader->info().configFourcc, 0U);
    EXPECT_TRUE(reader->info().codecConfig.empty());
    EXPECT_EQ(reader->info().codedWidth, 640U);

    // A Dolby Vision entry keeps the hvcC record it carries.
    Mp4Spec vision;
    vision.entry      = "dvh1";
    vision.configType = "hvcC";
    vision.samples    = Samples(3);
    reader            = OpenSpec(vision);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(FourCCString(reader->info().codecFourcc), "dvh1");
    EXPECT_EQ(FourCCString(reader->info().configFourcc), "hvcC");
}

TEST(IsoBmffReader, BrokenOrMissingConfigRecordsAreRefusedNotPassedOn)
{
    auto errorFor = [](Mp4Spec spec) {
        spec.samples = Samples(3);
        Error error;
        EXPECT_EQ(OpenSpec(spec, nullptr, &error), nullptr);
        return error;
    };
    Mp4Spec missing;
    missing.omitConfig = true;
    EXPECT_EQ(errorFor(missing).kind, ErrorKind::Corrupt);

    Mp4Spec mismatched;
    mismatched.configType = "hvcC";  // an avc1 entry with an hvcC record
    EXPECT_EQ(errorFor(mismatched).kind, ErrorKind::Corrupt);

    Mp4Spec shortHevc;
    shortHevc.entry  = "hvc1";
    shortHevc.config = Bytes(10, 1);
    EXPECT_EQ(errorFor(shortHevc).kind, ErrorKind::Corrupt);

    Mp4Spec shortAvc;
    shortAvc.config = Bytes { 1, 100, 0, 31, 0xFF, 0xE1, 0x00 };
    EXPECT_EQ(errorFor(shortAvc).kind, ErrorKind::Corrupt);

    Mp4Spec badAv1;
    badAv1.entry  = "av01";
    badAv1.config = Bytes { 0x01, 0, 0, 0 };
    EXPECT_EQ(errorFor(badAv1).kind, ErrorKind::Corrupt);

    Mp4Spec shortVp9;
    shortVp9.entry  = "vp09";
    shortVp9.config = Bytes { 1, 0, 0, 0, 2 };
    EXPECT_EQ(errorFor(shortVp9).kind, ErrorKind::Corrupt);

    Mp4Spec encrypted;
    encrypted.entry = "encv";
    EXPECT_EQ(errorFor(encrypted).kind, ErrorKind::Unsupported);

    Mp4Spec noSize;
    noSize.width = 0;
    EXPECT_EQ(errorFor(noSize).kind, ErrorKind::Corrupt);
}

TEST(IsoBmffReader, AQuickTimeZeroTerminatorAfterTheEntryChildrenIsIgnored)
{
    Mp4Spec spec;
    spec.samples      = Samples(3);
    spec.entryTrailer = Bytes(4, 0);
    EXPECT_NE(OpenSpec(spec), nullptr);
}

// --- Composition offsets and edit lists -------------------------------------------

TEST(IsoBmffReader, CompositionOffsetsGiveDisplayOrderTimes)
{
    // I P B B in decode order; version 0 and 1 may both carry negative offsets.
    for (std::uint32_t version : { 0U, 1U }) {
        Mp4Spec spec;
        spec.samples     = Samples(4, 20, 40, 4);
        spec.samples[0].cts = 0;
        spec.samples[1].cts = 80;
        spec.samples[2].cts = -40;
        spec.samples[3].cts = -40;
        spec.cttsVersion = version;
        Error error;
        auto  reader = OpenSpec(spec, nullptr, &error);
        ASSERT_NE(reader, nullptr) << Describe(error);
        EXPECT_EQ(Dts(*reader), (std::vector<std::int64_t> { 0, 40, 80, 120 })) << "ctts version " << version;
        EXPECT_EQ(Pts(*reader), (std::vector<std::int64_t> { 0, 120, 40, 80 })) << "ctts version " << version;
        EXPECT_EQ(reader->info().contentEndTicks, 160);
    }
}

TEST(IsoBmffReader, AnEditListThatSkipsTheCompositionDelayStartsPresentationAtZero)
{
    Mp4Spec spec;
    spec.samples        = Samples(4, 20, 40, 4);
    spec.samples[0].cts = 80;
    spec.samples[1].cts = 160;
    spec.samples[2].cts = 40;
    spec.samples[3].cts = 40;
    spec.edits = std::vector<EditSpec> { { 160, 80, 1, 0 } };
    Error error;
    auto  reader = OpenSpec(spec, nullptr, &error);
    ASSERT_NE(reader, nullptr) << Describe(error);
    // Raw dts 0 40 80 120, raw pts 80 200 120 160, shifted by the edit's media start.
    EXPECT_EQ(Dts(*reader), (std::vector<std::int64_t> { -80, -40, 0, 40 }));
    EXPECT_EQ(Pts(*reader), (std::vector<std::int64_t> { 0, 120, 40, 80 }));
    EXPECT_EQ(reader->info().durationTicks, 160);
}

TEST(IsoBmffReader, AnInitialEmptyEditDelaysPresentationInMediaTicks)
{
    for (std::uint32_t version : { 0U, 1U }) {
        Mp4Spec spec;
        spec.mediaTimescale = 1200;
        spec.movieTimescale = 600;
        spec.samples        = Samples(6, 50, 50, 3);
        // Half a second of nothing (300 movie ticks = 600 media ticks), then 2 s of media.
        spec.edits       = std::vector<EditSpec> { { 300, -1, 1, 0 }, { 1200, 0, 1, 0 } };
        spec.elstVersion = version;
        Error error;
        auto  reader = OpenSpec(spec, nullptr, &error);
        ASSERT_NE(reader, nullptr) << Describe(error);
        EXPECT_EQ(Dts(*reader), (std::vector<std::int64_t> { 600, 650, 700, 750, 800, 850 })) << "elst version " << version;
        EXPECT_EQ(Pts(*reader), Dts(*reader));
        EXPECT_EQ(reader->info().durationTicks, 600 + 2400);
    }
}

TEST(IsoBmffReader, AMediaStartOffsetAndAnEmptyDelayCombine)
{
    Mp4Spec spec;
    spec.mediaTimescale = 1000;
    spec.movieTimescale = 1000;
    spec.samples        = Samples(6, 50, 50, 3);
    // 200 ticks of nothing, then the media from tick 100.
    spec.edits = std::vector<EditSpec> { { 200, -1, 1, 0 }, { 250, 100, 1, 0 } };
    auto reader = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(Dts(*reader).front(), 100);  // raw 0 + 200 - 100
    EXPECT_EQ(reader->info().durationTicks, 450);
    EXPECT_EQ(reader->samples()[2].pts, 200);  // raw 100 + 100: the media's own tick 100 plays at 200
}

TEST(IsoBmffReader, AnEmptyEditAfterTheMediaOnlyPadsTheEnd)
{
    Mp4Spec spec;
    spec.samples = Samples(6, 50, 50, 3);
    spec.edits   = std::vector<EditSpec> { { 300, 0, 1, 0 }, { 500, -1, 1, 0 } };
    auto reader  = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().durationTicks, 300);
    EXPECT_EQ(reader->samples().front().dts, 0);
}

TEST(IsoBmffReader, AZeroLengthMediaSegmentFallsBackToTheHeaderDuration)
{
    Mp4Spec spec;
    spec.samples = Samples(6, 50, 50, 3);
    spec.edits   = std::vector<EditSpec> { { 0, 0, 1, 0 } };
    auto reader  = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().durationTicks, 300);
}

TEST(IsoBmffReader, AnEditListWithOnlyEmptyEditsIsIgnoredWithAWarning)
{
    Mp4Spec spec;
    spec.samples = Samples(4, 50, 50, 3);
    spec.edits   = std::vector<EditSpec> { { 300, -1, 1, 0 } };
    auto reader  = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->samples().front().dts, 0);
    EXPECT_FALSE(reader->warnings().empty());
}

TEST(IsoBmffReader, EditListsItCannotHonourAreRefusedWithAReason)
{
    Mp4Spec twoSegments;
    twoSegments.samples = Samples(6, 50, 50, 3);
    twoSegments.edits   = std::vector<EditSpec> { { 100, 0, 1, 0 }, { 100, 200, 1, 0 } };
    Error error;
    EXPECT_EQ(OpenSpec(twoSegments, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("more than one media segment"), std::string::npos) << error.message;

    Mp4Spec doubleSpeed;
    doubleSpeed.samples = Samples(6, 50, 50, 3);
    doubleSpeed.edits   = std::vector<EditSpec> { { 300, 0, 2, 0 } };
    EXPECT_EQ(OpenSpec(doubleSpeed, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("media rate"), std::string::npos) << error.message;

    Mp4Spec halfRate;
    halfRate.samples = Samples(6, 50, 50, 3);
    halfRate.edits   = std::vector<EditSpec> { { 300, 0, 0, 0x4000 } };
    EXPECT_EQ(OpenSpec(halfRate, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);

    Mp4Spec farAway;
    farAway.samples     = Samples(6, 50, 50, 3);
    farAway.elstVersion = 1;
    farAway.edits       = std::vector<EditSpec> { { 300, std::int64_t { 1 } << 60, 1, 0 } };
    EXPECT_EQ(OpenSpec(farAway, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
}

// --- Orientation and size ----------------------------------------------------------

struct OrientationCase {
    const char*  name;
    std::int32_t a, b, c, d;
    Orientation  orientation;
    bool         swaps;
};
constexpr OrientationCase kOrientations[] = {
    { "identity", 1, 0, 0, 1, Orientation::Identity, false },     { "rotate90", 0, 1, -1, 0, Orientation::Rotate90, true },
    { "rotate180", -1, 0, 0, -1, Orientation::Rotate180, false }, { "rotate270", 0, -1, 1, 0, Orientation::Rotate270, true },
    { "mirrorX", -1, 0, 0, 1, Orientation::MirrorX, false },      { "mirrorY", 1, 0, 0, -1, Orientation::MirrorY, false },
    { "transpose", 0, 1, 1, 0, Orientation::Transpose, true },    { "transverse", 0, -1, -1, 0, Orientation::Transverse, true },
};

DisplayMatrix MatrixOf(const OrientationCase& test)
{
    return { test.a * 65536, test.b * 65536, 0, test.c * 65536, test.d * 65536, 0, 0, 0, 1 << 30 };
}

TEST(IsoBmffReader, ReportsTheTkhdMatrixOfAllEightOrientations)
{
    for (std::uint32_t version : { 0U, 1U }) {
        for (const OrientationCase& test : kOrientations) {
            Mp4Spec spec;
            spec.samples     = Samples(3);
            spec.matrix      = MatrixOf(test);
            spec.tkhdVersion = version;
            Error error;
            auto  reader = OpenSpec(spec, nullptr, &error);
            ASSERT_NE(reader, nullptr) << test.name << ": " << Describe(error);
            EXPECT_EQ(reader->info().displayMatrix, MatrixOf(test)) << test.name;
            const auto orientation = ClassifyDisplayMatrix(reader->info().displayMatrix);
            ASSERT_TRUE(orientation.has_value()) << test.name;
            EXPECT_EQ(*orientation, test.orientation) << test.name;
            EXPECT_EQ(SwapsAxes(*orientation), test.swaps) << test.name;
        }
    }
}

TEST(DisplayMatrix, TranslationAndHomogeneousScaleDoNotChangeTheOrientation)
{
    DisplayMatrix matrix = MatrixOf(kOrientations[1]);
    matrix[6]            = 1080 * 65536;  // x, y only place the image
    matrix[7]            = 0;
    EXPECT_EQ(ClassifyDisplayMatrix(matrix), std::optional<Orientation> { Orientation::Rotate90 });

    // A matrix whose homogeneous term is 0.5 and whose coefficients are halved is still identity.
    DisplayMatrix halved = { 32768, 0, 0, 0, 32768, 0, 0, 0, 1 << 29 };
    EXPECT_EQ(ClassifyDisplayMatrix(halved), std::optional<Orientation> { Orientation::Identity });
}

TEST(DisplayMatrix, ScalesShearsAndProjectionsAreNotOrientations)
{
    DisplayMatrix scaled = kIdentityDisplayMatrix;
    scaled[0]            = 2 * 65536;
    EXPECT_FALSE(ClassifyDisplayMatrix(scaled).has_value());
    DisplayMatrix sheared = kIdentityDisplayMatrix;
    sheared[1]            = 32768;
    EXPECT_FALSE(ClassifyDisplayMatrix(sheared).has_value());
    DisplayMatrix projective = kIdentityDisplayMatrix;
    projective[2]            = 1;
    EXPECT_FALSE(ClassifyDisplayMatrix(projective).has_value());
    DisplayMatrix degenerate = kIdentityDisplayMatrix;
    degenerate[8]            = 0;
    EXPECT_FALSE(ClassifyDisplayMatrix(degenerate).has_value());
    DisplayMatrix zero {};
    EXPECT_FALSE(ClassifyDisplayMatrix(zero).has_value());
}

TEST(IsoBmffReader, TheTkhdSizeIsRoundedFromSixteenSixteenFixedPoint)
{
    Mp4Spec spec;
    spec.samples      = Samples(3);
    spec.tkhdWidth16  = (1920U << 16) | 0x7FFF;
    spec.tkhdHeight16 = (1080U << 16) | 0x8000;
    auto reader       = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().displayWidth, 1920U);
    EXPECT_EQ(reader->info().displayHeight, 1081U);
    EXPECT_EQ(reader->info().codedWidth, 640U) << "the coded size comes from the sample entry";
}

// --- Seeking -----------------------------------------------------------------------

TEST(IsoBmffReader, KeyframeSeekFindsTheLastSyncSampleAtOrBeforeATime)
{
    Mp4Spec spec;
    spec.samples = Samples(12, 20, 100, 4);  // sync at samples 0, 4, 8; pts 0, 400, 800
    auto reader  = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    auto seek = [&](std::int64_t pts) { return reader->findKeyframeAtOrBefore(pts); };
    EXPECT_EQ(seek(-500), std::optional<std::size_t> { 0 });
    EXPECT_EQ(seek(0), std::optional<std::size_t> { 0 });
    EXPECT_EQ(seek(399), std::optional<std::size_t> { 0 });
    EXPECT_EQ(seek(400), std::optional<std::size_t> { 4 });
    EXPECT_EQ(seek(799), std::optional<std::size_t> { 4 });
    EXPECT_EQ(seek(800), std::optional<std::size_t> { 8 });
    EXPECT_EQ(seek(1000000000), std::optional<std::size_t> { 8 });
}

TEST(IsoBmffReader, KeyframeSeekUsesPresentationNotDecodeTimeWithReordering)
{
    // The second sync sample decodes at 400 but is shown at 300 (cts -100).
    Mp4Spec spec;
    spec.samples        = Samples(8, 20, 100, 4);
    spec.samples[4].cts = -100;
    auto reader         = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->samples()[4].pts, 300);
    EXPECT_EQ(reader->findKeyframeAtOrBefore(299), std::optional<std::size_t> { 0 });
    EXPECT_EQ(reader->findKeyframeAtOrBefore(300), std::optional<std::size_t> { 4 });
}

TEST(IsoBmffReader, KeyframeSeekStillAnswersWhenSyncSamplesAreNotInPresentationOrder)
{
    Mp4Spec spec;
    spec.samples        = Samples(8, 20, 100, 3);  // sync at 0, 3, 6
    spec.samples[3].cts = -350;                   // sync sample 3 is shown at -50, before sample 0
    auto reader         = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->samples()[3].pts, -50);
    EXPECT_EQ(reader->findKeyframeAtOrBefore(10), std::optional<std::size_t> { 0 });
    EXPECT_EQ(reader->findKeyframeAtOrBefore(-60), std::optional<std::size_t> { 0 });
    EXPECT_EQ(reader->findKeyframeAtOrBefore(700), std::optional<std::size_t> { 6 });
}

// --- Which track, and what is refused ----------------------------------------------

TEST(IsoBmffReader, PicksTheFirstEnabledVideoTrackWhateverComesBefore)
{
    Mp4Spec audioFirst;
    audioFirst.audioTrackFirst = true;
    audioFirst.trackId         = 2;
    audioFirst.samples         = Samples(3);
    auto reader                = OpenSpec(audioFirst);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().trackId, 2U);

    Mp4Spec disabledFirst;
    disabledFirst.extraDisabledVideoFirst = true;
    disabledFirst.trackId                 = 3;
    disabledFirst.samples                 = Samples(3);
    reader                                = OpenSpec(disabledFirst);
    ASSERT_NE(reader, nullptr);
    EXPECT_EQ(reader->info().trackId, 3U) << "a disabled track loses to an enabled one";

    Mp4Spec onlyDisabled;
    onlyDisabled.trackEnabled = false;
    onlyDisabled.samples      = Samples(3);
    reader                    = OpenSpec(onlyDisabled);
    ASSERT_NE(reader, nullptr) << "a lone disabled video track is still the video track";
}

TEST(IsoBmffReader, AFileWithoutAVideoTrackIsUnsupported)
{
    Mp4Spec spec;
    spec.noVideoTrack = true;
    spec.samples      = Samples(3);
    Error error;
    EXPECT_EQ(OpenSpec(spec, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("no video track"), std::string::npos);
}

TEST(IsoBmffReader, FragmentedFilesAreRefusedWithAClearReason)
{
    Mp4Spec withMvex;
    withMvex.mvex    = true;
    withMvex.samples = Samples(3);
    Error error;
    EXPECT_EQ(OpenSpec(withMvex, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("fragmented MP4 not supported"), std::string::npos) << error.message;

    Mp4Spec withMoof;
    withMoof.moofAfter = true;
    withMoof.samples   = Samples(3);
    EXPECT_EQ(OpenSpec(withMoof, nullptr, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Unsupported);
    EXPECT_NE(error.message.find("fragmented MP4 not supported"), std::string::npos) << error.message;
}

// --- Untrusted input ---------------------------------------------------------------

TEST(IsoBmffReader, NonMp4InputIsNotThisFormat)
{
    Error error;
    EXPECT_EQ(OpenBytes({}, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);
    EXPECT_EQ(OpenBytes(Bytes(7, 0), &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);

    const std::string text = "This is not a video file at all, just some words.";
    EXPECT_EQ(OpenBytes(Bytes(text.begin(), text.end()), &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);

    const Bytes png { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 'I', 'H', 'D', 'R' };
    EXPECT_EQ(OpenBytes(png, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);

    Bytes zeros(4096, 0);
    EXPECT_EQ(OpenBytes(zeros, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::NotThisFormat);
    EXPECT_EQ(IsoBmffReader::Open(nullptr, &error), nullptr);

    EXPECT_FALSE(LooksLikeIsoBmff(*MakeMemoryByteSource(png)));
    Mp4Spec spec;
    spec.samples = Samples(2);
    EXPECT_TRUE(LooksLikeIsoBmff(*MakeMemoryByteSource(BuildMp4(spec).bytes)));
}

TEST(IsoBmffReader, EveryTruncationOfAFileEndsInACleanResult)
{
    Mp4Spec spec;
    spec.samples        = Samples(9, 30, 40, 3);
    spec.chunking       = { 2, 3 };
    spec.samples[4].cts = 80;
    spec.edits          = std::vector<EditSpec> { { 100, -1, 1, 0 }, { 300, 0, 1, 0 } };
    const BuiltMp4 built = BuildMp4(spec);
    const std::uint64_t moovEnd = built.moovOffset + built.moovSize;
    for (std::size_t length = 0; length < built.bytes.size(); ++length) {
        Bytes prefix(built.bytes.begin(), built.bytes.begin() + static_cast<std::ptrdiff_t>(length));
        Error error;
        auto  reader = OpenBytes(prefix, &error);
        if (length < moovEnd) {
            EXPECT_EQ(reader, nullptr) << "a cut inside the moov box must not open (" << length << " bytes)";
            EXPECT_TRUE(error) << length;
            continue;
        }
        if (reader == nullptr) {
            EXPECT_TRUE(error) << length;
            continue;
        }
        // A cut inside the sample data keeps the samples that are whole.
        ASSERT_FALSE(reader->samples().empty()) << length;
        for (const Sample& sample : reader->samples()) EXPECT_LE(sample.offset + sample.size, length) << length;
        EXPECT_FALSE(reader->warnings().empty()) << length;
    }
}

TEST(IsoBmffReader, OversizedBoxFieldsFailCleanly)
{
    Mp4Spec spec;
    spec.samples        = Samples(6, 30, 40, 3);
    spec.chunking       = { 2 };
    spec.edits          = std::vector<EditSpec> { { 300, 0, 1, 0 } };
    spec.samples[2].cts = 5;
    const Bytes good    = BuildMp4(spec).bytes;
    ASSERT_NE(OpenBytes(good), nullptr);

    // Boxes inside moov carry an entry count right after the 4-byte version/flags.
    struct Patch {
        const char*   box;
        std::size_t   fieldOffset;  // from the box type
        std::uint32_t value;
    };
    const Patch patches[] = {
        { "stts", 8, 0x7FFFFFFF }, { "ctts", 8, 0x7FFFFFFF }, { "stss", 8, 0x7FFFFFFF }, { "stsc", 8, 0x7FFFFFFF },
        { "stco", 8, 0x7FFFFFFF }, { "stsd", 8, 0x7FFFFFFF }, { "elst", 8, 0x7FFFFFFF }, { "stsz", 12, 0x00F00000 },
    };
    for (const Patch& patch : patches) {
        Bytes bytes = good;
        const std::size_t at = FindBox(bytes, patch.box);
        ASSERT_NE(at, std::string::npos) << patch.box;
        PatchU32(bytes, at + patch.fieldOffset, patch.value);
        Error error;
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr) << patch.box;
        EXPECT_TRUE(error.kind == ErrorKind::Corrupt || error.kind == ErrorKind::LimitExceeded) << patch.box << ": " << Describe(error);
    }
    {
        // A sample count beyond the reader's limit is a limit, not corruption.
        Bytes bytes = good;
        PatchU32(bytes, FindBox(bytes, "stsz") + 12, 0xFFFFFFFF);
        Error error;
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
    }
    {
        // A moov that claims more bytes than the file has.
        Bytes bytes = good;
        const std::size_t at = FindBox(bytes, "moov");
        PatchU32(bytes, at - 4, 0x7FFFFFF0);
        Error error;
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::Truncated);
    }
    {
        // A top-level box smaller than its own header.
        Bytes bytes = good;
        const std::size_t at = FindBox(bytes, "moov");
        PatchU32(bytes, at - 4, 4);
        Error error;
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    }
    {
        // A child box that runs past its parent.
        Bytes bytes = good;
        const std::size_t at = FindBox(bytes, "mdia");
        PatchU32(bytes, at - 4, 0x00FFFFFF);
        Error error;
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    }
}

TEST(IsoBmffReader, InconsistentSampleTablesAreRefused)
{
    Mp4Spec spec;
    spec.samples = Samples(6, 30, 40, 3);
    const Bytes good = BuildMp4(spec).bytes;
    auto openPatched = [&](const char* box, std::size_t fieldOffset, std::uint32_t value, Error* error) {
        Bytes bytes = good;
        PatchU32(bytes, FindBox(bytes, box) + fieldOffset, value);
        return OpenBytes(bytes, error);
    };
    Error error;
    EXPECT_EQ(openPatched("mdhd", 16, 0, &error), nullptr) << "a zero timescale";
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    // stts run length 6 -> 2: the table covers fewer samples than stsz lists.
    EXPECT_EQ(openPatched("stts", 12, 2, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    // stsc must begin at chunk 1.
    EXPECT_EQ(openPatched("stsc", 12, 2, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    // stss entries: 0, out of range and the empty table are all corrupt.
    EXPECT_EQ(openPatched("stss", 12, 0, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    EXPECT_EQ(openPatched("stss", 12, 7, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
    EXPECT_EQ(openPatched("stss", 8, 0, &error), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::Corrupt);
}

TEST(IsoBmffReader, ChunkOffsetsBeyondTheFileTruncateOrFail)
{
    Mp4Spec spec;
    spec.samples  = Samples(6, 30, 40, 3);
    spec.chunking = { 2 };
    const BuiltMp4 built = BuildMp4(spec);
    {
        // The last chunk points past the end: the first four samples survive.
        Bytes bytes       = built.bytes;
        const std::size_t at = FindBox(bytes, "stco");
        PatchU32(bytes, at + 8 + 4 + 2 * 4, 0x00FFFFFF);
        Error error;
        auto  reader = OpenBytes(bytes, &error);
        ASSERT_NE(reader, nullptr) << Describe(error);
        EXPECT_EQ(reader->samples().size(), 4U);
        EXPECT_FALSE(reader->warnings().empty());
    }
    {
        // The first chunk points past the end: nothing is left.
        Bytes bytes       = built.bytes;
        const std::size_t at = FindBox(bytes, "stco");
        PatchU32(bytes, at + 8 + 4, 0x00FFFFFF);
        Error error;
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr);
        EXPECT_EQ(error.kind, ErrorKind::Truncated);
    }
    {
        // A 64-bit offset so large that adding a sample size overflows.
        Mp4Spec wide = spec;
        wide.co64    = true;
        Bytes bytes  = BuildMp4(wide).bytes;
        const std::size_t at = FindBox(bytes, "co64") + 8 + 4;
        for (int index = 0; index < 8; ++index) bytes[at + static_cast<std::size_t>(index)] = 0xFF;
        Error error;
        EXPECT_EQ(OpenBytes(bytes, &error), nullptr);
        EXPECT_TRUE(error.kind == ErrorKind::Corrupt || error.kind == ErrorKind::Truncated) << Describe(error);
    }
}

TEST(IsoBmffReader, ACompositionTableShorterThanTheSamplesIsToleratedWithAWarning)
{
    Mp4Spec spec;
    spec.samples        = Samples(6, 30, 40, 3);
    spec.samples[0].cts = 10;
    Bytes bytes         = BuildMp4(spec).bytes;
    const std::size_t at = FindBox(bytes, "ctts");
    PatchU32(bytes, at + 12, 2);  // the first run now covers 2 samples, the second run 5, ... shrink the table
    PatchU32(bytes, at + 8, 1);   // one entry only
    Error error;
    auto  reader = OpenBytes(bytes, &error);
    ASSERT_NE(reader, nullptr) << Describe(error);
    EXPECT_FALSE(reader->warnings().empty());
    EXPECT_EQ(reader->samples()[1].pts, 40 + 10);
    EXPECT_EQ(reader->samples()[5].pts, 200);
}

TEST(IsoBmffReader, ConfiguredLimitsRefuseWhatExceedsThem)
{
    Mp4Spec spec;
    spec.samples = Samples(5, 30, 40, 3);
    const Bytes bytes = BuildMp4(spec).bytes;
    Error       error;

    IsoBmffLimits samples;
    samples.maxSamples = 3;
    EXPECT_EQ(OpenBytes(bytes, &error, samples), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);

    IsoBmffLimits moov;
    moov.maxMoovBytes = 64;
    EXPECT_EQ(OpenBytes(bytes, &error, moov), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);

    IsoBmffLimits tracks;
    tracks.maxTracks = 0;
    EXPECT_EQ(OpenBytes(bytes, &error, tracks), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);

    IsoBmffLimits config;
    config.maxConfigBytes = 4;
    EXPECT_EQ(OpenBytes(bytes, &error, config), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);

    Bytes many = bytes;
    for (int index = 0; index < 50; ++index) Append(many, Box("free", {}));
    IsoBmffLimits boxes;
    boxes.maxTopLevelBoxes = 10;
    EXPECT_EQ(OpenBytes(many, &error, boxes), nullptr);
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
    EXPECT_NE(OpenBytes(many, &error), nullptr);
}

TEST(IsoBmffReader, ReadSampleRefusesAnOutOfRangeIndexAndAnOversizedSample)
{
    Mp4Spec spec;
    spec.samples = Samples(3, 100);
    auto reader  = OpenSpec(spec);
    ASSERT_NE(reader, nullptr);
    Bytes bytes;
    Error error;
    EXPECT_FALSE(reader->readSample(3, &bytes, &error));
    EXPECT_FALSE(reader->readSample(std::numeric_limits<std::size_t>::max(), &bytes, &error));

    IsoBmffLimits limits;
    limits.maxSampleBytes = 50;
    auto small            = IsoBmffReader::Open(MakeMemoryByteSource(BuildMp4(spec).bytes), &error, limits);
    ASSERT_NE(small, nullptr);
    EXPECT_FALSE(small->readSample(0, &bytes, &error));
    EXPECT_EQ(error.kind, ErrorKind::LimitExceeded);
}

// A deterministic stand-in for a fuzzer: thousands of single- and multi-byte
// mutations, truncations and fills of valid files. Whatever opens must describe
// samples that lie inside the file; nothing may crash or read out of bounds
// (run under -fsanitize=address,undefined to make the second one observable).
TEST(IsoBmffReader, RandomMutationsNeverCrashOrDescribeBytesOutsideTheFile)
{
    Mp4Spec rich;
    rich.samples        = Samples(24, 40, 40, 5);
    rich.chunking       = { 3, 5 };
    rich.samples[3].cts = 80;
    rich.samples[4].cts = -40;
    rich.cttsVersion    = 1;
    rich.edits          = std::vector<EditSpec> { { 100, -1, 1, 0 }, { 800, 40, 1, 0 } };
    rich.entryChildren  = { ColrNclx(1, 1, 1, false), Pasp(1, 1) };
    Mp4Spec plain;
    plain.samples  = Samples(10, 60, 33, 4);
    plain.sizeTable = 16;
    plain.co64      = true;
    plain.moovFirst = false;

    std::uint32_t state = 0xC0FFEE;
    auto next = [&state]() {
        state = state * 1664525U + 1013904223U;
        return state >> 8;
    };
    std::size_t opened = 0;
    for (const Mp4Spec* spec : { &rich, &plain }) {
        const Bytes original = BuildMp4(*spec).bytes;
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
                const std::size_t at = next() % bytes.size();
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
            ASSERT_FALSE(reader->samples().empty());
            for (const Sample& sample : reader->samples()) {
                ASSERT_LE(sample.offset + sample.size, bytes.size()) << "round " << round;
            }
            ASSERT_GT(reader->info().timescale, 0);
            reader->findKeyframeAtOrBefore(0);
            reader->findKeyframeAtOrBefore(std::numeric_limits<std::int64_t>::max());
            reader->findKeyframeAtOrBefore(std::numeric_limits<std::int64_t>::min());
            Bytes payload;
            EXPECT_TRUE(reader->readSample(reader->samples().size() - 1, &payload, &error)) << Describe(error);
        }
    }
    EXPECT_GT(opened, 100U) << "the mutations should leave some files readable, or the loop proves little";
}

} // namespace
} // namespace wallpaper::media
