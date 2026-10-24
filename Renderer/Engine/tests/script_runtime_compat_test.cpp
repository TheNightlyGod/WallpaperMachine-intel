#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"
#include "Scene/include/Scene/SceneImageEffectLayer.h"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "WPShaderValueUpdater.hpp"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scripting/ScriptEngine.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"
#include "Utils/TimeOfDay.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <ctime>
#include <iterator>
#include <map>
#include <memory>
#include <limits>
#include <set>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace wallpaper::audio {
void SetAudioSpectrumSnapshotForTesting(const AudioSpectrumSnapshot&);
}

namespace wallpaper
{
namespace
{

DynamicValue EvaluateScalar(ScriptEngine& engine, std::string script,
                            const ScriptHostContext& host = {}) {
    DynamicValue initial(0.0f);
    auto result = engine.Evaluate(script, {}, initial, host);
    if (result == nullptr) return DynamicValue();
    return *result;
}

std::unique_ptr<SceneRuntimeContext> MakeRuntimeWithScene(Scene& scene) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    if (runtime != nullptr) {
        runtime->AttachScene(&scene);
    }
    return runtime;
}

TEST(ScriptRuntimeCompat, CallbackOnlyPropertyScriptsInitializeAndToggleLayersOnHit) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto button = std::make_shared<SceneNode>();
    auto target = std::make_shared<SceneNode>();
    button->SetTranslate(linalg::Vector3f(300, 200, 0));
    runtime->RegisterNode("button", button.get());
    runtime->RegisterNodeSize("button", linalg::Vector2f(80, 60));
    runtime->RegisterNode("target", target.get());
    runtime->RegisterNodeVisibility("button", button.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
let visible;
export function init(value) { visible = true; return value; }
export function cursorClick(event) {
    visible = !visible;
    thisScene.getLayer('target').visible = visible;
}
)JS"}}, "button"));
    runtime->Tick(0.01);
    runtime->SetCursorEnter(true);
    runtime->SetCursorWorldPosition(linalg::Vector3f(600, 200, 0));
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_TRUE(target->Visible());
    runtime->SetCursorWorldPosition(linalg::Vector3f(300, 200, 0));
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(0.01);
    EXPECT_FALSE(target->Visible());
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(0.01);
    EXPECT_TRUE(target->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, CallbackOnlySelfWritesSurviveSubsequentTicksAndUserChanges) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"enabled", RuntimeScalarValue::Bool(true)}},
    });
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("button", node.get());
    runtime->RegisterNodeVisibility("button", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"user", "enabled"}, {"script", R"JS(
export function cursorClick() { thisLayer.visible = !thisLayer.visible; }
)JS"}}, "button"));
    runtime->Tick(0.01);
    runtime->DispatchCursorClick();
    EXPECT_FALSE(node->Visible());
    for (int i = 0; i < 3; ++i) runtime->Tick(0.01);
    EXPECT_FALSE(node->Visible());
    runtime->ApplyProjectPropertyOverride({{"enabled", RuntimeScalarValue::Bool(true)}});
    runtime->Tick(0.01);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, CallbackOnlyMenuReceivesInitialAndChangedUserPropertiesOnce) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width = 400,
        .canvas_height = 200,
        .project_properties = {
            {"menu", RuntimeScalarValue::Bool(false)},
            {"amount", RuntimeScalarValue::Float(1.0f)},
            {"caption", RuntimeScalarValue::String("ready")},
        },
    });
    auto button = std::make_shared<SceneNode>();
    auto panel = std::make_shared<SceneNode>();
    button->SetTranslate(linalg::Vector3f(200, 100, 0));
    panel->SetVisible(false);
    runtime->RegisterNode("control", button.get());
    runtime->RegisterNodeSize("control", linalg::Vector2f(80, 40));
    runtime->RegisterNode("panel", panel.get());
    runtime->RegisterNodeVisibility("control", button.get(), ResolveBoolSetting(*runtime, {
        {"value", true},
        {"scriptproperties", {
            {"enabled", {{"user", "menu"}, {"value", true}}},
            {"amount", {{"user", "amount"}, {"value", 8.0}}},
        }},
        {"script", R"JS(
export var scriptProperties = createScriptProperties()
    .addCheckbox({name: 'enabled', value: true})
    .addSlider({name: 'amount', value: 8})
    .addText({name: 'fallback', value: 'ready'}).finish();
let calls = 0;
export function applyUserProperties(changed) {
    calls++;
    const panel = thisScene.getLayer('panel');
    panel.visible = scriptProperties.enabled;
    const keys = (changed.hasOwnProperty('menu') ? 1 : 0) +
                 (changed.hasOwnProperty('amount') ? 2 : 0) +
                 (changed.hasOwnProperty('caption') ? 4 : 0);
    panel.scale = new Vec3(calls, scriptProperties.amount, keys);
    if (scriptProperties.amount !== engine.userProperties.amount ||
        scriptProperties.fallback !== engine.userProperties.caption) {
        throw new Error('property snapshot is inconsistent');
    }
}
export function cursorClick() {
    const panel = thisScene.getLayer('panel');
    panel.visible = !panel.visible;
}
)JS"},
    }, "control"));

    runtime->Tick(0.01);
    EXPECT_FALSE(panel->Visible());
    EXPECT_TRUE(panel->Scale().isApprox(linalg::Vector3f(1, 1, 7)));
    runtime->SetCursorInput(0.5f, 0.5f);
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(0u, 1u, 1u);
    runtime->DispatchCursorFrameEvents(false);
    runtime->BeginFrame();
    for (int frame = 0; frame < 4; ++frame) runtime->Tick(0.01);
    EXPECT_TRUE(panel->Visible());
    EXPECT_FLOAT_EQ(panel->Scale().x(), 1.0f);

    const ProjectProperties overrides {
        {"menu", RuntimeScalarValue::Bool(true)},
        {"amount", RuntimeScalarValue::Float(3.0f)},
    };
    runtime->ApplyProjectPropertyOverride(overrides);
    EXPECT_TRUE(panel->Visible());
    EXPECT_TRUE(panel->Scale().isApprox(linalg::Vector3f(2, 3, 3)));
    runtime->SetCursorButtons(0u, 1u, 1u);
    runtime->DispatchCursorFrameEvents(true);
    runtime->BeginFrame();
    EXPECT_FALSE(panel->Visible());
    runtime->ApplyProjectPropertyOverride(overrides);
    for (int frame = 0; frame < 4; ++frame) runtime->Tick(0.01);
    EXPECT_FALSE(panel->Visible());
    EXPECT_FLOAT_EQ(panel->Scale().x(), 2.0f);

    runtime->ApplyProjectPropertyOverride({
        {"menu", RuntimeScalarValue::Bool(true)},
        {"amount", RuntimeScalarValue::Float(5.0f)},
    });
    EXPECT_TRUE(panel->Scale().isApprox(linalg::Vector3f(3, 5, 2)));
    runtime->ResetProjectPropertyOverride();
    EXPECT_FALSE(panel->Visible());
    EXPECT_TRUE(panel->Scale().isApprox(linalg::Vector3f(4, 1, 3)));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, UserOverrideBeforeFirstTickInitializesWithOneCompleteSnapshot) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            {"enabled", RuntimeScalarValue::Bool(false)},
            {"amount", RuntimeScalarValue::Float(1.0f)},
        },
    });
    auto control = std::make_shared<SceneNode>();
    runtime->RegisterNode("control", control.get());
    runtime->RegisterNodeVisibility("control", control.get(), ResolveBoolSetting(*runtime, {
        {"value", false},
        {"scriptproperties", {
            {"enabled", {{"user", "enabled"}, {"value", false}}},
            {"amount", {{"user", "amount"}, {"value", 1.0}}},
        }},
        {"script", R"JS(
export var scriptProperties = createScriptProperties()
    .addCheckbox({name: 'enabled', value: false})
    .addSlider({name: 'amount', value: 1}).finish();
let calls = 0;
export function applyUserProperties(changed) {
    thisLayer.visible = scriptProperties.enabled;
    thisLayer.scale = new Vec3(++calls, scriptProperties.amount,
        changed.enabled === true && changed.amount === 4 ? 1 : 0);
}
)JS"},
    }, "control"));
    runtime->ApplyProjectPropertyOverride({
        {"enabled", RuntimeScalarValue::Bool(true)},
        {"amount", RuntimeScalarValue::Float(4.0f)},
    });
    runtime->Tick(0.01);
    EXPECT_TRUE(control->Visible());
    EXPECT_TRUE(control->Scale().isApprox(linalg::Vector3f(1, 4, 1)));
    for (int frame = 0; frame < 4; ++frame) runtime->Tick(0.01);
    EXPECT_TRUE(control->Scale().isApprox(linalg::Vector3f(1, 4, 1)));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ScenePropertyCallbacksReceiveDeltasAndKeepTheFullLiveSnapshot) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            {"enabled", RuntimeScalarValue::Bool(true)},
            {"amount", RuntimeScalarValue::Float(1.0f)},
        },
    });
    auto control = std::make_shared<SceneNode>();
    runtime->RegisterNode("control", control.get());
    runtime->RegisterSceneScript(R"JS(
let calls = 0;
export function applyUserProperties(changed) {
    thisLayer.scale = new Vec3(++calls, engine.userProperties.amount,
        changed.hasOwnProperty('enabled') ? 1 : 0);
    thisLayer.visible = engine.userProperties.enabled;
}
)JS", "control");
    EXPECT_TRUE(control->Scale().isApprox(linalg::Vector3f(1, 1, 1)));
    runtime->ApplyProjectPropertyOverride({{"amount", RuntimeScalarValue::Float(2.0f)}});
    EXPECT_TRUE(control->Visible());
    EXPECT_TRUE(control->Scale().isApprox(linalg::Vector3f(2, 2, 0)));
    runtime->ApplyProjectPropertyOverride({{"amount", RuntimeScalarValue::Float(2.0f)}});
    for (int frame = 0; frame < 4; ++frame) runtime->Tick(0.01);
    EXPECT_TRUE(control->Scale().isApprox(linalg::Vector3f(2, 2, 0)));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, HoverScaleInterpolatesAcrossFramesAndReversesWithoutSnapping) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(linalg::Vector3f(300, 200, 0));
    runtime->RegisterNodeSize("hover", linalg::Vector2f(80, 60));
    runtime->RegisterNodeScale("hover", node.get(), ResolveVec3Setting(*runtime, {
        {"value", "1 2 1"}, {"script", R"JS(
import * as WEMath from 'WEMath';
let original, enlarged, hovered = false;
export function init(value) {
    original = value;
    enlarged = value.multiply(1.2);
}
export function cursorEnter() { hovered = true; }
export function cursorLeave() { hovered = false; }
export function update(value) {
    const target = hovered ? enlarged : original;
    return new Vec3(WEMath.mix(value.x, target.x, 0.1),
                    WEMath.mix(value.y, target.y, 0.1),
                    WEMath.mix(value.z, target.z, 0.1));
}
)JS"}}, "hover"));
    runtime->Tick(1.0 / 60.0);
    runtime->SetCursorEnter(true);
    runtime->SetCursorWorldPosition(linalg::Vector3f(300, 200, 0));
    runtime->DispatchCursorFrameEvents(false);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.02f, 1.0e-6f);
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.038f, 1.0e-6f);
    EXPECT_NEAR(node->Scale().y(), 2.076f, 1.0e-6f);

    runtime->SetCursorWorldPosition(linalg::Vector3f(600, 200, 0));
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.0342f, 1.0e-6f);
    runtime->SetCursorWorldPosition(linalg::Vector3f(300, 200, 0));
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.05078f, 1.0e-6f);

    for (int frame = 0; frame < 120; ++frame) {
        runtime->DispatchCursorFrameEvents(true);
        runtime->Tick(1.0 / 60.0);
    }
    EXPECT_NEAR(node->Scale().x(), 1.2f, 1.0e-5f);
    EXPECT_NEAR(node->Scale().y(), 2.4f, 1.0e-5f);
    runtime->SetCursorEnter(false);
    runtime->DispatchCursorFrameEvents(true);
    runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.18f, 1.0e-5f);
    for (int frame = 0; frame < 120; ++frame) runtime->Tick(1.0 / 60.0);
    EXPECT_NEAR(node->Scale().x(), 1.0f, 1.0e-5f);
    EXPECT_NEAR(node->Scale().y(), 2.0f, 1.0e-5f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// Real wallpapers receive the cursor as a window fraction, not scene
// coordinates. A 7680x2160 scene on the recorded 4112x2658 output is cropped by
// the FILL presentation, so hover hit boxes only line up with the drawn layer
// when the window fraction is mapped back through that presentation rectangle.
TEST(ScriptRuntimeCompat, HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper) {
    Scene scene;
    auto  runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
         .canvas_width  = 7680,
         .canvas_height = 2160,
    });
    ASSERT_NE(runtime, nullptr);
    runtime->AttachScene(&scene);

    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(linalg::Vector3f(3850.0f, 865.0f, 0.0f));
    runtime->RegisterNodeSize("hover", linalg::Vector2f(275.0f, 134.0f));
    runtime->RegisterNodeScale("hover",
                               node.get(),
                               ResolveVec3Setting(*runtime,
                                                  { { "value", "1 1 1" }, { "script", R"JS(
import * as WEMath from 'WEMath';
let original, enlarged, hovered = false;
export function init(value) {
    original = value;
    enlarged = value.multiply(1.2);
}
export function cursorEnter() { hovered = true; }
export function cursorLeave() { hovered = false; }
export function update(value) {
    const target = hovered ? enlarged : original;
    return new Vec3(WEMath.mix(value.x, target.x, 0.2),
                    WEMath.mix(value.y, target.y, 0.2),
                    WEMath.mix(value.z, target.z, 0.2));
}
)JS" } },
                                                  "hover"));

    // Recorded runtime configuration: output_px 4112x2658, display_scale 2.0,
    // scaling mode fill, factor 1.0.
    const auto layout =
        ComputeWallpaperScalingLayout(WallpaperScalingMode::FILL, 7680, 2160, 2056, 1329, 2.0, 1.0);
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

    // Window fraction where the presented wallpaper draws a scene point.
    const auto screen_x = [&](double world) {
        const double fraction = (world - 3840.0) / 7680.0 + 0.5;
        return static_cast<float>((fraction * layout.viewport_px.width + layout.viewport_px.x) /
                                  4112.0);
    };
    const auto screen_y = [&](double world) {
        const double fraction = 0.5 - (world - 1080.0) / 2160.0;
        return static_cast<float>((fraction * layout.viewport_px.height + layout.viewport_px.y) /
                                  2658.0);
    };

    bool       inside = false;
    const auto settle = [&](double world_x, double world_y, int frames) {
        runtime->SetCursorInput(screen_x(world_x), screen_y(world_y));
        for (int frame = 0; frame < frames; ++frame) {
            inside = runtime->DispatchCursorFrameEvents(inside);
            runtime->Tick(1.0 / 60.0);
        }
        return node->Scale().x();
    };

    runtime->SetCursorEnter(true);
    // 120 scene units right of centre is inside the 275-unit layer, but outside
    // the strip a canvas-relative mapping would cover.
    EXPECT_NEAR(settle(3850.0 + 120.0, 865.0, 120), 1.2f, 1.0e-4f);
    EXPECT_NEAR(settle(3850.0 + 400.0, 865.0, 120), 1.0f, 1.0e-4f);
    EXPECT_NEAR(settle(3850.0 - 120.0, 865.0, 120), 1.2f, 1.0e-4f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, PropertyFeedbackResumesFromExplicitUserValueChanges) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"progress", RuntimeScalarValue::Float(2.0f)}},
    });
    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(material, "u_Progress", ResolveVec3Setting(*runtime, {
        {"value", "0 0 0"}, {"user", "progress"}, {"script", R"JS(
export function update(value) { value.x += engine.frametime; return value; }
)JS"}}));
    runtime->Tick(0.25);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Progress")[0], 2.25f);
    runtime->Tick(0.25);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Progress")[0], 2.5f);

    runtime->ApplyProjectPropertyOverride({{"progress", RuntimeScalarValue::Float(5.0f)}});
    runtime->Tick(0.25);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Progress")[0], 5.25f);
    runtime->Tick(0.25);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Progress")[0], 5.5f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A video-texture control script hides the layer in init() and re-shows it
// from update() without returning a value. The native write must survive the
// next reevaluation instead of being overwritten by the authored `false`.
TEST(ScriptRuntimeCompat, UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    node->SetVisible(false);
    runtime->RegisterNode("clip", node.get());
    runtime->RegisterNodeVisibility("clip", node.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
export function init() { thisLayer.visible = false; }
export function update(value) { thisLayer.visible = true; }
)JS"}}, "clip"));
    for (int i = 0; i < 3; ++i) runtime->Tick(0.01);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// An icon script asks its dock whether it is showing before it does anything
// else, through `getParent()`. Without that call the whole update threw once a
// frame, so the icons never scaled, never faded and never opened anything.
TEST(ScriptRuntimeCompat, LayerGetParentReachesTheParentLayer) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto dock    = std::make_shared<SceneNode>();
    auto icon    = std::make_shared<SceneNode>();
    dock->SetName("App Launcher Dock");
    icon->SetName("Launcher 1");
    dock->AppendChild(icon);
    dock->SetVisible(true);
    runtime->RegisterNode("App Launcher Dock", dock.get());
    runtime->RegisterNodeVisibility("Launcher 1", icon.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
let parent;
export function init() { parent = thisLayer.getParent(); }
export function update() { return parent !== null && parent.visible; }
)JS"}}, "Launcher 1"));

    runtime->Tick(0.01);
    EXPECT_TRUE(icon->Visible());
    dock->SetVisible(false);
    runtime->Tick(0.01);
    EXPECT_FALSE(icon->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A layer at the scene root has no parent layer, and saying so is the whole
// answer: an object standing in for the graph's unnamed root would report a
// visibility that belongs to nothing the author wrote.
TEST(ScriptRuntimeCompat, LayerGetParentIsNullAtTheSceneRoot) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    node->SetName("backdrop");
    runtime->RegisterNode("backdrop", node.get());
    runtime->RegisterNodeVisibility("backdrop", node.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
export function update() { return thisLayer.getParent() === null; }
)JS"}}, "backdrop"));

    runtime->Tick(0.01);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// `layer.alpha = x` is how one script fades another layer. It has to reach the
// material the flat shader reads, not stop at a number the script layer keeps
// to itself.
TEST(ScriptRuntimeCompat, LayerAlphaWritesReachTheMaterial) {
    auto runtime  = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node     = std::make_shared<SceneNode>();
    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterNode("icon", node.get());
    runtime->RegisterNodeAlpha("icon", material, 1.0f);
    runtime->RegisterNodeVisibility("icon", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
export function update(value) { thisLayer.alpha = 0.25; return value; }
)JS"}}, "icon"));

    runtime->Tick(0.01);
    ASSERT_TRUE(material->customShader.constValues.contains("g_UserAlpha"));
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_UserAlpha")[0], 0.25f);
    EXPECT_FLOAT_EQ(*runtime->NodeAlpha("icon"), 0.25f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A layer whose picture is drawn through more than one material -- its own and
// each effect pass that takes its alpha -- fades them all, and a script that
// reads the alpha back reads what it wrote, so a fade can step from it. An
// effect's own alpha, the `g_UserAlpha` of a pass that owns it, is not the
// layer's and stays as it is.
TEST(ScriptRuntimeCompat, LayerAlphaWritesReachEveryMaterialOfTheLayer) {
    auto runtime   = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node      = std::make_shared<SceneNode>();
    auto own       = std::make_shared<SceneMaterial>();
    auto first     = std::make_shared<SceneMaterial>();
    auto second    = std::make_shared<SceneMaterial>();
    second->own_user_alpha = true;
    second->customShader.constValues["g_UserAlpha"] = ShaderValue(0.9f);
    runtime->RegisterNode("icon", node.get());
    runtime->RegisterNodeAlpha("icon", { own, first, second }, 1.0f);
    runtime->RegisterNodeVisibility("icon", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
export function update(value) {
  thisLayer.alpha = 0.5;
  thisLayer.alpha -= 0.125;
  return value;
}
)JS"}}, "icon"));

    runtime->Tick(0.01);
    for (const auto& material : { own, first, second }) {
        ASSERT_TRUE(material->customShader.constValues.contains("g_UserAlpha"));
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_UserAlpha")[0],
                        material == second ? 0.9f : 0.375f);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Color4")[3], 0.375f);
    }
    EXPECT_FLOAT_EQ(*runtime->NodeAlpha("icon"), 0.375f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);

    // Registering the name again replaces what it reached.
    auto replacement = std::make_shared<SceneMaterial>();
    runtime->RegisterNodeAlpha("icon", replacement, 1.0f);
    EXPECT_TRUE(runtime->SetNodeAlpha("icon", 0.75f));
    EXPECT_FLOAT_EQ(replacement->customShader.constValues.at("g_UserAlpha")[0], 0.75f);
    EXPECT_FLOAT_EQ(own->customShader.constValues.at("g_UserAlpha")[0], 0.375f);
}

// A layer with no material of its own — a sound layer, an empty group — still
// remembers what a script wrote to it rather than reporting a made-up 1.
TEST(ScriptRuntimeCompat, LayerAlphaWithoutAMaterialKeepsWhatWasWritten) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("group", node.get());
    runtime->RegisterNodeVisibility("group", node.get(), ResolveBoolSetting(*runtime, {
        {"value", false}, {"script", R"JS(
export function update() {
  thisLayer.alpha = 0.5;
  return thisLayer.alpha === 0.5;
}
)JS"}}, "group"));

    runtime->Tick(0.01);
    EXPECT_TRUE(node->Visible());
    EXPECT_FALSE(runtime->NodeAlpha("group").has_value());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

namespace
{

std::shared_ptr<WPPuppet> MakePuppet(WPPuppet::PlayMode mode) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.emplace_back();
    WPPuppet::Animation animation;
    animation.id     = 7;
    animation.fps    = 10.0;
    animation.length = 5;
    animation.mode   = mode;
    animation.name   = "gesture";
    WPPuppet::Animation::BoneTrack track;
    for (int frame = 0; frame <= animation.length; ++frame) {
        track.frames.push_back(WPPuppet::BoneFrame {
            .position = linalg::Vector3f(static_cast<float>(frame), 0.0f, 0.0f),
            .angle    = linalg::Vector3f::Zero(),
            .scale    = linalg::Vector3f::Ones(),
        });
    }
    animation.bone_tracks.push_back(std::move(track));
    puppet->anims.push_back(std::move(animation));
    puppet->prepared();
    return puppet;
}

std::shared_ptr<WPPuppet> MakeSingleShotPuppet() { return MakePuppet(WPPuppet::PlayMode::Single); }

} // namespace

// getAnimationLayer(...).play() from a click handler restarts a single-shot
// puppet layer that already finished, and every copy of the layer follows.
TEST(ScriptRuntimeCompat, PuppetAnimationLayerPlayRestartsFinishedSingleShotForAllCopies) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());

    std::vector<WPPuppetLayer::AnimationLayer> authored(1);
    authored[0].id   = 7;
    authored[0].name = "siche";
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    WPPuppetLayer render_copy = layer;
    runtime->RegisterPuppetLayer("character", layer);

    runtime->RegisterNodeVisibility("character", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
export function cursorClick(event) { thisLayer.getAnimationLayer("siche").play(); }
)JS"}}, "character"));
    runtime->Tick(0.01);

    render_copy.genFrame(0.0);
    render_copy.genFrame(2.0);
    EXPECT_FALSE(render_copy.isPlaying(0));
    EXPECT_DOUBLE_EQ(render_copy.frame(0), 5.0);
    EXPECT_FLOAT_EQ(render_copy.genFrame(2.0)[0].translation().x(), 5.0f);

    runtime->DispatchCursorClick();
    EXPECT_TRUE(render_copy.isPlaying(0));
    EXPECT_DOUBLE_EQ(render_copy.frame(0), 0.0);
    EXPECT_FLOAT_EQ(render_copy.genFrame(2.0)[0].translation().x(), 0.0f);
    EXPECT_FLOAT_EQ(layer.genFrame(2.0)[0].translation().x(), 0.0f);
    render_copy.genFrame(2.1);
    EXPECT_NEAR(render_copy.frame(0), 1.0, 1e-9);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// Puppet animation layers bound to a user property toggle their visibility on
// the shared state when the property changes.
TEST(ScriptRuntimeCompat, PuppetAnimationLayerVisibilityFollowsUserProperty) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"outfit", RuntimeScalarValue::String("1")}},
    });
    std::vector<WPPuppetLayer::AnimationLayer> authored(1);
    authored[0].id = 7;
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    WPPuppetLayer copy = layer;
    runtime->RegisterDynamicValueListener(
        ResolveBoolSetting(*runtime, {{"value", true}, {"user", {{"name", "outfit"}, {"condition", "0"}}}}),
        [layer](const DynamicValue& value) mutable { layer.setVisible(0, value.getBool()); });
    EXPECT_FALSE(copy.visible(0));
    ASSERT_TRUE(layer.setFrame(0, 2.5));
    EXPECT_FLOAT_EQ(copy.genFrame(0.0)[0].translation().x(), 0.0f);
    runtime->ApplyProjectPropertyOverride({{"outfit", RuntimeScalarValue::String("0")}});
    EXPECT_TRUE(copy.visible(0));
    EXPECT_FLOAT_EQ(copy.genFrame(0.0)[0].translation().x(), 2.5f);
    runtime->ApplyProjectPropertyOverride({{"outfit", RuntimeScalarValue::String("1")}});
    EXPECT_FLOAT_EQ(copy.genFrame(0.0)[0].translation().x(), 0.0f);
}

// Two interlocking triangle buttons share a bounding box; the cursor must only
// hit the one whose texels are opaque under it.
TEST(ScriptRuntimeCompat, CursorHitTestRespectsCoverageMask) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    node->SetTranslate(linalg::Vector3f(100.0f, 100.0f, 0.0f));
    runtime->RegisterNode("button", node.get());
    runtime->RegisterNodeSize("button", linalg::Vector2f(40.0f, 40.0f));
    // Left half opaque, right half transparent.
    NodeHitMask mask;
    mask.width  = 4;
    mask.height = 2;
    mask.alpha  = { 255, 255, 0, 0, 255, 255, 0, 0 };
    runtime->RegisterNodeHitMask("button", std::move(mask));
    runtime->RegisterNodeVisibility("button", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
export function cursorClick(event) { thisLayer.visible = false; }
)JS"}}, "button"));
    runtime->Tick(0.01);
    runtime->SetCursorEnter(true);

    runtime->SetCursorWorldPosition(linalg::Vector3f(110.0f, 100.0f, 0.0f));
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_TRUE(node->Visible());

    runtime->SetCursorWorldPosition(linalg::Vector3f(90.0f, 100.0f, 0.0f));
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A compose layer with effects holds what is behind the place its card is
// drawn: its first pass maps the card onto the screen to read it, and its last
// pass draws the card there. Camera parallax moves the card, so it has to move
// what the first pass reads by the same offset. The layer's own node has no
// depth of its own -- the layer's is on its effect passes -- so the depth could
// not be taken from the node as it stands. And a layer without children frames
// its effects with a camera at the origin, not the scene camera, so the centre
// of the view the offset is measured from could not be taken from the camera
// that draws the pass either. (A layer with children is drawn through the scene
// camera already: the render graph overrides the camera of its first pass.)
// Read at the unshifted place, the layer showed a slab of the scene displaced
// by its own parallax offset. An ordinary effect layer's first pass draws into
// the layer's target and stays where it is.
TEST(ScriptRuntimeCompat, AComposeLayersFirstPassReadsTheScreenWhereParallaxDrawsItsCard) {
    Scene scene;
    scene.ortho[0]   = 640;
    scene.ortho[1]   = 360;
    scene.sceneGraph = std::make_shared<SceneNode>();
    auto screen      = std::make_shared<SceneCamera>(640, 360, -1, 1);
    auto screen_node = std::make_shared<SceneNode>();
    screen_node->SetTranslate(linalg::Vector3f(320, 180, 0));
    screen->AttatchNode(screen_node);
    scene.activeCamera     = screen.get();
    scene.cameras["screen"] = screen;
    auto composite     = std::make_shared<SceneCamera>(64, 32, -1, 1);
    composite->SetLayerLocal(true);
    scene.cameras["composite"] = composite;
    // The camera every layer without children frames its effects with, at the origin.
    auto effect_camera_node = std::make_shared<SceneNode>();
    scene.sceneGraph->AppendChild(effect_camera_node);

    WPShaderValueUpdater updater(&scene);
    updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.0f,
                                .mouseinfluence = 1.0f, .canvas_scene = true });
    scene.frameTime = 1.0 / 60.0;

    auto group = std::make_shared<SceneNode>();
    group->SetTranslate(linalg::Vector3f(400, 100, 0));
    scene.sceneGraph->AppendChild(group);

    // A layer drawn through one effect, as the parser builds it: the layer's own
    // node draws the first pass and holds no depth, a pass node of its own draws
    // the card on the scene with the layer's depth.
    struct EffectLayer
    {
        std::shared_ptr<SceneNode> node;
        std::shared_ptr<SceneNode> card;
        std::string                camera;
        // The camera the render graph draws the first pass with, when it names one.
        std::string                first_pass_camera;
    };
    const auto add_node = [&](const char* shader) {
        auto node = std::make_shared<SceneNode>();
        auto mesh = std::make_shared<SceneMesh>();
        SceneMaterial material;
        material.name = shader;
        mesh->AddMaterial(std::move(material));
        node->AddMesh(mesh);
        return node;
    };
    const auto exists = [](std::string_view name) {
        return name == "g_ModelViewProjectionMatrix";
    };
    // A compose layer with children frames its effects with a camera attached to
    // itself and is drawn through the scene camera; any other layer frames them
    // with the one at the origin and draws its first pass with it.
    const auto add_layer = [&](const char* name, const char* shader, bool has_children) {
        EffectLayer layer { add_node(shader), add_node("copy"), std::string(name) + "-camera",
                            has_children ? "screen" : "" };
        layer.node->SetTranslate(linalg::Vector3f(-40, 20, 0));
        auto camera = std::make_shared<SceneCamera>(64, 32, -1, 1);
        camera->AttatchNode(has_children ? layer.node : effect_camera_node);
        scene.cameras[layer.camera] = camera;
        layer.node->SetCamera(layer.camera);
        if (! has_children) layer.node->SetRenderTransformOverride(linalg::Matrix4d::Identity());
        group->AppendChild(layer.node);
        layer.node->UpdateTrans();
        layer.card->SetRenderTransformOverride(layer.node->ModelTrans());
        updater.SetNodeData(layer.node.get(), WPShaderValueData {});
        WPShaderValueData pass;
        pass.effect_owner   = layer.node.get();
        pass.parallax_layer = layer.node.get();
        pass.parallaxDepth  = { 2.0f, 2.0f };
        updater.SetNodeData(layer.card.get(), pass);
        updater.InitUniforms(layer.node.get(), exists);
        updater.InitUniforms(layer.card.get(), exists);
        return layer;
    };
    // The matrix a pass is drawn with, through the camera the render graph names
    // (`camera_override`) or else the node's own, as the passes swap them.
    const auto mvp = [&](SceneNode& node, const std::string& camera_override = {}) {
        const std::string own = node.Camera();
        if (! camera_override.empty()) node.SetCamera(camera_override);
        sprite_map_t sprites;
        ShaderValue  actual;
        updater.UpdateUniforms(&node, sprites, [&](std::string_view name, const ShaderValue& v) {
            if (name == "g_ModelViewProjectionMatrix") actual = v;
        });
        node.SetCamera(own);
        return actual;
    };
    const auto expect_matrix = [](const ShaderValue& actual, const linalg::Matrix4d& expected,
                                  const char* what) {
        const auto wanted = ShaderValue::fromMatrix(expected);
        ASSERT_EQ(actual.size(), wanted.size()) << what;
        for (std::size_t i = 0; i < actual.size(); ++i) EXPECT_NEAR(actual[i], wanted[i], 1e-5) << what;
    };
    const auto moved = [](const linalg::Matrix4d& model, const linalg::Vector2d& by) -> linalg::Matrix4d {
        return linalg::Affine3d(linalg::Translation3d(by.x(), by.y(), 0.0)).matrix() * model;
    };
    const auto follows_cursor = [&](SceneNode& node, const std::string& camera_override) {
        return (updater.FrameVaryingUniforms(&node, 0, camera_override) &
                frame_varying_uniform::kParallax) != 0;
    };

    const auto with_children = add_layer("with-children", "composelayer", true);
    const auto leaf          = add_layer("leaf", "composelayer", false);
    const auto plain         = add_layer("plain", "genericimage", false);
    // A compose layer without effects draws its card itself and holds its own depth.
    auto bare = add_node("composelayer");
    bare->SetTranslate(linalg::Vector3f(-40, 20, 0));
    group->AppendChild(bare);
    bare->UpdateTrans();
    WPShaderValueData bare_data;
    bare_data.parallaxDepth = { 2.0f, 2.0f };
    updater.SetNodeData(bare.get(), bare_data);
    updater.InitUniforms(bare.get(), exists);

    const linalg::Matrix4d view_projection = screen->GetViewProjectionMatrix();
    const linalg::Matrix4d model           = leaf.node->ModelTrans();
    // The group is the outermost layer: it sits (80, -80) from the view centre, and
    // the cursor, when it moves, adds its own distance from the centre of the canvas.
    const linalg::Vector2d root_offset(80.0, -80.0);
    const double          depth_and_amount = 2.0 * 0.5;

    struct Cursor
    {
        const char*     name;
        double          x;
        linalg::Vector2d pull;
    };
    for (const auto& cursor : { Cursor { "cursor centred", 0.5, { 0.0, 0.0 } },
                                Cursor { "cursor right", 0.75, { -160.0, 0.0 } } }) {
        SCOPED_TRACE(cursor.name);
        updater.MouseInput(cursor.x, 0.5);
        updater.FrameBegin();
        const linalg::Vector2d shift = (cursor.pull + root_offset) * depth_and_amount;

        for (const auto* layer : { &with_children, &leaf }) {
            SCOPED_TRACE(layer == &leaf ? "a layer without children" : "a layer with children");
            const auto card_mvp  = mvp(*layer->card);
            const auto first_mvp = mvp(*layer->node, layer->first_pass_camera);
            expect_matrix(card_mvp, view_projection * moved(model, shift), "the card on the scene");
            expect_matrix(first_mvp, view_projection * moved(model, shift),
                          "the screen the first pass reads must be where the card is drawn");
            ASSERT_EQ(first_mvp.size(), card_mvp.size());
            for (std::size_t i = 0; i < first_mvp.size(); ++i) {
                EXPECT_NEAR(first_mvp[i], card_mvp[i], 1e-6);
            }
            // The card of a layer another layer samples is drawn through a layer-local
            // camera, where the layer sits in the scene does not reach the image.
            expect_matrix(mvp(*layer->node, "composite"), view_projection * model,
                          "a compose layer drawn into its composite");
        }
        // A layer that holds its depth on its own node is moved by it.
        expect_matrix(mvp(*bare), view_projection * moved(bare->ModelTrans(), shift),
                      "a compose layer without effects");
        // An ordinary effect layer draws its first pass into its own target.
        expect_matrix(mvp(*plain.node), scene.cameras.at(plain.camera)->GetViewProjectionMatrix(),
                      "the first pass of an ordinary effect layer");
    }

    // The first pass moves with the cursor, so it is never reused while it moves.
    for (const auto* layer : { &with_children, &leaf }) {
        EXPECT_TRUE(follows_cursor(*layer->node, layer->first_pass_camera));
        EXPECT_TRUE(follows_cursor(*layer->card, ""));
        EXPECT_FALSE(follows_cursor(*layer->node, "composite"));
    }
    EXPECT_TRUE(follows_cursor(*bare, ""));
    EXPECT_FALSE(follows_cursor(*plain.node, "")) << "an ordinary effect layer's first pass stands still";

    // A depth a script writes reaches the passes the layer's depth is on, so the
    // first pass keeps reading where the card is drawn, and stops moving with it
    // when the depth goes to zero. The first pass of an ordinary effect layer
    // stays where it is whatever the script writes.
    updater.MouseInput(0.5, 0.5);
    updater.FrameBegin();
    for (const auto* layer : { &with_children, &leaf, &plain }) {
        const bool compose = layer != &plain;
        SCOPED_TRACE(layer == &leaf ? "a layer without children"
                                    : compose ? "a layer with children" : "an ordinary effect layer");
        const auto first_pass = [&] {
            return mvp(*layer->node, layer->first_pass_camera);
        };
        const auto at_rest = [&] {
            return compose ? view_projection * model
                           : scene.cameras.at(layer->camera)->GetViewProjectionMatrix();
        };
        EXPECT_FALSE(updater.SetNodeParallaxDepth(layer->node.get(), 4.0f, 1.0f))
            << "it followed the cursor before and still does";
        EXPECT_EQ(updater.NodeParallaxDepth(layer->node.get()), (std::array<float, 2> { 4.0f, 1.0f }));
        if (compose) {
            const linalg::Vector2d shift(root_offset.x() * 4.0 * 0.5, root_offset.y() * 1.0 * 0.5);
            expect_matrix(mvp(*layer->card), view_projection * moved(model, shift),
                          "the card at the depth the script wrote");
            expect_matrix(first_pass(), view_projection * moved(model, shift),
                          "the first pass at the depth the script wrote");
            EXPECT_TRUE(follows_cursor(*layer->node, layer->first_pass_camera));
        } else {
            expect_matrix(first_pass(), at_rest(), "the first pass of an ordinary effect layer");
            EXPECT_FALSE(follows_cursor(*layer->node, layer->first_pass_camera));
        }
        EXPECT_TRUE(updater.SetNodeParallaxDepth(layer->node.get(), 0.0f, 0.0f))
            << "it stopped following the cursor";
        expect_matrix(first_pass(), at_rest(), "the first pass once the depth is zero");
        EXPECT_FALSE(follows_cursor(*layer->node, layer->first_pass_camera));
        EXPECT_FALSE(follows_cursor(*layer->card, ""));
    }
}

