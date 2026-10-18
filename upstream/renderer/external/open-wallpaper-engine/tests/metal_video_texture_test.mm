// Surface-free coverage for scene video textures on the native Metal backend.
// Every frame is synthetic: no media file, no decoder and no display.
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

#include <gtest/gtest.h>

#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>

#include "Image.hpp"
#include "Interface/IImageParser.h"
#include "MetalRender/MetalVideoSupport.hpp"
#include "Scene/MetalRender/MetalVideoTextures.hpp"
#include "Scene/Scene.h"
#include "Video/VideoColorConversion.hpp"
#include "Video/VideoTextureSource.hpp"
#include "video_orientation_cases.hpp"

namespace
{
using namespace wallpaper;

/// A decoder that produces exactly the frames a test asks for.
///
/// It models the one behaviour the renderer depends on and cannot fake for
/// itself: a paused source does not promote a new generation, so pausing is
/// observable as "the generation stopped changing" rather than as a flag the
/// consumer is trusted to honour.
class FakeVideoSource final : public video::VideoTextureSource {
public:
    explicit FakeVideoSource(uint32_t width = 16,
                             uint32_t height = 16,
                             OSType format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    {
        resize(width, height, format);
    }

    ~FakeVideoSource() override
    {
        if (m_buffer != nullptr) CVPixelBufferRelease(m_buffer);
    }

    void resize(uint32_t width, uint32_t height, OSType format)
    {
        NSDictionary* attributes = @{
            (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : @ {},
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
        };
        CVPixelBufferRef replacement = nullptr;
        if (CVPixelBufferCreate(kCFAllocatorDefault,
                                width,
                                height,
                                format,
                                (__bridge CFDictionaryRef)attributes,
                                &replacement) != kCVReturnSuccess) {
            ADD_FAILURE() << "IOSurface-backed Metal-compatible CVPixelBuffer prerequisite";
            return;
        }
        if (m_buffer != nullptr) CVPixelBufferRelease(m_buffer);
        m_buffer            = replacement;
        m_frame.width       = width;
        m_frame.height      = height;
        m_frame.pixel_buffer = m_buffer;
        m_frame.io_surface  = CVPixelBufferGetIOSurface(m_buffer);
        m_frame.pixel_format = format;
        m_frame.plane_count = static_cast<uint32_t>(CVPixelBufferIsPlanar(m_buffer)
                                                        ? CVPixelBufferGetPlaneCount(m_buffer)
                                                        : 1);
        // The generation counter is the decoder's, not the buffer's: a
        // resolution change still produces newer frames, never older ones.
    }

    /// Fills the frame with one flat colour and queues it as a newer
    /// generation. It becomes the current frame at the next unpaused refresh.
    void produce(uint8_t luma_or_blue,
                 uint8_t cb_or_green,
                 uint8_t cr_or_red,
                 CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    {
        CVBufferSetAttachment(
            m_buffer, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
        ASSERT_EQ(CVPixelBufferLockBaseAddress(m_buffer, 0), kCVReturnSuccess);
        if (CVPixelBufferIsPlanar(m_buffer)) {
            auto* luma   = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(m_buffer, 0));
            auto* chroma = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(m_buffer, 1));
            for (uint32_t row = 0; row < m_frame.height; ++row) {
                memset(luma + row * CVPixelBufferGetBytesPerRowOfPlane(m_buffer, 0),
                       luma_or_blue,
                       m_frame.width);
            }
            for (uint32_t row = 0; row < m_frame.height / 2; ++row) {
                auto* line = chroma + row * CVPixelBufferGetBytesPerRowOfPlane(m_buffer, 1);
                for (uint32_t x = 0; x < m_frame.width; x += 2) {
                    line[x]     = cb_or_green;
                    line[x + 1] = cr_or_red;
                }
            }
        } else {
            auto* raw = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(m_buffer));
            for (uint32_t row = 0; row < m_frame.height; ++row) {
                auto* line = raw + row * CVPixelBufferGetBytesPerRow(m_buffer);
                for (uint32_t x = 0; x < m_frame.width; ++x) {
                    line[x * 4 + 0] = luma_or_blue;
                    line[x * 4 + 1] = cb_or_green;
                    line[x * 4 + 2] = cr_or_red;
                    line[x * 4 + 3] = 255;
                }
            }
        }
        ASSERT_EQ(CVPixelBufferUnlockBaseAddress(m_buffer, 0), kCVReturnSuccess);
        m_pending = m_frame.generation + 1;
    }

    bool prime(std::string*) override { return true; }

    void produceQuadrants() {
        produce(128, 128, 128);
        ASSERT_TRUE(video::testing_media::FillVideoQuadrants(m_buffer));
    }

    void setDisplayMatrix(const std::array<int32_t, 9>& matrix) {
        const auto transform = video::ResolveVideoDisplayTransform(matrix, m_frame.width, m_frame.height);
        ASSERT_TRUE(transform.has_value());
        m_frame.display_transform = *transform;
    }

    bool syncPlayback(const video::VideoPlaybackState& state, std::string* error) override
    {
        m_playback = state;
        if (! fail_sync) return true;
        if (error != nullptr) *error = "synthetic decoder failure";
        return false;
    }

    /// The clock the consumer last handed this source.
    const video::VideoPlaybackState& playback() const { return m_playback; }

    /// A decoder that has failed: every later sync reports it.
    bool fail_sync { false };

    bool refreshFrame(std::string*) override
    {
        if (! m_playback.paused && m_playback.rate > 0.0f && m_pending > m_frame.generation) {
            m_frame.generation = m_pending;
        }
        return true;
    }

    video::VideoTextureFrame currentFrame() const override { return m_frame; }
    double                   durationSeconds() const override { return 10.0; }
    double                   playbackSeconds() const override { return 0.0; }
    uint64_t                 loopCount() const override { return 0; }
    double frameDurationSeconds() const override { return frame_duration_seconds; }

    double frame_duration_seconds { 1.0 / 30.0 };

private:
    CVPixelBufferRef          m_buffer { nullptr };
    video::VideoTextureFrame  m_frame {};
    video::VideoPlaybackState m_playback {};
    uint64_t                  m_pending { 0 };
};

class MetalVideoTexture : public ::testing::Test {
protected:
    void SetUp() override
    {
        device = MTLCreateSystemDefaultDevice();
        if (device == nil) GTEST_SKIP() << "no Metal device on this machine";
        queue = [device newCommandQueue];
        ASSERT_NE(queue, nil);
        textures = std::make_unique<metal::MetalVideoTextures>();
        textures->configure(device);
    }

