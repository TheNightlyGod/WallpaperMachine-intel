// What an internal render scale is allowed to change, and what it must leave
// alone.
//
// The scale exists to rasterize fewer pixels. It is not a window scale and not
// the wallpaper's fit/fill: the author's canvas, and therefore presentation
// layout and cursor mapping, must resolve to the same numbers at every scale.
// Targets whose size comes from decoded media are not the author's canvas and
// must keep their own resolution.
//
// The raster behind a 2D canvas has two sizes it can start from. `Canvas` is the
// authored size. `Display` is the size the canvas is presented at, so that a
// display with more pixels than the canvas is not fed an upscaled picture. Either
// way the canvas stays the source extent, and the render scale divides whichever
// raster was chosen.

#include "Presentation/WallpaperScaling.hpp"
#include "Scene/Scene.h"
#include "Scene/SpecTexs.hpp"
#include "RenderCommon/SceneRaster.hpp"

#include <gtest/gtest.h>

#include <string>
#include <utility>
#include <vector>

namespace wallpaper::render
{
namespace
{

constexpr Extent2D kOutput { 3840, 2160 };

/// The shape a parsed authored scene has: a default target at the author's
/// canvas size, a screen-bound half-size effect target, and an unbound scratch
/// target the parser sized directly.
void InstallAuthoredTargets(Scene& scene, i32 width, i32 height) {
    scene.scene_extent[0] = width;
    scene.scene_extent[1] = height;
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width           = width,
        .height          = height,
        .authored_width  = width,
        .authored_height = height,
        .bind            = { .enable = true, .screen = true },
    };
    scene.renderTargets["_rt_bloom_mip1"] = SceneRenderTarget {
        .width  = width / 2,
        .height = height / 2,
        .bind   = { .enable = true, .screen = true, .scale = 0.5 },
    };
    scene.renderTargets["_rt_4FrameBuffer"] = SceneRenderTarget {
        .width  = width / 4,
        .height = height / 4,
    };
}

TEST(RenderScale, FullScaleLeavesEveryTargetAtTheAuthoredSize) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    EXPECT_EQ(extents.source.width, 1920u);
    EXPECT_EQ(extents.raster.width, 1920u);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 1920);
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 960);
}

TEST(RenderScale, PerspectiveRasterFollowsTheSurfaceWithoutChangingTheCanvasFallback) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.display_sized = true;
    scene.cameras["global_perspective"] =
        std::make_shared<SceneCamera>(16.0f / 9.0f, 0.01f, 1000.0f, 50.0f);
    for (const auto output : { kOutput, Extent2D { 1800, 1200 } }) {
        for (const double scale : { 1.0, 0.5, 1.0 }) {
            scene.render_scale = scale;
            const auto extents = ResolveScreenBoundRenderTargetSizes(scene, output);
            EXPECT_EQ(extents.source.width, output.width);
            EXPECT_EQ(extents.source.height, output.height);
            EXPECT_EQ(extents.raster.width, output.width * scale);
            EXPECT_EQ(extents.raster.height, output.height * scale);
            EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width,
                      output.width * scale);
            EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, output.width * scale / 2);
            EXPECT_DOUBLE_EQ(scene.cameras.at("global_perspective")->Aspect(),
                             double(output.width) / output.height);
            EXPECT_FLOAT_EQ(scene.cameras.at("global_perspective")->Fov(), 50.0f);
            EXPECT_EQ(scene.scene_extent[0], 1920);
            EXPECT_EQ(scene.scene_extent[1], 1080);
        }
    }
}

TEST(RenderScale, HalfScaleHalvesTheRasterButNotTheAuthoredCanvas) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.render_scale = 0.5;

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    // The canvas the composition is laid out against is untouched. This is what
    // keeps fit/fill and the cursor hit test where they were.
    EXPECT_EQ(extents.source.width, 1920u);
    EXPECT_EQ(extents.source.height, 1080u);

    EXPECT_EQ(extents.raster.width, 960u);
    EXPECT_EQ(extents.raster.height, 540u);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 960);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].height, 540);
    // A screen-bound target keeps its own relative scale on top of the raster.
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 480);
}

TEST(RenderScale, ThreeQuarterScaleRoundsRatherThanTruncates) {
    Scene scene;
    InstallAuthoredTargets(scene, 1366, 768);
    scene.render_scale = 0.75;

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    EXPECT_EQ(extents.raster.width, 1025u); // 1024.5 rounds up
    EXPECT_EQ(extents.raster.height, 576u);
}