TEST(ScriptRuntimeCompat, ThisLayerAndThisSceneResolveCurrentLayer) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1920,
        .canvas_height = 1080,
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    node->SetTranslate(linalg::Vector3f(12.0f, 34.0f, 0.0f));
    runtime->RegisterNode("probe", node.get());
    runtime->RegisterNodeSize("probe", linalg::Vector2f(320.0f, 240.0f));

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
export function update(value) {
  var same = thisLayer === thisScene.getLayer('probe') ? 1 : 0;
  return same + thisLayer.origin.x * 10 + thisLayer.size.y * 1000;
}
)JS",
        "probe",
        {},
        DynamicValue(0.0f),
        runtime->hostContext());
    ASSERT_NE(program, nullptr);

    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 1.0f + 120.0f + 240000.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, UpstreamConsoleInputAndEngineCompatibilityStubsAreCallable) {
    ScriptEngine      engine;
    ScriptHostContext host {};
    host.canvas_size                = linalg::Vector2f(1920.0f, 1080.0f);
    host.cursor_normalized_position = linalg::Vector2f(0.25f, 0.75f);
    host.cursor_world_position      = linalg::Vector3f(480.0f, 270.0f, 0.0f);
    host.cursor_in_window           = true;
    host.mouse_buttons_down         = 3u;
    host.mouse_buttons_pressed      = 1u;
    host.mouse_buttons_released     = 2u;

    auto program = engine.CreatePropertyScriptProgram(
        nullptr,
        R"JS(
console.debug('debug');
console.trace('trace');
console.dir({ value: 1 });
console.assert(false, 'assertion text is ignored by the no-op shim');
console.group('group');
console.groupCollapsed('collapsed');
console.groupEnd();

export function update(value) {
  var ok = 0;
  if (typeof engine.isRunningInEditor === 'function' && engine.isRunningInEditor() === false) ok += 1;
  if (typeof engine.isScreensaver === 'function' && engine.isScreensaver() === false) ok += 1;
  if (typeof engine.isWallpaper === 'function' && engine.isWallpaper() === true) ok += 1;
  var isScreensaver = engine.isScreensaver;
  engine.isScreensaver = function() { return true; };
  if (engine.isWallpaper() === false) ok += 1;
  engine.isScreensaver = isScreensaver;
  if (typeof engine.isDesktopDevice === 'function' && engine.isDesktopDevice() === true) ok += 1;
  if (typeof engine.isMobileDevice === 'function' && engine.isMobileDevice() === false) ok += 1;
  if (input.cursorPosition.x === 0.25 && input.cursorPosition.y === 0.75) ok += 1;
  if (input.cursorWorldPosition.x === 480 && input.cursorWorldPosition.y === 270) ok += 1;
  if (input.cursorLocalPosition && input.cursorLocalPosition.x === 480) ok += 1;
  // Pixels from the display's top-left: 0.25 / 0.75 of the 1920x1080 canvas.
  if (input.cursorScreenPosition && input.cursorScreenPosition.x === 480 &&
      input.cursorScreenPosition.y === 810) ok += 1;
  if (input.mouseButtonsDown === 3 && input.mouseButtonsPressed === 1 && input.mouseButtonsReleased === 2) ok += 1;
  if (input.inWindow === true) ok += 1;
  return ok;
}
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(program, nullptr);

    const auto result = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 12.0f);
}

TEST(ScriptRuntimeCompat, LocalStorageRoundTripsObjectsInSharedRuntime) {
    ScriptEngine      engine;
    ScriptHostContext host {};

    auto writer = engine.CreatePropertyScriptProgram(
        nullptr,
        R"JS(
localStorage.set('number', 42);
localStorage.set('object', { nested: { value: 8 } });
export function update(value) { return 0; }
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(writer, nullptr);
    ASSERT_NE(writer->Evaluate(host, DynamicValue(0.0f)), nullptr);

    auto reader = engine.CreatePropertyScriptProgram(
        nullptr,
        R"JS(
export function update(value) {
  var object = localStorage.get('object');
  return localStorage.get('number') + object.nested.value;
}
)JS",
        "",
        {},
        DynamicValue(0.0f),
        host);
    ASSERT_NE(reader, nullptr);
    const auto result = reader->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 50.0f);
}

// WEMath exports `deg2rad` and `rad2deg` as the conversion factors themselves
// (`angle * WEMath.deg2rad`), plus `smoothStep(min, max, v)` and `mix(a, b, v)`.
TEST(ScriptRuntimeCompat, WEMathProvidesWallpaperEngineAliases) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
import * as M from 'WEMath';
export function update(value) {
  return Math.round(M.smoothStep(0, 1, 0.5) * 100) +
         Math.round(M.smoothstep(0, 1, 0.5) * 100) * 100 +
         Math.round(180 * M.deg2rad * 1000) * 10000 +
         Math.round(Math.PI * M.rad2deg) * 1000000000;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 50.0f + 50.0f * 100.0f + 3142.0f * 10000.0f +
                                           180.0f * 1000000000.0f);
}

TEST(ScriptRuntimeCompat, WEMathConstantsAreNumbersAndMixInterpolates) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
import { deg2rad, rad2deg, mix, smoothStep } from 'WEMath';
export function update(value) {
  var numbers = typeof deg2rad === 'number' && typeof rad2deg === 'number';
  var axis = new Vec3(90, 0, 180).multiply(deg2rad);
  var back = (Math.PI / 2) * rad2deg;
  var ok = numbers && Math.abs(axis.x - Math.PI / 2) < 1e-9 && Math.abs(axis.z - Math.PI) < 1e-9 &&
           Math.abs(back - 90) < 1e-9 && mix(10, 20, 0.25) === 12.5 && smoothStep(0, 2, 1) === 0.5;
  return ok ? 1 : 0;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 1.0f);
}

TEST(ScriptRuntimeCompat, WEColorConvertsBetweenRgbAndHsvAndScales) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
import { rgb2hsv, hsv2rgb, normalizeColor, expandColor } from 'WEColor';
function near(a, b) { return Math.abs(a - b) < 1e-6; }
export function update(value) {
  var green = rgb2hsv(new Vec3(0, 1, 0));
  var grey = rgb2hsv(new Vec3(0.5, 0.5, 0.5));
  var black = rgb2hsv(new Vec3(0, 0, 0));
  var wine = rgb2hsv(new Vec3(0.5, 0.1, 0.3));
  var round = hsv2rgb(wine);
  var unit = normalizeColor(new Vec3(255, 51, 0));
  var bytes = expandColor(new Vec3(1, 0.2, 0));
  var ok = near(green.x, 1 / 3) && near(green.y, 1) && near(green.z, 1) &&
           near(grey.x, 0) && near(grey.y, 0) && near(grey.z, 0.5) &&
           near(black.y, 0) && near(black.z, 0) &&
           near(round.x, 0.5) && near(round.y, 0.1) && near(round.z, 0.3) &&
           near(unit.x, 1) && near(unit.y, 0.2) && near(unit.z, 0) &&
           near(bytes.x, 255) && near(bytes.y, 51) && near(bytes.z, 0) &&
           unit instanceof Vec3;
  return ok ? 1 : 0;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 1.0f);
}

TEST(ScriptRuntimeCompat, WEVectorReportsTheAngleOfADirection) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
import { angleVector2, vectorAngle2 } from 'WEVector';
export function update(value) {
  var up = vectorAngle2(new Vec2(0, 1));
  var left = vectorAngle2(new Vec2(-1, 0));
  var round = vectorAngle2(angleVector2(37));
  return (Math.abs(up - 90) < 1e-9 && Math.abs(left - 180) < 1e-9 && Math.abs(round - 37) < 1e-9) ? 1 : 0;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 1.0f);
}

TEST(ScriptRuntimeCompat, LocalStorageDeleteRemovesAKeyAndRemoveStaysAnAlias) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
export function update(value) {
  localStorage.set('a', 1);
  localStorage.set('b', 2);
  localStorage.set('c', 3);
  localStorage.delete('a');
  localStorage.remove('b');
  var seen = (localStorage.get('a') === undefined ? 0 : 1) + (localStorage.get('b') === undefined ? 0 : 10) +
             (localStorage.get('c') === 3 ? 100 : 0);
  localStorage.clear();
  return seen + (localStorage.get('c') === undefined ? 1000 : 0);
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 1100.0f);
}

// A pointer at a quarter of the way across and three quarters of the way down a
// 2560x1440 display is at pixel (640, 1080) counted from the top-left, whatever
// the scene's own coordinates make of it. The primary button is the lowest bit.
TEST(ScriptRuntimeCompat, CursorScreenPositionIsInDisplayPixelsFromTheTop) {
    ScriptEngine      engine;
    ScriptHostContext host {};
    host.canvas_size                = linalg::Vector2f(1920.0f, 1080.0f);
    host.screen_resolution          = linalg::Vector2f(2560.0f, 1440.0f);
    host.cursor_normalized_position = linalg::Vector2f(0.25f, 0.75f);
    host.cursor_world_position      = linalg::Vector3f(480.0f, 270.0f, 0.0f);
    host.mouse_buttons_down         = 0u;

    auto program = engine.CreatePropertyScriptProgram(
        nullptr,
        R"JS(
export function update(value) {
  var p = input.cursorScreenPosition;
  // Dividing by the screen resolution gives the fraction back, which is how
  // scripts turn it into their own layout coordinates.
  var fractionOk = Math.abs(p.y / engine.screenResolution.y - 0.75) < 1e-6;
  return p.x + p.y * 10000 + (input.cursorLeftDown === true ? 1e8 : 0) + (fractionOk ? 0 : 5e7);
}
)JS",
        "", {}, DynamicValue(0.0f), host);
    ASSERT_NE(program, nullptr);

    auto idle = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(idle, nullptr);
    // 640 + 1080 * 10000 = 10800640; floats hold it exactly.
    EXPECT_FLOAT_EQ(idle->getFloat(), 10800640.0f);

    host.mouse_buttons_down = 1u;
    auto held = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(held, nullptr);
    EXPECT_FLOAT_EQ(held->getFloat(), 10800640.0f + 1.0e8f);

    // Only the primary button counts; a right-button hold leaves it up.
    host.mouse_buttons_down = 2u;
    auto secondary = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(secondary, nullptr);
    EXPECT_FLOAT_EQ(secondary->getFloat(), 10800640.0f);
}

// `engine.timeOfDay` is the local clock as a fraction of the day, the value
// shaders read as `g_Daytime`. While it was missing, a blend amount a script
// derived from the hour came out NaN and the effect drew its layer black.
TEST(ScriptRuntimeCompat, EngineTimeOfDayFollowsTheLocalClock) {
    ScriptEngine engine;
    const auto   before = LocalTimeOfDay(std::chrono::system_clock::now());
    const auto   result = EvaluateScalar(engine,
                                       R"JS(
export function update(value) { return engine.timeOfDay; }
)JS");
    const auto   after  = LocalTimeOfDay(std::chrono::system_clock::now());
    ASSERT_TRUE(before.has_value() && after.has_value());

    const double time_of_day = result.getFloat();
    const double tolerance   = 1.0e-6;
    EXPECT_GE(time_of_day, 0.0);
    EXPECT_LE(time_of_day, 1.0);
    if (*before <= *after) {
        EXPECT_GE(time_of_day, *before - tolerance);
        EXPECT_LE(time_of_day, *after + tolerance);
    } else {
        // Midnight passed while the script ran.
        EXPECT_TRUE(time_of_day >= *before - tolerance || time_of_day <= *after + tolerance);
    }
}

TEST(ScriptRuntimeCompat, WEColorHsv2RgbSupportsNamespaceImport) {
    ScriptEngine engine;
    const auto   result = EvaluateScalar(
        engine,
        R"JS(
import * as WEColor from 'WEColor';
export function update(value) {
  var red = WEColor.hsv2rgb({ x: 0.0, y: 1.0, z: 1.0 });
  var green = WEColor.hsv2rgb({ x: 1.0 / 3.0, y: 1.0, z: 1.0 });
  var blue = WEColor.hsv2rgb({ x: 2.0 / 3.0, y: 1.0, z: 1.0 });
  return red.x + green.y * 10 + blue.z * 100;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 111.0f);
}

// Scripts pasted from a rich-text editor carry U+00A0 where a space was typed.
// JavaScript reads that as whitespace, so `export` has to be stripped after it
// as after a space: left in place, the program does not compile and the layer
// keeps its authored value for good. One export starts its line and the other
// follows a statement: those are the two places the rewrite looks. Only the
// keyword goes: a comment that ends with the word keeps its line break, or the
// next line would become part of the comment.
TEST(ScriptRuntimeCompat, ExportFollowedByUnicodeWhitespaceStillCompiles) {
    ScriptEngine engine;
    const auto   result = EvaluateScalar(engine,
                                       "// values we export\n"
                                       "var scale = 2;\n"
                                       "export\u00a0var\u00a0factor = 3;\n"
                                       "var unused = 0; export\u00a0function\u00a0update (value) {\n"
                                       "  return factor * 7 * scale;\n"
                                       "}\n");
    EXPECT_FLOAT_EQ(result.getFloat(), 42.0f);
}

// A property script that also listens for scene events is run as a property
// only when it declares `update`. The declaration has to be found whatever the
// author put between the tokens: missed, the script runs as a scene script and
// the property never moves.
TEST(ScriptRuntimeCompat, AnUpdateSeparatedByUnicodeWhitespaceStillDrivesItsProperty) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto value   = ResolveFloatSetting(
        *runtime,
        { { "value", 1.0f },
          { "script", "engine.on('resizeScreen', function() {});\n"
                      "export\u00a0function\u00a0update(value) {\n"
                      "  return 5;\n"
                      "}\n" } });
    ASSERT_NE(value, nullptr);
    runtime->Tick(1.0 / 60.0);
    EXPECT_FLOAT_EQ(value->getFloat(), 5.0f);
}

// The rarer separators are matched here, where no JavaScript is compiled.
TEST(ScriptModuleSyntax, AnExportedFunctionIsFoundAcrossEverySeparatorAndNowhereElse) {
    EXPECT_TRUE(ExportsFunction("export function update(value) {}", "update"));
    // U+FEFF is whitespace to JavaScript but not Unicode White_Space.
    EXPECT_TRUE(ExportsFunction("export\ufefffunction\u3000update (value) {}", "update"));
    EXPECT_TRUE(ExportsFunction("export\n  function\tupdate\u00a0(value) {}", "update"));
    // Wherever a statement can start.
    EXPECT_TRUE(ExportsFunction("var a = 1;export function update(value) {}", "update"));
    EXPECT_TRUE(ExportsFunction("function a() {}export function update(value) {}", "update"));
    EXPECT_TRUE(ExportsFunction("var a = 1;\u3000export function update(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("reexport function update(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("module.export function update(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("export function updateAll(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("export functionupdate(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("exportfunction update(value) {}", "update"));
    EXPECT_FALSE(ExportsFunction("function update(value) {}", "update"));
}

TEST(ScriptRuntimeCompat, Vec3SupportsCopyAndScalarSplat) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
export function update(value) {
  var splat = new Vec3(3);
  var copy = splat.copy();
  copy.x = 9;
  return splat.x + splat.y * 10 + splat.z * 100 + copy.x * 1000;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 9333.0f);
}

TEST(ScriptRuntimeCompat, HostVectorUpdatesDoNotCallMutableGlobalVectorConstructors) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    ScriptHostContext host {};
    host.canvas_size                = linalg::Vector2f(100.0f, 50.0f);
    host.cursor_normalized_position = linalg::Vector2f(0.1f, 0.2f);
    host.cursor_world_position      = linalg::Vector3f(10.0f, 20.0f, 0.0f);
    DynamicValue tint(linalg::Vector4f(0.5f, 0.25f, 0.125f, 0.75f));

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
export var scriptProperties = createScriptProperties().finish();
var savedVec2 = Vec2;
var savedVec3 = Vec3;
var savedVec4 = Vec4;
Vec2 = function(x, y) { return new Vec2(x, y); };
Vec3 = function(x, y, z) { return new Vec3(x, y, z); };
Vec4 = function(x, y, z, w) { return new Vec4(x, y, z, w); };

export function update(value) {
  var constructed = new savedVec3(1, 2, 3);
  return input.cursorPosition.x + input.cursorWorldPosition.y + engine.canvasSize.x +
         scriptProperties.tint.w + constructed.z;
}
)JS",
        "",
        { { "tint", &tint } },
        DynamicValue(0.0f),
        host);
    ASSERT_NE(program, nullptr);

    host.canvas_size                = linalg::Vector2f(200.0f, 100.0f);
    host.cursor_normalized_position = linalg::Vector2f(0.25f, 0.75f);
    host.cursor_world_position      = linalg::Vector3f(25.0f, 75.0f, 0.0f);
    const auto result = program->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 279.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

namespace {
// One authored layer, `owner`, whose model `models/line.json` scripts copy.
struct LineTemplateScene {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> runtime = MakeRuntimeWithScene(scene);
    std::shared_ptr<SceneNode>           owner   = std::make_shared<SceneNode>(
        linalg::Vector3f::Zero(), linalg::Vector3f::Ones(), linalg::Vector3f::Zero(), "owner");

    LineTemplateScene() {
        auto mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(SceneMaterial {});
        owner->AddMesh(mesh);
        scene.sceneGraph->AppendChild(owner);
        runtime->RegisterNode("owner", owner.get());
        runtime->RegisterLayerTemplate("models/line.json", owner, linalg::Vector2f(1, 1));
    }
};
} // namespace

// A script that rebuilds the layers it made when its settings change destroys
// the old ones first (IScene.destroyLayer, by reference or by name). They leave
// the scene graph, and the layer object the script still holds does nothing.
TEST(ScriptRuntimeCompat, DestroyLayerRemovesALayerTheScriptCreated) {
    LineTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    ScriptHostContext host {};
    auto program = runtime.scriptEngine().CreatePropertyScriptProgram(&runtime,
                                                                      R"JS(
export var scriptProperties = createScriptProperties().finish();
var lines = [];
var first;
function build() {
  for (var i = 0; i < lines.length; ++i) {
    if (thisScene.destroyLayer(lines[i]) !== true) throw new Error('a created layer stayed');
  }
  lines = [];
  for (var j = 0; j < 3; ++j) lines.push(thisScene.createLayer('models/line.json'));
}
export function init(value) {
  build();
  first = lines[0];
  return value;
}
export function applyUserProperties() {
  build();
  if (thisScene.destroyLayer(first) !== false) throw new Error('a layer was destroyed twice');
  first.visible = true;
  first.origin = new Vec3(5, 6, 0);
  if (first.visible) throw new Error('a destroyed layer can still be shown');
  if (thisScene.destroyLayer(lines.pop().name) !== true) throw new Error('a name was not destroyed');
}
export function update(value) { return value; }
)JS",
                                                                      "owner",
                                                                      {},
                                                                      DynamicValue(0.0f),
                                                                      host);
    ASSERT_NE(program, nullptr);
    program->Evaluate(host, DynamicValue(0.0f));

    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;
    const auto& layers = fixture.scene.sceneGraph->GetChildren();
    ASSERT_EQ(layers.size(), 3u);
    EXPECT_EQ(layers.front(), fixture.owner);
    for (const auto& layer : layers) {
        EXPECT_TRUE(layer->Translate().isZero()) << layer->Name();
    }
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
}

// The graph compiled before a layer was destroyed still points at it, so the
// layer leaves the scene graph at once but is freed only after the graph has
// been rebuilt without it, which consuming the mutation flag stands for.
TEST(ScriptRuntimeCompat, ADestroyedLayerIsFreedOnlyOnceTheGraphNoLongerDrawsIt) {
    LineTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    runtime.RegisterSceneScript(R"JS(
var ticks = 0;
var line;
function update() {
  ++ticks;
  if (ticks === 1) line = thisScene.createLayer('models/line.json');
  if (ticks === 2 && thisScene.destroyLayer(line) !== true) throw new Error('the line stayed');
}
)JS",
                                "owner");

    runtime.Tick(1.0 / 60.0);
    ASSERT_EQ(fixture.scene.sceneGraph->GetChildren().size(), 2u);
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    const std::weak_ptr<SceneNode> line = fixture.scene.sceneGraph->GetChildren().back();

    runtime.Tick(1.0 / 60.0);
    EXPECT_EQ(fixture.scene.sceneGraph->GetChildren().size(), 1u);
    runtime.Tick(1.0 / 60.0);
    EXPECT_FALSE(line.expired());
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    runtime.Tick(1.0 / 60.0);
    EXPECT_TRUE(line.expired());
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;
}

TEST(ScriptRuntimeCompat, ScriptsLoadedByAnEventStartWithTheFollowingEvent) {
    for (const int event : {0, 1, 2}) {
        SCOPED_TRACE(event);
        Scene scene;
        auto runtime = MakeRuntimeWithScene(scene);
        auto observer = std::make_shared<SceneNode>();
        runtime->RegisterNode("observer", observer.get());
        scene.sceneGraph->AppendChild(observer);
        const std::string handler = event == 2 ? "mediaThumbnailChanged" : "cursorClick";
        const auto increment = [](const std::string& axis) {
            return "var n=thisScene.getLayer('observer'); var p=n.origin; p." + axis +
                   "+=1; n.origin=p;";
        };
        int loads = 0;
        runtime->SetLayerTemplateLoader([&](std::string_view path) {
            ++loads;
            auto source = std::make_shared<SceneNode>();
            auto mesh = std::make_shared<SceneMesh>();
            mesh->AddMaterial(SceneMaterial {});
            source->AddMesh(mesh);
            runtime->RegisterMaterialConstant(mesh->MaterialSlotPtr(), "u_Event",
                ResolveFloatSetting(*runtime, {
                    {"value", 0.0f}, {"script", "export function " + handler + "(){" + increment("y") + "}"}
                }));
            runtime->RegisterSceneScript("function " + handler + "(){" + increment("z") + "}", "");
            runtime->RegisterLayerTemplate(std::string(path), source, linalg::Vector2f(16, 16));
            return true;
        });
        runtime->RegisterSceneScript("var made=false; function " + handler +
            "(){if(!made){made=true;thisScene.createLayer('models/event.json');}" + increment("x") + "}", "");
        runtime->SetMediaIntegrationEnabled(true);
        const auto dispatch = [&] {
            if (event == 0) runtime->DispatchCursorClick(0);
            else if (event == 1) {
                runtime->SetCursorEnter(true);
                runtime->SetCursorButtons(1, 1, 0);
                runtime->DispatchCursorFrameEvents(true);
            } else {
                runtime->DispatchMediaEventJson(R"({"type":"mediaThumbnailChanged","hasThumbnail":false})");
            }
        };
        dispatch();
        EXPECT_EQ(loads, 1);
        EXPECT_TRUE(observer->Translate().isApprox(linalg::Vector3f(1, 0, 0)));
        dispatch();
        EXPECT_EQ(loads, 1);
        EXPECT_TRUE(observer->Translate().isApprox(linalg::Vector3f(2, 1, 1)));
        EXPECT_EQ(runtime->scriptErrorCount(), 0u);
    }
}

TEST(ScriptRuntimeCompat, LazyTemplateScriptsStartOnTheFollowingTickAndLoadedGeometryIsReusable) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto owner = std::make_shared<SceneNode>();
    scene.sceneGraph->AppendChild(owner);
    std::shared_ptr<SceneMesh> loaded_mesh;
    int loads = 0;
    runtime->SetLayerTemplateLoader([&](std::string_view path) {
        ++loads;
        auto source = std::make_shared<SceneNode>();
        loaded_mesh = std::make_shared<SceneMesh>();
        loaded_mesh->AddMaterial(SceneMaterial {});
        source->AddMesh(loaded_mesh);
        runtime->RegisterMaterialConstant(loaded_mesh->MaterialSlotPtr(), "u_Age",
            ResolveFloatSetting(*runtime, {
                {"value", 0.0f}, {"script", R"JS(
export function update(value) { return value + 1; }
)JS"}
            }));
        runtime->RegisterLayerTemplate(std::string(path), source, linalg::Vector2f(32, 32));
        return true;
    });
    runtime->RegisterNodeVisibility("owner", owner.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
let frame = 0;
export function update(value) {
    const point = thisScene.createLayer({image: 'models/lazy.json'});
    point.origin = new Vec3(++frame, 0, 0);
    return value;
}
)JS"}}, "owner"));
    EXPECT_EQ(loads, 0);
    runtime->Tick(0.01);
    ASSERT_NE(loaded_mesh, nullptr);
    EXPECT_FLOAT_EQ(loaded_mesh->Material()->customShader.constValues.at("u_Age")[0], 0);
    runtime->Tick(0.01);
    EXPECT_EQ(loads, 1);
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 3u);
    auto first = std::next(scene.sceneGraph->GetChildren().begin());
    auto second = std::next(first);
    EXPECT_TRUE((*first)->Translate().isApprox(linalg::Vector3f(1, 0, 0)));
    EXPECT_TRUE((*second)->Translate().isApprox(linalg::Vector3f(2, 0, 0)));
    EXPECT_FLOAT_EQ((*first)->Mesh()->Material()->customShader.constValues.at("u_Age")[0], 1);
    EXPECT_FLOAT_EQ((*second)->Mesh()->Material()->customShader.constValues.at("u_Age")[0], 1);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, RecursiveTemplateLoadsAreGuardedAndMissingAssetsAreNotRetried) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    int loads = 0;
    runtime->SetLayerTemplateLoader([&](std::string_view path) {
        ++loads;
        EXPECT_TRUE(runtime->CreateLayerFromTemplate(path, "").empty());
        if (path == "models/missing.json") return false;
        auto source = std::make_shared<SceneNode>();
        runtime->RegisterLayerTemplate(std::string(path), source, linalg::Vector2f(32, 32));
        return true;
    });
    const auto first = runtime->CreateLayerFromTemplate("models/available.json", "");
    const auto second = runtime->CreateLayerFromTemplate("models/available.json", "");
    ASSERT_FALSE(first.empty());
    ASSERT_FALSE(second.empty());
    EXPECT_NE(first, second);
    runtime->SetNodeTranslate(first, linalg::Vector3f(1, 2, 3));
    EXPECT_TRUE(runtime->NodeTranslate(second).isZero());
    EXPECT_TRUE(runtime->CreateLayerFromTemplate("models/missing.json", "").empty());
    EXPECT_TRUE(runtime->CreateLayerFromTemplate("models/missing.json", "").empty());
    EXPECT_EQ(loads, 2);
}

// The editor stores an asset imported from the Workshop under
// `models/workshop/<item>/` and writes `__workshopId` into its script, which
// still names the files as they were in the asset's own project. The source
// layers are often hidden, so nothing registers them before the script asks.
namespace
{
struct WorkshopTemplateScene {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> runtime = MakeRuntimeWithScene(scene);
    std::shared_ptr<SceneNode>           owner   = std::make_shared<SceneNode>(
        linalg::Vector3f::Zero(), linalg::Vector3f::Ones(), linalg::Vector3f::Zero(), "owner");
    std::vector<std::string> requested;

    explicit WorkshopTemplateScene(std::vector<std::string> loadable) {
        scene.sceneGraph->AppendChild(owner);
        runtime->RegisterNode("owner", owner.get());
        runtime->SetLayerTemplateLoader([this, loadable](std::string_view path) {
            requested.emplace_back(path);
            if (std::find(loadable.begin(), loadable.end(), path) == loadable.end()) return false;
            auto source = std::make_shared<SceneNode>();
            auto mesh   = std::make_shared<SceneMesh>();
            mesh->AddMaterial(SceneMaterial {});
            source->AddMesh(mesh);
            runtime->RegisterLayerTemplate(std::string(path), source, linalg::Vector2f(8, 8));
            return true;
        });
    }

    std::size_t CreatedLayers() const { return scene.sceneGraph->GetChildren().size() - 1u; }
};

std::string BarScript(std::string_view declaration) {
    return std::string(declaration) + R"JS(
var bars = [];
export function init() {
  for (var i = 0; i < 3; ++i) bars.push(thisScene.createLayer('models/bar.json'));
}
export function update(value) {
  bars[2].origin = new Vec3(1, 2, 0);
  return value;
}
)JS";
}
} // namespace

TEST(ScriptRuntimeCompat, CreateLayerFindsTheAssetsOfTheWorkshopItemItsScriptDeclares) {
    for (const bool property_script : { false, true }) {
        SCOPED_TRACE(property_script ? "property script" : "scene script");
        WorkshopTemplateScene fixture({ "models/workshop/2398102478/bar.json" });
        auto& runtime = *fixture.runtime;
        const auto script = BarScript("export let __workshopId = '2398102478';");
        if (property_script) {
            runtime.RegisterNodeVisibility(
                "owner",
                fixture.owner.get(),
                ResolveBoolSetting(runtime,
                                   nlohmann::json { { "script", script }, { "value", true } },
                                   "owner"));
        } else {
            runtime.RegisterSceneScript(script, "owner");
        }

        runtime.Tick(1.0 / 60.0);
        runtime.Tick(1.0 / 60.0);

        EXPECT_EQ(fixture.CreatedLayers(), 3u);
        EXPECT_EQ(runtime.scriptErrorCount(), 0u);
        // Each spelling is looked up once, not once per layer.
        EXPECT_EQ(fixture.requested,
                  (std::vector<std::string> { "models/bar.json",
                                              "models/workshop/2398102478/bar.json" }));
    }
}

// The scene layer that uses a model registers as its template, but one with an
// effect chain (its own camera) or child layers cannot be copied. The model
// still makes a layer, as it does when no scene layer uses it.
TEST(ScriptRuntimeCompat, CreateLayerBuildsTheModelsOwnLayerWhenTheLayerUsingItCannotBeCopied) {
    for (const bool has_effects : { true, false }) {
        SCOPED_TRACE(has_effects ? "owner with effects" : "owner with a child layer");
        WorkshopTemplateScene fixture({ "models/workshop/2398102478/bar.json" });
        auto& runtime = *fixture.runtime;
        if (has_effects) {
            fixture.owner->SetCamera("owner-effects");
        } else {
            fixture.owner->AppendChild(std::make_shared<SceneNode>());
        }
        runtime.RegisterLayerTemplate(
            "models/workshop/2398102478/bar.json", fixture.owner, linalg::Vector2f(8, 8));
        runtime.RegisterNodeVisibility(
            "owner",
            fixture.owner.get(),
            ResolveBoolSetting(runtime,
                               nlohmann::json {
                                   { "script", BarScript("export let __workshopId = '2398102478';") },
                                   { "value", true } },
                               "owner"));

        runtime.Tick(1.0 / 60.0);
        runtime.Tick(1.0 / 60.0);

        ASSERT_EQ(fixture.CreatedLayers(), 3u);
        EXPECT_EQ(runtime.scriptErrorCount(), 0u);
        for (const auto& created : fixture.scene.sceneGraph->GetChildren()) {
            if (created == fixture.owner) continue;
            EXPECT_TRUE(created->Camera().empty());
            EXPECT_TRUE(created->GetChildren().empty());
        }
        EXPECT_TRUE(fixture.scene.sceneGraph->GetChildren().back()->Translate().isApprox(
            linalg::Vector3f(1, 2, 0)));
        EXPECT_EQ(fixture.requested,
                  (std::vector<std::string> { "models/workshop/2398102478/bar.json" }));
    }
}

TEST(ScriptRuntimeCompat, CreateLayerDoesNotReloadAModelThatLoadsIntoALayerItCannotCopy) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    const auto uncopyable = [] {
        auto node = std::make_shared<SceneNode>();
        node->SetCamera("effects");
        return node;
    };
    runtime->RegisterLayerTemplate("models/fx.json", uncopyable(), linalg::Vector2f(8, 8));
    int loads = 0;
    runtime->SetLayerTemplateLoader([&](std::string_view path) {
        ++loads;
        runtime->RegisterLayerTemplate(std::string(path), uncopyable(), linalg::Vector2f(8, 8));
        return true;
    });

    EXPECT_TRUE(runtime->CreateLayerFromTemplate("models/fx.json", "").empty());
    EXPECT_TRUE(runtime->CreateLayerFromTemplate("models/fx.json", "").empty());
    EXPECT_EQ(loads, 1);
}

TEST(ScriptRuntimeCompat, CreateLayerPrefersThePathAsWrittenOverTheDeclaredWorkshopItem) {
    WorkshopTemplateScene fixture(
        { "models/bar.json", "models/workshop/2398102478/bar.json" });
    fixture.runtime->RegisterSceneScript(
        BarScript("export let __workshopId = '2398102478';"), "owner");

    fixture.runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(fixture.CreatedLayers(), 3u);
    EXPECT_EQ(fixture.requested, (std::vector<std::string> { "models/bar.json" }));
}

TEST(ScriptRuntimeCompat, CreateLayerLooksInAWorkshopFolderOnlyForANumericDeclaredItem) {
    for (const std::string declaration :
         { "", "export let __workshopId = '';", "export let __workshopId = '../2398102478';" }) {
        SCOPED_TRACE(declaration);
        WorkshopTemplateScene fixture({ "models/workshop/2398102478/bar.json" });
        fixture.runtime->RegisterSceneScript(BarScript(declaration), "owner");

        fixture.runtime->Tick(1.0 / 60.0);

        EXPECT_EQ(fixture.CreatedLayers(), 0u);
        EXPECT_EQ(fixture.requested, (std::vector<std::string> { "models/bar.json" }));
    }
}

TEST(ScriptRuntimeCompat, CachedFactoriesCreateLayersBesideTheirOwnOwner) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto source = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    source->AddMesh(mesh);
    runtime->RegisterLayerTemplate("models/point.json", source, linalg::Vector2f(32, 32));
    const std::string script = R"JS(
