// The JavaScript host that runs property scripts and scene scripts: layer wrapper identity, text
// layers, timers, the payload a cursor event hands a handler, a vec3 constant bound to a user
// property, and `sortLayer`. Programs are driven frame by frame with hand-chosen clocks.

#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scripting/ScriptEngine.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace wallpaper
{
namespace
{

constexpr double kFrame = 1.0 / 60.0;

std::unique_ptr<SceneRuntimeContext> MakeRuntime(int w = 0, int h = 0, ProjectProperties properties = {})
{
    return CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = w,
                                                            .canvas_height = h,
                                                            .project_properties = std::move(properties) });
}

std::unique_ptr<PropertyScriptProgram> Start(ScriptEngine& engine, SceneRuntimeContext* runtime,
                                             const std::string& source, const std::string& layer = {},
                                             double clock = 0.0)
{
    ScriptHostContext host {};
    host.runtime_seconds = clock;
    auto program = engine.CreatePropertyScriptProgram(runtime, source, layer, {}, DynamicValue(0.0f), host);
    EXPECT_NE(program, nullptr);
    if (program != nullptr) EXPECT_TRUE(program->Valid());
    return program;
}

// One frame at scene clock `clock`; the script's number result.
float Frame(PropertyScriptProgram& program, double clock)
{
    ScriptHostContext host {};
    host.runtime_seconds = clock;
    const auto result = program.Evaluate(host, DynamicValue(0.0f));
    EXPECT_NE(result, nullptr);
    return result == nullptr ? -1000.0f : result->getFloat();
}

// ---- layer wrappers --------------------------------------------------------------------------

TEST(ScriptHost, EveryLookupOfALayerReturnsTheSameObject)
{
    auto rt = MakeRuntime();
    SceneNode node;
    rt->RegisterNode("probe", &node);
    auto program = Start(rt->scriptEngine(), rt.get(), R"js(
        var stored = thisScene.getObject('probe');
        export function update(value) {
            var mask = 0;
            if (stored === thisScene.getLayer('probe')) { mask += 1; }
            if (stored === thisLayer) { mask += 2; }
            if (thisScene.getSprite('probe') === thisLayer) { mask += 4; }
            if (thisScene.getObject('probe') === stored) { mask += 8; }
            return mask;
        }
    )js", "probe");
    ASSERT_NE(program, nullptr);

    const float mask = Frame(*program, 0.0);
    EXPECT_NE(static_cast<int>(mask) & 1, 0) << "getLayer differs from getObject";
    EXPECT_NE(static_cast<int>(mask) & 2, 0) << "thisLayer differs from the looked-up wrapper";
    EXPECT_NE(static_cast<int>(mask) & 4, 0) << "getSprite differs from thisLayer";
    EXPECT_NE(static_cast<int>(mask) & 8, 0) << "a repeated lookup builds a new wrapper";
    EXPECT_FLOAT_EQ(mask, 15.0f);
    EXPECT_EQ(rt->scriptErrorCount(), 0u);
}

// ---- text layers ------------------------------------------------------------------------------

TEST(ScriptHost, AScriptWritesATextLayerThroughEitherWrapper)
{
    auto rt = MakeRuntime();
    SceneNode node;
    rt->RegisterNode("caption", &node);
    TextLayerState state;
    state.text = "before";
    state.font_key = "Arial";
    state.point_size = 12.0f;
    rt->RegisterTextLayer("caption", state);
    ASSERT_EQ(rt->NodeText("caption"), "before");

    auto program = Start(rt->scriptEngine(), rt.get(), R"js(
        export function update(value) {
            thisLayer.text = 'after';
            var other = thisScene.getLayer('caption');
            other.text = other.text + ' indirect';
            return thisLayer.text === 'after indirect' ? 1 : -1;
        }
    )js", "caption");
    ASSERT_NE(program, nullptr);
    EXPECT_EQ(rt->NodeText("caption"), "before") << "nothing is written before the script runs";

    EXPECT_FLOAT_EQ(Frame(*program, 0.0), 1.0f);
    EXPECT_EQ(rt->NodeText("caption"), "after indirect");
    EXPECT_EQ(rt->scriptErrorCount(), 0u);

    // A number is converted to its text.
    auto numberRt = MakeRuntime();
    SceneNode numberNode;
    numberRt->RegisterNode("caption", &numberNode);
    numberRt->RegisterTextLayer("caption", state);
    auto numeric = Start(numberRt->scriptEngine(), numberRt.get(),
                         "export function update(value) { thisLayer.text = 42; return 0; }", "caption");
    ASSERT_NE(numeric, nullptr);
    Frame(*numeric, 0.0);
    EXPECT_EQ(numberRt->NodeText("caption"), "42");
}

