// A scene's video reaches the decoder without a whole-file copy in memory. Where the clip comes
// from decides how it is handed over:
//
//   * a loose file on the host disk, or on a physical mount of the file space, is probed and
//     played where it lies: nothing is read through the mount and no cache file is made;
//   * a loose file inside a `.pkg` is streamed in bounded pieces into a content-named file of
//     the temp directory, once, and that path is what the decoder opens;
//   * a clip packed into a `.tex` keeps its bytes in the texture's first level.
//
// Every shape must give the metadata, the duration and the first picture that decoding the media
// file itself gives, and a clip that is truncated, garbage or empty must fail in every shape.
//
// Media is encoded by this project's synthetic encoder (Renderer/Testing). The temp directory is
// a private folder for the length of each test, so the cache files a shape makes can be counted.
#include "Fs/CBinaryStream.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Image.hpp"
#include "Media/ByteSource.hpp"
#include "Scene/WPPkgFs.hpp"
#include "Utils/Sha.hpp"
#include "Video/VideoContainerProbe.hpp"
#include "Video/VideoTextureSource.hpp"
#include "WPTexImageParser.hpp"
#include "synthetic_video.hpp"

#import <CoreVideo/CoreVideo.h>

#include <gtest/gtest.h>
#include <lz4.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <cstring>
#include <map>
#include <mutex>
#include <span>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <mach-o/dyld.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace wallpaper;
namespace disk  = std::filesystem;
namespace synth = wallpaper::video::testing_media;

namespace
{

constexpr std::size_t kMiB = std::size_t { 1 } << 20;

// ---- a private temp directory -------------------------------------------------------------

class ScopedTemp {
public:
    ScopedTemp()
    {
        static std::atomic<int> serial { 0 };
        root_ = disk::canonical(disk::temp_directory_path()) /
                ("wm-video-input-" + std::to_string(::getpid()) + "-" + std::to_string(serial.fetch_add(1)));
        disk::create_directories(root_ / "tmp");
        disk::create_directories(root_ / "work");
        if (const char* held = std::getenv("TMPDIR")) {
            had_      = true;
            previous_ = held;
        }
        ::setenv("TMPDIR", (root_ / "tmp").c_str(), 1);
    }
    ~ScopedTemp()
    {
        if (had_) {
            ::setenv("TMPDIR", previous_.c_str(), 1);
        } else {
            ::unsetenv("TMPDIR");
        }
        std::error_code ignored;
        disk::remove_all(root_, ignored);
    }
    ScopedTemp(const ScopedTemp&)            = delete;
    ScopedTemp& operator=(const ScopedTemp&) = delete;

    /// Where the code under test makes its files (the process temp directory).
    [[nodiscard]] disk::path TempDir() const { return root_ / "tmp"; }
    /// Where the test keeps its own fixtures.
    [[nodiscard]] disk::path Work() const { return root_ / "work"; }

