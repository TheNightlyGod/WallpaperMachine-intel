#include "Presentation/WallpaperScaling.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>

namespace wallpaper
{
namespace
{

// The presentation layout as it was before the wallpaper could be positioned:
// the same scale arithmetic, then the slack split evenly. Kept here as a
// literal copy so the default can never drift away from it without a test
// saying so, whatever happens to the production function.
struct ReferenceLayout {
    PixelRect viewport;
    PixelRect scissor;
};

ReferenceLayout CentredReference(WallpaperScalingMode mode, uint32_t scene_width,
                                 uint32_t scene_height, uint32_t display_width,
                                 uint32_t display_height, double display_scale, double factor) {
    const double scene_w   = std::max<uint32_t>(1, scene_width);
    const double scene_h   = std::max<uint32_t>(1, scene_height);
    const double display_w = std::max<uint32_t>(1, display_width);
    const double display_h = std::max<uint32_t>(1, display_height);
    const double sx        = display_w / scene_w;
    const double sy        = display_h / scene_h;

    double scale_x = 1.0;
    double scale_y = 1.0;
    switch (mode) {
    case WallpaperScalingMode::NONE: break;
    case WallpaperScalingMode::STRETCH:
        scale_x = sx;
        scale_y = sy;
        break;
    case WallpaperScalingMode::FIT: scale_x = scale_y = std::min(sx, sy); break;
    case WallpaperScalingMode::FILL: scale_x = scale_y = std::max(sx, sy); break;
    }
    scale_x *= factor;
    scale_y *= factor;

    const double content_w = scene_w * scale_x;
    const double content_h = scene_h * scale_y;
    const double x         = (display_w - content_w) * 0.5;
    const double y         = (display_h - content_h) * 0.5;
    const auto   px        = [](double value) { return static_cast<int32_t>(std::lround(value)); };
    return ReferenceLayout {
        PixelRect { px(x * display_scale), px(y * display_scale), px(content_w * display_scale),
                    px(content_h * display_scale) },
        PixelRect { 0, 0, px(display_w * display_scale), px(display_h * display_scale) },
    };
}

void ExpectSameRect(const PixelRect& actual, const PixelRect& expected, const char* what) {
    EXPECT_EQ(actual.x, expected.x) << what;
    EXPECT_EQ(actual.y, expected.y) << what;
    EXPECT_EQ(actual.width, expected.width) << what;
    EXPECT_EQ(actual.height, expected.height) << what;
}

constexpr std::array kModes {
    WallpaperScalingMode::NONE,
    WallpaperScalingMode::STRETCH,
    WallpaperScalingMode::FIT,
    WallpaperScalingMode::FILL,
};

const char* ModeName(WallpaperScalingMode mode) {
    switch (mode) {
    case WallpaperScalingMode::NONE: return "none";
    case WallpaperScalingMode::STRETCH: return "stretch";
    case WallpaperScalingMode::FIT: return "fit";
    case WallpaperScalingMode::FILL: return "fill";
    }
    return "?";
}

struct Geometry {
    uint32_t scene_w;
    uint32_t scene_h;
    uint32_t display_w;
    uint32_t display_h;
    double   display_scale;
};

constexpr std::array kGeometries {
    Geometry { 1920, 1080, 1000, 1000, 1.0 },
    Geometry { 7680, 2160, 3456, 2234, 2.0 },
    Geometry { 1080, 1920, 2056, 1329, 2.0 },
    Geometry { 1920, 1080, 1920, 1080, 1.0 },
};

// A caller that never heard of framing, and one that passes the centre
// explicitly, must both land on exactly the pixels the layout always produced.
// Any other result would shift every existing wallpaper by a pixel.
TEST(WallpaperScaling, DefaultPanIsBitExactWithTheCentredLayout) {
    for (const auto& g : kGeometries) {
        for (const auto mode : kModes) {
            for (const double factor : { 1.0, 1.5, 0.6 }) {
                SCOPED_TRACE(std::string(ModeName(mode)) + " " + std::to_string(g.scene_w) + "x" +
                             std::to_string(g.scene_h) + " on " + std::to_string(g.display_w) +
                             "x" + std::to_string(g.display_h) + " @" +
                             std::to_string(g.display_scale) + " factor " +
                             std::to_string(factor));
                const auto expected = CentredReference(mode, g.scene_w, g.scene_h, g.display_w,
                                                       g.display_h, g.display_scale, factor);

                const auto implicit_centre = ComputeWallpaperScalingLayout(
                    mode, g.scene_w, g.scene_h, g.display_w, g.display_h, g.display_scale, factor);
                ExpectSameRect(implicit_centre.viewport_px, expected.viewport, "viewport");
                ExpectSameRect(implicit_centre.scissor_px, expected.scissor, "scissor");

                const auto explicit_centre =
                    ComputeWallpaperScalingLayout(mode, g.scene_w, g.scene_h, g.display_w,
                                                  g.display_h, g.display_scale, factor, 0.5, 0.5);
                ExpectSameRect(explicit_centre.viewport_px, expected.viewport, "viewport");
                ExpectSameRect(explicit_centre.scissor_px, expected.scissor, "scissor");
            }
        }
    }
}

// FILL overflows horizontally here, so the slack is negative: 0 shows the left
// part of the wallpaper, 1 the right part, and the centre is what it always was.
TEST(WallpaperScaling, PanAlignsLeadingAndTrailingEdgesOfAnOverflowingWallpaper) {
    const auto at = [](double pan_x, double pan_y) {
        return ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 1000, 1000,
                                             1.0, 1.0, pan_x, pan_y);
    };
    EXPECT_EQ(at(0.0, 0.5).viewport_px.width, 3556);
    EXPECT_EQ(at(0.0, 0.5).viewport_px.x, 0);
    EXPECT_EQ(at(0.5, 0.5).viewport_px.x, -1278);
    EXPECT_EQ(at(1.0, 0.5).viewport_px.x, -2556);
    // The right edge of the wallpaper meets the right edge of the display.
    EXPECT_EQ(at(1.0, 0.5).viewport_px.x + at(1.0, 0.5).viewport_px.width, 1000);
    // FILL covers the height exactly, so there is nothing to move vertically.
    for (const double pan_y : { 0.0, 0.25, 0.5, 1.0 }) {
        EXPECT_EQ(at(0.5, pan_y).viewport_px.y, 0) << pan_y;
        EXPECT_EQ(at(0.5, pan_y).viewport_px.height, 1000) << pan_y;
    }
}

// FIT leaves bars above and below here: the slack is positive, 0 puts the
// picture against the top and 1 against the bottom.
TEST(WallpaperScaling, PanPlacesAFittedWallpaperInsideItsBars) {
    const auto fit = [](double pan_x, double pan_y) {
        return ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000, 1000,
                                             1.0, 1.0, pan_x, pan_y);
    };
    EXPECT_EQ(fit(0.5, 0.0).viewport_px.height, 563);
    EXPECT_EQ(fit(0.5, 0.0).viewport_px.y, 0);
    EXPECT_EQ(fit(0.5, 0.5).viewport_px.y, 219);
    EXPECT_EQ(fit(0.5, 1.0).viewport_px.y, 438);
    EXPECT_EQ(fit(0.5, 1.0).viewport_px.y + fit(0.5, 1.0).viewport_px.height, 1001);
    for (const double pan_x : { 0.0, 0.5, 1.0 }) {
        EXPECT_EQ(fit(pan_x, 0.5).viewport_px.x, 0) << pan_x;
        EXPECT_EQ(fit(pan_x, 0.5).viewport_px.width, 1000) << pan_x;
    }