// ---- timers -----------------------------------------------------------------------------------

constexpr const char* kOneShotAndCancel = R"js(
    var a = 0, b = 0;
    setTimeout(function () { a += 1; }, 100);
    var handle = engine.setTimeout(function () { b += 1; }, 100);
    clearTimeout(handle);
    export function update(value) { return a * 10 + b; }
)js";

TEST(ScriptTimers, AOneShotFiresOnceThroughEverySpellingAndACanceledOneNeverFires)
{
    ScriptEngine engine;
    auto program = Start(engine, nullptr, kOneShotAndCancel);
    ASSERT_NE(program, nullptr);
    EXPECT_FLOAT_EQ(Frame(*program, 0.05), 0.0f) << "nothing is due yet";
    EXPECT_FLOAT_EQ(Frame(*program, 0.15), 10.0f) << "one fired, the canceled one did not";
    EXPECT_FLOAT_EQ(Frame(*program, 0.30), 10.0f) << "a one-shot fires once";

    // Due exactly at its deadline.
    auto exact = Start(engine, nullptr, kOneShotAndCancel);
    ASSERT_NE(exact, nullptr);
    EXPECT_FLOAT_EQ(Frame(*exact, 0.10), 10.0f);

    // Either spelling of clear cancels either spelling of set.
    auto engineSpelling = Start(engine, nullptr, R"js(
        var n = 0;
        var h = engine.setInterval(function () { n += 1; }, 100);
        engine.clearInterval(h);
        export function update(value) { return n; }
    )js");
    ASSERT_NE(engineSpelling, nullptr);
    EXPECT_FLOAT_EQ(Frame(*engineSpelling, 0.5), 0.0f);

    auto mixed = Start(engine, nullptr, R"js(
        var n = 0;
        var h = setInterval(function () { n += 1; }, 100);
        clearTimeout(h);
        export function update(value) { return n; }
    )js");
    ASSERT_NE(mixed, nullptr);
    EXPECT_FLOAT_EQ(Frame(*mixed, 0.5), 0.0f);
}

TEST(ScriptTimers, AThrowingOneShotNeitherFiresAgainNorBlocksALaterTimer)
{
    auto rt = MakeRuntime();
    auto program = Start(rt->scriptEngine(), rt.get(), R"js(
        var landed = 0;
        setTimeout(function () { throw new Error('boom'); }, 100);
        setTimeout(function () { landed += 1; }, 150);
        export function update(value) { return landed; }
    )js");
    ASSERT_NE(program, nullptr);

    EXPECT_FLOAT_EQ(Frame(*program, 0.12), 0.0f);
    ASSERT_EQ(rt->scriptErrorCount(), 1u);
    EXPECT_FLOAT_EQ(Frame(*program, 0.20), 1.0f);
    ASSERT_EQ(rt->scriptErrorCount(), 1u);
    EXPECT_FLOAT_EQ(Frame(*program, 0.30), 1.0f);
    EXPECT_EQ(rt->scriptErrorCount(), 1u) << "the thrown one-shot is gone";

    // One error per pass, however many callbacks throw, and the healthy one in the pass still runs.
    auto crowded = MakeRuntime();
    auto together = Start(crowded->scriptEngine(), crowded.get(), R"js(
        var landed = 0;
        setTimeout(function () { throw new Error('one'); }, 100);
        setTimeout(function () { throw new Error('two'); }, 100);
        setTimeout(function () { landed += 1; }, 100);
        export function update(value) { return landed; }
    )js");
    ASSERT_NE(together, nullptr);
    EXPECT_FLOAT_EQ(Frame(*together, 0.2), 1.0f);
    EXPECT_EQ(crowded->scriptErrorCount(), 1u);
}

TEST(ScriptTimers, AThrowingIntervalKeepsItsScheduleAndDoesNotBlockLaterTimers)
{
    auto rt = MakeRuntime();
    auto program = Start(rt->scriptEngine(), rt.get(), R"js(
        var ticks = 0, landed = 0;
        setInterval(function () { ticks += 1; if (ticks === 1) { throw new Error('first run'); } }, 100);
        setTimeout(function () { landed += 1; }, 150);
        export function update(value) { return landed * 100 + ticks; }
    )js");
    ASSERT_NE(program, nullptr);

    EXPECT_FLOAT_EQ(Frame(*program, 0.12), 1.0f);
    ASSERT_EQ(rt->scriptErrorCount(), 1u);
    EXPECT_FLOAT_EQ(Frame(*program, 0.16), 101.0f);
    ASSERT_EQ(rt->scriptErrorCount(), 1u);
    EXPECT_FLOAT_EQ(Frame(*program, 0.18), 101.0f) << "next due at 0.2";
    ASSERT_EQ(rt->scriptErrorCount(), 1u);

    EXPECT_FLOAT_EQ(Frame(*program, 0.25), 102.0f) << "due at 0.2, and this run does not throw";
    EXPECT_FLOAT_EQ(Frame(*program, 0.90), 103.0f) << "a late interval fires once, without catching up";
    EXPECT_FLOAT_EQ(Frame(*program, 0.95), 103.0f) << "the next one is a period after the late run";
    EXPECT_FLOAT_EQ(Frame(*program, 1.05), 104.0f);
    EXPECT_EQ(rt->scriptErrorCount(), 1u);
}

