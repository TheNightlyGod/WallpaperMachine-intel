// MetalFX upscaling of a scene drawn below full resolution, as the native Metal renderer
// composes it, seen through the synthetic scene harness: one sharp-edged picture is drawn at
// full resolution, at a lowered render scale stretched the old way, and at the same scale
// brought back by MetalFX, and the three pictures are compared.
//
// Every GPU image is private to the process; no window or drawable is shown.

#include <gtest/gtest.h>

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include "MetalRender/MetalRender.hpp"
#include "MetalRender/MetalUpscaling.hpp"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <string>

namespace
{
using namespace we_test;

constexpr uint32_t kCanvasWidth  = 512;
constexpr uint32_t kCanvasHeight = 288;

/// Whether this device has MetalFX's spatial scaler, the one `MetalUpscaler` checks for. A
/// Metal device without it composes the old way, so a test that needs MetalFX skips.
bool MetalFxAvailable()
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device != nil && [MTLFXSpatialScalerDescriptor supportsDevice:device];
}

#define WE_SKIP_WITHOUT_METALFX()                                                                  \
    do {                                                                                           \
        WE_SKIP_WITHOUT_METAL();                                                                   \
        if (!MetalFxAvailable()) GTEST_SKIP() << "no MetalFX spatial scaler on this device";       \
    } while (false)

/// Restores the process-wide switch whatever the test does.
class Upscaling {
public:
    explicit Upscaling(bool enabled) : previous_(wallpaper::metal::MetalUpscalingEnabled())
    {
        wallpaper::metal::SetMetalUpscalingEnabled(enabled);
    }
    ~Upscaling() { wallpaper::metal::SetMetalUpscalingEnabled(previous_); }
    Upscaling(const Upscaling&)            = delete;
    Upscaling& operator=(const Upscaling&) = delete;

private:
    bool previous_;
};

// Hard-edged rings and bars at a size the canvas holds exactly: what a lowered resolution
// blurs first, and what an upscaler is for.
Image Edges()
{
    Image image { kCanvasWidth, kCanvasHeight, std::vector<uint8_t>(kCanvasWidth * kCanvasHeight * 4) };
    for (uint32_t y = 0; y < kCanvasHeight; ++y) {
        for (uint32_t x = 0; x < kCanvasWidth; ++x) {
            const double dx = x + 0.5 - kCanvasWidth / 2.0, dy = y + 0.5 - kCanvasHeight / 2.0;
            const bool   ring = (static_cast<int>(std::sqrt(dx * dx + dy * dy)) / 9) % 2 == 0;
            const bool   bar  = (x / 23) % 2 == 0;
            const uint8_t value = ring != bar ? 230 : 25;
            image.Set(x, y, { value, static_cast<uint8_t>(255 - value), 128, 255 });
        }
    }
    return image;
}

void MakeEdgeScene(ScenePackage& package)
{
    TexOptions smooth;
    smooth.point_sampling = false;
    const std::string texture = package.AddTexture("edges", Edges(), smooth);
    ImageLayer layer;
    layer.model  = package.AddImageModel("edges", texture);
    layer.origin = { kCanvasWidth / 2.0f, kCanvasHeight / 2.0f, 0.0f };
    layer.size   = { static_cast<float>(kCanvasWidth), static_cast<float>(kCanvasHeight) };
    SceneGeneral general;
    general.canvas_width  = static_cast<int>(kCanvasWidth);
    general.canvas_height = static_cast<int>(kCanvasHeight);
    package.SetProject();
    package.SetScene(SceneJson(general, { ImageLayerJson(layer) }));
}

struct Drawn {
    Image    picture;
    uint64_t bytes { 0 };
};

/// The scene at `scale`, with upscaling on or off, after a few frames.
Drawn Draw(double scale, bool upscaling)
{
    const Upscaling switched(upscaling);
    ScenePackage    package;
    MakeEdgeScene(package);
    GpuSceneOptions options;
    options.width        = kCanvasWidth;
    options.height       = kCanvasHeight;
    options.render_scale = scale;
    GpuScene scene(package, options);
    EXPECT_TRUE(scene.ok()) << scene.error();
    if (!scene.ok()) return {};
    Drawn drawn;
    drawn.picture = scene.Run(3);
    drawn.bytes   = scene.renderer().RenderTargetBytesForTests();
    return drawn;
}

/// Mean absolute difference over every channel but alpha, in 0..255.
double MeanError(const Image& a, const Image& b)
{
    if (a.width != b.width || a.height != b.height || a.empty()) return 255.0;
    double sum = 0.0;
    for (uint32_t y = 0; y < a.height; ++y) {
        for (uint32_t x = 0; x < a.width; ++x) {
            const Rgba p = a.At(x, y), q = b.At(x, y);
            for (int c = 0; c < 3; ++c) sum += std::abs(int(p[c]) - int(q[c]));
        }
    }
    return sum / (3.0 * a.width * a.height);
}