    /// One whole renderer frame: import, then let the GPU finish so the test
    /// can read what was written.
    bool RunFrame(std::string* error)
    {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        const bool           ok      = textures->beginFrame(scene, command, error);
        [command commit];
        [command waitUntilCompleted];
        return ok;
    }

    std::array<uint8_t, 4> ReadPixel(id<MTLTexture> texture, NSUInteger x, NSUInteger y)
    {
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:texture.pixelFormat
                                                               width:texture.width
                                                              height:texture.height
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage       = MTLTextureUsageShaderRead;
        id<MTLTexture> staging = [device newTextureWithDescriptor:descriptor];
        id<MTLCommandBuffer>      command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit    = [command blitCommandEncoder];
        [blit copyFromTexture:texture
                       sourceSlice:0
                       sourceLevel:0
                      sourceOrigin:MTLOriginMake(0, 0, 0)
                        sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                         toTexture:staging
                  destinationSlice:0
                  destinationLevel:0
                 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];

        std::array<uint8_t, 4> pixel {};
        [staging getBytes:pixel.data()
              bytesPerRow:4
               fromRegion:MTLRegionMake2D(x, y, 1, 1)
              mipmapLevel:0];
        return pixel;
    }

    id<MTLDevice>                               device { nil };
    id<MTLCommandQueue>                         queue { nil };
    std::unique_ptr<metal::MetalVideoTextures>  textures;
    Scene                                       scene;
};

/// What the shared CPU reference says this NV12 sample should become.
std::array<uint8_t, 3> CpuReference(video::YuvMatrix matrix,
                                    video::YuvRange  range,
                                    uint8_t          y,
                                    uint8_t          cb,
                                    uint8_t          cr)
{
    video::YuvColorDescription description {};
    description.matrix = matrix;
    description.range  = range;
    const auto rgb     = video::ConvertYuvCodeToRgb8(video::MakeYuvColorParams(description), y, cb, cr);
    return { rgb.red, rgb.green, rgb.blue };
}

TEST_F(MetalVideoTexture, ImportsABgraFrameWithoutConverting)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    source->produce(20, 140, 220);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    ASSERT_TRUE(RunFrame(&error)) << error;

