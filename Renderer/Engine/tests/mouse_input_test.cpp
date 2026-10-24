#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scripting/ScriptEngine.hpp"
#include "Scene/SceneNode.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <cmath>
#include <memory>
#include <utility>

namespace wallpaper
{
namespace
{

// The presented image is the camera rectangle stretched into the scaling
// viewport, which FILL pushes outside the window. Cursor coordinates have to
// follow that rectangle: mapping them onto the raw canvas compresses every hit
// box toward the screen centre on scenes whose aspect differs from the display.
TEST(MouseInput, CursorViewportMapsWindowOntoTheCroppedSceneRectangle) {
    const auto filled =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 3456, 2234, 1.0, 1.0);
    const auto crop = ComputeWallpaperCursorMapping(filled, 3840.0, 1080.0, 7680.0, 2160.0);
    ASSERT_TRUE(crop.valid);
    // A FILL crop keeps the full scene height and shows
    // window_width * scene_height / window_height scene units horizontally.
    EXPECT_NEAR(crop.size_x, 3456.0 * 2160.0 / 2234.0, 1.0);
    EXPECT_NEAR(crop.origin_x, 3840.0 - 0.5 * 3456.0 * 2160.0 / 2234.0, 1.0);
    EXPECT_NEAR(crop.origin_y, 0.0, 1.0);
    EXPECT_NEAR(crop.size_y, 2160.0, 1.0);

    const auto letterboxed =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000, 1000, 1.0, 1.0);
    const auto fit = ComputeWallpaperCursorMapping(letterboxed, 960.0, 540.0, 1920.0, 1080.0);
    ASSERT_TRUE(fit.valid);
    EXPECT_NEAR(fit.origin_x, 0.0, 1.0);
    EXPECT_NEAR(fit.size_x, 1920.0, 1.0);
    // Cursor positions over the letterbox bars stay outside the scene, and the
    // drawn content stays the camera rectangle.
    EXPECT_LT(fit.origin_y, 0.0);
    EXPECT_GT(fit.origin_y + fit.size_y, 1080.0);
    EXPECT_NEAR(fit.origin_y + 0.5 * fit.size_y, 540.0, 1.0);
    EXPECT_NEAR(fit.content_origin_x, 0.0, 1.0e-6);
    EXPECT_NEAR(fit.content_origin_y, 0.0, 1.0e-6);
    EXPECT_NEAR(fit.content_size_x, 1920.0, 1.0e-6);
    EXPECT_NEAR(fit.content_size_y, 1080.0, 1.0e-6);

    EXPECT_FALSE(ComputeWallpaperCursorMapping(filled, 3840.0, 1080.0, 0.0, 2160.0).valid);
    EXPECT_FALSE(ComputeWallpaperCursorMapping({}, 3840.0, 1080.0, 7680.0, 2160.0).valid);
}

TEST(MouseInput, LayerHitTestingFollowsWhereTheWallpaperIsPresented) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 7680,
        .canvas_height = 2160,
    });
    ASSERT_NE(runtime, nullptr);

    auto layer = std::make_shared<SceneNode>();
    layer->SetTranslate(linalg::Vector3f(3850.0f, 865.0f, 0.0f));
    runtime->RegisterNode("layer", layer.get());
    runtime->RegisterNodeSize("layer", linalg::Vector2f(275.0f, 134.0f));
    auto marker = std::make_shared<SceneNode>();
    marker->SetVisible(false);
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(
        R"JS(
function cursorEnter() { scene.getObject('marker').visible = true; }
function cursorLeave() { scene.getObject('marker').visible = false; }
)JS",
        "layer");

    const auto layout =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 3456, 2234, 1.0, 1.0);
    const auto mapping = ComputeWallpaperCursorMapping(layout, 3840.0, 1080.0, 7680.0, 2160.0);
    ASSERT_TRUE(mapping.valid);
    runtime->SetCursorViewport(CursorViewport {
        .origin = linalg::Vector2f(static_cast<float>(mapping.origin_x),
                                  static_cast<float>(mapping.origin_y)),
        .size =
            linalg::Vector2f(static_cast<float>(mapping.size_x), static_cast<float>(mapping.size_y)),
        .content_origin = linalg::Vector2f(static_cast<float>(mapping.content_origin_x),
                                          static_cast<float>(mapping.content_origin_y)),
        .content_size   = linalg::Vector2f(static_cast<float>(mapping.content_size_x),
                                        static_cast<float>(mapping.content_size_y)),
    });

    // Where the presented wallpaper draws a scene point, in window fractions.
    const auto screen_x = [&](double world) {
        const double fraction = (world - 3840.0) / 7680.0 + 0.5;
        return (fraction * layout.viewport_px.width + layout.viewport_px.x) / 3456.0;
    };
    const auto screen_y = [&](double world) {
        const double fraction = 0.5 - (world - 1080.0) / 2160.0;
        return (fraction * layout.viewport_px.height + layout.viewport_px.y) / 2234.0;
    };

    runtime->SetCursorEnter(true);
    bool       cursor_was_in_window = false;
    const auto hover                = [&](double world_x, double world_y) {
        runtime->SetCursorInput(static_cast<float>(screen_x(world_x)),
                                static_cast<float>(screen_y(world_y)));
        cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
        runtime->Tick(1.0 / 60.0);
        return runtime->NodeVisible("marker");
    };

    EXPECT_TRUE(hover(3850.0, 865.0));
    // Near the drawn left and right edges, far outside the canvas-relative
    // fraction the window would map to without the presentation rectangle.
    EXPECT_TRUE(hover(3850.0 - 130.0, 865.0));
    EXPECT_TRUE(hover(3850.0 + 130.0, 865.0));
    EXPECT_FALSE(hover(3850.0 + 200.0, 865.0));
    EXPECT_FALSE(hover(3850.0, 865.0 + 100.0));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A camera object's zoom moves the image without touching the authored canvas,