// ---- cursor payload ---------------------------------------------------------------------------

constexpr const char* kCursorProbe = R"js(
    var count = 0, mask = 0, button = -1;
    function cursorDown(event) {
        count += 1;
        button = event.button;
        if (event.button === 1) { mask |= 1; }
        if (event.normalizedPosition.x === 0.25) { mask |= 2; }
        if (event.normalizedPosition.y === 0.75) { mask |= 4; }
        if (event.position.x === 480) { mask |= 8; }
        if (event.position.y === 270) { mask |= 16; }
        if (event.worldPosition.x === 480) { mask |= 32; }
        if (event.worldPosition.y === 270) { mask |= 64; }
    }
    function update() {
        var probe = scene.getObject('probe');
        probe.origin = new Vec3(mask, count, button);
        if (count === 1) { probe.visible = true; }
    }
)js";

struct CursorStage {
    std::unique_ptr<SceneRuntimeContext> rt = MakeRuntime(1920, 1080);
    SceneNode                            probe;

    CursorStage()
    {
        probe.SetVisible(false);
        rt->RegisterNode("probe", &probe);
        rt->RegisterSceneScript(kCursorProbe, "");
        rt->SetCursorInput(0.25f, 0.75f);
    }
};

TEST(ScriptHost, ACursorDownHandsTheButtonAndThePointerInEverySpelling)
{
    CursorStage stage;
    ASSERT_FALSE(stage.rt->NodeVisible("probe"));
    stage.rt->SetCursorButton(1, true);
    stage.rt->DispatchCursorDown(1);
    stage.rt->Tick(kFrame);

    const auto origin = stage.rt->NodeTranslate("probe");
    const int  mask = static_cast<int>(origin[0]);
    EXPECT_NE(mask & 1, 0) << "button";
    EXPECT_NE(mask & 2, 0) << "normalizedPosition.x";
    EXPECT_NE(mask & 4, 0) << "normalizedPosition.y";
    EXPECT_NE(mask & 8, 0) << "position.x";
    EXPECT_NE(mask & 16, 0) << "position.y";
    EXPECT_NE(mask & 32, 0) << "worldPosition.x";
    EXPECT_NE(mask & 64, 0) << "worldPosition.y";
    EXPECT_EQ(mask, 127);
    EXPECT_FLOAT_EQ(origin[1], 1.0f) << "the handler ran once";
    EXPECT_TRUE(stage.rt->NodeVisible("probe"));
    EXPECT_EQ(stage.rt->scriptErrorCount(), 0u);
}

TEST(ScriptHost, ACursorDownWithoutAButtonArgumentIsThePrimaryButton)
{
    CursorStage stage;
    stage.rt->DispatchCursorDown();
    stage.rt->Tick(kFrame);
    const auto origin = stage.rt->NodeTranslate("probe");
    EXPECT_FLOAT_EQ(origin[1], 1.0f);
    EXPECT_FLOAT_EQ(origin[2], 0.0f) << "event.button";
}

TEST(ScriptHost, EachDispatchRunsTheHandlerOnce)
{
    CursorStage stage;
    stage.rt->DispatchCursorDown(1);
    stage.rt->DispatchCursorDown(1);
    stage.rt->SetNodeVisible("probe", false);
    stage.rt->Tick(kFrame);
    EXPECT_FLOAT_EQ(stage.rt->NodeTranslate("probe")[1], 2.0f);
    EXPECT_FALSE(stage.rt->NodeVisible("probe")) << "the update rule only fires at exactly one";
}

// ---- a vec3 constant bound to a user property ---------------------------------------------------

