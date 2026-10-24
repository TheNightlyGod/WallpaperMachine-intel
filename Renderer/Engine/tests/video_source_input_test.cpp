// What a video source is allowed to do with a media file.
//
// A plain local file is decode input, not a payload: it must be opened where it
// lies, never read into the process and never copied into the shared cache.
// Embedded media is read where it lies too, from memory or from an anonymous
// file, and no file with a name is ever written for it. Everything below drives
// `CreateVideoTextureSource` over media the test encodes for itself, on an image
// that names its file the way the engine once built one for a video project
// (`video_project_image.hpp`). The native backend (the project's own container
// readers and VideoToolbox) is the only decoder, so a medium it cannot play
// fails with its own reason and nothing else is tried.
//
// The last group is the clock a consumer gives a source: a source opened when
// the scene is already some way into the clip, and what a jump of that clock
// costs the decoder.

#include "Image.hpp"
#include "Media/IsoBmff/IsoBmffReader.hpp"
#include "Video/NativeVideoBackend.hpp"
#include "Video/VideoMedia.hpp"
#include "video_project_image.hpp"
#include "Video/VideoSeekPolicy.hpp"
#include "Video/VideoTextureSource.hpp"
#include "embedded_clips.hpp"
#include "synthetic_video.hpp"
#include "video_orientation_cases.hpp"

#include <gtest/gtest.h>

#include <mach/mach.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace wallpaper::video
{
namespace
{

namespace wm = wallpaper::media;
using testing_media::kFrameHeight;
using testing_media::kFrameWidth;
using testing_media::EncoderAvailable;
using testing_media::WriteSyntheticVideo;

std::vector<char> ReadWholeFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input.good()) return {};
    const auto size = static_cast<size_t>(input.tellg());
    input.seekg(0, std::ios::beg);
    std::vector<char> bytes(size);
    input.read(bytes.data(), static_cast<std::streamsize>(size));
    return bytes;
}

/// Builds the in-package shape: the media bytes ride inside the image itself,
/// exactly as `WPTexImageParser` hands them over for a packaged asset.
std::shared_ptr<Image> MakeInlinePayloadImage(const std::string& key,
                                              const std::vector<char>& payload) {
    auto image                      = std::make_shared<Image>();
    image->key                      = key;
    image->header.isVideo           = true;
    image->header.count             = 1;
    image->header.width             = kFrameWidth;
    image->header.height            = kFrameHeight;

    Image::Slot slot;
    slot.width  = kFrameWidth;
    slot.height = kFrameHeight;

    ImageData mip;
    mip.width  = kFrameWidth;
    mip.height = kFrameHeight;
    mip.size   = static_cast<isize>(payload.size());
    mip.data   = ImageDataPtr(new uint8_t[payload.size()], [](uint8_t* data) { delete[] data; });
    std::memcpy(mip.data.get(), payload.data(), payload.size());
    slot.mipmaps.push_back(std::move(mip));
    image->slots.push_back(std::move(slot));
    return image;
}

std::filesystem::path VideoCacheDirectory() {
    return std::filesystem::temp_directory_path() / "wallpaper-engine-video";
}

/// TMPDIR is private to this test process; production's cache path therefore
/// remains realistic without touching another renderer's cache.
std::set<std::filesystem::path> VideoCacheEntries() {
    std::set<std::filesystem::path> entries;
    std::error_code                 ec;
    for (const auto& entry : std::filesystem::directory_iterator(VideoCacheDirectory(), ec)) {
        entries.insert(entry.path());
    }
    return entries;
}

uint64_t PhysicalFootprintBytes() {
    task_vm_info_data_t    info {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) !=
        KERN_SUCCESS) {
        return 0;
    }
    return info.phys_footprint;
}

class VideoSourceInputBase : public ::testing::Test {
protected:
    void SetUp() override {
        ASSERT_TRUE(EncoderAvailable())
            << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
        static std::atomic<uint64_t> serial { 0 };
        project_dir = std::filesystem::temp_directory_path() /
                      ("owe-video-source-" + std::to_string(::getpid()) + "-" +
                       std::to_string(serial.fetch_add(1)));
        std::filesystem::create_directories(project_dir);
        if (const char* previous = std::getenv("TMPDIR")) previous_tmpdir = previous;
        const auto temp = project_dir / "tmp";
        std::filesystem::create_directories(temp);
        ASSERT_EQ(setenv("TMPDIR", temp.c_str(), 1), 0);
        tmpdir_overridden = true;
        // Cases set the payload spill threshold; each starts and ends on the default.
        if (const char* spill = std::getenv("WALLPAPER_MACHINE_VIDEO_SPILL_BYTES")) previous_spill = spill;
    }

    void TearDown() override {
        if (previous_spill) setenv("WALLPAPER_MACHINE_VIDEO_SPILL_BYTES", previous_spill->c_str(), 1);
        else unsetenv("WALLPAPER_MACHINE_VIDEO_SPILL_BYTES");
        if (tmpdir_overridden) {
            if (previous_tmpdir) setenv("TMPDIR", previous_tmpdir->c_str(), 1);
            else unsetenv("TMPDIR");
        }
        std::error_code ec;
        std::filesystem::remove_all(project_dir, ec);
        std::filesystem::remove_all(outside_dir, ec);
    }

    /// A directory deliberately outside the project, for containment cases.
    const std::filesystem::path& OutsideDir() {
        if (outside_dir.empty()) {
            outside_dir = project_dir.parent_path() / (project_dir.filename().string() + "-outside");
            std::filesystem::create_directories(outside_dir);
        }
        return outside_dir;
    }

    /// Only the private cache is inspected; cleanup owns the whole test root.
    std::set<std::filesystem::path> CacheEntriesAddedSince(
        const std::set<std::filesystem::path>& before) {
        std::set<std::filesystem::path> added;
        for (const auto& path : VideoCacheEntries()) {
            if (before.count(path) == 0) added.insert(path);
        }
        return added;
    }