// so pointer mapping has to read the extent that was projected. Reading the
// authored width and height instead leaves clicks on the unzoomed picture:
// right at the centre, wrong everywhere else, and wrong by more the further out
// and the more the window is reshaped.
//
// The cursor position here is derived from the projection matrix -- where the
// drawn frame actually puts that scene point -- not from the mapping under
// test, so the two have to agree for the layer to be hit.
TEST(MouseInput, HitTestingFollowsACameraObjectZoomAcrossAResize) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    // Off centre, where a zoomed and an unzoomed mapping disagree, and inside
    // the tighter frustum so the probe never leaves the drawn rectangle.
    auto layer = std::make_shared<SceneNode>();
    layer->SetTranslate(linalg::Vector3f(1200.0f, 540.0f, 0.0f));
    runtime->RegisterNode("layer", layer.get());
    runtime->RegisterNodeSize("layer", linalg::Vector2f(80.0f, 80.0f));
    auto marker = std::make_shared<SceneNode>();
    marker->SetVisible(false);
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(
        R"JS(
function cursorEnter() { scene.getObject('marker').visible = true; }
function cursorLeave() { scene.getObject('marker').visible = false; }
)JS",
        "layer");

    // The scene's own ortho camera: parked at the canvas centre, zoomed 2x.
    auto camera_node = std::make_shared<SceneNode>();
    camera_node->SetTranslate(linalg::Vector3f(960.0f, 540.0f, 0.0f));
    SceneCamera camera(1920, 1080, -5000.0f, 5000.0f);
    camera.AttatchNode(camera_node);
    camera.SetZoom(2.0);
    camera.Update();
    EXPECT_DOUBLE_EQ(camera.VisibleWidth(), 960.0);
    EXPECT_DOUBLE_EQ(camera.VisibleHeight(), 540.0);

    runtime->SetCursorEnter(true);
    bool cursor_was_in_window = false;
    // Each window size is a fresh presentation: the mapping is recomputed the
    // way both render backends recompute it after a resize.
    const auto hover = [&](unsigned window_w, unsigned window_h, double world_x, double world_y) {
        const auto layout = ComputeWallpaperScalingLayout(
            WallpaperScalingMode::FILL, 1920, 1080, window_w, window_h, 1.0, 1.0);
        const auto mapping = ComputeWallpaperCursorMapping(layout, 960.0, 540.0,
                                                           camera.VisibleWidth(),
                                                           camera.VisibleHeight());
        EXPECT_TRUE(mapping.valid);
        runtime->SetCursorViewport(CursorViewport {
            .origin = linalg::Vector2f(static_cast<float>(mapping.origin_x),
                                      static_cast<float>(mapping.origin_y)),
            .size   = linalg::Vector2f(static_cast<float>(mapping.size_x),
                                    static_cast<float>(mapping.size_y)),
            .content_origin = linalg::Vector2f(static_cast<float>(mapping.content_origin_x),
                                              static_cast<float>(mapping.content_origin_y)),
            .content_size   = linalg::Vector2f(static_cast<float>(mapping.content_size_x),
                                            static_cast<float>(mapping.content_size_y)),
        });
        // Ground truth: the projection the frame is drawn with, taken to window
        // fractions through the presented viewport rectangle.
        const linalg::Vector4d clip =
            camera.GetViewProjectionMatrix() * linalg::Vector4d(world_x, world_y, 0.0, 1.0);
        const double ndc_x = clip.x() / clip.w();
        const double ndc_y = clip.y() / clip.w();
        const double px = layout.viewport_px.x + (ndc_x * 0.5 + 0.5) * layout.viewport_px.width;
        const double py = layout.viewport_px.y + (0.5 - ndc_y * 0.5) * layout.viewport_px.height;
        runtime->SetCursorInput(static_cast<float>(px / window_w),
                                static_cast<float>(py / window_h));
        cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
        runtime->Tick(1.0 / 60.0);
        return runtime->NodeVisible("marker");
    };

    EXPECT_TRUE(hover(1920, 1080, 1200.0, 540.0));
    EXPECT_FALSE(hover(1920, 1080, 1200.0 + 120.0, 540.0));
    // Same layer, a differently shaped window: the zoom must survive the
    // fill-mode rewrite of the camera's authored width and height.
    EXPECT_TRUE(hover(2560, 1080, 1200.0, 540.0));
    EXPECT_FALSE(hover(2560, 1080, 1200.0 + 120.0, 540.0));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A letterboxed presentation leaves window area the wallpaper never draws.
