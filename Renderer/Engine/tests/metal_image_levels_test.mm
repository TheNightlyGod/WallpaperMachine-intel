// A parsed picture's levels come from the wallpaper's file, so they may claim any size: the
// texture made for them holds only the levels its own size allows, each written inside its own
// extent, and a level shorter than the region it fills is refused rather than read past its end.
#include "support/gpu_scene.hpp"

#include "Scene/MetalRender/MetalImageLevels.hpp"
#include "Scene/MetalRender/MetalSharedImages.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

using wallpaper::Image;
using wallpaper::ImageData;
using wallpaper::metal::MakeImageTexture;
using wallpaper::metal::SharedImageCache;
using wallpaper::metal::SharedImageRequest;

namespace
{

// A level of `width` x `height` RGBA pixels, every byte `mark`, in a buffer of `capacity` bytes
// (at least the pixels) of which `size` are claimed.
ImageData Level(int width, int height, uint8_t mark, long capacity = -1, long size = -1)
{
    const long pixels = static_cast<long>(width) * height * 4;
    if (capacity < 0) capacity = pixels;
    auto* bytes = new uint8_t[static_cast<std::size_t>(capacity)];
    std::memset(bytes, mark, static_cast<std::size_t>(capacity));
    ImageData level;
    level.width  = width;
    level.height = height;
    level.size   = size < 0 ? pixels : size;
    level.data   = wallpaper::ImageDataPtr(bytes, [](uint8_t* p) { delete[] p; });
    return level;
}

template <class... Levels> Image::Slot SlotOf(Levels... levels)
{
    Image::Slot slot;
    (slot.mipmaps.push_back(std::move(levels)), ...);
    slot.width  = slot.mipmaps.front().width;
    slot.height = slot.mipmaps.front().height;
    return slot;
}

// The bytes of `level` of an RGBA8 texture.
std::vector<uint8_t> Pixels(id<MTLTexture> texture, NSUInteger level)
{
    const NSUInteger     width  = std::max<NSUInteger>(1, texture.width >> level);
    const NSUInteger     height = std::max<NSUInteger>(1, texture.height >> level);
    std::vector<uint8_t> out(width * height * 4, 0);
    [texture getBytes:out.data()
          bytesPerRow:width * 4
           fromRegion:MTLRegionMake2D(0, 0, width, height)
          mipmapLevel:level];
    return out;
}

bool AllEqual(const std::vector<uint8_t>& bytes, uint8_t mark)
{
    return std::all_of(bytes.begin(), bytes.end(), [mark](uint8_t b) { return b == mark; });
}

class MetalImageLevels : public ::testing::Test {
protected:
    void SetUp() override
    {
        WE_SKIP_WITHOUT_METAL();
        device = MTLCreateSystemDefaultDevice();
        ASSERT_NE(device, nil);
    }
    id<MTLDevice> device { nil };
};

} // namespace

TEST_F(MetalImageLevels, AnHonestChainFillsEveryLevel)
{
    const Image::Slot slot = SlotOf(Level(4, 4, 1), Level(2, 2, 2), Level(1, 1, 3));
    id<MTLTexture>    texture = MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, slot, 4, 0);
    ASSERT_NE(texture, nil);
    EXPECT_EQ(texture.mipmapLevelCount, 3u);
    for (NSUInteger level = 0; level < 3; ++level) {
        EXPECT_TRUE(AllEqual(Pixels(texture, level), static_cast<uint8_t>(level + 1))) << "level " << level;
    }
}

TEST_F(MetalImageLevels, ALevelShorterThanItsPixelsIsRefused)
{
    // The buffer really holds the pixels, so the test itself never reads past it; the level
    // claims a quarter of them, as a file can.
    const Image::Slot slot = SlotOf(Level(4, 4, 7, 64, 16));
    EXPECT_EQ(MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, slot, 4, 0), nil);
}

TEST_F(MetalImageLevels, ALaterLevelShorterThanItsPixelsIsRefused)
{
    const Image::Slot slot = SlotOf(Level(4, 4, 1), Level(2, 2, 2, 16, 4));
    EXPECT_EQ(MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, slot, 4, 0), nil);
}

TEST_F(MetalImageLevels, ALevelLargerThanItsPlaceInTheChainFillsOnlyItsOwnExtent)
{
    // Level 1 of a 4x4 texture is 2x2; the file says 4x4.
    const Image::Slot slot = SlotOf(Level(4, 4, 1), Level(4, 4, 2));
    id<MTLTexture>    texture = MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, slot, 4, 0);
    ASSERT_NE(texture, nil);
    ASSERT_EQ(texture.mipmapLevelCount, 2u);
    EXPECT_TRUE(AllEqual(Pixels(texture, 0), 1));
    EXPECT_TRUE(AllEqual(Pixels(texture, 1), 2));
}

