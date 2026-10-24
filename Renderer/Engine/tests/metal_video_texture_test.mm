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
#include "hdr_reference.hpp"
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

    /// What a 10-bit frame is tagged with. A null string is "not stated", and a
    /// zero light level is "no such attachment".
    struct TenBitTags {
        CFStringRef transfer { nullptr };
        CFStringRef primaries { nullptr };
        CFStringRef matrix { kCVImageBufferYCbCrMatrix_ITU_R_2020 };
        int         max_content_light_nits { 0 };
        int         mastering_peak_nits { 0 };
    };

    /// Fills a 10-bit biplanar frame with one flat colour, given as the 10-bit
    /// code values, and queues it as a newer generation. The codes go where a
    /// decoder puts them: the top ten bits of each 16-bit word.
    void produceTenBit(uint16_t y, uint16_t cb, uint16_t cr, const TenBitTags& tags)
    {
        for (CFStringRef key : { kCVImageBufferTransferFunctionKey, kCVImageBufferColorPrimariesKey,
                                 kCVImageBufferYCbCrMatrixKey, kCVImageBufferContentLightLevelInfoKey,
                                 kCVImageBufferMasteringDisplayColorVolumeKey }) {
            CVBufferRemoveAttachment(m_buffer, key);
        }
        const auto attach = [&](CFStringRef key, CFTypeRef value) {
            if (value != nullptr) CVBufferSetAttachment(m_buffer, key, value, kCVAttachmentMode_ShouldPropagate);
        };
        attach(kCVImageBufferYCbCrMatrixKey, tags.matrix);
        attach(kCVImageBufferTransferFunctionKey, tags.transfer);
        attach(kCVImageBufferColorPrimariesKey, tags.primaries);
        if (tags.max_content_light_nits > 0) {
            // CTA-861.3: MaxCLL then MaxFALL, big-endian 16-bit nits.
            const uint8_t bytes[4] { static_cast<uint8_t>(tags.max_content_light_nits >> 8),
                                     static_cast<uint8_t>(tags.max_content_light_nits & 0xff), 0, 0 };
            CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, sizeof(bytes));
            attach(kCVImageBufferContentLightLevelInfoKey, data);
            CFRelease(data);
        }
        if (tags.mastering_peak_nits > 0) {
            // ST 2086: three primaries and a white point as 16-bit xy, then the
            // maximum and minimum luminance as 32-bit values of 0.0001 nits.
            const uint32_t max_luminance = static_cast<uint32_t>(tags.mastering_peak_nits) * 10000u;
            uint8_t bytes[24] {};
            for (int i = 0; i < 4; ++i) bytes[16 + i] = static_cast<uint8_t>(max_luminance >> (24 - 8 * i));
            CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, sizeof(bytes));
            attach(kCVImageBufferMasteringDisplayColorVolumeKey, data);
            CFRelease(data);
        }
        ASSERT_EQ(CVPixelBufferLockBaseAddress(m_buffer, 0), kCVReturnSuccess);
        auto* luma   = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(m_buffer, 0));
        auto* chroma = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(m_buffer, 1));
        for (uint32_t row = 0; row < m_frame.height; ++row) {
            auto* line = reinterpret_cast<uint16_t*>(luma + row * CVPixelBufferGetBytesPerRowOfPlane(m_buffer, 0));
            for (uint32_t x = 0; x < m_frame.width; ++x) line[x] = static_cast<uint16_t>(y << 6);
        }
        for (uint32_t row = 0; row < m_frame.height / 2; ++row) {
            auto* line = reinterpret_cast<uint16_t*>(chroma + row * CVPixelBufferGetBytesPerRowOfPlane(m_buffer, 1));
            for (uint32_t x = 0; x < m_frame.width; x += 2) {
                line[x]     = static_cast<uint16_t>(cb << 6);
                line[x + 1] = static_cast<uint16_t>(cr << 6);
            }
        }
        ASSERT_EQ(CVPixelBufferUnlockBaseAddress(m_buffer, 0), kCVReturnSuccess);
        m_pending = m_frame.generation + 1;
    }

    /// Four luma quadrants in a full-range 10-bit frame, neutral chroma, tagged
    /// as display-referred BT.709: the picture the display-matrix tests use.
    void produceTenBitQuadrants()
    {
        TenBitTags tags;
        tags.matrix    = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        tags.transfer  = kCVImageBufferTransferFunction_ITU_R_709_2;
        tags.primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
        produceTenBit(512, 512, 512, tags);
        ASSERT_EQ(CVPixelBufferLockBaseAddress(m_buffer, 0), kCVReturnSuccess);
        auto* luma = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(m_buffer, 0));
        for (uint32_t y = 0; y < m_frame.height; ++y) {
            auto* line = reinterpret_cast<uint16_t*>(luma + y * CVPixelBufferGetBytesPerRowOfPlane(m_buffer, 0));
            for (uint32_t x = 0; x < m_frame.width; ++x) {
                const auto quadrant = (y >= m_frame.height / 2 ? 2 : 0) + (x >= m_frame.width / 2 ? 1 : 0);
                line[x] = static_cast<uint16_t>((video::testing_media::kQuadrantLuma[quadrant] * 4) << 6);
            }
        }
        ASSERT_EQ(CVPixelBufferUnlockBaseAddress(m_buffer, 0), kCVReturnSuccess);
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