// Extrapolated coordinates there must not reach layers that extend past the
// canvas edge, or the bars behave like an invisible extension of the scene.
TEST(MouseInput, LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    // Half of this layer hangs below the canvas, so it is drawn only down to
    // the bottom edge of the wallpaper.
    auto layer = std::make_shared<SceneNode>();
    layer->SetTranslate(linalg::Vector3f(960.0f, 40.0f, 0.0f));
    runtime->RegisterNode("layer", layer.get());
    runtime->RegisterNodeSize("layer", linalg::Vector2f(400.0f, 200.0f));
    auto marker = std::make_shared<SceneNode>();
    marker->SetVisible(false);
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(
        R"JS(
function cursorEnter() { scene.getObject('marker').visible = true; }
function cursorLeave() { scene.getObject('marker').visible = false; }
)JS",
        "layer");

    const auto layout =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000, 1000, 1.0, 1.0);
    const auto mapping = ComputeWallpaperCursorMapping(layout, 960.0, 540.0, 1920.0, 1080.0);
    ASSERT_TRUE(mapping.valid);
    runtime->SetCursorViewport(CursorViewport {
        .origin = linalg::Vector2f(static_cast<float>(mapping.origin_x),
                                  static_cast<float>(mapping.origin_y)),
        .size =
            linalg::Vector2f(static_cast<float>(mapping.size_x), static_cast<float>(mapping.size_y)),
        .content_origin = linalg::Vector2f(static_cast<float>(mapping.content_origin_x),
                                          static_cast<float>(mapping.content_origin_y)),
        .content_size   = linalg::Vector2f(static_cast<float>(mapping.content_size_x),
                                        static_cast<float>(mapping.content_size_y)),
    });

    runtime->SetCursorEnter(true);
    bool       cursor_was_in_window = false;
    const auto hover                = [&](float x, float y) {
        runtime->SetCursorInput(x, y);
        cursor_was_in_window = runtime->DispatchCursorFrameEvents(cursor_was_in_window);
        runtime->Tick(1.0 / 60.0);
        return runtime->NodeVisible("marker");
    };

    // Bottom edge of the drawn wallpaper, over the layer.
    const double drawn_bottom_px = layout.viewport_px.y + layout.viewport_px.height;
    EXPECT_TRUE(hover(0.5f, static_cast<float>((drawn_bottom_px - 1.0) / 1000.0)));
    // Just below it, on the bar. The extrapolated scene position is still
    // inside the layer's box, but the wallpaper draws nothing there.
    runtime->SetCursorInput(0.5f, static_cast<float>((drawn_bottom_px + 8.0) / 1000.0));
    const float bar_world_y = runtime->hostContext().cursor_world_position.y();
    EXPECT_LT(bar_world_y, 0.0f);
    EXPECT_GT(bar_world_y, -60.0f);
    EXPECT_FALSE(hover(0.5f, static_cast<float>((drawn_bottom_px + 8.0) / 1000.0)));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(MouseInput, StationarySampleRemapsEveryFrameAndRechecksLiveLayerGeometry) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width = 200,
        .canvas_height = 100,
    });
    auto layer = std::make_shared<SceneNode>();
    auto marker = std::make_shared<SceneNode>();
    layer->SetTranslate(linalg::Vector3f(100, 50, 0));
    runtime->RegisterNode("layer", layer.get());
    runtime->RegisterNodeSize("layer", linalg::Vector2f(20, 20));
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(R"JS(
function emit(component) {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin[component] += 1;
    marker.origin = origin;
}
function cursorEnter() { emit('x'); }
function cursorLeave() { emit('y'); }
function cursorMove() { emit('z'); }
)JS", "layer");
    // One window-normalized sample, retained by the native renderer even when
    // the Rust delivery cache suppresses all subsequent identical writes.
    const linalg::Vector2f sample(0.5f, 0.5f);
    bool was_inside = false;
    const auto frame = [&](const CursorViewport& viewport) {
        runtime->BeginFrame();
        runtime->SetCursorViewport(viewport);
        runtime->SetCursorInput(sample.x(), sample.y());
        runtime->SetCursorEnter(true);
        was_inside = runtime->DispatchCursorFrameEvents(was_inside);
    };
    frame(CursorViewport { .origin = linalg::Vector2f::Zero(), .size = linalg::Vector2f(200, 100) });
    EXPECT_TRUE(runtime->hostContext().cursor_world_position.isApprox(linalg::Vector3f(100, 50, 0)));
    EXPECT_TRUE(marker->Translate().isApprox(linalg::Vector3f(1, 0, 1)));
    frame(CursorViewport { .origin = linalg::Vector2f(100, 0), .size = linalg::Vector2f(200, 100) });
    EXPECT_TRUE(runtime->hostContext().cursor_world_position.isApprox(linalg::Vector3f(200, 50, 0)));
    EXPECT_TRUE(marker->Translate().isApprox(linalg::Vector3f(1, 1, 1)));
    layer->SetTranslate(linalg::Vector3f(200, 50, 0));
    frame(CursorViewport { .origin = linalg::Vector2f(100, 0), .size = linalg::Vector2f(200, 100) });
    EXPECT_TRUE(marker->Translate().isApprox(linalg::Vector3f(2, 1, 2)));
    frame(CursorViewport {
        .origin = linalg::Vector2f(100, 0), .size = linalg::Vector2f(200, 100),
        .content_origin = linalg::Vector2f(0, 0), .content_size = linalg::Vector2f(100, 100),
    });
    EXPECT_TRUE(marker->Translate().isApprox(linalg::Vector3f(2, 2, 2)));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(MouseInput, GlobalReleaseRemainsObservableOutsidePresentedContentAndWindow) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto marker = std::make_shared<SceneNode>();
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(
        R"JS(function cursorUp() {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.x += 1;
    marker.origin = origin;
})JS", "");
    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(0, 0, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 1.0f);
    runtime->SetCursorViewport(CursorViewport {
        .origin = linalg::Vector2f::Zero(), .size = linalg::Vector2f(200, 100),
        .content_origin = linalg::Vector2f::Zero(), .content_size = linalg::Vector2f(20, 20),
    });
    runtime->SetCursorInput(0.5f, 0.5f);
    runtime->SetCursorEnter(true);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 2.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(MouseInput, HiddenCallbackHelperDrivesOverlayAcrossProjectedOpaqueEnterAndExit) {
    Scene scene;
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width = 1920,
        .canvas_height = 1080,
    });
    runtime->AttachScene(&scene);
    auto camera_node = std::make_shared<SceneNode>();
    camera_node->SetTranslate(linalg::Vector3f(0, 0, 100));
    auto lens = std::make_shared<SceneCamera>(1920.0f / 1080.0f, 0.1f, 500.0f, 45.0f);
    lens->AttatchNode(camera_node);
    scene.cameras["lens"] = lens;
    auto canvas_camera = std::make_shared<SceneCamera>(1920, 1080, -5000.0f, 5000.0f);
    scene.activeCamera = canvas_camera.get();

    auto parent = std::make_shared<SceneNode>();
    parent->SetTranslate(linalg::Vector3f(12, 8, 0));
    parent->SetScale(linalg::Vector3f(1.3f, 0.8f, 1));
    parent->SetRotation(linalg::Vector3f(0, 0, 0.2f));
    auto helper = std::make_shared<SceneNode>();
    helper->SetTranslate(linalg::Vector3f(3, -2, -5));
    helper->SetRotation(linalg::Vector3f(0.3f, 0, 0));
    helper->SetCamera("lens");
    parent->AppendChild(helper);
    auto overlay = std::make_shared<SceneNode>();
    runtime->RegisterNode("overlay", overlay.get());
    runtime->RegisterNode("helper", helper.get());
    runtime->RegisterNodeSize("helper", linalg::Vector2f(20, 20));
    runtime->RegisterNodeHitMask("helper", NodeHitMask {
        .width = 2, .height = 1, .alpha = {255, 0},
    });
    runtime->RegisterNodeVisibility("helper", helper.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
shared.highlighted = false;
export function cursorEnter() {
    shared.highlighted = true;
    const overlay = thisScene.getLayer('overlay');
    const origin = overlay.origin;
    origin.x++;
    overlay.origin = origin;
}
export function cursorLeave() {
    shared.highlighted = false;
    const overlay = thisScene.getLayer('overlay');
    const origin = overlay.origin;
    origin.y++;
    overlay.origin = origin;
}
)JS"},
    }, "helper"));
    auto material = std::make_shared<SceneMaterial>();
    material->customShader.constValues["g_Alpha"] = ShaderValue(0.0f);
    runtime->BindMaterialAlpha(material, ResolveFloatSetting(*runtime, {
        {"value", 0.0f}, {"script", R"JS(
export function update(value) {
    return value + ((shared.highlighted ? 1 : 0) - value) * 0.5;
}
)JS"},
    }, "overlay"));
    runtime->Tick(0.01);
    EXPECT_FALSE(helper->Visible());
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Alpha")[0], 0.0f);

    bool was_in_window = false;
    const auto pointer_at = [&](double local_x) {
        helper->UpdateTrans();
        const linalg::Vector4d clip = lens->GetViewProjectionMatrix() *
            helper->ModelTrans() * linalg::Vector4d(local_x, 0, 0, 1);
        runtime->SetCursorInput(static_cast<float>(0.5 + 0.5 * clip.x() / clip.w()),
                                static_cast<float>(0.5 - 0.5 * clip.y() / clip.w()));
        runtime->SetCursorEnter(true);
        was_in_window = runtime->DispatchCursorFrameEvents(was_in_window);
        runtime->Tick(0.01);
        return material->customShader.constValues.at("g_Alpha")[0];
    };
    EXPECT_FLOAT_EQ(pointer_at(5), 0.0f); // Transparent part is not a hit.
    EXPECT_FLOAT_EQ(pointer_at(-5), 0.5f);
    EXPECT_TRUE(overlay->Translate().isApprox(linalg::Vector3f(1, 0, 0)));
    EXPECT_FLOAT_EQ(pointer_at(-5), 0.75f);
    EXPECT_TRUE(overlay->Translate().isApprox(linalg::Vector3f(1, 0, 0)));
    EXPECT_FLOAT_EQ(pointer_at(5), 0.375f); // Crossing coverage exits once.
    EXPECT_TRUE(overlay->Translate().isApprox(linalg::Vector3f(1, 1, 0)));
    EXPECT_FLOAT_EQ(pointer_at(-5), 0.6875f);
    runtime->SetCursorEnter(false);
    was_in_window = runtime->DispatchCursorFrameEvents(was_in_window);
    runtime->Tick(0.01);
    EXPECT_FALSE(was_in_window);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Alpha")[0], 0.34375f);
    EXPECT_TRUE(overlay->Translate().isApprox(linalg::Vector3f(2, 2, 0)));
    EXPECT_FALSE(helper->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// Which layers the cursor reaches. Wallpaper Engine walks the layers from the
// front and only tests those that are `solid` image, text or model layers; a
// visible layer under the cursor with `disablepropagation` ends the walk, so
// nothing behind it is visited, entered, left or moved over.
namespace
{
// A 1920x1080 scene of square layers, each marked by a script that shows its
// marker on `cursorEnter` and hides it on `cursorLeave`.
struct CursorStage {
    std::unique_ptr<SceneRuntimeContext>      runtime;
    std::vector<std::shared_ptr<SceneNode>>   nodes;
    bool                                      was_in_window { false };

    CursorStage() {
        runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
            .canvas_width = 1920, .canvas_height = 1080 });
    }

    // Layers register back to front, as the scene lists them.
    void AddLayer(const std::string& name, float x, float size = 100.0f, bool script = true) {
        auto node = std::make_shared<SceneNode>();
        node->SetTranslate(linalg::Vector3f(x, 500.0f, 0.0f));
        runtime->RegisterNode(name, node.get());
        runtime->RegisterNodeSize(name, linalg::Vector2f(size, size));
        nodes.push_back(node);
        order.push_back(name);
        runtime->SetLayerOrder(order);
        if (! script) return;
        auto marker = std::make_shared<SceneNode>();
        marker->SetVisible(false);
        runtime->RegisterNode(name + " marker", marker.get());
        nodes.push_back(marker);
        runtime->RegisterSceneScript(
            "function cursorEnter() { scene.getObject('" + name + " marker').visible = true; }\n"
            "function cursorLeave() { scene.getObject('" + name + " marker').visible = false; }\n",
            name);
    }

    // Puts the cursor at scene point (x, 500) and lets the frame's events run.
    void MoveTo(float x) {
        runtime->SetCursorInput(x / 1920.0f, 1.0f - 500.0f / 1080.0f);
        runtime->SetCursorEnter(true);
        was_in_window = runtime->DispatchCursorFrameEvents(was_in_window);
        runtime->Tick(1.0 / 60.0);
    }

    bool Hovered(const std::string& name) const { return runtime->NodeVisible(name + " marker"); }

    std::vector<std::string> order;
};
} // namespace

