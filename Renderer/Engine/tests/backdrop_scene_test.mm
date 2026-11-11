// "Fit with blurred backdrop" as the native Metal renderer draws it, seen through the
// synthetic scene harness: a canvas-filling gradient is shown as Fit and as the new mode, and
// the pictures, the images the copy lives in, and the work a frame records are compared.
//
// Every GPU image is private to the process; no window or drawable is shown.

#include <gtest/gtest.h>

#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include "Core/RendererCounters.hpp"
#include "MetalRender/MetalRender.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <cstdint>
#include <string>

namespace
{
using namespace we_test;
using wallpaper::ComputeWallpaperScalingLayout;
using wallpaper::PixelRect;
using wallpaper::WallpaperScalingMode;

constexpr auto kFit     = WallpaperScalingMode::FIT;
constexpr auto kFill    = WallpaperScalingMode::FILL;
constexpr auto kBlurred = WallpaperScalingMode::FIT_BLURRED;

struct Case {
    const char* name;
    uint32_t    canvas_w, canvas_h;
    uint32_t    display_w, display_h;
    bool        mirrored { false };
};

// A picture 640x360 on a display 800x360 leaves bars left and right, on 640x480 above and
// below; a canvas of 1600x900 is longer than 1024 texels, so its copy takes the 8-bit step.
const Case kBarsLeftRight { "bars left and right", 640, 360, 800, 360 };
const Case kBarsAboveBelow { "bars above and below", 640, 360, 640, 480 };
const Case kMirrored { "mirrored", 640, 360, 800, 360, true };
const Case kLargeLeftRight { "large, bars left and right", 1600, 900, 1000, 400 };
const Case kLargeAboveBelow { "large, bars above and below", 1600, 900, 640, 480 };
const Case kExactFit { "exact fit", 1600, 900, 640, 360 };

// Each channel is a gradient the test knows: red across the picture, green down it, blue flat.
Image Gradient()
{
    Image image { 256, 144, std::vector<uint8_t>(256 * 144 * 4) };
    for (uint32_t y = 0; y < 144; ++y) {
        for (uint32_t x = 0; x < 256; ++x) {
            const double u = (x + 0.5) / 256.0, v = (y + 0.5) / 144.0;
            image.Set(x, y, { static_cast<uint8_t>(std::lround(100 + 120 * u)),
                              static_cast<uint8_t>(std::lround(100 + 120 * v)), 128, 255 });
        }
    }
    return image;
}

void MakeGradientScene(ScenePackage& package, const Case& c)
{
    TexOptions smooth;
    smooth.point_sampling = false;
    const std::string texture = package.AddTexture("gradient", Gradient(), smooth);
    ImageLayer layer;
    layer.model  = package.AddImageModel("gradient", texture);
    layer.origin = { c.canvas_w / 2.0f, c.canvas_h / 2.0f, 0.0f };
    layer.size   = { static_cast<float>(c.canvas_w), static_cast<float>(c.canvas_h) };
    SceneGeneral general;
    general.canvas_width  = static_cast<int>(c.canvas_w);
    general.canvas_height = static_cast<int>(c.canvas_h);
    package.SetProject();
    package.SetScene(SceneJson(general, { ImageLayerJson(layer) }));
}

GpuSceneOptions OptionsFor(const Case& c)
{
    GpuSceneOptions options;
    options.width  = c.display_w;
    options.height = c.display_h;
    return options;
}

wallpaper::WallpaperScalingLayout LayoutOf(const Case& c, WallpaperScalingMode mode, double factor = 1.0)
{
    return ComputeWallpaperScalingLayout(mode, c.canvas_w, c.canvas_h, c.display_w, c.display_h, 1.0, factor);
}

/// One scene, shown in `mode` (and at `factor`) for a few frames.
class Showing {
public:
    Showing(const Case& c, WallpaperScalingMode mode, double factor = 1.0, bool static_reuse = true) : c_(c)
    {
        MakeGradientScene(package_, c);
        GpuSceneOptions options    = OptionsFor(c);
        options.scene_optimization = static_reuse;
        scene_ = std::make_unique<GpuScene>(package_, options);
        if (!scene_->ok()) return;
        scene_->renderer().SetWallpaperHorizontalFlip(c.mirrored);
        scene_->renderer().SetWallpaperScalingMode(mode);
        scene_->renderer().SetWallpaperScalingFactor(factor);
    }
    GpuScene& scene() { return *scene_; }
    const Case& shape() const { return c_; }
    Image Picture(int frames = 3)
    {
        EXPECT_TRUE(scene_->ok()) << scene_->error();
        return scene_->Run(frames);
    }
    uint64_t Bytes() { return scene_->renderer().RenderTargetBytesForTests(); }

private:
    Case                      c_;
    ScenePackage              package_;
    std::unique_ptr<GpuScene> scene_;
};

bool Inside(const PixelRect& r, uint32_t x, uint32_t y)
{
    return int(x) >= r.x && int(x) < r.x + r.width && int(y) >= r.y && int(y) < r.y + r.height;
}

PixelRect Shown(const wallpaper::WallpaperScalingLayout& layout)
{
    const int x0 = std::max(0, layout.viewport_px.x), y0 = std::max(0, layout.viewport_px.y);
    const int x1 = std::min(layout.scissor_px.width, layout.viewport_px.x + layout.viewport_px.width);
    const int y1 = std::min(layout.scissor_px.height, layout.viewport_px.y + layout.viewport_px.height);
    return { x0, y0, std::max(0, x1 - x0), std::max(0, y1 - y0) };
}

struct BarStats {
    size_t pixels { 0 };
    size_t black { 0 };
    int    worst_step { 0 };
};

/// What the pixels outside `picture` look like: how many there are, how many are black, and the
/// largest step between two neighbours that are both outside it.
BarStats Bars(const Image& image, const PixelRect& picture)
{
    BarStats stats;
    for (uint32_t y = 0; y < image.height; ++y) {
        for (uint32_t x = 0; x < image.width; ++x) {
            if (Inside(picture, x, y)) continue;
            const Rgba here = image.At(x, y);
            ++stats.pixels;
            if (here[0] == 0 && here[1] == 0 && here[2] == 0) ++stats.black;
            for (const auto& next : { std::pair<uint32_t, uint32_t> { x + 1, y }, { x, y + 1 } }) {
                if (next.first >= image.width || next.second >= image.height || Inside(picture, next.first, next.second)) continue;
                const Rgba there = image.At(next.first, next.second);
                for (int ch = 0; ch < 3; ++ch) stats.worst_step = std::max(stats.worst_step, std::abs(int(here[ch]) - int(there[ch])));
            }
        }
    }
    return stats;
}

/// The pictures agree byte for byte inside `region`.
::testing::AssertionResult SameInside(const Image& a, const Image& b, const PixelRect& region)
{
    if (a.width != b.width || a.height != b.height) return ::testing::AssertionFailure() << "sizes differ";
    size_t differing = 0;
    int    worst     = 0;
    std::string first;
    for (uint32_t y = 0; y < a.height; ++y) {
        for (uint32_t x = 0; x < a.width; ++x) {
            if (!Inside(region, x, y)) continue;
            const Rgba p = a.At(x, y), q = b.At(x, y);
            if (p == q) continue;
            if (differing++ == 0) first = "(" + std::to_string(x) + "," + std::to_string(y) + ")";
            for (int ch = 0; ch < 4; ++ch) worst = std::max(worst, std::abs(int(p[ch]) - int(q[ch])));
        }
    }
    if (differing == 0) return ::testing::AssertionSuccess();
    return ::testing::AssertionFailure() << differing << " pixels differ inside the picture, first at " << first
                                         << ", by up to " << worst;
}

// What the copy should show at a display pixel: the gradient as Fill at a factor of 1 places
// it, mirrored when the picture is, at 70% of its brightness.
std::array<double, 3> Expected(const wallpaper::WallpaperScalingLayout& layout, bool mirrored, uint32_t x, uint32_t y)
{
    double u = (x + 0.5 - layout.backdrop_px.x) / layout.backdrop_px.width;
    const double v = (y + 0.5 - layout.backdrop_px.y) / layout.backdrop_px.height;
    if (mirrored) u = 1.0 - u;
    return { 0.7 * (100 + 120 * u), 0.7 * (100 + 120 * v), 0.7 * 128 };
}

class BackdropScene : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }

    // The checks every case shares: Fit and the new mode draw the same picture, Fit's bars are
    // black, the copy fills the bars smoothly with the picture's colours at 70%.
    void CheckCase(const Case& c)
    {
        SCOPED_TRACE(c.name);
        const auto layout = LayoutOf(c, kBlurred);
        const PixelRect picture = Shown(layout);
        ASSERT_TRUE(layout.backdrop) << "the case is meant to leave room";

        Showing fit(c, kFit);
        ASSERT_TRUE(fit.scene().ok()) << fit.scene().error();
        const Image fit_picture = fit.Picture();
        ASSERT_EQ(fit_picture.width, c.display_w);
        ASSERT_EQ(fit_picture.height, c.display_h);
        Showing blurred(c, kBlurred);
        ASSERT_TRUE(blurred.scene().ok()) << blurred.scene().error();
        const Image picture_with_copy = blurred.Picture();
        ASSERT_EQ(picture_with_copy.width, c.display_w);
        KeepPicture(std::string("backdrop_") + (c.mirrored ? "mirrored_" : "") + std::to_string(c.canvas_w) + "x" +
                        std::to_string(c.display_w) + "x" + std::to_string(c.display_h),
                    picture_with_copy);

        EXPECT_TRUE(SameInside(picture_with_copy, fit_picture, picture)) << "the picture is Fit's";

        const BarStats fit_bars = Bars(fit_picture, picture);
        ASSERT_GT(fit_bars.pixels, 0u);
        EXPECT_EQ(fit_bars.black, fit_bars.pixels) << "Fit's bars are the clear colour";

        const BarStats bars = Bars(picture_with_copy, picture);
        EXPECT_EQ(bars.pixels, fit_bars.pixels);
        EXPECT_EQ(bars.black, 0u) << "the copy fills every pixel of the bars";
        EXPECT_LE(bars.worst_step, 4) << "neighbouring pixels of the copy are close";

        // The copy is the picture again, darker: the gradient the scene holds, Fill-sized, at 70%.
        size_t   checked = 0;
        int      worst   = 0;
        double   bar_mean[3] = { 0, 0, 0 };
        for (uint32_t y = 0; y < picture_with_copy.height; ++y) {
            for (uint32_t x = 0; x < picture_with_copy.width; ++x) {
                if (Inside(picture, x, y)) continue;
                const auto want = Expected(layout, c.mirrored, x, y);
                const Rgba got  = picture_with_copy.At(x, y);
                for (int ch = 0; ch < 3; ++ch) {
                    worst = std::max(worst, int(std::lround(std::abs(got[ch] - want[ch]))));
                    bar_mean[ch] += got[ch];
                }
                ++checked;
            }
        }
        ASSERT_GT(checked, 0u);
        EXPECT_LE(worst, 5) << "the copy is the scene's own picture at 70% of its brightness";

        // Each side is darker than the strip of picture beside it.
        const auto strip_mean = [&](int x0, int y0, int w, int h, int ch) {
            double sum = 0;
            for (int y = y0; y < y0 + h; ++y) for (int x = x0; x < x0 + w; ++x) sum += picture_with_copy.At(x, y)[ch];
            return sum / (double(w) * h);
        };
        const bool sides = picture.x > 0;
        for (int ch = 0; ch < 3; ++ch) {
            double near_mean[2], far_mean[2];
            double bar0 = 0, bar1 = 0;
            size_t n0 = 0, n1 = 0;
            for (uint32_t y = 0; y < picture_with_copy.height; ++y) {
                for (uint32_t x = 0; x < picture_with_copy.width; ++x) {
                    if (Inside(picture, x, y)) continue;
                    const bool first = sides ? int(x) < picture.x : int(y) < picture.y;
                    (first ? bar0 : bar1) += picture_with_copy.At(x, y)[ch];
                    ++(first ? n0 : n1);
                }
            }
            ASSERT_GT(n0, 0u);
            ASSERT_GT(n1, 0u);
            near_mean[0] = sides ? strip_mean(picture.x, picture.y, 8, picture.height, ch)
                                 : strip_mean(picture.x, picture.y, picture.width, 8, ch);
            near_mean[1] = sides ? strip_mean(picture.x + picture.width - 8, picture.y, 8, picture.height, ch)
                                 : strip_mean(picture.x, picture.y + picture.height - 8, picture.width, 8, ch);
            far_mean[0] = bar0 / n0;
            far_mean[1] = bar1 / n1;
            EXPECT_LT(far_mean[0], 0.9 * near_mean[0]) << "channel " << ch << ", first bar";
            EXPECT_LT(far_mean[1], 0.9 * near_mean[1]) << "channel " << ch << ", second bar";
        }
    }
};

} // namespace