let point;
export function update(value) {
    if (!point) point = thisScene.createLayer('models/point.json');
    point.origin = thisLayer.origin;
    return value;
}
)JS";
    std::array<std::shared_ptr<SceneNode>, 2> parents;
    for (int index = 0; index < 2; ++index) {
        parents[index] = std::make_shared<SceneNode>();
        auto owner = std::make_shared<SceneNode>();
        owner->SetTranslate(linalg::Vector3f(10 * (index + 1), 0, 0));
        parents[index]->AppendChild(owner);
        scene.sceneGraph->AppendChild(parents[index]);
        const auto name = "owner" + std::to_string(index);
        runtime->RegisterNodeVisibility(name, owner.get(), ResolveBoolSetting(*runtime, {
            {"value", true}, {"script", script}
        }, name));
    }
    runtime->Tick(0.01);
    for (int index = 0; index < 2; ++index) {
        ASSERT_EQ(parents[index]->GetChildren().size(), 2u);
        EXPECT_TRUE(parents[index]->GetChildren().back()->Translate().isApprox(
            linalg::Vector3f(10 * (index + 1), 0, 0)));
    }
    runtime->Tick(0.01);
    for (const auto& parent : parents) EXPECT_EQ(parent->GetChildren().size(), 2u);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ConfiguredTrailPoolKeepsIndependentLayersAndRecyclesWithoutCloning) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto source = std::make_shared<SceneNode>(
        linalg::Vector3f::Zero(), linalg::Vector3f::Ones(), linalg::Vector3f::Zero(), "source");
    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial material;
    material.customShader.constValues["g_Color"] = std::array<float, 3> {1, 1, 1};
    material.customShader.constValues["g_Color4"] = std::array<float, 4> {1, 1, 1, 0.9f};
    material.customShader.constValues["g_UserAlpha"] = 0.9f;
    material.customShader.constValues["g_Alpha"] = 0.9f;
    mesh->AddMaterial(std::move(material));
    source->AddMesh(mesh);
    scene.sceneGraph->AppendChild(source);
    runtime->RegisterNode("source", source.get());
    runtime->RegisterLayerTemplate("models/point.json", source, linalg::Vector2f(32, 32));
    runtime->RegisterSceneScript(R"JS(
let points = [], frame = 0;
export function update() {
    ++frame;
    let point;
    if (points.length < 3) {
        point = thisScene.createLayer({
            image: 'models/point.json',
            origin: new Vec3(frame, 2, -3),
            scale: '0.1 0.2 0.3',
            angles: new Vec3(0, 0, 90),
            color: new Vec3(0.2, 0.4, 0.6),
            alpha: 0.25,
            visible: false
        });
    } else {
        point = points.shift();
        point.origin = new Vec3(frame, 2, -3);
        point.color = new Vec3(0.6, 0.4, 0.2);
        point.alpha = 0.5;
        point.visible = true;
    }
    points.push(point);
}
)JS", "source");

    runtime->Tick(0.01);
    auto first = scene.sceneGraph->GetChildren().back();
    EXPECT_TRUE(first->Translate().isApprox(linalg::Vector3f(1, 2, -3)));
    EXPECT_TRUE(first->Scale().isApprox(linalg::Vector3f(0.1f, 0.2f, 0.3f)));
    EXPECT_NEAR(first->Rotation().z(), 1.57079632679f, 1.0e-6f);
    EXPECT_FALSE(first->Visible());
    EXPECT_EQ(runtime->NodeAlpha(first->Name()), 0.25f);
    EXPECT_TRUE(runtime->NodeColor(first->Name()).isApprox(linalg::Vector3f(0.2f, 0.4f, 0.6f)));
    EXPECT_FLOAT_EQ(first->Mesh()->Material()->customShader.constValues.at("g_Alpha")[0], 0.25f);
    runtime->Tick(0.01);
    auto second = scene.sceneGraph->GetChildren().back();
    EXPECT_NE(first, second);
    EXPECT_TRUE(first->Translate().isApprox(linalg::Vector3f(1, 2, -3)));
    EXPECT_TRUE(second->Translate().isApprox(linalg::Vector3f(2, 2, -3)));
    for (int frame = 3; frame <= 8; ++frame) runtime->Tick(0.01);
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 4u);
    EXPECT_TRUE(first->Translate().isApprox(linalg::Vector3f(7, 2, -3)));
    EXPECT_TRUE(second->Translate().isApprox(linalg::Vector3f(8, 2, -3)));
    for (const auto& point : scene.sceneGraph->GetChildren()) {
        if (point == source) continue;
        EXPECT_TRUE(point->Visible());
        EXPECT_EQ(runtime->NodeAlpha(point->Name()), 0.5f);
        EXPECT_TRUE(runtime->NodeColor(point->Name()).isApprox(linalg::Vector3f(0.6f, 0.4f, 0.2f)));
        EXPECT_FLOAT_EQ(point->Mesh()->Material()->customShader.constValues.at("g_Color4")[3], 0.5f);
    }
    EXPECT_TRUE(source->Translate().isZero());
    EXPECT_TRUE(source->Scale().isOnes());
    EXPECT_TRUE(runtime->NodeColor("source").isOnes());
    EXPECT_FLOAT_EQ(mesh->Material()->customShader.constValues.at("g_Alpha")[0], 0.9f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, SharedProducerRunsBeforeDependentTextAndAdvancesOncePerTick) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto producer = std::make_shared<SceneNode>();
    runtime->RegisterNodeVisibility("producer", producer.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
let count = 0;
export function update(value) {
    shared.position = ++count + engine.runtime;
    return value;
}
)JS"}}, "producer"));
    runtime->RegisterTextLayer("readout", TextLayerState { .text = "initial" });
    runtime->RegisterTextValue("readout", ResolveStringSetting(*runtime, {
        {"value", "initial"}, {"script", R"JS(
export function update(value) { return shared.position.toFixed(2); }
)JS"}}, "readout"), false);
    EXPECT_EQ(runtime->NodeText("readout"), "initial");
    runtime->Tick(0.25);
    EXPECT_EQ(runtime->NodeText("readout"), "1.25");
    runtime->Tick(0.25);
    EXPECT_EQ(runtime->NodeText("readout"), "2.50");
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, PausedMaterialTimelinePlaysOnlyWhenScriptRequestsIt) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);
    auto material = std::make_shared<SceneMaterial>();
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", node.get());
    const auto setting = nlohmann::json::parse(R"({
        "value":1.5,
        "animation":{
            "options":{"fps":30,"length":9,"mode":"single","startpaused":true,"name":"transition"},
            "c0":[{"frame":0,"value":0},{"frame":5,"value":1.5},{"frame":9,"value":0}]
        }
    })");
    const auto animation = ResolveScalarAnimation(setting);
    ASSERT_TRUE(animation.has_value());
    auto timeline             = std::make_shared<MaterialConstantAnimation>();
    timeline->components[0]   = *animation;
    timeline->component_count = 1;
    timeline->playback        = runtime->RegisterScalarAnimation("subject", *animation);
    runtime->RegisterMaterialConstant(material, "u_Opacity", std::make_unique<DynamicValue>(1.5f),
                                      timeline);
    const auto command = [&](std::string source) {
        auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
            runtime.get(), "export function update(value) { " + source + "; return value; }",
            "subject", {}, DynamicValue(0.0f), runtime->hostContext());
        EXPECT_TRUE(program->Valid());
        program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    };

    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    command("thisLayer.getAnimation('transition').play()");
    runtime->Tick(5.0 / 30.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 1.5f);
    command("thisLayer.getAnimation('transition').pause()");
    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 1.5f);
    command("thisLayer.getAnimation('transition').play()");
    runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    command("thisLayer.getAnimation('transition').play(); thisLayer.getAnimation('transition').rate = 2");
    runtime->Tick(2.5 / 30.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 1.5f);
    command("thisLayer.getAnimation('transition').stop()");
    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 0.0f);
    command("thisLayer.getAnimation('transition').setFrame(5)");
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Opacity")[0], 1.5f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// Vector constants animate per component, so a shader reading `xyzw` has to see
// every animated channel move and every unanimated channel keep its own value.
std::shared_ptr<MaterialConstantAnimation> BuildComponentTimeline(const nlohmann::json& setting,
                                                                  std::size_t components) {
    auto timeline             = std::make_shared<MaterialConstantAnimation>();
    timeline->component_count = components;
    for (std::size_t index = 0; index < components; ++index) {
        if (auto curve = ResolveScalarAnimation(setting, index)) {
            timeline->components[index] = std::move(*curve);
        } else {
            timeline->components[index].initial_value =
                setting.at("value").at(index).get<float>();
        }
    }
    return timeline;
}

TEST(ScriptRuntimeCompat, VectorMaterialTimelineDrivesEveryComponentSeparately) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);
    auto material = std::make_shared<SceneMaterial>();
    auto node     = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", node.get());
    const auto setting = nlohmann::json::parse(R"({
        "value":[0,0,0.25,0],
        "animation":{
            "options":{"fps":30,"length":6,"mode":"single","startpaused":true,"name":"fold"},
            "c0":[{"frame":0,"value":1},{"frame":6,"value":2}],
            "c1":[{"frame":0,"value":-1},{"frame":6,"value":-4}],
            "c3":[{"frame":0,"value":10},{"frame":3,"value":16}]
        }
    })");
    auto timeline      = BuildComponentTimeline(setting, 4);
    timeline->playback = runtime->RegisterScalarAnimation("subject", timeline->components[0]);
    runtime->RegisterMaterialConstant(
        material, "u_Fold", std::make_unique<DynamicValue>(linalg::Vector4f(0.0f, 0.0f, 0.0f, 0.0f)),
        timeline);
    const auto component = [&](std::size_t index) {
        return material->customShader.constValues.at("u_Fold")[index];
    };
    const auto command = [&](std::string source) {
        auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
            runtime.get(), "export function update(value) { " + source + "; return value; }",
            "subject", {}, DynamicValue(0.0f), runtime->hostContext());
        EXPECT_TRUE(program->Valid());
        program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    };

    ASSERT_EQ(material->customShader.constValues.at("u_Fold").size(), 4u);
    EXPECT_FLOAT_EQ(component(0), 1.0f);
    EXPECT_FLOAT_EQ(component(1), -1.0f);
    EXPECT_FLOAT_EQ(component(2), 0.25f);
    EXPECT_FLOAT_EQ(component(3), 10.0f);
    command("thisLayer.getAnimation('fold').play()");
    runtime->Tick(3.0 / 30.0);
    EXPECT_FLOAT_EQ(component(0), 1.5f);
    EXPECT_FLOAT_EQ(component(1), -2.5f);
    EXPECT_FLOAT_EQ(component(2), 0.25f);
    EXPECT_FLOAT_EQ(component(3), 16.0f);
    command("thisLayer.getAnimation('fold').setFrame(6)");
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(component(0), 2.0f);
    EXPECT_FLOAT_EQ(component(1), -4.0f);
    EXPECT_FLOAT_EQ(component(2), 0.25f);
    // The short curve holds its last key instead of restarting on its own.
    EXPECT_FLOAT_EQ(component(3), 16.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ClonedTemplateLayersShareOneTimelineAndKeepEveryBinding) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);

    auto source_node = std::make_shared<SceneNode>(linalg::Vector3f(100.0f, 50.0f, 0.0f),
                                                   linalg::Vector3f::Ones(),
                                                   linalg::Vector3f::Zero(), "source");
    auto source_mesh = std::make_shared<SceneMesh>();
    source_mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(source_mesh);
    scene.sceneGraph->AppendChild(source_node);
    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/workshop/123456/bar.json", source_node,
                                   linalg::Vector2f(20.0f, 10.0f));
    runtime->RegisterMaterialConstant(
        source_mesh->MaterialSlotPtr(), "g_Tint",
        std::make_unique<DynamicValue>(linalg::Vector3f(0.25f, 0.5f, 0.75f)));
    const auto setting = nlohmann::json::parse(R"({
        "value":[0,0.625],
        "animation":{
            "options":{"fps":1,"length":4,"mode":"single","name":"slide"},
            "c0":[{"frame":0,"value":0},{"frame":4,"value":1}]
        }
    })");
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("source", timeline->components[0]);
    runtime->RegisterMaterialConstant(source_mesh->MaterialSlotPtr(), "g_Point",
                                      std::make_unique<DynamicValue>(linalg::Vector2f(0.0f, 0.0f)),
                                      timeline);

    runtime->Tick(2.0);
    ASSERT_FALSE(runtime->CreateLayerFromTemplate("models/bar.json", "source").empty());
    // A clone joins the running timeline; it must not rewind or restart it.
    auto* clock = runtime->FindScalarAnimation("source", "slide");
    ASSERT_NE(clock, nullptr);
    EXPECT_DOUBLE_EQ(clock->frame, 2.0);
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);
    const auto expect_layer = [](SceneNode& node, float slide) {
        ASSERT_NE(node.Mesh(), nullptr);
        ASSERT_NE(node.Mesh()->Material(), nullptr);
        const auto& values = node.Mesh()->Material()->customShader.constValues;
        ASSERT_TRUE(values.contains("g_Tint"));
        ASSERT_EQ(values.at("g_Tint").size(), 3u);
        EXPECT_FLOAT_EQ(values.at("g_Tint")[0], 0.25f);
        EXPECT_FLOAT_EQ(values.at("g_Tint")[2], 0.75f);
        ASSERT_TRUE(values.contains("g_Point"));
        ASSERT_EQ(values.at("g_Point").size(), 2u);
        EXPECT_FLOAT_EQ(values.at("g_Point")[0], slide);
        EXPECT_FLOAT_EQ(values.at("g_Point")[1], 0.625f);
    };
    for (const auto& child : scene.sceneGraph->GetChildren()) expect_layer(*child, 0.5f);
    runtime->Tick(2.0);
    for (const auto& child : scene.sceneGraph->GetChildren()) expect_layer(*child, 1.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// An authored timeline can name frames; the layer's own scripts react to them.
// The handler counts on the marker's scale so a missed or repeated event shows.
nlohmann::json TimelineEventSetting(const char* options) {
    auto setting = nlohmann::json::parse(std::string(R"({
        "value":[0,0],
        "animation":{
            "options":)") + options + R"(,
            "c0":[{"frame":0,"value":0},{"frame":9,"value":1}],
            "c1":[{"frame":0,"value":0},{"frame":9,"value":2}]
        }
    })");
    setting["script"] = R"JS(
let fired = 0;
export function animationEvent(event) {
  if (event.name === 'half') {
    fired += 1;
    thisScene.getLayer('marker').scale = new Vec3(fired, 1, 1);
  }
  if (event.name === 'done') thisScene.getLayer('subject').visible = false;
}
)JS";
    return setting;
}

TEST(ScriptRuntimeCompat, TimelineEventsFireWhenThePlayheadCrossesTheirFrame) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    marker->SetScale(linalg::Vector3f(0.0f, 1.0f, 1.0f));
    const auto setting = TimelineEventSetting(
        R"({"fps":30,"length":9,"mode":"single","startpaused":true,"name":"fold",
            "events":[{"frame":5,"name":"half"},{"frame":9,"name":"done"}]})");
    auto material      = std::make_shared<SceneMaterial>();
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("subject", timeline->components[0]);
    runtime->RegisterMaterialConstant(material, "g_Point",
                                      ResolveVectorSetting(*runtime, setting, 2, "subject"),
                                      timeline);
    const auto command = [&](std::string source) {
        auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
            runtime.get(), "export function update(value) { " + source + "; return value; }",
            "subject", {}, DynamicValue(0.0f), runtime->hostContext());
        EXPECT_TRUE(program->Valid());
        program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    };

    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 0.0f);
    EXPECT_TRUE(subject->Visible());
    command("thisLayer.getAnimation('fold').play()");
    runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 0.0f);
    runtime->Tick(1.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 1.0f);
    EXPECT_TRUE(subject->Visible());
    runtime->Tick(4.0 / 30.0);
    // The last frame of a single timeline still crosses its event.
    EXPECT_FALSE(subject->Visible());
    runtime->Tick(1.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 1.0f);
    // Seeking is an explicit jump, not playback, so it replays nothing.
    command("thisLayer.getAnimation('fold').stop()");
    command("thisLayer.getAnimation('fold').setFrame(9)");
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 1.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, LoopingTimelineEventsFireOncePerLapAndOncePerStall) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    marker->SetScale(linalg::Vector3f(0.0f, 1.0f, 1.0f));
    const auto setting = TimelineEventSetting(
        R"({"fps":30,"length":10,"mode":"loop","name":"fold",
            "events":[{"frame":5,"name":"half"}]})");
    auto material      = std::make_shared<SceneMaterial>();
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("subject", timeline->components[0]);
    runtime->RegisterMaterialConstant(material, "g_Point",
                                      ResolveVectorSetting(*runtime, setting, 2, "subject"),
                                      timeline);

    runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 0.0f);
    runtime->Tick(2.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 1.0f);
    // Wrapping past the end and back over the event counts one more crossing.
    runtime->Tick(10.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 2.0f);
    // A stall longer than the whole loop reports each event once, not per lap.
    runtime->Tick(100.0 / 30.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 3.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// The handler records how many markers it saw, the frame of the last one and
// the sum of all their frames, so a missed, repeated or misordered marker and a
// missing `event.frame` all show up in one Vec3.
nlohmann::json MarkerTallySetting(const char* options) {
    auto setting = nlohmann::json::parse(std::string(R"({
        "value":[0,0],
        "animation":{"options":)") + options + R"(,
            "c0":[{"frame":0,"value":0},{"frame":10,"value":1}],
            "c1":[{"frame":0,"value":0},{"frame":10,"value":2}]}
    })");
    setting["script"] = R"JS(
let seen = 0;
let total = 0;
export function animationEvent(event) {
  seen += 1;
  total += event.frame;
  thisScene.getLayer('marker').scale = new Vec3(seen, event.frame, total);
}
)JS";
    return setting;
}

std::shared_ptr<ScalarAnimationPlayback> AttachMarkerTally(SceneRuntimeContext& runtime,
                                                           const nlohmann::json& setting,
                                                           std::shared_ptr<SceneMaterial> material) {
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime.RegisterScalarAnimation("subject", timeline->components[0]);
    runtime.RegisterMaterialConstant(std::move(material), "g_Point",
                                     ResolveVectorSetting(runtime, setting, 2, "subject"),
                                     timeline);
    return timeline->playback;
}

TEST(ScriptRuntimeCompat, OneTickReportsEveryCrossedMarkerWithItsAuthoredFrame) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    auto playback = AttachMarkerTally(
        *runtime,
        MarkerTallySetting(R"({"fps":1,"length":10,"mode":"single","name":"fold",
            "events":[{"frame":7,"name":"c"},{"frame":2,"name":"a"},{"frame":3,"name":"b"}]})"),
        std::make_shared<SceneMaterial>());

    runtime->Tick(8.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 3.0f);
    // Ascending frame order, so the last marker seen is the furthest one.
    EXPECT_FLOAT_EQ(marker->Scale().y(), 7.0f);
    EXPECT_FLOAT_EQ(marker->Scale().z(), 12.0f);
    EXPECT_DOUBLE_EQ(playback->frame, 8.0);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, LoopMarkersSurviveReverseTravelAndExactWraps) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    auto playback = AttachMarkerTally(
        *runtime,
        MarkerTallySetting(R"({"fps":1,"length":10,"mode":"loop","name":"fold",
            "events":[{"frame":0,"name":"seam"},{"frame":8,"name":"late"}]})"),
        std::make_shared<SceneMaterial>());

    // Running backwards past the seam still meets the late marker on the far
    // side, in the order the playhead reaches them.
    playback->SetFrame(1.0);
    playback->rate = -1.0;
    runtime->Tick(4.0);
    EXPECT_DOUBLE_EQ(playback->frame, 7.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 2.0f);
    EXPECT_FLOAT_EQ(marker->Scale().y(), 8.0f);
    EXPECT_FLOAT_EQ(marker->Scale().z(), 8.0f);

    // Landing exactly on the seam counts as reaching frame 0.
    playback->SetFrame(6.0);
    playback->rate = 1.0;
    runtime->Tick(4.0);
    EXPECT_DOUBLE_EQ(playback->frame, 0.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 4.0f);
    EXPECT_FLOAT_EQ(marker->Scale().y(), 0.0f);
    EXPECT_FLOAT_EQ(marker->Scale().z(), 16.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, TimelineMarkersReachInitializedScriptsOnTheFirstTick) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto subject = std::make_shared<SceneNode>();
    auto marker  = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", subject.get());
    runtime->RegisterNode("marker", marker.get());
    auto setting = nlohmann::json::parse(R"({
        "value":[0,0],
        "animation":{"options":{"fps":1,"length":10,"mode":"single","name":"fold",
                                "events":[{"frame":1,"name":"tick"}]},
                     "c0":[{"frame":0,"value":0},{"frame":10,"value":1}],
                     "c1":[{"frame":0,"value":0},{"frame":10,"value":2}]}
    })");
    // The handler can only report 7 if `init` ran before the marker arrived.
    setting["script"] = R"JS(
let ready;
export function init(value) { ready = 7; return value; }
export function animationEvent(event) {
  thisScene.getLayer('marker').scale = new Vec3(ready === undefined ? -1 : ready, 1, 1);
}
)JS";
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("subject", timeline->components[0]);
    runtime->RegisterMaterialConstant(std::make_shared<SceneMaterial>(), "g_Point",
                                      ResolveVectorSetting(*runtime, setting, 2, "subject"),
                                      timeline);

    runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(marker->Scale().x(), 7.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, GlobalAnimationListenersRunOncePerMarkerWhateverIsBound) {
    for (const int scene_scripts : { 0, 2 }) {
        Scene scene;
        auto  runtime = MakeRuntimeWithScene(scene);
        ASSERT_NE(runtime, nullptr);
        auto subject  = std::make_shared<SceneNode>();
        auto marker   = std::make_shared<SceneNode>();
        auto listener = std::make_shared<SceneNode>();
        runtime->RegisterNode("subject", subject.get());
        runtime->RegisterNode("marker", marker.get());
        runtime->RegisterNode("listener", listener.get());
        // The global list lives on the shared context, so it must run once per
        // marker whether nothing or several scene scripts are bound here.
        runtime->RegisterSceneScript(R"JS(
let heard = 0;
engine.on('animationEvent', function(event) {
  heard += 1;
  thisScene.getLayer('listener').scale = new Vec3(heard, event.frame, 1);
});
function update() {}
)JS",
                                     "elsewhere");
        for (int index = 0; index < scene_scripts; ++index) {
            runtime->RegisterSceneScript(R"JS(
function update() {}
export function animationEvent(event) {
  var layer = thisScene.getLayer('marker');
  layer.scale = new Vec3(layer.scale.x + 1, 1, 1);
}
)JS",
                                         "subject");
        }
        AttachMarkerTally(
            *runtime,
            MarkerTallySetting(R"({"fps":1,"length":10,"mode":"single","name":"fold",
                "events":[{"frame":2,"name":"only"}]})"),
            std::make_shared<SceneMaterial>());

        runtime->Tick(3.0);
        EXPECT_FLOAT_EQ(listener->Scale().x(), 1.0f) << "scene scripts: " << scene_scripts;
        EXPECT_FLOAT_EQ(listener->Scale().y(), 2.0f) << "scene scripts: " << scene_scripts;
        EXPECT_EQ(runtime->scriptErrorCount(), 0u);
    }
}

TEST(ScriptRuntimeCompat, GlobalOnlyAnimationListenerSeesTheCurrentTickTime) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto listener = std::make_shared<SceneNode>();
    runtime->RegisterNode("listener", listener.get());
    // No property script and no layer export: the global listener is the only
    // consumer, so nothing else refreshes `engine` before it runs.
    runtime->RegisterSceneScript(R"JS(
engine.on('animationEvent', function(event) {
  thisScene.getLayer('listener').scale =
      new Vec3(engine.runtime, engine.frametime, event.frame);
});
function update() {}
)JS",
                                 "elsewhere");
    ScalarAnimation clock;
    clock.fps           = 1.0;
    clock.length_frames = 10.0;
    clock.name          = "fold";
    clock.keyframes     = { { .frame = 0.0, .value = 0.0f }, { .frame = 10.0, .value = 1.0f } };
    clock.events        = { { .frame = 1.0, .name = "tick" } };
    runtime->RegisterScalarAnimation("subject", clock);

    runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(listener->Scale().x(), 2.0f);
    EXPECT_FLOAT_EQ(listener->Scale().y(), 2.0f);
    EXPECT_FLOAT_EQ(listener->Scale().z(), 1.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, SceneGetAnimationFindsATimelineOnAnotherLayer) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    ASSERT_NE(runtime, nullptr);
    auto page = std::make_shared<SceneNode>();
    runtime->RegisterNode("page", page.get());
    const auto setting = nlohmann::json::parse(R"({
        "value":[0,0],
        "animation":{"options":{"fps":30,"length":30,"mode":"single","startpaused":true,
                                "name":"111"},
                     "c0":[{"frame":0,"value":0},{"frame":30,"value":1}],
                     "c1":[{"frame":0,"value":0},{"frame":30,"value":2}]}
    })");
    auto timeline      = BuildComponentTimeline(setting, 2);
    timeline->playback = runtime->RegisterScalarAnimation("page", timeline->components[0]);
    auto material      = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(material, "g_Point",
                                      std::make_unique<DynamicValue>(linalg::Vector2f(0.0f, 0.0f)),
                                      timeline);
    auto other = std::make_shared<SceneNode>();
    runtime->RegisterNode("other", other.get());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        "export function update(value) { thisScene.getAnimation('111').play(); return value; }",
        "other", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);

    EXPECT_FALSE(timeline->playback->playing);
    program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    EXPECT_TRUE(timeline->playback->playing);
    runtime->Tick(15.0 / 30.0);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Point")[0], 0.5f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ScalarTimelineUsesBezierTimeHandlesAndExactInitialKey) {
    const auto animation = ResolveScalarAnimation(nlohmann::json::parse(R"({
        "value":9,"animation":{
            "options":{"fps":10,"length":10,"mode":"single"},
            "c0":[
                {"frame":0,"value":0,"front":{"enabled":true,"x":1,"y":0}},
                {"frame":10,"value":1,"back":{"enabled":true,"x":-1,"y":0}}
            ]
        }
    })"));
    ASSERT_TRUE(animation.has_value());
    EXPECT_FLOAT_EQ(animation->Evaluate(0.0), 0.0f);
    // At Bezier parameter 1/4, time is .184375 and value is .15625, not linear.
    EXPECT_NEAR(animation->Evaluate(0.184375), 0.15625f, 1e-6f);
    EXPECT_FLOAT_EQ(animation->Evaluate(1.0), 1.0f);
}

// `wraploop` makes a looping curve come back to where it started: it is cut at
// the timeline's length and closed there with the first key's value. Without it
// the curve holds its last key to the end of the length and jumps back.
TEST(ScriptRuntimeCompat, WrapLoopClosesACurveOnItsFirstKeyAtTheTimelinesLength) {
    const auto resolve = [](bool wrap, const char* keys) {
        return ResolveScalarAnimation(nlohmann::json::parse(
            std::string(R"({"value":0,"animation":{"options":{"fps":10,"length":10,"mode":"loop",)") +
            (wrap ? R"("wraploop":true,)" : R"("wraploop":false,)") + R"("name":"sway"},"c0":)" +
            keys + "}}"));
    };
    const char* const keys = R"([{"frame":0,"value":0},{"frame":5,"value":1}])";

    const auto held = resolve(false, keys);
    ASSERT_TRUE(held.has_value());
    EXPECT_FLOAT_EQ(held->Evaluate(0.75), 1.0f);
    EXPECT_EQ(held->keyframes.size(), 2u);

    const auto closed = resolve(true, keys);
    ASSERT_TRUE(closed.has_value());
    ASSERT_EQ(closed->keyframes.size(), 3u);
    EXPECT_DOUBLE_EQ(closed->keyframes.back().frame, 10.0);
    EXPECT_FLOAT_EQ(closed->keyframes.back().value, 0.0f);
    EXPECT_FLOAT_EQ(closed->Evaluate(0.5), 1.0f);
    EXPECT_FLOAT_EQ(closed->Evaluate(0.75), 0.5f);
    EXPECT_FLOAT_EQ(closed->Evaluate(0.99), 0.02f);
    // The lap after the first one starts from the same value it ended on.
    EXPECT_FLOAT_EQ(closed->Evaluate(1.0), 0.0f);
    EXPECT_FLOAT_EQ(closed->Evaluate(1.25), 0.5f);

    // A last key on the length gives its value back too; keys past the length
    // are cut, but never down to fewer than two.
    const auto landed = resolve(true, R"([{"frame":0,"value":2},{"frame":10,"value":9}])");
    ASSERT_TRUE(landed.has_value());
    ASSERT_EQ(landed->keyframes.size(), 2u);
    EXPECT_FLOAT_EQ(landed->keyframes.back().value, 2.0f);
    const auto cut = resolve(true, R"([{"frame":0,"value":2},{"frame":5,"value":4},{"frame":12,"value":9}])");
    ASSERT_TRUE(cut.has_value());
    ASSERT_EQ(cut->keyframes.size(), 3u);
    EXPECT_FLOAT_EQ(cut->keyframes.back().value, 2.0f);
    EXPECT_FLOAT_EQ(cut->Evaluate(0.75), 3.0f);
    const auto single = resolve(true, R"([{"frame":0,"value":2}])");
    ASSERT_TRUE(single.has_value());
    EXPECT_EQ(single->keyframes.size(), 1u);
}

// The seam is as smooth as the start of the curve: the closing key's incoming
// handle mirrors the first key's outgoing one.
TEST(ScriptRuntimeCompat, WrapLoopSeamMirrorsTheFirstKeysHandle) {
    const auto animation = ResolveScalarAnimation(nlohmann::json::parse(R"({
        "value":0,"animation":{
            "options":{"fps":10,"length":10,"mode":"loop","wraploop":true},
            "c0":[
                {"frame":0,"value":0,"front":{"enabled":true,"x":2,"y":1}},
                {"frame":5,"value":3}
            ]
        }
    })"));
    ASSERT_TRUE(animation.has_value());
    ASSERT_EQ(animation->keyframes.size(), 3u);
    const auto& closing = animation->keyframes.back();
    EXPECT_TRUE(closing.back.enabled);
    EXPECT_DOUBLE_EQ(closing.back.x, -2.0);
    EXPECT_DOUBLE_EQ(closing.back.y, -1.0);
    const auto plain = ResolveScalarAnimation(nlohmann::json::parse(R"({
        "value":0,"animation":{
            "options":{"fps":10,"length":10,"mode":"loop","wraploop":true},
            "c0":[{"frame":0,"value":0},{"frame":5,"value":3}]
        }
    })"));
    ASSERT_TRUE(plain.has_value());
    EXPECT_FALSE(plain->keyframes.back().back.enabled);
}

TEST(ScriptRuntimeCompat, AuthoredColorPropertiesStayVectorsAcrossTicksAndPropertyChanges) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"tint", RuntimeScalarValue::String("0.2 0.4 0.8")}},
    });
    ASSERT_NE(runtime, nullptr);
    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(material, "g_Tint", ResolveVec3Setting(*runtime, {
        {"value", {1.0f, 1.0f, 1.0f}},
        {"scriptproperties", {
            {"tint", {{"value", "0.2 0.4 0.8"}, {"user", "tint"}}},
            {"caption", "0.1 0.2 0.3"},
        }},
        {"script", R"JS(
export var scriptProperties = createScriptProperties()
    .addColor({name: 'tint', value: new Vec3(1)})
    .addColor({name: 'multiplier', value: new Vec3(2)})
    .addText({name: 'caption', value: ''}).finish();
export function update(value) {
    if (typeof scriptProperties.caption !== 'string') throw new Error('text was coerced');
    return scriptProperties.tint.multiply(scriptProperties.multiplier);
}
)JS"},
    }));
    const auto expect_tint = [&](float r, float g, float b) {
        for (int frame = 0; frame < 3; ++frame) {
            runtime->Tick(1.0 / 60.0);
            const auto& tint = material->customShader.constValues.at("g_Tint");
            ASSERT_EQ(tint.size(), 3u);
            EXPECT_FLOAT_EQ(tint[0], r);
            EXPECT_FLOAT_EQ(tint[1], g);
            EXPECT_FLOAT_EQ(tint[2], b);
        }
    };
    expect_tint(0.4f, 0.8f, 1.6f);
    runtime->ApplyProjectPropertyOverride({{"tint", RuntimeScalarValue::String("0.6 0.3 0.1")}});
    expect_tint(1.2f, 0.6f, 0.2f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A layer's saved and user-bound values reach its script after the module has
// run, as in Wallpaper Engine: top-level code reads the declared default, init
// and update read the value. A switch whose position slider moves its layers by
// the difference from the top-level reading stayed where it was authored when
// the module already saw the final value.
TEST(ScriptRuntimeCompat, ModuleCodeSeesDeclaredDefaultsAndInitSeesTheBoundValue) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"offset", RuntimeScalarValue::Float(1346.0f)}},
    });
    ASSERT_NE(runtime, nullptr);
    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(material, "g_Offset", ResolveVec3Setting(*runtime, {
        {"value", {0.0f, 0.0f, 0.0f}},
        {"scriptproperties", {{"offset", {{"value", 0}, {"user", "offset"}}}}},
        {"script", R"JS(
export var scriptProperties = createScriptProperties()
    .addSlider({name: 'offset', value: 7, min: -4000, max: 4000}).finish();
const atLoad = scriptProperties.offset;
let atInit;
export function init() { atInit = scriptProperties.offset; }
export function update(value) {
    return new Vec3(atLoad, atInit, scriptProperties.offset);
}
)JS"},
    }));
    const auto expect_offset = [&](float load, float init, float now) {
        runtime->Tick(1.0 / 60.0);
        const auto& offset = material->customShader.constValues.at("g_Offset");
        ASSERT_EQ(offset.size(), 3u);
        EXPECT_FLOAT_EQ(offset[0], load);
        EXPECT_FLOAT_EQ(offset[1], init);
        EXPECT_FLOAT_EQ(offset[2], now);
    };
    expect_offset(7.0f, 1346.0f, 1346.0f);
    runtime->ApplyProjectPropertyOverride({{"offset", RuntimeScalarValue::Float(20.0f)}});
    expect_offset(7.0f, 1346.0f, 20.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, VisibleOnlyBindingIgnoresObjectReturn) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {
            { "visible", RuntimeScalarValue::Bool(false) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNodeVisibility(
        "probe",
        node.get(),
        ResolveBoolSetting(
            *runtime,
            nlohmann::json {
                { "script", "export function update(value) { return { x: 1 }; }" },
                { "user", "visible" },
                { "value", true },
            },
            "probe"));

    runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(runtime->NodeVisible("probe"));
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A flag reads a string as it reads a combo's choice: `true` in any case or `1` is
// on, every other string is off. A script that returns the string is read the same
// way on every tick it runs.
TEST(ScriptRuntimeCompat, AVisibleScriptThatReturnsAStringIsReadAsAFlag) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    struct Case {
        const char* name;
        const char* returned;
        bool        visible;
    };
    const Case cases[] = {
        { "one", "1", true },
        { "lower", "true", true },
        { "upper", "TRUE", true },
        { "zero", "0", false },
        { "word", "false", false },
        { "other", "maybe", false },
        { "empty", "", false },
    };
    std::vector<std::shared_ptr<SceneNode>> nodes;
    for (const auto& item : cases) {
        auto node = std::make_shared<SceneNode>();
        runtime->RegisterNodeVisibility(
            item.name,
            node.get(),
            ResolveBoolSetting(
                *runtime,
                nlohmann::json {
                    { "script", std::string("export function update(value) { return '") +
                                    item.returned + "'; }" },
                    { "value", false },
                },
                item.name));
        nodes.push_back(std::move(node));
    }

    runtime->Tick(1.0 / 60.0);
    runtime->Tick(1.0 / 60.0);
    for (const auto& item : cases) {
        EXPECT_EQ(runtime->NodeVisible(item.name), item.visible) << "returned '" << item.returned << "'";
    }
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ScriptPropertiesUseUserPropertyWrites) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .canvas_width  = 1000,
        .canvas_height = 500,
        .project_properties = {
            { "x", RuntimeScalarValue::Float(0.8f) },
        },
    });
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("probe", node.get());
    runtime->RegisterNodeTranslate(
        "probe",
        node.get(),
        ResolveVec3Setting(
            *runtime,
            nlohmann::json {
                {
                    "script",
                    R"JS(
export var scriptProperties = createScriptProperties()
  .addSlider({ name: 'x', value: 0.5 })
  .finish();
export function update(value) {
  value.x = scriptProperties.x * engine.canvasSize.x;
  return value;
}
)JS",
                },
                { "scriptproperties", { { "x", { { "user", "x" }, { "value", 0.5f } } } } },
                { "value", "0 0 0" },
            },
            "probe"));

    runtime->Tick(1.0 / 60.0);
    EXPECT_FLOAT_EQ(runtime->NodeTranslate("probe").x(), 800.0f);

    runtime->ApplyProjectPropertyOverride({
        { "x", RuntimeScalarValue::Float(0.25f) },
    });
    runtime->Tick(1.0 / 60.0);
    EXPECT_FLOAT_EQ(runtime->NodeTranslate("probe").x(), 250.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(AudioResponseCompat, RegisteredBuffersSupportTypedViewsAndClearWhenDisabled) {
    audio::ResetAudioResponseServiceForTesting();
    // A bass tone: the lowest of 16 bands spans roughly 20 to 120 Hz.
    std::array<float, audio::kAudioResponseWindowFrames> samples {};
    for (std::size_t index = 0; index < samples.size(); ++index) {
        samples[index] = 0.025f * std::sin(2.0 * 3.141592653589793 * 70.0 * index /
                                           audio::kAudioResponseSampleRate);
    }
    std::string error;
    ASSERT_TRUE(audio::SubmitMonoAudioFrames(
        audio::kAudioResponseSampleRate, samples.size(), samples.data(), &error))
        << error;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (audio::CurrentAudioSpectrumSnapshot().generation == 0 &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_GT(audio::CurrentAudioSpectrumSnapshot().generation, 0u);

    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->SetAudioResponseEnabled(true);
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(),
                                                                       R"JS(
const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
const bass = audio.average.subarray(0, 1);
export function update(value) {
    return bass[0];
}
)JS",
                                                                       "",
                                                                       {},
                                                                       DynamicValue(0.0f),
                                                                       runtime->hostContext());
    ASSERT_TRUE(program->Valid());
    const auto active = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(active, nullptr);
    EXPECT_GT(active->getFloat(), 0.05f);
    runtime->SetAudioResponseEnabled(false);
    const auto disabled = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(disabled, nullptr);
    EXPECT_FLOAT_EQ(disabled->getFloat(), 0.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(AudioResponseCompat, NativeRegistrationsKeepTypedViewsAndRefreshLateBuffersAtTheSameGeneration) {
    struct ResetAudioOnExit {
        ~ResetAudioOnExit() { audio::ResetAudioResponseServiceForTesting(); }
    } reset;
    audio::AudioSpectrumSnapshot snapshot;
    snapshot.generation = 29;
    snapshot.left16.fill(0.125f); snapshot.right16.fill(0.25f); snapshot.average16.fill(0.375f);
    snapshot.left32.fill(0.25f); snapshot.right32.fill(0.375f); snapshot.average32.fill(0.5f);
    snapshot.left64.fill(0.375f); snapshot.right64.fill(0.5f); snapshot.average64.fill(0.625f);
    audio::SetAudioSpectrumSnapshotForTesting(snapshot);
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    runtime->SetAudioResponseEnabled(true);
    for (const auto [resolution, expected] : {
        std::pair {16, linalg::Vector3f(0.125f, 0.25f, 0.375f)},
        std::pair {32, linalg::Vector3f(0.25f, 0.375f, 0.5f)},
        std::pair {64, linalg::Vector3f(0.375f, 0.5f, 0.625f)} }) {
        const auto size = std::to_string(resolution);
        auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(),
            "const b=engine.registerAudioBuffers(" + size + ");const held=b.average.subarray(" +
            std::to_string(resolution - 1) + "); export function update(){return new Vec3(b.left[" +
            std::to_string(resolution - 1) + "],b.right[" + std::to_string(resolution - 1) + "],held[0]);}",
            "", {}, DynamicValue(linalg::Vector3f::Zero().eval()), runtime->hostContext());
        ASSERT_TRUE(program->Valid());
        const auto value = program->Evaluate(runtime->hostContext(), DynamicValue(linalg::Vector3f::Zero().eval()));
        ASSERT_NE(value, nullptr);
        EXPECT_TRUE(value->getVec3().isApprox(expected));
    }
    auto late = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
let b;
export function update() {
    if (!b) { b = engine.registerAudioBuffers(64); return -1; }
    return b.average[63];
}
)JS", "", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_TRUE(late->Valid());
    const auto registered = late->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(registered, nullptr);
    EXPECT_FLOAT_EQ(registered->getFloat(), -1.0f);
    const auto refreshed = late->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(refreshed, nullptr);
    EXPECT_FLOAT_EQ(refreshed->getFloat(), 0.625f);
    runtime->SetAudioResponseEnabled(false);
    const auto disabled = late->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(disabled, nullptr);
    EXPECT_FLOAT_EQ(disabled->getFloat(), 0.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(AudioResponseCompat, ResolutionConversionExceptionIsReturnedToTheCaller) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function update() {
    try { engine.registerAudioBuffers({valueOf() { throw new Error('conversion'); }}); }
    catch (error) { return 1; }
    return 0;
}
)JS", "", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_TRUE(program->Valid());
    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 1.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(AudioResponseCompat, ASceneWhoseLayersAllRegisterBuffersKeepsEveryRegistration) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function update() {
    var last;
    for (var i = 0; i < 200; ++i) last = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
    return last.left.length;
}
)JS", "", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_TRUE(program->Valid());
    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 16.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, InitAndUpdateEachReceiveTheirOwnCopyOfTheValue) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function init(value) { value.y = 90; return value; }