TEST(RenderScale, ReturningToFullScaleRestoresTheExactAuthoredSize) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);

    // Deriving each size from the latched authored size rather than from the
    // current one is what stops repeated changes drifting a rounding step at a
    // time until the image no longer matches the canvas.
    for (double scale : { 0.5, 0.75, 0.5, 1.0 }) {
        scene.render_scale = scale;
        ResolveScreenBoundRenderTargetSizes(scene, kOutput);
        ResolveRenderScaledSize(scene.renderTargets["_rt_4FrameBuffer"],
                                ResolveSceneRenderScale(scene));
    }

    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 1920);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].height, 1080);
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 960);
    EXPECT_EQ(scene.renderTargets["_rt_4FrameBuffer"].width, 480);
}

TEST(RenderScale, ScalesBelowTheFloorAreClampedRatherThanHonoured) {
    Scene scene;
    scene.render_scale = 0.01;
    EXPECT_DOUBLE_EQ(ResolveSceneRenderScale(scene), kMinRenderScale);

    scene.render_scale = 4.0;
    EXPECT_DOUBLE_EQ(ResolveSceneRenderScale(scene), 1.0);

    scene.render_scale = std::nan("");
    EXPECT_DOUBLE_EQ(ResolveSceneRenderScale(scene), 1.0);
}

TEST(RenderScale, ASceneWithNoLatchedCanvasStillResolvesAgainstItsOwnSize) {
    // Scenes built before the canvas is latched fall back to the default target
    // and then to the author's ortho, never to the output extent, so a large
    // display cannot silently become the composition size.
    Scene scene;
    scene.ortho[0] = 1600;
    scene.ortho[1] = 900;
    scene.render_scale = 0.5;

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    EXPECT_EQ(extents.source.width, 1600u);
    EXPECT_EQ(extents.raster.width, 800u);
}

TEST(RenderScale, AScreenBoundTargetsResolutionReachesTheMaterialThatSamplesIt) {
    // A target that follows the screen is registered with placeholder
    // dimensions, because the output size is not known while the scene is
    // parsed. `g_TextureNResolution` is folded into the material at that same
    // moment, so without a refresh a shader is handed 2x2 -- and a separable
    // blur, which steps by `1 / g_Texture0Resolution.zw`, then puts every one
    // of its taps outside the texture and returns a flat wash instead of a
    // blur.
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.renderTargets["_rt_QuarterCompoBuffer1"] = SceneRenderTarget {
        .width  = 2,
        .height = 2,
        .bind   = { .enable = true, .screen = true, .scale = 0.25 },
    };

    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial material;
    material.textures = { "_rt_QuarterCompoBuffer1" };
    material.customShader.constValues["g_Texture0Resolution"] =
        std::array<float, 4> { 2.0F, 2.0F, 2.0F, 2.0F };
    mesh->AddMaterial(std::move(material));
    node->AddMesh(mesh);
    scene.sceneGraph = std::make_shared<SceneNode>();
    scene.sceneGraph->AppendChild(node);

    ResolveScreenBoundRenderTargetSizes(scene, kOutput);

    const auto* slot = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(slot, nullptr);
    const auto found = slot->customShader.constValues.find("g_Texture0Resolution");
    ASSERT_NE(found, slot->customShader.constValues.end());
    ASSERT_EQ(found->second.size(), 4u);
    // All four: a blur divides by `.zw`, which a test that only checked the
    // first two would have let stay at the placeholder.
    EXPECT_FLOAT_EQ(found->second[0], 480.0F);
    EXPECT_FLOAT_EQ(found->second[1], 270.0F);
    EXPECT_FLOAT_EQ(found->second[2], 480.0F);
    EXPECT_FLOAT_EQ(found->second[3], 270.0F);
}


// ---------------------------------------------------------------------------
// 2D scene resolution: the Display raster.

/// A 3456x2234 panel backed at 2x, the display class this setting is for.
constexpr Extent2D kLaptop { 3456, 2234 };

SceneRasterSurface Surface(double display_scale_factor, uint32_t max_dimension = 16384) {
    return SceneRasterSurface { .display_scale_factor = display_scale_factor,
                                .max_dimension        = max_dimension };
}