    [[nodiscard]] std::vector<disk::path> TempEntries() const
    {
        std::vector<disk::path> found;
        for (const auto& entry : disk::directory_iterator(TempDir())) found.push_back(entry.path());
        return found;
    }

private:
    disk::path  root_;
    std::string previous_;
    bool        had_ { false };
};

std::string ReadAll(const disk::path& path)
{
    std::ifstream in(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

void WriteAll(const disk::path& path, const std::string& bytes)
{
    disk::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary);
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

std::string Sha1Of(const std::string& bytes)
{
    return utils::genSha1(std::span<const char>(bytes.data(), bytes.size()));
}

// ---- the clip ----------------------------------------------------------------------------

/// An encoded clip of at least `min_bytes`, made once per size for the whole run.
const std::string& ClipBytes(std::size_t min_bytes = 0)
{
    static std::map<std::size_t, std::string> made;
    auto found = made.find(min_bytes);
    if (found != made.end()) return found->second;
    ScopedTemp scratch;
    const auto path = scratch.Work() / "clip.mp4";
    for (int repeats = 1; repeats <= 4096; repeats *= 2) {
        if (!synth::WriteSyntheticVideo(path, repeats, "scene-video-input-" + std::to_string(min_bytes))) break;
        if (disk::file_size(path) >= min_bytes) break;
    }
    return made.emplace(min_bytes, disk::exists(path) ? ReadAll(path) : std::string()).first->second;
}

/// What decoding the media file itself gives.
struct Reference {
    uint32_t width { 0 };
    uint32_t height { 0 };
    double   duration { 0.0 };
    uint64_t first_picture { 0 };
};

uint64_t HashLuma(void* pixel_buffer)
{
    CVPixelBufferRef buffer = static_cast<CVPixelBufferRef>(pixel_buffer);
    if (buffer == nullptr) return 0;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    uint64_t hash = 1469598103934665603ull;
    if (CVPixelBufferIsPlanar(buffer)) {
        const auto* base   = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
        const auto  stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        const auto  width  = CVPixelBufferGetWidthOfPlane(buffer, 0);
        const auto  height = CVPixelBufferGetHeightOfPlane(buffer, 0);
        for (std::size_t y = 0; y < height; ++y) {
            for (std::size_t x = 0; x < width; ++x) {
                hash ^= base[y * stride + x];
                hash *= 1099511628211ull;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return hash;
}

/// The first picture a source plays, as a hash of its luma plane; 0 when there is none.
uint64_t FirstPicture(const std::shared_ptr<video::VideoTextureSource>& source)
{
    std::string error;
    if (source == nullptr || !source->prime(&error)) return 0;
    video::VideoPlaybackState state;
    state.paused = true;
    if (!source->syncPlayback(state, &error) || !source->refreshFrame(&error)) return 0;
    const auto frame = source->currentFrame();
    return frame.valid() ? HashLuma(frame.pixel_buffer) : 0;
}

Reference DecodeFileItself(const disk::path& file)
{
    Reference    reference;
    wallpaper::media::Error error;
    auto         source = wallpaper::media::OpenFileByteSource(file.string(), &error);
    if (source == nullptr) return reference;
    if (const auto meta = video::ProbeVideoMetadataFromSource(source)) {
        reference.width    = static_cast<uint32_t>(meta->width);
        reference.height   = static_cast<uint32_t>(meta->height);
        reference.duration = meta->duration_seconds;
    }
    std::string failure;
    reference.first_picture = FirstPicture(video::CreateVideoTextureSourceForFile(file.string(), &failure));
    return reference;
}

/// What the image handed to the decoder gives.
Reference DecodeImage(const std::shared_ptr<Image>& image)
{
    Reference reference;
    if (image == nullptr) return reference;
    reference.width    = static_cast<uint32_t>(image->header.width);
    reference.height   = static_cast<uint32_t>(image->header.height);
    reference.duration = image->header.durationSeconds;
    std::string failure;
    reference.first_picture = FirstPicture(video::CreateVideoTextureSource(image, &failure));
    return reference;
}

void ExpectSameAsTheFile(const Reference& got, const Reference& file)
{
    ASSERT_GT(file.width, 0u) << "the reference clip must decode";
    ASSERT_NE(file.first_picture, 0u);
    EXPECT_EQ(got.width, file.width);
    EXPECT_EQ(got.height, file.height);
    EXPECT_DOUBLE_EQ(got.duration, file.duration);
    EXPECT_EQ(got.first_picture, file.first_picture) << "the first picture is the one the file decodes to";
}

// ---- a counting file system --------------------------------------------------------------

struct Counters {
    std::atomic<uint64_t> opens { 0 };
    std::atomic<uint64_t> reads { 0 };
    std::atomic<uint64_t> bytes { 0 };
    std::atomic<uint64_t> largest_read { 0 };
    void                  Reset() { opens = reads = bytes = largest_read = 0; }
};

class CountingStream final : public fs::IBinaryStream {
public:
    CountingStream(std::shared_ptr<fs::IBinaryStream> inner, Counters& counters)
        : inner_(std::move(inner)), counters_(counters) {}
    usize Read(void* buffer, usize size) override
    {
        const usize got = inner_->Read(buffer, size);
        counters_.reads.fetch_add(1);
        counters_.bytes.fetch_add(got);
        uint64_t seen = counters_.largest_read.load();
        while (size > seen && !counters_.largest_read.compare_exchange_weak(seen, size)) {}
        return got;
    }
    char*  Gets(char* buffer, usize size) override { return inner_->Gets(buffer, size); }
    idx    Tell() const override { return inner_->Tell(); }
    bool   SeekSet(idx offset) override { return inner_->SeekSet(offset); }
    bool   SeekCur(idx offset) override { return inner_->SeekCur(offset); }
    bool   SeekEnd(idx offset) override { return inner_->SeekEnd(offset); }
    isize  Size() const override { return inner_->Size(); }

protected:
    usize Write_impl(const void*, usize) override { return 0; }

private:
    std::shared_ptr<fs::IBinaryStream> inner_;
    Counters&                          counters_;
};

/// A folder mount that counts what is opened and read through it.
class CountingPhysicalFs final : public fs::PhysicalFs {
public:
    CountingPhysicalFs(const std::string& folder, Counters& counters) : PhysicalFs(folder), counters_(counters) {}
    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override
    {
        auto inner = PhysicalFs::Open(path);
        if (inner == nullptr) return nullptr;
        counters_.opens.fetch_add(1);
        return std::make_shared<CountingStream>(std::move(inner), counters_);
    }

private:
    Counters& counters_;
};

/// A package mount that counts what is opened and read through it. It is not a physical mount:
/// the files in it have no path of their own.
class CountingPkgFs final : public fs::Fs {
public:
    CountingPkgFs(std::unique_ptr<fs::WPPkgFs> inner, Counters& counters)
        : inner_(std::move(inner)), counters_(counters) {}
    bool Contains(std::string_view path) const override { return inner_->Contains(path); }
    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override
    {
        auto inner = inner_->Open(path);
        if (inner == nullptr) return nullptr;
        counters_.opens.fetch_add(1);
        return std::make_shared<CountingStream>(std::move(inner), counters_);
    }
    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::unique_ptr<fs::WPPkgFs> inner_;
    Counters&                    counters_;
};

// ---- a package file ----------------------------------------------------------------------

std::string MakePkg(const std::vector<std::pair<std::string, std::string>>& files)
{
    std::string out;
    const auto  put32 = [&out](uint32_t value) { out.append(reinterpret_cast<const char*>(&value), 4); };
    const std::string version = "PKGV0001";
    put32(static_cast<uint32_t>(version.size()));
    out += version;
    put32(static_cast<uint32_t>(files.size()));
    uint32_t offset = 0;
    for (const auto& [name, bytes] : files) {
        put32(static_cast<uint32_t>(name.size()));
        out += name;
        put32(offset);
        put32(static_cast<uint32_t>(bytes.size()));
        offset += static_cast<uint32_t>(bytes.size());
    }
    for (const auto& file : files) out += file.second;
    return out;
}

/// A `.tex` holding `payload` as a video, stored plain or lz4 compressed.
std::string MakeVideoTex(const std::string& payload, uint32_t width, uint32_t height, bool compress)
{
    std::string out;
    const auto  put32 = [&out](uint32_t value) { out.append(reinterpret_cast<const char*>(&value), 4); };
    out.append("TEXV0005\0", 9);
    out.append("TEXI0001\0", 9);
    put32(0);          // RGBA8
    put32(1u << 5);    // a video
    put32(width);
    put32(height);
    put32(width);
    put32(height);
    put32(0xff000000u);
    out.append("TEXB0003\0", 9);
    put32(1);          // one picture
    put32(0xffffffffu); // no declared picture type
    put32(1);          // one level
    put32(width);
    put32(height);
    if (compress) {
        std::string packed(static_cast<std::size_t>(LZ4_compressBound(static_cast<int>(payload.size()))), '\0');
        const int   size = LZ4_compress_default(payload.data(), packed.data(), static_cast<int>(payload.size()),
                                                static_cast<int>(packed.size()));
        packed.resize(static_cast<std::size_t>(size));
        put32(1);
        put32(static_cast<uint32_t>(payload.size()));
        put32(static_cast<uint32_t>(packed.size()));
        out += packed;
    } else {
        put32(0);
        put32(static_cast<uint32_t>(payload.size()));
        put32(static_cast<uint32_t>(payload.size()));
        out += payload;
    }
    return out;
}

std::string Garbage(std::size_t size)
{
    std::string bytes(size, '\0');
    uint32_t    state = 12345;
    for (auto& byte : bytes) {
        state = state * 1664525u + 1013904223u;
        byte  = static_cast<char>(state >> 24);
    }
    return bytes;
}

class VideoInput : public ::testing::Test {
protected:
    void SetUp() override
    {
        if (!synth::EncoderAvailable()) GTEST_SKIP() << "no H.264 encoder on this machine";
    }
};

/// Mounts `fs` as the project's files, the way the host mounts a scene source.
void MountAssets(fs::VFS& vfs, std::unique_ptr<fs::Fs> files)
{
    ASSERT_TRUE(vfs.Mount("/assets", std::move(files)));
}

} // namespace

// ---- SHA-1 in pieces -----------------------------------------------------------------------

TEST(Sha1Stream, GivesTheDigestsOfTheOneShotFunctionHoweverTheInputIsCut)
{
    const std::string input = Garbage(300000);
    for (const std::size_t cut : { std::size_t { 1 }, std::size_t { 63 }, std::size_t { 64 }, std::size_t { 65 },
                                   std::size_t { 4096 }, std::size_t { 65535 }, std::size_t { 65536 },
                                   std::size_t { 65537 }, std::size_t { 131072 }, std::size_t { 299999 } }) {
        utils::Sha1Stream stream;
        for (std::size_t at = 0; at < input.size(); at += cut) {
            stream.Update(std::span<const char>(input.data() + at, std::min(cut, input.size() - at)));
        }
        EXPECT_EQ(stream.Finish(), Sha1Of(input)) << "pieces of " << cut;
    }
}

TEST(Sha1Stream, KnownAnswers)
{
    const auto digest = [](const std::string& text) {
        utils::Sha1Stream stream;
        stream.Update(std::span<const char>(text.data(), text.size()));
        return stream.Finish();
    };
    EXPECT_EQ(digest(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    EXPECT_EQ(digest("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
    EXPECT_EQ(digest("The quick brown fox jumps over the lazy dog"), "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12");
    EXPECT_EQ(digest(std::string(1000000, 'a')), "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
}

// ---- a loose clip on the host disk --------------------------------------------------------

TEST_F(VideoInput, ALooseClipOnTheHostDiskIsProbedAndOpenedWhereItLies)
{
    ScopedTemp scratch;
    const auto file = scratch.Work() / "host.mp4";
    WriteAll(file, ClipBytes());
    const Reference direct = DecodeFileItself(file);

    fs::VFS          vfs;
    WPTexImageParser parser(&vfs);
    const auto       image = parser.Parse(file.string());
    ASSERT_NE(image, nullptr);
    EXPECT_TRUE(image->header.isVideo);
    EXPECT_EQ(image->videoFilePath, file.string()) << "the decoder opens the file where it lies";
    EXPECT_TRUE(image->slots.empty()) << "no copy of the file travels with the image";
    ExpectSameAsTheFile(DecodeImage(image), direct);
    EXPECT_TRUE(scratch.TempEntries().empty()) << "no cache file for a file that can be opened in place";

    const auto header = parser.ParseHeader(file.string());
    EXPECT_TRUE(header.isVideo);
    EXPECT_EQ(static_cast<uint32_t>(header.width), direct.width);
    EXPECT_DOUBLE_EQ(header.durationSeconds, direct.duration);
}

// ---- a loose clip on a physical mount -----------------------------------------------------

TEST_F(VideoInput, ALooseClipOnAPhysicalMountIsPlayedFromItsFileAndNothingIsReadThroughTheMount)
{
    ScopedTemp scratch;
    const auto folder = scratch.Work() / "project";
    WriteAll(folder / "materials" / "clip.mp4", ClipBytes());
    const Reference direct = DecodeFileItself(folder / "materials" / "clip.mp4");

    Counters counters;
    fs::VFS  vfs;
    MountAssets(vfs, std::make_unique<CountingPhysicalFs>(folder.string(), counters));
    WPTexImageParser parser(&vfs);

    const auto image = parser.Parse("clip");
    ASSERT_NE(image, nullptr);
    EXPECT_TRUE(image->header.isVideo);
    EXPECT_EQ(image->videoFilePath, (folder / "materials" / "clip.mp4").string());
    EXPECT_TRUE(image->slots.empty());
    ExpectSameAsTheFile(DecodeImage(image), direct);

    const auto header = parser.ParseHeader("clip");
    EXPECT_EQ(static_cast<uint32_t>(header.width), direct.width);
    EXPECT_DOUBLE_EQ(header.durationSeconds, direct.duration);

    EXPECT_EQ(counters.opens.load(), 0u) << "the mount is not asked to open the clip";
    EXPECT_EQ(counters.bytes.load(), 0u) << "nothing is read through the mount";
    EXPECT_TRUE(scratch.TempEntries().empty()) << "and no cache entry is made";
}

// ---- a loose clip inside a package --------------------------------------------------------

namespace
{

struct PackedClip {
    ScopedTemp  scratch;
    Counters    counters;
    fs::VFS     vfs;
    std::string bytes;

    explicit PackedClip(const std::string& payload, const std::string& entry = "materials/clip.mp4")
        : bytes(payload)
    {
        const auto pkg = scratch.Work() / "scene.pkg";
        WriteAll(pkg, MakePkg({ { entry, payload } }));
        auto mounted = fs::WPPkgFs::CreatePkgFs(pkg.string());
        if (mounted != nullptr) {
            vfs.Mount("/assets", std::make_unique<CountingPkgFs>(std::move(mounted), counters));
        }
    }

    [[nodiscard]] std::vector<disk::path> CacheFiles() const { return scratch.TempEntries(); }
};

} // namespace

TEST_F(VideoInput, ALooseClipInAPackageIsStreamedInBoundedPiecesToOneContentNamedFile)
{
    // Several megabytes, so that "bounded pieces" means something.
    const std::string& clip = ClipBytes(3 * kMiB);
    ASSERT_GT(clip.size(), 2 * kMiB);
    PackedClip packed(clip);
    const auto reference_file = packed.scratch.Work() / "reference.mp4";
    WriteAll(reference_file, clip);
    const Reference direct = DecodeFileItself(reference_file);

    WPTexImageParser parser(&packed.vfs);
    const auto       image = parser.Parse("clip");
    ASSERT_NE(image, nullptr);
    EXPECT_TRUE(image->header.isVideo);
    EXPECT_TRUE(image->slots.empty()) << "the image carries a path, not the bytes";

    const auto entries = packed.CacheFiles();
    ASSERT_EQ(entries.size(), 1u) << "exactly one cache file";
    EXPECT_NE(entries[0].filename().string().find(Sha1Of(clip)), std::string::npos)
        << "named by the content hash: " << entries[0].filename();
    EXPECT_EQ(image->videoFilePath, entries[0].string());
    EXPECT_EQ(ReadAll(entries[0]), clip) << "the cache file is the clip, byte for byte";
    EXPECT_LE(packed.counters.largest_read.load(), kMiB) << "no read through the mount is larger than 1 MiB";
    EXPECT_GE(packed.counters.bytes.load(), clip.size()) << "the clip was read through the mount";
    ExpectSameAsTheFile(DecodeImage(image), direct);

    // A second open reuses the entry: no new file, and the one there is not replaced.
    struct stat before {};
    ASSERT_EQ(::stat(entries[0].c_str(), &before), 0);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    WPTexImageParser again(&packed.vfs);
    const auto       second = again.Parse("clip");
    ASSERT_NE(second, nullptr);
    EXPECT_EQ(second->videoFilePath, image->videoFilePath);
    ASSERT_EQ(packed.CacheFiles().size(), 1u);
    struct stat after {};
    ASSERT_EQ(::stat(entries[0].c_str(), &after), 0);
    EXPECT_EQ(before.st_ino, after.st_ino) << "an existing valid entry is never replaced";
    EXPECT_EQ(before.st_mtime, after.st_mtime);
    EXPECT_EQ(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec);
}

TEST_F(VideoInput, ConcurrentOpenersNeverSeeAPartialCacheFile)
{
    const std::string& clip = ClipBytes(6 * kMiB);
    PackedClip         packed(clip);
    const std::string  digest = Sha1Of(clip);

    std::atomic<bool> done { false };
    std::atomic<int>  partial { 0 };
    std::atomic<int>  sightings { 0 };
    std::thread       watcher([&] {
        while (!done.load()) {
            std::error_code failure;
            for (const auto& entry : disk::directory_iterator(packed.scratch.TempDir(), failure)) {
                const std::string name = entry.path().filename().string();
                // A published entry carries the content's name and the clip's own extension.
                if (name.find(digest) == std::string::npos || entry.path().extension() != ".mp4") continue;
                std::error_code size_failure;
                const auto      size = disk::file_size(entry.path(), size_failure);
                if (size_failure) continue;
                ++sightings;
                if (size != clip.size()) ++partial;
            }
        }
    });

    constexpr int kOpeners = 6;
    std::vector<std::thread> openers;
    std::vector<std::string> paths(kOpeners);
    for (int index = 0; index < kOpeners; ++index) {
        openers.emplace_back([&, index] {
            // Each opener has a file space of its own over the same package.
            fs::VFS    vfs;
            Counters   counters;
            auto       mounted = fs::WPPkgFs::CreatePkgFs((packed.scratch.Work() / "scene.pkg").string());
            vfs.Mount("/assets", std::make_unique<CountingPkgFs>(std::move(mounted), counters));
            WPTexImageParser parser(&vfs);
            if (const auto image = parser.Parse("clip")) paths[static_cast<std::size_t>(index)] = image->videoFilePath;
        });
    }
    for (auto& thread : openers) thread.join();
    done = true;
    watcher.join();

    EXPECT_EQ(partial.load(), 0) << "a file at the content's name is always whole";
    for (const auto& path : paths) {
        ASSERT_FALSE(path.empty());
        EXPECT_EQ(path, paths.front());
    }
    const auto entries = packed.CacheFiles();
    ASSERT_EQ(entries.size(), 1u) << "one entry, and no staging file left behind";
    EXPECT_EQ(ReadAll(entries[0]), clip);
}

// ---- a clip packed into a .tex ------------------------------------------------------------

TEST_F(VideoInput, AClipPackedIntoATexKeepsItsBytesInTheFirstLevel)
{
    const std::string& clip = ClipBytes();
    for (const bool compress : { false, true }) {
        ScopedTemp scratch;
        const auto reference_file = scratch.Work() / "reference.mp4";
        WriteAll(reference_file, clip);
        const Reference direct = DecodeFileItself(reference_file);

        const auto folder = scratch.Work() / "project";
        WriteAll(folder / "materials" / "packed.tex", MakeVideoTex(clip, direct.width, direct.height, compress));
        Counters counters;
        fs::VFS  vfs;
        MountAssets(vfs, std::make_unique<CountingPhysicalFs>(folder.string(), counters));
        WPTexImageParser parser(&vfs);

        const auto image = parser.Parse("packed");
        ASSERT_NE(image, nullptr) << (compress ? "lz4" : "plain");
        EXPECT_TRUE(image->header.isVideo);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        const auto& level = image->slots[0].mipmaps[0];
        ASSERT_EQ(static_cast<std::size_t>(level.size), clip.size());
        EXPECT_EQ(std::memcmp(level.data.get(), clip.data(), clip.size()), 0);
        EXPECT_TRUE(image->videoFilePath.empty());
        ExpectSameAsTheFile(DecodeImage(image), direct);
        EXPECT_TRUE(scratch.TempEntries().empty() || compress == false) << "reading it makes no cache file";

        // The header of a plain clip is read by streaming its byte range, not by reading all of it.
        counters.Reset();
        const auto header = parser.ParseHeader("packed");
        EXPECT_TRUE(header.isVideo);
        EXPECT_DOUBLE_EQ(header.durationSeconds, direct.duration);
        if (!compress) {
            EXPECT_LT(counters.bytes.load(), clip.size() + 4096) << "the range is probed in place";
            EXPECT_LE(counters.largest_read.load(), kMiB);
        }
    }
}

// ---- clips that cannot play ---------------------------------------------------------------

TEST_F(VideoInput, ATruncatedGarbageOrEmptyClipFailsInEveryShape)
{
    const std::string& clip      = ClipBytes();
    const std::string  truncated = clip.substr(0, clip.size() / 3);
    const std::string  garbage   = Garbage(200000);
    const std::string  empty;
    for (const auto& [label, bytes] : std::vector<std::pair<std::string, const std::string*>> {
             { "truncated", &truncated }, { "garbage", &garbage }, { "empty", &empty } }) {
        SCOPED_TRACE(label);
        // Host disk.
        {
            ScopedTemp scratch;
            const auto file = scratch.Work() / "bad.mp4";
            WriteAll(file, *bytes);
            fs::VFS          vfs;
            WPTexImageParser parser(&vfs);
            EXPECT_EQ(parser.Parse(file.string()), nullptr) << "host path";
            EXPECT_FALSE(parser.ParseHeader(file.string()).isVideo);
            EXPECT_TRUE(scratch.TempEntries().empty());
        }
        // Physical mount.
        {
            ScopedTemp scratch;
            const auto folder = scratch.Work() / "project";
            WriteAll(folder / "materials" / "bad.mp4", *bytes);
            Counters counters;
            fs::VFS  vfs;
            MountAssets(vfs, std::make_unique<CountingPhysicalFs>(folder.string(), counters));
            WPTexImageParser parser(&vfs);
            EXPECT_EQ(parser.Parse("bad"), nullptr) << "physical mount";
            EXPECT_FALSE(parser.ParseHeader("bad").isVideo);
            EXPECT_TRUE(scratch.TempEntries().empty());
        }
        // Package.
        {
            PackedClip packed(*bytes, "materials/bad.mp4");
            WPTexImageParser parser(&packed.vfs);
            EXPECT_EQ(parser.Parse("bad"), nullptr) << "package";
            EXPECT_FALSE(parser.ParseHeader("bad").isVideo);
            EXPECT_TRUE(packed.CacheFiles().empty()) << "a clip that cannot play leaves no cache entry";
        }
    }
    // Packed into a texture: the empty payload is not a level, the others are not clips.
    for (const std::string* bytes : { &truncated, &garbage }) {
        ScopedTemp scratch;
        const auto folder = scratch.Work() / "project";
        WriteAll(folder / "materials" / "bad.tex", MakeVideoTex(*bytes, 640, 360, false));
        Counters counters;
        fs::VFS  vfs;
        MountAssets(vfs, std::make_unique<CountingPhysicalFs>(folder.string(), counters));
        WPTexImageParser parser(&vfs);
        const auto       image = parser.Parse("bad");
        // The container itself is fine; the clip fails when it is opened.
        if (image != nullptr) {
            std::string failure;
            EXPECT_EQ(FirstPicture(video::CreateVideoTextureSource(image, &failure)), 0u);
        }
    }
}

// ---- measuring -----------------------------------------------------------------------------

// Not part of the routine run. `--gtest_also_run_disabled_tests --gtest_filter=*PeakGrowth*` makes a
// ~100 MB clip and a package around it, then runs the open in a process of its own (so the peak is
// that open's and not the fixture's) and prints how far that process's resident size peaked.
std::string ThisExecutable()
{
    char          path[4096] {};
    std::uint32_t size = sizeof(path);
    return _NSGetExecutablePath(path, &size) == 0 ? std::string(path) : std::string();
}

TEST_F(VideoInput, DISABLED_PeakGrowthWorkerOpensTheClipNamedByTheEnvironment)
{
    const char* pkg = std::getenv("WM_VIDEO_PEAK_PKG");
    if (pkg == nullptr) GTEST_SKIP() << "run by DISABLED_PeakResidentGrowth only";
    ScopedTemp scratch;
    Counters   counters;
    fs::VFS    vfs;
    auto       mounted = fs::WPPkgFs::CreatePkgFs(pkg);
    ASSERT_NE(mounted, nullptr);
    vfs.Mount("/assets", std::make_unique<CountingPkgFs>(std::move(mounted), counters));
    struct rusage before {};
    ::getrusage(RUSAGE_SELF, &before);
    WPTexImageParser parser(&vfs);
    const auto       image = parser.Parse("clip");
    ASSERT_NE(image, nullptr);
    struct rusage after {};
    ::getrusage(RUSAGE_SELF, &after);
    // ru_maxrss is in bytes on macOS.
    std::printf("PEAK_GROWTH_MIB %.1f\n",
                static_cast<double>(after.ru_maxrss - before.ru_maxrss) / static_cast<double>(kMiB));
}

TEST_F(VideoInput, DISABLED_PeakResidentGrowthOfOpeningAHundredMegabyteClipFromAPackage)
{
    ScopedTemp scratch;
    const auto pkg = scratch.Work() / "scene.pkg";
    std::size_t clip_bytes = 0;
    {
        const std::string& clip = ClipBytes(100 * kMiB);
        clip_bytes              = clip.size();
        WriteAll(pkg, MakePkg({ { "materials/clip.mp4", clip } }));
    }
    const std::string command = "WM_VIDEO_PEAK_PKG='" + pkg.string() + "' '" + ThisExecutable() +
                                "' --gtest_also_run_disabled_tests --gtest_filter='*PeakGrowthWorker*' 2>&1";
    std::string output;
    if (std::FILE* pipe = ::popen(command.c_str(), "r")) {
        char line[512];
        while (std::fgets(line, sizeof(line), pipe) != nullptr) output += line;
        ::pclose(pipe);
    }
    const auto at = output.find("PEAK_GROWTH_MIB");
    ASSERT_NE(at, std::string::npos) << output;
    std::printf("clip %.1f MiB; peak resident growth of the process that opened it from a package: %s",
                static_cast<double>(clip_bytes) / static_cast<double>(kMiB), output.c_str() + at + 16);
}