    id<MTLTexture> texture = textures->texture("video");
    ASSERT_NE(texture, nil);
    EXPECT_EQ(texture.width, 16u);
    EXPECT_EQ(texture.height, 16u);
    // A BGRA frame is sampled where the decoder put it; nothing is converted.
    EXPECT_EQ(textures->conversionsEncodedForTests(), 0u);

    const auto pixel = ReadPixel(texture, 8, 8);
    EXPECT_EQ(pixel[0], 20);
    EXPECT_EQ(pixel[1], 140);
    EXPECT_EQ(pixel[2], 220);
    EXPECT_EQ(pixel[3], 255);
}

TEST_F(MetalVideoTexture, ConvertedNv12MatchesTheCpuColorReference)
{
    // The kernel is the compatibility backend's, field for field, so a wrong
    // range or matrix here would be a wrong picture there too.
    struct Case {
        OSType           format;
        video::YuvRange  range;
    };
    const std::array<Case, 2> cases {{
        { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, video::YuvRange::Limited },
        { kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, video::YuvRange::Full },
    }};
    const std::array<std::array<uint8_t, 3>, 3> samples {{
        { 126, 128, 160 },
        { 180, 128, 128 },
        { 51, 109, 212 },
    }};

    for (const auto& test_case : cases) {
        for (const auto& sample : samples) {
            auto source = std::make_shared<FakeVideoSource>(16, 16, test_case.format);
            source->produce(sample[0], sample[1], sample[2]);

            metal::MetalVideoTextures converter;
            converter.configure(device);
            std::string error;
            ASSERT_TRUE(converter.prepareForTests("video", source, &error)) << error;

            id<MTLCommandBuffer> command = [queue commandBuffer];
            ASSERT_TRUE(converter.beginFrame(scene, command, &error)) << error;
            [command commit];
            [command waitUntilCompleted];

            id<MTLTexture> texture = converter.texture("video");
            ASSERT_NE(texture, nil);
            EXPECT_EQ(converter.conversionsEncodedForTests(), 1u);

            const auto expected =
                CpuReference(video::YuvMatrix::Bt709, test_case.range, sample[0], sample[1], sample[2]);
            const auto pixel = ReadPixel(texture, 8, 8);
            // Destination is BGRA8, so the blue channel comes first.
            EXPECT_NEAR(pixel[2], expected[0], 2) << "red";
            EXPECT_NEAR(pixel[1], expected[1], 2) << "green";
            EXPECT_NEAR(pixel[0], expected[2], 2) << "blue";
            EXPECT_EQ(pixel[3], 255) << "video frames are opaque";
        }
    }
}

TEST_F(MetalVideoTexture, BgraAndNv12ApplyEveryDisplayOrientationToTheirPixels)
{
    for (const auto format : {kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange}) {
        for (const auto& orientation : video::testing_media::kOrientations) {
            SCOPED_TRACE(orientation.name);
            auto source = std::make_shared<FakeVideoSource>(16, 8, format);
            source->produceQuadrants();
            source->setDisplayMatrix(orientation.matrix());
            metal::MetalVideoTextures converter;
            converter.configure(device);
            std::string error;
            ASSERT_TRUE(converter.prepareForTests("video", source, &error)) << error;
            auto command = [queue commandBuffer];
            ASSERT_TRUE(converter.beginFrame(scene, command, &error)) << error;
            [command commit]; [command waitUntilCompleted];
            const auto texture = converter.texture("video");
            ASSERT_NE(texture, nil);
            EXPECT_EQ(texture.width, orientation.swaps_axes ? 8u : 16u);
            EXPECT_EQ(texture.height, orientation.swaps_axes ? 16u : 8u);
            for (size_t corner = 0; corner < 4; ++corner) {
                const auto pixel = ReadPixel(texture, corner % 2 ? texture.width - 2 : 1,
                                             corner / 2 ? texture.height - 2 : 1);
                const auto expected = video::testing_media::kQuadrantLuma[orientation.source_quadrants[corner]];
                for (size_t channel = 0; channel < 3; ++channel) EXPECT_NEAR(pixel[channel], expected, 2);
                EXPECT_EQ(pixel[3], 255);
            }
        }
    }
}

TEST_F(MetalVideoTexture, AffineShearLeavesUncoveredCornersTransparent)
{
    for (const auto format : {kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange}) {
        auto source = std::make_shared<FakeVideoSource>(16, 8, format);
        source->produceQuadrants();
        source->setDisplayMatrix({65536, 0, 0, 32768, 65536, 0, 0, 0, 1 << 30});
        metal::MetalVideoTextures converter;
        converter.configure(device);
        std::string error;
        ASSERT_TRUE(converter.prepareForTests("video", source, &error)) << error;
        auto command = [queue commandBuffer];
        ASSERT_TRUE(converter.beginFrame(scene, command, &error)) << error;
        [command commit]; [command waitUntilCompleted];
        const auto texture = converter.texture("video");
        ASSERT_NE(texture, nil);
        EXPECT_EQ(texture.width, 20u); EXPECT_EQ(texture.height, 8u);
        EXPECT_EQ(ReadPixel(texture, 19, 0), (std::array<uint8_t, 4> {}));
        EXPECT_EQ(ReadPixel(texture, 0, 7), (std::array<uint8_t, 4> {}));
        EXPECT_EQ(ReadPixel(texture, 10, 4)[3], 255u);
    }
}

TEST_F(MetalVideoTexture, AGenerationIsConvertedOnlyOnce)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(128, 128, 128);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    ASSERT_TRUE(RunFrame(&error)) << error;
    id<MTLTexture> first = textures->texture("video");
    ASSERT_NE(first, nil);
    ASSERT_EQ(textures->conversionsEncodedForTests(), 1u);

