// A/B checks of the ISO-BMFF reader against real files, for the properties a
// decoder front end depends on: the picture size, the number of samples and how
// long the track plays. The bundled starter wallpaper carries recorded
// expectations; the local wallpaper library (or WALLPAPER_MACHINE_VIDEO_ROOT) is
// compared with ffprobe when one is installed and with the reader's own header
// versus sample-table evidence otherwise. Without any file the tests skip and
// say why; a skipped corpus check is not a passing one.
#include "Media/ByteSource.hpp"
#include "Media/IsoBmff/IsoBmffReader.hpp"

#include "corpus_support.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

namespace wallpaper::media
{
namespace
{

using namespace testing;

double Seconds(const IsoBmffReader& reader)
{
    return static_cast<double>(reader.info().durationTicks) / static_cast<double>(reader.info().timescale);
}

TEST(IsoBmffCorpus, TheStarterWallpaperMatchesItsRecordedExpectations)
{
    const fs::path file = fs::path(WM_MEDIA_REPO_ROOT) / "Resources/StarterWallpaper/Aurora.mp4";
    if (! fs::exists(file)) GTEST_SKIP() << "skipped: the bundled starter wallpaper is not in this checkout";
    Error error;
    auto  source = OpenFileByteSource(file.string(), &error);
    ASSERT_NE(source, nullptr) << Describe(error);
    auto reader = IsoBmffReader::Open(source, &error);
    ASSERT_NE(reader, nullptr) << Describe(error);

    // Recorded once with ffprobe: H.264 1280x720, 288 packets, 12 s, 24 fps.
    const VideoStreamInfo& info = reader->info();
    EXPECT_EQ(FourCCString(info.codecFourcc), "avc1");
    EXPECT_EQ(info.codedWidth, 1280U);
    EXPECT_EQ(info.codedHeight, 720U);
    EXPECT_EQ(info.bitDepth, 8);
    EXPECT_EQ(reader->samples().size(), 288U);
    EXPECT_NEAR(Seconds(*reader), 12.0, 0.001);
    EXPECT_EQ(info.minFramePeriod, MakeRational(1, 24));
    EXPECT_EQ(info.avgFramePeriod, MakeRational(1, 24));
    EXPECT_TRUE(reader->samples().front().sync);
    EXPECT_EQ(info.displayMatrix, kIdentityDisplayMatrix);
    EXPECT_TRUE(reader->warnings().empty());
    std::int64_t firstShown = reader->samples().front().pts;
    for (const Sample& sample : reader->samples()) firstShown = std::min(firstShown, sample.pts);
    EXPECT_EQ(firstShown, 0) << "the first frame a player shows is at time 0";
}

TEST(IsoBmffCorpus, LibraryVideosAgreeWithFfprobeOrTheirOwnSampleTables)
{
    const auto root = CorpusRoot();
    if (! root) GTEST_SKIP() << "skipped: no video corpus (set WALLPAPER_MACHINE_VIDEO_ROOT or install wallpapers in the app library)";
    const std::vector<fs::path> files = CorpusFiles(*root, { ".mp4", ".m4v", ".mov" });
    if (files.empty()) GTEST_SKIP() << "skipped: no .mp4/.m4v/.mov file under the corpus root";

    const std::string ffprobe = FindFfprobe();
    if (ffprobe.empty()) std::printf("note: no ffprobe found; comparing header duration with the sample table only\n");
    std::size_t compared = 0;
    for (const fs::path& file : files) {
        SCOPED_TRACE(file.filename().string());
        Error error;
        auto  source = OpenFileByteSource(file.string(), &error);
        ASSERT_NE(source, nullptr) << Describe(error);
        auto reader = IsoBmffReader::Open(source, &error);
        if (reader == nullptr) {
            // Unsupported by design (fragmented, encrypted, exotic edit lists) is reported, not failed.
            std::printf("%s refused: %s\n", file.filename().string().c_str(), Describe(error).c_str());
            EXPECT_EQ(error.kind, ErrorKind::Unsupported) << Describe(error);
            continue;
        }
        const VideoStreamInfo& info = reader->info();
        const double seconds        = Seconds(*reader);
        const double contentEnd     = static_cast<double>(info.contentEndTicks) / static_cast<double>(info.timescale);
        const double period         = info.avgFramePeriod.toDouble();
        std::printf("%s %s %ux%u frames=%zu duration=%.3fs period=%.5fs warnings=%zu\n", file.filename().string().c_str(),
                    FourCCString(info.codecFourcc).c_str(), info.codedWidth, info.codedHeight, reader->samples().size(), seconds,
                    period, reader->warnings().size());
        for (const Sample& sample : reader->samples()) {
            ASSERT_LE(sample.offset + sample.size, source->size());
        }
        EXPECT_TRUE(reader->samples().front().sync || reader->findKeyframeAtOrBefore(0).has_value());
        // Header and sample table are two independent statements of the length.
        EXPECT_NEAR(seconds, contentEnd, std::max(0.25, 4 * period)) << "header duration vs sample table";
        if (ffprobe.empty()) continue;
        const auto probed = Ffprobe(ffprobe, file);
        if (probed.count("width") == 0) continue;
        ++compared;
        EXPECT_EQ(std::to_string(info.codedWidth), probed.at("width"));
        EXPECT_EQ(std::to_string(info.codedHeight), probed.at("height"));
        if (reader->warnings().empty() && probed.count("nb_read_packets") != 0) {
            EXPECT_EQ(std::to_string(reader->samples().size()), probed.at("nb_read_packets"));
        }
        if (probed.count("duration") != 0 && probed.at("duration") != "N/A") {
            EXPECT_NEAR(seconds, std::atof(probed.at("duration").c_str()), std::max(0.1, 2 * period)) << "duration vs ffprobe";
        }
    }
    std::printf("%zu of %zu files compared with ffprobe\n", compared, files.size());
}

} // namespace
} // namespace wallpaper::media
