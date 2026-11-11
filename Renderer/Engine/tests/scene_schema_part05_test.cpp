// Scene file schema, part 5: authored transform timelines (origin / scale / angles), anchored
// layers, and the click-script sound layers of layers that share a name.
//
// Every test parses a scene headlessly with a live runtime and advances that runtime by hand.
#include "support/schema_fixtures.hpp"

#include "Runtime/ScalarAnimation.hpp"
#include "Scene/SceneLight.hpp"
#include "Scene/SceneUpdateDemand.hpp"

#include <gtest/gtest.h>

#include <array>
#include <functional>
#include <string>
#include <tuple>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

using Vec3 = std::array<float, 3>;

// ---- scene-file builders -----------------------------------------------------------------

Json V3(double x, double y, double z) { return Json::array({ x, y, z }); }
Json V2(double x, double y) { return Json::array({ x, y }); }

// A list of {frame, value} keys.
Json Keys(const std::vector<std::pair<double, double>>& keys)
{
    Json list = Json::array();
    for (const auto& [frame, value] : keys) list.push_back({ { "frame", frame }, { "value", value } });
    return list;
}

struct Curves {
    Json c0, c1, c2;
};

// An `animation` block. `options` is taken as given; the curves that are null stay un-keyed.
Json Animation(bool relative, const Json& options, const Curves& curves)
{
    Json animation = { { "relative", relative }, { "options", options } };
    if (!curves.c0.is_null()) animation["c0"] = curves.c0;
    if (!curves.c1.is_null()) animation["c1"] = curves.c1;
    if (!curves.c2.is_null()) animation["c2"] = curves.c2;
    return animation;
}

Json Options(int fps, int length, const std::string& mode, const Json& more = Json::object())
{
    Json options = { { "fps", fps }, { "mode", mode } };
    if (length > 0) options["length"] = length;
    for (const auto& [key, value] : more.items()) options[key] = value;
    return options;
}

// A vec3 setting carrying a timeline.
Json Timeline(const Json& value, const Json& animation) { return { { "value", value }, { "animation", animation } }; }

Json Merged(Json base, const Json& extra)
{
    for (const auto& [key, value] : extra.items()) base[key] = value;
    return base;
}

Json ImageLayer(int id, const std::string& name, const Json& extra = Json::object())
{
    return Merged({ { "id", id }, { "name", name }, { "image", "image.json" }, { "visible", true } }, extra);
}

// The object every timeline scene ends with: it keeps the canvas an image layer can sit on.
Json CanvasImage()
{
    return { { "id", 310 }, { "name", "canvas image" }, { "image", "image.json" }, { "alignment", "bottomleft" },
             { "scale", V3(1, 1, 1) }, { "angles", V3(0, 0, 0) }, { "visible", true } };
}

Json LookingDownScene(Json objects, Json general_patch = Json::object())
{
    general_patch["bloom"] = false;
    Json scene      = QuietScene(std::move(objects), general_patch);
    scene["camera"] = { { "center", V3(0, 0, -1) }, { "eye", V3(0, 0, 0) }, { "up", V3(0, 1, 0) } };
    return scene;
}

Json TimelineScene(Json objects)
{
    objects.push_back(CanvasImage());
    return LookingDownScene(std::move(objects));
}

Vec3 AsArray(const linalg::Vector3f& v) { return { v.x(), v.y(), v.z() }; }

// ---- the rig -----------------------------------------------------------------------------

// A live scene: a file set, a parsed scene with a runtime, and a few readers.
class Live {
public:
    Live(const Json& scene, FileMap assets = BasicAssets(), const ProjectProperties& properties = {})
        : rig_(std::move(assets))
    {
        for (const auto& [name, value] : properties) rig_.properties()[name] = value;
        scene_ = rig_.Parse(scene, ParseOptions { .live = true });
    }

    bool ok() const { return scene_ != nullptr && scene_->runtime != nullptr; }
    Scene&               scene() { return *scene_; }
    SceneRuntimeContext& rt() { return *scene_->runtime; }
    SceneNode*           node(std::string_view name) { return FindRootChild(*scene_, name); }

    void Tick(double seconds) { rt().Tick(seconds); }

    Vec3 Origin(const std::string& name) { return AsArray(rt().NodeTranslate(name)); }
    Vec3 Scale(const std::string& name) { return AsArray(rt().NodeScale(name)); }
    Vec3 Angles(const std::string& name) { return AsArray(rt().NodeRotation(name)); }

    // Whether the runtime reports a playing clock.
    bool Animating() { return (rt().DescribeTimeAdvancingWork() & static_cast<std::uint32_t>(SceneDemandReason::Animation)) != 0; }

private:
    ParseRig               rig_;
    std::shared_ptr<Scene> scene_; // after rig_: dies first
};