// ---- the picture and the copy ------------------------------------------------------------

TEST_F(BackdropScene, BarsOnTheLeftAndRightAreFilledAndThePictureIsFits) { CheckCase(kBarsLeftRight); }
TEST_F(BackdropScene, BarsAboveAndBelowAreFilledAndThePictureIsFits) { CheckCase(kBarsAboveBelow); }
TEST_F(BackdropScene, AMirroredPictureHasAMirroredCopy) { CheckCase(kMirrored); }
TEST_F(BackdropScene, ALargePictureWithBarsOnTheSidesTakesTheEightBitStep) { CheckCase(kLargeLeftRight); }
TEST_F(BackdropScene, ALargePictureWithBarsAboveAndBelowTakesTheEightBitStep)
{
    Showing probe(kLargeAboveBelow, kFit);
    ASSERT_TRUE(probe.scene().ok()) << probe.scene().error();
    ASSERT_TRUE(probe.scene().Step(1));
    const std::string output = probe.scene().scene().ResolveRenderTargetName(wallpaper::SpecTex_Default);
    EXPECT_GT(probe.scene().RenderTarget(output).width, 1024u) << "the picture is longer than 1024 texels";
    CheckCase(kLargeAboveBelow);
}

// ---- the colour of the bars ----------------------------------------------------------------