TEST_F(MetalImageLevels, AChainLongerThanTheTextureAllowsIsCut)
{
    // A 2x2 texture holds two levels, 2x2 and 1x1.
    const Image::Slot slot = SlotOf(Level(2, 2, 1), Level(1, 1, 2), Level(1, 1, 3), Level(1, 1, 4));
    EXPECT_EQ(wallpaper::metal::ImageTextureLevels(slot.mipmaps.size(), 2, 2), 2u);
    id<MTLTexture> texture = MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, slot, 4, 0);
    ASSERT_NE(texture, nil);
    EXPECT_EQ(texture.mipmapLevelCount, 2u);
    EXPECT_TRUE(AllEqual(Pixels(texture, 1), 2));
}

TEST_F(MetalImageLevels, AShortBlockLevelIsRefused)
{
    if (! device.supportsBCTextureCompression) GTEST_SKIP() << "no BC textures on this device";
    // An 8x8 BC1 level is four blocks of eight bytes; this one claims two.
    const Image::Slot slot = SlotOf(Level(8, 8, 0, 256, 16));
    EXPECT_EQ(MakeImageTexture(device, MTLPixelFormatBC1_RGBA, slot, 0, 8), nil);
}

TEST_F(MetalImageLevels, ABlockLevelThatStopsInsideAPartialBlockIsSkipped)
{
    if (! device.supportsBCTextureCompression) GTEST_SKIP() << "no BC textures on this device";
    // Level 1 of an 8x8 texture is 4x4, one block; a 2x2 region inside it cannot be written as
    // blocks. The level is left as it is and the texture still holds level 0.
    const Image::Slot slot = SlotOf(Level(8, 8, 0, 256, 32), Level(2, 2, 0xab, 64, 8));
    id<MTLTexture>    texture = MakeImageTexture(device, MTLPixelFormatBC1_RGBA, slot, 0, 8);
    ASSERT_NE(texture, nil);
    EXPECT_EQ(texture.mipmapLevelCount, 2u);
    // Level 1 is one block: none of its eight bytes came from the skipped level.
    std::array<uint8_t, 8> block {};
    [texture getBytes:block.data() bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:1];
    EXPECT_FALSE(std::all_of(block.begin(), block.end(), [](uint8_t b) { return b == 0xab; }));
}

TEST_F(MetalImageLevels, ARefusedUploadLeavesTheTextureAsItWas)
{
    // A runtime picture is written into a texture that may already be shown. When a later level
    // is too short, nothing is written: not even the levels before it.
    const Image::Slot first = SlotOf(Level(4, 4, 1), Level(2, 2, 2));
    id<MTLTexture>    texture = MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, first, 4, 0);
    ASSERT_NE(texture, nil);
    const Image::Slot short_later = SlotOf(Level(4, 4, 7), Level(2, 2, 8, 16, 4));
    EXPECT_FALSE(wallpaper::metal::UploadImageLevels(texture, short_later, 4, 0));
    EXPECT_TRUE(AllEqual(Pixels(texture, 0), 1));
    EXPECT_TRUE(AllEqual(Pixels(texture, 1), 2));
}

TEST_F(MetalImageLevels, ASecondDisplayNeverReadsALevelBackPastItsExtent)
{
    // A display importing a picture another one holds reads the held texture back to compare
    // it with its own bytes. A level the upload clipped to its extent cannot be compared at
    // the size the file claims, which lies outside the level: the picture is uploaded again.
    const Image::Slot  slot = SlotOf(Level(4, 4, 1), Level(4, 4, 2));
    SharedImageRequest request;
    request.device          = device;
    request.name            = "metal-image-levels/overlong";
    request.format          = MTLPixelFormatRGBA8Unorm;
    request.slot            = &slot;
    request.bytes_per_pixel = 4;
    const auto upload = [&] { return MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, slot, 4, 0); };
    id<MTLTexture> first = SharedImageCache::shared().import(request, upload);
    ASSERT_NE(first, nil);
    const uint64_t uploads  = SharedImageCache::shared().uploads();
    const uint64_t readback = SharedImageCache::shared().levelsReadBack();
    id<MTLTexture> second   = SharedImageCache::shared().import(request, upload);
    ASSERT_NE(second, nil);
    EXPECT_EQ(SharedImageCache::shared().uploads(), uploads + 1);
    // Level 0 was compared; level 1, which the file claims is 4x4, was never read back.
    EXPECT_EQ(SharedImageCache::shared().levelsReadBack(), readback + 1);
    EXPECT_TRUE(AllEqual(Pixels(second, 1), 2));

    // An honest chain is shared as before.
    const Image::Slot  honest = SlotOf(Level(4, 4, 3), Level(2, 2, 4));
    SharedImageRequest same   = request;
    same.name                 = "metal-image-levels/honest";
    same.slot                 = &honest;
    const auto upload_honest  = [&] { return MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, honest, 4, 0); };
    id<MTLTexture> kept       = SharedImageCache::shared().import(same, upload_honest);
    ASSERT_NE(kept, nil);
    const uint64_t before = SharedImageCache::shared().uploads();
    EXPECT_EQ(SharedImageCache::shared().import(same, upload_honest), kept);
    EXPECT_EQ(SharedImageCache::shared().uploads(), before);
}