    ASSERT_TRUE(RunFrame(&error)) << error;
    EXPECT_EQ(textures->conversionsEncodedForTests(), 1u)
        << "an unchanged generation keeps the texture it already has";
    EXPECT_EQ(textures->texture("video"), first);
    EXPECT_EQ(textures->importsForTests(), 1u);
}

TEST_F(MetalVideoTexture, PausedPlaybackKeepsTheLastTexture)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(128, 128, 128);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    ASSERT_TRUE(RunFrame(&error)) << error;
    id<MTLTexture> first   = textures->texture("video");
    const auto     imports = textures->importsForTests();
    ASSERT_NE(first, nil);
    EXPECT_TRUE(textures->advancesOnItsOwn());

    textures->setPaused(true);
    source->produce(64, 100, 200);
    ASSERT_TRUE(RunFrame(&error)) << error;
    EXPECT_EQ(textures->texture("video"), first);
    EXPECT_EQ(textures->importsForTests(), imports);
    EXPECT_FALSE(textures->advancesOnItsOwn());

    textures->setPaused(false);
    ASSERT_TRUE(RunFrame(&error)) << error;
    EXPECT_EQ(textures->importsForTests(), imports + 1)
        << "resuming picks up the frame the decoder promoted, not a backlog";
}

TEST_F(MetalVideoTexture, RebuildsDestinationsWhenTheFrameSizeChanges)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(128, 128, 128);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    ASSERT_TRUE(RunFrame(&error)) << error;
    ASSERT_EQ(textures->texture("video").width, 16u);

    source->resize(32, 24, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    source->produce(128, 128, 128);
    ASSERT_TRUE(RunFrame(&error)) << error;

    id<MTLTexture> resized = textures->texture("video");
    ASSERT_NE(resized, nil);
    EXPECT_EQ(resized.width, 32u);
    EXPECT_EQ(resized.height, 24u);
}