/// One 10-bit frame through a fresh converter, and the BGRA pixel at its centre.
/// What the frame is tagged with follows from `input`, the way a decoder would
/// tag it from the stream's own colour description.
struct TenBitResult {
    std::array<uint8_t, 4> pixel {};
    metal::VideoFramePath  path { metal::VideoFramePath::None };
    bool                   ok { false };
};

CFStringRef TransferTag(video::testing_media::hdr::Transfer transfer)
{
    using video::testing_media::hdr::Transfer;
    switch (transfer) {
    case Transfer::Pq: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    case Transfer::Hlg: return kCVImageBufferTransferFunction_ITU_R_2100_HLG;
    case Transfer::Sdr: break;
    }
    return kCVImageBufferTransferFunction_ITU_R_709_2;
}

CFStringRef PrimariesTag(video::testing_media::hdr::Primaries primaries)
{
    using video::testing_media::hdr::Primaries;
    switch (primaries) {
    case Primaries::Bt2020: return kCVImageBufferColorPrimaries_ITU_R_2020;
    case Primaries::P3D65: return kCVImageBufferColorPrimaries_P3_D65;
    case Primaries::Bt709: break;
    }
    return kCVImageBufferColorPrimaries_ITU_R_709_2;
}

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

    /// One 10-bit frame through a converter of its own.
    TenBitResult ConvertTenBit(const video::testing_media::hdr::Input& input, int max_content_light_nits = 0,
                               int mastering_peak_nits = 0)
    {
        TenBitResult result;
        auto source = std::make_shared<FakeVideoSource>(
            16, 16,
            input.full_range ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                             : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
        FakeVideoSource::TenBitTags tags;
        tags.transfer  = TransferTag(input.transfer);
        tags.primaries = PrimariesTag(input.primaries);
        tags.matrix    = input.bt2020_matrix ? kCVImageBufferYCbCrMatrix_ITU_R_2020
                                             : kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        tags.max_content_light_nits = max_content_light_nits;
        tags.mastering_peak_nits    = mastering_peak_nits;
        source->produceTenBit(static_cast<uint16_t>(input.y), static_cast<uint16_t>(input.cb),
                              static_cast<uint16_t>(input.cr), tags);

        metal::MetalVideoTextures converter;
        converter.configure(device);
        std::string error;
        if (! converter.prepareForTests("video", source, &error)) {
            ADD_FAILURE() << error;
            return result;
        }
        id<MTLCommandBuffer> command = [queue commandBuffer];
        if (! converter.beginFrame(scene, command, &error)) {
            ADD_FAILURE() << error;
            [command commit];
            return result;
        }
        [command commit];
        [command waitUntilCompleted];
        id<MTLTexture> texture = converter.texture("video");
        if (texture == nil) {
            ADD_FAILURE() << "a 10-bit frame produced no image";
            return result;
        }
        result.pixel = ReadPixel(texture, 8, 8);
        result.path  = converter.path("video");
        result.ok    = true;
        return result;
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
    // The kernel is checked against the CPU reference field for field, so a wrong
    // range or matrix would be a wrong picture.
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

TEST_F(MetalVideoTexture, OwnsTheKeysItPreparedUntilItIsReleased)
{
    auto fast = std::make_shared<FakeVideoSource>(16, 16);
    fast->produce(128, 128, 128);
    auto slow = std::make_shared<FakeVideoSource>(16, 16);
    slow->produce(128, 128, 128);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("fast", fast, &error)) << error;
    ASSERT_TRUE(textures->prepareForTests("slow", slow, &error)) << error;

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

// ---- 10-bit and HDR video -----------------------------------------------------
//
// The reference these compare against is `hdr_reference.hpp`, written from the
// standards (BT.2100, ST 2084, BT.2390) rather than from the kernel, so a wrong
// curve, a wrong matrix or a wrong order of steps shows as a difference here
// and not as two copies of the same mistake.

namespace
{
namespace ref = video::testing_media::hdr;

constexpr int kGpuTolerance = 3;

/// Compares one converted pixel with the reference's, per channel, in 8-bit codes.
void ExpectMatchesReference(const std::array<uint8_t, 4>& pixel, const ref::Input& input,
                            const std::string& what, int tolerance = kGpuTolerance)
{
    const auto expected = ref::ToBgra8(ref::ReferenceRgb(input));
    EXPECT_NEAR(pixel[2], expected[0], tolerance) << what << " red";
    EXPECT_NEAR(pixel[1], expected[1], tolerance) << what << " green";
    EXPECT_NEAR(pixel[0], expected[2], tolerance) << what << " blue";
    EXPECT_EQ(pixel[3], 255) << what << ": video frames are opaque";
}

ref::Input PqGrey(double nits)
{
    ref::Input input;
    input.transfer = ref::Transfer::Pq;
    input.y        = ref::PqLumaCode(nits);
    return input;
}

ref::Input HlgGrey(double level)
{
    ref::Input input;
    input.transfer = ref::Transfer::Hlg;
    input.y        = ref::HlgLumaCode(level);
    return input;
}
} // namespace

TEST_F(MetalVideoTexture, P010ConvertedMatchesCpuReference)
{
    struct Case {
        const char* name;
        ref::Input  input;
    };
    std::vector<Case> cases;
    // PQ greys across the range, from black through reference white to the peak
    // of the curve.
    for (const double nits : { 0.0, 1.0, 20.0, 100.0, 203.0, 400.0, 1000.0, 4000.0, 10000.0 }) {
        cases.push_back({ "PQ grey", PqGrey(nits) });
    }
    // HLG greys, 0.75 being reference white.
    for (const double level : { 0.0, 0.25, 0.5, 0.75, 0.9, 1.0 }) {
        cases.push_back({ "HLG grey", HlgGrey(level) });
    }
    // Colour: BT.2020 saturated chroma in each curve, which also exercises the
    // BT.2020 matrix, the gamut rotation and the soft clip.
    for (const auto transfer : { ref::Transfer::Pq, ref::Transfer::Hlg }) {
        for (const auto& chroma : std::array<std::array<int, 3>, 5> {{
                 { 400, 300, 700 },   // red-ish
                 { 400, 700, 300 },   // green-ish
                 { 300, 760, 420 },   // blue-ish
                 { 600, 480, 560 },   // mild
                 { 700, 600, 450 },   // yellow-ish
             }}) {
            ref::Input input;
            input.transfer = transfer;
            input.y = chroma[0];
            input.cb = chroma[1];
            input.cr = chroma[2];
            cases.push_back({ transfer == ref::Transfer::Pq ? "PQ colour" : "HLG colour", input });
        }
    }
    // P3-D65 primaries, which rotate differently from BT.2020's.
    {
        ref::Input input = PqGrey(300.0);
        input.cb         = 420;
        input.cr         = 600;
        input.primaries  = ref::Primaries::P3D65;
        cases.push_back({ "PQ colour in P3-D65", input });
    }
    // Full range, BT.709 matrix on an HDR curve (a stream can mix them).
    {
        ref::Input input;
        input.transfer      = ref::Transfer::Pq;
        input.full_range    = true;
        input.bt2020_matrix = false;
        input.y             = 600;
        input.cb            = 450;
        input.cr            = 580;
        cases.push_back({ "PQ full range, BT.709 matrix", input });
    }
    // Display-referred 10-bit: BT.709 as it is, and BT.2020 primaries rotated.
    {
        ref::Input input;
        input.transfer      = ref::Transfer::Sdr;
        input.primaries     = ref::Primaries::Bt709;
        input.bt2020_matrix = false;
        input.y             = 500;
        input.cb            = 400;
        input.cr            = 610;
        cases.push_back({ "SDR BT.709", input });
        input.primaries = ref::Primaries::Bt2020;
        input.bt2020_matrix = true;
        cases.push_back({ "SDR in BT.2020 primaries", input });
    }

    for (const auto& test_case : cases) {
        SCOPED_TRACE(test_case.name);
        const auto result = ConvertTenBit(test_case.input);
        ASSERT_TRUE(result.ok);
        EXPECT_EQ(result.path, metal::VideoFramePath::Yuv10Converted);
        ExpectMatchesReference(result.pixel, test_case.input,
                               std::string(test_case.name) + " y=" + std::to_string(test_case.input.y) +
                                   " cb=" + std::to_string(test_case.input.cb) +
                                   " cr=" + std::to_string(test_case.input.cr));
    }
}

TEST_F(MetalVideoTexture, PqTransferToneMapsPeakBelowOne)
{
    // The peak the stream is mastered to lands on SDR white and no higher, and
    // it stays grey: tone mapping on the brightest channel must not tint a
    // neutral highlight.
    for (const double nits : { 1000.0, 4000.0, 10000.0 }) {
        const auto result = ConvertTenBit(PqGrey(nits));
        ASSERT_TRUE(result.ok);
        EXPECT_EQ(result.pixel[2], 255) << nits << " nits";
        EXPECT_EQ(result.pixel[1], 255) << nits << " nits";
        EXPECT_EQ(result.pixel[0], 255) << nits << " nits";
    }

    // Everything below it is ordered: a brighter source is never a darker
    // picture, and none of them reaches white before the peak does.
    // The roll-off squeezes the top of the range into the last few codes, so
    // the sequence is non-decreasing throughout and still short of white well
    // below the peak.
    int previous = -1;
    for (const double nits : { 5.0, 50.0, 100.0, 203.0, 400.0, 700.0, 900.0 }) {
        const auto result = ConvertTenBit(PqGrey(nits));
        ASSERT_TRUE(result.ok);
        EXPECT_GE(static_cast<int>(result.pixel[1]), previous) << nits << " nits";
        if (nits <= 400.0) EXPECT_LT(result.pixel[1], 255) << nits << " nits is below the peak";
        previous = result.pixel[1];
    }

    // Reference white is close to SDR white and not at it: mapping a 1000 nit
    // peak onto 203 nits of SDR white leaves its diffuse white a little under.
    const auto white = ConvertTenBit(PqGrey(203.0));
    ASSERT_TRUE(white.ok);
    EXPECT_GE(white.pixel[1], 220);
    EXPECT_LT(white.pixel[1], 250);

    // A source that states a lower peak is compressed less: 400 nits is white.
    const auto stated = ConvertTenBit(PqGrey(400.0), 400);
    ASSERT_TRUE(stated.ok);
    EXPECT_EQ(stated.pixel[1], 255);
    const auto assumed = ConvertTenBit(PqGrey(400.0));
    ASSERT_TRUE(assumed.ok);
    EXPECT_LT(assumed.pixel[1], 255);
}

TEST_F(MetalVideoTexture, HlgTransferToneMaps)
{
    // 0.75 is reference white and comes out nearly as SDR white; the top of the
    // curve is the 1000 nit peak and lands on it; a mid-grey is darker than both.
    const auto reference_white = ConvertTenBit(HlgGrey(0.75));
    const auto peak            = ConvertTenBit(HlgGrey(1.0));
    const auto mid             = ConvertTenBit(HlgGrey(0.5));
    ASSERT_TRUE(reference_white.ok && peak.ok && mid.ok);
    EXPECT_GE(reference_white.pixel[1], 220);
    EXPECT_LT(reference_white.pixel[1], 250);
    EXPECT_EQ(peak.pixel[1], 255);
    EXPECT_LT(mid.pixel[1], reference_white.pixel[1]);

    // The same codes are a different picture as PQ: the curve is read from the
    // frame's tag, not assumed.
    auto as_pq = HlgGrey(0.75);
    as_pq.transfer = ref::Transfer::Pq;
    const auto pq = ConvertTenBit(as_pq);
    ASSERT_TRUE(pq.ok);
    EXPECT_NE(pq.pixel[1], reference_white.pixel[1]);
}

TEST_F(MetalVideoTexture, SdrTenBitSkipsToneMap)
{
    // A 10-bit BT.709 picture is display-referred already: its codes decode to
    // the colour they stand for and nothing is compressed, so a bright grey that
    // an HDR curve would have rolled off is carried through untouched.
    ref::Input sdr;
    sdr.transfer      = ref::Transfer::Sdr;
    sdr.primaries     = ref::Primaries::Bt709;
    sdr.bt2020_matrix = false;
    sdr.y             = 700;
    const auto plain = ConvertTenBit(sdr);
    ASSERT_TRUE(plain.ok);
    const int expected = static_cast<int>(std::lround((700.0 - 64.0) / 876.0 * 255.0));
    EXPECT_NEAR(plain.pixel[1], expected, 2);
    EXPECT_NEAR(plain.pixel[2], expected, 2);
    EXPECT_NEAR(plain.pixel[0], expected, 2);

    // The decision is the transfer function's, not the bit depth's: the same
    // codes tagged PQ are tone mapped, so they come out differently.
    auto as_pq = sdr;
    as_pq.transfer      = ref::Transfer::Pq;
    as_pq.primaries     = ref::Primaries::Bt2020;
    as_pq.bt2020_matrix = true;
    const auto mapped = ConvertTenBit(as_pq);
    ASSERT_TRUE(mapped.ok);
    EXPECT_GT(std::abs(static_cast<int>(mapped.pixel[1]) - static_cast<int>(plain.pixel[1])), 20);

    // Colour is the matrix alone, with no curve in between.
    ref::Input coloured = sdr;
    coloured.y  = 480;
    coloured.cb = 380;
    coloured.cr = 640;
    const auto pixel = ConvertTenBit(coloured);
    ASSERT_TRUE(pixel.ok);
    ExpectMatchesReference(pixel.pixel, coloured, "SDR colour", 2);
}

TEST_F(MetalVideoTexture, TenBitForcesConvertedPathEvenWhenPlanesAreDemanded)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    FakeVideoSource::TenBitTags tags;
    tags.transfer  = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    tags.primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
    source->produceTenBit(static_cast<uint16_t>(ref::PqLumaCode(300.0)), 512, 512, tags);

    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    // The renderer found a material that samples planes directly and asked for
    // nothing else. A 10-bit frame cannot be sampled that way.
    textures->setDemand({ { "video", metal::VideoConsumerDemand { true, false } } });
    ASSERT_TRUE(RunFrame(&error)) << error;

    EXPECT_EQ(textures->conversionsEncodedForTests(), 1u);
    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Yuv10Converted);
    EXPECT_NE(textures->texture("video"), nil) << "the one image every consumer samples";
    EXPECT_FALSE(textures->planes("video").valid()) << "16-bit planes are not offered to author shaders";

    uint32_t width = 0, height = 0;
    EXPECT_TRUE(textures->frameSize("video", &width, &height));
    EXPECT_EQ(width, 16u);

    // A demand change does not re-import the same generation: the demand was
    // never what decided the path.
    textures->setDemand({ { "video", metal::VideoConsumerDemand { false, true } } });
    ASSERT_TRUE(RunFrame(&error)) << error;
    EXPECT_EQ(textures->conversionsEncodedForTests(), 1u);
    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Yuv10Converted);
}