export function update(value) { return value; }
)JS", "", {}, DynamicValue(linalg::Vector3f(1, 2, 3)), runtime->hostContext());
    ASSERT_TRUE(program->Valid());
    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(linalg::Vector3f(1, 2, 3)));
    ASSERT_NE(result, nullptr);
    EXPECT_TRUE(result->getVec3().isApprox(linalg::Vector3f(1, 2, 3)));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ShaderValuePacking, FixedMatricesAndExpressionsPreserveColumnMajorValues) {
    linalg::Matrix4d matrix;
    matrix << 1, 2, 0, 4,
              0, 2, 1, 3,
              0, 0, 4, 2,
              0, 0, 0, 1;
    const std::array<float, 16> expected_matrix {
        1, 0, 0, 0,
        2, 2, 0, 0,
        0, 1, 4, 0,
        4, 3, 2, 1,
    };
    const std::array<float, 16> expected_inverse {
        1, 0, 0, 0,
        -1, 0.5f, 0, 0,
        0.25f, -0.125f, 0.25f, 0,
        -1.5f, -1.25f, -0.5f, 1,
    };
    const std::array<float, 16> expected_product {
        21, 16, 8, 4,
        16, 14, 10, 3,
        8, 10, 20, 2,
        4, 3, 2, 1,
    };
    const auto expect_packed = [](const char* context, const ShaderValue& actual,
                                  const std::array<float, 16>& expected) {
        SCOPED_TRACE(context);
        ASSERT_EQ(actual.size(), expected.size());
        for (std::size_t i = 0; i < expected.size(); ++i) {
            EXPECT_FLOAT_EQ(actual[i], expected[i]) << "coefficient " << i;
        }
    };
    expect_packed("fixed double", ShaderValue::fromMatrix(matrix), expected_matrix);
    expect_packed("inverse", ShaderValue::fromMatrix(matrix.inverse()), expected_inverse);
    expect_packed("product", ShaderValue::fromMatrix(matrix * matrix.transpose()), expected_product);

    const linalg::Matrix<float, 4, 4> float_matrix = matrix.cast<float>();
    expect_packed("fixed float", ShaderValue::fromMatrix(float_matrix), expected_matrix);
    const linalg::Matrix<double, 4, 4, linalg::RowMajor> row_major = matrix;
    expect_packed("row major", ShaderValue::fromMatrix(row_major), expected_matrix);
    linalg::Matrix<double, 6, 7> padded = linalg::Matrix<double, 6, 7>::Constant(-99.0);
    padded.block<4, 4>(1, 2) = matrix;
    expect_packed("strided block", ShaderValue::fromMatrix(padded.block<4, 4>(1, 2)),
                  expected_matrix);
}

TEST(ShaderValuePacking, PackedValuesOwnTheirStorageAcrossInputChanges) {
    const auto packed = [] {
        linalg::Matrix4d inline_matrix;
        linalg::Matrix<double, 5, 5> large_matrix;
        linalg::Matrix<double, 1, 1> single_matrix;
        single_matrix(0, 0) = 0.7;
        for (linalg::Index column = 0; column < inline_matrix.cols(); ++column) {
            for (linalg::Index row = 0; row < inline_matrix.rows(); ++row) {
                inline_matrix(row, column) = (10 * column + row + 1) / 10.0;
            }
        }
        for (linalg::Index column = 0; column < large_matrix.cols(); ++column) {
            for (linalg::Index row = 0; row < large_matrix.rows(); ++row) {
                large_matrix(row, column) = (10 * column + row + 1) / 10.0;
            }
        }
        std::array<ShaderValue, 3> values {
            ShaderValue::fromMatrix(inline_matrix),
            ShaderValue::fromMatrix(large_matrix),
            ShaderValue::fromMatrix(single_matrix),
        };
        inline_matrix.setConstant(-99.0);
        large_matrix.setConstant(-99.0);
        single_matrix.setConstant(-99.0);
        return values;
    }();

    const std::array<float, 16> expected_inline {
        0.1f, 0.2f, 0.3f, 0.4f,
        1.1f, 1.2f, 1.3f, 1.4f,
        2.1f, 2.2f, 2.3f, 2.4f,
        3.1f, 3.2f, 3.3f, 3.4f,
    };
    const std::array<float, 25> expected_large {
        0.1f, 0.2f, 0.3f, 0.4f, 0.5f,
        1.1f, 1.2f, 1.3f, 1.4f, 1.5f,
        2.1f, 2.2f, 2.3f, 2.4f, 2.5f,
        3.1f, 3.2f, 3.3f, 3.4f, 3.5f,
        4.1f, 4.2f, 4.3f, 4.4f, 4.5f,
    };
    ASSERT_EQ(packed[0].size(), expected_inline.size());
    for (std::size_t i = 0; i < expected_inline.size(); ++i) {
        EXPECT_FLOAT_EQ(packed[0][i], expected_inline[i]) << "inline coefficient " << i;
    }
    ASSERT_EQ(packed[1].size(), expected_large.size());
    for (std::size_t i = 0; i < expected_large.size(); ++i) {
        EXPECT_FLOAT_EQ(packed[1][i], expected_large[i]) << "dynamic coefficient " << i;
    }
    ASSERT_EQ(packed[2].size(), 1u);
    EXPECT_FLOAT_EQ(packed[2][0], 0.7f) << "single coefficient";
}

TEST(ShaderValueUpdaterCompat, FourLightColorsRoundTripThroughPackedUniforms) {
    Scene scene;
    auto camera = std::make_shared<SceneCamera>(384, 256, -1.f, 1.f);
    scene.activeCamera = camera.get();
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_LightsPosition" || name == "g_LightsColorPremultiplied";
    });
    // Different channels expose transposition as well as the lost fourth light;
    // five lights must leave the shader's bounded four-light input unchanged.
    for (size_t count = 0; count <= 5; ++count) {
        SCOPED_TRACE(count);
        if (count > 0) {
            const float n = static_cast<float>(count);
            auto light = std::make_unique<SceneLight>(linalg::Vector3f(n, n + 1, n + 2), 2.f, 0.5f);
            auto transform = std::make_shared<SceneNode>();
            transform->SetTranslate(linalg::Vector3f(n * 10, n * 20, n * 30));
            light->setNode(transform);
            scene.lights.push_back(std::move(light));
        }
        sprite_map_t sprites;
        std::unordered_map<std::string, ShaderValue> values;
        updater.UpdateUniforms(node.get(), sprites, [&](std::string_view name, const ShaderValue& value) {
            values.emplace(std::string(name), value);
        });
        const auto& colors = values.at("g_LightsColorPremultiplied");
        const auto& positions = values.at("g_LightsPosition");
        ASSERT_EQ(colors.size(), 12u);
        ASSERT_EQ(positions.size(), 16u);
        for (size_t light = 0; light < 4; ++light) {
            for (size_t channel = 0; channel < 3; ++channel) {
                const size_t index = light < 3 ? light * 4 + channel : channel * 4 + 3;
                EXPECT_FLOAT_EQ(colors[index], light < count ? 2.f * (light + 1 + channel) : 0.f);
                EXPECT_FLOAT_EQ(positions[light * 4 + channel],
                                light < count ? 10.f * (light + 1) * (channel + 1) : 0.f);
            }
        }
    }
    // Fewer lights on the next draw must clear the packed fourth-light lanes.
    scene.lights.clear();
    sprite_map_t sprites;
    updater.UpdateUniforms(node.get(), sprites, [](std::string_view name, const ShaderValue& value) {
        if (name == "g_LightsColorPremultiplied")
            for (size_t i = 0; i < value.size(); ++i) EXPECT_FLOAT_EQ(value[i], 0.f);
    });
    scene.activeCamera = nullptr;
}

// Camera parallax moves a layer by the cursor and the layer's depth alone. With
// the cursor centred every layer rests where it was authored; offsetting a deep
// layer by its distance from the camera as well pushed a planet near the top of
// a 4K canvas out of the frame. Away from the centre, layers of one depth move
// together wherever they sit, nested in a group or not, and depth scales it.
TEST(ShaderValueUpdaterCompat, DayTimeUniformFollowsLocalClockAndWrapsAtMidnight) {
    Scene scene;
    auto camera = std::make_shared<SceneCamera>(32, 32, -1.0f, 1.0f);
    scene.cameras["clock"] = camera;
    scene.activeCamera = camera.get();
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    std::tm local {};
    local.tm_year = 126;
    local.tm_mon = 0;
    local.tm_mday = 2;
    local.tm_hour = 12;
    local.tm_isdst = -1;
    auto now = std::chrono::system_clock::from_time_t(std::mktime(&local));
    WPShaderValueUpdater updater(&scene, [&] { return now; });
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_DayTime" || name == "g_Daytime";
    });
    sprite_map_t sprites;
    const auto sample = [&] {
        updater.FrameBegin();
        std::map<std::string, float> values;
        updater.UpdateUniforms(node.get(), sprites, [&](std::string_view name, const ShaderValue& value) {
            values[std::string(name)] = value[0];
        });
        EXPECT_EQ(values.at("g_DayTime"), values.at("g_Daytime"));
        return values.at("g_DayTime");
    };
    EXPECT_FLOAT_EQ(sample(), 0.5f);
    now += std::chrono::hours(12) - std::chrono::seconds(1);
    EXPECT_NEAR(sample(), 86399.0 / 86400.0, 1e-7);
    now += std::chrono::seconds(1);
    EXPECT_FLOAT_EQ(sample(), 0.0f);
    EXPECT_NE(updater.FrameVaryingUniforms(node.get(), 0, "") & frame_varying_uniform::kDayTime, 0u);
}

// Wallpaper Engine moves every layer tree in a 2D scene by its outermost
// layer's distance from the eased cursor point, times that layer's depth and
// the scene's amount. The point rests at the centre of the view, so with the
// cursor centred a layer off the centre is pushed further out; a cursor away
// from the centre then moves every tree alike, by its depth.
TEST(ShaderValueUpdaterCompat, CameraParallaxMovesEachLayerTreeByItsRootsDistanceFromTheCursor) {
    Scene scene;
    scene.ortho[0] = 3840;
    scene.ortho[1] = 2160;
    scene.sceneGraph = std::make_shared<SceneNode>();
    auto camera      = std::make_shared<SceneCamera>(3840, 2160, -1.0f, 1.0f);
    auto camera_node = std::make_shared<SceneNode>();
    camera_node->SetTranslate(linalg::Vector3f(1920, 1080, 0));
    camera->AttatchNode(camera_node);
    scene.activeCamera = camera.get();

    const auto layer = [] {
        auto node = std::make_shared<SceneNode>();
        auto mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(SceneMaterial {});
        node->AddMesh(mesh);
        return node;
    };
    WPShaderValueUpdater updater(&scene);
    updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.5f,
                                .mouseinfluence = 0.5f, .canvas_scene = true });
    // How far the drawn layer sits from where its node places it.
    const auto displacement = [&](SceneNode& node, float depth, SceneNode* anchor = nullptr) {
        WPShaderValueData data;
        data.parallaxDepth  = { depth, depth };
        data.parallax_layer = anchor;
        updater.SetNodeData(&node, data);
        updater.InitUniforms(&node, [](std::string_view name) { return name == "g_ModelMatrix"; });
        sprite_map_t sprites;
        ShaderValue  value;
        updater.UpdateUniforms(&node, sprites, [&](std::string_view name, const ShaderValue& v) {
            if (name == "g_ModelMatrix") value = v;
        });
        node.UpdateTrans();
        const auto model = node.ModelTrans();
        return linalg::Vector2f(value[12] - static_cast<float>(model(0, 3)),
                               value[13] - static_cast<float>(model(1, 3)));
    };

    auto planet = layer();
    planet->SetTranslate(linalg::Vector3f(1907, 2647, 0));
    scene.sceneGraph->AppendChild(planet);
    auto group = std::make_shared<SceneNode>();
    group->SetTranslate(linalg::Vector3f(1000, 500, 0));
    scene.sceneGraph->AppendChild(group);
    auto nested = layer();
    nested->SetTranslate(linalg::Vector3f(500, 200, 0));
    group->AppendChild(nested);
    auto centred = layer();
    centred->SetTranslate(linalg::Vector3f(1920, 1080, 0));
    scene.sceneGraph->AppendChild(centred);
    // An effect pass of the planet: a node of its own, outside the tree.
    auto planet_effect = layer();

    // At rest: (origin - view centre) * amount * depth, the root's origin for
    // the whole tree.
    const linalg::Vector2f planet_rest = displacement(*planet, 0.5f);
    EXPECT_LT((planet_rest - linalg::Vector2f(-3.25f, 391.75f)).norm(), 1e-2f);
    EXPECT_LT((displacement(*nested, 0.5f) - linalg::Vector2f(-230.0f, -145.0f)).norm(), 1e-2f)
        << "a nested layer is not anchored at its outermost layer";
    EXPECT_LT((displacement(*planet_effect, 0.5f, planet.get()) - planet_rest).norm(), 1e-2f)
        << "an effect pass is not anchored at its layer";
    EXPECT_LT(displacement(*centred, 0.5f).norm(), 1e-3f) << "a centred layer left its place";

    updater.MouseInput(1.0, 0.0);
    scene.frameTime = 10.0; // long enough for the eased cursor to arrive
    updater.FrameBegin();
    const linalg::Vector2f moved = displacement(*centred, 0.5f);
    EXPECT_GT(moved.norm(), 1.0f) << "a cursor away from the centre must move the layer";
    EXPECT_LT((displacement(*planet, 0.5f) - planet_rest - moved).norm(), 1e-2f);
    EXPECT_LT((displacement(*centred, 1.0f) - 2.0f * moved).norm(), 1e-3f);
    EXPECT_LT(displacement(*planet, 0.0f).norm(), 1e-3f) << "depth zero stays put";
}

// A parallax delay of zero is authored as "no smoothing": the cursor is
// followed at once. Dividing the elapsed time by it made the smoothed cursor
// NaN, which reached every parallax layer's model matrix, so a scene drew only
// its clear colour.
TEST(ShaderValueUpdaterCompat, ZeroParallaxDelayFollowsTheCursorAtOnce) {
    Scene scene;
    scene.ortho[0] = 1920;
    scene.ortho[1] = 1080;
    auto camera      = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    auto camera_node = std::make_shared<SceneNode>();
    camera_node->SetTranslate(linalg::Vector3f(960, 540, 0));
    camera->AttatchNode(camera_node);
    scene.activeCamera = camera.get();

    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    node->SetTranslate(linalg::Vector3f(960, 540, 0));

    WPShaderValueUpdater updater(&scene);
    WPShaderValueData    data;
    data.parallaxDepth = { 1.0f, 1.0f };
    updater.SetNodeData(node.get(), data);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_ModelMatrix" || name == "g_PointerPosition";
    });
    const auto uniforms = [&] {
        std::map<std::string, ShaderValue, std::less<>> values;
        sprite_map_t                                    sprites;
        updater.UpdateUniforms(node.get(), sprites,
                               [&](std::string_view name, const ShaderValue& v) {
                                   values[std::string(name)] = v;
                               });
        return values;
    };

    updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.0f,
                                .mouseinfluence = 0.5f });
    scene.frameTime = 1.0 / 60.0;
    updater.FrameBegin();
    auto values = uniforms();
    ASSERT_TRUE(values.contains("g_ModelMatrix"));
    for (std::size_t i = 0; i < 16; ++i) {
        ASSERT_TRUE(std::isfinite(values["g_ModelMatrix"][i])) << "model matrix element " << i;
    }

    updater.MouseInput(0.25, 0.75);
    updater.FrameBegin();
    values = uniforms();
    ASSERT_TRUE(values.contains("g_PointerPosition"));
    EXPECT_FLOAT_EQ(values["g_PointerPosition"][0], 0.25f) << "no delay, no smoothing";
    EXPECT_FLOAT_EQ(values["g_PointerPosition"][1], 0.75f);
    for (std::size_t i = 0; i < 16; ++i) {
        ASSERT_TRUE(std::isfinite(values["g_ModelMatrix"][i])) << "model matrix element " << i;
    }
    node->UpdateTrans();
    const auto model = node->ModelTrans();
    EXPECT_GT(std::abs(values["g_ModelMatrix"][12] - static_cast<float>(model(0, 3))), 1.0f)
        << "an off-centre cursor must still move a parallax layer";
}

// Wallpaper Engine eases only parallax: each frame it closes
// (1 - delay / 3) * 10 * frametime of the way to the cursor, while shaders read
// the cursor itself. A delay of 1.5 at 60 FPS closes a twelfth per frame.
TEST(ShaderValueUpdaterCompat, ParallaxEasesAsWallpaperEngineWhileShadersSeeTheCursor) {
    Scene scene;
    auto  camera       = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    scene.activeCamera = camera.get();
    auto node          = std::make_shared<SceneNode>();
    auto mesh          = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_PointerPosition" || name == "g_ParallaxPosition";
    });
    updater.SetCameraParallax({ .enable = true, .amount = 1.0f, .delay = 1.5f,
                                .mouseinfluence = 1.0f });
    scene.frameTime = 1.0 / 60.0;
    const auto frame = [&] {
        updater.FrameBegin();
        std::map<std::string, ShaderValue, std::less<>> values;
        sprite_map_t                                    sprites;
        updater.UpdateUniforms(node.get(), sprites,
                               [&](std::string_view name, const ShaderValue& v) {
                                   values[std::string(name)] = v;
                               });
        return values;
    };
    updater.MouseInput(1.0, 0.5);
    auto values = frame();
    EXPECT_FLOAT_EQ(values["g_PointerPosition"][0], 1.0f) << "shaders see the cursor at once";
    const float step = (1.0f - 1.5f / 3.0f) * 10.0f / 60.0f;
    EXPECT_NEAR(values["g_ParallaxPosition"][0], 0.5f + 0.5f * step, 1e-5f);
    values = frame();
    EXPECT_NEAR(values["g_ParallaxPosition"][0],
                1.0f - 0.5f * (1.0f - step) * (1.0f - step), 1e-5f);
    // A cursor outside the window is followed only to its edge.
    updater.MouseInput(3.0, 0.5);
    scene.frameTime = 10.0;
    values = frame();
    EXPECT_FLOAT_EQ(values["g_ParallaxPosition"][0], 1.0f);
}

// Camera parallax moves a layer through its model matrix, which neither the
// uniforms its shader declares nor the node transform the static cache hashes
// reveal. Such a pass has to be reported as following the cursor, or it is
// reused while the cursor moves and a still scene never wakes for it. The
// camera the pass draws through decides: the effect camera and a layer-local
// one, which draws a layer into a composite another layer samples, move nothing.
TEST(ShaderValueUpdaterCompat, ParallaxLayersAreReportedAsFollowingTheCursor) {
    Scene scene;
    scene.ortho[0] = 1920;
    scene.ortho[1] = 1080;
    auto camera        = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    scene.activeCamera = camera.get();
    scene.cameras["effect"] = std::make_shared<SceneCamera>(64, 32, -1.0f, 1.0f);
    auto composite = std::make_shared<SceneCamera>(64, 32, -1.0f, 1.0f);
    composite->SetLayerLocal(true);
    scene.cameras["composite"] = composite;
    WPShaderValueUpdater updater(&scene);
    updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.5f,
                                .mouseinfluence = 0.5f });

    std::vector<std::shared_ptr<SceneNode>> nodes;
    const auto layer = [&](float depth, const char* camera_name) {
        auto node = std::make_shared<SceneNode>();
        auto mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(SceneMaterial {});
        node->AddMesh(mesh);
        node->SetCamera(camera_name);
        WPShaderValueData data;
        data.parallaxDepth = { depth, depth };
        updater.SetNodeData(node.get(), data);
        updater.InitUniforms(node.get(), [](std::string_view name) {
            return name == "g_ModelViewProjectionMatrix";
        });
        nodes.push_back(node);
        return node.get();
    };
    const auto follows_cursor = [&](SceneNode* node, const std::string& camera_override) {
        return (updater.FrameVaryingUniforms(node, 0, camera_override) &
                frame_varying_uniform::kParallax) != 0;
    };

    auto* deep   = layer(0.5f, "");
    auto* flat   = layer(0.0f, "");
    auto* effect = layer(0.5f, "effect");
    EXPECT_TRUE(follows_cursor(deep, ""));
    EXPECT_FALSE(follows_cursor(flat, "")) << "depth zero never moves";
    EXPECT_FALSE(follows_cursor(effect, "")) << "effect passes draw through the effect camera";
    EXPECT_FALSE(follows_cursor(deep, "composite"))
        << "drawn into its composite through a layer-local camera, the layer does not move";

    updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.5f,
                                .mouseinfluence = 0.0f });
    EXPECT_FALSE(follows_cursor(deep, "")) << "without mouse influence the cursor moves nothing";
}

TEST(ShaderValueUpdaterCompat, EffectMatricesRetainOwnerScaleAndMapQuadToLayer) {
    Scene scene;
    auto camera = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    scene.activeCamera = camera.get();
    scene.cameras["effect"] = std::make_shared<SceneCamera>(2, 2, -1.0f, 1.0f);
    SceneNode owner;
    owner.SetScale(linalg::Vector3f(0.8f, 0.6f, 1.0f));
    owner.SetTranslate(linalg::Vector3f(100.0f, 200.0f, 0.0f));
    owner.UpdateTrans();
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    node->SetCamera("effect");
    WPShaderValueData data;
    data.effect_owner = &owner;
    data.effect_extent = linalg::Vector2f(280, 300);
    WPShaderValueUpdater updater(&scene);
    updater.SetNodeData(node.get(), data);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_LayerModelMatrix" || name == "g_EffectModelViewProjectionMatrix";
    });
    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> values;
    auto capture = [&](std::string_view name, const ShaderValue& value) {
        values[std::string(name)] = value;
    };
    updater.UpdateUniforms(node.get(), sprites, capture);
    ASSERT_TRUE(values.contains("g_LayerModelMatrix"));
    EXPECT_NEAR(values.at("g_LayerModelMatrix")[0], 0.8f, 1e-6f);
    linalg::Matrix4d extent = linalg::Matrix4d::Identity();
    extent(0, 0) = 140;
    extent(1, 1) = 150;
    const linalg::Matrix4d expected = camera->GetViewProjectionMatrix() * owner.ModelTrans() * extent;
    for (int i = 0; i < 16; ++i)
        EXPECT_NEAR(values.at("g_EffectModelViewProjectionMatrix")[i], expected.data()[i], 1e-5);
    node->SetCamera("");
    updater.UpdateUniforms(node.get(), sprites, capture);
    const linalg::Matrix4d final_expected = camera->GetViewProjectionMatrix() * owner.ModelTrans();
    for (int i = 0; i < 16; ++i)
        EXPECT_NEAR(values.at("g_EffectModelViewProjectionMatrix")[i], final_expected.data()[i], 1e-5);
}

// Wallpaper Engine's simulation effects (cursor ripple, fluid simulation)
// step by the frame's duration and by how far the cursor travelled since the
// last frame, and push harder while the primary button is held; blend and skew
// divide by the texture reduction scale. Left at zero, a ripple never starts,
// the fluid never moves and a blend offset divides by zero.
TEST(ShaderValueUpdaterCompat, SimulationEffectsSeeFrameTimeCursorTravelAndButtons) {
    Scene scene;
    auto  camera       = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    scene.activeCamera = camera.get();
    auto node          = std::make_shared<SceneNode>();
    auto mesh          = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);

    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_Frametime" || name == "g_PointerPosition" ||
               name == "g_PointerPositionLast" || name == "g_PointerState" ||
               name == "g_TextureReductionScale";
    });
    const auto frame = [&] {
        updater.FrameBegin();
        std::map<std::string, ShaderValue, std::less<>> values;
        sprite_map_t                                    sprites;
        updater.UpdateUniforms(node.get(), sprites,
                               [&](std::string_view name, const ShaderValue& v) {
                                   values[std::string(name)] = v;
                               });
        return values;
    };

    scene.frameTime = 1.0 / 30.0;
    updater.MouseInput(0.25, 0.75);
    auto values = frame();
    for (const char* name : { "g_Frametime", "g_TextureReductionScale", "g_PointerPosition",
                              "g_PointerPositionLast", "g_PointerState" }) {
        ASSERT_TRUE(values.contains(name)) << name << " was never set";
    }
    EXPECT_FLOAT_EQ(values["g_Frametime"][0], 1.0f / 30.0f);
    EXPECT_FLOAT_EQ(values["g_TextureReductionScale"][0], 1.0f);
    EXPECT_FLOAT_EQ(values["g_PointerPosition"][0], 0.25f);
    EXPECT_FLOAT_EQ(values["g_PointerPositionLast"][0], 0.5f) << "where the cursor started";
    EXPECT_FLOAT_EQ(values["g_PointerPositionLast"][1], 0.5f);
    for (std::size_t i = 0; i < 4; ++i) EXPECT_FLOAT_EQ(values["g_PointerState"][i], 0.0f);

    updater.MouseInput(0.5, 0.25);
    updater.MouseButtonsInput(1u);
    values = frame();
    EXPECT_FLOAT_EQ(values["g_PointerPosition"][0], 0.5f);
    EXPECT_FLOAT_EQ(values["g_PointerPosition"][1], 0.25f);
    EXPECT_FLOAT_EQ(values["g_PointerPositionLast"][0], 0.25f) << "the previous frame's cursor";
    EXPECT_FLOAT_EQ(values["g_PointerPositionLast"][1], 0.75f);
    EXPECT_FLOAT_EQ(values["g_PointerState"][0], 1.0f);
    EXPECT_FLOAT_EQ(values["g_PointerState"][1], 1.0f);
    EXPECT_FLOAT_EQ(values["g_PointerState"][2], 1.0f) << "the press pushes the simulation";
    EXPECT_FLOAT_EQ(values["g_PointerState"][3], 0.0f);

    // Still held a frame later: held, but no new push, as in Wallpaper Engine.
    updater.MouseButtonsInput(1u);
    values = frame();
    EXPECT_FLOAT_EQ(values["g_PointerState"][0], 1.0f);
    EXPECT_FLOAT_EQ(values["g_PointerState"][1], 1.0f);
    EXPECT_FLOAT_EQ(values["g_PointerState"][2], 0.0f) << "a held button pushed again";

    updater.MouseButtonsInput(2u);
    values = frame();
    EXPECT_FLOAT_EQ(values["g_PointerPositionLast"][0], values["g_PointerPosition"][0])
        << "a still cursor travelled nowhere";
    EXPECT_FLOAT_EQ(values["g_PointerPositionLast"][1], values["g_PointerPosition"][1]);
    for (std::size_t i = 0; i < 4; ++i)
        EXPECT_FLOAT_EQ(values["g_PointerState"][i], 0.0f) << "only the primary button pushes";

    const uint32_t varying = updater.FrameVaryingUniforms(node.get(), 0, "");
    EXPECT_NE(varying & frame_varying_uniform::kTime, 0u);
    EXPECT_NE(varying & frame_varying_uniform::kPointer, 0u);

    // Reading only the cursor's travel or the buttons still follows the cursor,
    // so a still scene wakes for it.
    auto pressed_only = std::make_shared<SceneNode>();
    pressed_only->AddMesh(mesh);
    updater.InitUniforms(pressed_only.get(),
                         [](std::string_view name) { return name == "g_PointerState"; });
    EXPECT_NE(updater.FrameVaryingUniforms(pressed_only.get(), 0, "") &
                  frame_varying_uniform::kPointer,
              0u);
}

// A lit effect shades by where its quad lands in the scene and unprojects
// through the inverse of the effect's projection.
TEST(ShaderValueUpdaterCompat, EffectModelMatrixAndInverseProjectionMatchTheEffectProjection) {
    Scene scene;
    auto  camera            = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    scene.activeCamera      = camera.get();
    scene.cameras["effect"] = std::make_shared<SceneCamera>(2, 2, -1.0f, 1.0f);
    SceneNode owner;
    owner.SetScale(linalg::Vector3f(0.8f, 0.6f, 1.0f));
    owner.SetTranslate(linalg::Vector3f(100.0f, 200.0f, 0.0f));
    owner.UpdateTrans();
    // Once as the layer sits, once drawn off its place by a screen anchor's offset: the
    // effect lands where the card is drawn.
    for (const linalg::Vector3f offset : { linalg::Vector3f(0.0f, 0.0f, 0.0f),
                                          linalg::Vector3f(-37.0f, 11.0f, 0.0f) }) {
    SCOPED_TRACE(offset.x());
    owner.SetDrawOffset(offset);
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    node->SetCamera("effect");
    WPShaderValueData data;
    data.effect_owner  = &owner;
    data.effect_extent = linalg::Vector2f(280, 300);
    WPShaderValueUpdater updater(&scene);
    updater.SetNodeData(node.get(), data);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_EffectModelMatrix" || name == "g_EffectModelViewProjectionMatrix" ||
               name == "g_EffectModelViewProjectionMatrixInverse";
    });
    sprite_map_t                                 sprites;
    std::unordered_map<std::string, ShaderValue> values;
    updater.UpdateUniforms(node.get(), sprites, [&](std::string_view name, const ShaderValue& v) {
        values[std::string(name)] = v;
    });
    ASSERT_TRUE(values.contains("g_EffectModelMatrix"));
    ASSERT_TRUE(values.contains("g_EffectModelViewProjectionMatrix"));
    ASSERT_TRUE(values.contains("g_EffectModelViewProjectionMatrixInverse"));
    const auto matrix = [&](std::string_view name) {
        linalg::Matrix4d m;
        for (int i = 0; i < 16; ++i) m.data()[i] = values.at(std::string(name))[i];
        return m;
    };
    // The unit quad's corner (1, 1) lands on the layer card's corner.
    const linalg::Vector4d corner = matrix("g_EffectModelMatrix") * linalg::Vector4d(1, 1, 0, 1);
    EXPECT_NEAR(corner.x(), 100.0 + offset.x() + 0.8 * 140.0, 1e-3);
    EXPECT_NEAR(corner.y(), 200.0 + offset.y() + 0.6 * 150.0, 1e-3);
    const linalg::Matrix4d mvp = matrix("g_EffectModelViewProjectionMatrix");
    EXPECT_TRUE((camera->GetViewProjectionMatrix() * matrix("g_EffectModelMatrix"))
                    .isApprox(mvp, 1e-5));
    EXPECT_TRUE((matrix("g_EffectModelViewProjectionMatrixInverse") * mvp)
                    .isApprox(linalg::Matrix4d::Identity(), 1e-4));
    }
}

// A pointer or direction effect maps the screen back into the layer's own
// texture space through the inverse of the layer card's projection, wherever the
// card sits: moved, scaled, turned or flipped, on an intermediate pass and on
// the final one alike.
TEST(ShaderValueUpdaterCompat, EffectTextureProjectionMapsTheLayerCardOntoTheScreen) {
    Scene scene;
    auto  camera            = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    scene.activeCamera      = camera.get();
    scene.cameras["effect"] = std::make_shared<SceneCamera>(2, 2, -1.0f, 1.0f);
    SceneNode owner;
    owner.SetScale(linalg::Vector3f(-0.8f, 0.6f, 1.0f));
    owner.SetRotation(linalg::Vector3f(0.0f, 0.0f, 0.5f));
    owner.SetTranslate(linalg::Vector3f(100.0f, 200.0f, 0.0f));
    owner.UpdateTrans();
    // Once as the layer sits, once drawn off its place by a screen anchor's offset.
    for (const bool anchored : { false, true }) {
    for (const char* pass_camera : { "effect", "" }) {
        SCOPED_TRACE(std::string(pass_camera) + (anchored ? ", anchored" : ""));
        owner.SetDrawOffset(anchored ? linalg::Vector3f(-37.0f, 11.0f, 0.0f) : linalg::Vector3f::Zero());
        auto node = std::make_shared<SceneNode>();
        auto mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(SceneMaterial {});
        node->AddMesh(mesh);
        node->SetCamera(pass_camera);
        WPShaderValueData data;
        data.effect_owner  = &owner;
        data.effect_extent = linalg::Vector2f(280, 300);
        WPShaderValueUpdater updater(&scene);
        updater.SetNodeData(node.get(), data);
        updater.InitUniforms(node.get(), [](std::string_view name) {
            return name == "g_EffectTextureProjectionMatrix" ||
                   name == "g_EffectTextureProjectionMatrixInverse";
        });
        sprite_map_t                                 sprites;
        std::unordered_map<std::string, ShaderValue> values;
        updater.UpdateUniforms(node.get(), sprites,
                               [&](std::string_view name, const ShaderValue& v) {
                                   values[std::string(name)] = v;
                               });
        ASSERT_TRUE(values.contains("g_EffectTextureProjectionMatrix"));
        ASSERT_TRUE(values.contains("g_EffectTextureProjectionMatrixInverse"));
        const auto matrix = [&](std::string_view name) {
            linalg::Matrix4d m;
            for (int i = 0; i < 16; ++i) m.data()[i] = values.at(std::string(name))[i];
            return m;
        };
        // The card's (1, 1) corner, in its own half-extent space, lands where
        // the layer's transform puts its corner on the screen.
        // The card is drawn where `RenderTrans` puts it, which carries the draw offset.
        const linalg::Vector4d card_corner =
            owner.RenderTrans() * linalg::Vector4d(140.0, 150.0, 0.0, 1.0);
        const linalg::Vector4d expected = camera->GetViewProjectionMatrix() * card_corner;
        const linalg::Vector4d mapped =
            matrix("g_EffectTextureProjectionMatrix") * linalg::Vector4d(1, 1, 0, 1);
        EXPECT_TRUE(mapped.isApprox(expected, 1e-5));
        EXPECT_TRUE((matrix("g_EffectTextureProjectionMatrixInverse") *
                     matrix("g_EffectTextureProjectionMatrix"))
                        .isApprox(linalg::Matrix4d::Identity(), 1e-4));
    }
    }
}

TEST(ScriptRuntimeCompat, CompiledExportsIgnoreSourceTextAndRecognizePlainFunctions) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("plain", node.get());
    runtime->RegisterNodeTranslate("plain", node.get(), ResolveVec3Setting(*runtime, {
        {"value", "1 2 3"},
        {"script", "function update(value) { value.x += 2; return value; }"},
    }, "plain"));
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(node->Translate().x(), 3.0f);
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(node->Translate().x(), 5.0f);

    auto callback = ResolveBoolSetting(*runtime, {
        {"value", true},
        {"script", R"JS(
// export function update(value) { return false; }
const notAnExport = 'export function update';
function init() { thisLayer.visible = false; }
function cursorClick() { thisLayer.visible = !thisLayer.visible; }
)JS"},
    }, "plain");
    int notifications = 0;
    callback->listen([&](const DynamicValue&) { ++notifications; });
    runtime->RegisterNodeVisibility("plain", node.get(), std::move(callback));
    runtime->Tick(0.0);
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(notifications, 1);
    runtime->Tick(0.0);
    EXPECT_EQ(notifications, 1);
    runtime->DispatchCursorClick();
    runtime->Tick(0.0);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(notifications, 2);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, InitOnlyProgramsStillRunTimersAndConvenienceInitialization) {
    ScriptEngine engine;
    const auto initial = engine.Evaluate(R"JS(
function init() { localStorage.set('init-only-proof', 17); }
)JS", {}, DynamicValue(9.0f), {});
    ASSERT_NE(initial, nullptr);
    EXPECT_FLOAT_EQ(initial->getFloat(), 9.0f);
    EXPECT_FLOAT_EQ(EvaluateScalar(engine,
        "function update() { return Number(localStorage.get('init-only-proof')); }").getFloat(), 17.0f);

    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("timer", node.get());
    runtime->RegisterNodeVisibility("timer", node.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
function init() {
    thisLayer.visible = false;
    setTimeout(function() { thisLayer.visible = true; }, 100);
}
)JS"},
    }, "timer"));
    runtime->Tick(0.0);
    EXPECT_FALSE(node->Visible());
    runtime->Tick(0.2);
    EXPECT_TRUE(node->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, UpdateExceptionAndBooleanObjectKeepLiveNativeWrites) {
    for (const auto& ending : { std::string("throw new Error('expected update failure');"),
                               std::string("return new Boolean(false);") }) {
        auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
        auto node = std::make_shared<SceneNode>();
        runtime->RegisterNode("live", node.get());
        runtime->RegisterNodeVisibility("live", node.get(), ResolveBoolSetting(*runtime, {
            {"value", false},
            {"script", "function update() { thisLayer.visible = true; " + ending + " }"},
        }, "live"));
        for (int index = 0; index < 3; ++index) {
            runtime->SetNodeVisible("live", false);
            runtime->Tick(0.01);
            EXPECT_TRUE(node->Visible());
            EXPECT_EQ(runtime->scriptErrorCount(), ending.starts_with("throw") ? index + 1u : 0u);
        }
    }
}