TEST_F(MetalVideoTexture, SurvivesReleaseWhileAFrameIsInFlight)
{
    auto source = std::make_shared<FakeVideoSource>(64, 64);
    source->produce(128, 128, 128);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;

    id<MTLCommandBuffer> command = [queue commandBuffer];
    ASSERT_TRUE(textures->beginFrame(scene, command, &error)) << error;

    __block bool completed = false;
    [command addCompletedHandler:^(id<MTLCommandBuffer>) {
        completed = true;
    }];
    [command commit];

    // The frame's pixel buffer, plane wrappers and destination belong to the
    // command buffer now, so tearing the renderer down cannot free them.
    textures->release();
    textures.reset();

    [command waitUntilCompleted];
    EXPECT_TRUE(completed);
    EXPECT_NE(command.status, MTLCommandBufferStatusError);
}

TEST_F(MetalVideoTexture, ReportsTheShortestFramePeriod)
{
    auto fast = std::make_shared<FakeVideoSource>(16, 16);
    fast->produce(128, 128, 128);
    fast->frame_duration_seconds = 1.0 / 60.0;
    auto slow = std::make_shared<FakeVideoSource>(16, 16);
    slow->produce(128, 128, 128);
    slow->frame_duration_seconds = 1.0 / 24.0;

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("fast", fast, &error)) << error;
    ASSERT_TRUE(textures->prepareForTests("slow", slow, &error)) << error;
    EXPECT_NEAR(textures->shortestFramePeriod(), 1.0 / 60.0, 1e-9);

    // A source that cannot report its rate makes the whole answer unknown.
    slow->frame_duration_seconds = 0.0;
    EXPECT_EQ(textures->shortestFramePeriod(), 0.0);

    EXPECT_TRUE(textures->owns("fast"));
    EXPECT_FALSE(textures->owns("missing"));
    textures->release();
    EXPECT_TRUE(textures->empty());
}

/// A parser that is not to be asked for anything: a video a rebuild kept open is
/// not read again, and reading one packaged in a scene copies and hashes its file.
class CountingImageParser final : public IImageParser {
public:
    std::shared_ptr<Image> Parse(const std::string&) override
    {
        ++parses;
        return nullptr;
    }
    ImageHeader ParseHeader(const std::string&) override { return {}; }
    int         parses { 0 };
};

/// The scene a rebuild compiles again: a video texture named `key`, a parser that
/// counts what it is asked for, the clock somewhere into the clip.
CountingImageParser* DescribeVideos(Scene& scene, std::initializer_list<const char*> keys,
                                    double elapsed_seconds)
{
    for (const char* key : keys) {
        scene.textures[key] = SceneTexture { .url = key, .isVideo = true };
    }
    auto parser          = std::make_unique<CountingImageParser>();
    auto* counting       = parser.get();
    scene.imageParser    = std::move(parser);
    scene.elapsingTime   = elapsed_seconds;
    return counting;
}