TEST(ScriptHost, AVec3ConstantFollowsAUserPropertyHoldingThreeNumbers)
{
    auto rt = MakeRuntime(0, 0, { { "tintprop", RuntimeScalarValue::String("0.25 0.5 0.75") } });
    auto material = std::make_shared<SceneMaterial>();
    rt->RegisterMaterialConstant(
        material, "g_Tint",
        ResolveVec3Setting(*rt, { { "user", "tintprop" }, { "value", { 1.0, 1.0, 1.0 } } }));

    auto expect = [&](float x, float y, float z) {
        const auto found = material->customShader.constValues.find("g_Tint");
        ASSERT_NE(found, material->customShader.constValues.end());
        ASSERT_EQ(found->second.size(), 3u);
        EXPECT_FLOAT_EQ(found->second[0], x);
        EXPECT_FLOAT_EQ(found->second[1], y);
        EXPECT_FLOAT_EQ(found->second[2], z);
    };

    rt->Tick(kFrame);
    expect(0.25f, 0.5f, 0.75f);  // never the authored 1 1 1

    rt->ApplyProjectPropertyOverride({ { "tintprop", RuntimeScalarValue::String("0.1 0.2 0.3") } });
    rt->Tick(kFrame);
    expect(0.1f, 0.2f, 0.3f);

    // A document that adds an unrelated property leaves this one where the document put it.
    rt->ApplyProjectPropertyOverride({ { "tintprop", RuntimeScalarValue::String("0.1 0.2 0.3") },
                                       { "other", RuntimeScalarValue::String("9 9 9") } });
    rt->Tick(kFrame);
    expect(0.1f, 0.2f, 0.3f);

    // Whole documents: leaving the name out returns it to the value the runtime was built with.
    rt->ApplyProjectPropertyOverride({ { "other", RuntimeScalarValue::String("9 9 9") } });
    rt->Tick(kFrame);
    expect(0.25f, 0.5f, 0.75f);
}

// ---- sortLayer --------------------------------------------------------------------------------

struct Siblings {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> rt = MakeRuntime(1920, 1080);
    std::vector<std::shared_ptr<SceneNode>> nodes;

    Siblings()
    {
        rt->AttachScene(&scene);
        for (const char* name : { "first", "second", "third" }) {
            auto node = std::make_shared<SceneNode>(linalg::Vector3f(0, 0, 0), linalg::Vector3f(1, 1, 1),
                                                    linalg::Vector3f(0, 0, 0), name);
            scene.sceneGraph->AppendChild(node);
            rt->RegisterNode(name, node.get());
            nodes.push_back(node);
        }
    }
    int Index(const char* name) const { return rt->NodeSiblingIndex(name); }
};

TEST(ScriptHost, SortLayerFromAScriptMovesTheLayerOnceWhateverTheFrameCount)
{
    Siblings f;
    EXPECT_EQ(f.Index("first"), 0);
    EXPECT_EQ(f.Index("second"), 1);
    EXPECT_EQ(f.Index("third"), 2);
    f.rt->RegisterSceneScript("function update() { scene.sortLayer('first', 2); }", "");

    f.rt->Tick(kFrame);
    EXPECT_TRUE(f.rt->ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(f.Index("first"), 2);
    EXPECT_EQ(f.Index("second"), 0);
    EXPECT_EQ(f.Index("third"), 1);

    f.rt->Tick(kFrame);
    EXPECT_FALSE(f.rt->ConsumeSceneGraphMutationFlag()) << "repeating the same sort changes nothing";
    EXPECT_EQ(f.Index("first"), 2);
    EXPECT_EQ(f.rt->scriptErrorCount(), 0u);
}

TEST(ScriptHost, SortLayerThroughTheRuntimeReportsWhetherAnythingMoved)
{
    Siblings f;
    EXPECT_TRUE(f.rt->SortLayer("third", 0));
    EXPECT_EQ(f.Index("third"), 0);
    EXPECT_EQ(f.Index("first"), 1);
    EXPECT_EQ(f.Index("second"), 2);
    EXPECT_FALSE(f.rt->SortLayer("third", 0));

    Siblings clamped;
    EXPECT_TRUE(clamped.rt->SortLayer("first", 99));
    EXPECT_EQ(clamped.Index("first"), 2);
    EXPECT_EQ(clamped.rt->LayerIndex("first"), 2);

    Siblings floored;
    EXPECT_TRUE(floored.rt->SortLayer("third", -5));
    EXPECT_EQ(floored.Index("third"), 0);
    EXPECT_EQ(floored.rt->LayerIndex("third"), 0);

    Siblings unknown;
    unknown.rt->ConsumeSceneGraphMutationFlag();
    EXPECT_FALSE(unknown.rt->SortLayer("missing", 0));
    EXPECT_FALSE(unknown.rt->ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(unknown.Index("first"), 0);
    EXPECT_EQ(unknown.Index("second"), 1);
    EXPECT_EQ(unknown.Index("third"), 2);
}

} // namespace
} // namespace wallpaper
