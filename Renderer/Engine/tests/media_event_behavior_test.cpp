// Media playback events, video playback clocks and settings bound to project properties, as a
// script and the runtime see them.
//
// Headless and file-free: runtimes are built in memory and nodes are plain SceneNode objects
// that the tests keep alive themselves.

#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/SceneNode.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace wallpaper
{
namespace
{

constexpr double kFrame = 1.0 / 60.0;
constexpr float  kNaN = std::numeric_limits<float>::quiet_NaN();

std::unique_ptr<SceneRuntimeContext> MakeRuntime(int w = 0, int h = 0,
                                                 ProjectProperties properties = {})
{
    return CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = w,
                                                            .canvas_height = h,
                                                            .project_properties = std::move(properties) });
}

std::shared_ptr<SceneNode> Register(SceneRuntimeContext& rt, const std::string& name,
                                    bool visible = true)
{
    auto node = std::make_shared<SceneNode>();
    node->SetVisible(visible);
    rt.RegisterNode(name, node.get());
    return node;
}

// ---- media events ---------------------------------------------------------------------

// Two hidden probe layers a script can light.
struct Probes {
    std::unique_ptr<SceneRuntimeContext> rt = MakeRuntime(3840, 2160);
    std::shared_ptr<SceneNode>           a = Register(*rt, "probeA", false);
    std::shared_ptr<SceneNode>           b = Register(*rt, "probeB", false);

    bool Lit(const char* name) const { return rt->NodeVisible(name); }
};

constexpr const char* kStateScript = R"js(
    function mediaPlaybackChanged(event) {
        if (event.state === MediaPlaybackEvent.PLAYBACK_PLAYING) {
            scene.getObject('probeA').visible = true;
        }
    }
    scene.on('mediaPlaybackChanged', function (event) {
        if (event.state === 1) { scene.getObject('probeB').visible = true; }
    });
)js";

constexpr const char* kAlwaysScript = R"js(
    function mediaPlaybackChanged(event) { scene.getObject('probeA').visible = true; }
    scene.on('mediaPlaybackChanged', function (event) { scene.getObject('probeB').visible = true; });
)js";

std::string MediaJson(const char* type, int state)
{
    return std::string("{\"type\":\"") + type + "\",\"state\":" + std::to_string(state) + "}";
}

TEST(MediaEventScripts, APlayingEventReachesTheTopLevelHandlerAndTheSceneListener)
{
    Probes p;
    p.rt->RegisterSceneScript(kStateScript, "");
    ASSERT_EQ(p.rt->sceneScriptCount(), 1u);
    p.rt->SetMediaIntegrationEnabled(true);
    ASSERT_FALSE(p.Lit("probeA"));
    ASSERT_FALSE(p.Lit("probeB"));

    p.rt->DispatchMediaEventJson(MediaJson("mediaPlaybackChanged", 1));
    EXPECT_TRUE(p.Lit("probeA")) << "top-level handler or the PLAYBACK_PLAYING constant";
    EXPECT_TRUE(p.Lit("probeB")) << "scene.on listener or a numeric state";
    EXPECT_EQ(p.rt->scriptErrorCount(), 0u);
}

TEST(MediaEventScripts, PausedAndStoppedAreNotPlaying)
{
    Probes p;
    p.rt->RegisterSceneScript(kStateScript, "");
    p.rt->SetMediaIntegrationEnabled(true);

    p.rt->DispatchMediaEventJson(MediaJson("mediaPlaybackChanged", 2));
    p.rt->DispatchMediaEventJson(MediaJson("mediaPlaybackChanged", 0));
    EXPECT_FALSE(p.Lit("probeA"));
    EXPECT_FALSE(p.Lit("probeB"));
    EXPECT_EQ(p.rt->scriptErrorCount(), 0u);
}