TEST_F(MetalVideoTexture, AVideoSetAsideByARebuildIsTakenBackAsItIsAndNotReadAgain)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    source->produce(20, 140, 220);
    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    ASSERT_TRUE(RunFrame(&error)) << error;
    auto* parser = DescribeVideos(scene, { "video" }, 4.0);

    textures->hold();
    EXPECT_FALSE(textures->owns("video")) << "the graph that went still owns its video";
    EXPECT_TRUE(textures->empty());
    EXPECT_EQ(textures->texture("video"), nil);
    EXPECT_FALSE(textures->advancesOnItsOwn());

    ASSERT_TRUE(textures->prepare(scene, { "video" }, &error)) << error;
    EXPECT_TRUE(textures->owns("video"));
    EXPECT_EQ(parser->parses, 0) << "a video kept open was read from the scene again";
    // The source that was playing is the one playing, given the clock it is to be at.
    EXPECT_NEAR(source->playback().scene_elapsed_seconds, 4.0, 1e-9);

    // And it goes on delivering: its next frame reaches the new graph's texture.
    source->produce(200, 60, 10);
    ASSERT_TRUE(RunFrame(&error)) << error;
    id<MTLTexture> texture = textures->texture("video");
    ASSERT_NE(texture, nil);
    const auto pixel = ReadPixel(texture, 8, 8);
    EXPECT_EQ(pixel[0], 200);
    EXPECT_EQ(pixel[1], 60);
    EXPECT_EQ(pixel[2], 10);
    EXPECT_TRUE(textures->advancesOnItsOwn());

    // Nothing is left to close: the compile that took it back ends without ending it.
    const std::weak_ptr<FakeVideoSource> watcher = source;
    source.reset();
    textures->closeHeld();
    EXPECT_FALSE(watcher.expired());
    EXPECT_TRUE(textures->owns("video"));
}

TEST_F(MetalVideoTexture, AVideoTheNewGraphDoesNotUseIsClosedWithItsCompile)
{
    auto kept    = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    auto dropped = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    kept->produce(20, 140, 220);
    dropped->produce(20, 140, 220);
    std::string error;
    ASSERT_TRUE(textures->prepareForTests("kept", kept, &error)) << error;
    ASSERT_TRUE(textures->prepareForTests("dropped", dropped, &error)) << error;
    auto* parser = DescribeVideos(scene, { "kept", "dropped" }, 1.0);
    const std::weak_ptr<FakeVideoSource> kept_watch = kept, dropped_watch = dropped;
    kept.reset();
    dropped.reset();

    textures->hold();
    // The graph that went is released as it always was; what was set aside is not
    // part of it, and stays open until the compile says which videos it still uses.
    textures->release();
    EXPECT_FALSE(kept_watch.expired());
    EXPECT_FALSE(dropped_watch.expired());

    ASSERT_TRUE(textures->prepare(scene, { "kept" }, &error)) << error;
    EXPECT_FALSE(dropped_watch.expired()) << "closed before the compile had finished";
    textures->closeHeld();
    EXPECT_TRUE(dropped_watch.expired()) << "a video the new graph does not use is still open";
    EXPECT_FALSE(kept_watch.expired());
    EXPECT_TRUE(textures->owns("kept"));
    EXPECT_FALSE(textures->owns("dropped"));
    EXPECT_EQ(parser->parses, 0);
}

TEST_F(MetalVideoTexture, VideosSetAsideAreClosedByClosingThemAndByTheObjectGoingAway)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    source->produce(20, 140, 220);
    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    const std::weak_ptr<FakeVideoSource> watcher = source;
    source.reset();
    textures->hold();
    EXPECT_FALSE(watcher.expired());
    // A graph that is released for good (the scene is replaced, the renderer is
    // destroyed) closes what was set aside with it.
    textures->closeHeld();
    EXPECT_TRUE(watcher.expired());

    auto again = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    again->produce(20, 140, 220);
    ASSERT_TRUE(textures->prepareForTests("video", again, &error)) << error;
    const std::weak_ptr<FakeVideoSource> other = again;
    again.reset();
    textures->hold();
    EXPECT_FALSE(other.expired());
    textures.reset();
    EXPECT_TRUE(other.expired());
}