TEST_F(MetalVideoTexture, EightBitVideoNeverBuildsTheTenBitPipeline)
{
    // The 10-bit kernel is a second compile that only a 10-bit video asks for.
    // An 8-bit scene, with either of its paths, must not have paid for it.
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(126, 128, 160);
    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    ASSERT_TRUE(RunFrame(&error)) << error;
    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Nv12Converted);
    EXPECT_FALSE(textures->tenBitPipelineBuiltForTests());

    auto bgra = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_32BGRA);
    bgra->produce(20, 140, 220);
    metal::MetalVideoTextures other;
    other.configure(device);
    ASSERT_TRUE(other.prepareForTests("video", bgra, &error)) << error;
    id<MTLCommandBuffer> command = [queue commandBuffer];
    ASSERT_TRUE(other.beginFrame(scene, command, &error)) << error;
    [command commit];
    [command waitUntilCompleted];
    EXPECT_FALSE(other.tenBitPipelineBuiltForTests());

    // And a 10-bit video is what builds it, when the graph is prepared and not
    // on the first draw.
    metal::MetalVideoTextures ten;
    ten.configure(device);
    auto ten_source = std::make_shared<FakeVideoSource>(16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    FakeVideoSource::TenBitTags tags;
    ten_source->produceTenBit(512, 512, 512, tags);
    EXPECT_FALSE(ten.tenBitPipelineBuiltForTests());
    ASSERT_TRUE(ten.prepareForTests("video", ten_source, &error)) << error;
    EXPECT_TRUE(ten.tenBitPipelineBuiltForTests());
}