namespace
{
// A text layer under the cursor. Its card hangs from the layer's origin by the layout's
// offset, in the layer's own axes, so a left-aligned layer's card lies to the right of the
// node and a top-aligned one's below it. A script on the layer shows a marker while the
// cursor is over the card.
struct TextCursorStage {
    std::unique_ptr<SceneRuntimeContext> runtime;
    std::shared_ptr<SceneNode>           node  = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode>           marker = std::make_shared<SceneNode>();
    CursorViewport                       viewport {
        .origin = { 0.0f, 0.0f }, .size = { 1920.0f, 1080.0f },
        .content_origin = { 0.0f, 0.0f }, .content_size = { 1920.0f, 1080.0f } };
    bool was_in_window { false };

    TextCursorStage() {
        runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
            .canvas_width = 1920, .canvas_height = 1080 });
        node->SetTranslate(linalg::Vector3f(800.0f, 500.0f, 0.0f));
        node->SetScale(linalg::Vector3f(1.5f, 0.8f, 1.0f));
        node->SetRotation(linalg::Vector3f(0.0f, 0.0f, 0.4f));
        runtime->RegisterNode("text", node.get());
        runtime->RegisterTextLayer("text", TextLayerState {
            .text = "HHHHHH", .font_key = "Arial", .point_size = 20.0f,
            .horizontal_align = "left", .vertical_align = "top" });
        marker->SetVisible(false);
        runtime->RegisterNode("marker", marker.get());
        runtime->RegisterSceneScript(
            "function cursorEnter() { scene.getObject('marker').visible = true; }\n"
            "function cursorLeave() { scene.getObject('marker').visible = false; }\n",
            "text");
    }

    TextLayerLayout Layout() const { return runtime->NodeTextLayout("text").value(); }

    // Where a point of the layer's own plane is drawn, in the scene.
    linalg::Vector3d Drawn(double x, double y) const {
        node->UpdateTrans();
        return (node->RenderTrans() * linalg::Vector4d(x, y, 0.0, 1.0)).head<3>();
    }

    // The cursor at the point of the card `across` and `down` fractions of the way over its
    // width and height from its top left, where the card is drawn.
    bool OverCard(double across, double down) {
        const auto layout = Layout();
        const double x = layout.centre.x() + (across - 0.5) * layout.card.x();
        const double y = layout.centre.y() + (0.5 - down) * layout.card.y();
        return OverLocal(x, y);
    }
    bool OverLocal(double x, double y) {
        const auto world = Drawn(x, y);
        runtime->SetCursorInput(
            static_cast<float>((world.x() - viewport.origin.x()) / viewport.size.x()),
            static_cast<float>(1.0 - (world.y() - viewport.origin.y()) / viewport.size.y()));
        runtime->SetCursorEnter(true);
        was_in_window = runtime->DispatchCursorFrameEvents(was_in_window);
        runtime->Tick(1.0 / 60.0);
        return runtime->NodeVisible("marker");
    }
};
} // namespace

// Wallpaper Engine tests the cursor against the quad it draws. A text layer's quad is its
// card, which hangs from the layer's origin: a left-aligned top-aligned card lies to the
// right of the origin and below it, so the cursor is over it there, and not on the other
// sides of the origin where a box centred on the node would reach.
TEST(MouseInput, ATextLayersHitBoxIsItsCardWhereItIsDrawn) {
    TextCursorStage stage;
    const auto      layout = stage.Layout();
    ASSERT_FALSE(layout.centre.isZero()) << "the card hangs off the origin in both axes";
    EXPECT_TRUE(stage.OverCard(0.1, 0.1));
    EXPECT_TRUE(stage.OverCard(0.9, 0.9));
    EXPECT_TRUE(stage.OverCard(0.5, 0.5));
    EXPECT_FALSE(stage.OverCard(-0.1, 0.5)) << "left of the card";
    EXPECT_FALSE(stage.OverCard(1.1, 0.5)) << "right of the card";
    EXPECT_FALSE(stage.OverCard(0.5, -0.1)) << "above the card";
    EXPECT_FALSE(stage.OverCard(0.5, 1.1)) << "below the card";
    // The origin is the card's top left corner: just outside it on the near sides, just in.
    EXPECT_TRUE(stage.OverLocal(0.02 * layout.card.x(), -0.02 * layout.card.y()));
    EXPECT_FALSE(stage.OverLocal(-0.02 * layout.card.x(), -0.02 * layout.card.y()));
    EXPECT_FALSE(stage.OverLocal(0.02 * layout.card.x(), 0.02 * layout.card.y()));
    EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
}

// A layer's coverage mask is read across the card where it hangs: the left texel of a
// two-texel mask is the left half of the card, wherever the card lies from the node.
TEST(MouseInput, ACoverageMaskIsReadAcrossTheCardWhereItHangs) {
    TextCursorStage stage;
    stage.runtime->RegisterNodeHitMask(
        "text", NodeHitMask { .width = 2, .height = 1, .alpha = { 255, 0 } });
    EXPECT_TRUE(stage.OverCard(0.25, 0.5));
    EXPECT_FALSE(stage.OverCard(0.75, 0.5));
    EXPECT_TRUE(stage.OverCard(0.1, 0.9));
    EXPECT_FALSE(stage.OverCard(0.9, 0.1));
    EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
}

// A screen anchor moves the card with the draw, and the cursor follows what is drawn.
TEST(MouseInput, ACursorHitFollowsAScreenAnchoredCard) {
    TextCursorStage stage;
    stage.runtime->SetNodeScreenAnchor("text", TextScreenAnchor::Right);
    // The display shows 1840 of the 1920 columns from column 10: the right edge of what is
    // shown is 70 columns in from the canvas's.
    stage.viewport = CursorViewport {
        .origin = { 10.0f, 0.0f }, .size = { 1840.0f, 1080.0f },
        .content_origin = { 10.0f, 0.0f }, .content_size = { 1840.0f, 1080.0f } };
    stage.runtime->SetCursorViewport(stage.viewport);
    const auto layout = stage.Layout();
    // Over the card near its far end where it is drawn ...
    EXPECT_TRUE(stage.OverCard(0.97, 0.5));
    EXPECT_TRUE(stage.node->DrawOffset().isApprox(linalg::Vector3f(-70.0f, 0.0f, 0.0f)));
    // ... and not at the world point that same spot is at without the anchor, 70 columns
    // right of the end of the card.
    const linalg::Vector4d spot(layout.centre.x() + 0.47 * layout.card.x(), layout.centre.y(), 0.0, 1.0);
    stage.node->UpdateTrans();
    const linalg::Vector4d unshifted = stage.node->ModelTrans() * spot;
    stage.runtime->SetCursorInput(
        static_cast<float>((unshifted.x() - 10.0) / 1840.0),
        static_cast<float>(1.0 - unshifted.y() / 1080.0));
    stage.runtime->SetCursorEnter(true);
    stage.was_in_window = stage.runtime->DispatchCursorFrameEvents(stage.was_in_window);
    stage.runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(stage.runtime->NodeVisible("marker"));
}