TEST(ScriptRuntimeCompat, SharedCallbacksRetainPerProgramDispatchAndDynamicRegistration) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto marker = std::make_shared<SceneNode>();
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterSceneScript(R"JS(
let registered = false;
scene.on('update', function() {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.x += 1;
    marker.origin = origin;
    if (!registered) {
        registered = true;
        scene.on('cursorClick', function() {
            const marker = thisScene.getLayer('marker');
            const origin = marker.origin;
            origin.y += 1;
            marker.origin = origin;
        });
    }
});
)JS", "");
    runtime->RegisterSceneScript("const noExports = true;", "");
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 2.0f);
    runtime->DispatchCursorClick();
    EXPECT_FLOAT_EQ(marker->Translate().y(), 2.0f);
    runtime->Tick(0.0);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 4.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, TransformBindingsRepairDestinationsAndRefreshIdentityAndSize) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto original = std::make_shared<SceneNode>();
    runtime->RegisterNodeTranslate("anchor", original.get(),
        std::make_unique<DynamicValue>(linalg::Vector3f(10, 20, 0)));
    runtime->RegisterNodeScale("anchor", original.get(),
        std::make_unique<DynamicValue>(linalg::Vector3f(2, 3, 1)));
    runtime->SetNodeAnchorAlignment("anchor", "left bottom", linalg::Vector3f(10, 20, 0));
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(linalg::Vector3f(10, 20, 0)));
    runtime->RegisterNodeSize("anchor", linalg::Vector2f(20, 10));
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(linalg::Vector3f(30, 35, 0)));
    original->SetTranslate(linalg::Vector3f(-99, -99, 0));
    original->SetScale(linalg::Vector3f::Ones());
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(linalg::Vector3f(30, 35, 0)));
    EXPECT_TRUE(original->Scale().isApprox(linalg::Vector3f(2, 3, 1)));
    runtime->RegisterNode("anchor", original.get());
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(linalg::Vector3f(30, 35, 0)));
    runtime->RegisterNodeSize("anchor", linalg::Vector2f(40, 20));
    runtime->Tick(0.0);
    EXPECT_TRUE(original->Translate().isApprox(linalg::Vector3f(50, 50, 0)));

    auto replacement = std::make_shared<SceneNode>();
    runtime->RegisterNode("anchor", replacement.get());
    runtime->SetNodeAnchorAlignment("anchor", "left bottom", linalg::Vector3f(10, 20, 0));
    runtime->Tick(0.0);
    EXPECT_TRUE(replacement->Translate().isApprox(linalg::Vector3f(50, 50, 0)));
    EXPECT_TRUE(replacement->Scale().isApprox(linalg::Vector3f(2, 3, 1)));
}

linalg::Vector3f NodePointInScene(SceneNode& node, float x, float y) {
    node.UpdateTrans();
    return (node.ModelTrans() * linalg::Vector4d(x, y, 0.0, 1.0)).head<3>().cast<float>();
}

// Alignment names the layer's pivot in its own axes: a turned layer keeps the
// named edge on its origin instead of sliding along the scene's axes.
TEST(ScriptRuntimeCompat, RotatedAnchoredLayerTurnsAboutItsAnchor) {
    constexpr float quarter_turn = 1.5707963267948966f;
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    node->SetScale(linalg::Vector3f(1, 4, 1));
    node->SetRotation(linalg::Vector3f(0, 0, quarter_turn));
    runtime->RegisterNode("hand", node.get());
    runtime->RegisterNodeSize("hand", linalg::Vector2f(20, 10));
    runtime->SetNodeAnchorAlignment("hand", "top", linalg::Vector3f(100, 50, 0));
    // The 40-unit hand hangs from its top edge, a quarter turn from straight down.
    EXPECT_TRUE(node->Translate().isApprox(linalg::Vector3f(120, 50, 0)));
    EXPECT_TRUE(NodePointInScene(*node, 0, 5).isApprox(linalg::Vector3f(100, 50, 0)));

    // Perspective layers also turn about x and y; the anchor still stays put.
    runtime->SetNodeAnchorAlignment("hand", "bottom right", linalg::Vector3f(100, 50, 0));
    ASSERT_TRUE(runtime->SetNodeRotation("hand", linalg::Vector3f(0.4f, -0.3f, 1.1f)));
    EXPECT_TRUE(NodePointInScene(*node, 10, -5).isApprox(linalg::Vector3f(100, 50, 0)));

    // Turned back, the layer lands exactly where an unrotated one is placed.
    ASSERT_TRUE(runtime->SetNodeRotation("hand", linalg::Vector3f::Zero()));
    EXPECT_EQ(node->Translate(), linalg::Vector3f(90, 70, 0));

    // A bound rotation re-derives the anchor in the same tick, after the
    // translate binding has already been applied.
    runtime->RegisterNodeTranslate("hand", node.get(),
        std::make_unique<DynamicValue>(linalg::Vector3f(100, 50, 0)));
    auto angles = std::make_unique<DynamicValue>(linalg::Vector3f(0, 0, 0));
    auto* bound_angles = angles.get();
    runtime->RegisterNodeRotation("hand", node.get(), std::move(angles));
    runtime->Tick(0.0);
    EXPECT_EQ(node->Translate(), linalg::Vector3f(90, 70, 0));
    bound_angles->update(linalg::Vector3f(0, 0, quarter_turn * 2));
    runtime->Tick(0.0);
    EXPECT_TRUE(NodePointInScene(*node, 10, -5).isApprox(linalg::Vector3f(100, 50, 0)));
    EXPECT_TRUE(node->Translate().isApprox(linalg::Vector3f(110, 30, 0)));
}

// Workshop 2850003448 builds a ring visualizer: every bar is aligned 'top',
// placed on a circle and turned to face outward, then scaled by audio. Each
// bar must hang outward from the circle; with the anchor offset left on the
// scene's axes the whole ring slid down over the planet it surrounds.
TEST(ScriptRuntimeCompat, ScriptedRingBarsHangOutwardFromTheirCircle) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    std::vector<std::shared_ptr<SceneNode>> bars;
    for (int index = 0; index < 4; ++index) {
        auto bar = std::make_shared<SceneNode>();
        bar->SetTranslate(linalg::Vector3f(1280, 720, 0));
        const auto name = "bar" + std::to_string(index);
        runtime->RegisterNode(name, bar.get());
        runtime->RegisterNodeSize(name, linalg::Vector2f(8, 8));
        bars.push_back(bar);
    }
    runtime->RegisterSceneScript(R"JS(
import * as WEVector from 'WEVector';
export function init() {
    let center = thisLayer.origin;
    for (var i = 0; i < 4; ++i) {
        let bar = thisScene.getLayer('bar' + i);
        let angle = 90 * i + 30;
        bar.alignment = 'top';
        bar.origin = center.add(new Vec3(WEVector.angleVector2(angle)).multiply(90));
        bar.angles = new Vec3(0, 0, angle + 90);
    }
}
export function update() {
    for (var i = 0; i < 4; ++i) {
        let bar = thisScene.getLayer('bar' + i);
        bar.alignment = 'top';
        bar.scale = new Vec3(10, 6, 1);
    }
}
)JS", "bar0");
    runtime->Tick(1.0 / 60.0);
    runtime->Tick(1.0 / 60.0);
    ASSERT_EQ(runtime->scriptErrorCount(), 0u);

    const linalg::Vector3f center(1280, 720, 0);
    for (int index = 0; index < 4; ++index) {
        SCOPED_TRACE(index);
        const float radians = (90.0f * index + 30.0f) * 3.14159265f / 180.0f;
        const linalg::Vector3f outward(std::cos(radians), std::sin(radians), 0);
        // The top edge stays where the unscaled bar's edge sat, just inside the
        // circle, and the 48-unit bar reaches straight out from there.
        EXPECT_TRUE(NodePointInScene(*bars[index], 0, 4).isApprox(center + outward * 86.0f));
        EXPECT_TRUE(NodePointInScene(*bars[index], 0, -4).isApprox(center + outward * 134.0f));
    }
}

TEST(ScriptRuntimeCompat, EffectFinalRepairUsesCurrentParentAttachmentAndResolvedTarget) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto parent = std::make_shared<SceneNode>();
    auto source = std::make_shared<SceneNode>();
    parent->AppendChild(source);
    SceneImageEffectLayer layer(source.get(), 40, 20, "a", "b");
    runtime->RegisterNodeEffectFinal("effect", source.get(), &layer);
    runtime->Tick(0.0);
    layer.FinalNode().ClearRenderTransformOverride();
    parent->SetTranslate(linalg::Vector3f(7, 8, 0));
    linalg::Affine3d attachment = linalg::Affine3d::Identity();
    attachment.translate(linalg::Vector3d(3, 4, 0));
    source->SetAttachmentTransform(attachment.matrix());
    runtime->Tick(0.0);
    EXPECT_TRUE(layer.FinalNode().HasRenderTransformOverride());
    EXPECT_TRUE(layer.FinalNode().RenderTrans().isApprox(source->ModelTrans(), 1e-12));
    layer.FinalNode().SetRenderTransformOverride(linalg::Matrix4d::Identity());
    runtime->Tick(0.0);
    EXPECT_TRUE(layer.FinalNode().RenderTrans().isApprox(source->ModelTrans(), 1e-12));
    layer.SetFinalBlend(BlendMode::Normal);
    SceneMesh default_mesh;
    auto effect = std::make_shared<SceneImageEffect>();
    auto first = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    first->AddMesh(mesh);
    effect->nodes.push_back({ std::string(SpecTex_Default), first });
    layer.AddEffect(effect);
    layer.ResolveEffect(default_mesh, "effect");
    runtime->Tick(0.0);
    EXPECT_TRUE(first->RenderTrans().isApprox(source->ModelTrans(), 1e-12));
    auto second = std::make_shared<SceneNode>();
    auto second_mesh = std::make_shared<SceneMesh>();
    second_mesh->AddMaterial(SceneMaterial {});
    second->AddMesh(second_mesh);
    effect->nodes.back().sceneNode = second;
    layer.ResolveEffect(default_mesh, "effect");
    runtime->Tick(0.0);
    EXPECT_TRUE(second->HasRenderTransformOverride());
    EXPECT_TRUE(second->RenderTrans().isApprox(source->ModelTrans(), 1e-12));
}

TEST(ScriptRuntimeCompat, MaterialBindingsRepairCurrentMapsAndPreserveSecondPhasePrecedence) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto material = std::make_shared<SceneMaterial>();
    auto value = std::make_unique<DynamicValue>(std::string("1 2 3"));
    auto* source = value.get();
    runtime->RegisterMaterialConstant(material, "u_Value", std::move(value));
    runtime->RegisterMaterialConstant(material, "u_Null", std::make_unique<DynamicValue>());
    auto alpha = std::make_shared<ScalarAnimationPlayback>();
    runtime->RegisterMaterialAlphaAnimation(material, alpha);
    runtime->RegisterMaterialConstant(material, "g_Alpha", std::make_unique<DynamicValue>(0.75f));
    runtime->RegisterMaterialConstant(material, "u_Duplicate", std::make_unique<DynamicValue>(1.0f));
    runtime->RegisterMaterialConstant(material, "u_Duplicate", std::make_unique<DynamicValue>(2.0f));
    for (int index = 0; index < 3; ++index) {
        material->customShader.constValues.clear();
        runtime->Tick(0.0);
        ASSERT_EQ(material->customShader.constValues.at("u_Value").size(), 3u);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Value")[2], 3.0f);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Null")[0], 0.0f);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Duplicate")[0], 2.0f);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("g_Alpha")[0], 0.75f);
    }
    source->update(std::string("4 5"));
    runtime->Tick(0.0);
    ASSERT_EQ(material->customShader.constValues.at("u_Value").size(), 2u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Value")[1], 5.0f);
    material->customShader.constValues["u_Value"] = ShaderValue(9.0f);
    runtime->Tick(0.0);
    EXPECT_EQ(material->customShader.constValues.at("u_Value").size(), 2u);
    EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Value")[0], 4.0f);
}

TEST(ScriptRuntimeCompat, FailedRegistrationReleasesListenersAndMaterialTargetsOnlyInItsTail) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = {{"amount", RuntimeScalarValue::Float(1.0f)}},
    });
    auto survivor = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(survivor, "u_Value",
        ResolveFloatSetting(*runtime, {{"value", 0.0f}, {"user", "amount"}}));
    int survivor_calls = 0;
    runtime->RegisterDynamicValueListener(
        ResolveFloatSetting(*runtime, {{"value", 0.0f}, {"user", "amount"}}),
        [&](const DynamicValue&) { ++survivor_calls; });
    auto old_node = std::make_shared<SceneNode>();
    runtime->RegisterNode("transaction", old_node.get());
    const auto snapshot = runtime->CaptureNodeRegistration("transaction");
    auto failed_node = std::make_shared<SceneNode>();
    runtime->RegisterNode("transaction", failed_node.get());
    auto failed_material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(failed_material, "u_Value",
        ResolveFloatSetting(*runtime, {{"value", 0.0f}, {"user", "amount"}}));
    int failed_calls = 0;
    auto held = std::make_shared<int>(42);
    std::weak_ptr<int> resource = held;
    runtime->RegisterDynamicValueListener(
        ResolveFloatSetting(*runtime, {{"value", 0.0f}, {"user", "amount"}}),
        [held, &failed_calls](const DynamicValue&) { ++failed_calls; });
    held.reset();
    ASSERT_FALSE(resource.expired());
    runtime->RollbackNodeRegistration("transaction", failed_node.get(), snapshot);
    EXPECT_TRUE(resource.expired());
    failed_material->customShader.constValues["u_Value"] = ShaderValue(91.0f);
    runtime->ApplyProjectPropertyOverride({{"amount", RuntimeScalarValue::Float(7.0f)}});
    runtime->Tick(0.0);
    EXPECT_EQ(failed_calls, 1);
    EXPECT_EQ(survivor_calls, 2);
    EXPECT_FLOAT_EQ(failed_material->customShader.constValues.at("u_Value")[0], 91.0f);
    EXPECT_FLOAT_EQ(survivor->customShader.constValues.at("u_Value")[0], 7.0f);
    EXPECT_TRUE(runtime->HasNodeNamed("transaction"));
    runtime->SetNodeTranslate("transaction", linalg::Vector3f(4, 5, 0));
    EXPECT_TRUE(old_node->Translate().isApprox(linalg::Vector3f(4, 5, 0)));
}

TEST(ShaderValueUpdaterCompat, EmptyPuppetPosesDoNotEmitBoneUniforms) {
    Scene scene;
    SceneCamera camera(1920, 1080, 0.01f, 1000.0f);
    scene.activeCamera = &camera;
    scene.elapsingTime = 2.0;
    auto node = std::make_shared<SceneNode>();
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    node->AddMesh(mesh);
    WPShaderValueUpdater updater(&scene);
    updater.InitUniforms(node.get(), [](std::string_view name) {
        return name == "g_Bones" || name == "g_Time";
    });
    auto empty_asset = std::make_shared<WPPuppet>();
    empty_asset->prepared();
    const std::array<WPPuppetLayer, 3> empty_layers {
        WPPuppetLayer {}, WPPuppetLayer { std::shared_ptr<WPPuppet> {} }, WPPuppetLayer { empty_asset }
    };
    sprite_map_t sprites;
    for (const auto& layer : empty_layers) {
        WPShaderValueData data;
        data.puppet_layer = layer;
        updater.SetNodeData(node.get(), data);
        std::vector<std::string> names;
        updater.UpdateUniforms(node.get(), sprites, [&](std::string_view name, const ShaderValue& value) {
            names.emplace_back(name);
            if (name == "g_Time") {
                ASSERT_EQ(value.size(), 1u);
                EXPECT_FLOAT_EQ(value[0], 2.0f);
            }
        });
        EXPECT_EQ(names, std::vector<std::string> { "g_Time" });
    }
    auto asset = std::make_shared<WPPuppet>();
    asset->bones.emplace_back();
    asset->prepared();
    WPShaderValueData data;
    data.puppet_layer = WPPuppetLayer { asset };
    updater.SetNodeData(node.get(), data);
    std::vector<std::string> names;
    updater.UpdateUniforms(node.get(), sprites, [&](std::string_view name, const ShaderValue& value) {
        names.emplace_back(name);
        if (name == "g_Bones") {
            ASSERT_EQ(value.size(), 16u);
            for (std::size_t i = 0; i < value.size(); ++i) {
                EXPECT_FLOAT_EQ(value[i], i % 5 == 0 ? 1.0f : 0.0f);
            }
        }
    });
    EXPECT_EQ(names, (std::vector<std::string> { "g_Bones", "g_Time" }));
    scene.activeCamera = nullptr;
}

TEST(ScriptRuntimeCompat, CursorCoveragePreservesAllPhasesThresholdsAndLiveTransforms) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto target = std::make_shared<SceneNode>();
    auto marker = std::make_shared<SceneNode>();
    target->SetTranslate(linalg::Vector3f(100, 100, 0));
    target->SetRotation(linalg::Vector3f(0, 0, 0.5f));
    target->SetScale(linalg::Vector3f(-2, 1, 1));
    runtime->RegisterNode("target", target.get());
    runtime->RegisterNodeSize("target", linalg::Vector2f(40, 20));
    runtime->RegisterNodeHitMask("target", NodeHitMask { .width = 2, .height = 1, .alpha = {15, 16} });
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterNodeVisibility("target", target.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
function emit(n) {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.x = origin.x * 10 + n;
    marker.origin = origin;
}
function cursorEnter() { emit(1); }
function cursorMove() { emit(2); }
function cursorDown() { emit(3); }
function cursorClick() { emit(4); }
function cursorUp() { emit(5); }
function cursorLeave() { emit(6); }
)JS"},
    }, "target"));
    runtime->RegisterSceneScript(
        R"JS(scene.on('cursorClick', function() {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.y += 1;
    marker.origin = origin;
});)JS",
        "target");
    runtime->Tick(0.0);
    runtime->SetCursorEnter(true);
    const auto point = [&](float local_x) {
        target->UpdateTrans();
        const linalg::Vector4d world = target->ModelTrans() * linalg::Vector4d(local_x, 0, 0, 1);
        runtime->SetCursorWorldPosition(world.head<3>().cast<float>());
    };
    point(-10);
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 0);
    EXPECT_FLOAT_EQ(marker->Translate().y(), 0);
    point(10);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 12345);
    EXPECT_FLOAT_EQ(marker->Translate().y(), 1);
    runtime->BeginFrame();
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 123452);
    point(-10);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 1234526);
    runtime->SetNodeTranslate("marker", linalg::Vector3f::Zero());
    target->SetRotation(linalg::Vector3f::Zero());
    target->SetScale(linalg::Vector3f(-1, 1, 1));
    point(20);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 12);
    runtime->SetCursorEnter(false);
    runtime->SetCursorButtons(0, 0, 1);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 126);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, CursorCallbacksRecheckLaterTargetsWithoutAddingVisibilityFiltering) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto first = std::make_shared<SceneNode>();
    auto second = std::make_shared<SceneNode>();
    auto marker = std::make_shared<SceneNode>();
    runtime->RegisterNode("first", first.get());
    runtime->RegisterNodeSize("first", linalg::Vector2f(40, 40));
    runtime->RegisterNode("second", second.get());
    runtime->RegisterNodeSize("second", linalg::Vector2f(40, 40));
    runtime->RegisterNode("marker", marker.get());
    runtime->RegisterNodeVisibility("first", first.get(), ResolveBoolSetting(*runtime, {
        {"value", true}, {"script", R"JS(
let calls = 0;
function cursorClick() {
    const next = thisScene.getLayer('second');
    const origin = next.origin;
    origin.x = ++calls === 1 ? 100 : 0;
    next.origin = origin;
    next.visible = false;
}
)JS"},
    }, "first"));
    runtime->RegisterNodeVisibility("second", second.get(), ResolveBoolSetting(*runtime, {
        {"value", true},
        {"script", R"JS(function cursorClick() {
    const marker = thisScene.getLayer('marker');
    const origin = marker.origin;
    origin.x += 1;
    marker.origin = origin;
})JS"},
    }, "second"));
    runtime->Tick(0.0);
    runtime->SetCursorWorldPosition(linalg::Vector3f::Zero());
    runtime->SetCursorEnter(true);
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_FLOAT_EQ(marker->Translate().x(), 0);
    EXPECT_FLOAT_EQ(second->Translate().x(), 100);
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FLOAT_EQ(second->Translate().x(), 0);
    EXPECT_FALSE(second->Visible());
    EXPECT_FLOAT_EQ(marker->Translate().x(), 1);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, RollbackRestoresCoverageAndSharedPuppetAndHonorsIdentity) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", node.get());
    runtime->RegisterNodeSize("subject", linalg::Vector2f(40, 40));
    runtime->RegisterNodeHitMask("subject", NodeHitMask { .width = 1, .height = 1, .alpha = {0} });
    WPPuppetLayer layer(MakeSingleShotPuppet());
    WPPuppetLayer::AnimationLayer authored;
    authored.id = 7;
    layer.prepared(std::span(&authored, 1));
    ASSERT_TRUE(layer.setFrame(0, 2.5));
    runtime->RegisterPuppetLayer("subject", layer);
    const auto snapshot = runtime->CaptureNodeRegistration("subject");
    auto failed = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", failed.get());
    runtime->RegisterNodeHitMask("subject", NodeHitMask { .width = 1, .height = 1, .alpha = {255} });
    runtime->RegisterPuppetLayer("subject", WPPuppetLayer(MakeSingleShotPuppet()));
    runtime->RollbackNodeRegistration("subject", failed.get(), snapshot);
    ASSERT_NE(runtime->FindPuppetLayer("subject"), nullptr);
    EXPECT_FLOAT_EQ(runtime->FindPuppetLayer("subject")->genFrame(0)[0].translation().x(), 2.5f);
    ASSERT_TRUE(runtime->FindPuppetLayer("subject")->setFrame(0, 3.5));
    EXPECT_FLOAT_EQ(layer.genFrame(0)[0].translation().x(), 3.5f);
    runtime->RegisterSceneScript("function cursorClick() { thisLayer.visible = false; }", "subject");
    runtime->SetCursorEnter(true);
    runtime->SetCursorWorldPosition(linalg::Vector3f::Zero());
    runtime->SetCursorButtons(0, 1, 1);
    runtime->DispatchCursorFrameEvents(false);
    EXPECT_TRUE(node->Visible());

    auto replacement = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", replacement.get());
    runtime->RollbackNodeRegistration("subject", failed.get(), snapshot);
    runtime->SetNodeTranslate("subject", linalg::Vector3f(1, 2, 0));
    EXPECT_TRUE(replacement->Translate().isApprox(linalg::Vector3f(1, 2, 0)));
    runtime->RollbackNodeRegistration("subject", replacement.get(), nullptr);
    EXPECT_EQ(runtime->FindPuppetLayer("subject"), nullptr);
    auto fresh = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", fresh.get());
    runtime->RegisterNodeSize("subject", linalg::Vector2f(40, 40));
    runtime->DispatchCursorFrameEvents(true);
    EXPECT_FALSE(fresh->Visible());
}

TEST(ScriptRuntimeCompat, MaterialSecondPhaseRepairsSceneCallbackWrites) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    auto material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialConstant(material, "u_Value", std::make_unique<DynamicValue>(3.0f));
    auto visible = std::make_unique<DynamicValue>(true);
    int writes = 0;
    visible->listen([&](const DynamicValue&) {
        material->customShader.constValues["u_Value"] = ShaderValue(91.0f);
        ++writes;
    });
    runtime->RegisterNodeVisibility("subject", node.get(), std::move(visible));
    runtime->RegisterSceneScript("function update() { thisLayer.visible = !thisLayer.visible; }", "subject");
    for (int frame = 0; frame < 3; ++frame) {
        runtime->Tick(0.0);
        EXPECT_EQ(writes, frame + 1);
        EXPECT_FLOAT_EQ(material->customShader.constValues.at("u_Value")[0], 3.0f);
    }
}

TEST(ScriptRuntimeCompat, CloneGrowthSharesSourcesButRepairsIndependentDestinations) {
    Scene scene;
    auto runtime = MakeRuntimeWithScene(scene);
    auto source_node = std::make_shared<SceneNode>(
        linalg::Vector3f::Zero(), linalg::Vector3f::Ones(), linalg::Vector3f::Zero(), "source");
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    source_node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(source_node);
    runtime->RegisterNode("source", source_node.get());
    runtime->RegisterLayerTemplate("models/template.json", source_node, linalg::Vector2f(20, 20));
    auto value = std::make_unique<DynamicValue>(2.0f);
    auto* source = value.get();
    runtime->RegisterMaterialConstant(mesh->MaterialSlotPtr(), "u_Value", std::move(value));
    for (int index = 0; index < 40; ++index) {
        ASSERT_FALSE(runtime->CreateLayerFromTemplate("models/template.json", "source").empty());
    }
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 41u);
    source->update(7.0f);
    runtime->Tick(0.0);
    for (const auto& child : scene.sceneGraph->GetChildren()) {
        EXPECT_FLOAT_EQ(child->Mesh()->Material()->customShader.constValues.at("u_Value")[0], 7.0f);
        if (child.get() != source_node.get()) child->Mesh()->Material()->customShader.constValues.clear();
    }
    EXPECT_FLOAT_EQ(mesh->Material()->customShader.constValues.at("u_Value")[0], 7.0f);
    runtime->Tick(0.0);
    for (const auto& child : scene.sceneGraph->GetChildren()) {
        EXPECT_FLOAT_EQ(child->Mesh()->Material()->customShader.constValues.at("u_Value")[0], 7.0f);
    }
}

TEST(ScriptRuntimeCompat, RollbackDropsNewAnimationsAndAlphaButPreservesReusedPlayback) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", node.get());
    ScalarAnimation animation {
        .initial_value = 1.0f, .fps = 10.0, .length_frames = 100.0,
        .name = "survivor",
        .keyframes = {{.frame = 0.0, .value = 1.0f}, {.frame = 100.0, .value = 11.0f}},
    };
    auto survivor = runtime->RegisterScalarAnimation("subject", animation);
    runtime->Tick(0.2);
    const auto snapshot = runtime->CaptureNodeRegistration("subject");
    auto failed_node = std::make_shared<SceneNode>();
    runtime->RegisterNode("subject", failed_node.get());
    auto reused = runtime->RegisterScalarAnimation("subject", animation);
    reused->SetFrame(5.0);
    animation.name = "failed";
    auto failed_playback = runtime->RegisterScalarAnimation("subject", animation);
    std::weak_ptr<ScalarAnimationPlayback> failed_owner = failed_playback;
    auto failed_material = std::make_shared<SceneMaterial>();
    runtime->RegisterMaterialAlphaAnimation(failed_material, failed_playback);
    failed_playback.reset();
    runtime->RollbackNodeRegistration("subject", failed_node.get(), snapshot);
    EXPECT_TRUE(failed_owner.expired());
    EXPECT_EQ(runtime->FindScalarAnimation("subject", "failed"), nullptr);
    EXPECT_DOUBLE_EQ(survivor->frame, 5.0);
    failed_material->customShader.constValues["g_UserAlpha"] = ShaderValue(91.0f);
    runtime->Tick(0.2);
    EXPECT_DOUBLE_EQ(survivor->frame, 7.0);
    EXPECT_FLOAT_EQ(failed_material->customShader.constValues.at("g_UserAlpha")[0], 91.0f);
}

// ---------------------------------------------------------------------------
// SceneScript API parity with Wallpaper Engine 2.8.42.
// ---------------------------------------------------------------------------

namespace
{

// What running one property script's `update` produced: its numeric result and
// every error the runtime recorded. A script reports a failed expectation by
// throwing, so the message names the expectation.
struct ScriptRun {
    float                    value { 0.0f };
    std::vector<std::string> errors;
    bool                     evaluated { false };
};

ScriptRun RunUpdateOnce(const std::string& script) {
    ScriptRun run;
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = 1920, .canvas_height = 1080 });
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(), script, "", {}, DynamicValue(0.0f), runtime->hostContext());
    if (program == nullptr) {
        run.errors.push_back("script did not compile");
        return run;
    }
    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    run.errors = runtime->scriptErrors();
    if (result != nullptr) {
        run.value     = result->getFloat();
        run.evaluated = true;
    }
    return run;
}

#define EXPECT_SCRIPT_PASSES(run)                                                            \
    do {                                                                                     \
        EXPECT_TRUE((run).evaluated);                                                        \
        EXPECT_TRUE((run).errors.empty()) << (run).errors.front();                           \
        EXPECT_FLOAT_EQ((run).value, 1.0f);                                                  \
    } while (false)

const char* const kCheckHelpers = R"JS(
function check(name, ok) { if (!ok) throw new Error('check failed: ' + name); }
function near(a, b) { return Math.abs(a - b) < 1e-6; }
function same(v, other) { return v.equals(other) && v.constructor === other.constructor; }
)JS";

} // namespace