TEST_F(MetalVideoTexture, TenBitPeakComesFromTheStreamsOwnMetadata)
{
    const auto input = PqGrey(400.0);
    // No metadata: 1000 nits is assumed.
    const auto assumed = ConvertTenBit(input);
    // A content light level of 400 nits: this very light is the peak.
    const auto content = ConvertTenBit(input, 400, 0);
    // A mastering display of 4000 nits: compressed harder than the assumption.
    const auto mastering = ConvertTenBit(input, 0, 4000);
    // Both stated: the content light level, which is what the picture really
    // reaches, wins over the display it was graded on.
    const auto both = ConvertTenBit(input, 400, 4000);
    ASSERT_TRUE(assumed.ok && content.ok && mastering.ok && both.ok);

    auto with_peak = [&](double peak) {
        auto copy      = input;
        copy.peak_nits = peak;
        return copy;
    };
    ExpectMatchesReference(assumed.pixel, input, "assumed 1000 nits");
    ExpectMatchesReference(content.pixel, with_peak(400.0), "content light level 400");
    ExpectMatchesReference(mastering.pixel, with_peak(4000.0), "mastering display 4000");
    ExpectMatchesReference(both.pixel, with_peak(400.0), "both stated");
    EXPECT_GT(content.pixel[1], assumed.pixel[1]);
    EXPECT_LT(mastering.pixel[1], assumed.pixel[1]);
}