TEST(MediaEventScripts, AnotherEventNameIsNotDeliveredToThePlaybackHandlers)
{
    Probes p;
    p.rt->RegisterSceneScript(kStateScript, "");
    p.rt->SetMediaIntegrationEnabled(true);

    p.rt->DispatchMediaEventJson(MediaJson("somethingElseChanged", 1));
    EXPECT_FALSE(p.Lit("probeA"));
    EXPECT_FALSE(p.Lit("probeB"));
    EXPECT_EQ(p.rt->scriptErrorCount(), 0u);
}

TEST(MediaEventScripts, AnUnreadablePayloadIsRecordedAsAnError)
{
    Probes p;
    p.rt->RegisterSceneScript(kStateScript, "");
    p.rt->SetMediaIntegrationEnabled(true);

    p.rt->DispatchMediaEventJson("not json");
    EXPECT_FALSE(p.Lit("probeA"));
    EXPECT_FALSE(p.Lit("probeB"));
    EXPECT_GE(p.rt->scriptErrorCount(), 1u);
}

TEST(MediaEventScripts, ADisabledIntegrationDropsTheEvent)
{
    Probes p;
    p.rt->RegisterSceneScript(kAlwaysScript, "");
    p.rt->SetMediaIntegrationEnabled(false);
    p.rt->DispatchMediaEventJson(MediaJson("mediaPlaybackChanged", 1));
    EXPECT_FALSE(p.Lit("probeA"));
    EXPECT_FALSE(p.Lit("probeB"));
    EXPECT_EQ(p.rt->scriptErrorCount(), 0u);

    // Turning it on later does not replay what was dropped.
    p.rt->SetMediaIntegrationEnabled(true);
    EXPECT_FALSE(p.Lit("probeA"));
    EXPECT_FALSE(p.Lit("probeB"));
}

TEST(MediaEventScripts, TheIntegrationIsOffUntilSomeoneTurnsItOn)
{
    Probes p;
    p.rt->RegisterSceneScript(kAlwaysScript, "");
    EXPECT_FALSE(p.rt->MediaIntegrationEnabled());

    p.rt->DispatchMediaEventJson(MediaJson("mediaPlaybackChanged", 1));
    EXPECT_FALSE(p.Lit("probeA"));
    EXPECT_FALSE(p.Lit("probeB"));
    EXPECT_EQ(p.rt->scriptErrorCount(), 0u);
}

// ---- video playback clocks ----------------------------------------------------------------