TEST_F(MetalVideoTexture, AVideoSetAsideThatFailedWhileItWaitedIsOpenedAgainLikeAnyOther)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    source->produce(20, 140, 220);
    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    auto* parser = DescribeVideos(scene, { "video" }, 2.0);
    textures->hold();
    source->fail_sync = true;
    const std::weak_ptr<FakeVideoSource> watcher = source;
    source.reset();

    // The scene's parser is asked, as it would be for a video never opened; this one
    // has nothing to give, which is what shows the open was tried.
    EXPECT_FALSE(textures->prepare(scene, { "video" }, &error));
    EXPECT_EQ(parser->parses, 1);
    EXPECT_NE(error.find("failed to parse video texture"), std::string::npos) << error;
    EXPECT_TRUE(watcher.expired()) << "a decoder that had failed was kept";
}

TEST(MetalVideoTextureRejection, AcceptsAPlainVideoTextureAndRejectsASpriteSheet)
{
    Scene scene;
    scene.textures["plain"]  = SceneTexture { .url = "video.mp4", .isVideo = true };
    scene.textures["sprite"] = SceneTexture {
        .url = "video.mp4", .isVideo = true, .isSprite = true
    };
    scene.textures["still"] = SceneTexture { .url = "image.tex" };

    EXPECT_TRUE(metal::MetalVideoTextureRejection(scene, "plain").empty());
    EXPECT_TRUE(metal::MetalVideoTextureRejection(scene, "still").empty());
    // Not described by the scene at all: the parser decides later, and the
    // frames decide after that.
    EXPECT_TRUE(metal::MetalVideoTextureRejection(scene, "unknown").empty());
    EXPECT_FALSE(metal::MetalVideoTextureRejection(scene, "sprite").empty());
}

} // namespace

// ---------------------------------------------------------------------------
// Consumption is decided before anything is imported.
//
// The point of the direct path is not that a shader *can* sample planes; it is
// that nothing converts a frame no consumer asked to have converted. These
// assert the negative -- no conversion encoded, no destination allocated --
// because a path that samples planes and still converts every frame has saved
// nothing at all.

TEST_F(MetalVideoTexture, PlanesOnlyDemandEncodesNoConversion)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(126, 128, 160);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    textures->setDemand({ { "video", metal::VideoConsumerDemand { true, false } } });
    ASSERT_TRUE(RunFrame(&error)) << error;

    EXPECT_EQ(textures->conversionsEncodedForTests(), 0u);
    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Nv12Direct);
    // No single colour image exists, and that is the point rather than an
    // omission: asking for one has to come back empty.
    EXPECT_EQ(textures->texture("video"), nil);

    const auto planes = textures->planes("video");
    ASSERT_TRUE(planes.valid());
    EXPECT_EQ(planes.luma.width, 16u);
    EXPECT_EQ(planes.luma.height, 16u);
    EXPECT_EQ(planes.chroma.width, 8u);
    EXPECT_EQ(planes.chroma.height, 8u);
    EXPECT_EQ(planes.luma.pixelFormat, MTLPixelFormatR8Unorm);
    EXPECT_EQ(planes.chroma.pixelFormat, MTLPixelFormatRG8Unorm);

    uint32_t width  = 0;
    uint32_t height = 0;
    EXPECT_TRUE(textures->frameSize("video", &width, &height));
    EXPECT_EQ(width, 16u);
    EXPECT_EQ(height, 16u);
}

TEST_F(MetalVideoTexture, MixedDemandConvertsOnceAndStillPublishesThePlanes)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(126, 128, 160);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    textures->setDemand({ { "video", metal::VideoConsumerDemand { true, true } } });
    ASSERT_TRUE(RunFrame(&error)) << error;

    // One conversion for every consumer that needs an image, however many
    // passes that is -- not one per pass, and not none.
    EXPECT_EQ(textures->conversionsEncodedForTests(), 1u);
    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Nv12Mixed);
    EXPECT_NE(textures->texture("video"), nil);
    EXPECT_TRUE(textures->planes("video").valid());
}