TEST(MouseInput, OnlySolidImageTextAndModelLayersAreHitTested) {
    CursorStage stage;
    stage.AddLayer("solid", 100.0f);
    stage.AddLayer("not solid", 300.0f);
    stage.AddLayer("particles", 500.0f);
    stage.runtime->SetNodeCursorTarget("solid", true, true, false);
    stage.runtime->SetNodeCursorTarget("not solid", true, false, false);
    stage.runtime->SetNodeCursorTarget("particles", false, true, false);

    stage.MoveTo(100.0f);
    EXPECT_TRUE(stage.Hovered("solid"));
    stage.MoveTo(300.0f);
    EXPECT_FALSE(stage.Hovered("not solid")) << "a layer with solid off is never hit";
    EXPECT_FALSE(stage.Hovered("solid"));
    stage.MoveTo(500.0f);
    EXPECT_FALSE(stage.Hovered("particles")) << "a particle layer is never hit, solid or not";
    EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
}

TEST(MouseInput, ALayerThatDisablesPropagationHidesTheLayersBehindItFromTheCursor) {
    CursorStage stage;
    stage.AddLayer("back", 100.0f);     // spans 50..150
    stage.AddLayer("front", 150.0f);    // spans 100..200, drawn over it
    stage.AddLayer("beside", 400.0f);
    stage.runtime->SetNodeCursorTarget("back", true, true, false);
    stage.runtime->SetNodeCursorTarget("front", true, true, true);
    stage.runtime->SetNodeCursorTarget("beside", true, true, false);

    // Over `back` alone it is entered, and over `front` alone only `front` is.
    stage.MoveTo(75.0f);
    EXPECT_TRUE(stage.Hovered("back"));
    EXPECT_FALSE(stage.Hovered("front"));
    // Where `front` covers it the walk ends at `front`: `back` hears nothing, and
    // stays as it was, entered, rather than being left.
    stage.MoveTo(125.0f);
    EXPECT_TRUE(stage.Hovered("front"));
    EXPECT_TRUE(stage.Hovered("back"));
    // Away from both, the walk reaches `back` and it is left.
    stage.MoveTo(300.0f);
    EXPECT_FALSE(stage.Hovered("back"));
    EXPECT_FALSE(stage.Hovered("front"));
    // Coming back in where `front` covers it, `back` is not entered.
    stage.MoveTo(125.0f);
    EXPECT_FALSE(stage.Hovered("back"));
    EXPECT_TRUE(stage.Hovered("front"));
    // A layer elsewhere is unaffected throughout.
    stage.MoveTo(400.0f);
    EXPECT_TRUE(stage.Hovered("beside"));
    EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
}

TEST(MouseInput, OnlyAVisibleBlockerInFrontStopsTheWalk) {
    // A solid layer in front that does not disable propagation hides nothing.
    {
        CursorStage stage;
        stage.AddLayer("back", 100.0f);
        stage.AddLayer("front", 150.0f);
        stage.runtime->SetNodeCursorTarget("front", true, true, false);
        stage.MoveTo(125.0f);
        EXPECT_TRUE(stage.Hovered("back"));
        EXPECT_TRUE(stage.Hovered("front"));
    }
    // A blocker behind a layer does not hide the one in front of it.
    {
        CursorStage stage;
        stage.AddLayer("back", 100.0f);
        stage.AddLayer("front", 150.0f);
        stage.runtime->SetNodeCursorTarget("back", true, true, true);
        stage.MoveTo(125.0f);
        EXPECT_TRUE(stage.Hovered("front"));
        EXPECT_TRUE(stage.Hovered("back"));
    }
    // A blocker that is hidden is not visible and hides nothing; one that is not
    // solid or is not a hit-tested kind is not walked at all.
    for (int variant = 0; variant < 3; ++variant) {
        CursorStage stage;
        stage.AddLayer("back", 100.0f);
        stage.AddLayer("front", 150.0f, 100.0f, false);
        stage.runtime->SetNodeCursorTarget("front", variant != 2, variant != 1, true);
        if (variant == 0) stage.nodes.back()->SetVisible(false);
        stage.MoveTo(125.0f);
        EXPECT_TRUE(stage.Hovered("back")) << "variant " << variant;
    }
    // A blocker that is visible does hide it, with no script of its own.
    {
        CursorStage stage;
        stage.AddLayer("back", 100.0f);
        stage.AddLayer("front", 150.0f, 100.0f, false);
        stage.runtime->SetNodeCursorTarget("front", true, true, true);
        stage.MoveTo(125.0f);
        EXPECT_FALSE(stage.Hovered("back"));
    }
}

// A press goes to the layers the walk reaches and to no other: a layer behind a
// visible blocker hears neither its down nor its click, and one not behind it
// hears both.
TEST(MouseInput, ALayerBehindABlockerHearsNeitherTheDownNorTheClickOfAPress) {
    CursorStage stage;
    stage.AddLayer("back", 100.0f, 100.0f, false);   // spans 50..150
    stage.AddLayer("front", 150.0f, 100.0f, false);  // spans 100..200
    stage.AddLayer("beside", 400.0f, 100.0f, false);
    stage.runtime->SetNodeCursorTarget("front", true, true, true);
    const auto listen = [&](const std::string& layer) {
        auto down = std::make_shared<SceneNode>();
        auto click = std::make_shared<SceneNode>();
        down->SetVisible(false);
        click->SetVisible(false);
        stage.runtime->RegisterNode(layer + " down", down.get());
        stage.runtime->RegisterNode(layer + " click", click.get());
        stage.nodes.push_back(down);
        stage.nodes.push_back(click);
        stage.runtime->RegisterSceneScript(
            "function cursorDown() { scene.getObject('" + layer + " down').visible = true; }\n"
            "function cursorClick() { scene.getObject('" + layer + " click').visible = true; }\n",
            layer);
    };
    listen("back");
    listen("front");
    listen("beside");

    // Where `front` covers `back`, only `front` is pressed.
    stage.runtime->SetCursorInput(125.0f / 1920.0f, 1.0f - 500.0f / 1080.0f);
    stage.runtime->SetCursorEnter(true);
    stage.runtime->SetCursorButton(0, true);
    stage.was_in_window = stage.runtime->DispatchCursorFrameEvents(stage.was_in_window);
    stage.runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(stage.runtime->NodeVisible("front down"));
    EXPECT_TRUE(stage.runtime->NodeVisible("front click"));
    EXPECT_FALSE(stage.runtime->NodeVisible("back down"));
    EXPECT_FALSE(stage.runtime->NodeVisible("back click"));
    EXPECT_FALSE(stage.runtime->NodeVisible("beside down"));
    stage.runtime->SetCursorButton(0, false);
    stage.was_in_window = stage.runtime->DispatchCursorFrameEvents(stage.was_in_window);

    // Where only `back` is under the cursor, nothing stands in front of it.
    stage.runtime->SetCursorInput(75.0f / 1920.0f, 1.0f - 500.0f / 1080.0f);
    stage.runtime->SetCursorButton(0, true);
    stage.was_in_window = stage.runtime->DispatchCursorFrameEvents(stage.was_in_window);
    stage.runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(stage.runtime->NodeVisible("back down"));
    EXPECT_TRUE(stage.runtime->NodeVisible("back click"));
    EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
}