namespace
{
/// How many pixels outside the picture are exactly `color`, and how many there are.
std::pair<size_t, size_t> BarsOfColour(const Image& image, const PixelRect& picture, Rgba color)
{
    size_t matching = 0, total = 0;
    for (uint32_t y = 0; y < image.height; ++y) {
        for (uint32_t x = 0; x < image.width; ++x) {
            if (Inside(picture, x, y)) continue;
            ++total;
            const Rgba here = image.At(x, y);
            if (here[0] == color[0] && here[1] == color[1] && here[2] == color[2]) ++matching;
        }
    }
    return { matching, total };
}
} // namespace

// Wallpaper Engine clears the room a fitted picture leaves with the wallpaper's `schemecolor`
// (sub_140181F30 reads it, sub_14017FA70 clears with it); the blurred backdrop fills its bars
// with the picture instead.
TEST_F(BackdropScene, FitBordersTakeTheSchemeColour)
{
    ScenePackage package;
    MakeGradientScene(package, kBarsLeftRight);
    package.SetProject({ { "schemecolor", { { "type", "color" }, { "text", "Scheme" }, { "value", "1 0 0" } } } });
    GpuScene scene(package, OptionsFor(kBarsLeftRight));
    ASSERT_TRUE(scene.ok()) << scene.error();
    const PixelRect picture = Shown(LayoutOf(kBarsLeftRight, kFit));

    scene.renderer().SetWallpaperScalingMode(kFit);
    const auto red = BarsOfColour(scene.Run(3), picture, { 255, 0, 0, 255 });
    ASSERT_GT(red.second, 0u) << "Fit leaves bars on this display";
    EXPECT_EQ(red.first, red.second) << "every bar pixel is the scheme colour";

    // The property follows a live change.
    ASSERT_TRUE(scene.SetProperty("schemecolor", "0 0 1"));
    const auto blue = BarsOfColour(scene.Run(3), picture, { 0, 0, 255, 255 });
    EXPECT_EQ(blue.first, blue.second);

    scene.renderer().SetWallpaperScalingMode(kBlurred);
    const auto blurred = BarsOfColour(scene.Run(3), Shown(LayoutOf(kBarsLeftRight, kBlurred)), { 0, 0, 255, 255 });
    EXPECT_EQ(blurred.first, 0u) << "the blurred backdrop is never the scheme colour";
}