    std::filesystem::path           project_dir;
    std::filesystem::path           outside_dir;
    std::optional<std::string> previous_tmpdir;
    std::optional<std::string> previous_spill;
    bool tmpdir_overridden { false };
};

/// A case over a source and its media.
class VideoSourceInput : public VideoSourceInputBase {};

/// How an embedded payload reaches the decoder: from memory, or from an anonymous
/// file when it is large, and never from a named one.
class NativePayloads : public VideoSourceInputBase {
protected:
    /// Every entry under the private temporary directory, which a staged file would be in.
    std::set<std::filesystem::path> TemporaryEntries() {
        std::set<std::filesystem::path> entries;
        std::error_code                 ec;
        for (const auto& entry : std::filesystem::recursive_directory_iterator(project_dir / "tmp", ec)) {
            entries.insert(entry.path());
        }
        return entries;
    }
};

TEST_F(VideoSourceInput, DisplayMatrixSurvivesMetadataProbeAndFrameExtraction) {
    for (const auto& orientation : testing_media::kOrientations) {
        SCOPED_TRACE(orientation.name);
        const std::string name = std::string(orientation.name) + ".mp4";
        ASSERT_TRUE(WriteSyntheticVideo(project_dir / name, 1, name, orientation.matrix()));
        std::string error;
        auto image = CreateVideoProjectImage(project_dir, name, &error);
        ASSERT_NE(image, nullptr) << error;
        auto source = CreateVideoTextureSource(image, &error);
        ASSERT_NE(source, nullptr) << error;
        ASSERT_TRUE(source->prime(&error)) << error;
        const auto frame = source->currentFrame();
        ASSERT_TRUE(frame.valid());
        EXPECT_EQ(frame.width, kFrameWidth); EXPECT_EQ(frame.height, kFrameHeight);
        EXPECT_EQ(frame.displayWidth(), orientation.swaps_axes ? kFrameHeight : kFrameWidth);
        EXPECT_EQ(frame.displayHeight(), orientation.swaps_axes ? kFrameWidth : kFrameHeight);
        EXPECT_EQ(image->header.width, frame.displayWidth());
        EXPECT_EQ(image->header.height, frame.displayHeight());
        const auto expected = ResolveVideoDisplayTransform(orientation.matrix(), kFrameWidth, kFrameHeight);
        ASSERT_TRUE(expected.has_value());
        EXPECT_EQ(frame.display_transform.matrix, expected->matrix);
        EXPECT_EQ(frame.display_transform.offset, expected->offset);
    }
}

TEST_F(VideoSourceInput, PlainLocalFileIsDecodedWhereItLies) {
    const auto media = project_dir / "media.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "plain-local"));
    const auto original_size  = std::filesystem::file_size(media);
    const auto original_write = std::filesystem::last_write_time(media);
    const auto cache_before   = VideoCacheEntries();

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "media.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    // No slots is the whole point: there is no second copy of the media to own.
    EXPECT_TRUE(image->slots.empty());
    EXPECT_EQ(image->videoFilePath, std::filesystem::canonical(media).string());
    EXPECT_EQ(image->header.width, kFrameWidth);
    EXPECT_EQ(image->header.height, kFrameHeight);

    auto source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_TRUE(source->currentFrame().valid());
    EXPECT_GT(source->durationSeconds(), 0.0);

    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
    EXPECT_EQ(std::filesystem::file_size(media), original_size);
    EXPECT_EQ(std::filesystem::last_write_time(media), original_write);
}

TEST_F(VideoSourceInput, LargeLocalFileIsNeverResident) {
    const auto media = project_dir / "large.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 96, "large-local"));
    const auto media_size = std::filesystem::file_size(media);
    ASSERT_GT(media_size, 48u * 1024u * 1024u);
    const auto cache_before = VideoCacheEntries();

    const uint64_t before = PhysicalFootprintBytes();
    ASSERT_GT(before, 0u);

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "large.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    ASSERT_TRUE(source->currentFrame().valid());

    const uint64_t after  = PhysicalFootprintBytes();
    const uint64_t growth = after > before ? after - before : 0;
    // Decoded 640x360 frames and the decoder's own buffers are megabytes; a copy
    // of the media would be tens of them, twice over.
    EXPECT_LT(growth, 16u * 1024u * 1024u)
        << "opening a " << media_size << " byte file grew the footprint by " << growth << " bytes";
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

TEST_F(VideoSourceInput, ConcurrentOpensOfOneFileEachGetTheirOwnDecoder) {
    const auto media = project_dir / "shared.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "concurrent-local"));
    const auto cache_before = VideoCacheEntries();

    constexpr int              kOpeners = 4;
    std::vector<std::thread>   threads;
    std::vector<std::string>   errors(kOpeners);
    std::vector<uint64_t>      instance_ids(kOpeners, 0);
    std::atomic<int>           primed { 0 };
    for (int index = 0; index < kOpeners; ++index) {
        threads.emplace_back([&, index]() {
            auto image = CreateVideoProjectImage(project_dir, "shared.mp4", &errors[index]);
            if (image == nullptr) return;
            auto source = CreateVideoTextureSource(image, &errors[index]);
            if (source == nullptr) return;
            if (!source->prime(&errors[index])) return;
            instance_ids[index] = source->sourceStats().instance_id;
            primed.fetch_add(1);
        });
    }
    for (auto& thread : threads) thread.join();

    EXPECT_EQ(primed.load(), kOpeners) << errors[0] << "|" << errors[1] << "|" << errors[2] << "|"
                                       << errors[3];
    const std::set<uint64_t> distinct(instance_ids.begin(), instance_ids.end());
    EXPECT_EQ(distinct.size(), static_cast<size_t>(kOpeners));
    EXPECT_EQ(distinct.count(0), 0u);
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

TEST_F(VideoSourceInput, MissingMediaIsReportedAndNotOpened) {
    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "absent.mp4", &error), nullptr);
    EXPECT_NE(error.find("failed to open video project media file"), std::string::npos) << error;

    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "", &error), nullptr);
    EXPECT_EQ(error, "video project file entry must not be empty");

    // A file that disappears between resolution and decode fails on prime
    // rather than at construction, and still reports rather than crashing.
    const auto media = project_dir / "vanishing.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 1, "vanishing"));
    error.clear();
    auto image = CreateVideoProjectImage(project_dir, "vanishing.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    std::filesystem::remove(media);
    auto source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    error.clear();
    EXPECT_FALSE(source->prime(&error));
    EXPECT_FALSE(error.empty());
}