void ExpectVec(const Vec3& actual, const Vec3& expected, float tolerance = 1e-5f)
{
    for (std::size_t i = 0; i < 3; ++i) EXPECT_NEAR(actual[i], expected[i], tolerance) << "component " << i;
}

void ExpectVecExact(const Vec3& actual, const Vec3& expected)
{
    for (std::size_t i = 0; i < 3; ++i) EXPECT_FLOAT_EQ(actual[i], expected[i]) << "component " << i;
}

// ---- origin timeline on an anchored layer ------------------------------------------------

class OriginSlide : public testing::TestWithParam<std::tuple<std::string, bool>> {};

// R-5.01 / B-5.01, B-5.02, B-5.03
TEST_P(OriginSlide, TheDrawnPositionKeepsTheAnchorOffsetWhileTheClockPlaysAndIsControllable)
{
    const auto& [alignment, relative] = GetParam();
    const float b    = relative ? 100.0f : 0.0f;
    const float edge = alignment == "left" ? 64.0f : -64.0f;

    Live live(TimelineScene(Json::array({ ImageLayer(21, "A",
        { { "alignment", alignment },
          { "scale", V3(2, 1, 1) },
          { "origin", Timeline(V3(100, 70, 3), Animation(relative, Options(20, 20, "single", { { "name", "slide" } }),
                                                          { Keys({ { 0, 0 }, { 20, 80 } }) })) } }) })));
    ASSERT_TRUE(live.ok());
    SceneNode* node = live.node("A");
    ASSERT_NE(node, nullptr);
    ASSERT_FLOAT_EQ(live.rt().NodeSize("A").x(), 64.0f);

    auto expect_at = [&](float origin_x, const char* when) {
        SCOPED_TRACE(when);
        ExpectVecExact(live.Origin("A"), { origin_x, 70.0f, 3.0f });
        ExpectVecExact(AsArray(node->Translate()), { origin_x + edge, 70.0f, 3.0f });
    };

    expect_at(b, "after parse");
    EXPECT_TRUE(live.Animating());

    live.Tick(0.5);
    expect_at(b + 40.0f, "half way");
    EXPECT_TRUE(live.Animating());

    live.Tick(0.5);
    expect_at(b + 80.0f, "at the end");
    EXPECT_FALSE(live.Animating()) << "a single play that has ended keeps nothing awake";

    live.Tick(10.0);
    expect_at(b + 80.0f, "long after the end: a relative offset must not accumulate");

    ScalarAnimationPlayback* clock = live.rt().FindScalarAnimation("A", "slide");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    live.Tick(0.25);
    expect_at(b + 20.0f, "play restarts a finished clock from its first frame");

    clock->playing = false;
    live.Tick(10.0);
    expect_at(b + 20.0f, "a stopped clock holds");

    clock->SetFrame(15.0);
    live.Tick(0.0);
    expect_at(b + 60.0f, "a seek shows on the next tick, even a zero-length one");
    EXPECT_EQ(live.rt().scriptErrorCount(), 0u);
}

INSTANTIATE_TEST_SUITE_P(Anchors, OriginSlide, testing::Combine(testing::Values("left", "right"), testing::Bool()),
                         [](const testing::TestParamInfo<OriginSlide::ParamType>& info) {
                             return std::get<0>(info.param) + (std::get<1>(info.param) ? "Relative" : "Absolute");
                         });

// An unnamed timeline still plays: it is reachable only through the runtime's own clock.
TEST(TransformTimeline, AnUnnamedTimelineStillRunsItsClock)
{
    Live live(TimelineScene(Json::array({ ImageLayer(21, "A",
        { { "origin", Timeline(V3(0, 0, 0), Animation(false, Options(10, 10, "single"), { Keys({ { 0, 0 }, { 10, 100 } }) })) } }) })));
    ASSERT_TRUE(live.ok());
    EXPECT_TRUE(live.Animating());
    live.Tick(0.5);
    EXPECT_FLOAT_EQ(live.Origin("A")[0], 50.0f);
}

// ---- loops with components of unequal length ---------------------------------------------

// R-5.02 / B-5.04
TEST(TransformTimeline, ALoopingPausedOriginTimelineSharesOneClockLengthedByItsLongestCurve)
{
    Live live(TimelineScene(Json::array({ ImageLayer(21, "B",
        { { "origin", Timeline(V3(10, 20, 30),
                               Animation(true, Options(10, 0, "loop", { { "name", "orbit" }, { "startpaused", true } }),
                                         { Keys({ { 2, 4 }, { 5, 10 } }), Keys({ { 0, 0 }, { 20, 40 } }) })) } }) })));
    ASSERT_TRUE(live.ok());

    live.Tick(5.0);
    ExpectVecExact(live.Origin("B"), { 10, 20, 30 }); // paused: before the first x key the offset is nothing

    ScalarAnimationPlayback* clock = live.rt().FindScalarAnimation("B", "orbit");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    live.Tick(0.5);
    ExpectVecExact(live.Origin("B"), { 20, 30, 30 });
    live.Tick(0.5);
    ExpectVecExact(live.Origin("B"), { 20, 40, 30 }); // x holds its last key, y keeps climbing
    live.Tick(1.0);
    ExpectVecExact(live.Origin("B"), { 10, 20, 30 }); // the longest curve ends at frame 20: the clock wraps here
    EXPECT_EQ(live.rt().scriptErrorCount(), 0u);
}