TEST_F(BackdropScene, FitBordersAreBlackWithoutASchemeColour)
{
    Showing fit(kBarsLeftRight, kFit);
    ASSERT_TRUE(fit.scene().ok()) << fit.scene().error();
    const auto black = BarsOfColour(fit.Picture(), Shown(LayoutOf(kBarsLeftRight, kFit)), { 0, 0, 0, 255 });
    ASSERT_GT(black.second, 0u);
    EXPECT_EQ(black.first, black.second);
}

// A picture of four flat colours, hard edges and all, on a display that leaves bars.
Image PictureOfQuadrants(const Case& c)
{
    ScenePackage package;
    const std::string texture = package.AddTexture("quadrants", Image::Quadrants(2, 2, { 255, 0, 0, 255 }, { 0, 255, 0, 255 },
                                                                                { 0, 0, 255, 255 }, { 255, 255, 255, 255 }));
    ImageLayer layer;
    layer.model  = package.AddImageModel("quadrants", texture);
    layer.origin = { c.canvas_w / 2.0f, c.canvas_h / 2.0f, 0.0f };
    layer.size   = { static_cast<float>(c.canvas_w), static_cast<float>(c.canvas_h) };
    SceneGeneral general;
    general.canvas_width  = static_cast<int>(c.canvas_w);
    general.canvas_height = static_cast<int>(c.canvas_h);
    package.SetProject();
    package.SetScene(SceneJson(general, { ImageLayerJson(layer) }));
    GpuScene scene(package, OptionsFor(c));
    EXPECT_TRUE(scene.ok()) << scene.error();
    scene.renderer().SetWallpaperScalingMode(kBlurred);
    return scene.Run(3);
}