    // Original size: a small picture is moved around a large display on both axes.
    const auto none = [](double pan_x, double pan_y) {
        return ComputeWallpaperScalingLayout(WallpaperScalingMode::NONE, 100, 50, 400, 300, 1.0,
                                             1.0, pan_x, pan_y);
    };
    EXPECT_EQ(none(0.0, 0.0).viewport_px.x, 0);
    EXPECT_EQ(none(0.0, 0.0).viewport_px.y, 0);
    EXPECT_EQ(none(0.5, 0.5).viewport_px.x, 150);
    EXPECT_EQ(none(0.5, 0.5).viewport_px.y, 125);
    EXPECT_EQ(none(1.0, 1.0).viewport_px.x, 300);
    EXPECT_EQ(none(1.0, 1.0).viewport_px.y, 250);

    // A user scale that makes Fit overflow on both axes reverses the sign of
    // the slack on both; the same fraction still means leading and trailing.
    const auto zoomed = [](double pan_x, double pan_y) {
        return ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000, 1000,
                                             1.0, 3.0, pan_x, pan_y);
    };
    EXPECT_EQ(zoomed(0.0, 0.0).viewport_px.width, 3000);
    EXPECT_EQ(zoomed(0.0, 0.0).viewport_px.x, 0);
    EXPECT_EQ(zoomed(0.0, 0.0).viewport_px.y, 0);
    EXPECT_EQ(zoomed(1.0, 1.0).viewport_px.x + zoomed(1.0, 1.0).viewport_px.width, 1000);
    EXPECT_EQ(zoomed(1.0, 1.0).viewport_px.y + zoomed(1.0, 1.0).viewport_px.height, 1000);
}

