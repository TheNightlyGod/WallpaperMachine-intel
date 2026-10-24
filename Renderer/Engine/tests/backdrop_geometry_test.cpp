// The pure arithmetic of "Fit with blurred backdrop": the layout the mode reports, the
// rectangles the backdrop is drawn into, and the plan that reduces the picture for it.
// Nothing here draws.

#include <gtest/gtest.h>

#include "Presentation/BackdropGeometry.hpp"
#include "Presentation/WallpaperScaling.hpp"

#include <algorithm>
#include <cstdint>

namespace
{
using namespace wallpaper;

struct Shape {
    const char* name;
    uint32_t    scene_w, scene_h;
    uint32_t    display_w, display_h;
    bool        room_at_factor_one;
};

// A 1920x1080 picture on displays of several shapes. The last two rows are the shapes where
// Fit leaves no room: the same shape, and the one pixel the rounding of a nearly equal shape
// leaves (1000 x 563.5 rounds to 1000 x 563 or 564).
const Shape kShapes[] = {
    { "ultrawide", 1920, 1080, 2560, 1080, true },
    { "sixteen by ten", 1920, 1080, 1920, 1200, true },
    { "portrait", 1920, 1080, 1080, 1920, true },
    { "same shape", 1920, 1080, 1280, 720, false },
    { "one pixel gap", 1920, 1080, 1000, 564, false },
};

WallpaperScalingLayout Layout(WallpaperScalingMode mode, const Shape& shape, double dpr, double factor,
                              double pan_x = 0.5, double pan_y = 0.5)
{
    return ComputeWallpaperScalingLayout(mode, shape.scene_w, shape.scene_h, shape.display_w,
                                         shape.display_h, dpr, factor, pan_x, pan_y);
}

bool SameRect(const PixelRect& a, const PixelRect& b)
{
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

int64_t Area(const PixelRect& r) { return int64_t(std::max(0, r.width)) * std::max(0, r.height); }

bool Contains(const PixelRect& r, int x, int y)
{
    return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
}

PixelRect Clip(const PixelRect& a, const PixelRect& b)
{
    const int x0 = std::max(a.x, b.x), y0 = std::max(a.y, b.y);
    const int x1 = std::min(a.x + a.width, b.x + b.width), y1 = std::min(a.y + a.height, b.y + b.height);
    return { x0, y0, std::max(0, x1 - x0), std::max(0, y1 - y0) };
}

} // namespace

// ---- the scaling mode and its layout -----------------------------------------------------

TEST(BackdropLayout, TheModeHasValueFourAndNothingPastTheLastIsAMode)
{
    ASSERT_TRUE(WallpaperScalingModeFromValue(4).has_value());
    EXPECT_EQ(*WallpaperScalingModeFromValue(4), WallpaperScalingMode::FIT_BLURRED);
    EXPECT_EQ(static_cast<int>(WallpaperScalingMode::FIT_BLURRED), 4);
    for (int64_t value = 0; value <= 3; ++value) {
        ASSERT_TRUE(WallpaperScalingModeFromValue(value).has_value()) << value;
        EXPECT_EQ(static_cast<int64_t>(*WallpaperScalingModeFromValue(value)), value);
    }
    for (const int64_t value : { int64_t(5), int64_t(6), int64_t(255), int64_t(256), int64_t(-1),
                                 int64_t(1) << 40 }) {
        EXPECT_FALSE(WallpaperScalingModeFromValue(value).has_value()) << value;
    }
}

TEST(BackdropLayout, FitWithBackdropIsFitWhateverTheFactorAndPosition)
{
    for (const Shape& shape : kShapes) {
        for (const double dpr : { 1.0, 2.0 }) {
            for (const double factor : { 0.5, 1.0, 1.3 }) {
                for (const double pan_x : { 0.0, 0.5, 1.0 }) {
                    for (const double pan_y : { 0.0, 0.5, 1.0 }) {
                        const auto fit  = Layout(WallpaperScalingMode::FIT, shape, dpr, factor, pan_x, pan_y);
                        const auto blur = Layout(WallpaperScalingMode::FIT_BLURRED, shape, dpr, factor, pan_x, pan_y);
                        const std::string where = std::string(shape.name) + " dpr " + std::to_string(dpr) +
                                                  " factor " + std::to_string(factor);
                        EXPECT_TRUE(SameRect(fit.viewport_px, blur.viewport_px)) << where;
                        EXPECT_TRUE(SameRect(fit.scissor_px, blur.scissor_px)) << where;
                        EXPECT_EQ(fit.scale_x, blur.scale_x) << where;
                        EXPECT_EQ(fit.scale_y, blur.scale_y) << where;
                    }
                }
            }
        }
    }
}

TEST(BackdropLayout, TheBackdropIsFillAtFactorOneCentredWhereverThePictureIs)
{
    for (const Shape& shape : kShapes) {
        for (const double dpr : { 1.0, 2.0 }) {
            const auto fill = Layout(WallpaperScalingMode::FILL, shape, dpr, 1.0);
            for (const double factor : { 0.5, 1.0, 1.3 }) {
                for (const double pan_x : { 0.0, 0.5, 1.0 }) {
                    for (const double pan_y : { 0.0, 1.0 }) {
                        const auto blur = Layout(WallpaperScalingMode::FIT_BLURRED, shape, dpr, factor, pan_x, pan_y);
                        EXPECT_TRUE(SameRect(blur.backdrop_px, fill.viewport_px))
                            << shape.name << " dpr " << dpr << " factor " << factor << " pan " << pan_x << "," << pan_y;
                    }
                }
            }
        }
    }
}

TEST(BackdropLayout, TheBackdropIsOnlyWantedWhenThePictureLeavesMoreThanAPixelOfRoom)
{
    for (const Shape& shape : kShapes) {
        const auto layout = Layout(WallpaperScalingMode::FIT_BLURRED, shape, 1.0, 1.0);
        EXPECT_EQ(layout.backdrop, shape.room_at_factor_one) << shape.name;
    }
    // Once the picture is smaller than the display every shape leaves room, and once it is
    // larger than the display in both directions none does.
    for (const Shape& shape : kShapes) {
        EXPECT_TRUE(Layout(WallpaperScalingMode::FIT_BLURRED, shape, 1.0, 0.5).backdrop) << shape.name;
        EXPECT_FALSE(Layout(WallpaperScalingMode::FIT_BLURRED, shape, 1.0, 4.0).backdrop) << shape.name;
    }
    // Room on one axis is enough: at 1.2 the picture is taller than the 1080 px display and
    // still narrower than its 2560 px.
    EXPECT_TRUE(Layout(WallpaperScalingMode::FIT_BLURRED, kShapes[0], 1.0, 1.2).backdrop);
}

TEST(BackdropLayout, EveryOtherModeHasNoBackdropAndItsLayoutIsAsItWas)
{
    const Shape& s = kShapes[0]; // 1920x1080 on 2560x1080
    for (const auto mode : { WallpaperScalingMode::NONE, WallpaperScalingMode::STRETCH,
                             WallpaperScalingMode::FIT, WallpaperScalingMode::FILL }) {
        const auto layout = Layout(mode, s, 1.0, 1.0);
        EXPECT_FALSE(layout.backdrop) << static_cast<int>(mode);
        EXPECT_EQ(Area(layout.backdrop_px), 0) << static_cast<int>(mode);
        EXPECT_EQ(layout.scissor_px.width, 2560);
        EXPECT_EQ(layout.scissor_px.height, 1080);
    }
    EXPECT_TRUE(SameRect(Layout(WallpaperScalingMode::NONE, s, 1.0, 1.0).viewport_px, { 320, 0, 1920, 1080 }));
    EXPECT_TRUE(SameRect(Layout(WallpaperScalingMode::STRETCH, s, 1.0, 1.0).viewport_px, { 0, 0, 2560, 1080 }));
    EXPECT_TRUE(SameRect(Layout(WallpaperScalingMode::FIT, s, 1.0, 1.0).viewport_px, { 320, 0, 1920, 1080 }));
    EXPECT_TRUE(SameRect(Layout(WallpaperScalingMode::FILL, s, 1.0, 1.0).viewport_px, { 0, -180, 2560, 1440 }));
}

// ---- the bands ---------------------------------------------------------------------------

namespace
{

// Every pixel of the display is in the picture or in exactly one band, and no band leaves the
// display; the areas add up the same way.
void ExpectExactCover(const PixelRect& display, const PixelRect& picture, const char* what)
{
    const SurroundBands bands = ComputeSurroundBands(display, picture);
    ASSERT_GE(bands.count, 0) << what;
    ASSERT_LE(bands.count, 4) << what;
    const PixelRect shown = Clip(display, picture);

    int64_t band_area = 0;
    for (int i = 0; i < bands.count; ++i) {
        const PixelRect& band = bands.rects[i];
        EXPECT_GT(Area(band), 0) << what << ": an empty band is not reported";
        EXPECT_EQ(Area(Clip(band, display)), Area(band)) << what << ": band " << i << " leaves the display";
        EXPECT_EQ(Area(Clip(band, shown)), 0) << what << ": band " << i << " overlaps the picture";
        for (int j = i + 1; j < bands.count; ++j) {
            EXPECT_EQ(Area(Clip(band, bands.rects[j])), 0) << what << ": bands " << i << " and " << j << " overlap";
        }
        band_area += Area(band);
    }
    EXPECT_EQ(band_area, Area(display) - Area(shown)) << what;

    const int step_x = std::max(1, display.width / 37), step_y = std::max(1, display.height / 29);
    for (int y = display.y; y < display.y + display.height; y += step_y) {
        for (int x = display.x; x < display.x + display.width; x += step_x) {
            int covers = Contains(picture, x, y) ? 1 : 0;
            for (int i = 0; i < bands.count; ++i) covers += Contains(bands.rects[i], x, y) ? 1 : 0;
            EXPECT_EQ(covers, 1) << what << " at " << x << "," << y;
        }
    }
}

} // namespace

TEST(BackdropBands, TheyExactlyCoverTheDisplayAroundThePicture)
{
    const PixelRect display { 0, 0, 2560, 1080 };
    ExpectExactCover(display, { 320, 0, 1920, 1080 }, "bars left and right");
    ExpectExactCover({ 0, 0, 1920, 1200 }, { 0, 60, 1920, 1080 }, "bars above and below");
    ExpectExactCover({ 0, 0, 1080, 1920 }, { 0, 656, 1080, 608 }, "portrait display");
    ExpectExactCover(display, { 100, 50, 400, 300 }, "a picture in the middle of the room");
    ExpectExactCover(display, { 0, 0, 400, 300 }, "a picture in a corner");
    ExpectExactCover(display, { 2160, 780, 400, 300 }, "a picture in the opposite corner");
}

TEST(BackdropBands, APictureMovedPastAnEdgeLeavesOnlyWhatTheDisplayShowsOfIt)
{
    const PixelRect display { 0, 0, 1000, 600 };
    ExpectExactCover(display, { -200, 100, 700, 300 }, "past the left edge");
    ExpectExactCover(display, { 700, -50, 600, 300 }, "past the top right corner");
    ExpectExactCover(display, { -100, -100, 1200, 800 }, "larger than the display");
    ExpectExactCover(display, { 0, 0, 1000, 600 }, "exactly the display");
    ExpectExactCover(display, { 2000, 2000, 10, 10 }, "entirely off the display");
    ExpectExactCover(display, { 500, 300, 0, 0 }, "without any size");
}

TEST(BackdropBands, ACoveringPictureLeavesNoneAndAnAbsentOneLeavesTheWholeDisplay)
{
    const PixelRect display { 0, 0, 1000, 600 };
    EXPECT_EQ(ComputeSurroundBands(display, { 0, 0, 1000, 600 }).count, 0);
    EXPECT_EQ(ComputeSurroundBands(display, { -10, -10, 1100, 700 }).count, 0);

    const SurroundBands whole = ComputeSurroundBands(display, { 4000, 0, 10, 10 });
    ASSERT_EQ(whole.count, 1);
    EXPECT_TRUE(SameRect(whole.rects[0], display));
}

TEST(BackdropBands, TheyFollowTheLayoutOfEveryShape)
{
    for (const Shape& shape : kShapes) {
        for (const double factor : { 0.5, 1.0, 1.3 }) {
            for (const double pan : { 0.0, 0.5, 1.0 }) {
                const auto layout = Layout(WallpaperScalingMode::FIT_BLURRED, shape, 2.0, factor, pan, 1.0 - pan);
                ExpectExactCover(layout.scissor_px, layout.viewport_px,
                                 (std::string(shape.name) + " factor " + std::to_string(factor)).c_str());
            }
        }
    }
}

// ---- the reduction plan ------------------------------------------------------------------

namespace
{

// The source size each step reads: the picture for the first, the previous step's image after.
void ExpectTapsAreCloseEnough(uint32_t width, uint32_t height)
{
    const auto steps = PlanBackdropReduction(width, height);
    ASSERT_FALSE(steps.empty()) << width << "x" << height;
    uint32_t   from_w = width, from_h = height;
    for (const auto& step : steps) {
        ASSERT_GE(step.taps_x, 1u);
        ASSERT_GE(step.taps_y, 1u);
        EXPECT_LE(step.spacing_x, kBackdropMaxTapSpacing + 1e-9) << width << "x" << height;
        EXPECT_LE(step.spacing_y, kBackdropMaxTapSpacing + 1e-9) << width << "x" << height;
        EXPECT_NEAR(step.spacing_x * step.taps_x, double(from_w) / step.width, 1e-9) << width << "x" << height;
        EXPECT_NEAR(step.spacing_y * step.taps_y, double(from_h) / step.height, 1e-9) << width << "x" << height;
        from_w = step.width;
        from_h = step.height;
    }
}

} // namespace

TEST(BackdropReduction, ALargePictureTakesTwoStepsThroughAnEightBitImage)
{
    const auto steps = PlanBackdropReduction(3840, 2160);
    ASSERT_EQ(steps.size(), 2u);
    EXPECT_EQ(steps[0].width, 480u);
    EXPECT_EQ(steps[0].height, 270u);
    EXPECT_TRUE(steps[0].eight_bit);
    EXPECT_EQ(steps[1].width, 128u);
    EXPECT_EQ(steps[1].height, 72u);
    EXPECT_FALSE(steps[1].eight_bit);
}

TEST(BackdropReduction, APictureOfAThousandTexelsOrLessTakesOneStep)
{
    auto steps = PlanBackdropReduction(1000, 600);
    ASSERT_EQ(steps.size(), 1u);
    EXPECT_EQ(steps[0].width, 128u);
    EXPECT_EQ(steps[0].height, 77u);
    EXPECT_FALSE(steps[0].eight_bit);

    steps = PlanBackdropReduction(1024, 1024);
    ASSERT_EQ(steps.size(), 1u) << "a thousand and twenty-four is not longer than that";
    EXPECT_EQ(steps[0].width, 128u);
    EXPECT_EQ(steps[0].height, 128u);

    EXPECT_EQ(PlanBackdropReduction(1025, 600).size(), 2u);
}

TEST(BackdropReduction, TheLongerSideEndsAt128WhicheverWayThePictureIsTurned)
{
    const auto wide = PlanBackdropReduction(2560, 1080);
    const auto tall = PlanBackdropReduction(1080, 2560);
    ASSERT_EQ(wide.size(), 2u);
    ASSERT_EQ(tall.size(), 2u);
    EXPECT_EQ(wide.back().width, 128u);
    EXPECT_LT(wide.back().height, 128u);
    EXPECT_EQ(tall.back().height, 128u);
    EXPECT_LT(tall.back().width, 128u);
    EXPECT_EQ(wide.back().height, tall.back().width);

    const auto square = PlanBackdropReduction(600, 600);
    ASSERT_EQ(square.size(), 1u);
    EXPECT_EQ(square[0].width, 128u);
    EXPECT_EQ(square[0].height, 128u);

    // The shorter side never reaches zero, however thin the picture.
    const auto thin = PlanBackdropReduction(4000, 3);
    ASSERT_FALSE(thin.empty());
    EXPECT_GE(thin.back().height, 1u);
}

TEST(BackdropReduction, NoTapIsMoreThanFourTexelsFromItsNeighbour)
{
    for (const uint32_t width : { 1u, 64u, 128u, 700u, 1000u, 1024u, 1025u, 1920u, 2560u, 3840u, 6880u, 8192u, 16384u }) {
        for (const uint32_t height : { 1u, 72u, 128u, 900u, 1080u, 2160u, 2880u, 8192u }) {
            ExpectTapsAreCloseEnough(width, height);
        }
    }
}

TEST(BackdropReduction, AnEightToOneStepReadsAQuarterOfTheTexels)
{
    // Two taps per axis, each reading a two by two block, four texels apart: 16 of 64.
    const auto steps = PlanBackdropReduction(3840, 2160);
    ASSERT_EQ(steps.size(), 2u);
    EXPECT_EQ(steps[0].taps_x, 2u);
    EXPECT_EQ(steps[0].taps_y, 2u);
    EXPECT_NEAR(steps[0].spacing_x, 4.0, 1e-9);
    EXPECT_NEAR(steps[0].spacing_y, 4.0, 1e-9);
}