/// The output pixels the presentation lays the canvas over: the FILL layout the
/// renderers present with, scaled by the display's backing factor.
Extent2D PresentedCanvas(Extent2D canvas, Extent2D output, double display_scale_factor) {
    const auto logical_width = static_cast<uint32_t>(std::lround(output.width / display_scale_factor));
    const auto logical_height =
        static_cast<uint32_t>(std::lround(output.height / display_scale_factor));
    const auto layout = ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, canvas.width,
                                                      canvas.height, logical_width, logical_height,
                                                      display_scale_factor, 1.0);
    return { static_cast<uint32_t>(layout.viewport_px.width),
             static_cast<uint32_t>(layout.viewport_px.height) };
}

TEST(RasterResolution, TheEngineDefaultIsTheCanvasAndTheHostSetsItProcessWide) {
    EXPECT_EQ(Scene {}.resolution, SceneResolution::Canvas);
    EXPECT_EQ(CurrentSceneResolution(), SceneResolution::Canvas);

    SetSceneResolution(SceneResolution::Display);
    EXPECT_EQ(CurrentSceneResolution(), SceneResolution::Display);
    SetSceneResolution(SceneResolution::Canvas);
    EXPECT_EQ(CurrentSceneResolution(), SceneResolution::Canvas);
}

TEST(RasterResolution, CanvasModeIgnoresTheDisplayCompletely) {
    for (const double factor : { 1.0, 2.0 }) {
        Scene scene;
        InstallAuthoredTargets(scene, 1920, 1080);
        scene.resolution = SceneResolution::Canvas;

        const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kLaptop, Surface(factor));

        EXPECT_EQ(extents.raster.width, 1920u);
        EXPECT_EQ(extents.raster.height, 1080u);
        EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 1920);
        EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 960);
    }
}

TEST(RasterResolution, DisplayRasterIsTheSizeTheCanvasIsPresentedAt) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.resolution = SceneResolution::Display;

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kLaptop, Surface(2.0));

    // The canvas is filled over a 1728x1117 point panel: height is the short
    // side, so the canvas is 2234 pixels tall and 3971.6 wide, and the
    // presentation crops the width back to the panel.
    const auto presented = PresentedCanvas({ 1920, 1080 }, kLaptop, 2.0);
    EXPECT_EQ(presented.height, 2234u);
    EXPECT_NEAR(presented.width, 3971.6, 1.0);
    EXPECT_EQ(extents.raster.width, presented.width);
    EXPECT_EQ(extents.raster.height, presented.height);
    // The default target is the scene's colour buffer: it is the raster.
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width,
              static_cast<i32>(presented.width));
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].height,
              static_cast<i32>(presented.height));
    // A screen-bound target keeps its fraction of the raster.
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width,
              static_cast<i32>(std::lround(presented.width * 0.5)));
}

TEST(RasterResolution, TheCanvasStaysTheSourceExtentOfEverythingElse) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.resolution = SceneResolution::Display;

    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kLaptop, Surface(2.0));

    // Layout and cursor mapping are computed against the source extent, so a
    // finer raster must not move either.
    EXPECT_EQ(extents.source.width, 1920u);
    EXPECT_EQ(extents.source.height, 1080u);
    EXPECT_EQ(scene.scene_extent[0], 1920);
    EXPECT_EQ(scene.scene_extent[1], 1080);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].authored_width, 1920);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].authored_height, 1080);
}

TEST(RasterResolution, TheRenderScaleDividesTheDisplayRaster) {
    const auto presented = PresentedCanvas({ 1920, 1080 }, kLaptop, 2.0);
    for (const double scale : { 1.0, 0.75, 0.5, 0.25 }) {
        Scene scene;
        InstallAuthoredTargets(scene, 1920, 1080);
        scene.resolution   = SceneResolution::Display;
        scene.render_scale = scale;

        const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kLaptop, Surface(2.0));

        EXPECT_EQ(extents.raster.width, static_cast<uint32_t>(std::lround(presented.width * scale)))
            << scale;
        EXPECT_EQ(extents.raster.height,
                  static_cast<uint32_t>(std::lround(presented.height * scale)))
            << scale;
    }
}

