// Decoded frames must reach Metal, with hardware-capable decoders kept eligible.
// No window, audio device or private media is needed for the generated cases.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>

#include <gtest/gtest.h>

extern "C" {
#include <libavutil/frame.h>
}

#include <array>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <vector>
#include <unistd.h>

#include "Image.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Video/FfmpegVideoTextureSource.hpp"
#include "synthetic_video.hpp"

namespace {
using namespace wallpaper;
using namespace wallpaper::video;

struct OwnedFrame {
    VideoTextureFrame value {};
    ~OwnedFrame() { ReleaseAppleVideoFrame(&value); }
};
using Lease = std::unique_ptr<void, decltype(&ReleaseAppleVideoFrameLease)>;
using Pixel = std::array<uint8_t, 4>;

class SoftwareVideoFrame : public ::testing::TestWithParam<AVPixelFormat> {};

TEST_P(SoftwareVideoFrame, ImportedPixelsOutliveTheDecoderWithoutAnotherConversion) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        ASSERT_NE(device, nil);
        const auto free_frame = [](AVFrame* frame) { av_frame_free(&frame); };
        std::unique_ptr<AVFrame, decltype(free_frame)> decoded(av_frame_alloc(), free_frame);
        ASSERT_NE(decoded, nullptr);
        // Not a cache-line-sized row: exercise the decoder and IOSurface strides.
        constexpr int width = 18, height = 10;
        decoded->width = width;
        decoded->height = height;
        decoded->format = GetParam();
        decoded->colorspace = AVCOL_SPC_BT709;
        decoded->color_range = GetParam() == AV_PIX_FMT_YUVJ420P ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
        ASSERT_GE(av_frame_get_buffer(decoded.get(), 32), 0);

        std::vector<Pixel> expected(width * height);
        YuvColorDescription description;
        description.matrix = YuvMatrix::Bt709;
        description.range = GetParam() == AV_PIX_FMT_YUVJ420P ? YuvRange::Full : YuvRange::Limited;
        const auto params = MakeYuvColorParams(description);
        for (int y = 0; y < height; ++y) {
            auto* row = decoded->data[0] + y * decoded->linesize[0];
            for (int x = 0; x < width; ++x) {
                if (GetParam() == AV_PIX_FMT_BGRA) {
                    const Pixel pixel {uint8_t(10 + x * 7), uint8_t(20 + y * 11), 150, 173};
                    std::memcpy(row + x * 4, pixel.data(), 4);
                    expected[y * width + x] = pixel;
                } else {
                    row[x] = uint8_t(40 + x * 5 + y * 3);
                    const auto rgb = ConvertYuvCodeToRgb8(params, row[x], 90, 180);
                    expected[y * width + x] = {rgb.blue, rgb.green, rgb.red, 255};
                }
            }
        }
        if (GetParam() != AV_PIX_FMT_BGRA) {
            for (int y = 0; y < height / 2; ++y) {
                auto* chroma = decoded->data[1] + y * decoded->linesize[1];
                for (int x = 0; x < width / 2; ++x) {
                    if (GetParam() == AV_PIX_FMT_NV12) {
                        chroma[x * 2] = 90;
                        chroma[x * 2 + 1] = 180;
                    } else {
                        chroma[x] = 90;
                        decoded->data[2][y * decoded->linesize[2] + x] = 180;
                    }
                }
            }
        }

        std::string error;
        OwnedFrame extracted;
        ASSERT_TRUE(ExtractAppleVideoFrame(decoded.get(), &extracted.value, &error)) << error;
        decoded.reset();
        const auto waits = AppleVideoConversionCpuWaits();
        void* destination = nullptr;
        Lease lease(CreateAppleVideoFrameLease(extracted.value, (__bridge void*)device, nullptr,
                                               &error, nullptr, &destination), ReleaseAppleVideoFrameLease);
        ASSERT_NE(lease, nullptr) << error;
        EXPECT_EQ(destination, nullptr) << "software output must import directly, not allocate a conversion target";
        EXPECT_EQ(AppleVideoConversionCpuWaits(), waits);
        ReleaseAppleVideoFrame(&extracted.value);
        id<MTLTexture> texture = (__bridge id<MTLTexture>)AppleVideoFrameLeaseTexture(lease.get());
        ASSERT_NE(texture, nil);
        std::vector<Pixel> actual(width * height);
        [texture getBytes:actual.data() bytesPerRow:width * 4
               fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        EXPECT_EQ(actual, expected);
    }
}