TEST_F(VideoSourceInput, EmptyMediaIsReported) {
    const auto media = project_dir / "empty.mp4";
    std::ofstream(media, std::ios::binary).close();
    ASSERT_TRUE(std::filesystem::exists(media));

    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "empty.mp4", &error), nullptr);
    EXPECT_NE(error.find("video project media file is empty"), std::string::npos) << error;
}

TEST_F(VideoSourceInput, CorruptMediaFailsWithoutWritingAFile) {
    const auto media = project_dir / "corrupt.mp4";
    {
        std::ofstream output(media, std::ios::binary);
        std::vector<char> noise(64 * 1024);
        for (size_t i = 0; i < noise.size(); ++i) noise[i] = static_cast<char>(i * 31 + 7);
        output.write(noise.data(), static_cast<std::streamsize>(noise.size()));
    }
    const auto cache_before = VideoCacheEntries();

    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "corrupt.mp4", &error), nullptr);
    EXPECT_FALSE(error.empty());

    // The same bytes offered as a packaged payload must fail on prime, not on
    // an unchecked decode.
    auto image  = MakeInlinePayloadImage("corrupt-inline", ReadWholeFile(media));
    error.clear();
    auto source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    error.clear();
    EXPECT_FALSE(source->prime(&error));
    EXPECT_FALSE(error.empty());
    source.reset();

    // A rejected payload leaves nothing behind: no file is staged for it.
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

TEST_F(VideoSourceInput, MediaOutsideTheProjectIsRejected) {
    const auto outside = OutsideDir() / "outside.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(outside, 1, "outside"));
    const auto inside = project_dir / "inside.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(inside, 1, "inside"));

    std::string error;
    const auto  traversal =
        std::filesystem::path("..") / OutsideDir().filename() / "outside.mp4";
    EXPECT_EQ(CreateVideoProjectImage(project_dir, traversal.string(), &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, outside.string(), &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    // A symlink is resolved before the containment test, so pointing out of the
    // project is rejected even though the link itself lives inside it.
    std::error_code ec;
    std::filesystem::create_symlink(outside, project_dir / "escape.mp4", ec);
    ASSERT_FALSE(ec);
    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "escape.mp4", &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    // A link that stays inside the project is still ordinary media.
    std::filesystem::create_symlink(inside, project_dir / "alias.mp4", ec);
    ASSERT_FALSE(ec);
    error.clear();
    auto image = CreateVideoProjectImage(project_dir, "alias.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    EXPECT_EQ(image->videoFilePath, std::filesystem::canonical(inside).string());
}

TEST_F(VideoSourceInput, ASourceSharesAnInlinePayloadInsteadOfCopyingIt) {
    const auto media = project_dir / "shared-payload.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 96, "shared-payload"));
    const auto payload = ReadWholeFile(media);
    ASSERT_GT(payload.size(), 32u * 1024u * 1024u);
    // The image is built before the footprint is read, so what is measured is
    // what making a source adds to a payload that is already resident.
    auto image = MakeInlinePayloadImage("shared-payload.mp4", payload);

    const uint64_t before = PhysicalFootprintBytes();
    std::string    error;
    auto           source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    const uint64_t after  = PhysicalFootprintBytes();
    const uint64_t growth = after > before ? after - before : 0;
    EXPECT_LT(growth, 16u * 1024u * 1024u)
        << "a source on a " << payload.size() << " byte payload grew the footprint by " << growth
        << " bytes";
}

TEST_F(VideoSourceInput, TwoSourcesOnOnePayloadPlayIndependently) {
    const auto media = project_dir / "twice.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "twice-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());

    auto        image = MakeInlinePayloadImage("twice.mp4", payload);
    std::string error;
    auto        first  = CreateVideoTextureSource(image, &error);
    auto        second = CreateVideoTextureSource(image, &error);
    ASSERT_NE(first, nullptr) << error;
    ASSERT_NE(second, nullptr) << error;
    image.reset();

    ASSERT_TRUE(first->prime(&error)) << error;
    first.reset();
    // The first source's teardown left the shared bytes alone.
    ASSERT_TRUE(second->prime(&error)) << error;
    EXPECT_TRUE(second->currentFrame().valid());
}

// B-frames: the order the samples are stored in is not the order they are shown in, and the first
// pictures of the file are decoded before the ones that precede them in time.
TEST_F(VideoSourceInput, AClipWithBFramesPlaysFromItsFirstFrameInDisplayOrder) {
    ASSERT_TRUE(testing_media::WriteReorderedVideo(project_dir / "reordered.mp4", "reordered-" + std::to_string(::getpid())));
    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "reordered.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_NEAR(source->currentFrame().pts_seconds, 0.0, 0.001) << "the first picture shown is not the first of the clip";
    EXPECT_NEAR(source->durationSeconds(), testing_media::kReorderedFrames / 30.0, 0.05);

    double last_pts = -1.0;
    for (int frame = 0; frame < testing_media::kReorderedFrames; ++frame) {
        const double clock = frame / 30.0;
        ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, clock }, &error)) << error;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        do {
            ASSERT_TRUE(source->refreshFrame(&error)) << error;
            if (std::abs(source->currentFrame().pts_seconds - clock) < 0.034) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        } while (std::chrono::steady_clock::now() < deadline);
        const double pts = source->currentFrame().pts_seconds;
        EXPECT_NEAR(pts, clock, 0.034) << "frame " << frame;
        EXPECT_GE(pts + 1e-9, last_pts) << "frame " << frame << " came out of display order";
        last_pts = pts;
    }
}

