// The Apple adapter of the container readers, on real VideoToolbox decoding of
// the synthetic clips: the format description built from a reader's output, the
// session wrapper's display-order delivery, seek epochs, draining, bounds,
// cancellation and the refusals for formats this Mac cannot decode.
//
// No GPU, window or desktop is involved: frames are read back from their pixel
// buffers on the CPU.

#include "Media/Apple/FormatDescription.hpp"
#include "Media/Apple/VtFrameDecoder.hpp"
#include "Media/ByteSource.hpp"
#include "Media/IsoBmff/IsoBmffReader.hpp"
#include "Media/Matroska/MatroskaReader.hpp"
#include "Media/SampleOrder.hpp"
#include "embedded_clips.hpp"
#include "synthetic_video.hpp"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#include <gtest/gtest.h>

#include <mach/mach.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace wallpaper::media::apple
{
namespace
{

namespace tm = wallpaper::video::testing_media;
namespace stdfs = std::filesystem;

class VtFrameDecoderTest : public ::testing::Test {
protected:
    void SetUp() override
    {
        ASSERT_TRUE(tm::EncoderAvailable())
            << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
        static std::atomic<uint64_t> serial { 0 };
        directory = stdfs::temp_directory_path() /
                    ("owe-vt-decoder-" + std::to_string(::getpid()) + "-" + std::to_string(serial.fetch_add(1)));
        stdfs::create_directories(directory);
    }
    void TearDown() override
    {
        std::error_code ec;
        stdfs::remove_all(directory, ec);
    }

    std::unique_ptr<IsoBmffReader> OpenReader(const stdfs::path& path)
    {
        Error error;
        auto  source = OpenFileByteSource(path.string(), &error);
        EXPECT_NE(source, nullptr) << Describe(error);
        if (source == nullptr) return nullptr;
        auto reader = IsoBmffReader::Open(source, &error);
        EXPECT_NE(reader, nullptr) << Describe(error);
        return reader;
    }

    /// A decoder for the reader's stream, or null with a test failure.
    std::unique_ptr<VtFrameDecoder> MakeDecoder(const IsoBmffReader& reader, DecoderOptions options = {})
    {
        std::vector<std::uint8_t> first;
        for (std::size_t index = 0; index < reader.samples().size(); ++index) {
            if (reader.samples()[index].sync) {
                Error error;
                EXPECT_TRUE(reader.readSample(index, &first, &error));
                break;
            }
        }
        StreamFormat format;
        std::string  why;
        EXPECT_TRUE(MakeStreamFormat(reader.info(), nullptr, first.data(), first.size(), &format, &why)) << why;
        if (! format.description) return nullptr;
        std::string error;
        auto        decoder = VtFrameDecoder::Create(std::move(format), reader.info().timescale,
                                                     ReorderDepth(reader.samples()), options, &error);
        EXPECT_NE(decoder, nullptr) << error;
        return decoder;
    }

    /// Feeds samples [first, last) and collects every frame that comes out, then
    /// drains when `drain` is set. Respects the decoder's bounds.
    std::vector<DecodedFrame> Run(const IsoBmffReader& reader, VtFrameDecoder& decoder, std::size_t first,
                                  std::size_t last, bool drain)
    {
        std::vector<DecodedFrame> frames;
        std::vector<std::uint8_t> bytes;
        std::string               error;
        std::size_t               next = first;
        const auto                deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
        while (std::chrono::steady_clock::now() < deadline) {
            while (next < last) {
                Error readError;
                EXPECT_TRUE(reader.readSample(next, &bytes, &readError)) << Describe(readError);
                const Sample& sample = reader.samples()[next];
                const auto    result = decoder.submit(bytes.data(), bytes.size(),
                                                      { sample.pts, sample.dts, sample.duration }, sample.sync, &error);
                if (result == VtFrameDecoder::SubmitResult::Failed) {
                    ADD_FAILURE() << error;
                    return frames;
                }
                if (result == VtFrameDecoder::SubmitResult::Full) break;
                ++next;
            }
            if (next >= last && drain && ! drained) {
                EXPECT_TRUE(decoder.drain(&error)) << error;
                drained = true;
            }
            DecodedFrame frame;
            const auto   received = decoder.receive(&frame, std::chrono::milliseconds(50), &error);
            if (received == VtFrameDecoder::ReceiveResult::Frame) {
                frames.push_back(std::move(frame));
            } else if (received == VtFrameDecoder::ReceiveResult::EndOfStream) {
                break;
            } else if (received == VtFrameDecoder::ReceiveResult::Failed) {
                ADD_FAILURE() << error;
                break;
            } else if (next >= last && ! drain) {
                break;
            }
        }
        drained = false;
        return frames;
    }

    /// Luma of pixel (x, y) of a decoded 8-bit biplanar frame.
    static std::uint8_t LumaAt(CVPixelBufferRef buffer, int x, int y)
    {
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        const auto* plane  = static_cast<const std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
        const auto  stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        const auto  value  = plane[static_cast<std::size_t>(y) * stride + static_cast<std::size_t>(x)];
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        return value;
    }

    /// Which of the first `candidates` frames of the fixture's noise `frame` looks most like.
    static int NoiseFrameOf(CVPixelBufferRef buffer, int candidates)
    {
        int      best      = -1;
        uint64_t best_cost = std::numeric_limits<uint64_t>::max();
        for (int candidate = 0; candidate < candidates; ++candidate) {
            uint64_t cost = 0;
            for (int y = 8; y < tm::kFrameHeight; y += 24) {
                for (int x = 8; x < tm::kFrameWidth; x += 24) {
                    const int diff = static_cast<int>(LumaAt(buffer, x, y)) - static_cast<int>(tm::FrameLuma(candidate, x, y));
                    cost += static_cast<uint64_t>(diff < 0 ? -diff : diff);
                }
            }
            if (cost < best_cost) {
                best_cost = cost;
                best      = candidate;
            }
        }
        return best;
    }

    stdfs::path directory;
    bool        drained { false };
};

TEST_F(VtFrameDecoderTest, FramesComeOutInDisplayOrderOnAClipWithBFrames)
{
    const auto path = directory / "reordered.mp4";
    ASSERT_TRUE(tm::WriteReorderedVideo(path, "reordered"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    ASSERT_EQ(reader->samples().size(), static_cast<std::size_t>(tm::kReorderedFrames));
    const std::size_t depth = ReorderDepth(reader->samples());
    ASSERT_GE(depth, 1u) << "the fixture has no reordering, so this proves nothing";

    auto decoder = MakeDecoder(*reader);
    ASSERT_NE(decoder, nullptr);
    EXPECT_EQ(decoder->pixelFormat(), static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));

    const auto frames = Run(*reader, *decoder, 0, reader->samples().size(), true);
    ASSERT_EQ(frames.size(), reader->samples().size());
    std::int64_t previous = std::numeric_limits<std::int64_t>::min();
    for (std::size_t index = 0; index < frames.size(); ++index) {
        EXPECT_GT(frames[index].pts, previous) << "frame " << index << " came out of display order";
        previous = frames[index].pts;
        // The picture is the one shown at that time: frame i of the encoded noise.
        const int expected = static_cast<int>(index);
        EXPECT_EQ(NoiseFrameOf(static_cast<CVPixelBufferRef>(frames[index].pixels.get()), tm::kReorderedFrames), expected)
            << "the picture at position " << index << " is another frame's";
    }
    // Printed so a log shows whether VideoToolbox reordered itself or the wrapper did.
    std::printf("[ vt ] reorder depth %zu, completions out of decode order: %llu, hardware: %d\n", depth,
                static_cast<unsigned long long>(decoder->outOfOrderCompletions()), decoder->usingHardware());
}

TEST_F(VtFrameDecoderTest, FramesAreIoSurfaceBackedAndMetalCompatible)
{
    const auto path = directory / "plain.mp4";
    ASSERT_TRUE(tm::WriteSyntheticVideo(path, 1, "plain"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    auto decoder = MakeDecoder(*reader);
    ASSERT_NE(decoder, nullptr);
    const auto frames = Run(*reader, *decoder, 0, 5, true);
    ASSERT_EQ(frames.size(), 5u);
    for (const auto& frame : frames) {
        auto* buffer = static_cast<CVPixelBufferRef>(frame.pixels.get());
        EXPECT_NE(CVPixelBufferGetIOSurface(buffer), nullptr);
        EXPECT_EQ(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        EXPECT_EQ(CVPixelBufferGetWidth(buffer), static_cast<std::size_t>(tm::kFrameWidth));
        EXPECT_EQ(CVPixelBufferGetHeight(buffer), static_cast<std::size_t>(tm::kFrameHeight));
        EXPECT_EQ(CVPixelBufferGetPlaneCount(buffer), 2u);
    }
}

TEST_F(VtFrameDecoderTest, AResetDropsEverythingFromBeforeTheSeek)
{
    const auto path = directory / "seek.mp4";
    ASSERT_TRUE(tm::WriteReorderedVideo(path, "seek"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    auto decoder = MakeDecoder(*reader);
    ASSERT_NE(decoder, nullptr);

    // Put frames of the first group in flight, take none of them, and seek to the second group.
    std::vector<std::uint8_t> bytes;
    std::string               error;
    for (std::size_t index = 0; index < 12; ++index) {
        ASSERT_TRUE(reader->readSample(index, &bytes, nullptr));
        const Sample& sample = reader->samples()[index];
        ASSERT_NE(decoder->submit(bytes.data(), bytes.size(), { sample.pts, sample.dts, sample.duration }, sample.sync, &error),
                  VtFrameDecoder::SubmitResult::Failed) << error;
    }
    ASSERT_TRUE(decoder->reset(&error)) << error;

    const auto keyframe = reader->findKeyframeAtOrBefore(30 * (reader->info().timescale / 30));
    ASSERT_TRUE(keyframe.has_value());
    ASSERT_GT(*keyframe, 0u);
    const std::int64_t keyframe_pts = reader->samples()[*keyframe].pts;
    const auto frames = Run(*reader, *decoder, *keyframe, reader->samples().size(), true);
    ASSERT_FALSE(frames.empty());
    for (const auto& frame : frames) {
        EXPECT_GE(frame.pts, keyframe_pts) << "a frame from before the seek came out";
    }
    EXPECT_EQ(frames.size(), reader->samples().size() - *keyframe);
}

TEST_F(VtFrameDecoderTest, DrainDeliversTheReorderedTailAndThenEndsTheStream)
{
    const auto path = directory / "drain.mp4";
    ASSERT_TRUE(tm::WriteReorderedVideo(path, "drain"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    auto decoder = MakeDecoder(*reader);
    ASSERT_NE(decoder, nullptr);

    // Without a drain the last frames are still owed.
    const auto before = Run(*reader, *decoder, 0, reader->samples().size(), false);
    EXPECT_LT(before.size(), reader->samples().size());
    EXPECT_GE(before.size(), reader->samples().size() - ReorderDepth(reader->samples()) - 1);

    std::string error;
    ASSERT_TRUE(decoder->drain(&error)) << error;
    std::vector<DecodedFrame> tail;
    while (true) {
        DecodedFrame frame;
        const auto   received = decoder->receive(&frame, std::chrono::milliseconds(500), &error);
        if (received == VtFrameDecoder::ReceiveResult::Frame) {
            tail.push_back(std::move(frame));
            continue;
        }
        EXPECT_EQ(received, VtFrameDecoder::ReceiveResult::EndOfStream) << error;
        break;
    }
    EXPECT_EQ(before.size() + tail.size(), reader->samples().size());
    ASSERT_FALSE(before.empty());
    ASSERT_FALSE(tail.empty());
    EXPECT_GT(tail.front().pts, before.back().pts);
}

TEST_F(VtFrameDecoderTest, SubmittingStopsAtTheBoundUntilFramesAreTaken)
{
    const auto path = directory / "bounded.mp4";
    ASSERT_TRUE(tm::WriteSyntheticVideo(path, 2, "bounded"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    DecoderOptions options;
    options.maxInFlight   = 4;
    options.extraBuffered = 2;
    auto decoder = MakeDecoder(*reader, options);
    ASSERT_NE(decoder, nullptr);

    std::vector<std::uint8_t> bytes;
    std::string               error;
    std::size_t               accepted = 0;
    for (std::size_t index = 0; index < reader->samples().size(); ++index) {
        ASSERT_TRUE(reader->readSample(index, &bytes, nullptr));
        const Sample& sample = reader->samples()[index];
        const auto    result = decoder->submit(bytes.data(), bytes.size(), { sample.pts, sample.dts, sample.duration }, sample.sync, &error);
        if (result == VtFrameDecoder::SubmitResult::Full) {
            // Let the decoder finish what it has: the bound is on frames not yet taken.
            std::this_thread::sleep_for(std::chrono::milliseconds(300));
            if (decoder->submit(bytes.data(), bytes.size(), { sample.pts, sample.dts, sample.duration }, sample.sync, &error) ==
                VtFrameDecoder::SubmitResult::Accepted) {
                ADD_FAILURE() << "the decoder accepted a sample with its output buffer full";
            }
            break;
        }
        ASSERT_EQ(result, VtFrameDecoder::SubmitResult::Accepted) << error;
        ++accepted;
    }
    // In flight plus held (no reordering here: depth 0) plus the extra frames, and no more.
    EXPECT_LE(accepted, options.maxInFlight + 1 + options.extraBuffered + 1);
    EXPECT_GE(accepted, options.maxInFlight);

    // Taking frames makes room again, after as many as the bound let in beyond it.
    std::size_t taken = 0;
    bool        resumed = false;
    ASSERT_TRUE(reader->readSample(accepted, &bytes, nullptr));
    const Sample& pending = reader->samples()[accepted];
    while (taken <= accepted && ! resumed) {
        DecodedFrame frame;
        ASSERT_EQ(decoder->receive(&frame, std::chrono::milliseconds(2000), &error), VtFrameDecoder::ReceiveResult::Frame) << error;
        ++taken;
        resumed = decoder->submit(bytes.data(), bytes.size(), { pending.pts, pending.dts, pending.duration }, pending.sync,
                                  &error) == VtFrameDecoder::SubmitResult::Accepted;
    }
    EXPECT_TRUE(resumed) << "no room after taking " << taken << " frames";
    EXPECT_GE(taken, 1u);
}

TEST_F(VtFrameDecoderTest, DestroyingADecoderMidDecodeIsPrompt)
{
    const auto path = directory / "long.mp4";
    ASSERT_TRUE(tm::WriteLongGopVideo(path, "long"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    auto decoder = MakeDecoder(*reader);
    ASSERT_NE(decoder, nullptr);

    std::vector<std::uint8_t> bytes;
    std::string               error;
    for (std::size_t index = 0; index < 60; ++index) {
        ASSERT_TRUE(reader->readSample(index, &bytes, nullptr));
        const Sample& sample = reader->samples()[index];
        if (decoder->submit(bytes.data(), bytes.size(), { sample.pts, sample.dts, sample.duration }, sample.sync, &error) ==
            VtFrameDecoder::SubmitResult::Full) {
            break;
        }
    }
    // A waiting receive returns as soon as the decoder is cancelled.
    std::thread canceller([&decoder] {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        decoder->cancel();
    });
    const auto   waited_from = std::chrono::steady_clock::now();
    DecodedFrame frame;
    while (decoder->receive(&frame, std::chrono::seconds(10), &error) == VtFrameDecoder::ReceiveResult::Frame) {}
    canceller.join();
    EXPECT_LT(std::chrono::steady_clock::now() - waited_from, std::chrono::seconds(2));

    const auto start = std::chrono::steady_clock::now();
    decoder.reset();
    EXPECT_LT(std::chrono::steady_clock::now() - start, std::chrono::seconds(2));
}

/// Decodes every sample of a Matroska clip held in memory and returns the frames in the order they come out.
std::vector<DecodedFrame> DecodeMatroskaClip(const unsigned char* bytes, std::size_t size, std::string* why,
                                             std::int64_t* timescale, std::size_t* reorder)
{
    std::vector<DecodedFrame> frames;
    Error                     error;
    auto source = MakeMemoryByteSource(std::vector<std::uint8_t>(bytes, bytes + size));
    auto reader = MatroskaReader::Open(source, &error);
    if (reader == nullptr) {
        *why = Describe(error);
        return frames;
    }
    std::vector<std::uint8_t> first;
    reader->readSample(0, &first, &error);
    StreamFormat format;
    if (! MakeStreamFormat(reader->videoInfo(), reader->vp9KeyFrame() ? &*reader->vp9KeyFrame() : nullptr,
                           first.data(), first.size(), &format, why)) {
        return frames;
    }
    *timescale = reader->videoInfo().timescale;
    *reorder   = ReorderDepth(reader->videoSamples());
    auto decoder = VtFrameDecoder::Create(std::move(format), *timescale, *reorder, {}, why);
    if (decoder == nullptr) return frames;

    std::vector<std::uint8_t> data;
    std::size_t               next = 0;
    const auto&               samples = reader->videoSamples();
    bool                      drained = false;
    const auto                deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (std::chrono::steady_clock::now() < deadline) {
        while (next < samples.size()) {
            reader->readSample(next, &data, &error);
            const auto result = decoder->submit(data.data(), data.size(), { samples[next].pts, samples[next].dts, samples[next].duration },
                                                samples[next].sync, why);
            if (result == VtFrameDecoder::SubmitResult::Failed) return frames;
            if (result == VtFrameDecoder::SubmitResult::Full) break;
            ++next;
        }
        if (next >= samples.size() && ! drained) {
            decoder->drain(why);
            drained = true;
        }
        DecodedFrame frame;
        const auto   received = decoder->receive(&frame, std::chrono::milliseconds(50), why);
        if (received == VtFrameDecoder::ReceiveResult::Frame) frames.push_back(std::move(frame));
        else if (received == VtFrameDecoder::ReceiveResult::EndOfStream || received == VtFrameDecoder::ReceiveResult::Failed) break;
    }
    return frames;
}

TEST_F(VtFrameDecoderTest, AVp9ClipFromWebMDecodesEveryShownFrameInOrder)
{
    std::string    why;
    std::int64_t   timescale = 0;
    std::size_t    reorder   = 0;
    const auto frames = DecodeMatroskaClip(tm::kVp9Webm, sizeof(tm::kVp9Webm), &why, &timescale, &reorder);
    ASSERT_TRUE(why.empty()) << why;
    ASSERT_EQ(frames.size(), static_cast<std::size_t>(tm::kVp9WebmFrames));
    std::int64_t previous = std::numeric_limits<std::int64_t>::min();
    for (const auto& frame : frames) {
        EXPECT_GT(frame.pts, previous);
        previous = frame.pts;
        auto* buffer = static_cast<CVPixelBufferRef>(frame.pixels.get());
        EXPECT_EQ(CVPixelBufferGetWidth(buffer), static_cast<std::size_t>(tm::kVp9WebmWidth));
        EXPECT_EQ(CVPixelBufferGetHeight(buffer), static_cast<std::size_t>(tm::kVp9WebmHeight));
        EXPECT_EQ(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    }
    // 30 frames at 30 per second, in nanosecond ticks.
    EXPECT_NEAR(static_cast<double>(frames.back().pts) / static_cast<double>(timescale), 29.0 / 30.0, 0.002);
}

TEST_F(VtFrameDecoderTest, AnH264ClipWithBFramesFromMatroskaComesOutInDisplayOrder)
{
    std::string    why;
    std::int64_t   timescale = 0;
    std::size_t    reorder   = 0;
    const auto frames = DecodeMatroskaClip(tm::kH264Matroska, sizeof(tm::kH264Matroska), &why, &timescale, &reorder);
    ASSERT_TRUE(why.empty()) << why;
    EXPECT_GE(reorder, 1u) << "the clip has no reordering, so this proves nothing";
    ASSERT_EQ(frames.size(), static_cast<std::size_t>(tm::kH264MatroskaFrames));
    std::int64_t previous = std::numeric_limits<std::int64_t>::min();
    for (const auto& frame : frames) {
        EXPECT_GT(frame.pts, previous);
        previous = frame.pts;
    }
}

TEST_F(VtFrameDecoderTest, SamplesThatAreNotVideoAreSkippedAndAStreamOfThemFails)
{
    const auto path = directory / "garbage.mp4";
    ASSERT_TRUE(tm::WriteSyntheticVideo(path, 1, "garbage"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    auto decoder = MakeDecoder(*reader);
    ASSERT_NE(decoder, nullptr);

    std::vector<std::uint8_t> bytes;
    std::string               error;
    ASSERT_TRUE(reader->readSample(0, &bytes, nullptr));
    const Sample& first = reader->samples()[0];
    ASSERT_EQ(decoder->submit(bytes.data(), bytes.size(), { first.pts, first.dts, first.duration }, true, &error),
              VtFrameDecoder::SubmitResult::Accepted) << error;

    // Then samples whose NAL lengths point past their own end.
    std::vector<std::uint8_t> garbage(2000, 0xFF);
    std::size_t               frames = 0;
    bool                      failed = false;
    for (int index = 1; index < 400 && ! failed; ++index) {
        const auto submitted = decoder->submit(garbage.data(), garbage.size(), { index * 20, index * 20, 20 }, false, &error);
        failed = submitted == VtFrameDecoder::SubmitResult::Failed;
        DecodedFrame frame;
        while (true) {
            const auto received = decoder->receive(&frame, std::chrono::milliseconds(0), &error);
            if (received == VtFrameDecoder::ReceiveResult::Frame) ++frames;
            else {
                failed = failed || received == VtFrameDecoder::ReceiveResult::Failed;
                break;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::printf("[ vt ] garbage: frames %zu, skipped %llu, failed %d (%s)\n", frames,
                static_cast<unsigned long long>(decoder->skippedFrames()), failed, error.c_str());
    EXPECT_TRUE(failed) << "a stream of undecodable samples never failed";
    EXPECT_FALSE(error.empty());
    EXPECT_GE(decoder->skippedFrames(), 1u);
}

std::uint64_t PhysicalFootprintBytes()
{
    task_vm_info_data_t    info {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

// A measurement, not a check: how fast the decoder runs through a real clip and how much memory it
// holds while it does. `WALLPAPER_MACHINE_VIDEO_FILE` names an MP4 (any local one; the library's 4K
// 60 fps clips are the demanding case), `WE_TEST_VT_IN_FLIGHT` and `WE_TEST_VT_EXTRA_BUFFERED`
// override the decoder's bounds so a setting can be compared with another. Without a file it skips.
TEST_F(VtFrameDecoderTest, ALocalClipDecodesWholeAtSpeedWithinItsMemoryBounds)
{
    const char* file = std::getenv("WALLPAPER_MACHINE_VIDEO_FILE");
    if (file == nullptr || *file == '\0') GTEST_SKIP() << "WALLPAPER_MACHINE_VIDEO_FILE names no clip";
    auto reader = OpenReader(file);
    ASSERT_NE(reader, nullptr);
    DecoderOptions options;
    if (const char* value = std::getenv("WE_TEST_VT_IN_FLIGHT")) options.maxInFlight = static_cast<std::size_t>(std::atoi(value));
    if (const char* value = std::getenv("WE_TEST_VT_EXTRA_BUFFERED")) options.extraBuffered = static_cast<std::size_t>(std::atoi(value));
    auto decoder = MakeDecoder(*reader, options);
    ASSERT_NE(decoder, nullptr);

    const std::uint64_t base  = PhysicalFootprintBytes();
    std::uint64_t       peak  = base;
    std::size_t         count = 0;
    std::vector<std::uint8_t> bytes;
    std::string               error;
    std::size_t               next = 0;
    bool                      drained = false;
    const auto                started = std::chrono::steady_clock::now();
    while (true) {
        while (next < reader->samples().size()) {
            ASSERT_TRUE(reader->readSample(next, &bytes, nullptr));
            const Sample& sample = reader->samples()[next];
            const auto    result = decoder->submit(bytes.data(), bytes.size(), { sample.pts, sample.dts, sample.duration }, sample.sync, &error);
            ASSERT_NE(result, VtFrameDecoder::SubmitResult::Failed) << error;
            if (result == VtFrameDecoder::SubmitResult::Full) break;
            ++next;
        }
        if (next >= reader->samples().size() && ! drained) {
            ASSERT_TRUE(decoder->drain(&error)) << error;
            drained = true;
        }
        DecodedFrame frame;
        const auto   received = decoder->receive(&frame, std::chrono::milliseconds(20), &error);
        if (received == VtFrameDecoder::ReceiveResult::Frame) {
            ++count;
            if (count % 16 == 0) peak = std::max(peak, PhysicalFootprintBytes());
        } else if (received == VtFrameDecoder::ReceiveResult::EndOfStream) {
            break;
        } else {
            ASSERT_NE(received, VtFrameDecoder::ReceiveResult::Failed) << error;
        }
    }
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    std::printf("[ vt ] %zu frames in %.2f s = %.0f frames/s; in flight %zu, extra %zu; footprint peak +%.0f MB; hardware %d; out of order %llu\n",
                count, seconds, static_cast<double>(count) / seconds, options.maxInFlight, options.extraBuffered,
                static_cast<double>(peak - base) / 1048576.0, decoder->usingHardware(),
                static_cast<unsigned long long>(decoder->outOfOrderCompletions()));
    EXPECT_EQ(count, reader->samples().size());
}

TEST_F(VtFrameDecoderTest, ParameterSetsInTheFirstKeyFrameStandInForAnEmptyRecord)
{
    const auto path = directory / "inband.mp4";
    ASSERT_TRUE(tm::WriteSyntheticVideo(path, 1, "inband"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);

    // Rebuild the first key frame the way an `avc3` file carries it: the parameter sets in front of the picture.
    const VideoStreamInfo&    info = reader->info();
    ASSERT_EQ(info.configFourcc, FourCC('a', 'v', 'c', 'C'));
    ASSERT_GE(info.codecConfig.size(), 9u);
    std::vector<std::uint8_t> sample;
    ASSERT_TRUE(reader->readSample(0, &sample, nullptr));
    std::vector<std::uint8_t> with_sets;
    const std::uint8_t        lengthSize = static_cast<std::uint8_t>((info.codecConfig[4] & 3U) + 1U);
    ASSERT_EQ(lengthSize, 4);
    std::size_t at = 6;
    for (int pass = 0; pass < 2; ++pass) {
        const std::size_t count = pass == 0 ? (info.codecConfig[5] & 0x1FU) : info.codecConfig[at++];
        for (std::size_t index = 0; index < count; ++index) {
            const std::size_t length = (static_cast<std::size_t>(info.codecConfig[at]) << 8) | info.codecConfig[at + 1];
            at += 2;
            for (int shift = 24; shift >= 0; shift -= 8) with_sets.push_back(static_cast<std::uint8_t>(length >> shift));
            with_sets.insert(with_sets.end(), info.codecConfig.begin() + static_cast<std::ptrdiff_t>(at),
                             info.codecConfig.begin() + static_cast<std::ptrdiff_t>(at + length));
            at += length;
        }
    }
    with_sets.insert(with_sets.end(), sample.begin(), sample.end());

    VideoStreamInfo empty = info;
    empty.codecFourcc = FourCC('a', 'v', 'c', '3');
    empty.codecConfig = { info.codecConfig[0], info.codecConfig[1], info.codecConfig[2], info.codecConfig[3],
                          info.codecConfig[4], 0xE0, 0 };  // no SPS, no PPS

    StreamFormat format;
    std::string  why;
    EXPECT_FALSE(MakeStreamFormat(empty, nullptr, sample.data(), sample.size(), &format, &why))
        << "a stream with no parameter sets anywhere was accepted";
    ASSERT_TRUE(MakeStreamFormat(empty, nullptr, with_sets.data(), with_sets.size(), &format, &why)) << why;

    std::string error;
    auto decoder = VtFrameDecoder::Create(std::move(format), info.timescale, 0, {}, &error);
    ASSERT_NE(decoder, nullptr) << error;
    const Sample& first = reader->samples()[0];
    ASSERT_EQ(decoder->submit(sample.data(), sample.size(), { first.pts, first.dts, first.duration }, true, &error),
              VtFrameDecoder::SubmitResult::Accepted) << error;
    ASSERT_TRUE(decoder->drain(&error)) << error;
    DecodedFrame frame;
    ASSERT_EQ(decoder->receive(&frame, std::chrono::seconds(2), &error), VtFrameDecoder::ReceiveResult::Frame) << error;
    EXPECT_NE(frame.pixels.get(), nullptr);
}

VideoStreamInfo H264InfoFrom(const IsoBmffReader& reader)
{
    VideoStreamInfo info = reader.info();
    return info;
}

TEST_F(VtFrameDecoderTest, FormatsThisMacCannotDecodeAreRefusedWithAClearReason)
{
    const auto path = directory / "plain.mp4";
    ASSERT_TRUE(tm::WriteSyntheticVideo(path, 1, "refusals"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    StreamFormat format;
    std::string  why;

    VideoStreamInfo vp8 = H264InfoFrom(*reader);
    vp8.codecFourcc = FourCC('v', 'p', '0', '8');
    vp8.configFourcc = 0;
    vp8.codecConfig.clear();
    EXPECT_FALSE(MakeStreamFormat(vp8, nullptr, nullptr, 0, &format, &why));
    EXPECT_EQ(why, std::string(kFormatNotSupported) + "VP8 video");

    VideoStreamInfo unknown = H264InfoFrom(*reader);
    unknown.codecFourcc = FourCC('m', 'p', '4', 'v');
    EXPECT_FALSE(MakeStreamFormat(unknown, nullptr, nullptr, 0, &format, &why));
    EXPECT_NE(why.find("format not supported"), std::string::npos) << why;
    EXPECT_NE(why.find("mp4v"), std::string::npos) << why;

    // High 4:2:2: profile 122 and chroma_format_idc 2 in the avcC extension.
    VideoStreamInfo yuv422 = H264InfoFrom(*reader);
    yuv422.codecConfig[1] = 122;
    {
        std::vector<std::uint8_t>& config = yuv422.codecConfig;
        // Walk to the end of the PPS list and append the extension.
        std::size_t at = 6;
        for (std::size_t sets = config[5] & 0x1FU; sets > 0; --sets) at += 2 + ((static_cast<std::size_t>(config[at]) << 8) | config[at + 1]);
        const std::size_t ppsCount = config[at++];
        for (std::size_t sets = ppsCount; sets > 0; --sets) at += 2 + ((static_cast<std::size_t>(config[at]) << 8) | config[at + 1]);
        config.resize(at);
        config.insert(config.end(), { 0xFC | 2, 0xF8, 0xF8, 0 });
    }
    EXPECT_FALSE(MakeStreamFormat(yuv422, nullptr, nullptr, 0, &format, &why));
    EXPECT_EQ(why, std::string(kFormatNotSupported) + "4:2:2 chroma video");

    VideoStreamInfo twelve = H264InfoFrom(*reader);
    twelve.bitDepth = 12;
    EXPECT_FALSE(MakeStreamFormat(twelve, nullptr, nullptr, 0, &format, &why));
    EXPECT_EQ(why, std::string(kFormatNotSupported) + "12-bit video");

    // A damaged record is not "format not supported": the file is at fault.
    VideoStreamInfo damaged = H264InfoFrom(*reader);
    damaged.codecConfig.resize(3);
    EXPECT_FALSE(MakeStreamFormat(damaged, nullptr, nullptr, 0, &format, &why));
    EXPECT_EQ(why.find("format not supported"), std::string::npos) << why;

    // The decoder itself says the same when VideoToolbox has none.
    VideoStreamInfo ok = H264InfoFrom(*reader);
    std::vector<std::uint8_t> first;
    ASSERT_TRUE(reader->readSample(0, &first, nullptr));
    ASSERT_TRUE(MakeStreamFormat(ok, nullptr, first.data(), first.size(), &format, &why)) << why;
    EXPECT_EQ(format.pixelFormat, static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));
    EXPECT_EQ(format.bitDepth, 8);
}

TEST_F(VtFrameDecoderTest, TenBitStreamsAskForTheTenBitBiplanarFormat)
{
    const auto path = directory / "plain.mp4";
    ASSERT_TRUE(tm::WriteSyntheticVideo(path, 1, "tenbit"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    // A Main10 HEVC record: the format layer only reads the record, so one built by hand is enough.
    VideoStreamInfo info = reader->info();
    info.codecFourcc = FourCC('h', 'v', 'c', '1');
    info.configFourcc = FourCC('h', 'v', 'c', 'C');
    info.bitDepth = 10;
    info.codecConfig.assign(23, 0);
    info.codecConfig[0]  = 1;
    info.codecConfig[16] = 0xFC | 1;  // 4:2:0
    info.codecConfig[17] = 0xF8 | 2;  // luma 10-bit
    info.codecConfig[18] = 0xF8 | 2;
    info.codecConfig[21] = 0x03;      // 4-byte lengths
    info.codecConfig[22] = 0;         // no arrays
    EXPECT_EQ(ChromaSubsamplingOf(info, nullptr), ChromaSubsampling::Yuv420);
    StreamFormat format;
    std::string  why;
    // With no parameter sets anywhere the description cannot be built, which is the refusal asked for.
    EXPECT_FALSE(MakeStreamFormat(info, nullptr, nullptr, 0, &format, &why));
    EXPECT_NE(why.find("no parameter sets"), std::string::npos) << why;
    info.colour.source    = ColourDescription::Source::ContainerNclx;
    info.colour.fullRange = true;
    // 8-bit full range maps to the full-range biplanar format.
    VideoStreamInfo avc = reader->info();
    avc.colour = info.colour;
    std::vector<std::uint8_t> first;
    ASSERT_TRUE(reader->readSample(0, &first, nullptr));
    ASSERT_TRUE(MakeStreamFormat(avc, nullptr, first.data(), first.size(), &format, &why)) << why;
    EXPECT_EQ(format.pixelFormat, static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));
    EXPECT_TRUE(format.fullRange);
    // 10-bit: the 'x420' pair.
    avc.bitDepth = 10;
    ASSERT_TRUE(MakeStreamFormat(avc, nullptr, first.data(), first.size(), &format, &why)) << why;
    EXPECT_EQ(format.pixelFormat, static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange));
    avc.colour = {};
    ASSERT_TRUE(MakeStreamFormat(avc, nullptr, first.data(), first.size(), &format, &why)) << why;
    EXPECT_EQ(format.pixelFormat, static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange));
}

// A stream that states full range only in its parameter sets (no colr box) must
// reach the decoder as full range: asked for video range, VideoToolbox would
// compress 0-255 into 16-235 and every picture would come out flat.
TEST_F(VtFrameDecoderTest, FullRangeStatedOnlyByTheParameterSetsDecodesAsFullRange)
{
    const auto path = directory / "ramp.mp4";
    {
        std::ofstream out(path, std::ios::binary);
        out.write(reinterpret_cast<const char*>(tm::kH264FullRangeMp4), sizeof tm::kH264FullRangeMp4);
    }
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    ASSERT_FALSE(reader->info().colour.present()) << "the fixture must carry no colr box";

    auto decoder = MakeDecoder(*reader);
    ASSERT_NE(decoder, nullptr);
    EXPECT_EQ(decoder->pixelFormat(), static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));

    const auto frames = Run(*reader, *decoder, 0, reader->samples().size(), true);
    ASSERT_EQ(frames.size(), static_cast<std::size_t>(tm::kFullRangeMp4Frames));
    auto* buffer = static_cast<CVPixelBufferRef>(frames.front().pixels.get());
    EXPECT_EQ(CVPixelBufferGetPixelFormatType(buffer), static_cast<OSType>(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));
    // The ramp runs from black to white; a video-range decode would stop at about 16 and 235.
    int lowest = 255, highest = 0;
    std::set<int> levels;
    for (int x = 0; x < tm::kFullRangeMp4Width; ++x) {
        const int value = LumaAt(buffer, x, 24);
        lowest  = std::min(lowest, value);
        highest = std::max(highest, value);
        levels.insert(value);
    }
    EXPECT_LE(lowest, 4);
    EXPECT_GE(highest, 251);
    EXPECT_GE(levels.size(), 48u) << "the ramp lost levels";
}

TEST_F(VtFrameDecoderTest, TheContainersColourOutranksTheParameterSetsRange)
{
    const auto path = directory / "ramp.mp4";
    {
        std::ofstream out(path, std::ios::binary);
        out.write(reinterpret_cast<const char*>(tm::kH264FullRangeMp4), sizeof tm::kH264FullRangeMp4);
    }
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    std::vector<std::uint8_t> first;
    ASSERT_TRUE(reader->readSample(0, &first, nullptr));
    VideoStreamInfo info = reader->info();
    info.colour.source    = ColourDescription::Source::ContainerNclx;
    info.colour.fullRange = false;
    info.colour.primaries = info.colour.transfer = info.colour.matrix = 1;
    StreamFormat format;
    std::string  why;
    ASSERT_TRUE(MakeStreamFormat(info, nullptr, first.data(), first.size(), &format, &why)) << why;
    EXPECT_EQ(format.pixelFormat, static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));
    EXPECT_FALSE(format.fullRange);
}

TEST_F(VtFrameDecoderTest, HevcAndAv1RecordsThatStateFullRangeAskForTheFullRangeFormat)
{
    // HEVC: the parameter sets in the hvcC record.
    {
        const auto path = directory / "ramp265.mp4";
        {
            std::ofstream out(path, std::ios::binary);
            out.write(reinterpret_cast<const char*>(tm::kHevcFullRangeMp4), sizeof tm::kHevcFullRangeMp4);
        }
        auto reader = OpenReader(path);
        ASSERT_NE(reader, nullptr);
        ASSERT_FALSE(reader->info().colour.present());
        StreamFormat format;
        std::string  why;
        ASSERT_TRUE(MakeStreamFormat(reader->info(), nullptr, nullptr, 0, &format, &why)) << why;
        EXPECT_EQ(format.codecType, static_cast<std::uint32_t>(kCMVideoCodecType_HEVC));
        EXPECT_EQ(format.pixelFormat, static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange));
        EXPECT_TRUE(format.fullRange);
    }
    // AV1: the sequence header in the av1C record (written by SVT-AV1 for a full-range and a limited-range clip).
    if (! VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
        GTEST_SKIP() << "no AV1 hardware decoder on this Mac, so AV1 streams are refused before their range matters";
    }
    for (const bool full : { true, false }) {
        VideoStreamInfo info;
        info.codecFourcc  = FourCC('a', 'v', '0', '1');
        info.configFourcc = FourCC('a', 'v', '1', 'C');
        info.codedWidth   = 128;
        info.codedHeight  = 96;
        info.timescale    = 1000;
        info.codecConfig  = { 0x81, 0x00, 0x0c, 0x00, 0x0a, 0x0b, 0x02, 0x00, 0x00, 0x05, 0x59, 0xbf, 0xdf, 0x00, 0xbe,
                              static_cast<std::uint8_t>(full ? 0x02 : 0x00), 0x10 };
        StreamFormat format;
        std::string  why;
        ASSERT_TRUE(MakeStreamFormat(info, nullptr, nullptr, 0, &format, &why)) << why;
        EXPECT_EQ(format.fullRange, full);
        EXPECT_EQ(format.pixelFormat,
                  static_cast<std::uint32_t>(full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                                  : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));
    }
}

// The depth comes from the sample table of an untrusted file, and every level of
// it is a decoded picture held in memory.
TEST_F(VtFrameDecoderTest, AStreamThatReordersMoreThanADecoderMayHoldIsRefused)
{
    const auto path = directory / "plain.mp4";
    ASSERT_TRUE(tm::WriteSyntheticVideo(path, 1, "deep"));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    std::vector<std::uint8_t> first;
    ASSERT_TRUE(reader->readSample(0, &first, nullptr));

    // A table whose presentation times run backwards: every sample is shown before all the earlier ones.
    std::vector<Sample> reversed(300);
    for (std::size_t index = 0; index < reversed.size(); ++index) {
        reversed[index].dts = static_cast<std::int64_t>(index);
        reversed[index].pts = static_cast<std::int64_t>(reversed.size() - index);
    }
    const std::size_t depth = ReorderDepth(reversed);
    ASSERT_EQ(depth, 299u);

    auto create = [&](std::size_t reorder, std::string* error) {
        StreamFormat format;
        std::string  why;
        EXPECT_TRUE(MakeStreamFormat(reader->info(), nullptr, first.data(), first.size(), &format, &why)) << why;
        return VtFrameDecoder::Create(std::move(format), reader->info().timescale, reorder, {}, error);
    };
    std::string error;
    EXPECT_EQ(create(depth, &error), nullptr);
    EXPECT_NE(error.find("reorders 299 frames"), std::string::npos) << error;
    EXPECT_EQ(error.find("format not supported"), std::string::npos)
        << "a damaged table is not a format this Mac cannot decode, so another decoder may still play the file";
    EXPECT_EQ(create(kMaxReorderDepth + 1, &error), nullptr);
    EXPECT_NE(create(kMaxReorderDepth, &error), nullptr) << error;
}

TEST_F(VtFrameDecoderTest, AVp9StreamFromWebMGetsASynthesizedRecordAndASession)
{
    VideoStreamInfo info;
    info.codecFourcc = FourCC('v', 'p', '0', '9');
    info.codedWidth  = 640;
    info.codedHeight = 360;
    info.timescale   = 1000000000;
    Vp9FrameHeader header;
    header.profile         = 0;
    header.keyFrame        = true;
    header.hasColourConfig = true;
    header.bitDepth        = 8;
    header.colourSpace     = 2;
    header.width           = 640;
    header.height          = 360;
    StreamFormat format;
    std::string  why;
    ASSERT_TRUE(MakeStreamFormat(info, &header, nullptr, 0, &format, &why)) << why;
    EXPECT_EQ(format.codecType, static_cast<std::uint32_t>(kCMVideoCodecType_VP9));
    EXPECT_EQ(format.pixelFormat, static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange));
    std::string error;
    auto        decoder = VtFrameDecoder::Create(std::move(format), info.timescale, 0, {}, &error);
    EXPECT_NE(decoder, nullptr) << error;

    // Without a key frame header nothing can be synthesized.
    EXPECT_FALSE(MakeStreamFormat(info, nullptr, nullptr, 0, &format, &why));
    EXPECT_EQ(why.find("format not supported"), std::string::npos) << why;
    // A 4:4:4 VP9 stream is refused.
    header.subsamplingX = 0;
    header.subsamplingY = 0;
    EXPECT_FALSE(MakeStreamFormat(info, &header, nullptr, 0, &format, &why));
    EXPECT_EQ(why, std::string(kFormatNotSupported) + "4:4:4 chroma video");
}


// The 10-bit path end to end up to the GPU: a Main10 clip, read by the ISO-BMFF
// reader, becomes a format description whose colour tags VideoToolbox puts on
// every decoded frame as attachments, which is where the scene video import
// reads the curve, the primaries and the matrix from.
TEST_F(VtFrameDecoderTest, TenBitHevcClipsDecodeToTenBitFramesThatCarryTheirTags)
{
    if (! tm::TenBitEncoderAvailable()) GTEST_SKIP() << "no VideoToolbox HEVC Main10 encoder on this machine";
    struct Case {
        tm::TenBitTagging tagging;
        CFStringRef       transfer;
        CFStringRef       primaries;
        CFStringRef       matrix;
    };
    const Case cases[] = {
        { tm::TenBitTagging::Pq, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
          kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferYCbCrMatrix_ITU_R_2020 },
        { tm::TenBitTagging::Hlg, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
          kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferYCbCrMatrix_ITU_R_2020 },
        { tm::TenBitTagging::Bt709, kCVImageBufferTransferFunction_ITU_R_709_2,
          kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2 },
    };
    const tm::TenBitPicture picture { 520, 450, 590 };
    int                     index = 0;
    for (const Case& test : cases) {
        SCOPED_TRACE(index);
        const auto path = directory / ("ten-" + std::to_string(index++) + ".mp4");
        ASSERT_TRUE(tm::WriteTenBitVideo(path, test.tagging, picture, "ten-bit"));
        auto reader = OpenReader(path);
        ASSERT_NE(reader, nullptr);
        EXPECT_EQ(reader->info().bitDepth, 10);
        auto decoder = MakeDecoder(*reader);
        ASSERT_NE(decoder, nullptr);
        EXPECT_EQ(decoder->pixelFormat(), static_cast<std::uint32_t>(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange));

        const auto frames = Run(*reader, *decoder, 0, reader->samples().size(), true);
        ASSERT_EQ(frames.size(), static_cast<std::size_t>(tm::kTenBitFrames));
        for (const DecodedFrame& frame : frames) {
            const auto buffer = static_cast<CVPixelBufferRef>(frame.pixels.get());
            EXPECT_EQ(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
            EXPECT_TRUE(CVPixelBufferGetIOSurface(buffer) != nullptr);
            const auto attachment = [&](CFStringRef key) {
                return static_cast<CFStringRef>(CVBufferCopyAttachment(buffer, key, nullptr));
            };
            for (const auto& [key, expected] : { std::pair { kCVImageBufferTransferFunctionKey, test.transfer },
                                                  std::pair { kCVImageBufferColorPrimariesKey, test.primaries },
                                                  std::pair { kCVImageBufferYCbCrMatrixKey, test.matrix } }) {
                CFStringRef value = attachment(key);
                ASSERT_NE(value, nullptr) << [(__bridge NSString*)key UTF8String] << " is not attached";
                EXPECT_TRUE(CFEqual(value, expected)) << [(__bridge NSString*)key UTF8String];
                CFRelease(value);
            }
            // The codes survive: 10 bits in the top of each 16-bit word.
            CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            const auto* luma = static_cast<const std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
            const int   y = reinterpret_cast<const std::uint16_t*>(
                                luma + (tm::kFrameHeight / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
                                [tm::kFrameWidth / 2] >> 6;
            CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            EXPECT_NEAR(y, picture.y, 3);
        }
    }
}

// What a stream states about its own peak reaches the decoded frame, because the
// tone map starts from it. Reported rather than required: whether an encoder
// writes the content light level, and whether the decoder returns it, is
// VideoToolbox's, and the renderer falls back to 1000 nits without it.
TEST_F(VtFrameDecoderTest, AStatedContentLightLevelIsReportedWhereTheDecoderCarriesIt)
{
    if (! tm::TenBitEncoderAvailable()) GTEST_SKIP() << "no VideoToolbox HEVC Main10 encoder on this machine";
    const auto path = directory / "cll.mp4";
    ASSERT_TRUE(tm::WriteTenBitVideo(path, tm::TenBitTagging::Pq, tm::TenBitPicture {}, "cll", 600));
    auto reader = OpenReader(path);
    ASSERT_NE(reader, nullptr);
    auto decoder = MakeDecoder(*reader);
    ASSERT_NE(decoder, nullptr);
    const auto frames = Run(*reader, *decoder, 0, reader->samples().size(), true);
    ASSERT_FALSE(frames.empty());
    const auto buffer = static_cast<CVPixelBufferRef>(frames.front().pixels.get());
    CFTypeRef  light  = CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nullptr);
    if (light == nullptr) {
        RecordProperty("content_light_level", "not carried");
        return;
    }
    ASSERT_EQ(CFGetTypeID(light), CFDataGetTypeID());
    ASSERT_GE(CFDataGetLength(static_cast<CFDataRef>(light)), 2);
    const auto* bytes = CFDataGetBytePtr(static_cast<CFDataRef>(light));
    EXPECT_EQ(bytes[0] << 8 | bytes[1], 600);
    CFRelease(light);
}

} // namespace
} // namespace wallpaper::media::apple