// R-5.07 / B-5.04
TEST(TransformTimeline, ALoopingScaleTimelineHoldsAShortCurveAndLeavesAnUnkeyedAxis)
{
    Live live(TimelineScene(Json::array({ ImageLayer(21, "B",
        { { "scale", Timeline(V3(1, 2, 3), Animation(true, Options(10, 0, "loop", { { "name", "pulse" } }),
                                                      { Keys({ { 0, 0 }, { 5, 1 } }), Keys({ { 0, 0 }, { 10, 4 } }) })) } }) })));
    ASSERT_TRUE(live.ok());
    EXPECT_TRUE(live.Animating()) << "a loop never ends";
    EXPECT_EQ(live.rt().scriptErrorCount(), 0u);

    auto expect_scale = [&](float x, float y, const char* when) {
        SCOPED_TRACE(when);
        const Vec3 scale = live.Scale("B");
        EXPECT_NEAR(scale[0], x, 1e-5f);
        EXPECT_NEAR(scale[1], y, 1e-5f);
        EXPECT_FLOAT_EQ(scale[2], 3.0f);
    };
    expect_scale(1.0f, 2.0f, "after parse");
    live.Tick(0.5);
    expect_scale(2.0f, 4.0f, "frame 5");
    live.Tick(0.3);
    expect_scale(2.0f, 5.2f, "frame 8: the x curve ended at 5 and holds");
    live.Tick(0.4);
    expect_scale(1.4f, 2.8f, "frame 12 wraps to 2 of a 10 frame loop");
}

// ---- timelines on a parent ---------------------------------------------------------------

class OriginOnParent : public testing::TestWithParam<bool> {};

// R-5.03 / B-5.05
TEST_P(OriginOnParent, MovingTheParentMovesTheChildThatHangsFromIt)
{
    Json parent = { { "id", 21 }, { "name", "P" }, { "visible", true },
                    { "origin", Timeline(V3(10, 20, 0), Animation(true, Options(10, 10, "single"), { Keys({ { 0, 0 }, { 10, 40 } }) })) } };
    if (GetParam()) parent = Merged(parent, { { "text", "caption" }, { "font", "Arial" }, { "pointsize", 24 } });
    Live live(TimelineScene(Json::array({ parent, ImageLayer(22, "C", { { "parent", 21 }, { "origin", V3(5, 6, 0) } }) })));
    ASSERT_TRUE(live.ok());

    SceneNode* p = live.node("P");
    ASSERT_NE(p, nullptr);
    ASSERT_EQ(p->GetChildren().size(), 1u);
    SceneNode* child = p->GetChildren().front().get();
    ASSERT_NE(child, nullptr);

    live.Tick(0.5);
    EXPECT_FLOAT_EQ(live.Origin("P")[0], 30.0f);
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), p->Translate().x() + 5.0, 1e-4);

    live.Tick(0.5);
    EXPECT_FLOAT_EQ(live.Origin("P")[0], 50.0f);
    EXPECT_FALSE(live.Animating());
    EXPECT_EQ(live.rt().scriptErrorCount(), 0u);
}

INSTANTIATE_TEST_SUITE_P(Parents, OriginOnParent, testing::Bool(),
                         [](const testing::TestParamInfo<bool>& info) { return info.param ? "TextParent" : "GroupParent"; });

class ScaleOnParent : public testing::TestWithParam<bool> {};

// R-5.13 / B-5.05
TEST_P(ScaleOnParent, ScalingTheParentScalesTheChild)
{
    const Json timeline = Timeline(V3(1, 1, 1), Animation(true, Options(10, 10, "single"), { Keys({ { 0, 0 }, { 10, 1 } }), Keys({ { 0, 0 }, { 10, 1 } }) }));
    Json       parent   = { { "id", 21 }, { "name", "G" }, { "visible", true }, { "scale", timeline } };
    if (!GetParam()) parent["image"] = "image.json"; // a parent that is itself a picture
    Live live(TimelineScene(Json::array({ parent, ImageLayer(22, "C", { { "parent", 21 }, { "origin", V3(5, 6, 0) } }) })));
    ASSERT_TRUE(live.ok());

    SceneNode* g = live.node("G");
    ASSERT_NE(g, nullptr);
    ASSERT_EQ(g->GetChildren().size(), 1u);
    SceneNode* child = g->GetChildren().front().get();

    live.Tick(0.5);
    EXPECT_FLOAT_EQ(g->Scale().x(), 1.5f);
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 7.5, 1e-4) << "the parent has no origin of its own";

    live.Tick(0.5);
    EXPECT_FLOAT_EQ(g->Scale().x(), 2.0f);
    EXPECT_FALSE(live.Animating());
}