TEST_F(BackdropScene, TheCopyIsSoftEvenWhenThePictureHasHardEdges)
{
    // The quadrants meet in a horizontal edge that crosses the bars at the sides and a
    // vertical one that crosses the bars above and below: each of the two blur passes is what
    // keeps one of them from showing.
    for (const Case* c : { &kBarsLeftRight, &kBarsAboveBelow }) {
        const Image picture = PictureOfQuadrants(*c);
        ASSERT_FALSE(picture.empty());
        const BarStats bars = Bars(picture, Shown(LayoutOf(*c, kBlurred)));
        EXPECT_GT(bars.pixels, 0u);
        EXPECT_EQ(bars.black, 0u) << c->name;
        // A hard edge of 255 steps becomes a ramp over some sixty pixels, a handful of steps a pixel;
        // unblurred it would be thirty or more.
        EXPECT_LE(bars.worst_step, 8) << c->name << ": neighbouring pixels of the copy differ by a few steps at most";
    }
}

TEST_F(BackdropScene, TheCopyCarriesOneStepOfDither)
{
    // Flat 101 darkened to 70% is 70.7 of 255: undithered it would be one value throughout.
    // The dither moves it by less than a step either way, so the bars hold exactly 70 and 71,
    // both of them, and the pattern is the same on every run.
    const auto run = [] {
        ScenePackage package;
        package.MakeSolidScene({ 101, 101, 101, 255 });
        GpuSceneOptions options;
        options.width = 320;
        GpuScene scene(package, options);
        EXPECT_TRUE(scene.ok()) << scene.error();
        scene.renderer().SetWallpaperScalingMode(kBlurred);
        return scene.Run(3);
    };
    const Image first = run();
    ASSERT_FALSE(first.empty());
    size_t seen[256] = {};
    for (uint32_t y = 0; y < first.height; ++y) {
        for (uint32_t x = 0; x < 32; ++x) ++seen[first.At(x, y)[0]];
    }
    EXPECT_GT(seen[70], 0u);
    EXPECT_GT(seen[71], 0u);
    EXPECT_EQ(seen[70] + seen[71], size_t(32) * first.height) << "nothing but those two values";
    EXPECT_EQ(first.rgba, run().rgba);
}

TEST_F(BackdropScene, TwoRunsGiveTheSameBytes)
{
    const auto run = [] {
        Showing showing(kLargeLeftRight, kBlurred);
        EXPECT_TRUE(showing.scene().ok()) << showing.scene().error();
        return showing.Picture(4);
    };
    const Image first  = run();
    const Image second = run();
    ASSERT_FALSE(first.empty());
    EXPECT_EQ(first.rgba, second.rgba);
}

TEST_F(BackdropScene, AFrameThatRepeatsThePictureRepeatsTheCopyToo)
{
    Showing showing(kBarsLeftRight, kBlurred);
    ASSERT_TRUE(showing.scene().ok()) << showing.scene().error();
    const Image first = showing.Picture(2);
    ASSERT_TRUE(showing.scene().Step(3)) << showing.scene().error();
    EXPECT_TRUE(ExpectSamePicture(showing.scene().Picture(), first));
}