// The blocker in front is found from the layers' order, which scripts and the
// host can change, and from what is visible, which a callback can change in the
// middle of a frame.
TEST(MouseInput, TheBlockerInFrontFollowsTheLayerOrderAndAFrameInProgress) {
    {
        CursorStage stage;
        stage.AddLayer("back", 100.0f);
        stage.AddLayer("front", 150.0f, 100.0f, false);
        stage.runtime->SetNodeCursorTarget("front", true, true, true);
        stage.MoveTo(125.0f);
        EXPECT_FALSE(stage.Hovered("back")) << "behind the blocker";
        stage.MoveTo(300.0f);
        // Bring `back` to the front of the blocker: nothing stands in front of it.
        stage.order = { "front", "back" };
        stage.runtime->SetLayerOrder(stage.order);
        stage.MoveTo(125.0f);
        EXPECT_TRUE(stage.Hovered("back")) << "after the order changed, it is in front";
        EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
    }
    {
        // `lid` is in front of `blocker`, which is in front of `under`. Entering
        // `lid` hides the blocker, so `under`, visited after it in the same frame,
        // is reached by the walk. A search made before the callback ran would have
        // `under` still hidden by it.
        CursorStage stage;
        stage.AddLayer("under", 100.0f, 100.0f, false);
        stage.AddLayer("blocker", 100.0f, 100.0f, false);
        stage.AddLayer("lid", 100.0f, 100.0f, false);
        stage.runtime->SetNodeCursorTarget("blocker", true, true, true);
        auto marker = std::make_shared<SceneNode>();
        marker->SetVisible(false);
        stage.runtime->RegisterNode("under marker", marker.get());
        stage.nodes.push_back(marker);
        stage.runtime->RegisterSceneScript(
            "function cursorEnter() { scene.getObject('blocker').visible = false; }\n", "lid");
        stage.runtime->RegisterSceneScript(
            "function cursorEnter() { scene.getObject('under marker').visible = true; }\n",
            "under");
        stage.MoveTo(100.0f);
        EXPECT_TRUE(stage.Hovered("under"))
            << "the blocker the first callback hid still hid the layer behind it";
        EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
    }
}

// `sortLayer` moves a layer in the same order the cursor walk reads, so a blocker found for
// one frame no longer stands in front of what was sorted past it.
TEST(MouseInput, SortingALayerPastABlockerLiftsItsHold) {
    CursorStage stage;
    stage.AddLayer("back", 100.0f);
    stage.AddLayer("aside", 900.0f, 100.0f, false);
    stage.AddLayer("front", 150.0f, 100.0f, false);
    stage.runtime->SetNodeCursorTarget("front", true, true, true);
    stage.MoveTo(125.0f);
    EXPECT_FALSE(stage.Hovered("back")) << "behind the blocker";
    stage.MoveTo(300.0f);
    EXPECT_TRUE(stage.runtime->SortLayer("back", 2));
    stage.MoveTo(125.0f);
    EXPECT_TRUE(stage.Hovered("back")) << "sorted in front of it";
    EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
}

// A registration rolled back because the layer failed to load puts back what the
// layer it replaced was to the cursor, and leaves nothing behind where there was
// no such layer.
TEST(MouseInput, ARolledBackRegistrationRestoresTheCursorTargetOfTheLayerItReplaced) {
    CursorStage stage;
    stage.AddLayer("back", 100.0f);
    stage.AddLayer("front", 150.0f, 100.0f, false);
    stage.runtime->SetNodeCursorTarget("front", true, true, true);
    const auto snapshot = stage.runtime->CaptureNodeRegistration("front");
    ASSERT_NE(snapshot, nullptr);

    // A reload registers the layer again as something the cursor passes through,
    // then fails.
    auto failed = std::make_shared<SceneNode>();
    failed->SetTranslate(linalg::Vector3f(150.0f, 500.0f, 0.0f));
    stage.runtime->RegisterNode("front", failed.get());
    stage.runtime->RegisterNodeSize("front", linalg::Vector2f(100.0f, 100.0f));
    stage.runtime->SetNodeCursorTarget("front", false, false, false);
    stage.runtime->RollbackNodeRegistration("front", failed.get(), snapshot);

    const auto restored = stage.runtime->NodeCursorTargetOf("front");
    ASSERT_TRUE(restored.has_value());
    EXPECT_TRUE(restored->hittable);
    EXPECT_TRUE(restored->solid);
    EXPECT_TRUE(restored->blocks);
    // The blocker still stands in front of `back`.
    stage.MoveTo(125.0f);
    EXPECT_FALSE(stage.Hovered("back"));

    // Nothing was there before: nothing is left.
    auto fresh = std::make_shared<SceneNode>();
    stage.runtime->RegisterNode("fresh", fresh.get());
    stage.runtime->SetNodeCursorTarget("fresh", true, true, true);
    stage.runtime->RollbackNodeRegistration("fresh", fresh.get(), nullptr);
    EXPECT_FALSE(stage.runtime->NodeCursorTargetOf("fresh").has_value());
}

// What a script reads as `input.cursorWorldPosition`. A scene drawn through the
// 2D canvas camera hands over the cursor in canvas units with no depth. A
// perspective scene (display-sized here) hands over the point where the cursor
// ray leaves the view, at the camera's far plane: Wallpaper Engine unprojects
// the pointer at the depth the projection puts at 0 after its [-1, 1] remap,
// which is the far plane because its projection stores depth reversed. Workshop
// scripts size their ranges to it (3509243656 divides by 8000 and 9000 under a
// farz of 10000).
namespace
{
// A perspective scene seen through one camera, the way a display-sized scene is
// parsed: the camera is the scene's active one and the runtime works in canvas
// units until a viewport says otherwise.
struct PerspectiveStage {
    Scene                        scene;
    std::unique_ptr<SceneRuntimeContext> runtime;
    std::shared_ptr<SceneNode>   camera_node = std::make_shared<SceneNode>();
    std::shared_ptr<SceneCamera> camera;

    PerspectiveStage(double aspect, double near_clip, double far_clip, double fov) {
        runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
            .canvas_width = 1920, .canvas_height = 1080 });
        runtime->AttachScene(&scene);
        camera = std::make_shared<SceneCamera>(static_cast<float>(aspect),
                                               static_cast<float>(near_clip),
                                               static_cast<float>(far_clip),
                                               static_cast<float>(fov));
        camera->AttatchNode(camera_node);
        scene.cameras["global_perspective"] = camera;
        scene.activeCamera                  = camera.get();
        scene.display_sized                 = true;
    }

    linalg::Vector3f Cursor() const { return runtime->hostContext().cursor_world_position; }

    // The window fraction at which `point` is drawn.
    std::pair<float, float> PointerAt(const linalg::Vector3d& point) const {
        const linalg::Vector4d clip = camera->GetViewProjectionMatrix() *
                                     linalg::Vector4d(point.x(), point.y(), point.z(), 1.0);
        return { static_cast<float>(0.5 + 0.5 * clip.x() / clip.w()),
                 static_cast<float>(0.5 - 0.5 * clip.y() / clip.w()) };
    }
};
} // namespace

