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

} // namespace
} // namespace wallpaper::render