TEST_F(MetalVideoTexture, TenBitFramesApplyEveryDisplayOrientationToTheirPixels)
{
    for (const auto& orientation : video::testing_media::kOrientations) {
        SCOPED_TRACE(orientation.name);
        auto source = std::make_shared<FakeVideoSource>(16, 8, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);
        source->produceTenBitQuadrants();
        source->setDisplayMatrix(orientation.matrix());
        metal::MetalVideoTextures converter;
        converter.configure(device);
        std::string error;
        ASSERT_TRUE(converter.prepareForTests("video", source, &error)) << error;
        auto command = [queue commandBuffer];
        ASSERT_TRUE(converter.beginFrame(scene, command, &error)) << error;
        [command commit];
        [command waitUntilCompleted];
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

TEST_F(MetalVideoTexture, AFormatChangeFromEightToTenBitSwitchesPathWithoutLosingTheTexture)
{
    auto source = std::make_shared<FakeVideoSource>(16, 16);
    source->produce(126, 128, 160);
    std::string error;
    ASSERT_TRUE(textures->prepareForTests("video", source, &error)) << error;
    ASSERT_TRUE(RunFrame(&error)) << error;
    ASSERT_EQ(textures->path("video"), metal::VideoFramePath::Nv12Converted);

    source->resize(16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    FakeVideoSource::TenBitTags tags;
    tags.transfer  = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    tags.primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
    source->produceTenBit(static_cast<uint16_t>(ref::PqLumaCode(100.0)), 512, 512, tags);
    ASSERT_TRUE(RunFrame(&error)) << error;
    EXPECT_EQ(textures->path("video"), metal::VideoFramePath::Yuv10Converted);
    EXPECT_NE(textures->texture("video"), nil);
    EXPECT_FALSE(textures->planes("video").valid());
}

TEST(SceneVideoPath, EveryPathHasItsOwnStableName)
{
    // These strings reach the settings panel and the diagnostics report through
    // the bridge, whose own table (`SceneVideoPath::name`) must agree with them.
    const std::pair<SceneVideoPath, const char*> names[] = {
        { SceneVideoPath::None, "none" },
        { SceneVideoPath::Bgra, "bgra" },
        { SceneVideoPath::Nv12Direct, "nv12_direct" },
        { SceneVideoPath::Nv12Converted, "nv12_converted" },
        { SceneVideoPath::Nv12Mixed, "nv12_mixed" },
        { SceneVideoPath::Nv12ConvertedPreparing, "nv12_converted_preparing" },
        { SceneVideoPath::Yuv10Converted, "yuv10_converted" },
    };
    for (std::size_t index = 0; index < std::size(names); ++index) {
        EXPECT_STREQ(SceneVideoPathName(names[index].first), names[index].second);
        // The numbers are the bridge's wire values: appended, never reordered.
        EXPECT_EQ(static_cast<std::size_t>(names[index].first), index) << names[index].second;
    }
}