TEST(RasterResolution, AuthorSizedTargetsStillFollowOnlyTheRenderScale) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.resolution   = SceneResolution::Display;
    scene.render_scale = 0.5;

    ResolveScreenBoundRenderTargetSizes(scene, kLaptop, Surface(2.0));
    ResolveRenderScaledSize(scene.renderTargets["_rt_4FrameBuffer"], ResolveSceneRenderScale(scene));

    // An effect's ping-pong buffer is sized by the author, not by the screen:
    // a finer raster does not make it larger.
    EXPECT_EQ(scene.renderTargets["_rt_4FrameBuffer"].width, 240);
    EXPECT_EQ(scene.renderTargets["_rt_4FrameBuffer"].height, 135);
}

TEST(RasterResolution, ADisplaySmallerThanTheCanvasRasterizesFewerPixels) {
    Scene scene;
    InstallAuthoredTargets(scene, 3840, 2160);
    scene.resolution = SceneResolution::Display;

    const auto extents =
        ResolveScreenBoundRenderTargetSizes(scene, Extent2D { 1280, 720 }, Surface(1.0));

    EXPECT_EQ(extents.raster.width, 1280u);
    EXPECT_EQ(extents.raster.height, 720u);
    EXPECT_EQ(extents.source.width, 3840u);
}

TEST(RasterResolution, AnAspectThatDoesNotMatchKeepsTheFillCrop) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.resolution = SceneResolution::Display;

    // A square display: FILL scales the canvas until the short side fits, so
    // the canvas is laid over 1778x1000 and the presentation crops it. The
    // raster keeps the canvas aspect instead of becoming the display's.
    const auto extents =
        ResolveScreenBoundRenderTargetSizes(scene, Extent2D { 1000, 1000 }, Surface(1.0));

    EXPECT_EQ(extents.raster.width, 1778u);
    EXPECT_EQ(extents.raster.height, 1000u);
}

TEST(RasterResolution, TheRasterNeverExceedsWhatTheDeviceCanHold) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    scene.resolution = SceneResolution::Display;

    const auto extents =
        ResolveScreenBoundRenderTargetSizes(scene, Extent2D { 7680, 4320 }, Surface(1.0, 4096));

    // Both sides shrink together, so the canvas aspect survives the cap.
    EXPECT_EQ(extents.raster.width, 4096u);
    EXPECT_EQ(extents.raster.height, 2304u);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 4096);

    // Without a known limit nothing is capped.
    const auto uncapped =
        ResolveScreenBoundRenderTargetSizes(scene, Extent2D { 7680, 4320 }, Surface(1.0, 0));
    EXPECT_EQ(uncapped.raster.width, 7680u);
}

TEST(RasterResolution, SwitchingBackAndForthDoesNotDriftTheSizes) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);

    for (int round = 0; round < 3; ++round) {
        scene.resolution = SceneResolution::Display;
        scene.render_scale = 0.75;
        ResolveScreenBoundRenderTargetSizes(scene, kLaptop, Surface(2.0));
        scene.resolution = SceneResolution::Canvas;
        scene.render_scale = 1.0;
        ResolveScreenBoundRenderTargetSizes(scene, kLaptop, Surface(2.0));
    }

    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 1920);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].height, 1080);
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 960);
}

TEST(RasterResolution, PerspectiveScenesAreAlreadyDisplaySized) {
    for (const auto resolution : { SceneResolution::Canvas, SceneResolution::Display }) {
        Scene scene;
        InstallAuthoredTargets(scene, 1920, 1080);
        scene.display_sized = true;
        scene.cameras["global_perspective"] =
            std::make_shared<SceneCamera>(16.0f / 9.0f, 0.01f, 1000.0f, 50.0f);
        scene.resolution   = resolution;
        scene.render_scale = 0.5;

        const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kLaptop, Surface(2.0));

        EXPECT_EQ(extents.source.width, kLaptop.width);
        EXPECT_EQ(extents.raster.width, kLaptop.width / 2);
        EXPECT_EQ(extents.raster.height, kLaptop.height / 2);
    }
}

TEST(RasterResolution, TheResolutionOnlyMattersToASceneWithACanvasToRasterize) {
    Scene perspective;
    perspective.display_sized = true;
    EXPECT_FALSE(SceneResolutionAffectsRaster(perspective));

    EXPECT_TRUE(SceneResolutionAffectsRaster(Scene {}));
}

// ---- SDR display framing: the window of the cover raster a framed scene draws.