TEST_F(BackdropScene, MovingOrScalingThePictureMovesThePictureAndNotTheCopy)
{
    // Smaller than Fit: room all around, and the picture moved off centre.
    const Case& c = kBarsLeftRight;
    Showing centred(c, kBlurred, 0.5);
    ASSERT_TRUE(centred.scene().ok()) << centred.scene().error();
    const Image middle = centred.Picture();

    Showing moved(c, kBlurred, 0.5);
    ASSERT_TRUE(moved.scene().ok()) << moved.scene().error();
    moved.scene().renderer().SetWallpaperFraming({ 0.0, 0.0 });
    const Image corner = moved.Picture();

    const auto centred_layout = ComputeWallpaperScalingLayout(kBlurred, c.canvas_w, c.canvas_h, c.display_w, c.display_h, 1.0, 0.5);
    const auto corner_layout  = ComputeWallpaperScalingLayout(kBlurred, c.canvas_w, c.canvas_h, c.display_w, c.display_h, 1.0, 0.5, 0.0, 0.0);
    ASSERT_NE(centred_layout.viewport_px.x, corner_layout.viewport_px.x);
    // Both pictures sit somewhere; the pixels neither covers hold the same copy.
    size_t compared = 0;
    for (uint32_t y = 0; y < middle.height; ++y) {
        for (uint32_t x = 0; x < middle.width; ++x) {
            if (Inside(Shown(centred_layout), x, y) || Inside(Shown(corner_layout), x, y)) continue;
            ASSERT_EQ(middle.At(x, y), corner.At(x, y)) << x << "," << y;
            ++compared;
        }
    }
    EXPECT_GT(compared, 1000u);
}

TEST_F(BackdropScene, APictureThatFitsTheDisplayDrawsNoCopyAndTheBytesOfFit)
{
    const Case& c = kExactFit;
    ASSERT_FALSE(LayoutOf(c, kBlurred).backdrop);
    Showing fit(c, kFit);
    Showing blurred(c, kBlurred);
    ASSERT_TRUE(fit.scene().ok()) << fit.scene().error();
    ASSERT_TRUE(blurred.scene().ok()) << blurred.scene().error();
    const Image a = fit.Picture();
    const Image b = blurred.Picture();
    ASSERT_FALSE(a.empty());
    EXPECT_EQ(a.rgba, b.rgba);
    EXPECT_EQ(blurred.Bytes(), fit.Bytes()) << "nothing is held for a copy nobody sees";
}

// ---- costs and lifetime ------------------------------------------------------------------

TEST_F(BackdropScene, FitAndFillHoldTheSameTargetsWhateverTheDisplayShape)
{
    for (const Case* c : { &kBarsLeftRight, &kBarsAboveBelow, &kLargeLeftRight }) {
        Showing fit(*c, kFit), fill(*c, kFill);
        ASSERT_TRUE(fit.scene().ok()) << fit.scene().error();
        ASSERT_TRUE(fill.scene().ok()) << fill.scene().error();
        ASSERT_FALSE(fit.Picture().empty());
        ASSERT_FALSE(fill.Picture().empty());
        EXPECT_EQ(fit.Bytes(), fill.Bytes()) << c->name;
    }
}

TEST_F(BackdropScene, TheCopyHoldsMemoryOnlyWhileThePictureLeavesRoom)
{
    const Case& c = kBarsLeftRight;
    Showing     fit(c, kFit);
    ASSERT_TRUE(fit.scene().ok()) << fit.scene().error();
    ASSERT_FALSE(fit.Picture().empty());
    const uint64_t fit_bytes = fit.Bytes();

    Showing showing(c, kBlurred);
    ASSERT_TRUE(showing.scene().ok()) << showing.scene().error();
    ASSERT_FALSE(showing.Picture().empty());
    const uint64_t held = showing.Bytes();
    // Two half-float images of 128x72 texels at least.
    EXPECT_GE(held, fit_bytes + 2 * 128 * 72 * 8);
    EXPECT_LT(held, fit_bytes + 4 * 1024 * 1024) << "a couple of megabytes at most";

    // A scale factor that leaves no room: the first frame after it has none, and the images go.
    showing.scene().renderer().SetWallpaperScalingFactor(1.5);
    ASSERT_TRUE(showing.scene().Step(1)) << showing.scene().error();
    EXPECT_EQ(showing.Bytes(), fit_bytes);
    // Room again: they come back.
    showing.scene().renderer().SetWallpaperScalingFactor(1.0);
    ASSERT_TRUE(showing.scene().Step(1)) << showing.scene().error();
    EXPECT_EQ(showing.Bytes(), held);
    // Another mode: gone.
    showing.scene().renderer().SetWallpaperScalingMode(kFit);
    ASSERT_TRUE(showing.scene().Step(1)) << showing.scene().error();
    EXPECT_EQ(showing.Bytes(), fit_bytes);
}