// The fraction applies to the slack in points and the result is converted to
// pixels once, so a Retina display lands where a 1x display of twice the size
// would (to within the rounding of the last pixel).
TEST(WallpaperScaling, PanScalesWithTheDisplayScaleFactor) {
    for (const double pan_y : { 0.0, 0.3, 1.0 }) {
        const auto retina = ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080,
                                                          500, 500, 2.0, 1.0, 0.5, pan_y);
        const auto plain  = ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080,
                                                         1000, 1000, 1.0, 1.0, 0.5, pan_y);
        EXPECT_EQ(retina.scissor_px.width, plain.scissor_px.width);
        EXPECT_EQ(retina.scissor_px.height, plain.scissor_px.height);
        // Not a no-op: a picture pinned to the bottom sits lower than one on top.
        EXPECT_NEAR(retina.viewport_px.y, plain.viewport_px.y, 1) << pan_y;
        EXPECT_NEAR(retina.viewport_px.height, plain.viewport_px.height, 1) << pan_y;
        EXPECT_EQ(retina.viewport_px.x, plain.viewport_px.x) << pan_y;
    }
    const auto top = ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 500, 500,
                                                   2.0, 1.0, 0.5, 0.0);
    const auto bottom = ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 500,
                                                      500, 2.0, 1.0, 0.5, 1.0);
    EXPECT_EQ(top.viewport_px.y, 0);
    EXPECT_NEAR(bottom.viewport_px.y, 2 * (500 - 281.25), 1.0);
}

// Stretch at a scale of 1 fills the display exactly, so no fraction can move it.
TEST(WallpaperScaling, AnAxisWithoutSlackIsUnmovedByPan) {
    const auto centred = ComputeWallpaperScalingLayout(WallpaperScalingMode::STRETCH, 1920, 1080,
                                                       1000, 700, 2.0, 1.0);
    for (const double pan : { 0.0, 0.3, 1.0 }) {
        const auto moved = ComputeWallpaperScalingLayout(WallpaperScalingMode::STRETCH, 1920,
                                                         1080, 1000, 700, 2.0, 1.0, pan, pan);
        ExpectSameRect(moved.viewport_px, centred.viewport_px, "viewport");
    }
    EXPECT_EQ(centred.viewport_px.x, 0);
    EXPECT_EQ(centred.viewport_px.y, 0);
}

// `viewport_px.y` is the window row the picture's top edge lands on.
TEST(WallpaperScaling, TopPanTouchesTheTopOfTheWindow) {
    const auto top = ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000,
                                                   1000, 1.0, 1.0, 0.5, 0.0);
    EXPECT_EQ(top.viewport_px.y, 0);

    const auto bottom = ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000,
                                                      1000, 1.0, 1.0, 0.5, 1.0);
    // Only the bottom edge reaches the window's last row (rounding of the
    // half-pixel slack may overshoot it by one).
    EXPECT_NEAR(bottom.viewport_px.y + bottom.viewport_px.height,
                bottom.scissor_px.height, 1);
    // Panning never changes the clip: the window stays the window.
    EXPECT_EQ(bottom.scissor_px.width, top.scissor_px.width);
    EXPECT_EQ(bottom.scissor_px.height, top.scissor_px.height);
}