namespace
{
// Leaves the picture-optimization switch on whatever a test does to it.
struct OptimizationOnAtExit {
    ~OptimizationOnAtExit() { SharedImageCache::setOptimizationForTests(true); }
};

// Waits for the work queued on `queue`, so the pictures a test made die with it: a command
// buffer holds what it works on until it has run, and the tests after this one count the
// pictures alive in the process.
void Drain(id<MTLCommandQueue> queue)
{
    id<MTLCommandBuffer> fence = [queue commandBuffer];
    [fence commit];
    [fence waitUntilCompleted];
}
} // namespace

TEST_F(MetalImageLevels, ANewUploadIsOptimizedForSamplingOnceAndStillComparesEqual)
{
    // The CPU writes a picture in its own layout, which the GPU reads uncompressed. A new upload
    // is rearranged for sampling once, on the renderer's queue; the bytes stay what was written,
    // so a second display comparing its own bytes with them still finds the picture.
    OptimizationOnAtExit restore;
    SharedImageCache::setOptimizationForTests(true);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    const Image::Slot   slot  = SlotOf(Level(64, 64, 9), Level(32, 32, 10));
    SharedImageRequest  request;
    request.device          = device;
    request.name            = "metal-image-levels/optimized";
    request.format          = MTLPixelFormatRGBA8Unorm;
    request.slot            = &slot;
    request.bytes_per_pixel = 4;
    request.queue           = queue;
    const auto upload = [&] { return MakeImageTexture(device, MTLPixelFormatRGBA8Unorm, slot, 4, 0); };

    const uint64_t optimized = SharedImageCache::shared().optimized();
    id<MTLTexture> first     = SharedImageCache::shared().import(request, upload);
    ASSERT_NE(first, nil);
    EXPECT_EQ(SharedImageCache::shared().optimized(), optimized + 1) << "the new upload was left as written";

    const uint64_t uploads = SharedImageCache::shared().uploads();
    EXPECT_EQ(SharedImageCache::shared().import(request, upload), first)
        << "the optimized picture no longer compared equal to the same bytes";
    EXPECT_EQ(SharedImageCache::shared().uploads(), uploads);
    EXPECT_EQ(SharedImageCache::shared().optimized(), optimized + 1) << "a shared picture was optimized again";
    EXPECT_TRUE(AllEqual(Pixels(first, 0), 9));
    EXPECT_TRUE(AllEqual(Pixels(first, 1), 10));
    Drain(queue);
}

TEST_F(MetalImageLevels, OnlyAPlainPictureUploadedWithAQueueAndTheSwitchOnIsOptimized)
{
    OptimizationOnAtExit restore;
    SharedImageCache::setOptimizationForTests(true);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    const auto import = [&](const std::string& name, MTLPixelFormat format, const Image::Slot& slot,
                            uint32_t bytes_per_pixel, uint32_t block_bytes, id<MTLCommandQueue> on) {
        SharedImageRequest request;
        request.device          = device;
        request.name            = name;
        request.format          = format;
        request.slot            = &slot;
        request.bytes_per_pixel = bytes_per_pixel;
        request.block_bytes     = block_bytes;
        request.queue           = on;
        return SharedImageCache::shared().import(request, [&] {
            return MakeImageTexture(device, format, slot, bytes_per_pixel, block_bytes);
        });
    };
    const Image::Slot plain  = SlotOf(Level(16, 16, 3));
    const uint64_t    before = SharedImageCache::shared().optimized();

    // No queue: a caller with nowhere to queue the work leaves the picture as written.
    ASSERT_NE(import("metal-image-levels/no-queue", MTLPixelFormatRGBA8Unorm, plain, 4, 0, nil), nil);
    EXPECT_EQ(SharedImageCache::shared().optimized(), before);

    // The switch off (`WALLPAPER_MACHINE_OPTIMIZE_IMAGES=0`).
    SharedImageCache::setOptimizationForTests(false);
    ASSERT_NE(import("metal-image-levels/switched-off", MTLPixelFormatRGBA8Unorm, plain, 4, 0, queue), nil);
    EXPECT_EQ(SharedImageCache::shared().optimized(), before);
    SharedImageCache::setOptimizationForTests(true);

    // Block-compressed blocks are compressed already.
    if (device.supportsBCTextureCompression) {
        const Image::Slot blocks = SlotOf(Level(8, 8, 0, 32, 32));
        ASSERT_NE(import("metal-image-levels/blocks", MTLPixelFormatBC1_RGBA, blocks, 0, 8, queue), nil);
        EXPECT_EQ(SharedImageCache::shared().optimized(), before);
    }

    ASSERT_NE(import("metal-image-levels/plain", MTLPixelFormatRGBA8Unorm, plain, 4, 0, queue), nil);
    EXPECT_EQ(SharedImageCache::shared().optimized(), before + 1);
    Drain(queue);
}