TEST(MetalFxUpscale, BringsALoweredSceneCloserToItsFullResolutionPicture)
{
    WE_SKIP_WITHOUT_METALFX();
    const Drawn native    = Draw(1.0, false);
    const Drawn stretched = Draw(0.5, false);
    const Drawn upscaled  = Draw(0.5, true);
    ASSERT_FALSE(native.picture.empty());
    ASSERT_FALSE(stretched.picture.empty());
    ASSERT_FALSE(upscaled.picture.empty());
    KeepPicture("metalfx_native", native.picture);
    KeepPicture("metalfx_stretched", stretched.picture);
    KeepPicture("metalfx_upscaled", upscaled.picture);

    // The picture keeps the display's size whatever drew it.
    EXPECT_EQ(upscaled.picture.width, native.picture.width);
    EXPECT_EQ(upscaled.picture.height, native.picture.height);
    // MetalFX ran: the picture is not the bilinear stretch.
    EXPECT_GT(CountDifferingPixels(upscaled.picture, stretched.picture, 2), 0u);

    const double stretched_error = MeanError(stretched.picture, native.picture);
    const double upscaled_error  = MeanError(upscaled.picture, native.picture);
    EXPECT_LT(upscaled_error, stretched_error)
        << "stretched " << stretched_error << ", upscaled " << upscaled_error;
}

TEST(MetalFxUpscale, KeepsOneFullSizeImageOnlyWhileItIsUsed)
{
    WE_SKIP_WITHOUT_METALFX();
    const Drawn stretched = Draw(0.5, false);
    const Drawn upscaled  = Draw(0.5, true);
    ASSERT_GT(stretched.bytes, 0u);
    // One image the size of the full-resolution output, 8-bit: about four bytes a pixel.
    const uint64_t full_size = uint64_t(kCanvasWidth) * kCanvasHeight * 4;
    EXPECT_GE(upscaled.bytes, stretched.bytes + full_size);
    EXPECT_LE(upscaled.bytes, stretched.bytes + 2 * full_size);
}

TEST(MetalFxUpscale, LetsTheImageGoOnTheFirstFrameAfterItIsTurnedOff)
{
    WE_SKIP_WITHOUT_METALFX();
    const Upscaling switched(true);
    ScenePackage    package;
    MakeEdgeScene(package);
    GpuSceneOptions options;
    options.width        = kCanvasWidth;
    options.height       = kCanvasHeight;
    options.render_scale = 0.5;
    GpuScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const uint64_t full_size = uint64_t(kCanvasWidth) * kCanvasHeight * 4;

    ASSERT_FALSE(scene.Run(3).empty());
    const uint64_t on = scene.renderer().RenderTargetBytesForTests();

    // The same scene, without being rebuilt: the first drawn frame lets the image go, before
    // any poster is composed.
    wallpaper::metal::SetMetalUpscalingEnabled(false);
    ASSERT_TRUE(scene.Step(1)) << scene.error();
    const uint64_t off = scene.renderer().RenderTargetBytesForTests();
    EXPECT_GE(on, off + full_size);

    // And turning it back on makes it again.
    wallpaper::metal::SetMetalUpscalingEnabled(true);
    ASSERT_TRUE(scene.Step(1)) << scene.error();
    EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(), on);
}

TEST(MetalFxUpscale, AGpuWithoutTheScalerComposesTheStretchAndHoldsNothingMore)
{
    WE_SKIP_WITHOUT_METAL();
    const Drawn stretched = Draw(0.5, false);
    wallpaper::metal::SetMetalUpscalerUnsupportedForTests(true);
    const Drawn refused = Draw(0.5, true);
    wallpaper::metal::SetMetalUpscalerUnsupportedForTests(false);
    ASSERT_FALSE(stretched.picture.empty());
    EXPECT_TRUE(ExpectSamePicture(refused.picture, stretched.picture));
    EXPECT_EQ(refused.bytes, stretched.bytes);
}

TEST(MetalFxUpscale, ChangesNothingAtFullResolution)
{
    WE_SKIP_WITHOUT_METAL();
    const Drawn off = Draw(1.0, false);
    const Drawn on  = Draw(1.0, true);
    ASSERT_FALSE(off.picture.empty());
    EXPECT_TRUE(ExpectSamePicture(on.picture, off.picture));
    EXPECT_EQ(on.bytes, off.bytes);
}

} // namespace