TEST_F(VideoSourceInput, DestroyingASourceMidDecodeCancelsPromptly) {
    const auto media = project_dir / "cancelled.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 96, "cancelled"));
    const auto cache_before = VideoCacheEntries();

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "cancelled.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;

    // The decode thread is reading a large file; tearing the source down has to
    // abort that read instead of waiting for it.
    const auto start = std::chrono::steady_clock::now();
    source.reset();
    const auto elapsed = std::chrono::steady_clock::now() - start;
    EXPECT_LT(elapsed, std::chrono::seconds(2));

    // A source that is dropped before it is ever primed opens nothing at all.
    auto unprimed_image  = CreateVideoProjectImage(project_dir, "cancelled.mp4", &error);
    ASSERT_NE(unprimed_image, nullptr) << error;
    auto unprimed_source = CreateVideoTextureSource(unprimed_image, &error);
    ASSERT_NE(unprimed_source, nullptr) << error;
    unprimed_source.reset();

    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

/// A source on a clip of `seconds` seconds, with nothing yet asked of it.
class VideoSourceClock : public VideoSourceInput {
protected:
    std::shared_ptr<VideoTextureSource> Open(const std::string& name, int seconds) {
        EXPECT_TRUE(WriteSyntheticVideo(project_dir / name, seconds, name));
        std::string error;
        auto        image = CreateVideoProjectImage(project_dir, name, &error);
        EXPECT_NE(image, nullptr) << error;
        if (image == nullptr) return nullptr;
        auto source = CreateVideoTextureSource(image, &error);
        EXPECT_NE(source, nullptr) << error;
        return source;
    }

    /// Plays on from `start_seconds` at the pace of a wall clock, as a scene
    /// does when it is drawn in real time, and returns whether the frame on
    /// offer is within `tolerance` of that clock: as soon as it is, or, with
    /// `until_arrival` off, once `budget` has run out. Each step is one call of
    /// a draw -- the clock is handed over, then a frame is asked for -- and a
    /// step is far shorter than a seek.
    static bool FollowsTheClock(VideoTextureSource& source, double start_seconds,
                                double tolerance, std::chrono::milliseconds budget,
                                bool until_arrival = true) {
        std::string error;
        const auto  begin = std::chrono::steady_clock::now();
        bool        near  = false;
        while (std::chrono::steady_clock::now() - begin < budget) {
            const double clock =
                start_seconds +
                std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
            if (! source.syncPlayback(VideoPlaybackState { false, 1.0f, clock }, &error)) return false;
            if (! source.refreshFrame(&error)) return false;
            near = std::abs(source.currentFrame().pts_seconds - clock) <= tolerance;
            if (near && until_arrival) return true;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return near;
    }
};

// A scene whose graph is rebuilt keeps its videos open, but one that is opened
// while its clock is already some way into the clip still happens: a scene that
// is rebuilt after a failure, a surface split off a shared decoder. The open
// costs what opening at the head costs, however far in the clock is: it waits for
// no seek, and the seek to the clock is asked for once, on the first call that
// gives the source that clock after it has opened, and left to land. A source that
// waited for the seek would hold the render thread for as long as the seek takes,
// which on a clip of any size is more than a frame, and fail the open outright when
// it takes more than a few seconds.
TEST_F(VideoSourceClock, AReopenedSourceIsSoughtToTheClockOnceAndLeftToLand) {
    auto source = Open("reopened.mp4", 10);
    ASSERT_NE(source, nullptr);
    std::string error;
    // Even a clock handed over before the open is not one the open seeks to.
    ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, 6.5 }, &error)) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_NEAR(source->currentFrame().pts_seconds, 0.0, 0.1) << "the open waited for a seek";
    EXPECT_EQ(source->sourceStats().seek_requests, 0u);

    ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, 6.5 }, &error)) << error;
    ASSERT_TRUE(source->refreshFrame(&error)) << error;
    // The call that gives the clock returns with the head still on offer: it asked
    // for the seek and did not wait for it.
    EXPECT_NEAR(source->currentFrame().pts_seconds, 0.0, 0.1)
        << "the first call with the clock waited for the seek";
    EXPECT_EQ(source->sourceStats().seek_requests, 1u)
        << "the seek was not asked for as soon as the source had the clock";
    // A frame lasts a thirtieth of a second, and the first one at or after the
    // clock may be the one that started just before it.
    EXPECT_TRUE(FollowsTheClock(*source, 6.5, 0.15, std::chrono::seconds(2)))
        << "the frame on offer stayed at " << source->currentFrame().pts_seconds
        << " s with the clock at 6.5 s and after";
    EXPECT_EQ(source->sourceStats().seek_requests, 1u);

    // Past the end of a clip the clock wraps, as it does while playing: a 3 second
    // clip at 7.2 seconds is in its third pass, 1.2 seconds in.
    auto looping = Open("reopened-looping.mp4", 3);
    ASSERT_NE(looping, nullptr);
    ASSERT_TRUE(looping->prime(&error)) << error;
    EXPECT_TRUE(FollowsTheClock(*looping, 7.2, 0.15, std::chrono::seconds(2)))
        << "the frame on offer stayed at " << looping->currentFrame().pts_seconds
        << " s with the clock at 7.2 s and after";
    EXPECT_EQ(looping->sourceStats().seek_requests, 1u);
}