INSTANTIATE_TEST_SUITE_P(Parents, ScaleOnParent, testing::Bool(),
                         [](const testing::TestParamInfo<bool>& info) { return info.param ? "GroupParent" : "ImageParent"; });

// ---- a script or a user property is the only writer --------------------------------------

struct BoundCase {
    const char* key;
    bool        script;
};

Json ReadBinding(const Json& animation, bool script)
{
    Json setting = { { "value", V3(1, 2, 3) }, { "animation", animation } };
    if (script) {
        setting["script"] = "export function update() { return new Vec3(7, 8, 9); }";
    } else {
        setting["user"] = "prop";
    }
    return setting;
}

void CheckBoundSettingWins(const BoundCase& row)
{
    const Json animation = Animation(false, Options(10, 10, "single", { { "name", "unused" } }), { Keys({ { 0, 999 } }) });
    ProjectProperties properties;
    properties["prop"] = RuntimeScalarValue::String("7 8 9");
    Live live(TimelineScene(Json::array({ ImageLayer(21, "D", { { row.key, ReadBinding(animation, row.script) } }) })), BasicAssets(), properties);
    ASSERT_TRUE(live.ok());

    live.Tick(1.0);
    const std::string key = row.key;
    const Vec3        seen = key == "origin" ? live.Origin("D") : key == "scale" ? live.Scale("D") : live.Angles("D");
    ExpectVecExact(seen, { 7, 8, 9 });
    EXPECT_EQ(live.rt().FindScalarAnimation("D", "unused"), nullptr) << "a bound setting registers no clock of its own";
    EXPECT_EQ(live.rt().scriptErrorCount(), 0u);
}

// R-5.04 / B-5.06
TEST(BoundTransform, AnOriginBoundToAScriptOrAPropertyIgnoresItsTimeline)
{
    for (const bool script : { true, false }) {
        SCOPED_TRACE(script ? "script" : "user property");
        CheckBoundSettingWins({ "origin", script });
    }
}

// R-5.09 / B-5.06
TEST(BoundTransform, AScaleOrAnglesSettingBoundToAScriptOrAPropertyIgnoresItsTimeline)
{
    for (const BoundCase row : { BoundCase { "scale", true }, BoundCase { "scale", false }, BoundCase { "angles", false } }) {
        SCOPED_TRACE(std::string(row.key) + (row.script ? " script" : " user property"));
        CheckBoundSettingWins(row);
    }
}

// ---- scale and angles ---------------------------------------------------------------------

class ScaleAndAnglesTimeline : public testing::TestWithParam<std::tuple<std::string, bool>> {};

// R-5.05 / B-5.07, B-5.02, B-5.03
TEST_P(ScaleAndAnglesTimeline, ReadsLikeAnOriginTimeline)
{
    const auto& [key, relative] = GetParam();
    const bool  is_scale        = key == "scale";
    const Vec3  base            = is_scale ? Vec3 { 2, 3, 4 } : Vec3 { 10, 20, 30 };
    const float s               = relative ? base[0] : 0.0f;

    Live live(TimelineScene(Json::array({ ImageLayer(21, "E",
        { { key, Timeline(V3(base[0], base[1], base[2]), Animation(relative, Options(20, 20, "single", { { "name", "pose" } }), { Keys({ { 0, 0 }, { 20, 1 } }) })) } }) })));
    ASSERT_TRUE(live.ok());
    SceneNode* node = live.node("E");
    ASSERT_NE(node, nullptr);

    auto read = [&] { return is_scale ? AsArray(node->Scale()) : AsArray(node->Rotation()); };
    auto expect_x = [&](float x, const char* when) {
        SCOPED_TRACE(when);
        const Vec3 value = read();
        EXPECT_FLOAT_EQ(value[0], x);
        EXPECT_FLOAT_EQ(value[1], base[1]);
        EXPECT_FLOAT_EQ(value[2], base[2]);
    };

    expect_x(s, "after parse");
    EXPECT_TRUE(live.Animating());
    live.Tick(0.5);
    expect_x(s + 0.5f, "half way");
    live.Tick(0.5);
    expect_x(s + 1.0f, "end");
    EXPECT_FALSE(live.Animating());
    live.Tick(10.0);
    expect_x(s + 1.0f, "no accumulation");

    ScalarAnimationPlayback* clock = live.rt().FindScalarAnimation("E", "pose");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    live.Tick(0.25);
    expect_x(s + 0.25f, "replayed");
    EXPECT_EQ(live.rt().scriptErrorCount(), 0u);

    // The timeline moves the property it names and leaves the other two alone.
    const Vec3 other = is_scale ? AsArray(node->Rotation()) : AsArray(node->Scale());
    ExpectVecExact(other, is_scale ? Vec3 { 0, 0, 0 } : Vec3 { 1, 1, 1 });
}