INSTANTIATE_TEST_SUITE_P(DecodedFormats, SoftwareVideoFrame,
    ::testing::Values(AV_PIX_FMT_BGRA, AV_PIX_FMT_NV12, AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P));

class VideoDecoderSelection : public ::testing::Test {
protected:
    void SetUp() override {
        static std::atomic<uint64_t> serial { 0 };
        root = std::filesystem::temp_directory_path() /
            ("owe-video-decoder-" + std::to_string(::getpid()) + "-" +
             std::to_string(serial.fetch_add(1)));
        std::filesystem::create_directories(root);
    }

    void TearDown() override {
        std::error_code error;
        std::filesystem::remove_all(root, error);
    }

    void CheckHardwareFrame(const std::filesystem::path& media,
                            std::optional<Pixel> expected = std::nullopt) {
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            ASSERT_NE(device, nil);
            std::string error;
            auto image = CreateVideoProjectImage(root, media.filename().string(), &error);
            ASSERT_NE(image, nullptr) << error;
            auto source = CreateVideoTextureSource(*image, &error);
            ASSERT_NE(source, nullptr) << error;
            ASSERT_TRUE(source->prime(&error)) << error;
            const auto frame = source->currentFrame();
            ASSERT_TRUE(frame.valid());
            EXPECT_NE(frame.io_surface, nullptr);
            EXPECT_TRUE(frame.pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                        frame.pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                << DescribeAppleVideoFrame(frame);
            Lease lease(CreateAppleVideoFrameLease(frame, (__bridge void*)device, nullptr, &error),
                        ReleaseAppleVideoFrameLease);
            ASSERT_NE(lease, nullptr) << error;
            source.reset();
            id<MTLTexture> texture = (__bridge id<MTLTexture>)AppleVideoFrameLeaseTexture(lease.get());
            ASSERT_NE(texture, nil);
            std::vector<Pixel> pixels(texture.width * texture.height);
            [texture getBytes:pixels.data() bytesPerRow:texture.width * 4
                   fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
            ASSERT_FALSE(pixels.empty());
            size_t visible = 0;
            for (const auto& pixel : pixels) {
                if (pixel[3] > 0 && (pixel[0] > 8 || pixel[1] > 8 || pixel[2] > 8)) ++visible;
                if (expected) {
                    for (size_t channel = 0; channel < pixel.size(); ++channel) {
                        EXPECT_LE(std::abs(int(pixel[channel]) - int((*expected)[channel])), 3);
                    }
                }
            }
            EXPECT_GT(visible, pixels.size() / 100);
        }
    }

    std::filesystem::path root;
};

TEST_F(VideoDecoderSelection, AnAv1FrameReachesMetalWhenTheDefaultDecoderIsSoftwareOnly) {
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
        GTEST_SKIP() << "this machine has no VideoToolbox AV1 hardware decoder";
    }
    // A virtual Mac (a hosted CI runner) reports its host's AV1 decoder, but a session
    // for it cannot be opened inside the guest, so there is no hardware path to test.
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device != nil && [device.name containsString:@"Paravirtual"]) {
            GTEST_SKIP() << "a virtual machine's GPU cannot open VideoToolbox AV1 sessions";
        }
    }
    // Original solid-red 64x64 media, encoded with standalone FFmpeg / SVT-AV1 4.2.0:
    // ffmpeg -f lavfi -i color=c=red:s=64x64:r=30 -frames:v 3 -pix_fmt yuv420p
    //   -c:v libsvtav1 -preset 10 -crf 20 -svtav1-params lp=1 -an -f ivf red-av1.ivf
    // Keep the 152-byte result here so tests require neither private assets nor an AV1 encoder.
    constexpr std::array<uint8_t, 152> media_bytes {{
        0x44, 0x4b, 0x49, 0x46, 0x00, 0x00, 0x20, 0x00, 0x41, 0x56, 0x30, 0x31,
        0x40, 0x00, 0x40, 0x00, 0x1e, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x27, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x00, 0x0a, 0x0b,
        0x02, 0x00, 0x00, 0x05, 0x15, 0x7f, 0xfc, 0x4a, 0xf9, 0x00, 0x40, 0x32,
        0x16, 0x10, 0x00, 0x93, 0x02, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xd4, 0xbd, 0x59, 0x61, 0xee, 0x73, 0x8f, 0xc1, 0xd3, 0x91, 0xd0, 0x28,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12,
        0x00, 0x32, 0x11, 0x28, 0x02, 0x00, 0x40, 0x00, 0x00, 0x35, 0x50, 0x00,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x9c, 0x10, 0x32, 0x11, 0x30, 0x02,
        0x00, 0x00, 0x00, 0x49, 0x6a, 0xa0, 0x00, 0x00, 0x02, 0x00, 0x03, 0x00,
        0x00, 0x9b, 0x70, 0x05, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x12, 0x00, 0x1a, 0x01, 0x98,
    }};
    const auto media = root / "red-av1.ivf";
    std::ofstream output(media, std::ios::binary);
    output.write(reinterpret_cast<const char*>(media_bytes.data()), media_bytes.size());
    output.close();
    ASSERT_TRUE(output.good());
    CheckHardwareFrame(media, Pixel { 0, 0, 255, 255 });
}