// A vector is a real class: the operations bounce and orbit scripts rely on
// (`direction.reflect(normal)` killed two stock movement scripts) exist on every
// size, and vectors the host hands a script are the same class.
TEST(ScriptRuntimeCompat, VectorsCarryTheWallpaperEngineMethodSet) {
    const auto run = RunUpdateOnce(std::string(kCheckHelpers) + R"JS(
export function update(value) {
  // geometry
  check('reflect', same(new Vec3(1, -1, 0).reflect(new Vec3(0, 1, 0)), new Vec3(1, 1, 0)));
  check('reflect2', same(new Vec2(3, -2).reflect(new Vec2(0, 1)), new Vec2(3, 2)));
  check('dot', new Vec3(1, 2, 3).dot(new Vec3(4, 5, 6)) === 32);
  check('dot4', new Vec4(1, 2, 3, 4).dot(new Vec4(1, 1, 1, 1)) === 10);
  check('cross', same(new Vec3(1, 0, 0).cross(new Vec3(0, 1, 0)), new Vec3(0, 0, 1)));
  check('distance', new Vec3(0, 0, 0).distance(new Vec3(3, 4, 0)) === 5);
  check('distanceSqr', new Vec2(1, 1).distanceSqr(new Vec2(4, 5)) === 25);
  check('lengthSqr', new Vec3(1, 2, 2).lengthSqr() === 9 && new Vec3(1, 2, 2).length() === 3);
  check('negate', same(new Vec3(1, -2, 3).negate(), new Vec3(-1, 2, -3)));
  check('project', same(new Vec3(2, 2, 0).project(new Vec3(1, 0, 0)), new Vec3(2, 0, 0)));
  check('projectZero', same(new Vec3(2, 2, 0).project(new Vec3(0, 0, 0)), new Vec3(0, 0, 0)));
  check('perpendicular', same(new Vec2(1, 2).perpendicular(), new Vec2(2, -1)));
  check('normalize', near(new Vec3(0, 3, 4).normalize().length(), 1));
  // equality is within a tolerance, and only between vectors of one size
  check('equals', new Vec3(1, 2, 3).equals(new Vec3(1.000001, 2, 3)));
  check('notEquals', !new Vec3(1, 2, 3).equals(new Vec3(1.01, 2, 3)) && !new Vec3(1, 2, 0).equals(new Vec2(1, 2)));
  // per component
  var v = new Vec3(-1.5, 2.5, 0.25);
  check('abs', same(v.abs(), new Vec3(1.5, 2.5, 0.25)));
  check('sign', same(v.sign(), new Vec3(-1, 1, 1)));
  check('round', same(v.round(), new Vec3(-1, 3, 0)));
  check('floor', same(v.floor(), new Vec3(-2, 2, 0)));
  check('ceil', same(v.ceil(), new Vec3(-1, 3, 1)));
  check('fract', same(v.fract(), new Vec3(0.5, 0.5, 0.25)));
  check('mod', same(v.mod(2), new Vec3(0.5, 0.5, 0.25)));
  check('step', same(v.step(0), new Vec3(0, 1, 1)));
  check('smoothStep', same(v.smoothStep(0, 1), new Vec3(0, 1, 0.15625)));
  check('clamp', same(v.clamp(-1, 1), new Vec3(-1, 1, 0.25)));
  check('clampVec', same(v.clamp(new Vec3(0, 0, 0), new Vec3(1, 2, 3)), new Vec3(0, 2, 0.25)));
  check('min', same(v.min(0), new Vec3(-1.5, 0, 0)) && same(v.min(new Vec3(0, 3, 0)), new Vec3(-1.5, 2.5, 0)));
  check('max', same(v.max(0), new Vec3(0, 2.5, 0.25)));
  check('mixNumber', same(new Vec2(0, 10).mix(new Vec2(10, 20), 0.5), new Vec2(5, 15)));
  check('mixVector', same(new Vec2(0, 10).mix(new Vec2(10, 20), new Vec2(1, 0)), new Vec2(10, 10)));
  // angles, in degrees
  check('angle', near(new Vec2(0, 2).angle(), 90));
  check('angleBetween2', near(new Vec2(1, 0).angleBetween(new Vec2(0, 1)), 90));
  check('angleBetween3', near(new Vec3(1, 0, 0).angleBetween(new Vec3(0, 0, 1)), 90));
  check('rotate', same(new Vec2(1, 0).rotate(90), new Vec2(0, 1)));
  check('toSpherical', same(new Vec3(1, 0, 0).toSpherical(), new Vec3(1, 90, 0)));
  check('fromSpherical', same(Vec3.fromSpherical(1, 90, 0), new Vec3(1, 0, 0)));
  // arithmetic, with numbers and with a smaller vector standing for its components
  check('addNumber', same(new Vec3(1, 2, 3).add(1), new Vec3(2, 3, 4)));
  check('addVec2', same(new Vec3(1, 2, 3).add(new Vec2(1, 1)), new Vec3(2, 3, 3)));
  check('multiplyVec2', same(new Vec3(2, 3, 4).multiply(new Vec2(2, 2)), new Vec3(4, 6, 4)));
  check('divide', same(new Vec2(4, 6).divide(new Vec2(2, 3)), new Vec2(2, 2)));
  check('subtract', same(new Vec4(4, 3, 2, 1).subtract(new Vec4(1, 1, 1, 1)), new Vec4(3, 2, 1, 0)));
  check('isFinite', new Vec3(1, 2, 3).isFinite() && !new Vec3(1, Infinity, 3).isFinite());
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

TEST(ScriptRuntimeCompat, VectorsBuildFromStringsAndPrintLikeWallpaperEngine) {
    const auto run = RunUpdateOnce(std::string(kCheckHelpers) + R"JS(
export function update(value) {
  // a scene.json style "x y z" string builds a vector, and prints back the same way
  check('parse3', same(new Vec3('1 2 3'), new Vec3(1, 2, 3)));
  check('parse2', same(new Vec2('1.5 -2'), new Vec2(1.5, -2)));
  check('parse4', same(new Vec4('1 2 3 4'), new Vec4(1, 2, 3, 4)));
  check('print3', new Vec3(1, 2, 3).toString() === '1 2 3');
  check('print2', String(new Vec2(1.5, -2)) === '1.5 -2');
  check('config', new Vec4(1, 2, 3, 4).toConfigString() === '1 2 3 4');
  // a lone number fills the vector; a Vec2 widens with zero; a Vec3 narrows
  check('splat', same(new Vec3(7), new Vec3(7, 7, 7)) && same(new Vec2(5), new Vec2(5, 5)));
  check('widen', same(new Vec3(new Vec2(1, 2)), new Vec3(1, 2, 0)));
  check('narrow', same(new Vec2(new Vec3(1, 2, 3)), new Vec2(1, 2)));
  check('empty', same(new Vec3(), new Vec3(0, 0, 0)));
  check('copyIsIndependent', (function() { var a = new Vec3(1, 2, 3); var b = new Vec3(a); b.x = 9; return a.x === 1; })());
  // plain objects, as older scripts and the host pass them
  check('plain', same(new Vec3({ x: 1, y: 2 }), new Vec3(1, 2, 0)));
  // methods are not enumerable: only the components are
  var keys = []; for (var key in new Vec3(1, 2, 3)) keys.push(key);
  check('enumerable', keys.join(',') === 'x,y,z');
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

TEST(ScriptRuntimeCompat, VectorsTheHostHandsOutAreTheGlobalClasses) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = 1920, .canvas_height = 1080 });
    auto node    = std::make_shared<SceneNode>();
    node->SetTranslate(linalg::Vector3f(3.0f, 4.0f, 0.0f));
    runtime->RegisterNode("probe", node.get());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var origin = thisLayer.origin;
  check('instance3', origin instanceof Vec3 && origin.constructor === Vec3);
  check('canvasSize', engine.canvasSize instanceof Vec2);
  check('screenPosition', input.cursorScreenPosition instanceof Vec2);
  check('methodsOnHostVectors', origin.length() === 5 && origin.distance(new Vec3(0, 0, 0)) === 5);
  check('frozenAlias', __WEVec3 === Vec3 && __WEVec2 === Vec2 && __WEVec4 === Vec4);
  thisLayer.origin = origin.add(new Vec3(1, 1, 0)).multiply(2);
  return 1;
}
)JS",
        "probe", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_TRUE(runtime->scriptErrors().empty()) << runtime->scriptErrors().front();
    EXPECT_FLOAT_EQ(result->getFloat(), 1.0f);
    EXPECT_NEAR(node->Translate().x(), 8.0f, 1e-5);
    EXPECT_NEAR(node->Translate().y(), 10.0f, 1e-5);
}

TEST(ScriptRuntimeCompat, Mat4ComposesTransformsAndInvertsThem) {
    const auto run = RunUpdateOnce(std::string(kCheckHelpers) + R"JS(
export function update(value) {
  check('identity', Mat4.identity().m.length === 16 && Mat4.identity().m[0] === 1 && Mat4.identity().m[5] === 1);
  var t = Mat4.fromTranslation(new Vec3(1, 2, 3));
  check('translation', same(t.translation(), new Vec3(1, 2, 3)) && t.m[12] === 1 && t.m[13] === 2 && t.m[14] === 3);
  check('transformPoint', same(t.transformPoint(new Vec3(1, 1, 1)), new Vec3(2, 3, 4)));
  check('transformDirection', same(t.transformDirection(new Vec3(1, 1, 1)), new Vec3(1, 1, 1)));
  var s = Mat4.fromScale(new Vec3(2, 3, 4));
  check('scale', same(s.transformPoint(new Vec3(1, 1, 1)), new Vec3(2, 3, 4)));
  var r = Mat4.fromRotation(90, new Vec3(0, 0, 1));
  check('rotateAboutZ', same(r.transformPoint(new Vec3(1, 0, 0)), new Vec3(0, 1, 0)));
  var composed = t.multiply(r).multiply(s);
  check('multiplyOrder', same(composed.transformPoint(new Vec3(1, 0, 0)), new Vec3(1, 4, 3)));
  check('inverse', composed.multiply(composed.inverse()).equals(Mat4.identity()));
  check('determinant', near(s.determinant(), 24) && near(Mat4.identity().determinant(), 1));
  check('transpose', t.transpose().m[3] === 1 && t.transpose().m[7] === 2 && t.transpose().m[11] === 3);
  var d = Mat4.compose(new Vec3(5, 6, 7), new Vec3(0, 0, 30), new Vec3(2, 2, 2)).decompose();
  check('decompose', same(d.translation, new Vec3(5, 6, 7)) && near(d.rotation.z, 30) && same(d.scale, new Vec3(2, 2, 2)));
  check('euler', near(Mat4.fromEuler(10, 20, 30).extractEuler().x, 10) && near(Mat4.fromEuler(10, 20, 30).extractEuler().y, 20) &&
                 near(Mat4.fromEuler(10, 20, 30).extractEuler().z, 30));
  var look = Mat4.lookAt(new Vec3(0, 0, 5), new Vec3(0, 0, 0), new Vec3(0, 1, 0));
  check('lookAt', same(look.transformPoint(new Vec3(0, 0, 0)), new Vec3(0, 0, -5)));
  check('vec4', near(t.multiply(new Vec4(0, 0, 0, 1)).x, 1));
  check('copyAndString', t.copy().equals(t) && new Mat4(t.toString()).equals(t) && t.toString().split(' ').length === 16);
  check('basis', same(Mat4.identity().right(), new Vec3(1, 0, 0)) && same(Mat4.identity().up(), new Vec3(0, 1, 0)) &&
                 same(Mat4.identity().forward(), new Vec3(0, 0, 1)));
  check('translateAppends', same(r.translate(new Vec3(1, 0, 0)).translation(), new Vec3(0, 1, 0)));
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

TEST(ScriptRuntimeCompat, Mat3HandlesTwoDimensionalTransforms) {
    const auto run = RunUpdateOnce(std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var t = Mat3.fromTranslation(new Vec2(4, 5));
  check('translation', same(t.translation(), new Vec2(4, 5)));
  check('transformPoint', same(t.transformPoint(new Vec2(1, 1)), new Vec2(5, 6)));
  check('transformDirection', same(t.transformDirection(new Vec2(1, 1)), new Vec2(1, 1)));
  var r = Mat3.fromRotation(90);
  check('rotation', same(r.transformPoint(new Vec2(1, 0)), new Vec2(0, 1)));
  var composed = Mat3.compose(new Vec2(1, 2), 90, new Vec2(2, 2));
  check('compose', same(composed.transformPoint(new Vec2(1, 0)), new Vec2(1, 4)));
  check('inverse', composed.multiply(composed.inverse()).equals(Mat3.identity()));
  check('determinant', near(Mat3.fromScale(new Vec2(2, 3)).determinant(), 6));
  var d = composed.decompose();
  check('decompose', same(d.translation, new Vec2(1, 2)) && near(d.rotation, 90) && same(d.scale, new Vec2(2, 2)));
  check('fromMat4', Mat3.fromMat4(Mat4.fromScale(new Vec3(2, 3, 4))).m[8] === 4);
  check('multiplyVec3', same(Mat3.identity().multiply(new Vec3(1, 2, 3)), new Vec3(1, 2, 3)));
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// The sway-animation helpers loop `for (i < thisLayer.getAnimationLayerCount())`
// before they have named a single layer. The count is the puppet's own.
TEST(ScriptRuntimeCompat, AnimationLayerCountIsThePuppetsNotTheNumberAskedFor) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());
    std::vector<WPPuppetLayer::AnimationLayer> authored(3);
    for (std::size_t i = 0; i < authored.size(); ++i) {
        authored[i].id   = 7;
        authored[i].name = "layer" + std::to_string(i);
    }
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    runtime->RegisterPuppetLayer("character", layer);

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(),
        R"JS(
export function update(value) {
  var count = thisLayer.getAnimationLayerCount();
  var visited = 0;
  for (var i = 0; i < count; ++i) {
    thisLayer.getAnimationLayer(i).rate = 2 + i;
    ++visited;
  }
  return count * 100 + visited;
}
)JS",
        "character", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 303.0f);
    EXPECT_DOUBLE_EQ(layer.rate(0), 2.0);
    EXPECT_DOUBLE_EQ(layer.rate(1), 3.0);
    EXPECT_DOUBLE_EQ(layer.rate(2), 4.0);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, AnimationLayerCountIsZeroWithoutAPuppet) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("plain", node.get());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(), "export function update(value) { return thisLayer.getAnimationLayerCount(); }",
        "plain", {}, DynamicValue(7.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(7.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 0.0f);
}

namespace
{

// Runs one `update` of `script` as a property script of layer `layer_name` on an
// existing runtime and reports what it returned and every error recorded so far.
ScriptRun RunUpdateOn(SceneRuntimeContext& runtime, const std::string& layer_name,
                      const std::string& script) {
    ScriptRun run;
    auto      program = runtime.scriptEngine().CreatePropertyScriptProgram(
        &runtime, script, layer_name, {}, DynamicValue(0.0f), runtime.hostContext());
    if (program == nullptr) {
        run.errors.push_back("script did not compile");
        return run;
    }
    const auto result = program->Evaluate(runtime.hostContext(), DynamicValue(0.0f));
    run.errors        = runtime.scriptErrors();
    if (result != nullptr) {
        run.value     = result->getFloat();
        run.evaluated = true;
    }
    return run;
}

// Layers `a`, `b`, `c`, registered in that order, none of them attached to a graph.
struct ThreeLayers {
    std::unique_ptr<SceneRuntimeContext> runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    std::shared_ptr<SceneNode>           a = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode>           b = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode>           c = std::make_shared<SceneNode>();

    ThreeLayers() {
        runtime->RegisterNode("a", a.get());
        runtime->RegisterNode("b", b.get());
        runtime->RegisterNode("c", c.get());
    }
};

} // namespace

// IScene.getLayerCount / getLayer(index) / enumerateLayers / getLayerByID: the
// layers in the order the scene lists them, as the very objects `getLayer(name)`
// answers with, so identity holds between every way of reaching a layer.
TEST(ScriptRuntimeCompat, SceneEnumeratesItsLayersInOrderAsTheObjectsGetLayerReturns) {
    ThreeLayers fixture;
    auto&       runtime = *fixture.runtime;
    runtime.RegisterLayerId(11, "a");
    runtime.RegisterLayerId(22, "b");
    runtime.RegisterLayerId(33, "c");
    // A hidden template a script copies from is not one of the scene's layers.
    auto hidden = std::make_shared<SceneNode>();
    runtime.RegisterNode("__template:models/line.json", hidden.get());

    const auto run = RunUpdateOn(runtime, "b", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  check('count', thisScene.getLayerCount() === 3);
  check('byIndex', thisScene.getLayer(0).name === 'a' && thisScene.getLayer(1).name === 'b' &&
                   thisScene.getLayer(2).name === 'c');
  check('indexIsTheNamedWrapper', thisScene.getLayer(2) === thisScene.getLayer('c'));
  check('thisLayer', thisScene.getLayer(1) === thisLayer);
  check('outOfRange', thisScene.getLayer(3) === null && thisScene.getLayer(-1) === null);
  var layers = thisScene.enumerateLayers();
  check('enumerate', layers.length === 3 && layers.map(function(l) { return l.name; }).join(',') === 'a,b,c');
  check('includes', layers.includes(thisScene.getLayer('c')) && layers.includes(thisLayer));
  check('find', layers.find(function(l) { return l.name === 'a'; }) === thisScene.getLayer(0));
  check('freshArray', thisScene.enumerateLayers() !== layers);
  check('byId', thisScene.getLayerByID(22) === thisLayer && thisScene.getLayerByID(33).name === 'c');
  check('unknownId', thisScene.getLayerByID(999) === null);
  // a loop over the count reaches every layer
  var names = [];
  for (var i = 0; i < thisScene.getLayerCount(); ++i) names.push(thisScene.getLayer(i).name);
  check('loop', names.join('') === 'abc');
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);

    // The scene file's declaration order wins over registration order.
    runtime.SetLayerOrder({ "c", "a" });
    const auto reordered = RunUpdateOn(runtime, "b", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var order = thisScene.enumerateLayers().map(function(l) { return l.name; }).join('');
  check('declared first, the rest after', order === 'cab');
  check('index follows', thisScene.getLayer(0).name === 'c');
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(reordered);
}

TEST(ScriptRuntimeCompat, LayersAScriptCreatesJoinTheEnumerationAndLeaveItWhenDestroyed) {
    LineTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    const auto        run = RunUpdateOn(runtime, "owner", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  check('before', thisScene.getLayerCount() === 1 && thisScene.getLayer(0) === thisLayer);
  var made = thisScene.createLayer('models/line.json');
  check('after', thisScene.getLayerCount() === 2);
  check('last', thisScene.getLayer(1) === made && thisScene.enumerateLayers()[1] === made);
  check('byKey', thisScene.getLayerByID(0) === null);
  thisScene.destroyLayer(made);
  check('destroyed', thisScene.getLayerCount() === 1 && thisScene.getLayer(1) === null);
  check('enumerate', thisScene.enumerateLayers().length === 1);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// getInitialLayerConfig(layer) is what the scene file says about the layer, as a
// plain object a script may take apart (a clock's drop shadow copies `text`).
TEST(ScriptRuntimeCompat, InitialLayerConfigIsTheSceneFilesObjectForTheLayer) {
    ThreeLayers fixture;
    auto&       runtime = *fixture.runtime;
    runtime.RegisterLayerId(7, "b");
    runtime.SetInitialLayerConfigProvider([](int32_t id) -> std::string {
        return id == 7 ? R"({"id":7,"name":"b","text":{"value":"12:00","script":"x"},"size":"100 50","image":"models/b.json"})"
                       : std::string();
    });
    const auto run = RunUpdateOn(runtime, "b", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var config = thisScene.getInitialLayerConfig(thisLayer);
  check('object', typeof config === 'object' && config !== null);
  check('keys', config.image === 'models/b.json' && config.size === '100 50' && config.name === 'b');
  check('nested', config.text.value === '12:00');
  check('byName', thisScene.getInitialLayerConfig('b').id === 7);
  check('plain', Object.keys(config).indexOf('size') >= 0);
  config.size = 'changed';
  check('fresh', thisScene.getInitialLayerConfig(thisLayer).size === '100 50');
  check('noConfig', thisScene.getInitialLayerConfig(thisScene.getLayer('a')) === null);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

TEST(ScriptRuntimeCompat, ASceneKeepsItsObjectListOnlyWhenAScriptReadsIt) {
    ThreeLayers quiet;
    EXPECT_FALSE(quiet.runtime->InitialLayerConfigRequested());
    RunUpdateOn(*quiet.runtime, "a", "export function update(value) { return 1; }");
    EXPECT_FALSE(quiet.runtime->InitialLayerConfigRequested());

    ThreeLayers curious;
    RunUpdateOn(*curious.runtime, "a",
                "export function update(value) { thisScene.getInitialLayerConfig(thisLayer); return 1; }");
    EXPECT_TRUE(curious.runtime->InitialLayerConfigRequested());
}

// applyGeneralSettings({ language }) is called right after init, and again when
// the interface language changes; the tag is lower-case.
TEST(ScriptRuntimeCompat, ApplyGeneralSettingsFollowsInitAndTheInterfaceLanguage) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto value   = ResolveFloatSetting(*runtime, { { "value", 0.0f }, { "script", R"JS(
var log = [];
export function init(value) { log.push('init'); return value; }
export function applyGeneralSettings(settings) { log.push('settings:' + settings.language); }
export function update(value) {
  var seen = log.join(',');
  return seen === 'init,settings:en-us' ? 1
       : seen === 'init,settings:en-us,settings:zh-cn' ? 2
       : seen === 'init,settings:en-us,settings:zh-cn,settings:pt-br' ? 3 : -1;
}
)JS" } });
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(value->getFloat(), 1.0f) << "defaults to en-us, right after init";
    runtime->SetLanguage("ZH_cn");
    EXPECT_EQ(runtime->Language(), "zh-cn");
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(value->getFloat(), 2.0f);
    runtime->SetLanguage("zh-CN");  // unchanged: nothing is said
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(value->getFloat(), 2.0f);
    runtime->SetLanguage("pt_BR");
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(value->getFloat(), 3.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ASceneScriptIsToldTheLanguageAfterItsInit) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto probe   = std::make_shared<SceneNode>();
    probe->SetVisible(false);
    runtime->RegisterNode("probe", probe.get());
    runtime->SetLanguage("de-DE");
    runtime->RegisterSceneScript(R"JS(
var order = [];
function init() { order.push('init'); }
function applyGeneralSettings(settings) {
  order.push(settings.language);
  scene.getObject('probe').visible = order.join(',') === 'init,de-de';
}
)JS",
                                 "");
    EXPECT_TRUE(probe->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// resizeScreen(size) reaches a script that has started when the display's size
// changes, with the new size; an unchanged size says nothing.
TEST(ScriptRuntimeCompat, ResizeScreenReportsANewDisplaySizeToStartedScripts) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = 1920, .canvas_height = 1080 });
    auto value   = ResolveFloatSetting(*runtime, { { "value", 0.0f }, { "script", R"JS(
var calls = 0;
var last = null;
export function resizeScreen(size) { ++calls; last = size; }
export function update(value) {
  if (last === null) return calls;
  return calls * 1e6 + last.x * 1000 + last.y / 1000 + (last instanceof Vec2 ? 0.5 : 0);
}
)JS" } });
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(value->getFloat(), 0.0f);
    runtime->SetScreenResolution(linalg::Vector2f(1920.0f, 1080.0f));  // the same size
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(value->getFloat(), 0.0f);
    runtime->SetScreenResolution(linalg::Vector2f(2560.0f, 1440.0f));
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(value->getFloat(), 1.0f * 1e6f + 2560.0f * 1000.0f + 1.44f + 0.5f);
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(value->getFloat(), 1.0f * 1e6f + 2560.0f * 1000.0f + 1.44f + 0.5f)
        << "a size already told is not told again";
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ResizeScreenReachesSceneScriptsAndEngineOnListeners) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = 800, .canvas_height = 600 });
    auto exported = std::make_shared<SceneNode>();
    auto listened = std::make_shared<SceneNode>();
    exported->SetVisible(false);
    listened->SetVisible(false);
    runtime->RegisterNode("exported", exported.get());
    runtime->RegisterNode("listened", listened.get());
    runtime->RegisterSceneScript(R"JS(
function resizeScreen(size) { scene.getObject('exported').visible = size.x === 3000 && size.y === 2000; }
engine.on('resizeScreen', function(size) { scene.getObject('listened').visible = size.y === 2000; });
)JS",
                                 "");
    runtime->SetScreenResolution(linalg::Vector2f(3000.0f, 2000.0f));
    EXPECT_FALSE(exported->Visible()) << "nothing runs until the tick";
    runtime->Tick(0.01);
    EXPECT_TRUE(exported->Visible());
    EXPECT_TRUE(listened->Visible());
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// destroy() runs once when a script that started is torn down, while the layers
// it could still touch exist. A script that never started has nothing to undo.
TEST(ScriptRuntimeCompat, DestroyRunsOnceForScriptsThatStartedWhenTheSceneIsTornDown) {
    auto started     = std::make_shared<SceneNode>();
    auto scene_probe = std::make_shared<SceneNode>();
    {
        auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
        runtime->RegisterNode("started", started.get());
        runtime->RegisterNode("sceneProbe", scene_probe.get());
        runtime->RegisterNodeVisibility("started", started.get(),
                                        ResolveBoolSetting(*runtime, { { "value", true }, { "script", R"JS(
var runs = 0;
export function init(value) { return value; }
export function destroy() {
  ++runs;
  // one call only, and the layer is still reachable from here
  thisLayer.visible = runs === 1;
  thisLayer.origin = new Vec3(runs, 0, 0);
}
)JS" } }, "started"));
        runtime->RegisterSceneScript(R"JS(
function destroy() { scene.getObject('sceneProbe').origin = new Vec3(77, 0, 0); }
)JS", "");
        runtime->Tick(0.01);
        EXPECT_FLOAT_EQ(started->Translate().x(), 0.0f) << "nothing ends while the scene runs";
        EXPECT_FLOAT_EQ(scene_probe->Translate().x(), 0.0f);
    }
    EXPECT_FLOAT_EQ(started->Translate().x(), 1.0f) << "destroy ran, once";
    EXPECT_TRUE(started->Visible());
    EXPECT_FLOAT_EQ(scene_probe->Translate().x(), 77.0f) << "scene scripts end too";
}

// Once the scripts have been ended, a scene program is not started: it would run `init`
// against a scene that is going away and nothing would end it.
TEST(ScriptRuntimeCompat, ASceneProgramRegisteredAfterTeardownNeverStarts) {
    auto probe   = std::make_shared<SceneNode>();
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    runtime->RegisterNode("probe", probe.get());
    runtime->TearDownScripts();
    runtime->RegisterSceneScript("scene.getObject('probe').origin = new Vec3(5, 0, 0);\n", "");
    EXPECT_EQ(runtime->sceneScriptCount(), 0u);
    EXPECT_FLOAT_EQ(probe->Translate().x(), 0.0f);
}

// A timeline with no usable frame rate moves nothing and does not wander backwards, and a
// time too large to place on a loop answers the initial value.
TEST(ScriptRuntimeCompat, ATimelineWithoutAFrameRateStandsStill) {
    ScalarAnimationPlayback clock;
    clock.animation.fps       = -30.0;
    clock.animation.length_frames = 10.0;
    clock.animation.keyframes = { { .frame = 0.0, .value = 0.0f }, { .frame = 10.0, .value = 1.0f } };
    clock.frame               = 4.0;
    clock.playing             = true;
    clock.Advance(1.0);
    EXPECT_DOUBLE_EQ(clock.frame, 4.0);

    ScalarAnimation loop;
    loop.initial_value  = 0.25f;
    loop.fps            = 30.0;
    loop.mode           = ScalarAnimationMode::Loop;
    loop.length_frames  = 10.0;
    loop.keyframes      = { { .frame = 0.0, .value = 0.0f }, { .frame = 10.0, .value = 1.0f } };
    EXPECT_FLOAT_EQ(loop.Evaluate(std::numeric_limits<double>::max()), 0.25f);
}

// A setting resolved only for its first value leaves its scripted value
// destroyed at once. The runtime must not keep a pointer to it: it would be
// ticked, and told to end, after it was freed.
TEST(ScriptRuntimeCompat, AScriptedValueDestroyedBeforeTheRuntimeLeavesItsRegistry) {
    auto probe = std::make_shared<SceneNode>();
    {
        auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
        runtime->RegisterNode("probe", probe.get());
        const bool first = ResolveBoolSetting(*runtime, { { "value", true }, { "script", R"JS(
export function update(value) { thisLayer.origin = new Vec3(9, 0, 0); return value; }
export function destroy() { thisLayer.origin = new Vec3(10, 0, 0); }
)JS" } }, "probe")->getBool();
        EXPECT_TRUE(first);
        runtime->Tick(0.01);
        runtime->Tick(0.01);
        EXPECT_EQ(runtime->scriptErrorCount(), 0u);
        EXPECT_FLOAT_EQ(probe->Translate().x(), 0.0f) << "the dropped script never ran";
    }
    EXPECT_FLOAT_EQ(probe->Translate().x(), 0.0f) << "and was not told to end";
}

TEST(ScriptRuntimeCompat, DestroyDoesNotRunForAScriptThatNeverStarted) {
    auto node = std::make_shared<SceneNode>();
    {
        auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
        runtime->RegisterNode("layer", node.get());
        auto value = ResolveBoolSetting(*runtime, { { "value", true }, { "script", R"JS(
export function init(value) { return value; }
export function destroy() { thisLayer.origin = new Vec3(5, 0, 0); }
)JS" } }, "layer");
        runtime->RegisterNodeVisibility("layer", node.get(), std::move(value));
        // No tick: the script has not run `init`.
    }
    EXPECT_FLOAT_EQ(node->Translate().x(), 0.0f);
}

// A script on animationlayers[i] is about that animation layer: thisObject is
// it (it has addEndedCallback), thisLayer is still the layer that owns it.
TEST(ScriptRuntimeCompat, ThisObjectIsTheAnimationLayerAScriptIsBoundTo) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());
    std::vector<WPPuppetLayer::AnimationLayer> authored(2);
    for (std::size_t i = 0; i < authored.size(); ++i) {
        authored[i].id   = 7;
        authored[i].name = i == 0 ? "idle" : "wave";
    }
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    runtime->RegisterPuppetLayer("character", layer);

    // The "initial progress" script of the Workshop helper library.
    const std::string script = R"JS(
export function init(value) {
  var ani = 'addEndedCallback' in thisObject ? thisObject : thisObject.getAnimation();
  ani.play();
  ani.setFrame(ani.frameCount * 0.6);
  if (thisLayer.name !== 'character') throw new Error('thisLayer changed');
  return value;
}
)JS";
    runtime->RegisterNodeVisibility("character", node.get(), ResolveBoolSetting(*runtime, {
        { "value", true }, { "script", script } }, "character", 1));
    runtime->Tick(0.01);
    EXPECT_DOUBLE_EQ(layer.frame(1), 3.0) << "the bound animation layer started at its offset";
    EXPECT_DOUBLE_EQ(layer.frame(0), 0.0) << "its sibling was left alone";
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, ThisObjectIsTheLayerForAScriptOnTheLayerItself) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("plain", node.get());
    const auto run = RunUpdateOn(*runtime, "plain", R"JS(
export function update(value) { return thisObject === thisLayer ? 1 : 0; }
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// addEndedCallback listeners are called when a single-play animation layer
// plays out, once per play, however the layer was asked for.
TEST(ScriptRuntimeCompat, AnimationLayerEndedCallbacksFireWhenASingleShotFinishes) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    auto probe   = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());
    runtime->RegisterNode("probe", probe.get());
    std::vector<WPPuppetLayer::AnimationLayer> authored(1);
    authored[0].id   = 7;
    authored[0].name = "siche";
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    WPPuppetLayer render_copy = layer;
    runtime->RegisterPuppetLayer("character", layer);

    runtime->RegisterNodeVisibility("character", node.get(), ResolveBoolSetting(*runtime, {
        { "value", true }, { "script", R"JS(
var ended = 0;
export function init(value) {
  thisLayer.getAnimationLayer('siche').addEndedCallback(function() {
    ++ended;
    thisScene.getLayer('probe').origin = new Vec3(ended, 0, 0);
  });
  // asked for by number, it is the same animation layer with the same listeners
  thisLayer.getAnimationLayer(0).addEndedCallback(function() { thisScene.getLayer('probe').scale = new Vec3(ended, 1, 1); });
  return value;
}
)JS" } }, "character"));
    runtime->Tick(0.01);

    render_copy.genFrame(0.0);
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(probe->Translate().x(), 0.0f) << "still playing";

    render_copy.genFrame(2.0);  // plays out
    EXPECT_FALSE(render_copy.isPlaying(0));
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(probe->Translate().x(), 1.0f) << "the listener ran";
    EXPECT_FLOAT_EQ(probe->Scale().x(), 1.0f) << "and so did the one added by number";
    runtime->Tick(0.01);
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(probe->Translate().x(), 1.0f) << "once per finish";

    layer.play(0);
    render_copy.genFrame(2.0);
    render_copy.genFrame(4.0);  // plays out again
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(probe->Translate().x(), 2.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptRuntimeCompat, RemovedEndedCallbacksStaySilent) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    auto probe   = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());
    runtime->RegisterNode("probe", probe.get());
    std::vector<WPPuppetLayer::AnimationLayer> authored(1);
    authored[0].id   = 7;
    authored[0].name = "siche";
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    runtime->RegisterPuppetLayer("character", layer);
    runtime->RegisterNodeVisibility("character", node.get(), ResolveBoolSetting(*runtime, {
        { "value", true }, { "script", R"JS(
export function init(value) {
  var animation = thisLayer.getAnimationLayer('siche');
  var heard = function() { thisScene.getLayer('probe').origin = new Vec3(1, 0, 0); };
  animation.addEndedCallback(heard);
  animation.removeEndedCallback(heard);
  return value;
}
)JS" } }, "character"));
    runtime->Tick(0.01);
    WPPuppetLayer render_copy = layer;
    render_copy.genFrame(0.0);
    render_copy.genFrame(2.0);
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(probe->Translate().x(), 0.0f);
}

// A layer that loops plays past its last frame over and over without ever
// ending, so its listener is never called, and it is still playing.
TEST(ScriptRuntimeCompat, ALoopingAnimationLayerNeverEndsAndItsListenerStaysSilent) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    auto probe   = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());
    runtime->RegisterNode("probe", probe.get());
    std::vector<WPPuppetLayer::AnimationLayer> authored(1);
    authored[0].id   = 7;
    authored[0].name = "sway";
    WPPuppetLayer layer(MakePuppet(WPPuppet::PlayMode::Loop));
    layer.prepared(authored);
    runtime->RegisterPuppetLayer("character", layer);
    runtime->RegisterNodeVisibility("character", node.get(), ResolveBoolSetting(*runtime, {
        { "value", true }, { "script", R"JS(
export function init(value) {
  thisLayer.getAnimationLayer('sway').addEndedCallback(function() {
    thisScene.getLayer('probe').origin = new Vec3(1, 0, 0);
  });
  return value;
}
)JS" } }, "character"));
    runtime->Tick(0.01);
    WPPuppetLayer render_copy = layer;
    for (const double seconds : {0.0, 0.7, 1.4, 2.1, 5.0}) {  // the animation is half a second long
        render_copy.genFrame(seconds);
        runtime->Tick(0.01);
    }
    EXPECT_TRUE(render_copy.isPlaying(0)) << "a looping layer keeps playing";
    EXPECT_FLOAT_EQ(probe->Translate().x(), 0.0f) << "and never ends";
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

// A paused sprite sheet holds its frame, play() resumes it from there, stop()
// returns to the first frame, and rate scales how fast it runs.
namespace
{

struct SpriteSheetScene {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> runtime = MakeRuntimeWithScene(scene);
    std::shared_ptr<SceneNode>           node    = std::make_shared<SceneNode>();
    std::shared_ptr<SceneCamera>         camera = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    WPShaderValueUpdater                 updater { &scene };
    sprite_map_t                         sprites;

    ~SpriteSheetScene() { scene.activeCamera = nullptr; }
    SpriteSheetScene() {
        scene.activeCamera = camera.get();
        // Four frames of a tenth of a second each.
        SceneTexture texture;
        texture.isSprite = true;
        for (int frame = 0; frame < 4; ++frame) {
            texture.spriteAnim.AppendFrame(SpriteFrame { .imageId = frame, .frametime = 0.1f });
        }
        scene.textures["sheet"] = texture;
        sprites[0]              = texture.spriteAnim;
        auto mesh               = std::make_shared<SceneMesh>();
        SceneMaterial material;
        material.textures = { "sheet" };
        mesh->AddMaterial(std::move(material));
        node->AddMesh(mesh);
        runtime->RegisterNode("icon", node.get());
        updater.InitUniforms(node.get(), [](std::string_view) { return false; });
    }

    // The frame the sheet shows after the renderer draws `seconds` more of it.
    int Draw(double seconds) {
        scene.frameTime = seconds;
        updater.UpdateUniforms(node.get(), sprites, [](std::string_view, const ShaderValue&) {});
        return sprites.at(0).CurFrameIndex();
    }

    float Run(const std::string& body) {
        const auto run = RunUpdateOn(*runtime, "icon", "export function update(value) { var anim = thisLayer.getTextureAnimation(); " +
                                                          body + " }");
        EXPECT_TRUE(run.errors.empty()) << run.errors.front();
        return run.value;
    }
};

} // namespace

TEST(ScriptRuntimeCompat, PausedSpriteSheetHoldsItsFrameAndPlayResumesIt) {
    SpriteSheetScene fixture;
    fixture.Draw(0.0);
    const int running = fixture.Draw(0.15);
    EXPECT_NE(running, 0) << "a sheet runs by itself";
    EXPECT_EQ(fixture.Run("return anim.isPlaying() ? 1 : 0;"), 1.0f);

    EXPECT_EQ(fixture.Run("anim.pause(); return anim.isPlaying() ? 1 : 0;"), 0.0f);
    EXPECT_EQ(fixture.Draw(0.5), running) << "paused: half a second changes nothing";
    EXPECT_EQ(fixture.Draw(0.5), running);
    EXPECT_EQ(fixture.Run("return anim.getFrame();"), static_cast<float>(running))
        << "the frame it holds is reported";

    EXPECT_EQ(fixture.Run("anim.play(); return anim.isPlaying() ? 1 : 0;"), 1.0f);
    EXPECT_NE(fixture.Draw(0.15), running) << "playing again: it moves on from where it was";
}

TEST(ScriptRuntimeCompat, StoppedSpriteSheetReturnsToItsFirstFrameAndSetFrameStillPins) {
    SpriteSheetScene fixture;
    fixture.Draw(0.0);
    fixture.Draw(0.25);
    EXPECT_EQ(fixture.Run("anim.stop(); return anim.isPlaying() ? 1 : 0;"), 0.0f);
    EXPECT_EQ(fixture.Draw(0.3), 0) << "stop shows the first frame";
    EXPECT_EQ(fixture.Draw(0.3), 0) << "and stays there";

    EXPECT_EQ(fixture.Run("anim.setFrame(2); return anim.getFrame();"), 2.0f);
    EXPECT_EQ(fixture.Draw(0.3), 2) << "setFrame pins the frame, as it always did";
    EXPECT_EQ(fixture.node->TextureFrame(), 2.0);
    EXPECT_EQ(fixture.Run("return anim.isPlaying() ? 1 : 0;"), 0.0f);

    // play() lets the sheet run on from the pinned frame.
    EXPECT_EQ(fixture.Run("anim.play(); return anim.isPlaying() ? 1 : 0;"), 1.0f);
    EXPECT_FALSE(fixture.node->TextureFrame().has_value());
    EXPECT_EQ(fixture.Draw(0.0), 2);
    EXPECT_EQ(fixture.Draw(0.15), 3);
}

TEST(ScriptRuntimeCompat, SpriteSheetRateScalesPlaybackAndTheSheetDescribesItself) {
    SpriteSheetScene fast;
    SpriteSheetScene reference;
    fast.Draw(0.0);
    reference.Draw(0.0);
    EXPECT_EQ(fast.Run("return anim.rate;"), 1.0f);
    EXPECT_EQ(fast.Run("anim.rate = 0; return anim.rate;"), 0.0f);
    EXPECT_EQ(fast.Draw(1.0), 0) << "a rate of zero is a pause";
    EXPECT_EQ(fast.Run("anim.rate = 2; return anim.rate;"), 2.0f);
    // 0.1s at twice the rate is 0.2s of the sheet.
    EXPECT_EQ(fast.Draw(0.1), reference.Draw(0.2));
    EXPECT_EQ(fast.Draw(0.1), reference.Draw(0.2)) << "and it keeps pace";

    EXPECT_EQ(fast.Run("return anim.frameCount;"), 4.0f);
    EXPECT_NEAR(fast.Run("return anim.duration;"), 0.4f, 1e-6f);
    EXPECT_NEAR(fast.Run("return anim.fps;"), 10.0f, 1e-5f);
    EXPECT_EQ(fast.Run("return anim.name === 'sheet' ? 1 : 0;"), 1.0f);
}

TEST(ScriptRuntimeCompat, ALayerWithoutASpriteSheetReportsNoFrames) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    auto  node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("plain", node.get());
    const auto run = RunUpdateOn(*runtime, "plain", R"JS(
export function update(value) {
  var anim = thisLayer.getTextureAnimation();
  anim.pause(); anim.play();
  return anim.frameCount === 0 && anim.fps === 0 && anim.duration === 0 ? 1 : 0;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// ---------------------------------------------------------------------------
// Text layers
// ---------------------------------------------------------------------------

namespace
{

void WaitForTextLayout(SceneRuntimeContext& runtime, const std::string& layer) {
    for (int attempt = 0; attempt < 400 && runtime.NodeTextDirty(layer); ++attempt) {
        runtime.PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

} // namespace

// thisLayer.font / pointsize / horizontalalign / verticalalign read what the text
// layer has and write through to it, and a write lays the text out again.
TEST(ScriptRuntimeCompat, TextLayerStyleIsReadAndWrittenThroughTheLayer) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    node->SetTranslate(linalg::Vector3f(100, 200, 0));
    runtime->RegisterNode("clock", node.get());
    runtime->RegisterTextLayer("clock", TextLayerState {
        .text = "12:30", .font_key = "Arial", .point_size = 12.0f, .horizontal_align = "center",
        .vertical_align = "center",
    });
    std::vector<std::string> requested_fonts;
    runtime->SetTextFontResolver([&](TextLayerState& state, const std::string& font_key) {
        requested_fonts.push_back(font_key);
        state.resolved_font_kind     = "family";
        state.resolved_font_identity = "Courier New";
        state.resolved_font_path.clear();
    });
    runtime->Tick(0.0);
    WaitForTextLayout(*runtime, "clock");
    const auto before = runtime->NodeSize("clock");

    const auto run = RunUpdateOn(*runtime, "clock", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  check('font', thisLayer.font === 'Arial');
  check('pointsize', thisLayer.pointsize === 12);
  check('halign', thisLayer.horizontalalign === 'center' && thisLayer.verticalalign === 'center');
  thisLayer.pointsize = 36;
  thisLayer.font = 'systemfont_courier';
  thisLayer.horizontalalign = 'right';
  thisLayer.verticalalign = 'bottom';
  check('readBack', thisLayer.pointsize === 36 && thisLayer.font === 'systemfont_courier' &&
                    thisLayer.horizontalalign === 'right' && thisLayer.verticalalign === 'bottom');
  check('byName', thisScene.getLayer('clock').pointsize === 36);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);

    ASSERT_EQ(requested_fonts.size(), 1u);
    EXPECT_EQ(requested_fonts.front(), "systemfont_courier");
    const auto state = runtime->NodeTextState("clock");
    ASSERT_TRUE(state.has_value());
    EXPECT_FLOAT_EQ(state->point_size, 36.0f);
    EXPECT_EQ(state->font_key, "systemfont_courier");
    EXPECT_EQ(state->resolved_font_identity, "Courier New");
    EXPECT_EQ(state->horizontal_align, "right");
    EXPECT_EQ(state->vertical_align, "bottom");
    EXPECT_TRUE(runtime->NodeTextDirty("clock")) << "the text has to be laid out again";

    WaitForTextLayout(*runtime, "clock");
    ASSERT_FALSE(runtime->NodeTextDirty("clock"));
    const auto after = runtime->NodeSize("clock");
    EXPECT_GT(after.y(), before.y()) << "a larger point size makes a taller layer";
    EXPECT_GT(after.x(), before.x());
    // Aligned to its right and bottom edges now: the layer's origin stays where it was and
    // the card hangs up and to the left of it.
    EXPECT_TRUE(node->Translate().isApprox(linalg::Vector3f(100, 200, 0)));
    const auto layout = runtime->NodeTextLayout("clock");
    ASSERT_TRUE(layout.has_value());
    EXPECT_NEAR(runtime->NodeBoxCentre("clock").x(), -after.x() * 0.5f, 1e-3f);
    EXPECT_GT(runtime->NodeBoxCentre("clock").y(), 0.0f);
    EXPECT_NEAR(runtime->NodeBoxCentre("clock").y() + after.y() * 0.5f,
                layout->top + layout->descender, 1e-3f);
}

TEST(ScriptRuntimeCompat, TextStyleOnAnotherKindOfLayerStaysAPlainProperty) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("image", node.get());
    const auto run = RunUpdateOn(*runtime, "image", R"JS(
export function update(value) {
  thisLayer.font = 'x';
  thisLayer.pointsize = 5;
  return thisLayer.font === 'x' && thisLayer.pointsize === 5 ? 1 : 0;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

TEST(ScriptRuntimeCompat, TextStyleRejectsValuesTheLayerCannotUse) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("clock", node.get());
    runtime->RegisterTextLayer("clock", TextLayerState { .text = "x", .font_key = "Arial", .point_size = 20.0f });
    const auto run = RunUpdateOn(*runtime, "clock", R"JS(
export function update(value) {
  thisLayer.pointsize = -3;
  thisLayer.pointsize = NaN;
  thisLayer.pointsize = 'big';
  return thisLayer.pointsize;
}
)JS");
    EXPECT_TRUE(run.errors.empty());
    EXPECT_FLOAT_EQ(run.value, 20.0f);
}

// createLayer({ text, font, pointsize, color, alpha, ... }) makes a text layer
// instead of throwing; the scene's own layer config reaches it as scene.json keys.
TEST(ScriptRuntimeCompat, CreateLayerMakesATextLayerFromItsConfiguration) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    auto  owner   = std::make_shared<SceneNode>();
    runtime->RegisterNode("owner", owner.get());
    scene.sceneGraph->AppendChild(owner);
    nlohmann::json received;
    int32_t        received_id = 0;
    runtime->SetTextLayerFactory([&](const std::string& config_json, int32_t id) {
        received    = nlohmann::json::parse(config_json);
        received_id = id;
        auto node = std::make_shared<SceneNode>(linalg::Vector3f::Zero(), linalg::Vector3f::Ones(),
                                                linalg::Vector3f::Zero(), "__we_text_" + std::to_string(id));
        runtime->RegisterNode(node->Name(), node.get());
        runtime->RegisterTextLayer(node->Name(), TextLayerState {
            .text = received.at("text").get<std::string>(), .font_key = received.value("font", ""),
            .point_size = received.value("pointsize", 12.0f),
        });
        return node;
    });
    const auto run = RunUpdateOn(*runtime, "owner", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var shadow = thisScene.createLayer({
    text: { value: '10:45', script: 'ignored' },
    font: 'systemfont_arial',
    pointsize: 48,
    color: new Vec3(0.25, 0.5, 0.75),
    alpha: 0.4,
    horizontalalign: 'left',
    size: '300 80',
    perspective: true,
    origin: new Vec3(5, 6, 0),
    name: 'shadow'
  });
  check('a layer came back', shadow && typeof shadow === 'object');
  check('text', shadow.text === '10:45');
  check('font', shadow.font === 'systemfont_arial' && shadow.pointsize === 48);
  check('named', thisScene.getLayer('shadow') === shadow && shadow.name === 'shadow');
  check('origin', shadow.origin.x === 5 && shadow.origin.y === 6);
  check('counted', thisScene.getLayerCount() === 2);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);

    EXPECT_NE(received_id, 0);
    EXPECT_EQ(received.at("text"), "10:45") << "an object-valued text is its value";
    EXPECT_EQ(received.at("font"), "systemfont_arial");
    EXPECT_EQ(received.at("pointsize"), 48);
    EXPECT_EQ(received.at("color"), "0.25 0.5 0.75") << "colors travel as the scene file writes them";
    EXPECT_FLOAT_EQ(received.at("alpha").get<float>(), 0.4f);
    EXPECT_EQ(received.at("horizontalalign"), "left");
    EXPECT_EQ(received.at("size"), "300 80");
    EXPECT_EQ(received.at("perspective"), true);
    // The new layer joined the scene beside the layer that made it.
    ASSERT_EQ(scene.sceneGraph->GetChildren().size(), 2u);
    EXPECT_TRUE(runtime->ConsumeSceneGraphMutationFlag());
}

TEST(ScriptRuntimeCompat, CreateLayerWithoutAnythingToMakeStillThrowsAndWithoutAFactoryReportsIt) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    auto  owner   = std::make_shared<SceneNode>();
    runtime->RegisterNode("owner", owner.get());
    const auto run = RunUpdateOn(*runtime, "owner", R"JS(
export function update(value) {
  var errors = 0;
  try { thisScene.createLayer({ color: '1 1 1' }); } catch (error) { ++errors; }
  try { thisScene.createLayer({ text: 'no factory is installed' }); } catch (error) { ++errors; }
  return errors;
}
)JS");
    EXPECT_TRUE(run.errors.empty());
    EXPECT_FLOAT_EQ(run.value, 2.0f);
}

namespace
{

// `models/card.json`: a 20x10 card with positions and texture coordinates, which
// layers a script makes are copies of.
struct CardTemplateScene {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> runtime = MakeRuntimeWithScene(scene);
    std::shared_ptr<SceneNode>           owner   = std::make_shared<SceneNode>(
        linalg::Vector3f::Zero(), linalg::Vector3f::Ones(), linalg::Vector3f::Zero(), "owner");

    CardTemplateScene() {
        scene.shaderValueUpdater = std::make_unique<WPShaderValueUpdater>(&scene);
        auto mesh = std::make_shared<SceneMesh>();
        SceneVertexArray vertices({ { WE_IN_POSITION.data(), VertexType::FLOAT3 },
                                    { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 } },
                                  4);
        const std::array position { -10.0f, -5.0f, 0.0f, -10.0f, 5.0f, 0.0f,
                                    10.0f,  -5.0f, 0.0f, 10.0f,  5.0f, 0.0f };
        const std::array coordinate { 0.0f, 0.8f, 0.0f, 0.0f, 0.5f, 0.8f, 0.5f, 0.0f };
        vertices.SetVertex(WE_IN_POSITION, position);
        vertices.SetVertex(WE_IN_TEXCOORD, coordinate);
        mesh->AddVertexArray(std::move(vertices));
        mesh->AddMaterial(SceneMaterial {});
        owner->AddMesh(mesh);
        scene.sceneGraph->AppendChild(owner);
        runtime->RegisterNode("owner", owner.get());
        runtime->RegisterNodeSize("owner", linalg::Vector2f(20, 10));
        runtime->RegisterLayerTemplate("models/card.json", owner, linalg::Vector2f(20, 10));
    }

    // Corner extents of a node's card.
    static linalg::Vector2f Extent(SceneNode& node) {
        const auto& vertices = node.Mesh()->GetVertexArray(0);
        float       width    = 0.0f;
        float       height   = 0.0f;
        for (std::size_t vertex = 0; vertex < vertices.VertexCount(); ++vertex) {
            width  = std::max(width, std::abs(vertices.Data()[vertex * vertices.OneSize()]) * 2.0f);
            height = std::max(height, std::abs(vertices.Data()[vertex * vertices.OneSize() + 1]) * 2.0f);
        }
        return { width, height };
    }
};

} // namespace

// createLayer({ image, size, name, parent, parallaxDepth }): the layer is made
// that size, reachable by that name, hangs below that parent, and ignores the
// cursor's parallax by the depth it was given.
TEST(ScriptRuntimeCompat, CreateLayerHonoursSizeNameParentAndParallaxDepth) {
    CardTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    const auto        run = RunUpdateOn(runtime, "owner", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var bar = thisScene.createLayer({
    image: 'models/card.json',
    size: new Vec2(40, 30),
    name: 'bar',
    parent: thisLayer,
    parallaxDepth: new Vec2(0.5, 0.25)
  });
  check('size', bar.size.x === 40 && bar.size.y === 30);
  check('name', thisScene.getLayer('bar') === bar && bar.name === 'bar');
  check('parent', bar.getParent() === thisLayer);
  check('depth', bar.parallaxDepth.x === 0.5 && bar.parallaxDepth.y === 0.25 && bar.parallaxDepth instanceof Vec2);
  // the property setter works after the fact, as scripts that zero it do
  bar.parallaxDepth = new Vec2(0, 0);
  check('zeroed', bar.parallaxDepth.x === 0 && bar.parallaxDepth.y === 0);
  // a named layer is still destroyed through its object
  check('destroys', thisScene.destroyLayer(bar) === true && thisScene.getLayerCount() === 1);
  // a plain path keeps working
  var plain = thisScene.createLayer('models/card.json');
  check('plain', plain.size.x === 20 && plain.size.y === 10 && plain.parallaxDepth.x === 0);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    // The template keeps its own geometry: the stretched copy had a mesh of its own.
    EXPECT_EQ(CardTemplateScene::Extent(*fixture.owner), linalg::Vector2f(20, 10));
}

TEST(ScriptRuntimeCompat, ASizedLayerHasItsOwnStretchedCardAndTheTemplateKeepsItsOwn) {
    CardTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    const auto        run = RunUpdateOn(runtime, "owner", std::string(kCheckHelpers) + R"JS(
var wide, tall;
export function update(value) {
  wide = thisScene.createLayer({ image: 'models/card.json', size: '60 10' });
  tall = thisScene.createLayer({ image: 'models/card.json', size: '20 50' });
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    std::vector<SceneNode*> created;
    for (const auto& child : fixture.scene.sceneGraph->GetChildren()) {
        if (child.get() != fixture.owner.get()) created.push_back(child.get());
    }
    ASSERT_EQ(created.size(), 2u);
    EXPECT_EQ(CardTemplateScene::Extent(*created[0]), linalg::Vector2f(60, 10));
    EXPECT_EQ(CardTemplateScene::Extent(*created[1]), linalg::Vector2f(20, 50));
    EXPECT_EQ(CardTemplateScene::Extent(*fixture.owner), linalg::Vector2f(20, 10));
    // Texture coordinates are not stretched: a padded texture still maps.
    const auto& vertices = created[0]->Mesh()->GetVertexArray(0);
    const auto  offsets  = vertices.GetAttrOffsetMap();
    const auto  uv       = offsets.at(std::string(WE_IN_TEXCOORD)).offset / sizeof(float);
    EXPECT_FLOAT_EQ(vertices.Data()[0 * vertices.OneSize() + uv + 1], 0.8f);
    EXPECT_FLOAT_EQ(vertices.Data()[2 * vertices.OneSize() + uv], 0.5f);
}

TEST(ScriptRuntimeCompat, ParallaxDepthIsReadAndWrittenThroughTheShaderUpdater) {
    CardTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    const auto        run = RunUpdateOn(runtime, "owner", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  check('default', thisLayer.parallaxDepth.x === 0 && thisLayer.parallaxDepth.y === 0);
  thisLayer.parallaxDepth = new Vec2(0.75, 1.5);
  check('read', thisLayer.parallaxDepth.x === 0.75 && thisLayer.parallaxDepth.y === 1.5);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    const auto depth = fixture.scene.shaderValueUpdater->NodeParallaxDepth(fixture.owner.get());
    EXPECT_FLOAT_EQ(depth[0], 0.75f);
    EXPECT_FLOAT_EQ(depth[1], 1.5f);
}

TEST(ScriptRuntimeCompat, ALayerCreatedBelowAParentMovesWithItAndStaysOutOfTheRoot) {
    CardTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    // A group for the layers to hang from.
    auto group = std::make_shared<SceneNode>(linalg::Vector3f(100, 0, 0), linalg::Vector3f::Ones(),
                                             linalg::Vector3f::Zero(), "group");
    fixture.scene.sceneGraph->AppendChild(group);
    runtime.RegisterNode("group", group.get());
    const auto run = RunUpdateOn(runtime, "owner", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var child = thisScene.createLayer({ image: 'models/card.json', parent: 'group' });
  check('parent', child.getParent() === thisScene.getLayer('group'));
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    ASSERT_EQ(group->GetChildren().size(), 1u);
    const auto child = group->GetChildren().front();
    EXPECT_EQ(child->Parent(), group.get());
    for (const auto& root_child : fixture.scene.sceneGraph->GetChildren()) {
        EXPECT_EQ(root_child->Name().rfind("__generated_layer_", 0), std::string::npos)
            << "the created layer is not also in the root";
    }
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());

    // Below the group it moves with it: its place in the world is the group's.
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 100.0, 1e-3);
    group->SetTranslate(linalg::Vector3f(250, 40, 0));
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 250.0, 1e-3);
    EXPECT_NEAR(child->ModelTrans()(1, 3), 40.0, 1e-3);
}


// ---------------------------------------------------------------------------
// Matrix maths, layer lifetime, layer names and order.
// ---------------------------------------------------------------------------

// Values worked out by hand in exact rational arithmetic, not by the routines
// under test, so a slip in one routine cannot hide behind another that shares it.
TEST(ScriptRuntimeCompat, MatrixDeterminantAndInverseMatchValuesWorkedOutExactly) {
    const auto run = RunUpdateOnce(std::string(kCheckHelpers) + R"JS(
function elements(m, expected) {
  for (var i = 0; i < expected.length; ++i) if (!near(m.m[i], expected[i])) return false;
  return true;
}
export function update(value) {
  var four = new Mat4([2, 0, 1, 3,  1, 1, 0, 2,  0, 3, 1, 1,  4, 0, 2, 1]);
  check('det4', near(four.determinant(), -25));
  check('inverse4', elements(four.inverse(), [-0.44, 0.6, -0.2, 0.32,  -0.36, 0.4, 0.2, 0.08,
                                              0.68, -1.2, 0.4, -0.04,  0.4, 0, 0, -0.2]));
  check('product4', four.multiply(four.inverse()).equals(Mat4.identity()) &&
                    four.inverse().multiply(four).equals(Mat4.identity()));
  var swapped = new Mat4([1, 1, 0, 2,  2, 0, 1, 3,  0, 3, 1, 1,  4, 0, 2, 1]);
  check('swapping two columns flips the sign', near(swapped.determinant(), 25));
  var repeated = new Mat4([2, 0, 1, 3,  2, 0, 1, 3,  0, 3, 1, 1,  4, 0, 2, 1]);
  check('a repeated column', repeated.determinant() === 0);
  check('has no inverse', !repeated.inverse().m.some(Number.isFinite));
  var three = new Mat3([1, 2, 0,  0, 1, 4,  5, 6, 0]);
  check('det3', near(three.determinant(), 16));
  check('inverse3', elements(three.inverse(), [-1.5, 0, 0.5,  1.25, 0, -0.25,  -0.3125, 0.25, 0.0625]));
  check('product3', three.multiply(three.inverse()).equals(Mat3.identity()));
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// Euler angles are turns about x, then y, then z, about the fixed axes (the
// matrix is Rz * Ry * Rx), in degrees; extractEuler gives them back.
TEST(ScriptRuntimeCompat, EulerAnglesTurnAboutXThenYThenZAndComeBackOut) {
    const auto run = RunUpdateOnce(std::string(kCheckHelpers) + R"JS(
function about(axis, degrees) { return Mat4.fromRotation(degrees, axis); }
export function update(value) {
  var X = new Vec3(1, 0, 0), Y = new Vec3(0, 1, 0), Z = new Vec3(0, 0, 1);
  check('order', Mat4.fromEuler(30, 40, 50).equals(about(Z, 50).multiply(about(Y, 40)).multiply(about(X, 30))));
  check('vector form', Mat4.fromEuler(new Vec3(30, 40, 50)).equals(Mat4.fromEuler(30, 40, 50)));
  check('z carries x to y', same(Mat4.fromEuler(0, 0, 90).transformDirection(X), Y));
  check('x carries y to z', same(Mat4.fromEuler(90, 0, 0).transformDirection(Y), Z));
  check('y carries z to x', same(Mat4.fromEuler(0, 90, 0).transformDirection(Z), X));
  var samples = [[10, 20, 30], [-170, 45, 120], [0, 0, 0], [90, -60, -45], [179, 80, -179],
                 [33, -89, 12], [-45, 0, 170]];
  samples.forEach(function(angles) {
    var e = Mat4.fromEuler(angles[0], angles[1], angles[2]).extractEuler();
    check('round trip ' + angles, near(e.x, angles[0]) && near(e.y, angles[1]) && near(e.z, angles[2]));
    var scaled = Mat4.fromEuler(angles[0], angles[1], angles[2]).scale(3).extractEuler();
    check('scale leaves the angles ' + angles, near(scaled.x, angles[0]) && near(scaled.y, angles[1]) &&
                                                near(scaled.z, angles[2]));
  });
  // Straight up or down, x and z turn the same way and cannot be told apart:
  // what comes back builds the very same matrix.
  [[30, 90, 20], [-80, -90, 15], [0, 90, 0]].forEach(function(angles) {
    var original = Mat4.fromEuler(angles[0], angles[1], angles[2]);
    var e = original.extractEuler();
    check('lock keeps y ' + angles, near(e.y, angles[1]));
    check('lock rebuilds ' + angles, Mat4.fromEuler(e).equals(original));
  });
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// decompose gives translation, Euler angles and scale that compose back into the
// matrix, a mirroring showing as a negative x scale; the rest of the geometry
// (axis-angle, view and normal matrices) follows its definitions.
TEST(ScriptRuntimeCompat, MatrixDecompositionRebuildsTheMatrixAndMirroringIsANegativeXScale) {
    const auto run = RunUpdateOnce(std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var cases = [
    [[1, 2, 3], [10, 20, 30], [2, 3, 4]],
    [[-4, 5, 0.5], [-100, 35, 170], [-2, 3, 4]],
    [[0, 0, 0], [0, 0, 0], [1, -1, 1]],
    [[7, 8, 9], [45, -50, 60], [1, 1, -5]],
  ];
  cases.forEach(function(c, index) {
    var t = new Vec3(c[0][0], c[0][1], c[0][2]), r = new Vec3(c[1][0], c[1][1], c[1][2]);
    var s = new Vec3(c[2][0], c[2][1], c[2][2]);
    var m = Mat4.compose(t, r, s);
    var d = m.decompose();
    check('translation ' + index, same(d.translation, t));
    check('rebuild ' + index, Mat4.compose(d.translation, d.rotation, d.scale).equals(m));
    check('mirroring ' + index, (d.scale.x * d.scale.y * d.scale.z < 0) === (s.x * s.y * s.z < 0));
    check('lengths ' + index, near(Math.abs(d.scale.x), Math.abs(s.x)) && near(Math.abs(d.scale.y), Math.abs(s.y)) &&
                              near(Math.abs(d.scale.z), Math.abs(s.z)));
  });
  var plain = Mat4.compose(new Vec3(0, 0, 0), new Vec3(10, 20, 30), new Vec3(2, 3, 4)).decompose();
  check('authored', same(plain.rotation, new Vec3(10, 20, 30)) && same(plain.scale, new Vec3(2, 3, 4)));
  var mirrored = Mat4.compose(new Vec3(0, 0, 0), new Vec3(10, 20, 30), new Vec3(-2, 3, 4)).decompose();
  check('mirrored in x', same(mirrored.rotation, new Vec3(10, 20, 30)) && same(mirrored.scale, new Vec3(-2, 3, 4)));

  var flat = Mat3.compose(new Vec2(1, 2), 40, new Vec2(-2, 3));
  var d2 = flat.decompose();
  check('flat', same(d2.translation, new Vec2(1, 2)) && near(d2.rotation, 40) && same(d2.scale, new Vec2(-2, 3)));
  check('flat rebuild', Mat3.compose(d2.translation, d2.rotation, d2.scale).equals(flat));

  var X = new Vec3(1, 0, 0), Y = new Vec3(0, 1, 0), Z = new Vec3(0, 0, 1);
  check('a third of a turn about the diagonal', same(Mat4.fromRotation(120, new Vec3(1, 1, 1)).transformDirection(X), Y));
  check('right-handed about y', same(Mat4.fromRotation(90, Y).transformDirection(Z), X));
  check('the axis need not be unit', Mat4.fromRotation(90, new Vec3(0, 0, 5)).equals(Mat4.fromRotation(90, Z)));
  var eye = new Vec3(1, 2, 3), centre = new Vec3(1, 2, -7);
  var view = Mat4.lookAt(eye, centre, Y);
  check('the eye is the origin', same(view.transformPoint(eye), new Vec3(0, 0, 0)));
  check('what is ahead is down -z', same(view.transformPoint(centre), new Vec3(0, 0, -10)));
  check('up stays up', same(view.transformDirection(Y), Y));
  var model = Mat4.compose(new Vec3(0, 0, 0), new Vec3(20, 30, 40), new Vec3(2, 3, 5));
  check('normals stay perpendicular', near(model.transformDirection(X).dot(model.normalMatrix().multiply(Z)), 0));
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// A layer destroyed with layers below it (createLayer({ parent }) makes them)
// takes them along: none stays registered, counted, named or findable, and the
// nodes are freed together once the graph no longer draws them.
TEST(ScriptRuntimeCompat, DestroyLayerRemovesEveryLayerBelowItFromTheRuntime) {
    LineTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    const auto parent     = runtime.CreateLayerFromTemplate("models/line.json", "owner");
    const auto child      = runtime.CreateLayerFromTemplate("models/line.json", "owner");
    const auto grandchild = runtime.CreateLayerFromTemplate("models/line.json", "owner");
    const auto bystander  = runtime.CreateLayerFromTemplate("models/line.json", "owner");
    ASSERT_FALSE(parent.empty() || child.empty() || grandchild.empty() || bystander.empty());
    ASSERT_TRUE(runtime.SetNodeParent(child, parent));
    ASSERT_TRUE(runtime.SetNodeParent(grandchild, child));
    ASSERT_TRUE(runtime.NameLayer(child, "kid"));
    ASSERT_EQ(runtime.LayerCount(), 5u);
    ASSERT_EQ(runtime.NodeParentName(grandchild), child);

    // The nodes, to see when they are freed: owner and the bystander stay at the root.
    std::vector<std::weak_ptr<SceneNode>> nodes;
    for (const auto& top : fixture.scene.sceneGraph->GetChildren()) {
        if (top->Name() != parent) continue;
        nodes.push_back(top);
        nodes.push_back(top->GetChildren().front());
        nodes.push_back(top->GetChildren().front()->GetChildren().front());
    }
    ASSERT_EQ(nodes.size(), 3u);
    runtime.ConsumeSceneGraphMutationFlag();

    std::vector<std::string> destroyed;
    EXPECT_TRUE(runtime.DestroyLayer(parent, &destroyed));
    EXPECT_EQ(std::set<std::string>(destroyed.begin(), destroyed.end()),
              (std::set<std::string> { parent, child, grandchild }));
    for (const auto& name : { parent, child, grandchild }) {
        EXPECT_FALSE(runtime.HasNodeNamed(name)) << name;
        EXPECT_EQ(runtime.LayerIndex(name), -1) << name;
        EXPECT_FALSE(runtime.SetNodeVisible(name, true)) << "a script holding it reaches nothing";
        EXPECT_FALSE(runtime.DestroyLayer(name)) << name;
    }
    EXPECT_EQ(runtime.LayerCount(), 2u) << "the owner and the bystander";
    EXPECT_EQ(runtime.LayerIndex(bystander), 1);
    EXPECT_EQ(runtime.ResolveLayerName("kid"), "kid") << "the name a script gave goes with the layer";
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    EXPECT_FALSE(runtime.SetNodeVisible(child, true)) << "still unreachable while the nodes wait to be freed";
    for (const auto& node : nodes) EXPECT_FALSE(node.expired()) << "the compiled graph still points at them";

    runtime.Tick(1.0 / 60.0);
    for (const auto& node : nodes) EXPECT_TRUE(node.expired()) << "freed together once the graph was rebuilt";
    EXPECT_EQ(runtime.LayerCount(), 2u);
}

// The same through the script API: the wrappers a script still holds, the layer
// count and the enumeration stay safe to use after the layers are gone.
TEST(ScriptRuntimeCompat, ScriptsCanKeepUsingWrappersOfLayersDestroyedWithTheirParent) {
    LineTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    runtime.RegisterSceneScript(R"JS(
var ticks = 0;
var parent, child, grandchild;
function update() {
  ++ticks;
  if (ticks === 1) {
    parent = thisScene.createLayer({ image: 'models/line.json', name: 'parent' });
    child = thisScene.createLayer({ image: 'models/line.json', name: 'child', parent: parent });
    grandchild = thisScene.createLayer({ image: 'models/line.json', parent: child });
    if (thisScene.getLayerCount() !== 4) throw new Error('count before: ' + thisScene.getLayerCount());
    if (grandchild.getParent() !== child || child.getParent() !== parent) throw new Error('not nested');
  }
  if (ticks === 2) {
    if (thisScene.destroyLayer(parent) !== true) throw new Error('not destroyed');
    if (thisScene.getLayerCount() !== 1) throw new Error('count after: ' + thisScene.getLayerCount());
    if (thisScene.enumerateLayers().length !== 1) throw new Error('still enumerated');
  }
  if (ticks >= 3) {
    // wrappers of freed layers: nothing to reach, nothing to break
    child.visible = true;
    child.origin = new Vec3(1, 2, 3);
    child.alpha = 0.5;
    grandchild.scale = new Vec3(2, 2, 2);
    if (child.getParent() !== null) throw new Error('a destroyed layer still has a parent');
    if (thisScene.destroyLayer(child) !== false || thisScene.destroyLayer('child') !== false) {
      throw new Error('destroyed twice');
    }
    if (thisScene.getLayerCount() !== 1 || thisScene.getLayerIndex(grandchild) !== -1) throw new Error('counted');
    if (thisScene.getLayer('child') === child) throw new Error('the name still finds the old layer');
  }
}
)JS", "owner");
    runtime.Tick(1.0 / 60.0);
    runtime.ConsumeSceneGraphMutationFlag();
    runtime.Tick(1.0 / 60.0);
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    runtime.Tick(1.0 / 60.0);  // released at the start of this tick, then the script uses the wrappers
    runtime.Tick(1.0 / 60.0);
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;
    EXPECT_EQ(fixture.scene.sceneGraph->GetChildren().size(), 1u);
}

// A layer asked for by a name that was used before gets the new layer, not the
// destroyed one, and a layer cannot hang below itself or be given a missing parent.
TEST(ScriptRuntimeCompat, ANameFreedByDestroyLayerCanBeGivenAgainAndParentsAreChecked) {
    LineTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    const auto run = RunUpdateOn(runtime, "owner", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var first = thisScene.createLayer({ image: 'models/line.json', name: 'x' });
  check('first', thisScene.getLayer('x') === first && first.name === 'x');
  check('destroyed', thisScene.destroyLayer(first) === true);
  var second = thisScene.createLayer({ image: 'models/line.json', name: 'x' });
  check('second', thisScene.getLayer('x') === second && second !== first && second.name === 'x');
  check('counted', thisScene.getLayerCount() === 2);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);

    const auto a = runtime.CreateLayerFromTemplate("models/line.json", "owner");
    const auto b = runtime.CreateLayerFromTemplate("models/line.json", "owner");
    ASSERT_TRUE(runtime.SetNodeParent(b, a));
    EXPECT_FALSE(runtime.SetNodeParent(a, b)) << "a layer cannot hang below its own child";
    EXPECT_FALSE(runtime.SetNodeParent(a, a)) << "or below itself";
    EXPECT_FALSE(runtime.SetNodeParent(a, "no such layer"));
    EXPECT_EQ(runtime.NodeParentName(a), "") << "and stays where it was";
    EXPECT_EQ(runtime.NodeParentName(b), a);
    EXPECT_TRUE(runtime.SetNodeParent(b, ""));
    EXPECT_EQ(runtime.NodeParentName(b), "") << "an empty parent is the scene root";
}

// `layer.name` is what the scene file calls the layer. A layer whose name is
// shared or empty is registered under a generated key, which scripts never see
// as a name: enumerating, indexing and looking up by id all show the authored one.
TEST(ScriptRuntimeCompat, LayersShowTheNameTheSceneFileGaveThemWhateverKeyTheyAreRegisteredUnder) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto first   = std::make_shared<SceneNode>();
    auto second  = std::make_shared<SceneNode>();
    auto nameless = std::make_shared<SceneNode>();
    auto solo    = std::make_shared<SceneNode>();
    runtime->RegisterNode("__we_layer_5", first.get());
    runtime->RegisterNode("__we_layer_6", second.get());
    runtime->RegisterNode("__we_layer_7", nameless.get());
    runtime->RegisterNode("solo", solo.get());
    runtime->RegisterLayerAlias("twin", "__we_layer_5");
    runtime->RegisterLayerAuthoredName("__we_layer_5", "twin");
    runtime->RegisterLayerAuthoredName("__we_layer_6", "twin");
    runtime->RegisterLayerAuthoredName("__we_layer_7", "");
    runtime->RegisterLayerId(11, "__we_layer_5");
    runtime->RegisterLayerId(12, "__we_layer_6");
    runtime->RegisterLayerId(13, "__we_layer_7");
    EXPECT_EQ(runtime->LayerAuthoredName("__we_layer_6"), "twin");
    EXPECT_EQ(runtime->LayerAuthoredName("__we_layer_7"), "");
    EXPECT_EQ(runtime->LayerAuthoredName("solo"), "solo") << "no name on record: the key is the name";

    const auto run = RunUpdateOn(*runtime, "solo", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var layers = thisScene.enumerateLayers();
  check('names', layers.map(function(l) { return l.name; }).join('|') === 'twin|twin||solo');
  check('by index', thisScene.getLayer(1).name === 'twin' && thisScene.getLayer(2).name === '');
  check('by id', thisScene.getLayerByID(12).name === 'twin' && thisScene.getLayerByID(13).name === '');
  check('filter by name', layers.filter(function(l) { return l.name === 'twin'; }).length === 2);
  check('find by name', layers.find(function(l) { return l.name === 'solo'; }) === thisLayer);
  // Called the same, they are still two layers: every call goes by the registered key.
  layers[1].visible = false;
  check('the second twin hid', layers[1].visible === false && layers[0].visible === true);
  check('by name the first twin', thisScene.getLayer('twin') === layers[0]);
  check('index of the nameless', thisScene.getLayerIndex(layers[2]) === 2);
  check('identity', thisScene.getLayer(0) === layers[0] && thisScene.getLayerByID(11) === layers[0]);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    EXPECT_TRUE(first->Visible());
    EXPECT_FALSE(second->Visible());
    EXPECT_TRUE(nameless->Visible());
}

namespace
{
// A group of two layers beside two more at the root, registered in that order.
struct GroupedLayers {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> runtime = MakeRuntimeWithScene(scene);
    std::shared_ptr<SceneNode>           group = Named("group"), x = Named("x"), y = Named("y"),
                                         a = Named("a"), b = Named("b");

    static std::shared_ptr<SceneNode> Named(const char* name) {
        return std::make_shared<SceneNode>(linalg::Vector3f::Zero(), linalg::Vector3f::Ones(),
                                           linalg::Vector3f::Zero(), name);
    }
    GroupedLayers() {
        scene.sceneGraph->AppendChild(group);
        group->AppendChild(x);
        group->AppendChild(y);
        scene.sceneGraph->AppendChild(a);
        scene.sceneGraph->AppendChild(b);
        for (const auto& node : { group, x, y, a, b }) runtime->RegisterNode(node->Name(), node.get());
    }
    static std::string Order(const SceneNode& parent) {
        std::string order;
        for (const auto& child : parent.GetChildren()) order += (order.empty() ? "" : ",") + child->Name();
        return order;
    }
};
} // namespace

// getLayer(i), getLayerCount, enumerateLayers, getLayerIndex and sortLayer are
// one order. A sort moves the layer in it, every view agrees, and the draw order
// among the layer's siblings follows.
TEST(ScriptRuntimeCompat, OneLayerOrderServesIndexCountEnumerationAndSorting) {
    GroupedLayers fixture;
    auto&         runtime = *fixture.runtime;
    runtime.ConsumeSceneGraphMutationFlag();
    const auto run = RunUpdateOn(runtime, "a", std::string(kCheckHelpers) + R"JS(
function order() { return thisScene.enumerateLayers().map(function(l) { return l.name; }).join(','); }
function agree() {
  for (var i = 0; i < thisScene.getLayerCount(); ++i) {
    var layer = thisScene.getLayer(i);
    if (thisScene.getLayerIndex(layer) !== i || thisScene.getLayerIndex(layer.name) !== i) return false;
  }
  return true;
}
export function update(value) {
  check('declared', order() === 'group,x,y,a,b' && agree());
  check('unknown', thisScene.getLayerIndex('nowhere') === -1 && thisScene.getLayerIndex(null) === -1);
  thisScene.sortLayer(thisScene.getLayer('b'), 0);
  check('to the front', order() === 'b,group,x,y,a' && thisScene.getLayer(0).name === 'b');
  check('enumerateLayers()[0]', thisScene.enumerateLayers()[0] === thisScene.getLayer('b') && agree());
  check('index follows', thisScene.getLayerIndex('b') === 0 && thisScene.getLayerIndex('group') === 1);
  thisScene.sortLayer('y', 0);
  check('inside a group', order() === 'y,b,group,x,a' && agree());
  thisScene.sortLayer('y', 3);
  check('back again', order() === 'b,group,x,y,a' && thisScene.getLayerIndex('y') === 3 && agree());
  thisScene.sortLayer('b', 99);
  check('clamped to the end', order() === 'group,x,y,a,b' && thisScene.getLayerIndex('b') === 4 && agree());
  thisScene.sortLayer('a', -5);
  check('clamped to the start', order() === 'a,group,x,y,b' && agree());
  thisScene.sortLayer('nowhere', 1);
  check('unknown layers are left alone', order() === 'a,group,x,y,b');
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    // Draw order is the order among siblings: the root and the group each keep
    // their layers in the order the sorts left them.
    EXPECT_EQ(GroupedLayers::Order(*fixture.scene.sceneGraph), "a,group,b");
    EXPECT_EQ(GroupedLayers::Order(*fixture.group), "x,y");
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
}

TEST(ScriptRuntimeCompat, SortingASiblingWithinItsGroupReordersOnlyThatGroup) {
    GroupedLayers fixture;
    auto&         runtime = *fixture.runtime;
    ASSERT_TRUE(runtime.SortLayer("y", 0));
    EXPECT_EQ(GroupedLayers::Order(*fixture.group), "y,x");
    EXPECT_EQ(GroupedLayers::Order(*fixture.scene.sceneGraph), "group,a,b");
    EXPECT_EQ(runtime.LayerNameAt(0), "y");
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    EXPECT_FALSE(runtime.SortLayer("y", 0)) << "already there: nothing changes";
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());
    EXPECT_FALSE(runtime.SortLayer("missing", 0));
}

// createLayer({ parent }) with a parent that names no layer leaves the new layer
// beside the layer that made it instead of moving it to the scene root.
TEST(ScriptRuntimeCompat, CreateLayerWithAParentThatNamesNoLayerStaysBesideItsCreator) {
    LineTemplateScene fixture;
    auto&             runtime = *fixture.runtime;
    auto group = std::make_shared<SceneNode>(linalg::Vector3f::Zero(), linalg::Vector3f::Ones(),
                                             linalg::Vector3f::Zero(), "group");
    fixture.scene.sceneGraph->AppendChild(group);
    runtime.RegisterNode("group", group.get());
    ASSERT_TRUE(runtime.SetNodeParent("owner", "group"));
    const auto run = RunUpdateOn(runtime, "owner", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  var byNumber = thisScene.createLayer({ image: 'models/line.json', parent: 5 });
  var byObject = thisScene.createLayer({ image: 'models/line.json', parent: {} });
  var byEmpty = thisScene.createLayer({ image: 'models/line.json', parent: '' });
  var byMissing = thisScene.createLayer({ image: 'models/line.json', parent: 'no such layer' });
  var byNull = thisScene.createLayer({ image: 'models/line.json', parent: null });
  [byNumber, byObject, byEmpty, byMissing, byNull].forEach(function(layer, index) {
    check('beside the creator ' + index, layer.getParent() === thisScene.getLayer('group'));
  });
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    EXPECT_EQ(group->GetChildren().size(), 6u) << "the owner and the five new layers";
    EXPECT_EQ(fixture.scene.sceneGraph->GetChildren().size(), 1u) << "nothing went to the root";
}

// ---------------------------------------------------------------------------
// Colour, text style, texture-animation rate, animation-layer identity, parallax.
// ---------------------------------------------------------------------------

// hsv2rgb does not clamp the saturation or wrap the hue: a saturation above 1
// gives components outside 0..1, a hue of 1 or more goes round the sextants
// again, and a negative hue is no sextant at all and gives black.
TEST(ScriptRuntimeCompat, WEColorHsv2RgbDoesNotClampSaturationOrWrapHue) {
    ScriptEngine engine;
    const auto result = EvaluateScalar(
        engine,
        R"JS(
import { hsv2rgb } from 'WEColor';
function near(a, b) { return Math.abs(a - b) < 1e-6; }
function is(c, x, y, z) { return near(c.x, x) && near(c.y, y) && near(c.z, z); }
export function update(value) {
  var ok = is(hsv2rgb(new Vec3(0.1, 1.5, 1)), 1, 0.4, -0.5) &&
           is(hsv2rgb(new Vec3(0.1, 0, 0.7)), 0.7, 0.7, 0.7) &&
           is(hsv2rgb(new Vec3(1.25, 1, 1)), hsv2rgb(new Vec3(0.25, 1, 1)).x,
                                             hsv2rgb(new Vec3(0.25, 1, 1)).y, hsv2rgb(new Vec3(0.25, 1, 1)).z) &&
           is(hsv2rgb(new Vec3(-0.25, 1, 1)), 0, 0, 0) &&
           is(hsv2rgb(new Vec3(0, 1, 1)), 1, 0, 0) && is(hsv2rgb(new Vec3(5 / 6, 1, 1)), 1, 0, 1);
  return ok ? 1 : 0;
}
)JS");
    EXPECT_FLOAT_EQ(result.getFloat(), 1.0f);
}

// horizontalalign is left, center or right and verticalalign top, center or
// bottom, as Wallpaper Engine registers them. Anything else is not an alignment:
// it changes nothing about the layer, and stays a plain property.
TEST(ScriptRuntimeCompat, TextAlignmentOnlyTakesTheWordsItIsDefinedFor) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    node->SetTranslate(linalg::Vector3f(10, 20, 0));
    runtime->RegisterNode("clock", node.get());
    runtime->RegisterTextLayer("clock", TextLayerState { .text = "x", .font_key = "Arial", .point_size = 20.0f,
                                                        .horizontal_align = "center", .vertical_align = "center" });
    const auto run = RunUpdateOn(*runtime, "clock", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  ['top', 'Left', 'banana', '', 'LEFT', 'middle'].forEach(function(word) {
    thisLayer.horizontalalign = word;
    check('horizontal ' + word, thisLayer.horizontalalign === 'center');
  });
  ['left', 'Top', 'banana', '', 'right'].forEach(function(word) {
    thisLayer.verticalalign = word;
    check('vertical ' + word, thisLayer.verticalalign === 'center');
  });
  thisLayer.horizontalalign = 'right';
  thisLayer.verticalalign = 'bottom';
  check('valid', thisLayer.horizontalalign === 'right' && thisLayer.verticalalign === 'bottom');
  thisLayer.horizontalalign = 'center';
  thisLayer.verticalalign = 'top';
  check('center is a word too', thisLayer.horizontalalign === 'center' && thisLayer.verticalalign === 'top');
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    const auto state = runtime->NodeTextState("clock");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->horizontal_align, "center");
    EXPECT_EQ(state->vertical_align, "top");
    // The card hangs by the words it ended on, none of them made up: centred across, so
    // nothing moves it sideways, and below the origin for `top`. The node stays put.
    EXPECT_TRUE(node->Translate().isApprox(linalg::Vector3f(10, 20, 0)));
    WaitForTextLayout(*runtime, "clock");
    EXPECT_FLOAT_EQ(runtime->NodeBoxCentre("clock").x(), 0.0f);
    EXPECT_LT(runtime->NodeBoxCentre("clock").y(), 0.0f);
}

// The size reads back as the float it is, so a script that reads it, adds a
// little and writes it again keeps moving it.
TEST(ScriptRuntimeCompat, TextPointSizeSurvivesAReadModifyWriteWithoutLosingPrecision) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("clock", node.get());
    runtime->RegisterTextLayer("clock", TextLayerState { .text = "x", .font_key = "Arial", .point_size = 1000.0f });
    const auto run = RunUpdateOn(*runtime, "clock", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  for (var i = 0; i < 100; ++i) thisLayer.pointsize += 0.0004;
  check('moved', thisLayer.pointsize > 1000.03);
  thisLayer.pointsize = 0.1;
  check('short', thisLayer.pointsize === 0.1);
  thisLayer.pointsize = 24;
  check('whole', thisLayer.pointsize === 24);
  thisLayer.pointsize = 12.5;
  check('exact', thisLayer.pointsize === 12.5);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// `rate` reads back what was written, whatever it was; the sheet advances only
// at a rate that is a positive speed, and holds its frame at any other.
TEST(ScriptRuntimeCompat, SpriteSheetRateReadsBackWhatWasWrittenAndOnlyAPositiveRateAdvancesIt) {
    SpriteSheetScene fixture;
    fixture.Draw(0.0);
    EXPECT_EQ(fixture.Run("anim.rate = -1; return anim.rate;"), -1.0f);
    EXPECT_EQ(fixture.Draw(1.0), 0) << "a negative rate holds the sheet";
    EXPECT_EQ(fixture.Run("return anim.rate;"), -1.0f) << "and the next read still says so";
    EXPECT_EQ(fixture.Run("anim.rate = 2000000; return anim.rate;"), 2000000.0f);
    EXPECT_EQ(fixture.Draw(1.0), 0) << "a rate beyond any speed a sheet shows holds it";
    EXPECT_EQ(fixture.Run("anim.rate = 0.25; return anim.rate;"), 0.25f);
    EXPECT_NE(fixture.Draw(0.8), 0) << "a positive rate runs it again from where it was";
}

// A script on animationlayers[i] gets the same animation-layer object however
// that layer is asked for, and it carries the layer's own name.
TEST(ScriptRuntimeCompat, AnimationLayersAreOneObjectPerLayerAndKnowTheirOwnName) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());
    std::vector<WPPuppetLayer::AnimationLayer> authored(2);
    for (std::size_t i = 0; i < authored.size(); ++i) {
        authored[i].id   = 7;
        authored[i].name = i == 0 ? "idle" : "wave";
    }
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    runtime->RegisterPuppetLayer("character", layer);
    runtime->RegisterNodeVisibility("character", node.get(), ResolveBoolSetting(*runtime, {
        { "value", true }, { "script", std::string(kCheckHelpers) + R"JS(
export function init(value) {
  check('bound to the second layer', thisObject.name === 'wave');
  check('by name', thisLayer.getAnimationLayer('wave') === thisObject);
  check('by number', thisLayer.getAnimationLayer(1) === thisObject);
  check('by numeral', thisLayer.getAnimationLayer('1') === thisObject);
  check('the other one', thisLayer.getAnimationLayer(0) === thisLayer.getAnimationLayer('idle'));
  check('its name', thisLayer.getAnimationLayer(0).name === 'idle');
  check('not each other', thisLayer.getAnimationLayer(0) !== thisObject);
  var ghost = thisLayer.getAnimationLayer('nothing');
  check('a name no layer has', ghost.name === 'nothing' && ghost === thisLayer.getAnimationLayer('nothing'));
  return value;
}
)JS" } }, "character", 1));
    runtime->Tick(0.01);
    for (const auto& error : runtime->scriptErrors()) ADD_FAILURE() << error;
}

namespace
{
// A group at (100, 200) scaled by two with a child at (10, 20) inside it, and
// a layer beside them for the script under test, on a 1920 by 1080 canvas.
struct PlacedLayers {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> runtime = MakeRuntimeWithScene(scene);
    std::shared_ptr<SceneNode>           group = Named("group"), child = Named("child"),
                                         reader = Named("reader");

    static std::shared_ptr<SceneNode> Named(const char* name) {
        return std::make_shared<SceneNode>(linalg::Vector3f::Zero(), linalg::Vector3f::Ones(),
                                           linalg::Vector3f::Zero(), name);
    }
    PlacedLayers() {
        group->SetTranslate(linalg::Vector3f(100, 200, 0));
        group->SetScale(linalg::Vector3f(2, 2, 1));
        child->SetTranslate(linalg::Vector3f(10, 20, 0));
        scene.sceneGraph->AppendChild(group);
        group->AppendChild(child);
        scene.sceneGraph->AppendChild(reader);
        for (const auto& node : { group, child, reader }) {
            runtime->RegisterNode(node->Name(), node.get());
        }
    }
};
} // namespace

// A script that places one layer by another asks it where it is in the scene:
// `getTransformMatrix()` answers the layer's world transform, and m[12], m[13]
// are its x and y in canvas units. Without the method the script threw in init,
// so the values it set up there were never assigned.
TEST(ScriptRuntimeCompat, LayerTransformMatrixPlacesAChildWhereItsParentsPutIt) {
    PlacedLayers fixture;
    auto&        runtime = *fixture.runtime;
    runtime.RegisterNodeTranslate("reader", fixture.reader.get(), ResolveVec3Setting(runtime, {
        {"value", "0 0 0"}, {"script", R"JS(
export function init() {
  const m = thisScene.getLayer('child').getTransformMatrix().m;
  shared.worldX = m[12];
  shared.worldY = m[13];
}
export function update() { return new Vec3(shared.worldX, shared.worldY, 0); }
)JS"}}, "reader"));

    runtime.Tick(0.01);
    // (10, 20) scaled by the group's 2, then moved to (100, 200).
    EXPECT_TRUE(runtime.NodeTranslate("reader").isApprox(linalg::Vector3f(120, 240, 0)))
        << runtime.NodeTranslate("reader").transpose();
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;
}

// The matrix is the layer's world transform as a Mat4: its parents' turns and
// scales are in it, a layer placed on its own is not affected by them, and a
// layer drawn through an effect (which draws from an identity of its own) still
// reports where it stands in the scene.
TEST(ScriptRuntimeCompat, LayerTransformMatrixCarriesTheTurnAndScaleOfItsParents) {
    PlacedLayers fixture;
    auto&        runtime = *fixture.runtime;
    fixture.group->SetRotation(linalg::Vector3f(0, 0, static_cast<float>(M_PI) / 2));
    auto pinned = PlacedLayers::Named("pinned");
    pinned->SetTranslate(linalg::Vector3f(50, 60, 0));
    pinned->SetIgnoreParentTransform(true);
    fixture.group->AppendChild(pinned);
    runtime.RegisterNode("pinned", pinned.get());
    auto drawn = PlacedLayers::Named("drawn");
    drawn->SetTranslate(linalg::Vector3f(5, 5, 0));
    drawn->SetRenderTransformOverride(linalg::Matrix4d::Identity());
    fixture.group->AppendChild(drawn);
    runtime.RegisterNode("drawn", drawn.get());

    const auto run = RunUpdateOn(runtime, "reader", std::string(kCheckHelpers) + R"JS(
function close(a, b) { return Math.abs(a - b) < 1e-3; }
function at(matrix, x, y, z) {
  const t = matrix.translation();
  return close(t.x, x) && close(t.y, y) && close(t.z, z);
}
export function update(value) {
  const matrix = thisScene.getLayer('child').getTransformMatrix();
  check('a Mat4', matrix instanceof Mat4 && matrix.m.length === 16);
  // (10, 20) scaled by 2 is (20, 40); a quarter turn makes it (-40, 20).
  check('position', at(matrix, 60, 220, 0));
  // Its own axes are the group's turned and doubled: x points up, y points left.
  check('x axis', close(matrix.m[0], 0) && close(matrix.m[1], 2) && close(matrix.m[2], 0));
  check('y axis', close(matrix.m[4], -2) && close(matrix.m[5], 0) && close(matrix.m[6], 0));
  check('z axis', close(matrix.m[10], 1) && close(matrix.m[15], 1));
  check('a point of its own', matrix.transformPoint(new Vec3(1, 0, 0)).equals(new Vec3(60, 222, 0)));
  check('the group', at(thisScene.getLayer('group').getTransformMatrix(), 100, 200, 0));
  // A layer without a parent transform answers its own placement.
  check('pinned', at(thisScene.getLayer('pinned').getTransformMatrix(), 50, 60, 0));
  // A layer with a render transform of its own is still where its parents put it.
  check('drawn', at(thisScene.getLayer('drawn').getTransformMatrix(), 100 - 10, 200 + 10, 0));
  // Each call answers a matrix of its own: writing to one changes nothing.
  matrix.m[12] = 0;
  check('a copy', at(thisScene.getLayer('child').getTransformMatrix(), 60, 220, 0));
  // A script that reassigns the global class does not change what the host builds.
  const real = Mat4;
  Mat4 = function() { throw new Error('the script replaced Mat4'); };
  const kept = thisScene.getLayer('child').getTransformMatrix();
  Mat4 = real;
  check('a reassigned Mat4', kept instanceof real && at(kept, 60, 220, 0));
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// A layer's place in the scene is asked for every frame (is the widget on the
// right half of the canvas?), so it has to follow the layer: after a move of the
// layer itself or of what it hangs from, and right after the script wrote it.
TEST(ScriptRuntimeCompat, LayerTransformMatrixFollowsALayerWhereverItMoves) {
    PlacedLayers fixture;
    auto&        runtime = *fixture.runtime;
    runtime.RegisterNodeTranslate("reader", fixture.reader.get(), ResolveVec3Setting(runtime, {
        {"value", "0 0 0"}, {"script", R"JS(
export function update() {
  const onTheRight = thisScene.getLayer('child').getTransformMatrix().m[12] > engine.canvasSize.x / 2;
  return new Vec3(onTheRight ? 1 : -1, 0, 0);
}
)JS"}}, "reader"));

    runtime.Tick(0.01);
    EXPECT_FLOAT_EQ(runtime.NodeTranslate("reader").x(), -1.0f) << "the child sits at x = 120";
    runtime.SetNodeTranslate("group", linalg::Vector3f(1000, 200, 0));
    runtime.Tick(0.01);
    EXPECT_FLOAT_EQ(runtime.NodeTranslate("reader").x(), 1.0f) << "the child sits at x = 1020";
    for (const auto& error : runtime.scriptErrors()) ADD_FAILURE() << error;

    const auto run = RunUpdateOn(runtime, "reader", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  thisLayer.origin = new Vec3(1500, 300, 0);
  const own = thisLayer.getTransformMatrix();
  check('after a write', own.m[12] === 1500 && own.m[13] === 300);
  thisScene.getLayer('group').scale = new Vec3(1, 1, 1);
  check('after a parent changes', thisScene.getLayer('child').getTransformMatrix().m[12] === 1010);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

// A layer the scene has no node for — a sound layer, a name nothing carries —
// is not anywhere, and asking where it is must not stop the script: it answers
// the identity, as the matrix of a layer that was never moved.
TEST(ScriptRuntimeCompat, LayerTransformMatrixOfALayerWithoutANodeIsTheIdentity) {
    PlacedLayers fixture;
    const auto   run = RunUpdateOn(*fixture.runtime, "reader", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  const matrix = thisScene.getLayer('nowhere').getTransformMatrix();
  check('a Mat4', matrix instanceof Mat4);
  check('identity', matrix.m.join(',') === new Mat4().m.join(','));
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
}

namespace
{
// `owner` draws a card through an effect pass: its own node has no parallax
// record, the pass has one, and `kid` below it and `beside` next to it have theirs.
struct EffectLayerScene {
    CardTemplateScene          card;
    WPShaderValueUpdater&      updater = *static_cast<WPShaderValueUpdater*>(card.scene.shaderValueUpdater.get());
    std::shared_ptr<SceneNode> pass    = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode> kid     = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode> beside  = std::make_shared<SceneNode>();

    EffectLayerScene() {
        const auto depth = [](SceneNode* layer) {
            WPShaderValueData data;
            data.parallaxDepth  = { 0.5f, 0.25f };
            data.parallax_layer = layer;
            return data;
        };
        updater.SetNodeData(pass.get(), depth(card.owner.get()));
        card.owner->AppendChild(kid);
        card.scene.sceneGraph->AppendChild(beside);
        card.runtime->RegisterNode("kid", kid.get());
        card.runtime->RegisterNode("beside", beside.get());
        updater.SetNodeData(kid.get(), depth(nullptr));
        updater.SetNodeData(beside.get(), depth(nullptr));
    }
    std::array<float, 2> Depth(SceneNode& node) const { return updater.NodeParallaxDepth(&node); }
};
} // namespace

// parallaxDepth is what is drawn: for a layer drawn through effects that is its
// passes' depth. A write reaches the layer's passes and the layers below it, and
// not the layers beside it. A layer that starts or stops following the cursor
// asks for a new render graph, because the one built before has it standing still.
TEST(ScriptRuntimeCompat, ParallaxDepthIsTheDepthOfWhatIsDrawnAndAWriteReachesTheLayersBelow) {
    EffectLayerScene fixture;
    auto&            runtime = *fixture.card.runtime;
    runtime.ConsumeSceneGraphMutationFlag();
    auto run = RunUpdateOn(runtime, "owner", std::string(kCheckHelpers) + R"JS(
export function update(value) {
  check('the passes carry it', thisLayer.parallaxDepth.x === 0.5 && thisLayer.parallaxDepth.y === 0.25);
  thisLayer.parallaxDepth = new Vec2(2, 3);
  check('read back', thisLayer.parallaxDepth.x === 2 && thisLayer.parallaxDepth.y === 3);
  check('a layer below', thisScene.getLayer('kid').parallaxDepth.x === 2);
  check('a layer beside', thisScene.getLayer('beside').parallaxDepth.x === 0.5);
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    EXPECT_EQ(fixture.Depth(*fixture.pass), (std::array<float, 2> { 2.0f, 3.0f }));
    EXPECT_EQ(fixture.Depth(*fixture.kid), (std::array<float, 2> { 2.0f, 3.0f }));
    EXPECT_EQ(fixture.Depth(*fixture.beside), (std::array<float, 2> { 0.5f, 0.25f }));
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag()) << "following the cursor before and after";

    run = RunUpdateOn(runtime, "owner", "export function update(value) { thisLayer.parallaxDepth = new Vec2(0, 0); return 1; }");
    EXPECT_SCRIPT_PASSES(run);
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag()) << "it stopped following the cursor";
    run = RunUpdateOn(runtime, "owner", "export function update(value) { thisLayer.parallaxDepth = new Vec2(0, 0); return 1; }");
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag()) << "still not following";
    run = RunUpdateOn(runtime, "owner", "export function update(value) { thisLayer.parallaxDepth = new Vec2(0, 1); return 1; }");
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag()) << "and following again, on one axis";
}

namespace
{
// A scene whose parallax follows the cursor, with the card layers scripts make.
struct ParallaxCardScene {
    CardTemplateScene          card;
    WPShaderValueUpdater&      updater = *static_cast<WPShaderValueUpdater*>(card.scene.shaderValueUpdater.get());
    std::shared_ptr<SceneCamera> camera = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
    std::shared_ptr<SceneNode>   camera_node = std::make_shared<SceneNode>();

    ParallaxCardScene() {
        card.scene.ortho[0] = 1920;
        card.scene.ortho[1] = 1080;
        camera_node->SetTranslate(linalg::Vector3f(960, 540, 0));
        camera->AttatchNode(camera_node);
        card.scene.activeCamera = camera.get();
        updater.SetCameraParallax({ .enable = true, .amount = 0.5f, .delay = 0.0f,
                                    .mouseinfluence = 0.5f, .canvas_scene = true });
        updater.MouseInput(1.0, 0.0);  // the cursor well away from the centre
        card.scene.frameTime = 10.0;
        updater.FrameBegin();
    }
    ~ParallaxCardScene() { card.scene.activeCamera = nullptr; }

    // How far the cursor's parallax draws the layer from where its node puts it.
    float Displacement(SceneNode& node) {
        updater.InitUniforms(&node, [](std::string_view name) { return name == "g_ModelMatrix"; });
        sprite_map_t sprites;
        ShaderValue  value;
        updater.UpdateUniforms(&node, sprites, [&](std::string_view name, const ShaderValue& v) {
            if (name == "g_ModelMatrix") value = v;
        });
        node.UpdateTrans();
        const auto model = node.ModelTrans();
        return linalg::Vector2f(value[12] - static_cast<float>(model(0, 3)),
                               value[13] - static_cast<float>(model(1, 3))).norm();
    }
    SceneNode* Created(std::size_t index) {
        std::vector<SceneNode*> made;
        for (const auto& child : card.scene.sceneGraph->GetChildren()) {
            if (child.get() != card.owner.get()) made.push_back(child.get());
        }
        return index < made.size() ? made[index] : nullptr;
    }
};
} // namespace

// What a script writes to parallaxDepth changes what is drawn: a layer given a
// depth is displaced by the cursor, one given none or zero is not.
TEST(ScriptRuntimeCompat, ACreatedLayersParallaxDepthDecidesWhetherTheCursorMovesIt) {
    ParallaxCardScene fixture;
    const auto        run = RunUpdateOn(*fixture.card.runtime, "owner", R"JS(
export function update(value) {
  thisScene.createLayer({ image: 'models/card.json', parallaxDepth: new Vec2(1, 1) });
  thisScene.createLayer({ image: 'models/card.json', parallaxDepth: new Vec2(0, 0) });
  thisScene.createLayer('models/card.json');
  return 1;
}
)JS");
    EXPECT_SCRIPT_PASSES(run);
    ASSERT_NE(fixture.Created(2), nullptr);
    EXPECT_GT(fixture.Displacement(*fixture.Created(0)), 1.0f) << "a depth of one follows the cursor";
    EXPECT_LT(fixture.Displacement(*fixture.Created(1)), 1e-3f) << "a depth of zero does not";
    EXPECT_LT(fixture.Displacement(*fixture.Created(2)), 1e-3f) << "no depth asked for, none given";
}


// ---- host limits on the paths that run script code outside `update` ----------------

ScriptLimits QuickLimits() {
    ScriptLimits limits;
    limits.call_budget_ms     = 30.0;
    limits.creation_budget_ms = 60.0;
    return limits;
}

double MillisecondsOf(std::chrono::steady_clock::time_point since) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - since).count();
}

TEST(ScriptHostLimits, AGetterOnTheReturnedValueIsHeldToTheCallBudget) {
    ScriptEngine engine;
    engine.SetLimits(QuickLimits());
    const auto start  = std::chrono::steady_clock::now();
    const auto result = engine.Evaluate(R"JS(
export function update(value) { return { get x() { for (;;) {} } }; }
)JS", {}, DynamicValue(linalg::Vector3f(1, 2, 3)), {});
    ASSERT_NE(result, nullptr);
    EXPECT_LT(MillisecondsOf(start), 2000.0) << "an endless getter must be interrupted";
}

TEST(ScriptHostLimits, ASetterOnTheScriptParametersIsHeldToTheCallBudget) {
    ScriptEngine engine;
    engine.SetLimits(QuickLimits());
    DynamicValue parameter(1.0f);
    const auto   start  = std::chrono::steady_clock::now();
    const auto   result = engine.Evaluate(R"JS(
Object.defineProperty(scriptProperties, 'p', { set: function () { for (;;) {} }, get: function () { return 0; },
                                               configurable: true });
export function update(value) { return 2; }
)JS", { { "p", &parameter } }, DynamicValue(0.0f), {});
    ASSERT_NE(result, nullptr);
    EXPECT_LT(MillisecondsOf(start), 2000.0) << "an endless setter must be interrupted";
}

TEST(ScriptHostLimits, RunawayRecursionOnASecondaryThreadIsAnErrorNotACrash) {
    ScriptEngine engine;
    DynamicValue initial(0.0f);
    std::unique_ptr<PropertyScriptProgram> program;
    program = engine.CreatePropertyScriptProgram(nullptr, R"JS(
function down(n) { return down(n + 1) + 1; }
export function update(value) { try { down(0); } catch (e) { return 7; } return 1; }
)JS", "", {}, initial, {});
    ASSERT_NE(program, nullptr);
    double answer = 0.0;
    std::thread worker([&] {
        const auto result = program->Evaluate({}, DynamicValue(0.0f));
        if (result != nullptr) answer = result->getFloat();
    });
    worker.join();
    EXPECT_FLOAT_EQ(static_cast<float>(answer), 7.0f);
}


TEST(ScriptHostLimits, ExportAfterUnicodeWhitespaceAtTheStartOfALineIsRemoved) {
    ScriptEngine engine;
    EXPECT_FLOAT_EQ(EvaluateScalar(engine, " export function update(value) { return 5; }\n").getFloat(), 5.0f);
    EXPECT_FLOAT_EQ(EvaluateScalar(engine, "var a = 1;\n﻿export function update(value) { return 6; }\n").getFloat(), 6.0f);
    EXPECT_FLOAT_EQ(EvaluateScalar(engine, "var a = 1;\n  export function update(value) { return 8; }\n").getFloat(), 8.0f);
}


TEST(ScriptHostLimits, ARecordedErrorTextIsCutBetweenCharacters) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    auto  program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function update(value) { throw new Error('€'.repeat(2000)); }
)JS", "", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_EQ(runtime->scriptErrorCount(), 1u);
    const auto& text = runtime->scriptErrors().front();
    EXPECT_LE(text.size(), std::string("update: ").size() + 1024u);
    EXPECT_NO_THROW((void)nlohmann::json(text).dump()) << "the text must stay valid UTF-8";
}

TEST(ScriptHostLimits, ACursorEventHandsEveryProgramItsOwnWorldPosition) {
    ScriptEngine engine;
    DynamicValue initial(0.0f);
    auto         editor = engine.CreatePropertyScriptProgram(nullptr, R"JS(
export function cursorClick(event) { event.worldPosition.x = 999; }
)JS", "", {}, initial, {});
    auto reader = engine.CreatePropertyScriptProgram(nullptr, R"JS(
export function cursorClick(event) { globalThis.seen = event.worldPosition.x * 1000 + input.cursorWorldPosition.x; }
export function update(value) { return globalThis.seen; }
)JS", "", {}, initial, {});
    ASSERT_NE(editor, nullptr);
    ASSERT_NE(reader, nullptr);
    ScriptHostContext host;
    host.cursor_world_position = linalg::Vector3f(5, 6, 0);
    editor->DispatchCursorClick(host);
    reader->DispatchCursorClick(host);
    const auto seen = reader->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(seen, nullptr);
    EXPECT_FLOAT_EQ(seen->getFloat(), 5005.0f);
}

TEST(ScriptHostLimits, AnEndedListenerRemovedByAnEarlierOneDoesNotFire) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    auto node    = std::make_shared<SceneNode>();
    auto probe   = std::make_shared<SceneNode>();
    runtime->RegisterNode("character", node.get());
    runtime->RegisterNode("probe", probe.get());
    std::vector<WPPuppetLayer::AnimationLayer> authored(1);
    authored[0].id   = 7;
    authored[0].name = "siche";
    WPPuppetLayer layer(MakeSingleShotPuppet());
    layer.prepared(authored);
    runtime->RegisterPuppetLayer("character", layer);
    runtime->RegisterNodeVisibility("character", node.get(), ResolveBoolSetting(*runtime, {
        { "value", true }, { "script", R"JS(
export function init(value) {
  var animation = thisLayer.getAnimationLayer('siche');
  var second = function() { thisScene.getLayer('probe').origin = new Vec3(1, 0, 0); };
  animation.addEndedCallback(function() { animation.removeEndedCallback(second); });
  animation.addEndedCallback(second);
  return value;
}
)JS" } }, "character"));
    runtime->Tick(0.01);
    WPPuppetLayer render_copy = layer;
    render_copy.genFrame(0.0);
    render_copy.genFrame(2.0);
    runtime->Tick(0.01);
    EXPECT_FLOAT_EQ(probe->Translate().x(), 0.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}


TEST(ScriptHostLimits, ThousandNestedCallsWorkAndRunawayRecursionDoesNot) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    auto  program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
function nest(depth, a, b, c) {
  var x = 1, y = 2, z = 3, w = 4, v = 5, u = 6, t = 7;
  return depth === 0 ? 0 : 1 + nest(depth - 1, a + x, b + y, c + z);
}
function runaway(n) { return runaway(n + 1) + 1; }
export function update(value) {
  var caught = 0;
  try { runaway(0); } catch (e) { caught = 1; }
  return nest(1000, 0, 0, 0) + caught * 10000;
}
)JS", "", {}, DynamicValue(0.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 11000.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(ScriptHostLimits, AnEndlessUpdateIsInterruptedAndThreeInARowSwitchTheProgramOff) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function update(value) { for (;;) {} }
)JS", "looper", {}, DynamicValue(1.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    for (int tick = 0; tick < 3; ++tick) {
        ASSERT_TRUE(program->Valid()) << "interrupted " << tick << " times so far";
        const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(1.0f));
        ASSERT_NE(result, nullptr);
        EXPECT_FLOAT_EQ(result->getFloat(), 1.0f) << "the property keeps its value";
    }
    EXPECT_FALSE(program->Valid());
    // Three interrupted calls and one error naming the program.
    EXPECT_EQ(runtime->scriptErrorCount(), 4u);
}

TEST(ScriptHostLimits, HugeAllocationAndASelfRearmingThrowingTimerAreErrorsNotHangs) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    auto memory = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function update(value) {
  var keep = [];
  for (;;) keep.push(new Array(1000000).fill(1));
}
)JS", "", {}, DynamicValue(1.0f), runtime->hostContext());
    ASSERT_NE(memory, nullptr);
    memory->Evaluate(runtime->hostContext(), DynamicValue(1.0f));
    EXPECT_TRUE(memory->Valid());
    EXPECT_GE(runtime->scriptErrorCount(), 1u);

    auto timer = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
function again() { engine.setTimeout(again, 0); throw new Error('again'); }
engine.setTimeout(again, 0);
export function update(value) { return value; }
)JS", "", {}, DynamicValue(1.0f), runtime->hostContext());
    ASSERT_NE(timer, nullptr);
    const auto before = runtime->scriptErrorCount();
    for (int tick = 0; tick < 5; ++tick) timer->Evaluate(runtime->hostContext(), DynamicValue(1.0f));
    EXPECT_EQ(runtime->scriptErrorCount() - before, 5u) << "one error per timer pass";
}


TEST(ScriptHostLimits, AScriptCannotPutItsOwnCodeInsideTheHostsRefreshOfEngine) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    auto hostile = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
Object.defineProperty(engine, 'frametime', { set: function () { for (;;) {} }, configurable: true });
export function update(value) { return 9; }
)JS", "", {}, DynamicValue(1.0f), runtime->hostContext());
    EXPECT_EQ(hostile, nullptr) << "the engine's fields stay data properties";
    EXPECT_GE(runtime->scriptErrorCount(), 1u);

    auto bystander = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function update(value) { return engine.frametime; }
)JS", "", {}, DynamicValue(1.0f), runtime->hostContext());
    ASSERT_NE(bystander, nullptr);
    ScriptHostContext host = runtime->hostContext();
    host.frame_time        = 0.25;
    const auto start       = std::chrono::steady_clock::now();
    const auto answer      = bystander->Evaluate(host, DynamicValue(1.0f));
    ASSERT_NE(answer, nullptr);
    EXPECT_FLOAT_EQ(answer->getFloat(), 0.25f);
    EXPECT_LT(MillisecondsOf(start), 1000.0);
}


// ---- more hostile scripts: blocking calls, backtracking, queued jobs, frozen host objects ----

namespace {
// Runs one `update` that never finishes in time through a value program and answers
// how many milliseconds the host call took (negative when the program was refused).
double TimeOneHostileUpdate(const char* script) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(), script, "", {}, DynamicValue(1.0f), runtime->hostContext());
    if (program == nullptr) return -1.0;
    const auto start = std::chrono::steady_clock::now();
    program->Evaluate(runtime->hostContext(), DynamicValue(1.0f));
    return MillisecondsOf(start);
}
} // namespace

TEST(ScriptHostLimits, AtomicsWaitCannotBlockTheHost) {
    const double ms = TimeOneHostileUpdate(R"JS(
export function update(value) {
  try { Atomics.wait(new Int32Array(new SharedArrayBuffer(8)), 0, 0, 5000); } catch (e) {}
  return 1;
}
)JS");
    EXPECT_GE(ms, 0.0);
    EXPECT_LT(ms, 1000.0);
}

TEST(ScriptHostLimits, RegexBacktrackingIsInterrupted) {
    const double ms = TimeOneHostileUpdate(R"JS(
export function update(value) { /(a+)+b/.test('a'.repeat(60)); return 1; }
)JS");
    EXPECT_GE(ms, 0.0);
    EXPECT_LT(ms, 1000.0);
}

TEST(ScriptHostLimits, AnEndlessPromiseJobIsInterruptedAndCounted) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function update(value) { Promise.resolve().then(function () { for (;;) {} }); return 1; }
)JS", "jobber", {}, DynamicValue(1.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    const auto start = std::chrono::steady_clock::now();
    for (int tick = 0; tick < 3; ++tick) program->Evaluate(runtime->hostContext(), DynamicValue(1.0f));
    EXPECT_LT(MillisecondsOf(start), 2000.0);
    EXPECT_FALSE(program->Valid()) << "three interrupted calls in a row switch the program off";
}

TEST(ScriptHostLimits, AFrozenEngineDoesNotStopTheHostsRefresh) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    auto  hostile = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
Object.freeze(engine);
Object.freeze(input);
export function update(value) { return 1; }
)JS", "", {}, DynamicValue(1.0f), runtime->hostContext());
    auto reader = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
export function update(value) { return engine.frametime; }
)JS", "", {}, DynamicValue(1.0f), runtime->hostContext());
    ASSERT_NE(reader, nullptr);
    ScriptHostContext host = runtime->hostContext();
    host.frame_time        = 0.5;
    const auto errors      = runtime->scriptErrorCount();
    const auto answer      = reader->Evaluate(host, DynamicValue(1.0f));
    ASSERT_NE(answer, nullptr);
    EXPECT_FLOAT_EQ(answer->getFloat(), 0.5f);
    EXPECT_EQ(runtime->scriptErrorCount(), errors);
}

TEST(ScriptHostLimits, AScriptThatReplacesTheInputVectorsDoesNotBreakCursorEvents) {
    ScriptEngine engine;
    DynamicValue initial(0.0f);
    auto         vandal = engine.CreatePropertyScriptProgram(nullptr, R"JS(
input.cursorWorldPosition = 5;
input.cursorPosition = null;
export function update(value) { return 1; }
)JS", "", {}, initial, {});
    auto reader = engine.CreatePropertyScriptProgram(nullptr, R"JS(
export function cursorClick(event) { globalThis.seen = event.worldPosition.x * 100 + event.normalizedPosition.x; }
export function update(value) { return globalThis.seen; }
)JS", "", {}, initial, {});
    ASSERT_NE(reader, nullptr);
    ScriptHostContext host;
    host.cursor_world_position      = linalg::Vector3f(3, 4, 0);
    host.cursor_normalized_position = linalg::Vector2f(0.5f, 0.25f);
    if (vandal != nullptr) vandal->Evaluate(host, DynamicValue(0.0f));
    reader->DispatchCursorClick(host);
    const auto seen = reader->Evaluate(host, DynamicValue(0.0f));
    ASSERT_NE(seen, nullptr);
    EXPECT_FLOAT_EQ(seen->getFloat(), 300.5f);
}

TEST(ScriptHostLimits, AnEndlessTopLevelIsRefusedInTimeAndLeavesOtherProgramsAlone) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    const auto start   = std::chrono::steady_clock::now();
    auto       endless = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(), "for (;;) {}\nexport function update(value) { return 2; }", "", {},
        DynamicValue(1.0f), runtime->hostContext());
    EXPECT_EQ(endless, nullptr);
    EXPECT_LT(MillisecondsOf(start), 2000.0);
    EXPECT_GE(runtime->scriptErrorCount(), 1u);
    auto fine = runtime->scriptEngine().CreatePropertyScriptProgram(
        runtime.get(), "export function update(value) { return 3; }", "", {}, DynamicValue(1.0f),
        runtime->hostContext());
    ASSERT_NE(fine, nullptr);
    const auto answer = fine->Evaluate(runtime->hostContext(), DynamicValue(1.0f));
    ASSERT_NE(answer, nullptr);
    EXPECT_FLOAT_EQ(answer->getFloat(), 3.0f);
}

TEST(ScriptHostLimits, AnEndlessTimerCallbackIsInterruptedOnceAndTheNextEvaluationRunsNormally) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
engine.setTimeout(function () { for (;;) {} }, 0);
export function update(value) { return value + 1; }
)JS", "", {}, DynamicValue(1.0f), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    const auto first = program->Evaluate(runtime->hostContext(), DynamicValue(1.0f));
    ASSERT_NE(first, nullptr);
    EXPECT_EQ(runtime->scriptErrorCount(), 1u) << "the interrupted pass is one error";
    EXPECT_TRUE(program->Valid());
    const auto second = program->Evaluate(runtime->hostContext(), DynamicValue(1.0f));
    ASSERT_NE(second, nullptr);
    EXPECT_FLOAT_EQ(second->getFloat(), 2.0f);
    EXPECT_EQ(runtime->scriptErrorCount(), 1u) << "the timer that was interrupted is gone";
}

TEST(ScriptHostLimits, AnEndlessSceneInitAndAnEndlessListenerAreInterruptedInTime) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    const auto start = std::chrono::steady_clock::now();
    runtime->RegisterSceneScript("export function init() { for (;;) {} }", "");
    runtime->RegisterSceneScript("engine.on('update', function () { for (;;) {} });", "");
    runtime->Tick(0.016);
    EXPECT_LT(MillisecondsOf(start), 3000.0);
    EXPECT_GE(runtime->scriptErrorCount(), 2u);
}

TEST(ScriptHostLimits, ADynamicImportCannotLoadAnything) {
    ScriptEngine engine;
    EXPECT_FLOAT_EQ(EvaluateScalar(engine, R"JS(
var state = 0;
try { import('os').then(function () { state = 2; }, function () { state = 1; }); } catch (e) { state = 3; }
export function update(value) { return state === 2 ? 99 : 5; }
)JS").getFloat(), 5.0f);
}

TEST(ScriptHostLimits, AnErrorObjectThatRunsCodeWhenReadIsHeldToTheCallBudget) {
    Scene scene;
    auto  runtime = MakeRuntimeWithScene(scene);
    runtime->scriptEngine().SetLimits(QuickLimits());
    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(), R"JS(
// The host copies the value it hands to `update` with this method; a throw out of it
// reaches the host as an error object the script made.
Vec3.prototype.copy = function () { throw { get message() { for (;;) {} }, get stack() { for (;;) {} } }; };
export function update(value) { return value; }
)JS", "", {}, DynamicValue(linalg::Vector3f(1, 2, 3)), runtime->hostContext());
    ASSERT_NE(program, nullptr);
    const auto start = std::chrono::steady_clock::now();
    const auto answer = program->Evaluate(runtime->hostContext(), DynamicValue(linalg::Vector3f(1, 2, 3)));
    EXPECT_LT(MillisecondsOf(start), 2000.0) << "reading the error must be interrupted too";
    ASSERT_NE(answer, nullptr);
    EXPECT_GE(runtime->scriptErrorCount(), 1u);
}

} // namespace
} // namespace wallpaper