TEST(VideoPlaybackClocks, PauseSeekAndRateOfASingleKey)
{
    auto rt = MakeRuntime();
    const std::string key = "textures/a.mp4";
    rt->RegisterNodeVideoTexture("movie", key);
    rt->SetVideoTextureDuration(key, 3.0);

    EXPECT_TRUE(rt->PauseNodeVideoTexture("movie"));
    EXPECT_TRUE(rt->SetNodeVideoTextureCurrentTime("movie", 7.5));
    EXPECT_TRUE(rt->SetNodeVideoTextureRate("movie", -2.0f));

    const auto state = rt->ResolveVideoPlaybackState(key, 99.0);
    EXPECT_TRUE(state.paused);
    EXPECT_FLOAT_EQ(state.rate, 0.0f) << "a negative rate is stored as zero";
    EXPECT_DOUBLE_EQ(state.scene_elapsed_seconds, 1.5) << "7.5 wraps at a 3 s duration";

    // The end of the clip wraps to its start; negative and non-finite times become zero.
    EXPECT_TRUE(rt->SetNodeVideoTextureCurrentTime("movie", 3.0));
    EXPECT_DOUBLE_EQ(rt->NodeVideoTextureCurrentTime("movie"), 0.0);
    EXPECT_DOUBLE_EQ(rt->ResolveVideoPlaybackState(key, 99.0).scene_elapsed_seconds, 0.0);
    EXPECT_TRUE(rt->SetNodeVideoTextureCurrentTime("movie", 2.0));
    EXPECT_DOUBLE_EQ(rt->NodeVideoTextureCurrentTime("movie"), 2.0);
    EXPECT_TRUE(rt->SetNodeVideoTextureCurrentTime("movie", -4.0));
    EXPECT_DOUBLE_EQ(rt->NodeVideoTextureCurrentTime("movie"), 0.0);
    EXPECT_TRUE(rt->SetNodeVideoTextureCurrentTime("movie", 2.0));
    EXPECT_TRUE(rt->SetNodeVideoTextureCurrentTime("movie", std::numeric_limits<double>::quiet_NaN()));
    EXPECT_DOUBLE_EQ(rt->NodeVideoTextureCurrentTime("movie"), 0.0);

    // Rates: a positive finite one is kept, a NaN one becomes zero.
    EXPECT_TRUE(rt->SetNodeVideoTextureRate("movie", 0.25f));
    EXPECT_FLOAT_EQ(rt->ResolveVideoPlaybackState(key, 0.0).rate, 0.25f);
    EXPECT_TRUE(rt->SetNodeVideoTextureRate("movie", kNaN));
    EXPECT_FLOAT_EQ(rt->ResolveVideoPlaybackState(key, 0.0).rate, 0.0f);

    // Play undoes the pause.
    EXPECT_FALSE(rt->NodeVideoTextureIsPlaying("movie"));
    EXPECT_TRUE(rt->PlayNodeVideoTexture("movie"));
    EXPECT_TRUE(rt->NodeVideoTextureIsPlaying("movie"));
    EXPECT_FALSE(rt->ResolveVideoPlaybackState(key, 0.0).paused);

    // A node with no video answers false everywhere.
    EXPECT_FALSE(rt->PauseNodeVideoTexture("unknown"));
    EXPECT_FALSE(rt->SetNodeVideoTextureCurrentTime("unknown", 1.0));
    EXPECT_FALSE(rt->SetNodeVideoTextureRate("unknown", 1.0f));
    EXPECT_FALSE(rt->NodeVideoTextureIsPlaying("unknown"));
}

TEST(VideoPlaybackClocks, OneNodeWithTwoTexturesSharesOneControlSet)
{
    auto rt = MakeRuntime();
    const std::string diffuse = "textures/diffuse.mp4", mask = "textures/mask.mp4";
    rt->RegisterNodeVideoTexture("movie", diffuse);
    rt->RegisterNodeVideoTexture("movie", mask);
    rt->SetVideoTextureDuration(diffuse, 3.0);
    rt->SetVideoTextureDuration(mask, 5.0);

    EXPECT_TRUE(rt->PauseNodeVideoTexture("movie"));
    EXPECT_TRUE(rt->SetNodeVideoTextureCurrentTime("movie", 7.5));
    EXPECT_TRUE(rt->SetNodeVideoTextureRate("movie", 0.25f));

    auto check = [&] {
        const auto first = rt->ResolveVideoPlaybackState(diffuse, 99.0);
        EXPECT_TRUE(first.paused);
        EXPECT_FLOAT_EQ(first.rate, 0.25f);
        EXPECT_DOUBLE_EQ(first.scene_elapsed_seconds, 1.5) << "7.5 mod 3";

        const auto second = rt->ResolveVideoPlaybackState(mask, 99.0);
        EXPECT_TRUE(second.paused);
        EXPECT_FLOAT_EQ(second.rate, 0.25f);
        EXPECT_DOUBLE_EQ(second.scene_elapsed_seconds, 2.5) << "7.5 mod 5: each key wraps by its own length";
    };
    check();

    // Registering a pair again changes nothing.
    rt->RegisterNodeVideoTexture("movie", diffuse);
    rt->RegisterNodeVideoTexture("movie", mask);
    check();

    // Play reaches every key.
    EXPECT_TRUE(rt->PlayNodeVideoTexture("movie"));
    EXPECT_FALSE(rt->ResolveVideoPlaybackState(diffuse, 0.0).paused);
    EXPECT_FALSE(rt->ResolveVideoPlaybackState(mask, 0.0).paused);

    // A clock belongs to its key: another node naming the mask key steers the same clock.
    auto rt2 = MakeRuntime();
    rt2->RegisterNodeVideoTexture("movie", diffuse);
    rt2->RegisterNodeVideoTexture("movie", mask);
    rt2->RegisterNodeVideoTexture("overlay", mask);
    EXPECT_TRUE(rt2->SetNodeVideoTextureRate("movie", 0.25f));
    EXPECT_TRUE(rt2->SetNodeVideoTextureRate("overlay", 2.0f));
    EXPECT_FLOAT_EQ(rt2->ResolveVideoPlaybackState(mask, 0.0).rate, 2.0f);
    EXPECT_FLOAT_EQ(rt2->ResolveVideoPlaybackState(diffuse, 0.0).rate, 0.25f);
}