TEST_F(VideoDecoderSelection, AnAlreadyEligibleH264DecoderStillProducesAnImportedHardwareFrame) {
    const auto media = root / "h264.mp4";
    ASSERT_TRUE(testing_media::WriteSyntheticVideo(media, 1, "eligible-h264"));
    CheckHardwareFrame(media);
}

TEST_F(VideoDecoderSelection, ASoftwareOnlyCodecIsStillRejected) {
    const auto media = root / "red.ppm";
    std::ofstream output(media, std::ios::binary);
    output << "P6\n2 2\n255\n";
    constexpr std::array<uint8_t, 12> pixels { 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0 };
    output.write(reinterpret_cast<const char*>(pixels.data()), pixels.size());
    output.close();
    ASSERT_TRUE(output.good());
    std::string error;
    auto image = CreateVideoProjectImage(root, media.filename().string(), &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    EXPECT_FALSE(source->prime(&error));
    EXPECT_FALSE(error.empty());
    EXPECT_FALSE(source->currentFrame().valid());
}

// Opt-in corpus diagnostic; only opens the named file for reading.
TEST(AppleVideoFrame, LocalVideoImportsVisiblePixels) {
    const char* path = std::getenv("WE_TEST_VIDEO");
    if (path == nullptr || *path == '\0') GTEST_SKIP() << "WE_TEST_VIDEO names no local video";
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        ASSERT_NE(device, nil);
        const std::filesystem::path media(path);
        std::string error;
        auto image = CreateVideoProjectImage(media.parent_path(), media.filename().string(), &error);
        ASSERT_NE(image, nullptr) << error;
        auto source = CreateVideoTextureSource(*image, &error);
        ASSERT_NE(source, nullptr) << error;
        ASSERT_TRUE(source->prime(&error)) << error;
        const auto frame = source->currentFrame();
        std::cout << DescribeAppleVideoFrame(frame) << '\n';
        Lease lease(CreateAppleVideoFrameLease(frame, (__bridge void*)device, nullptr, &error),
                    ReleaseAppleVideoFrameLease);
        ASSERT_NE(lease, nullptr) << error;
        source.reset();
        id<MTLTexture> texture = (__bridge id<MTLTexture>)AppleVideoFrameLeaseTexture(lease.get());
        ASSERT_NE(texture, nil);
        std::vector<Pixel> pixels(texture.width * texture.height);
        [texture getBytes:pixels.data() bytesPerRow:texture.width * 4
               fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height) mipmapLevel:0];
        size_t visible = 0;
        for (const auto& pixel : pixels) {
            if (pixel[3] > 0 && (pixel[0] > 8 || pixel[1] > 8 || pixel[2] > 8)) ++visible;
        }
        std::cout << "visible pixels: " << visible << '/' << pixels.size() << '\n';
        EXPECT_GT(visible, pixels.size() / 100);
    }
}
} // namespace