/// How the unframed composition lays a `cover`-sized FILL raster of `canvas` on `output`
/// at `factor`, with the user's `zoom` and position, per axis.
std::pair<RasterAxisPlacement, RasterAxisPlacement>
FillPlacement(Extent2D canvas, Extent2D output, double factor, double zoom = 1.0,
              double pan_x = 0.5, double pan_y = 0.5) {
    const auto logical = [factor](uint32_t pixels) {
        return static_cast<uint32_t>(std::lround(pixels / factor));
    };
    const auto layout = ComputeWallpaperScalingLayout(
        WallpaperScalingMode::FILL, canvas.width, canvas.height, logical(output.width),
        logical(output.height), factor, zoom, pan_x, pan_y);
    return { RasterAxisPlacement { double(layout.viewport_px.x), double(layout.viewport_px.width),
                                   output.width },
             RasterAxisPlacement { double(layout.viewport_px.y), double(layout.viewport_px.height),
                                   output.height } };
}

TEST(RasterWindow, AWiderCanvasDrawsOnlyThePartTheOutputShows) {
    // A 5120x2160 canvas filled over a 3840x2160 display at 2x: the cover raster is 5120
    // wide and the composition shows the 3840 pixels in its middle, 1:1.
    const Extent2D cover { 5120, 2160 };
    const auto [x, y] = FillPlacement({ 5120, 2160 }, kOutput, 2.0);
    const auto window = PlanSceneRasterWindow(cover, x, y, 4, false);
    EXPECT_TRUE(window.Framed());
    EXPECT_EQ(window.x, 640u);
    EXPECT_EQ(window.y, 0u);
    EXPECT_EQ(window.size.width, 3840u);
    EXPECT_EQ(window.size.height, 2160u);
    // The canvas, which fills the cover raster, overhangs the window by 640 on each side.
    const auto clip = SceneRasterWindowClip(window);
    EXPECT_DOUBLE_EQ(clip[0], 5120.0 / 3840.0);
    EXPECT_DOUBLE_EQ(clip[1], 1.0);
    EXPECT_DOUBLE_EQ(clip[2], 0.0);
    EXPECT_DOUBLE_EQ(clip[3], 0.0);
    // The composition puts the window where its texels sit: the whole output.
    const auto [left, width] = RasterWindowFootprint(cover.width, window.x, window.size.width,
                                                     x.origin, x.extent, false);
    EXPECT_DOUBLE_EQ(left, 0.0);
    EXPECT_DOUBLE_EQ(width, 3840.0);
}

TEST(RasterWindow, AMinifiedRasterKeepsTheBilinearPairOfEveryVisiblePixel) {
    // 16:9 on the 3456x2234 panel at render scale 0.75: the 3972-pixel cover becomes 2979
    // texels, and the composition samples 0.75 texels per output pixel starting 258 pixels
    // left of the output. Its first pixel samples texel 193.375: the pair 193 and 194.
    const Extent2D cover { 2979, 1676 };
    const auto [x, y] = FillPlacement({ 3840, 2160 }, kLaptop, 2.0);
    ASSERT_EQ(x.origin, -258.0);
    ASSERT_EQ(x.extent, 3972.0);
    const auto window = PlanSceneRasterWindow(cover, x, y, 1, false);
    EXPECT_EQ(window.x, 193u);
    // The last output pixel samples 2784.625: texels 2784 and 2785.
    EXPECT_EQ(window.x + window.size.width, 2786u);
    EXPECT_EQ(window.size.height, 1676u);
}

TEST(RasterWindow, AWindowCutsOnlyAtTheGridOfTheScreenTargetsItSamples) {
    const Extent2D cover { 3972, 2234 };
    const auto [x, y] = FillPlacement({ 1920, 1080 }, kLaptop, 2.0);
    // Quarter-size targets: the 258-pixel crop rounds out to 256 and 3716.
    const auto quarter = PlanSceneRasterWindow(cover, x, y, 4, false);
    EXPECT_EQ(quarter.x, 256u);
    EXPECT_EQ(quarter.size.width, 3460u);
    EXPECT_EQ(quarter.x % 4, 0u);
    EXPECT_EQ(quarter.size.width % 4, 0u);
    // Eighth-size targets cannot keep a 3972-pixel raster's grid (496.5 texels): nothing is
    // framed rather than drawing them at another pitch.
    EXPECT_FALSE(PlanSceneRasterWindow(cover, x, y, 8, false).Framed());
    // Nor without a known grid.
    EXPECT_FALSE(PlanSceneRasterWindow(cover, x, y, 0, false).Framed());
}