// The picture of a jump of the clock has to arrive even when frames are asked for
// faster than a seek takes. A seek asked for again on every call restarts the
// decode from the keyframe each time, so the display never leaves the frame it had.
TEST_F(VideoSourceClock, AJumpOfTheClockLandsWhileFramesAreAskedForFasterThanASeekTakes) {
    auto source = Open("jumped.mp4", 10);
    ASSERT_NE(source, nullptr);
    std::string error;
    ASSERT_TRUE(source->prime(&error)) << error;
    ASSERT_NEAR(source->currentFrame().pts_seconds, 0.0, 0.1);

    // A seek of a few frames' decode lands in well under a second; the two are for a
    // busy machine. The number of seeks is not: one that takes longer is waited for.
    EXPECT_TRUE(FollowsTheClock(*source, 7.5, 0.15, std::chrono::seconds(2)))
        << "the frame on offer stayed at " << source->currentFrame().pts_seconds
        << " s with the clock at 7.5 s and after";
    EXPECT_EQ(source->sourceStats().seek_requests, 1u)
        << "the decoder was sent back to the keyframe again on call after call";
}

// What a jump costs is a seek, and a source that is kept up with needs none.
TEST_F(VideoSourceClock, ASourceThatIsKeptUpWithNeverSeeks) {
    auto source = Open("kept-up.mp4", 10);
    ASSERT_NE(source, nullptr);
    std::string error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_TRUE(FollowsTheClock(*source, 0.0, 0.15, std::chrono::seconds(2), false));
    EXPECT_EQ(source->sourceStats().seek_requests, 0u) << "playing on from the start asked for a seek";
}

// A seek that is on its way is waited for only while the clock still wants what it
// is fetching. A clock that goes back before it, or runs on past it by more than a
// second, is a new jump and gets its own seek.
TEST_F(VideoSourceClock, AClockThatLeavesASeekBehindAsksForAnother) {
    auto source = Open("left-behind.mp4", 10);
    ASSERT_NE(source, nullptr);
    std::string error;
    ASSERT_TRUE(source->prime(&error)) << error;

    ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, 8.0 }, &error)) << error;
    ASSERT_TRUE(source->refreshFrame(&error)) << error;
    const auto after_first = source->sourceStats().seek_requests;
    EXPECT_EQ(after_first, 1u);

    // Back to 2 seconds before the first seek can have delivered.
    ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, 2.0 }, &error)) << error;
    ASSERT_TRUE(source->refreshFrame(&error)) << error;
    EXPECT_GT(source->sourceStats().seek_requests, after_first);
    EXPECT_TRUE(FollowsTheClock(*source, 2.0, 0.15, std::chrono::seconds(5)))
        << "the frame on offer stayed at " << source->currentFrame().pts_seconds << " s";
}

// The arithmetic behind that wait. A clip small enough to test is seeked in a few
// milliseconds, so what a seek of seconds is waited for, and not asked for again,
// is shown here.
TEST(VideoSeekPolicy, ASeekIsWaitedForAsLongAsItTakesWhileTheClockOnlyRunsOn) {
    constexpr double kBack = 0.067, kForward = 1.0;
    // The clock still stands where the seek was sent.
    EXPECT_TRUE(SeekOnItsWayCoversClock(8.2, 8.2, 0.0, 1.0, kBack, kForward));
    // Four seconds on, the clock has run four seconds, which waiting explains.
    EXPECT_TRUE(SeekOnItsWayCoversClock(8.2, 12.2, 4.0, 1.0, kBack, kForward));
    EXPECT_TRUE(SeekOnItsWayCoversClock(8.2, 16.2, 4.0, 2.0, kBack, kForward))
        << "a clock at twice the pace runs twice as far in the same wait";
    EXPECT_FALSE(SeekOnItsWayCoversClock(8.2, 16.2, 4.0, 1.0, kBack, kForward));
    // A clock that has run on further than that, by more than the slack, has jumped.
    EXPECT_FALSE(SeekOnItsWayCoversClock(8.2, 20.0, 4.0, 1.0, kBack, kForward));
    EXPECT_FALSE(SeekOnItsWayCoversClock(8.2, 13.3, 4.0, 1.0, kBack, kForward));
    // So has one that has gone back before the target by more than the slack.
    EXPECT_TRUE(SeekOnItsWayCoversClock(8.2, 8.15, 0.5, 1.0, kBack, kForward));
    EXPECT_FALSE(SeekOnItsWayCoversClock(8.2, 2.0, 0.5, 1.0, kBack, kForward));
    // A clock slower than real time, or a wait that reads as negative, is not given credit.
    EXPECT_EQ(ClockRunOnSeconds(4.0, 0.5), 4.0);
    EXPECT_EQ(ClockRunOnSeconds(4.0, 0.0), 4.0);
    EXPECT_EQ(ClockRunOnSeconds(-1.0, 1.0), 0.0);
}

TEST(VideoSeekPolicy, ALandingThatCameLateIsCaughtUpWithByDecodingOn) {
    // A source that has not seeked leaves a frame a second behind the clock alone.
    EXPECT_EQ(ForwardResyncSeconds(1.0 / 30.0, 8.0, 0.0), 1.0);
    // The span of a long queue at a slow frame rate is longer than that.
    EXPECT_DOUBLE_EQ(ForwardResyncSeconds(0.25, 8.0, 0.0), 4.0);
    // A seek that took 3.6 seconds landed 3.6 seconds behind the clock; asking for
    // another because of that would land as late again.
    EXPECT_DOUBLE_EQ(ForwardResyncSeconds(1.0 / 30.0, 8.0, ClockRunOnSeconds(3.6, 1.0)), 4.6);
}

// ---------------------------------------------------------------------------
// The native backend: how an embedded payload reaches it, what it does when a
// stream breaks or a medium is one nobody here plays, and the clip's own numbers.
// ---------------------------------------------------------------------------