INSTANTIATE_TEST_SUITE_P(Properties, ScaleAndAnglesTimeline, testing::Combine(testing::Values("scale", "angles"), testing::Bool()),
                         [](const testing::TestParamInfo<ScaleAndAnglesTimeline::ParamType>& info) {
                             return std::get<0>(info.param) + (std::get<1>(info.param) ? "Relative" : "Absolute");
                         });

class PausedStart : public testing::TestWithParam<std::string> {};

// R-5.06 / B-5.08
TEST_P(PausedStart, ATimelineThatStartsPausedShowsItsFirstKeyUntilPlayed)
{
    const std::string key = GetParam();
    Live live(TimelineScene(Json::array({ ImageLayer(21, "F",
        { { key, Timeline(V3(1, 1, 1), Animation(true, Options(10, 10, "single", { { "name", "intro" }, { "startpaused", true } }),
                                                  { Json(), Keys({ { 0, -0.5 }, { 10, 0.5 } }) })) } }) })));
    ASSERT_TRUE(live.ok());

    auto read = [&] { return key == "scale" ? live.Scale("F") : live.Angles("F"); };
    auto expect_y = [&](float y, const char* when) {
        SCOPED_TRACE(when);
        ExpectVecExact(read(), { 1.0f, y, 1.0f });
    };

    expect_y(0.5f, "after parse: the first key, not the authored 1");
    EXPECT_FALSE(live.Animating());
    live.Tick(5.0);
    expect_y(0.5f, "still paused");

    ScalarAnimationPlayback* clock = live.rt().FindAnimationByName("intro");
    ASSERT_NE(clock, nullptr) << "found by name across the whole scene";
    clock->Play();
    live.Tick(0.5);
    expect_y(1.0f, "playing");
    live.Tick(0.5);
    expect_y(1.5f, "playing on");
}

INSTANTIATE_TEST_SUITE_P(Properties, PausedStart, testing::Values("scale", "angles"));

// ---- linked timelines ---------------------------------------------------------------------

// R-5.08 / B-5.09
TEST(TransformTimeline, OriginAnglesAndScaleKeyedTogetherShareTheRootsClock)
{
    const Json origin = Timeline(V3(10, 20, 0),
        Animation(true, Options(10, 10, "single", { { "name", "rise" }, { "startpaused", true }, { "children", Json::array({ { { "key", "angles" } } }) } }),
                  { Keys({ { 0, 0 }, { 10, 40 } }) }));
    const Json angles = Timeline(V3(0, 0, 0),
        Animation(true, Options(10, 10, "single", { { "parent", { { "key", "origin" } } }, { "children", Json::array({ { { "key", "scale" } } }) } }),
                  { Json(), Json(), Keys({ { 0, 0 }, { 10, 90 } }) }));
    const Json scale = Timeline(V3(1, 1, 1),
        Animation(true, Options(10, 10, "single", { { "parent", { { "key", "angles" } } } }), { Keys({ { 0, 0 }, { 10, 1 } }) }));

    Live live(TimelineScene(Json::array({ ImageLayer(21, "L", { { "origin", origin }, { "angles", angles }, { "scale", scale } }) })));
    ASSERT_TRUE(live.ok());

    auto expect_pose = [&](float x, float angle, float scale_x, const char* when) {
        SCOPED_TRACE(when);
        EXPECT_FLOAT_EQ(live.Origin("L")[0], x);
        EXPECT_FLOAT_EQ(live.Angles("L")[2], angle);
        EXPECT_FLOAT_EQ(live.Scale("L")[0], scale_x);
    };

    expect_pose(10, 0, 1, "after parse");
    live.Tick(5.0);
    expect_pose(10, 0, 1, "the root is paused, so all three are");
    EXPECT_FALSE(live.Animating());

    ScalarAnimationPlayback* clock = live.rt().FindScalarAnimation("L", "rise");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    live.Tick(0.5);
    expect_pose(30, 45, 1.5f, "half way");
    live.Tick(0.5);
    expect_pose(50, 90, 2, "end");
    EXPECT_FALSE(live.Animating());
    EXPECT_EQ(live.rt().scriptErrorCount(), 0u);
}

// ---- every kind of object -----------------------------------------------------------------

Json PoseTimelines()
{
    const Json animation = Animation(true, Options(10, 10, "single"), { Keys({ { 0, 0 }, { 10, 1 } }) });
    // The key reaches 1 at frame 10 on a 10 fps clock: one unit per second.
    return { { "scale", Timeline(V3(1, 2, 3), animation) }, { "angles", Timeline(V3(0.25, 0.5, 0.75), animation) } };
}