TEST_F(BackdropScene, ALargePictureAlsoHoldsTheEightBitImage)
{
    const auto bytes_of = [](const Case& c, WallpaperScalingMode mode) {
        Showing showing(c, mode);
        EXPECT_TRUE(showing.scene().ok()) << showing.scene().error();
        EXPECT_FALSE(showing.Picture().empty());
        return showing.Bytes();
    };
    // The same shape of picture at two sizes: the copy beside a 1600 wide one also holds an
    // image of 200x113 texels of four bytes, which the 640 wide one has no use for.
    const uint64_t small_copy = bytes_of(kBarsLeftRight, kBlurred) - bytes_of(kBarsLeftRight, kFit);
    const uint64_t large_copy = bytes_of(kLargeLeftRight, kBlurred) - bytes_of(kLargeLeftRight, kFit);
    EXPECT_GE(large_copy, small_copy + 200 * 113 * 4);
    EXPECT_LT(large_copy, 4u * 1024 * 1024);
}

TEST_F(BackdropScene, SwitchingBetweenFitAndTheModeShowsTheCopyAndASkippedFrameKeepsIt)
{
    wallpaper::RendererCounters counters;
    wallpaper::RendererCounters::SetEnabled(true);
    struct Off { ~Off() { wallpaper::RendererCounters::SetEnabled(false); } } off;

    Showing showing(kBarsLeftRight, kFit);
    ASSERT_TRUE(showing.scene().ok()) << showing.scene().error();
    showing.scene().renderer().SetCounters(&counters);
    const auto skipped = [&] { return counters.Get(OWE_RC_PRESENTS_SKIPPED_UNCHANGED); };

    ASSERT_TRUE(showing.scene().Step(4)) << showing.scene().error();
    const Image with_bars = showing.scene().Picture();
    const uint64_t before_switch = skipped();
    EXPECT_GT(before_switch, 0u) << "a static scene's repeated frames are skipped";

    showing.scene().renderer().SetWallpaperScalingMode(kBlurred);
    ASSERT_TRUE(showing.scene().Step(1)) << showing.scene().error();
    EXPECT_EQ(skipped(), before_switch) << "the frame after a switch presents again";
    const Image copy = showing.scene().Picture();
    EXPECT_GT(Bars(copy, Shown(LayoutOf(kBarsLeftRight, kBlurred))).pixels, 0u);
    EXPECT_NE(copy.rgba, with_bars.rgba) << "the bars changed";

    ASSERT_TRUE(showing.scene().Step(3)) << showing.scene().error();
    EXPECT_EQ(skipped(), before_switch + 3) << "a frame that repeats the picture still repeats the copy";
    EXPECT_EQ(showing.scene().Picture().rgba, copy.rgba);

    showing.scene().renderer().SetWallpaperScalingMode(kFit);
    ASSERT_TRUE(showing.scene().Step(1)) << showing.scene().error();
    EXPECT_EQ(skipped(), before_switch + 3) << "switching back presents again";
    EXPECT_EQ(showing.scene().Picture().rgba, with_bars.rgba);
}

TEST_F(BackdropScene, TheCopyAddsNoPassToAFrame)
{
    // Static reuse off, so every frame counts every pass it would draw.
    const auto passes = [&](const Case& c, WallpaperScalingMode mode) {
        Showing showing(c, mode, 1.0, false);
        EXPECT_TRUE(showing.scene().ok()) << showing.scene().error();
        EXPECT_TRUE(showing.scene().Step(3)) << showing.scene().error();
        return showing.scene().FramePasses();
    };
    for (const Case* c : { &kBarsLeftRight, &kLargeAboveBelow }) {
        const auto fit     = passes(*c, kFit);
        const auto blurred = passes(*c, kBlurred);
        ASSERT_EQ(fit.size(), 3u);
        ASSERT_EQ(blurred.size(), 3u);
        EXPECT_GE(fit[0].total(), 1u);
        for (size_t i = 0; i < fit.size(); ++i) {
            EXPECT_EQ(blurred[i].total(), fit[i].total()) << c->name << " frame " << i;
            EXPECT_EQ(blurred[i].scene_output_passes, fit[i].scene_output_passes) << c->name << " frame " << i;
        }
    }
}