namespace
{
std::string SpillBytes(uint64_t bytes) { return std::to_string(bytes); }
} // namespace

TEST_F(NativePayloads, InPackagePayloadIsDecodedFromMemoryAndWritesNoFile) {
    // Once with the payload kept in memory and once moved into an anonymous file:
    // neither may leave a file anywhere a staged one would be.
    for (const uint64_t spill_threshold : { uint64_t { 1ULL << 40 }, uint64_t { 0 } }) {
        SCOPED_TRACE(spill_threshold);
        setenv("WALLPAPER_MACHINE_VIDEO_SPILL_BYTES", SpillBytes(spill_threshold).c_str(), 1);
        const auto media = project_dir / ("packaged-" + std::to_string(spill_threshold) + ".mp4");
        ASSERT_TRUE(WriteSyntheticVideo(media, 2, "memory-" + std::to_string(spill_threshold)));
        const auto payload = ReadWholeFile(media);
        ASSERT_FALSE(payload.empty());
        const auto cache_before = VideoCacheEntries();
        const auto temp_before  = TemporaryEntries();

        auto        image = MakeInlinePayloadImage("packaged.mp4", payload);
        std::string error;
        auto        source = CreateVideoTextureSource(image, &error);
        ASSERT_NE(source, nullptr) << error;
        ASSERT_TRUE(source->prime(&error)) << error;
        EXPECT_TRUE(source->currentFrame().valid());
        EXPECT_GT(source->durationSeconds(), 0.0);

        EXPECT_EQ(TemporaryEntries(), temp_before) << "the payload was staged in a visible file";
        EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
    }
}

TEST_F(NativePayloads, ConcurrentPackagedOpensShareNoState) {
    const auto media = project_dir / "packaged-race.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "race-native-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    for (const uint64_t spill_threshold : { uint64_t { 1ULL << 40 }, uint64_t { 0 } }) {
        SCOPED_TRACE(spill_threshold);
        setenv("WALLPAPER_MACHINE_VIDEO_SPILL_BYTES", SpillBytes(spill_threshold).c_str(), 1);
        const auto temp_before = TemporaryEntries();

        constexpr int            kOpeners = 4;
        std::vector<std::thread> threads;
        std::vector<std::string> errors(kOpeners);
        std::vector<uint64_t>    instance_ids(kOpeners, 0);
        std::atomic<int>         primed { 0 };
        for (int index = 0; index < kOpeners; ++index) {
            threads.emplace_back([&, index]() {
                auto image  = MakeInlinePayloadImage("packaged-race.mp4", payload);
                auto source = CreateVideoTextureSource(image, &errors[index]);
                if (source == nullptr) return;
                if (!source->prime(&errors[index])) return;
                if (!source->currentFrame().valid()) return;
                instance_ids[index] = source->sourceStats().instance_id;
                primed.fetch_add(1);
            });
        }
        for (auto& thread : threads) thread.join();

        EXPECT_EQ(primed.load(), kOpeners) << errors[0] << "|" << errors[1] << "|" << errors[2] << "|" << errors[3];
        const std::set<uint64_t> distinct(instance_ids.begin(), instance_ids.end());
        EXPECT_EQ(distinct.size(), static_cast<size_t>(kOpeners));
        EXPECT_EQ(TemporaryEntries(), temp_before);
    }
}

TEST_F(NativePayloads, ReleasingThePayloadBufferKeepsAnOpenSourcePlaying) {
    const auto media = project_dir / "released.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "released-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());

    for (const bool moved_out : { false, true }) {
        SCOPED_TRACE(moved_out ? "moved to an anonymous file" : "kept in memory");
        setenv("WALLPAPER_MACHINE_VIDEO_SPILL_BYTES", moved_out ? "0" : "1099511627776", 1);
        auto                 image   = MakeInlinePayloadImage("released.mp4", payload);
        std::weak_ptr<Image> watcher = image;
        std::string          error;
        auto                 source = CreateVideoTextureSource(image, &error);
        ASSERT_NE(source, nullptr) << error;
        // A source a graph rebuild holds is opened later, with the scene's image long gone.
        image.reset();
        EXPECT_FALSE(watcher.expired()) << "the source dropped bytes it has not read yet";
        ASSERT_TRUE(source->prime(&error)) << error;
        EXPECT_TRUE(source->currentFrame().valid());
        // A payload that moved into a file no longer needs the buffer, and a source that
        // kept it would hold a second copy of the video for as long as it plays.
        EXPECT_EQ(watcher.expired(), moved_out);

        // The payload still plays on: forward, and back across a seek.
        VideoPlaybackState state;
        for (const double seconds : { 0.5, 1.5, 0.2 }) {
            state.scene_elapsed_seconds = seconds;
            error.clear();
            ASSERT_TRUE(source->syncPlayback(state, &error)) << error;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            error.clear();
            EXPECT_TRUE(source->refreshFrame(&error)) << error;
            EXPECT_TRUE(source->currentFrame().valid());
        }
    }
}

