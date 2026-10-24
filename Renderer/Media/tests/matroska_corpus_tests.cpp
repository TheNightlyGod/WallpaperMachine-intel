// A/B check of the Matroska reader against real .webm/.mkv files: the local
// wallpaper library (or WALLPAPER_MACHINE_VIDEO_ROOT) compared with ffprobe on
// picture size, frame count and duration. Files in a codec this project does not
// play (VP8, for one) must be refused as Unsupported, naming the codec. Without
// any file the test skips and says why; a skipped corpus check is not a passing one.
#include "Media/ByteSource.hpp"
#include "Media/Matroska/MatroskaReader.hpp"

#include "corpus_support.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>
#include <vector>

namespace wallpaper::media
{
namespace
{

using namespace testing;

TEST(MatroskaCorpus, LibraryFilesAgreeWithFfprobeOrAreRefusedAsUnsupported)
{
    const auto root = CorpusRoot();
    if (! root) GTEST_SKIP() << "skipped: no video corpus (set WALLPAPER_MACHINE_VIDEO_ROOT or install wallpapers in the app library)";
    const std::vector<fs::path> files = CorpusFiles(*root, { ".webm", ".mkv" });
    if (files.empty()) GTEST_SKIP() << "skipped: no .webm/.mkv file under the corpus root";

    const std::string ffprobe = FindFfprobe();
    if (ffprobe.empty()) std::printf("note: no ffprobe found; checking the index against itself only\n");
    std::size_t compared = 0;
    for (const fs::path& file : files) {
        SCOPED_TRACE(file.filename().string());
        Error error;
        auto  source = OpenFileByteSource(file.string(), &error);
        ASSERT_NE(source, nullptr) << Describe(error);
        auto reader = MatroskaReader::Open(source, &error);
        if (reader == nullptr) {
            std::printf("%s refused: %s\n", file.filename().string().c_str(), Describe(error).c_str());
            EXPECT_EQ(error.kind, ErrorKind::Unsupported) << Describe(error);
            continue;
        }
        const VideoStreamInfo& info = reader->videoInfo();
        const double seconds        = static_cast<double>(info.durationTicks) / static_cast<double>(info.timescale);
        const double period         = info.avgFramePeriod.toDouble();
        std::printf("%s %s %ux%u frames=%zu duration=%.3fs period=%.5fs warnings=%zu\n", file.filename().string().c_str(),
                    FourCCString(info.codecFourcc).c_str(), info.codedWidth, info.codedHeight, reader->videoSamples().size(),
                    seconds, period, reader->warnings().size());
        ASSERT_FALSE(reader->videoSamples().empty());
        std::int64_t previousDts = std::numeric_limits<std::int64_t>::min();
        for (const Sample& sample : reader->videoSamples()) {
            ASSERT_LE(sample.offset + sample.size, source->size());
            EXPECT_LE(sample.dts, sample.pts) << "a frame cannot be decoded after it is due";
            EXPECT_GE(sample.dts, previousDts) << "decode times never go backwards";
            previousDts = sample.dts;
        }
        for (std::size_t track = 0; track < reader->tracks().size(); ++track) {
            for (const MatroskaPacket& packet : reader->packets(track)) ASSERT_LE(packet.offset + packet.size, source->size());
        }
        EXPECT_TRUE(reader->videoSamples().front().sync);
        EXPECT_TRUE(reader->findVideoKeyframeAtOrBefore(0).has_value());
        if (ffprobe.empty()) continue;
        const auto probed = Ffprobe(ffprobe, file);
        if (probed.count("width") == 0) continue;
        ++compared;
        EXPECT_EQ(std::to_string(info.codedWidth), probed.at("width"));
        EXPECT_EQ(std::to_string(info.codedHeight), probed.at("height"));
        if (reader->warnings().empty() && probed.count("nb_read_packets") != 0) {
            EXPECT_EQ(std::to_string(reader->videoSamples().size()), probed.at("nb_read_packets"));
        }
        if (probed.count("format.duration") != 0 && probed.at("format.duration") != "N/A") {
            EXPECT_NEAR(seconds, std::atof(probed.at("format.duration").c_str()), std::max(0.1, 2 * period)) << "duration vs ffprobe";
        }
    }
    std::printf("%zu of %zu files compared with ffprobe\n", compared, files.size());
}

} // namespace
} // namespace wallpaper::media