TEST(MouseInput, APerspectiveSceneHandsScriptsTheCursorRayPointAtTheFarPlane) {
    PerspectiveStage stage(16.0 / 9.0, 0.1, 500.0, 45.0);
    stage.camera_node->SetTranslate(linalg::Vector3f(10, 5, 100));
    stage.camera->Update();

    // The middle of the window is straight down the view axis.
    stage.runtime->SetCursorInput(0.5f, 0.5f);
    EXPECT_NEAR(stage.Cursor().x(), 10.0f, 1.0e-3f);
    EXPECT_NEAR(stage.Cursor().y(), 5.0f, 1.0e-3f);
    EXPECT_NEAR(stage.Cursor().z(), -400.0f, 1.0e-2f);

    // Halfway to the right and top edges: half the frustum's width and height
    // at the far plane, 500 units from the eye.
    stage.runtime->SetCursorInput(0.75f, 0.25f);
    const double half_height = std::tan(0.5 * 45.0 * 3.14159265358979323846 / 180.0) * 500.0;
    EXPECT_NEAR(stage.Cursor().x(), 10.0 + 0.5 * half_height * 16.0 / 9.0, 1.0e-2);
    EXPECT_NEAR(stage.Cursor().y(), 5.0 + 0.5 * half_height, 1.0e-2);
    EXPECT_NEAR(stage.Cursor().z(), -400.0f, 1.0e-2f);
}

TEST(MouseInput, ThePerspectiveCursorPointLiesOnTheCursorRayOfAMovedAndShakenCamera) {
    PerspectiveStage stage(2.0, 0.01, 5389.07, 42.4);
    stage.camera_node->SetTranslate(linalg::Vector3f(0.5f, 2.2f, 4.4f));
    stage.camera_node->SetRotation(linalg::Vector3f(0.3f, -0.7f, 0.0f));
    stage.camera->SetShakeOffset(linalg::Vector3d(0.2, -0.1, 0.3));
    stage.camera->Update();

    for (const auto [x, y] : { std::pair { 0.5f, 0.5f }, std::pair { 0.0f, 0.0f },
                               std::pair { 1.0f, 0.2f }, std::pair { 0.3f, 0.9f } }) {
        stage.runtime->SetCursorInput(x, y);
        const linalg::Vector3d point = stage.Cursor().cast<double>();
        // The point is drawn exactly where the pointer is...
        const auto [pointer_x, pointer_y] = stage.PointerAt(point);
        EXPECT_NEAR(pointer_x, x, 1.0e-4f);
        EXPECT_NEAR(pointer_y, y, 1.0e-4f);
        // ...and is `farz` in front of the eye, measured along the view axis.
        const linalg::Vector4d seen =
            stage.camera->GetViewMatrix() * linalg::Vector4d(point.x(), point.y(), point.z(), 1.0);
        EXPECT_NEAR(seen.z(), -5389.07, 0.5);
    }
}

TEST(MouseInput, ACameraPointAtDepthIsOnlyDefinedForAPerspectiveViewAndARealDepth) {
    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(linalg::Vector3f(1, 2, 3));
    SceneCamera lens(2.0f, 0.1f, 100.0f, 90.0f);
    lens.AttatchNode(node);
    const auto centre = UnprojectNdcAtDepth(lens, 0.0, 0.0, 10.0);
    ASSERT_TRUE(centre.has_value());
    EXPECT_TRUE(centre->isApprox(linalg::Vector3d(1, 2, -7), 1.0e-9));
    // A 90 degree frustum is as wide as it is far at the top edge; twice that wide at 2:1.
    const auto corner = UnprojectNdcAtDepth(lens, 1.0, 1.0, 10.0);
    ASSERT_TRUE(corner.has_value());
    EXPECT_TRUE(corner->isApprox(linalg::Vector3d(1 + 20, 2 + 10, -7), 1.0e-6));

    EXPECT_FALSE(UnprojectNdcAtDepth(lens, 0.0, 0.0, 0.0).has_value());
    EXPECT_FALSE(UnprojectNdcAtDepth(lens, 0.0, 0.0, -5.0).has_value());
    EXPECT_FALSE(UnprojectNdcAtDepth(lens, 0.0, 0.0, std::nan("")).has_value());
    EXPECT_FALSE(UnprojectNdcAtDepth(lens, std::nan(""), 0.0, 10.0).has_value());
    SceneCamera canvas(1920, 1080, -5000.0f, 5000.0f);
    canvas.AttatchNode(node);
    EXPECT_FALSE(UnprojectNdcAtDepth(canvas, 0.0, 0.0, 10.0).has_value());
}

// Workshop 3477054430 turns a cat's head to the cursor: the script measures the
// cursor from the head's origin and turns by that direction past a 100 unit
// neutral zone. Wallpaper Engine, with the cursor in the middle of the screen,
// showed the head at pitch -6.1 and yaw -61.4 degrees (the scene's camera
// looks 12.8 degrees left of -z and a little up). Read in canvas pixels the
// cursor sat at (960, 540) beside a head at (4.8, 0.8): pitch about -15, yaw about -6.
TEST(MouseInput, AHeadScriptThatFollowsThePerspectiveCursorTurnsAsInWallpaperEngine) {
    PerspectiveStage stage(16.0 / 9.0, 0.01, 5389.0698, 42.43);
    stage.camera_node->SetTranslate(linalg::Vector3f(0.53864f, 2.22436f, 4.44038f));
    stage.camera_node->SetRotation(linalg::Vector3f(0.04597f, 0.224f, 0.0f));
    stage.camera->Update();

    auto head = std::make_shared<SceneNode>();
    head->SetTranslate(linalg::Vector3f(4.7824f, 0.80878f, -20.62969f));
    stage.runtime->RegisterNode("head", head.get());
    auto pose = std::make_shared<SceneNode>();
    stage.runtime->RegisterNode("pose", pose.get());
    stage.runtime->RegisterNodeTranslate("pose", pose.get(), ResolveVec3Setting(*stage.runtime, {
        {"value", "0 0 0"}, {"script", R"JS(
export function update(value) {
    const dx = input.cursorWorldPosition.x - 4.7824;
    const dy = input.cursorWorldPosition.y - 0.80878;
    const distance = Math.sqrt(dx * dx + dy * dy);
    const zone = 100;
    const influence = distance > zone ? Math.min(1, (distance - zone) / zone) : 0;
    value.x = -(dy / distance) * 30 * influence;
    value.y = -32 + (dx / distance) * 30 * influence;
    return value;
}
)JS"},
    }, "pose"));

    stage.runtime->SetCursorInput(0.5f, 0.5f);
    stage.runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(pose->Translate().x(), -6.1f, 0.2f) << "pitch";
    EXPECT_NEAR(pose->Translate().y(), -61.4f, 0.2f) << "yaw";
    EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
}