void ExpectPose(SceneNode& node, float t, const char* what)
{
    SCOPED_TRACE(what);
    EXPECT_NEAR(node.Scale().x(), 1.0f + t, 1e-5f);
    EXPECT_NEAR(node.Scale().y(), 2.0f, 1e-5f);
    EXPECT_NEAR(node.Scale().z(), 3.0f, 1e-5f);
    EXPECT_NEAR(node.Rotation().x(), 0.25f + t, 1e-5f);
    EXPECT_NEAR(node.Rotation().y(), 0.5f, 1e-5f);
    EXPECT_NEAR(node.Rotation().z(), 0.75f, 1e-5f);
}

// R-5.10 / B-5.10 (block 1)
TEST(TransformTimeline, TextParticleAndLightLayersTakeScaleAndAnglesTimelines)
{
    Json objects = Json::array({
        Merged({ { "id", 21 }, { "name", "label" }, { "text", "hello" }, { "font", "Arial" }, { "visible", true } }, PoseTimelines()),
        Merged({ { "id", 22 }, { "name", "sparks" }, { "particle", "particle.json" }, { "visible", true } }, PoseTimelines()),
        Merged({ { "id", 23 }, { "name", "bulb" }, { "light", "point" }, { "radius", 100 }, { "intensity", 1 }, { "color", V3(1, 1, 1) }, { "visible", true } },
               PoseTimelines()),
    });
    Live live(TimelineScene(objects));
    ASSERT_TRUE(live.ok());
    SceneNode* label  = live.node("label");
    SceneNode* sparks = live.node("sparks");
    ASSERT_NE(label, nullptr);
    ASSERT_NE(sparks, nullptr);
    ASSERT_EQ(live.scene().lights.size(), 1u);
    SceneNode* bulb = live.scene().lights[0]->node();
    ASSERT_NE(bulb, nullptr);

    auto expect_all = [&](float t, const char* when) {
        SCOPED_TRACE(when);
        ExpectPose(*label, t, "text");
        ExpectPose(*sparks, t, "particle");
        ExpectPose(*bulb, t, "light");
    };
    expect_all(0.0f, "t=0");
    live.Tick(0.5);
    expect_all(0.5f, "t=0.5");
    live.Tick(0.5);
    expect_all(1.0f, "t=1");
}

// R-5.10 / B-5.10 (block 2)
TEST(TransformTimeline, ATextLayersTimelinePlaysOnTheNodeItsChildHangsFrom)
{
    Json caption = { { "id", 31 }, { "name", "caption" }, { "text", "hello" }, { "font", "Arial" }, { "visible", true },
                     { "scale", Timeline(V3(1, 1, 1), Animation(true, Options(10, 10, "single"), { Keys({ { 0, 0 }, { 10, 1 } }) })) } };
    Live live(TimelineScene(Json::array({ caption, ImageLayer(32, "underline", { { "parent", 31 }, { "origin", V3(5, 6, 0) } }) })));
    ASSERT_TRUE(live.ok());
    SceneNode* node = live.node("caption");
    ASSERT_NE(node, nullptr);
    ASSERT_GE(node->GetChildren().size(), 1u);
    SceneNode* child = node->GetChildren().front().get();
    ASSERT_NE(child, nullptr);
    EXPECT_EQ(child->Name(), "underline");

    live.Tick(0.5);
    EXPECT_NEAR(node->Scale().x(), 1.5f, 1e-5f);
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3) - node->Translate().x(), 7.5, 1e-4);
}