TEST_F(NativePayloads, AStreamThatBreaksPartWayStopsPlayingAndKeepsItsLastPicture) {
    const auto media = project_dir / "broken.mp4";
    ASSERT_TRUE(testing_media::WriteLongGopVideo(media, "broken-" + std::to_string(::getpid())));
    auto bytes = ReadWholeFile(media);
    ASSERT_FALSE(bytes.empty());

    // Overwrite the compressed data of every sample from the tenth on with noise.
    {
        wm::Error error;
        auto source = wm::OpenFileByteSource(media.string(), &error);
        ASSERT_NE(source, nullptr) << wm::Describe(error);
        auto reader = wm::IsoBmffReader::Open(source, &error);
        ASSERT_NE(reader, nullptr) << wm::Describe(error);
        ASSERT_GT(reader->samples().size(), 200u);
        uint32_t state = 7;
        for (size_t index = 10; index < reader->samples().size(); ++index) {
            const auto& sample = reader->samples()[index];
            for (uint32_t offset = 0; offset < sample.size; ++offset) {
                state = state * 1664525u + 1013904223u;
                bytes[sample.offset + offset] = static_cast<char>(state >> 24);
            }
        }
    }
    auto        image = MakeInlinePayloadImage("broken.mp4", bytes);
    std::string error;
    auto        source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    ASSERT_TRUE(source->currentFrame().valid());

    // The decoder gives up on a stream that keeps failing, and says so.
    bool        stopped = false;
    std::string reason;
    VideoPlaybackState state;
    for (int step = 0; step < 400 && !stopped; ++step) {
        state.scene_elapsed_seconds = 0.05 * step;
        std::string step_error;
        if (!source->syncPlayback(state, &step_error)) {
            stopped = true;
            reason  = step_error;
        } else {
            // Frames are taken as the clock reaches them, which is what lets the decoder run on.
            std::string refresh_error;
            source->refreshFrame(&refresh_error);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    EXPECT_TRUE(stopped) << "a stream of undecodable samples played on forever";
    EXPECT_FALSE(reason.empty());
    // The picture on screen stays.
    EXPECT_TRUE(source->currentFrame().valid());
}

TEST_F(NativePayloads, AFragmentedMp4IsRefusedWithItsReason) {
    // A movie fragment box after the movie's own tables is what a reader of
    // progressive files has to refuse. Nothing else plays it: the reason says so,
    // and the source holds nothing.
    const auto media = project_dir / "fragmented.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "fragmented"));
    auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    const unsigned char moof[] = { 0, 0, 0, 24, 'm', 'o', 'o', 'f', 0, 0, 0, 16, 'm', 'f', 'h', 'd',
                                   0, 0, 0, 0, 0, 0, 0, 1 };
    payload.insert(payload.end(), reinterpret_cast<const char*>(moof), reinterpret_cast<const char*>(moof) + sizeof(moof));
    {
        // The fixture has to be what the case says it is.
        wm::Error error;
        auto      source = wm::MakeMemoryByteSource(std::vector<std::uint8_t>(payload.begin(), payload.end()));
        EXPECT_EQ(wm::IsoBmffReader::Open(source, &error), nullptr);
        ASSERT_EQ(error.kind, wm::ErrorKind::Unsupported) << wm::Describe(error);
    }

    std::string error;
    const auto  decoders_before = OpenVideoDecoderCount();
    auto        image           = MakeInlinePayloadImage("fragmented.mp4", payload);
    auto        source          = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    EXPECT_FALSE(source->prime(&error));
    EXPECT_NE(error.find("fragmented"), std::string::npos) << error;
    EXPECT_EQ(OpenVideoDecoderCount(), decoders_before);
    EXPECT_FALSE(source->currentFrame().valid());
}

TEST_F(NativePayloads, AContainerTheReadersDoNotKnowIsRefusedByName) {
    // An AVI file: a container the project's readers do not read and nothing else
    // here does either. The reason says the format is not supported, so the
    // failure is clear, and no file is staged for another demuxer.
    std::vector<char> payload(4096, 0);
    const char        riff[] = { 'R', 'I', 'F', 'F', 0, 0x10, 0, 0, 'A', 'V', 'I', ' ', 'L', 'I', 'S', 'T' };
    std::copy(std::begin(riff), std::end(riff), payload.begin());
    const auto cache_before = VideoCacheEntries();

    std::string error;
    auto        image  = MakeInlinePayloadImage("movie.avi", payload);
    auto        source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    EXPECT_FALSE(source->prime(&error));
    EXPECT_NE(error.find("format not supported"), std::string::npos) << error;
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
    EXPECT_TRUE(TemporaryEntries().empty());
}

/// A video image whose payload is `bytes`, as the texture parser hands over an embedded WebM or Matroska file.
std::shared_ptr<Image> MakeEmbeddedClipImage(const std::string& key, const unsigned char* bytes, std::size_t size) {
    const std::vector<char> payload(reinterpret_cast<const char*>(bytes), reinterpret_cast<const char*>(bytes) + size);
    auto image = MakeInlinePayloadImage(key, payload);
    image->header.width  = testing_media::kVp9WebmWidth;
    image->header.height = testing_media::kVp9WebmHeight;
    return image;
}

TEST_F(NativePayloads, AWebmPayloadPlaysAndLoops) {
    auto        image = MakeEmbeddedClipImage("clip.webm", testing_media::kVp9Webm, sizeof(testing_media::kVp9Webm));
    std::string error;
    auto        source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_NEAR(source->durationSeconds(), 1.0, 0.05);
    const auto frame = source->currentFrame();
    ASSERT_TRUE(frame.valid());
    EXPECT_EQ(frame.width, static_cast<uint32_t>(testing_media::kVp9WebmWidth));
    EXPECT_EQ(frame.height, static_cast<uint32_t>(testing_media::kVp9WebmHeight));
    // The clip is a second long: run the clock a pass and a half and it comes round once.
    double last_pts = frame.pts_seconds;
    const auto begin = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() - begin < std::chrono::milliseconds(1700) && source->loopCount() < 1) {
        const double clock = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, clock }, &error)) << error;
        ASSERT_TRUE(source->refreshFrame(&error)) << error;
        EXPECT_GE(source->currentFrame().pts_seconds + 1e-9, last_pts);
        last_pts = source->currentFrame().pts_seconds;
        std::this_thread::sleep_for(std::chrono::milliseconds(3));
    }
    EXPECT_GE(source->loopCount(), 1u);
}