// A scene drawn through the canvas camera keeps its cursor in canvas units with
// no depth, whatever perspective camera it also holds.
TEST(MouseInput, ACanvasSceneKeepsTheCursorInCanvasUnitsEvenWithAPerspectiveCameraAround) {
    Scene scene;
    auto  runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width = 1920, .canvas_height = 1080 });
    runtime->AttachScene(&scene);
    auto lens_node = std::make_shared<SceneNode>();
    lens_node->SetTranslate(linalg::Vector3f(960, 540, 1000));
    auto lens = std::make_shared<SceneCamera>(16.0f / 9.0f, 5.0f, 15000.0f, 60.0f);
    lens->AttatchNode(lens_node);
    scene.cameras["global_perspective"] = lens;
    auto canvas_node = std::make_shared<SceneNode>();
    canvas_node->SetTranslate(linalg::Vector3f(960, 540, 0));
    auto canvas = std::make_shared<SceneCamera>(1920, 1080, -5000.0f, 5000.0f);
    canvas->AttatchNode(canvas_node);
    scene.cameras["global"] = canvas;
    scene.activeCamera      = canvas.get();
    ASSERT_FALSE(scene.display_sized);

    runtime->SetCursorInput(0.25f, 0.75f);
    EXPECT_TRUE(runtime->hostContext().cursor_world_position.isApprox(linalg::Vector3f(480, 270, 0)));

    // Even when something makes the perspective camera the active one: a scene
    // authored on a canvas has no far-plane point to hand over.
    scene.activeCamera = lens.get();
    runtime->SetCursorInput(0.25f, 0.75f);
    EXPECT_TRUE(runtime->hostContext().cursor_world_position.isApprox(linalg::Vector3f(480, 270, 0)));
}

// Layers are still hit in their own plane through the real view-projection; the
// far-plane point scripts read is not what the hit test consults.
TEST(MouseInput, APerspectiveSceneStillHitsLayersWhereTheyAreDrawn) {
    PerspectiveStage stage(16.0 / 9.0, 0.1, 500.0, 45.0);
    stage.camera_node->SetTranslate(linalg::Vector3f(0, 0, 100));
    stage.camera->Update();

    auto layer = std::make_shared<SceneNode>();
    layer->SetTranslate(linalg::Vector3f(8, -3, 0));
    stage.runtime->RegisterNode("layer", layer.get());
    stage.runtime->RegisterNodeSize("layer", linalg::Vector2f(20, 20));
    auto marker = std::make_shared<SceneNode>();
    marker->SetVisible(false);
    stage.runtime->RegisterNode("marker", marker.get());
    stage.runtime->RegisterSceneScript(
        R"JS(
function cursorEnter() { scene.getObject('marker').visible = true; }
function cursorLeave() { scene.getObject('marker').visible = false; }
)JS",
        "layer");
    stage.runtime->Tick(0.01);

    bool was_in_window = false;
    const auto move_to = [&](const linalg::Vector3d& point) {
        const auto [x, y] = stage.PointerAt(point);
        stage.runtime->SetCursorInput(x, y);
        stage.runtime->SetCursorEnter(true);
        was_in_window = stage.runtime->DispatchCursorFrameEvents(was_in_window);
        stage.runtime->Tick(0.01);
    };
    move_to(linalg::Vector3d(8, -3, 0));
    EXPECT_TRUE(marker->Visible());
    move_to(linalg::Vector3d(40, -3, 0));
    EXPECT_FALSE(marker->Visible());
    move_to(linalg::Vector3d(14, 4, 0));
    EXPECT_TRUE(marker->Visible());
    EXPECT_EQ(stage.runtime->scriptErrorCount(), 0u);
}

// A particle system's mouse control point follows the cursor in the canvas
// plane. The far-plane point scripts read is thousands of units deep in a
// perspective scene, nowhere near where a particle is drawn.
TEST(MouseInput, AParticleControlPointFollowsTheCanvasPlaneCursorInAPerspectiveScene) {
    PerspectiveStage stage(16.0 / 9.0, 0.1, 500.0, 45.0);
    stage.camera_node->SetTranslate(linalg::Vector3f(10, 5, 100));
    stage.camera->Update();

    stage.runtime->SetCursorInput(0.25f, 0.75f);
    ASSERT_TRUE(stage.scene.pointerScenePosition.has_value());
    // 1920x1080 canvas, y up: a quarter across, a quarter up from the bottom.
    EXPECT_NEAR((*stage.scene.pointerScenePosition)[0], 480.0f, 1.0e-3f);
    EXPECT_NEAR((*stage.scene.pointerScenePosition)[1], 270.0f, 1.0e-3f);
    // Scripts read another point in the same frame.
    EXPECT_NEAR(stage.Cursor().z(), -400.0f, 1.0e-2f);
    EXPECT_GT(std::abs(stage.Cursor().x() - 480.0f), 100.0f);
}

// The window is not always the whole picture: a wallpaper scaled up is cropped
// by it and one scaled down is letterboxed in it. The cursor's place on the
// picture, not on the window, decides where its ray goes, so a corner of a
// cropped window looks through the picture's interior and a corner of a
// letterboxed one past the frustum's edge. Hit tests read the same mapping.
TEST(MouseInput, ThePerspectiveCursorPointFollowsThePictureWhenTheWindowCropsOrLetterboxesIt) {
    PerspectiveStage stage(16.0 / 9.0, 0.1, 500.0, 45.0);
    stage.camera_node->SetTranslate(linalg::Vector3f(10, 5, 100));
    stage.camera->Update();

    const auto present = [&](double wallpaper_scale) {
        const auto layout = ComputeWallpaperScalingLayout(
            WallpaperScalingMode::FILL, 1920, 1080, 1920, 1080, 1.0, wallpaper_scale);
        const auto mapping = ComputeWallpaperCursorMapping(layout, 960.0, 540.0, 1920.0, 1080.0);
        EXPECT_TRUE(mapping.valid);
        stage.runtime->SetCursorViewport(CursorViewport {
            .origin = linalg::Vector2f(static_cast<float>(mapping.origin_x),
                                      static_cast<float>(mapping.origin_y)),
            .size = linalg::Vector2f(static_cast<float>(mapping.size_x),
                                    static_cast<float>(mapping.size_y)),
            .content_origin = linalg::Vector2f(static_cast<float>(mapping.content_origin_x),
                                              static_cast<float>(mapping.content_origin_y)),
            .content_size = linalg::Vector2f(static_cast<float>(mapping.content_size_x),
                                            static_cast<float>(mapping.content_size_y)),
        });
    };
    const auto expect_on_ray_at = [&](float window_x, float window_y, float picture_x,
                                      float picture_y) {
        stage.runtime->SetCursorInput(window_x, window_y);
        const linalg::Vector3d point = stage.Cursor().cast<double>();
        const auto [pointer_x, pointer_y] = stage.PointerAt(point);
        EXPECT_NEAR(pointer_x, picture_x, 1.0e-4f) << window_x << "," << window_y;
        EXPECT_NEAR(pointer_y, picture_y, 1.0e-4f) << window_x << "," << window_y;
        const linalg::Vector4d seen =
            stage.camera->GetViewMatrix() * linalg::Vector4d(point.x(), point.y(), point.z(), 1.0);
        EXPECT_NEAR(seen.z(), -500.0, 0.05) << window_x << "," << window_y;
    };

    // Scaled up by 1.6 and centred: the window shows the middle 0.625 of the
    // picture each way.
    present(1.6);
    expect_on_ray_at(0.5f, 0.5f, 0.5f, 0.5f);
    expect_on_ray_at(0.0f, 0.0f, 0.1875f, 0.1875f);
    expect_on_ray_at(1.0f, 0.5f, 0.8125f, 0.5f);

    // Scaled down to half: the picture fills the middle of the window, whose
    // corners lie one picture-width and height beyond its own.
    present(0.5);
    expect_on_ray_at(0.5f, 0.5f, 0.5f, 0.5f);
    expect_on_ray_at(0.0f, 0.0f, -0.5f, -0.5f);
    expect_on_ray_at(1.0f, 1.0f, 1.5f, 1.5f);
}

} // namespace
} // namespace wallpaper
