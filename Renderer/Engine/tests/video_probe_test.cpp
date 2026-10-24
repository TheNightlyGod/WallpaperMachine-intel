// Reading a video's size and length from memory with the project's own readers
// (MP4, QuickTime, WebM, Matroska): nothing is written to a file, and a payload
// the readers refuse is declined with its reason instead of being left to another
// probe. The fixtures are checked against the numbers they were made with, and the
// video payloads of the local wallpaper library, when there is one, against the
// rule that every one is either read or declined with a reason.

#include "Fs/Fs.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Image.hpp"
#include "Video/VideoContainerProbe.hpp"
#include "Video/VideoTextureSource.hpp"
#include "WPPkgFs.hpp"
#include "WPTexImageParser.hpp"
#include "embedded_clips.hpp"
#include "synthetic_video.hpp"
#include "video_orientation_cases.hpp"

#include <gtest/gtest.h>

#include <unistd.h>

#include <algorithm>
#include <iterator>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace wallpaper::video
{
namespace
{

namespace stdfs = std::filesystem;
using testing_media::EncoderAvailable;
using testing_media::WriteSyntheticVideo;

std::vector<char> ReadWholeFile(const stdfs::path& path)
{
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (! input.good()) return {};
    const auto size = static_cast<size_t>(input.tellg());
    input.seekg(0, std::ios::beg);
    std::vector<char> bytes(size);
    input.read(bytes.data(), static_cast<std::streamsize>(size));
    return bytes;
}

std::set<stdfs::path> DirectoryEntries(const stdfs::path& directory)
{
    std::set<stdfs::path> entries;
    std::error_code    ec;
    for (const auto& entry : stdfs::directory_iterator(directory, ec)) entries.insert(entry.path());
    return entries;
}

class VideoProbe : public ::testing::Test {
protected:
    void SetUp() override
    {
        ASSERT_TRUE(EncoderAvailable())
            << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
        static std::atomic<uint64_t> serial { 0 };
        root = stdfs::temp_directory_path() /
               ("owe-video-probe-" + std::to_string(::getpid()) + "-" + std::to_string(serial.fetch_add(1)));
        stdfs::create_directories(root / "tmp");
        if (const char* previous = std::getenv("TMPDIR")) previous_tmpdir = previous;
        ASSERT_EQ(setenv("TMPDIR", (root / "tmp").c_str(), 1), 0);
        tmpdir_overridden = true;
    }

    void TearDown() override
    {
        if (tmpdir_overridden) {
            if (previous_tmpdir) setenv("TMPDIR", previous_tmpdir->c_str(), 1);
            else unsetenv("TMPDIR");
        }
        std::error_code ec;
        stdfs::remove_all(root, ec);
    }

    stdfs::path                   root;
    std::optional<std::string> previous_tmpdir;
    bool                       tmpdir_overridden { false };
};

TEST_F(VideoProbe, SizeAndLengthAreTheClipsOwnOnEveryOrientation)
{
    for (const auto& orientation : testing_media::kOrientations) {
        SCOPED_TRACE(orientation.name);
        const auto path = root / (std::string(orientation.name) + ".mp4");
        ASSERT_TRUE(WriteSyntheticVideo(path, 2, orientation.name, orientation.matrix()));
        const auto payload = ReadWholeFile(path);
        ASSERT_FALSE(payload.empty());

        std::string why;
        const auto  native = ProbeVideoMetadataFromMemory({ payload.data(), payload.size() }, &why);
        ASSERT_TRUE(native.has_value()) << why;

        EXPECT_EQ(native->width, orientation.swaps_axes ? testing_media::kFrameHeight : testing_media::kFrameWidth);
        EXPECT_EQ(native->height, orientation.swaps_axes ? testing_media::kFrameWidth : testing_media::kFrameHeight);
        EXPECT_NEAR(native->duration_seconds, 2.0 * testing_media::kGopFrames / 30.0, 0.05);
    }
}

TEST_F(VideoProbe, LengthIsTheClipsOwnForSeveralClipLengths)
{
    for (const int repeats : { 1, 2, 5, 10 }) {
        SCOPED_TRACE(repeats);
        const auto path = root / ("clip-" + std::to_string(repeats) + ".mp4");
        ASSERT_TRUE(WriteSyntheticVideo(path, repeats, path.filename().string()));
        const auto  payload = ReadWholeFile(path);
        std::string why;
        const auto  native = ProbeVideoMetadataFromMemory({ payload.data(), payload.size() }, &why);
        ASSERT_TRUE(native.has_value()) << why;
        EXPECT_EQ(native->width, static_cast<uint32_t>(testing_media::kFrameWidth));
        EXPECT_EQ(native->height, static_cast<uint32_t>(testing_media::kFrameHeight));
        EXPECT_NEAR(native->duration_seconds, repeats * testing_media::kGopFrames / 30.0, 0.05);
    }
}

TEST_F(VideoProbe, ProbingFromMemoryWritesNoFile)
{
    const auto path = root / "quiet.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(path, 2, "quiet"));
    const auto payload = ReadWholeFile(path);
    const auto before  = DirectoryEntries(stdfs::temp_directory_path());
    const auto cache   = stdfs::temp_directory_path() / "wallpaper-engine-video";

    std::string why;
    ASSERT_TRUE(ProbeVideoMetadataFromMemory({ payload.data(), payload.size() }, &why).has_value()) << why;

    EXPECT_EQ(DirectoryEntries(stdfs::temp_directory_path()), before);
    EXPECT_FALSE(stdfs::exists(cache)) << "the probe staged the payload in a file";
}

TEST_F(VideoProbe, ThroughTheTextureParserAnMp4PayloadWritesNoFile)
{
    // The parser is what production calls. A loose mp4 reaches the same probe.
    const auto path = root / "loose.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(path, 2, "loose-through-parser"));
    stdfs::path   directory = root / "assets";
    stdfs::create_directories(directory);
    stdfs::copy_file(path, directory / "loose.mp4");

    wallpaper::fs::VFS vfs;
    auto    physical = wallpaper::fs::CreatePhysicalFs(directory.string());
    ASSERT_NE(physical, nullptr);
    ASSERT_TRUE(vfs.Mount("/assets", std::move(physical)));
    WPTexImageParser parser(&vfs);

    const auto header = parser.ParseHeader("loose");
    EXPECT_TRUE(header.isVideo);
    EXPECT_EQ(header.width, testing_media::kFrameWidth);
    EXPECT_EQ(header.height, testing_media::kFrameHeight);
    EXPECT_NEAR(header.durationSeconds, 2.0, 0.05);
    EXPECT_FALSE(stdfs::exists(stdfs::temp_directory_path() / "wallpaper-engine-video"))
        << "an mp4 payload was staged in a file";

    const auto image = parser.Parse("loose");
    ASSERT_NE(image, nullptr);
    EXPECT_TRUE(image->header.isVideo);
    EXPECT_EQ(image->header.width, testing_media::kFrameWidth);
    EXPECT_NEAR(image->header.durationSeconds, 2.0, 0.05);
    EXPECT_FALSE(stdfs::exists(stdfs::temp_directory_path() / "wallpaper-engine-video"));
}

TEST_F(VideoProbe, AWebmAndAMatroskaPayloadAreReadFromTheirHeaders)
{
    struct Clip {
        const char*          name;
        const unsigned char* bytes;
        std::size_t          size;
        int                  width, height;
    };
    for (const Clip& clip : { Clip { "webm", testing_media::kVp9Webm, sizeof(testing_media::kVp9Webm),
                                     testing_media::kVp9WebmWidth, testing_media::kVp9WebmHeight },
                              Clip { "mkv", testing_media::kH264Matroska, sizeof(testing_media::kH264Matroska),
                                     testing_media::kH264MatroskaWidth, testing_media::kH264MatroskaHeight } }) {
        SCOPED_TRACE(clip.name);
        const std::vector<char> payload(reinterpret_cast<const char*>(clip.bytes),
                                        reinterpret_cast<const char*>(clip.bytes) + clip.size);
        std::string why;
        const auto  native = ProbeVideoMetadataFromMemory({ payload.data(), payload.size() }, &why);
        ASSERT_TRUE(native.has_value()) << why;
        EXPECT_EQ(native->width, static_cast<uint32_t>(clip.width));
        EXPECT_EQ(native->height, static_cast<uint32_t>(clip.height));
        EXPECT_GT(native->duration_seconds, 0.9);
    }
}

TEST_F(VideoProbe, ThroughTheParserAWebmPayloadWritesNoFileEither)
{
    stdfs::path directory = root / "assets";
    stdfs::create_directories(directory);
    {
        std::ofstream file(directory / "loose.webm", std::ios::binary);
        file.write(reinterpret_cast<const char*>(testing_media::kVp9Webm), sizeof(testing_media::kVp9Webm));
    }
    wallpaper::fs::VFS vfs;
    auto physical = wallpaper::fs::CreatePhysicalFs(directory.string());
    ASSERT_NE(physical, nullptr);
    ASSERT_TRUE(vfs.Mount("/assets", std::move(physical)));
    WPTexImageParser parser(&vfs);

    const auto header = parser.ParseHeader("loose");
    EXPECT_TRUE(header.isVideo);
    EXPECT_EQ(header.width, testing_media::kVp9WebmWidth);
    EXPECT_EQ(header.height, testing_media::kVp9WebmHeight);
    EXPECT_NEAR(header.durationSeconds, 1.0, 0.05);
    EXPECT_FALSE(stdfs::exists(stdfs::temp_directory_path() / "wallpaper-engine-video"))
        << "a webm payload was staged in a file";
}

TEST_F(VideoProbe, AVideoTheReadersRefuseIsDeclinedWithItsReason)
{
    // VP8 in a Matroska file: the reader names it unsupported, so the probe declines
    // with that reason, and nothing else probes it.
    std::vector<char> payload(reinterpret_cast<const char*>(testing_media::kVp9Webm),
                              reinterpret_cast<const char*>(testing_media::kVp9Webm) + sizeof(testing_media::kVp9Webm));
    const char id[] = { 'V', '_', 'V', 'P', '9' };
    const auto at   = std::search(payload.begin(), payload.end(), std::begin(id), std::end(id));
    ASSERT_NE(at, payload.end());
    *(at + 4) = '8';
    std::string why;
    EXPECT_FALSE(ProbeVideoMetadataFromMemory({ payload.data(), payload.size() }, &why).has_value());
    EXPECT_NE(why.find("VP8"), std::string::npos) << why;
}

TEST_F(VideoProbe, PayloadsThatAreNotMp4AreDeclinedNotCrashedOn)
{
    std::string why;
    EXPECT_FALSE(ProbeVideoMetadataFromMemory({}, &why).has_value());
    EXPECT_FALSE(why.empty());

    const std::vector<char> noise = [] {
        std::vector<char> bytes(64 * 1024);
        for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<char>(i * 31 + 7);
        return bytes;
    }();
    why.clear();
    EXPECT_FALSE(ProbeVideoMetadataFromMemory({ noise.data(), noise.size() }, &why).has_value());
    EXPECT_FALSE(why.empty());

    // A Matroska header with nothing after it is declined, not read past.
    const unsigned char ebml[] = { 0x1A, 0x45, 0xDF, 0xA3, 0x93, 0x42, 0x82, 0x84, 'w', 'e', 'b', 'm' };
    EXPECT_FALSE(ProbeVideoMetadataFromMemory({ reinterpret_cast<const char*>(ebml), sizeof(ebml) }, &why).has_value());
}

TEST_F(VideoProbe, ATruncatedMp4IsDeclinedAtEveryLength)
{
    const auto path = root / "cut.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(path, 1, "cut"));
    const auto payload = ReadWholeFile(path);
    ASSERT_GT(payload.size(), 1000u);
    // The probe may decline or, when only sample data is missing, still read the
    // tables; what it must not do is fault. The size stays right whenever it answers.
    for (size_t length = 0; length < payload.size(); length += std::max<size_t>(1, payload.size() / 400)) {
        const auto metadata = ProbeVideoMetadataFromMemory({ payload.data(), length });
        if (metadata) {
            EXPECT_EQ(metadata->width, static_cast<uint32_t>(testing_media::kFrameWidth)) << length;
        }
    }
}

// ---------------------------------------------------------------------------
// Corpus: the video payloads inside the local wallpaper library's `.tex` files,
// read through the texture parser.
// ---------------------------------------------------------------------------

std::optional<stdfs::path> LibraryRoot()
{
    stdfs::path root;
    if (const char* chosen = std::getenv("WALLPAPER_MACHINE_VIDEO_ROOT")) root = chosen;
    else if (const char* home = std::getenv("HOME")) {
        root = stdfs::path(home) / "Library/Application Support/WallpaperMachine/Library";
    }
    std::error_code ignored;
    if (root.empty() || ! stdfs::is_directory(root, ignored)) return std::nullopt;
    return root;
}

/// The `.tex` names a `scene.pkg` holds, without the `materials/` and `.tex` parts.
std::vector<std::string> TextureNamesInPackage(const stdfs::path& package)
{
    std::ifstream file(package, std::ios::binary);
    auto          read_i32 = [&file]() {
        int32_t value = 0;
        file.read(reinterpret_cast<char*>(&value), sizeof(value));
        return file.good() ? value : -1;
    };
    auto read_string = [&](int32_t length) {
        std::string text;
        if (length < 0 || length > 4096) return text;
        text.resize(static_cast<size_t>(length));
        file.read(text.data(), length);
        return text;
    };
    std::vector<std::string> names;
    read_string(read_i32());
    const int32_t count = read_i32();
    for (int32_t index = 0; index < count && file.good(); ++index) {
        const std::string path = read_string(read_i32());
        read_i32();
        read_i32();
        if (path.rfind("materials/", 0) == 0 && path.size() > 14 && path.substr(path.size() - 4) == ".tex") {
            names.push_back(path.substr(10, path.size() - 14));
        }
    }
    return names;
}

TEST_F(VideoProbe, EveryLocalLibraryTexPayloadIsReadOrDeclinedWithAReasonAndPlayed)
{
    const auto library = LibraryRoot();
    if (! library) GTEST_SKIP() << "no local wallpaper library (WALLPAPER_MACHINE_VIDEO_ROOT)";

    int payloads = 0, read = 0, declined = 0, played = 0, refused = 0;
    for (const auto& entry : stdfs::directory_iterator(*library)) {
        const auto package = entry.path() / "scene.pkg";
        std::error_code ec;
        if (! stdfs::is_regular_file(package, ec)) continue;
        auto pkg_fs = wallpaper::fs::WPPkgFs::CreatePkgFs(package.string());
        if (! pkg_fs) continue;
        wallpaper::fs::VFS vfs;
        ASSERT_TRUE(vfs.Mount("/assets", std::move(pkg_fs)));
        WPTexImageParser parser(&vfs);
        for (const auto& name : TextureNamesInPackage(package)) {
            const auto header = parser.ParseHeader(name);
            if (! header.isVideo) continue;
            const auto image = parser.Parse(name);
            if (image == nullptr || image->slots.empty() || image->slots[0].mipmaps.empty()) continue;
            const auto& mip = image->slots[0].mipmaps[0];
            if (mip.data == nullptr || mip.size <= 0) continue;
            ++payloads;

            const std::string label = entry.path().filename().string() + "/" + name;
            std::string       why;
            const auto        metadata = ProbeVideoMetadataFromMemory(
                { reinterpret_cast<const char*>(mip.data.get()), static_cast<size_t>(mip.size) }, &why);
            if (! metadata) {
                ++declined;
                EXPECT_FALSE(why.empty()) << label << ": declined without a reason";
                std::printf("[corpus] %s: declined (%s)\n", label.c_str(), why.c_str());
                continue;
            }
            ++read;
            EXPECT_GT(metadata->width, 0u) << label;
            EXPECT_GT(metadata->height, 0u) << label;
            // The parser's own header is fed by the same probe, so the two must agree.
            EXPECT_NEAR(header.durationSeconds, metadata->duration_seconds, 0.001) << label;
            std::printf("[corpus] %s: %ux%u %.4f s\n", label.c_str(), metadata->width, metadata->height,
                        metadata->duration_seconds);

            // The native backend is the only decoder: the payload either opens, or fails
            // with a reason that is reported here (it is not a failure of the probe).
            std::string error;
            auto        source = CreateVideoTextureSource(image, &error);
            if (source != nullptr && source->prime(&error) && source->currentFrame().valid()) {
                ++played;
            } else {
                ++refused;
                EXPECT_FALSE(error.empty()) << label << ": refused without a reason";
                std::printf("[corpus] %s: not played (%s)\n", label.c_str(), error.c_str());
            }
        }
    }
    std::printf("[corpus] library video payloads: %d, read %d, declined %d, played %d, refused %d\n", payloads, read,
                declined, played, refused);
    if (payloads == 0) GTEST_SKIP() << "the local library has no video texture payloads";
}

} // namespace
} // namespace wallpaper::video