TEST_F(NativePayloads, AMatroskaPayloadWithBFramesPlaysInDisplayOrder) {
    auto        image = MakeEmbeddedClipImage("clip.mkv", testing_media::kH264Matroska, sizeof(testing_media::kH264Matroska));
    std::string error;
    auto        source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_NEAR(source->durationSeconds(), 1.2, 0.05);
    // Step the clock a frame at a time: every shown time must follow the clock, in order.
    double last_pts = -1.0;
    for (int frame = 0; frame < testing_media::kH264MatroskaFrames; ++frame) {
        const double clock = frame / 30.0;
        ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, clock }, &error)) << error;
        // The decoder runs on its own thread; give the frame for this time a moment to arrive.
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        do {
            ASSERT_TRUE(source->refreshFrame(&error)) << error;
            if (std::abs(source->currentFrame().pts_seconds - clock) < 0.034) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        } while (std::chrono::steady_clock::now() < deadline);
        const double pts = source->currentFrame().pts_seconds;
        EXPECT_NEAR(pts, clock, 0.034) << "frame " << frame;
        EXPECT_GE(pts + 1e-9, last_pts) << "frame " << frame << " came out of display order";
        last_pts = pts;
    }
}

TEST_F(NativePayloads, ACodecThisMacCannotDecodeIsRefusedByName) {
    // A Matroska file whose video is VP8: the reader says so, and nothing plays it.
    // Built from the VP9 clip by changing the codec id in place ("V_VP9" -> "V_VP8").
    std::vector<unsigned char> clip(testing_media::kVp9Webm, testing_media::kVp9Webm + sizeof(testing_media::kVp9Webm));
    const unsigned char        id[] = { 'V', '_', 'V', 'P', '9' };
    const auto                 at   = std::search(clip.begin(), clip.end(), std::begin(id), std::end(id));
    ASSERT_NE(at, clip.end());
    *(at + 4) = '8';
    auto        image = MakeEmbeddedClipImage("vp8.webm", clip.data(), clip.size());
    std::string error;
    auto        source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    EXPECT_FALSE(source->prime(&error));
    EXPECT_NE(error.find("format not supported"), std::string::npos) << error;
    EXPECT_NE(error.find("VP8"), std::string::npos) << error;
}

TEST_F(NativePayloads, AClipReportsItsOwnLengthFrameRateAndPictureSize) {
    const auto media = project_dir / "numbers.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 3, "numbers"));
    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "numbers.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    // Play on until the pacing estimator has seen enough frames.
    VideoPlaybackState state;
    for (int step = 0; step < 100 && source->sourceStats().observed_samples < 12; ++step) {
        state.scene_elapsed_seconds = step / 30.0;
        ASSERT_TRUE(source->syncPlayback(state, &error)) << error;
        ASSERT_TRUE(source->refreshFrame(&error)) << error;
        std::this_thread::sleep_for(std::chrono::milliseconds(15));
    }
    // The clip is three seconds at thirty frames a second, 640x360.
    EXPECT_NEAR(source->durationSeconds(), 3.0, 0.05);
    EXPECT_NEAR(source->sourceStats().observed_period_seconds, 1.0 / 30.0, 1e-3);
    EXPECT_EQ(source->currentFrame().displayWidth(), kFrameWidth);
    EXPECT_EQ(source->currentFrame().displayHeight(), kFrameHeight);
}

// What a scene gets for an embedded payload: it is played where it lies.
TEST_F(VideoSourceInputBase, AnEmbeddedPayloadIsPlayedWithoutStagingAFile) {
    const auto media = project_dir / "default.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "default-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    const auto cache_before = VideoCacheEntries();

    auto        image = MakeInlinePayloadImage("default.mp4", payload);
    std::string error;
    auto        source = CreateVideoTextureSource(image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_TRUE(source->currentFrame().valid());
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty()) << "the decoder staged the payload in a file";

    // A WebM payload is played by the same decoder.
    auto webm = MakeEmbeddedClipImage("default.webm", testing_media::kVp9Webm, sizeof(testing_media::kVp9Webm));
    auto webm_source = CreateVideoTextureSource(webm, &error);
    ASSERT_NE(webm_source, nullptr) << error;
    ASSERT_TRUE(webm_source->prime(&error)) << error;
    EXPECT_TRUE(webm_source->currentFrame().valid());
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

// A clip that runs on past its end starts over, in the clip's own time and in
// the count of passes. The seam is where one pass ends and the next begins, and
// what time the first frame of the next one has.
TEST_F(VideoSourceClock, TheClockRunningPastTheEndStartsTheClipOverAndCountsThePass) {
    auto source = Open("seam.mp4", 3);
    ASSERT_NE(source, nullptr);
    std::string error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_NEAR(source->durationSeconds(), 3.0, 0.05);
    EXPECT_EQ(source->loopCount(), 0u);

    // Run the clock across the seam in real time, from a second before it.
    EXPECT_TRUE(FollowsTheClock(*source, 2.0, 0.15, std::chrono::seconds(2)))
        << "the frame on offer stayed at " << source->currentFrame().pts_seconds;
    double last_pts = source->currentFrame().pts_seconds;
    const auto begin = std::chrono::steady_clock::now();
    bool crossed = false;
    while (std::chrono::steady_clock::now() - begin < std::chrono::milliseconds(2500)) {
        const double clock = 2.0 + std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, clock }, &error)) << error;
        ASSERT_TRUE(source->refreshFrame(&error)) << error;
        const double pts = source->currentFrame().pts_seconds;
        // Absolute times only ever move on: across the seam they carry on from the pass before.
        EXPECT_GE(pts + 1e-9, last_pts) << "the frame time went backwards at clock " << clock;
        last_pts = pts;
        if (source->loopCount() >= 1) crossed = true;
        if (crossed && clock > 3.6) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    EXPECT_TRUE(crossed);
    EXPECT_GE(source->loopCount(), 1u);
    // The clip's own time is the wrapped one.
    EXPECT_LT(source->playbackSeconds(), 1.5);
    EXPECT_GT(last_pts, 3.0);
}

} // namespace
} // namespace wallpaper::video