// R-5.10 / B-5.10 (block 3)
TEST(TransformTimeline, AModelLayerTakesScaleAndAnglesTimelines)
{
    ParseRig         rig(LeafModelAssets());
    const Json       planet = Merged({ { "id", 7 }, { "name", "planet" }, { "model", "planet.mdl" }, { "perspective", true }, { "visible", true } }, PoseTimelines());
    auto             scene  = rig.Parse(PerspectiveScene(Json::array({ planet }), { { "bloom", false } }), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneNode* node = FindRootChild(*scene, "planet");
    ASSERT_NE(node, nullptr);

    ExpectPose(*node, 0.0f, "parse");
    scene->runtime->Tick(1.0);
    ExpectPose(*node, 1.0f, "after one second");
}

// ---- wraploop ------------------------------------------------------------------------------

class WrapLoop : public testing::TestWithParam<bool> {};

// R-5.11 / B-5.11
TEST_P(WrapLoop, WrapLoopReturnsTheCurveToItsFirstKeyByTheEndOfTheLength)
{
    const bool wrap = GetParam();
    const auto timeline = [&](const Json& base) {
        return Timeline(base, Animation(false, Options(10, 10, "loop", { { "wraploop", wrap } }), { Keys({ { 0, 0 }, { 5, 1 } }) }));
    };
    Live live(TimelineScene(Json::array({ ImageLayer(21, "W", { { "scale", timeline(V3(0, 1, 1)) }, { "origin", timeline(V3(0, 0, 0)) } }) })));
    ASSERT_TRUE(live.ok());
    SceneNode* node = live.node("W");
    ASSERT_NE(node, nullptr);

    live.Tick(0.5);
    EXPECT_FLOAT_EQ(node->Scale().x(), 1.0f);
    EXPECT_FLOAT_EQ(node->Translate().x(), 1.0f);
    live.Tick(0.25);
    EXPECT_FLOAT_EQ(node->Scale().x(), wrap ? 0.5f : 1.0f);
    EXPECT_FLOAT_EQ(node->Translate().x(), wrap ? 0.5f : 1.0f);
    live.Tick(0.25);
    EXPECT_FLOAT_EQ(node->Scale().x(), 0.0f);
    EXPECT_FLOAT_EQ(node->Translate().x(), 0.0f);
}

INSTANTIATE_TEST_SUITE_P(Flag, WrapLoop, testing::Bool(), [](const testing::TestParamInfo<bool>& info) { return info.param ? "Wrapped" : "Plain"; });

// ---- anchors -------------------------------------------------------------------------------

// R-5.12 / B-5.12
TEST(AnchoredTransform, AScaleTimelineKeepsALeftAnchoredLayersEdgeInPlace)
{
    Live live(TimelineScene(Json::array({ ImageLayer(21, "AN",
        { { "alignment", "left" },
          { "origin", V3(10, 0, 0) },
          { "scale", Timeline(V3(1, 1, 1), Animation(false, Options(10, 10, "single"), { Keys({ { 0, 1 }, { 10, 3 } }), Keys({ { 0, 1 }, { 10, 3 } }) })) } }) })));
    ASSERT_TRUE(live.ok());
    SceneNode* node = live.node("AN");
    ASSERT_NE(node, nullptr);
    const float width = live.rt().NodeSize("AN").x();
    ASSERT_FLOAT_EQ(width, 64.0f);

    EXPECT_FLOAT_EQ(node->Scale().x(), 1.0f);
    EXPECT_FLOAT_EQ(node->Translate().x(), 10.0f + width * 1.0f * 0.5f);
    live.Tick(1.0);
    EXPECT_FLOAT_EQ(node->Scale().x(), 3.0f);
    EXPECT_FLOAT_EQ(node->Translate().x(), 10.0f + width * 3.0f * 0.5f);
}

// R-5.14 / B-5.13
TEST(AnchoredTransform, TheAnchorOffsetIsDerivedAgainFromScriptedOriginAndScale)
{
    const Json objects = Json::array({
        ImageLayer(21, "X", { { "alignment", "bottom" }, { "size", V2(200, 100) },
                              { "origin", { { "value", V3(50, 0, 0) }, { "script", "export function update(value) { return value; }" } } } }),
        ImageLayer(22, "Y", { { "alignment", "left" }, { "size", V2(100, 100) }, { "scale", V3(2, 2, 1) }, { "origin", V3(10, 0, 0) } }),
        ImageLayer(23, "Z", { { "alignment", "left" }, { "size", V2(100, 100) }, { "origin", V3(10, 0, 0) },
                              { "scale", { { "value", V3(2, 2, 1) }, { "script", "export function update() { return new Vec3(0.5, 0.5, 1); }" } } } }),
    });
    Live live(QuietScene(objects, { { "bloom", false }, { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } }), BasicAssets(), ProjectProperties {});
    ASSERT_TRUE(live.ok());
    SceneNode* x = live.node("X");
    SceneNode* y = live.node("Y");
    SceneNode* z = live.node("Z");
    ASSERT_TRUE(x != nullptr && y != nullptr && z != nullptr);

    EXPECT_FLOAT_EQ(x->Translate().y(), live.rt().NodeSize("X").y() * 0.5f);
    EXPECT_FLOAT_EQ(y->Translate().x(), 10.0f + live.rt().NodeSize("Y").x() * 2.0f * 0.5f);
    // A scripted value shows the script's result from the first tick on; until then the layer
    // stands on its authored scale, and its anchor offset must agree with that scale.
    EXPECT_FLOAT_EQ(z->Scale().x(), 2.0f);
    EXPECT_FLOAT_EQ(z->Translate().x(), 10.0f + live.rt().NodeSize("Z").x() * 2.0f * 0.5f);
    live.Tick(0.0);
    EXPECT_FLOAT_EQ(z->Scale().x(), 0.5f);
    EXPECT_FLOAT_EQ(z->Translate().x(), 10.0f + live.rt().NodeSize("Z").x() * 0.5f * 0.5f);

    live.Tick(0.01);
    EXPECT_FLOAT_EQ(x->Translate().x(), 50.0f);
    EXPECT_FLOAT_EQ(x->Translate().y(), live.rt().NodeSize("X").y() * 0.5f);
    EXPECT_FLOAT_EQ(z->Translate().x(), 10.0f + live.rt().NodeSize("Z").x() * 0.5f * 0.5f) << "the offset is not stacked on the origin again";
    EXPECT_EQ(live.rt().scriptErrorCount(), 0u);
}

// ---- click-script sound layers of layers that share a name --------------------------------

// The script every "tap target" layer carries. Properties: the click counts that fire a voice,
// the layer names of the voices, and the pause after which the counter starts over.
constexpr const char* kTapScript = R"JS('use strict';
export var scriptProperties = createScriptProperties()
    .addText({ name: 'count1', label: 'first count', value: '1' })
    .addText({ name: 'voice1', label: 'first voice', value: '' })
    .addText({ name: 'count2', label: 'second count', value: '2' })
    .addText({ name: 'voice2', label: 'second voice', value: '' })
    .addText({ name: 'waitingtime', label: 'reset after', value: '1' })
    .finish();

var clicks = 0;
var idle = 0;
var counting = false;

function speak(name, wanted) {
    if (clicks !== Number(wanted)) return;
    var voice = thisScene.getLayer(name);
    if (voice) voice.play();
}

export function cursorClick(event) {
    counting = true;
    clicks += 1;
    speak(scriptProperties.voice1, scriptProperties.count1);
    speak(scriptProperties.voice2, scriptProperties.count2);
}

export function update(value) {
    if (counting) {
        idle += engine.frametime;
        if (idle > Number(scriptProperties.waitingtime)) {
            clicks = 0;
            idle = 0;
            counting = false;
        }
    }
    return value;
}
)JS";