TEST(VideoPlaybackClocks, AnUnknownKeyReportsTheCallersTimeAtNormalSpeed)
{
    auto rt = MakeRuntime();
    const auto missing = rt->ResolveVideoPlaybackState("textures/missing.mp4", 12.25);
    EXPECT_FALSE(missing.paused);
    EXPECT_FLOAT_EQ(missing.rate, 1.0f);
    EXPECT_DOUBLE_EQ(missing.scene_elapsed_seconds, 12.25);

    const auto empty = rt->ResolveVideoPlaybackState("", 3.5);
    EXPECT_FALSE(empty.paused);
    EXPECT_FLOAT_EQ(empty.rate, 1.0f);
    EXPECT_DOUBLE_EQ(empty.scene_elapsed_seconds, 3.5);

    // A registered key answers from its own clock, whatever the caller offers.
    rt->RegisterNodeVideoTexture("movie", "textures/known.mp4");
    const auto known = rt->ResolveVideoPlaybackState("textures/known.mp4", 7.0);
    EXPECT_FALSE(known.paused);
    EXPECT_FLOAT_EQ(known.rate, 1.0f);
    EXPECT_DOUBLE_EQ(known.scene_elapsed_seconds, 0.0);
}

// ---- settings bound to project properties --------------------------------------------------

TEST(PropertyBoundSettings, ATextPropertyKeepsItsVectorValueForAScale)
{
    auto rt = MakeRuntime(0, 0, { { "scale", RuntimeScalarValue::String("2 3 4") } });
    auto node = Register(*rt, "layer");
    rt->RegisterNodeScale(
        "layer", node.get(),
        ResolveVec3Setting(*rt, { { "user", "scale" }, { "value", "1 1 1" } }, "layer"));

    auto expect = [&](float x, float y, float z) {
        const auto scale = rt->NodeScale("layer");
        EXPECT_FLOAT_EQ(scale[0], x);
        EXPECT_FLOAT_EQ(scale[1], y);
        EXPECT_FLOAT_EQ(scale[2], z);
    };
    expect(2, 3, 4);  // the property, not the authored 1 1 1

    rt->ApplyProjectPropertyOverride({ { "scale", RuntimeScalarValue::String("5 6 7") } });
    rt->Tick(kFrame);
    expect(5, 6, 7);
    const auto drawn = node->Scale();
    EXPECT_FLOAT_EQ(drawn[0], 5.0f);
    EXPECT_FLOAT_EQ(drawn[1], 6.0f);
    EXPECT_FLOAT_EQ(drawn[2], 7.0f);

    rt->ApplyProjectPropertyOverride({ { "scale", RuntimeScalarValue::String("2 3 4") } });
    rt->Tick(kFrame);
    expect(2, 3, 4);

    rt->ApplyProjectPropertyOverride({ { "scale", RuntimeScalarValue::String("8 8 8") } });
    rt->Tick(kFrame);
    expect(8, 8, 8);
    // A document that leaves the name out returns it to the declared default.
    rt->ApplyProjectPropertyOverride({});
    rt->Tick(kFrame);
    expect(2, 3, 4);

    // A property the table never declared leaves the authored value in effect.
    auto bare = MakeRuntime();
    auto bareNode = Register(*bare, "layer");
    bare->RegisterNodeScale(
        "layer", bareNode.get(),
        ResolveVec3Setting(*bare, { { "user", "undeclared" }, { "value", "1 1 1" } }, "layer"));
    bare->Tick(kFrame);
    const auto authored = bare->NodeScale("layer");
    EXPECT_FLOAT_EQ(authored[0], 1.0f);
    EXPECT_FLOAT_EQ(authored[1], 1.0f);
    EXPECT_FLOAT_EQ(authored[2], 1.0f);
}