TEST(RasterWindow, AnOddCropKeepsTheCoverRastersOwnPixels) {
    // A 101-wide canvas on a 64x64 output: the cover is 101 wide and starts 19 pixels left of
    // the output (half of 37, rounded away from zero), an odd offset.
    const Extent2D cover { 101, 64 };
    const auto [x, y] = FillPlacement({ 101, 64 }, { 64, 64 }, 1.0);
    ASSERT_EQ(x.origin, -19.0);
    const auto window = PlanSceneRasterWindow(cover, x, y, 1, false);
    EXPECT_EQ(window.x, 19u);
    EXPECT_EQ(window.size.width, 64u);
    // With half-size targets the window starts and ends on even texels: a 102-wide canvas
    // starts 19 pixels out too, and its window is cut at 18 and 84.
    const auto [even_x, even_y] = FillPlacement({ 102, 64 }, { 64, 64 }, 1.0);
    ASSERT_EQ(even_x.origin, -19.0);
    const auto halves = PlanSceneRasterWindow(Extent2D { 102, 64 }, even_x, even_y, 2, false);
    EXPECT_EQ(halves.x, 18u);
    EXPECT_EQ(halves.size.width, 66u);
    // A cover that is itself odd cannot keep half-size targets' grid.
    EXPECT_FALSE(PlanSceneRasterWindow(cover, x, y, 2, false).Framed());
}

TEST(RasterWindow, ThePictureMovesInsideAWindowWithHeadroom) {
    const Extent2D cover { 5120, 2160 };
    const auto [x, y] = FillPlacement({ 5120, 2160 }, kOutput, 2.0);
    auto exact = PlanSceneRasterWindow(cover, x, y, 4, false);
    auto roomy = PlanSceneRasterWindow(cover, x, y, 4, true);
    EXPECT_GT(roomy.size.width, exact.size.width);
    EXPECT_LE(roomy.size.width, exact.size.width + 8);
    for (const double pan : { 0.0, 0.13, 0.5, 0.77, 1.0 }) {
        SCOPED_TRACE(pan);
        const auto [moved_x, moved_y] = FillPlacement({ 5120, 2160 }, kOutput, 2.0, 1.0, pan);
        EXPECT_TRUE(PlaceSceneRasterWindow(roomy, moved_x, moved_y, 4));
        EXPECT_EQ(roomy.x % 4, 0u);
        const auto sampled = moved_x.origin;
        // The window holds every texel the moved composition reads.
        EXPECT_LE(double(roomy.x), -sampled);
        EXPECT_GE(double(roomy.x + roomy.size.width), -sampled + 3840.0);
    }
    // Without headroom a move to the edge leaves the window and is refused, as it was.
    const auto before = exact;
    const auto [edge_x, edge_y] = FillPlacement({ 5120, 2160 }, kOutput, 2.0, 1.0, 0.13);
    EXPECT_FALSE(PlaceSceneRasterWindow(exact, edge_x, edge_y, 4));
    EXPECT_EQ(exact.x, before.x);
}

TEST(RasterWindow, AZoomedInPictureFitsTheWindowOfAZoomOfOne) {
    const Extent2D cover { 5120, 2160 };
    const auto [x, y] = FillPlacement({ 5120, 2160 }, kOutput, 2.0);
    auto window = PlanSceneRasterWindow(cover, x, y, 4, false);
    for (const double zoom : { 1.0, 1.25, 2.0, 3.5 }) {
        SCOPED_TRACE(zoom);
        const auto [zx, zy] = FillPlacement({ 5120, 2160 }, kOutput, 2.0, zoom);
        EXPECT_TRUE(PlaceSceneRasterWindow(window, zx, zy, 4));
    }
}

TEST(RasterWindow, FitAndStretchShowTheWholeCanvasSoNothingIsCut) {
    const Extent2D cover { 3972, 2234 };
    for (const auto mode : { WallpaperScalingMode::FIT, WallpaperScalingMode::STRETCH }) {
        SCOPED_TRACE(static_cast<int>(mode));
        const auto layout = ComputeWallpaperScalingLayout(mode, 1920, 1080, 1728, 1117, 2.0, 1.0);
        const RasterAxisPlacement x { double(layout.viewport_px.x), double(layout.viewport_px.width),
                                      kLaptop.width };
        const RasterAxisPlacement y { double(layout.viewport_px.y), double(layout.viewport_px.height),
                                      kLaptop.height };
        EXPECT_FALSE(PlanSceneRasterWindow(cover, x, y, 1, false).Framed());
    }
}