Json TapTarget(int id, double x, const std::string& voice)
{
    const Json bound = { { "user", "click_count" }, { "value", { { "user", "unused_default" }, { "value", "2" } } } };
    return { { "id", id }, { "name", "tap target" }, { "image", "image.json" }, { "origin", V3(x, 150, 0) }, { "size", V2(80, 80) },
             { "visible", { { "value", true },
                            { "script", kTapScript },
                            { "scriptproperties", { { "count1", bound }, { "voice1", voice }, { "count2", "200" }, { "voice2", "Voice2" }, { "waitingtime", "1.0" } } } } } };
}

Json SoundLayer(int id, const std::string& name, const std::string& file, const std::string& mode, bool silent)
{
    return { { "id", id }, { "name", name }, { "sound", Json::array({ "sounds/" + file }) }, { "playbackmode", mode }, { "startsilent", silent } };
}

// R-5.15 / B-5.14
TEST(ClickScripts, OnlyTheHitOneOfThreeSameNamedLayersPlaysItsOwnSound)
{
    const Json objects = Json::array({
        TapTarget(43, 100, "headAudio"),
        TapTarget(59, 200, "bodyAudio"),
        TapTarget(62, 300, "legAudio"),
        SoundLayer(74, "bodyAudio", "body.wav", "single", true),
        SoundLayer(75, "headAudio", "head.wav", "single", true),
        SoundLayer(77, "legAudio", "leg.wav", "single", true),
        SoundLayer(69, "backgroundAudio", "background.wav", "loop", false),
    });
    ProjectProperties properties;
    properties["click_count"] = RuntimeScalarValue::String("2");
    Live live(QuietScene(objects, { { "bloom", false }, { "orthogonalprojection", { { "width", 400 }, { "height", 300 } } } }), BasicAssets(), properties);
    ASSERT_TRUE(live.ok());
    SceneRuntimeContext& rt = live.rt();

    auto voices = [&] { return std::vector<bool> { rt.SoundLayerPlaying("headAudio"), rt.SoundLayerPlaying("bodyAudio"), rt.SoundLayerPlaying("legAudio") }; };
    const std::vector<bool> silent { false, false, false };

    EXPECT_TRUE(rt.SoundLayerPlaying("backgroundAudio"));
    EXPECT_EQ(voices(), silent);

    rt.SetCursorInput(0.5f, 0.5f);
    rt.SetCursorEnter(true);
    EXPECT_TRUE(rt.DispatchCursorFrameEvents(false));
    live.Tick(1.0 / 60.0);
    EXPECT_EQ(voices(), silent) << "hovering says nothing";

    rt.SetCursorButtons(0, 1, 1);
    EXPECT_TRUE(rt.DispatchCursorFrameEvents(true));
    live.Tick(1.0 / 60.0);
    EXPECT_EQ(voices(), silent) << "the first click counts one, and the voice is for the second";

    rt.SetCursorButtons(0, 0, 0);
    rt.DispatchCursorFrameEvents(true);
    live.Tick(1.0 / 60.0);
    rt.SetCursorButtons(0, 1, 1);
    rt.DispatchCursorFrameEvents(true);
    live.Tick(1.0 / 60.0);
    EXPECT_EQ(voices(), (std::vector<bool> { false, true, false })) << "only the middle layer's own voice plays";
    EXPECT_EQ(rt.scriptErrorCount(), 0u);
}

} // namespace