constexpr const char* kPassThroughModule = "export function update(value) { return value; }";

nlohmann::json ScriptedFlag(const char* module, bool authored)
{
    return { { "script", module }, { "user", "flagProp" }, { "value", authored } };
}

struct FlagFixture {
    std::unique_ptr<SceneRuntimeContext> rt;
    std::shared_ptr<SceneNode>           node;

    FlagFixture(bool property, const char* module, bool authored = true)
        : rt(MakeRuntime(0, 0, { { "flagProp", RuntimeScalarValue::Bool(property) } }))
        , node(std::make_shared<SceneNode>())
    {
        rt->RegisterNodeVisibility("part", node.get(),
                                   ResolveBoolSetting(*rt, ScriptedFlag(module, authored), "part"));
    }
};

TEST(PropertyBoundSettings, AUserBoundScriptedVisibilityFollowsItsPropertyNotTheAuthoredValue)
{
    FlagFixture f(false, kPassThroughModule);
    // Immediately after registering, before anything ticks.
    EXPECT_FALSE(f.rt->NodeVisible("part"));
    EXPECT_FALSE(f.node->Visible());

    f.rt->Tick(kFrame);
    EXPECT_FALSE(f.rt->NodeVisible("part"));
    EXPECT_FALSE(f.node->Visible());
    EXPECT_EQ(f.rt->scriptErrorCount(), 0u);

    // The control: the same setting with the property on is visible.
    FlagFixture on(true, kPassThroughModule);
    on.rt->Tick(kFrame);
    EXPECT_TRUE(on.rt->NodeVisible("part"));
    EXPECT_TRUE(on.node->Visible());

    // And the property is followed live.
    f.rt->ApplyProjectPropertyOverride({ { "flagProp", RuntimeScalarValue::Bool(true) } });
    f.rt->Tick(kFrame);
    EXPECT_TRUE(f.rt->NodeVisible("part"));
    EXPECT_TRUE(f.node->Visible());
}

TEST(PropertyBoundSettings, AVisibilityScriptReturningAnObjectGivesNoValue)
{
    const char* module = R"js(
        var shape = { x: 1, y: 2, z: 3 };
        export function init(value) { return value; }
        export function update(value) { return shape; }
    )js";

    FlagFixture off(false, module);
    EXPECT_FALSE(off.rt->NodeVisible("part"));
    EXPECT_FALSE(off.node->Visible());
    off.rt->Tick(kFrame);
    off.rt->Tick(3.0);
    EXPECT_FALSE(off.rt->NodeVisible("part"));
    EXPECT_FALSE(off.node->Visible());
    EXPECT_EQ(off.rt->scriptErrorCount(), 0u);

    // Neither direction is changed by the object: with the property on the layer stays visible.
    FlagFixture on(true, module);
    on.rt->Tick(kFrame);
    on.rt->Tick(3.0);
    EXPECT_TRUE(on.rt->NodeVisible("part"));
    EXPECT_TRUE(on.node->Visible());
    EXPECT_EQ(on.rt->scriptErrorCount(), 0u);
}