TEST(WallpaperScaling, NonFinitePanFallsBackToCentreAndOutOfRangeIsClamped) {
    constexpr double nan = std::numeric_limits<double>::quiet_NaN();
    constexpr double inf = std::numeric_limits<double>::infinity();

    const auto centre = NormalizeWallpaperFraming({ nan, -inf });
    EXPECT_EQ(centre.pan_x, 0.5);
    EXPECT_EQ(centre.pan_y, 0.5);
    EXPECT_EQ(NormalizeWallpaperFraming({ inf, nan }).pan_x, 0.5);
    EXPECT_EQ(NormalizeWallpaperFraming({ inf, nan }).pan_y, 0.5);

    const auto clamped = NormalizeWallpaperFraming({ -1.0, 2.0 });
    EXPECT_EQ(clamped.pan_x, 0.0);
    EXPECT_EQ(clamped.pan_y, 1.0);
    const auto inside = NormalizeWallpaperFraming({ 0.25, 0.75 });
    EXPECT_EQ(inside.pan_x, 0.25);
    EXPECT_EQ(inside.pan_y, 0.75);
    EXPECT_EQ(WallpaperFraming {}.pan_x, 0.5);
    EXPECT_EQ(WallpaperFraming {}.pan_y, 0.5);

    // The layout applies the same rules, so a bad value never moves the picture.
    const auto layout_at = [](double pan_x, double pan_y) {
        return ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 1000, 1000,
                                             1.0, 1.0, pan_x, pan_y);
    };
    // The pan is live here: the ends of the range really are different places.
    EXPECT_NE(layout_at(0.0, 0.5).viewport_px.x, layout_at(0.5, 0.5).viewport_px.x);
    EXPECT_NE(layout_at(1.0, 0.5).viewport_px.x, layout_at(0.5, 0.5).viewport_px.x);
    ExpectSameRect(layout_at(nan, nan).viewport_px, layout_at(0.5, 0.5).viewport_px, "nan");
    ExpectSameRect(layout_at(inf, -inf).viewport_px, layout_at(0.5, 0.5).viewport_px, "inf");
    ExpectSameRect(layout_at(-3.0, 0.5).viewport_px, layout_at(0.0, 0.5).viewport_px, "low");
    ExpectSameRect(layout_at(7.0, 0.5).viewport_px, layout_at(1.0, 0.5).viewport_px, "high");
}

// Hit testing derives from the same rectangle the picture is drawn into, so the
// pointer follows a panned wallpaper with no mapping of its own.
TEST(WallpaperScaling, CursorMappingFollowsThePannedPresentation) {
    const auto layout_at = [](double pan_x) {
        return ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 3456, 2234,
                                             1.0, 1.0, pan_x, 0.5);
    };
    const auto map = [](const WallpaperScalingLayout& layout) {
        return ComputeWallpaperCursorMapping(layout, 3840.0, 1080.0, 7680.0, 2160.0);
    };

    const auto left = map(layout_at(0.0));
    ASSERT_TRUE(left.valid);
    // The window's left edge is the scene's left edge.
    EXPECT_NEAR(left.origin_x, 0.0, 1.0e-6);
    EXPECT_NEAR(left.size_x, 3456.0 * 2160.0 / 2234.0, 1.0);

    const auto right = map(layout_at(1.0));
    ASSERT_TRUE(right.valid);
    // The window's right edge is the scene's right edge.
    EXPECT_NEAR(right.origin_x + right.size_x, 7680.0, 1.0);

    const auto centre = map(layout_at(0.5));
    ASSERT_TRUE(centre.valid);
    EXPECT_NEAR(centre.origin_x + 0.5 * centre.size_x, 3840.0, 1.0);

    // The window sees the same width of scene wherever it is panned to.
    EXPECT_NEAR(left.size_x, right.size_x, 1.0e-6);
    EXPECT_NEAR(left.size_x, centre.size_x, 1.0e-6);
    // What is drawn is still exactly the camera rectangle, and the clip is the
    // window, whatever the pan.
    for (const auto* mapping : { &left, &centre, &right }) {
        EXPECT_NEAR(mapping->content_origin_x, 0.0, 1.0e-6);
        EXPECT_NEAR(mapping->content_origin_y, 0.0, 1.0e-6);
        EXPECT_NEAR(mapping->content_size_x, 7680.0, 1.0e-6);
        EXPECT_NEAR(mapping->content_size_y, 2160.0, 1.0e-6);
        EXPECT_NEAR(mapping->origin_y, 0.0, 1.0);
        EXPECT_NEAR(mapping->size_y, 2160.0, 1.0);
    }
    EXPECT_EQ(layout_at(0.0).scissor_px.width, layout_at(1.0).scissor_px.width);
    EXPECT_EQ(layout_at(0.0).scissor_px.height, layout_at(1.0).scissor_px.height);

    // A letterboxed wallpaper pinned to the top has its bars below: the window's
    // top edge is the scene's top edge and the cursor over the bars is outside it.
    const auto fit_top = ComputeWallpaperCursorMapping(
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000, 1000, 1.0, 1.0,
                                      0.5, 0.0),
        960.0, 540.0, 1920.0, 1080.0);
    ASSERT_TRUE(fit_top.valid);
    EXPECT_NEAR(fit_top.origin_y + fit_top.size_y, 1080.0, 2.0);
    EXPECT_LT(fit_top.origin_y, 0.0);
}

} // namespace
} // namespace wallpaper