TEST(RasterWindow, AFlippedCompositionReadsTheMirroredSpan) {
    // Off-centre and flipped: the composition reads the raster right to left, so what it
    // shows is what an unflipped one shows with the viewport mirrored about the output.
    const Extent2D cover { 5120, 2160 };
    const auto [x, y] = FillPlacement({ 5120, 2160 }, kOutput, 2.0, 1.0, 0.2);
    RasterAxisPlacement mirrored = x;
    mirrored.origin = kOutput.width - x.origin - x.extent;
    const auto window = PlanSceneRasterWindow(cover, mirrored, y, 1, false);
    EXPECT_EQ(window.x, static_cast<uint32_t>(-mirrored.origin));
    // The flipped footprint puts the window's right edge where its texels' mirror image is.
    const auto [left, width] = RasterWindowFootprint(cover.width, window.x, window.size.width,
                                                     x.origin, x.extent, true);
    EXPECT_DOUBLE_EQ(left + width, x.origin + x.extent - window.x);
}

TEST(RasterWindow, PlannedSizingDrawsTheWindowAndKeepsTheFractions) {
    Scene scene;
    InstallAuthoredTargets(scene, 5120, 2160);
    scene.resolution     = SceneResolution::Display;
    scene.display_framed = true;
    auto surface         = Surface(2.0);
    EXPECT_EQ(ResolveSceneCoverRaster(scene, kOutput, surface).width, 5120u);
    surface.window = { 3840, 2160 };
    const auto extents = ResolveScreenBoundRenderTargetSizes(scene, kOutput, surface);
    EXPECT_EQ(extents.raster.width, 3840u);
    EXPECT_EQ(extents.source.width, 5120u);
    EXPECT_EQ(scene.renderTargets[std::string(SpecTex_Default)].width, 3840);
    EXPECT_EQ(scene.renderTargets["_rt_bloom_mip1"].width, 1920);
    EXPECT_EQ(scene.renderTargets["_rt_4FrameBuffer"].width, 1280);
    // Unframed, the same surface draws the whole cover raster.
    scene.display_framed = false;
    EXPECT_EQ(ResolveScreenBoundRenderTargetSizes(scene, kOutput, surface).raster.width, 5120u);
}

TEST(RasterWindow, TheGridIsTheFinestFractionOfTheRasterAScreenTargetIsDrawnAt) {
    Scene scene;
    InstallAuthoredTargets(scene, 1920, 1080);
    const std::string output(SpecTex_Default);
    scene.renderTargets["_rt_quarter"] = SceneRenderTarget {
        .width = 1, .height = 1, .bind = { .enable = true, .name = "_rt_bloom_mip1", .scale = 0.5 } };
    scene.renderTargets["_rt_third"] = SceneRenderTarget {
        .width = 1, .height = 1, .bind = { .enable = true, .screen = true, .scale = 1.0 / 3.0 } };
    scene.renderTargets["_rt_mips"] = SceneRenderTarget {
        .width = 1, .height = 1, .has_mipmap = true, .mipmap_level = 9,
        .bind = { .enable = true, .name = output } };
    using Keys = std::vector<std::string>;
    EXPECT_EQ(ScreenBoundWindowAlignment(scene, Keys { output }), 1u);
    EXPECT_EQ(ScreenBoundWindowAlignment(scene, Keys { output, "_rt_bloom_mip1" }), 2u);
    EXPECT_EQ(ScreenBoundWindowAlignment(scene, Keys { output, "_rt_quarter" }), 4u);
    EXPECT_EQ(ScreenBoundWindowAlignment(scene, Keys { "_rt_quarter", "_rt_third" }), 12u);
    // An author-sized target is not cut by the window, whatever its size.
    EXPECT_EQ(ScreenBoundWindowAlignment(scene, Keys { output, "_rt_4FrameBuffer" }), 1u);
    // A mip chain of the frame would need its smallest level's grid: no window at all.
    EXPECT_EQ(ScreenBoundWindowAlignment(scene, Keys { output, "_rt_mips" }), 0u);
}

} // namespace
} // namespace wallpaper::render