TEST(PropertyBoundSettings, APropertyChangeBeforeTheFirstTickIsWhatInitSees)
{
    const char* module = R"js(
        var remembered = { x: 1, y: 2, z: 3 };
        export function init(value) { remembered = value; return value; }
        export function update(value) { return remembered; }
    )js";

    FlagFixture f(true, module);
    EXPECT_TRUE(f.rt->NodeVisible("part")) << "before the override";
    f.rt->ApplyProjectPropertyOverride({ { "flagProp", RuntimeScalarValue::Bool(false) } });
    f.rt->Tick(kFrame);
    f.rt->Tick(3.0);
    EXPECT_FALSE(f.rt->NodeVisible("part"));
    EXPECT_FALSE(f.node->Visible());
    EXPECT_EQ(f.rt->scriptErrorCount(), 0u);

    // Without any override the remembered value is the property's own.
    FlagFixture untouched(true, module);
    untouched.rt->Tick(kFrame);
    untouched.rt->Tick(3.0);
    EXPECT_TRUE(untouched.rt->NodeVisible("part"));
    EXPECT_TRUE(untouched.node->Visible());
}

constexpr const char* kSpectrumModule = R"js(
    export var scriptProperties = createScriptProperties()
        .addSlider({ name: 'barWidth', value: 5 })
        .addSlider({ name: 'scaleY', value: 60 })
        .finish();
    export function update(value) {
        thisLayer.scale = new Vec3(scriptProperties.barWidth, scriptProperties.scaleY, 1);
        return value;
    }
)js";

nlohmann::json SpectrumSetting()
{
    return { { "script", kSpectrumModule },
             { "scriptproperties",
               { { "barWidth", { { "user", "widthProp" }, { "value", 5 } } },
                 { "scaleY", { { "user", "heightProp" }, { "value", 60 } } } } },
             { "user", "showProp" },
             { "value", true } };
}

struct SpectrumFixture {
    std::unique_ptr<SceneRuntimeContext> rt;
    std::shared_ptr<SceneNode>           node;

    explicit SpectrumFixture(ProjectProperties properties)
        : rt(MakeRuntime(0, 0, std::move(properties)))
        , node(std::make_shared<SceneNode>())
    {
        rt->RegisterNodeVisibility("Spectrum Bars", node.get(),
                                   ResolveBoolSetting(*rt, SpectrumSetting(), "Spectrum Bars"));
    }
};

ProjectProperties SpectrumProperties(bool show = true, float width = 3.0f, float height = 30.0f)
{
    return { { "widthProp", RuntimeScalarValue::Float(width) },
             { "heightProp", RuntimeScalarValue::Float(height) },
             { "showProp", RuntimeScalarValue::Bool(show) } };
}

TEST(PropertyBoundSettings, ScriptPropertiesBoundToUserPropertiesDriveALayersScale)
{
    SpectrumFixture f(SpectrumProperties());
    f.rt->Tick(kFrame);
    auto scale = f.rt->NodeScale("Spectrum Bars");
    EXPECT_FLOAT_EQ(scale[0], 3.0f);
    EXPECT_FLOAT_EQ(scale[1], 30.0f);
    EXPECT_FLOAT_EQ(scale[2], 1.0f);
    EXPECT_EQ(f.rt->scriptErrorCount(), 0u);

    // A script property follows its user property live.
    f.rt->ApplyProjectPropertyOverride(SpectrumProperties(true, 7.0f, 30.0f));
    f.rt->Tick(kFrame);
    scale = f.rt->NodeScale("Spectrum Bars");
    EXPECT_FLOAT_EQ(scale[0], 7.0f);
    EXPECT_FLOAT_EQ(scale[1], 30.0f);

    // Without declared properties the sliders' own defaults apply.
    SpectrumFixture bare({});
    bare.rt->Tick(kFrame);
    scale = bare.rt->NodeScale("Spectrum Bars");
    EXPECT_FLOAT_EQ(scale[0], 5.0f);
    EXPECT_FLOAT_EQ(scale[1], 60.0f);

    // Hidden by its own property, the script still runs.
    SpectrumFixture hidden(SpectrumProperties(false));
    hidden.rt->Tick(kFrame);
    EXPECT_FALSE(hidden.rt->NodeVisible("Spectrum Bars"));
    scale = hidden.rt->NodeScale("Spectrum Bars");
    EXPECT_FLOAT_EQ(scale[0], 3.0f);
    EXPECT_FLOAT_EQ(scale[1], 30.0f);
}