TEST_F(MetalVideoTexture, DirectlySampledPlanesCarryTheSameColourConstantsAsTheKernel)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(126, 128, 160, kCVImageBufferYCbCrMatrix_ITU_R_709_2);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    textures->setDemand({ { "video", metal::VideoConsumerDemand { true, false } } });
    ASSERT_TRUE(RunFrame(&error)) << error;

    video::YuvColorDescription description {};
    description.matrix = video::YuvMatrix::Bt709;
    description.range  = video::YuvRange::Limited;
    const auto expected = video::MakeYuvColorParams(description);
    const auto actual   = textures->planes("video").params;

    // The direct path hands these to the author's shader and the converting
    // path hands the same eight to the kernel. A difference here is the two
    // paths disagreeing about colour, which is the failure this exists to
    // catch.
    EXPECT_FLOAT_EQ(actual.y_offset, expected.y_offset);
    EXPECT_FLOAT_EQ(actual.y_scale, expected.y_scale);
    EXPECT_FLOAT_EQ(actual.chroma_offset, expected.chroma_offset);
    EXPECT_FLOAT_EQ(actual.chroma_scale, expected.chroma_scale);
    EXPECT_FLOAT_EQ(actual.r_cr, expected.r_cr);
    EXPECT_FLOAT_EQ(actual.g_cb, expected.g_cb);
    EXPECT_FLOAT_EQ(actual.g_cr, expected.g_cr);
    EXPECT_FLOAT_EQ(actual.b_cb, expected.b_cb);
}

TEST_F(MetalVideoTexture, ADemandChangeReImportsTheSameGenerationInsteadOfWaiting)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(126, 128, 160);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    textures->setDemand({ { "video", metal::VideoConsumerDemand { true, false } } });
    ASSERT_TRUE(RunFrame(&error)) << error;
    ASSERT_EQ(textures->conversionsEncodedForTests(), 0u);

    // The setting was switched off while this generation is still the current
    // one. Waiting for the next decoded frame would leave the consumer with no
    // image to sample at all.
    textures->setDemand({ { "video", metal::VideoConsumerDemand { false, true } } });
    ASSERT_TRUE(RunFrame(&error)) << error;

    EXPECT_EQ(textures->conversionsEncodedForTests(), 1u);
    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Nv12Converted);
    EXPECT_NE(textures->texture("video"), nil);
}

TEST_F(MetalVideoTexture, ABgraFrameIgnoresAPlaneDemand)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    source->produce(20, 140, 220);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    // The consumer asked for planes, but software decode produced BGRA. The
    // frame's real format decides, not the request.
    textures->setDemand({ { "video", metal::VideoConsumerDemand { true, false } } });
    ASSERT_TRUE(RunFrame(&error)) << error;

    EXPECT_EQ(textures->conversionsEncodedForTests(), 0u);
    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Bgra);
    EXPECT_NE(textures->texture("video"), nil);
    EXPECT_FALSE(textures->planes("video").valid());
}

TEST_F(MetalVideoTexture, AFormatChangeSwitchesPathWithoutLosingTheTexture)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(126, 128, 160);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    textures->setDemand({ { "video", metal::VideoConsumerDemand { true, false } } });
    ASSERT_TRUE(RunFrame(&error)) << error;
    ASSERT_EQ(textures->path("video"), metal::VideoFramePath::Nv12Direct);

    // Hardware decode dropped out mid-playback and the same file now arrives as
    // BGRA. Nothing is reparsed and no timeline is reset; the next frame is
    // simply read as what it is.
    source->resize(16, 16, kCVPixelFormatType_32BGRA);
    source->produce(20, 140, 220);
    ASSERT_TRUE(RunFrame(&error)) << error;

    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Bgra);
    ASSERT_NE(textures->texture("video"), nil);
    EXPECT_FALSE(textures->planes("video").valid());
    const auto pixel = ReadPixel(textures->texture("video"), 8, 8);
    EXPECT_EQ(pixel[0], 20);
    EXPECT_EQ(pixel[1], 140);
    EXPECT_EQ(pixel[2], 220);
}