// ---- a scripted transform with alignment ------------------------------------------------------

struct AlignedLayer {
    std::unique_ptr<SceneRuntimeContext> rt = MakeRuntime(3840, 2160);
    std::shared_ptr<SceneNode>           node = std::make_shared<SceneNode>();

    AlignedLayer(const char* alignment, const char* scale = "3, 4, 1")
    {
        node->SetTranslate({ 100.0f, 50.0f, 0.0f });
        node->SetScale({ 1.0f, 1.0f, 1.0f });
        rt->RegisterNode("tower", node.get());
        rt->RegisterNodeSize("tower", { 20.0f, 10.0f });
        rt->RegisterSceneScript(std::string("function update() {\n"
                                            "  var layer = scene.getObject('tower');\n"
                                            "  layer.alignment = '") +
                                    alignment + "';\n  layer.scale = new Vec3(" + scale +
                                    ");\n  layer.origin = new Vec3(100, 50, 0);\n}\n",
                                "");
        rt->Tick(kFrame);
    }

    // The layer's own values stay as written; only the drawn node moves.
    void Expect(float scaleX, float scaleY, float drawnX, float drawnY)
    {
        const auto logicalScale = rt->NodeScale("tower");
        EXPECT_FLOAT_EQ(logicalScale[0], scaleX);
        EXPECT_FLOAT_EQ(logicalScale[1], scaleY);
        const auto origin = rt->NodeTranslate("tower");
        EXPECT_FLOAT_EQ(origin[0], 100.0f);
        EXPECT_FLOAT_EQ(origin[1], 50.0f);
        const auto drawn = node->Translate();
        EXPECT_FLOAT_EQ(drawn[0], drawnX);
        EXPECT_FLOAT_EQ(drawn[1], drawnY);
        EXPECT_EQ(rt->scriptErrorCount(), 0u);
    }
};

TEST(ScriptedAlignment, ABottomAlignedLayerKeepsItsValuesAndTheDrawnNodeKeepsItsEdge)
{
    AlignedLayer layer("bottom");
    EXPECT_EQ(layer.rt->sceneScriptCount(), 1u);
    layer.Expect(3, 4, 100, 65);  // 50 + 10 * 3 * 0.5
}

TEST(ScriptedAlignment, EachAnchorWordShiftsTheDrawnNodeTheOtherWay)
{
    struct Row {
        const char* alignment;
        float       drawnX, drawnY;
    };
    // growth x = 2, y = 3; half sizes 10 and 5
    const Row rows[] = {
        { "top", 100, 35 },        { "left", 120, 50 },         { "right", 80, 50 },
        { "topleft", 120, 35 },    { "bottomright", 80, 65 },   { "center", 100, 50 },
    };
    for (const auto& row : rows) {
        SCOPED_TRACE(row.alignment);
        AlignedLayer layer(row.alignment);
        layer.Expect(3, 4, row.drawnX, row.drawnY);
    }
}

TEST(ScriptedAlignment, ALayerThatDoesNotGrowIsNotShifted)
{
    AlignedLayer layer("bottom", "1, 1, 1");
    layer.Expect(1, 1, 100, 50);
}

} // namespace
} // namespace wallpaper
