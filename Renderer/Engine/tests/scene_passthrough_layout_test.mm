// A pass-through layer (a project layer under effects, a compose layer) copies the part of the
// screen it is drawn over and draws the copy back through its effects. The copy is taken from
// where the layer is drawn -- its world transform under every parent -- and follows the groups
// when something moves them while the scene runs. An identity effect makes the result the
// backdrop itself, so every test compares with the backdrop drawn alone.
//
// Every GPU image is private to the process; no window or drawable is shown.

#include <gtest/gtest.h>

#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include "Runtime/SceneRuntimeContext.hpp"

#include <string>

namespace
{
using namespace we_test;

constexpr uint32_t kWidth  = 256;
constexpr uint32_t kHeight = 144;

constexpr int kBackdropId = 1;
constexpr int kGroupId    = 10;
constexpr int kLayerId    = 11;

// A fragment shader that copies its texture, and a vertex shader that takes the card's corners as
// clip space positions: the pair a pass-through material that draws its footprint 1:1 would use.
const char kCopyFragment[] = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Color4;
}
)";
const char kClipSpaceVertex[] = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
    gl_Position = vec4(a_Position.xy, 0.0, 1.0);
    v_TexCoord = a_TexCoord;
}
)";

// An effect that returns what it receives and makes it opaque. The screen it is applied to is opaque
// everywhere, so it is an identity there -- and, unlike a plain tint, it paints black wherever the
// pass-through card did not copy anything, so a card that copies the wrong part of the screen shows.
std::string AddOpaqueIdentityEffect(ScenePackage& package)
{
    package.InstallStandardAssets();
    package.AddShader("harness_opaque", StandardVertexShader(), R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    vec4 texel = texSample2D(g_Texture0, v_TexCoord);
    gl_FragColor = vec4(texel.rgb, 1.0);
}
)");
    package.PutJson("materials/opaque_identity.json",
                    { { "passes", Json::array({ { { "shader", "harness_opaque" },
                                                  { "textures", Json::array({ nullptr }) },
                                                  { "blending", "disabled" },
                                                  { "cullmode", "nocull" },
                                                  { "depthtest", "disabled" },
                                                  { "depthwrite", "disabled" } } }) } });
    package.PutJson("effects/opaque_identity.json",
                    { { "name", "opaque_identity" },
                      { "passes", Json::array({ { { "material", "materials/opaque_identity.json" } } }) } });
    return "effects/opaque_identity.json";
}

Image Backdrop()
{
    return Image::Quadrants(kWidth, kHeight, { 220, 40, 40, 255 }, { 40, 220, 40, 255 }, { 40, 40, 220, 255 },
                            { 220, 220, 40, 255 });
}

// The shader a pass-through material uses. `clip_space` is the one named `passthrough`, whose card
// is drawn straight into the effect buffer; the other goes through the camera of the card.
struct Flavour {
    const char* name;
    bool        clip_space;
};
constexpr Flavour kFlavours[] = { { "camera", false }, { "clipspace", true } };

// Writes a model that is a project layer: as large as the canvas, taking no picture of its own, it
// copies the screen behind it.
std::string AddProjectLayerModel(ScenePackage& package, const Flavour& flavour)
{
    ModelOptions options;
    if (flavour.clip_space) {
        package.AddShader("passthrough", kClipSpaceVertex, kCopyFragment);
        options.shader = "passthrough";
    }
    const std::string model = package.AddImageModel("projectlayer", "_rt_FullFrameBuffer", options);
    package.PutJson(model, { { "material", "materials/projectlayer.json" },
                             { "autosize", true },
                             { "projectlayer", true },
                             { "passthrough", true } });
    return model;
}

struct World {
    std::vector<Json> objects;
    Json              properties { Json::object() };
};

// The backdrop: four colours across the canvas, drawn first.
void AddBackdrop(ScenePackage& package, World& world)
{
    ImageLayer backdrop;
    backdrop.id    = kBackdropId;
    backdrop.name  = "backdrop";
    backdrop.model = package.AddImageModel("backdrop", package.AddTexture("backdrop", Backdrop()));
    world.objects.push_back(ImageLayerJson(backdrop));
}

// The pass-through layer with an identity effect; no origin saved when `origin` is false.
Json PassThroughLayer(ScenePackage& package, const Flavour& flavour, int parent, bool origin)
{
    ImageLayer layer;
    layer.id      = kLayerId;
    layer.name    = "screen";
    layer.model   = AddProjectLayerModel(package, flavour);
    layer.parent  = parent;
    layer.effects = { EffectUse(AddOpaqueIdentityEffect(package), Json::object(), 21) };
    Json json     = ImageLayerJson(layer);
    if (!origin) json.erase("origin");
    return json;
}

Json Group(std::array<float, 3> origin, const char* scale = nullptr)
{
    Json group = GroupJson(kGroupId, "group", origin);
    if (scale != nullptr) group["scale"] = scale;
    return group;
}

// The backdrop alone, which is what every scene below has to draw.
Image BackdropAlone()
{
    ScenePackage package;
    World        world;
    AddBackdrop(package, world);
    package.SetProject();
    package.SetScene(SceneJson({}, world.objects));
    GpuScene scene(package);
    EXPECT_TRUE(scene.ok()) << scene.error();
    return scene.Run(3);
}

// Blanks the strip around the quadrant seams, in both pictures, before they are compared: a card
// that is scaled up samples its copy at half resolution and softens the seams by a few pixels.
void BlankSeams(Image* image)
{
    for (uint32_t y = 0; y < image->height; ++y) {
        for (uint32_t x = 0; x < image->width; ++x) {
            const bool near_x = x + 4 >= kWidth / 2 && x <= kWidth / 2 + 4;
            const bool near_y = y + 4 >= kHeight / 2 && y <= kHeight / 2 + 4;
            if (near_x || near_y) image->Set(x, y, { 0, 0, 0, 255 });
        }
    }
}

::testing::AssertionResult SameAwayFromTheSeams(Image actual, Image expected, int tolerance = 3)
{
    BlankSeams(&actual);
    BlankSeams(&expected);
    return ExpectSamePicture(actual, expected, tolerance);
}

class PassThroughLayout : public ::testing::TestWithParam<Flavour> {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }
};

// The pass that draws the footprint straight into clip space (the `passthrough` shader) lays the
// copy out in canvas coordinates, which is the screen again only for a layer that covers the whole
// canvas; under a moved or scaled group the camera variant is the one that returns the backdrop.
class PassThroughLayoutMoved : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }
    const Flavour flavour { kFlavours[0] };
};

} // namespace

INSTANTIATE_TEST_SUITE_P(Shaders, PassThroughLayout, ::testing::ValuesIn(kFlavours),
                         [](const ::testing::TestParamInfo<Flavour>& info) { return std::string(info.param.name); });

TEST_P(PassThroughLayout, ALayerAloneCopiesTheScreenBehindIt)
{
    ScenePackage package;
    World        world;
    AddBackdrop(package, world);
    world.objects.push_back(PassThroughLayer(package, GetParam(), -1, true));
    package.SetProject();
    package.SetScene(SceneJson({}, world.objects));
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(ExpectSamePicture(scene.Run(3), BackdropAlone(), 1));
}

TEST_P(PassThroughLayout, ALayerWithNoOriginInAGroupAtTheCentreCopiesTheWholeScreen)
{
    ScenePackage package;
    World        world;
    AddBackdrop(package, world);
    world.objects.push_back(Group({ 128.0f, 72.0f, 0.0f }));
    world.objects.push_back(PassThroughLayer(package, GetParam(), kGroupId, false));
    package.SetProject();
    package.SetScene(SceneJson({}, world.objects));
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    const Image frame = scene.Run(3);
    KeepPicture("passthrough_in_group", frame);
    EXPECT_TRUE(ExpectSamePicture(frame, BackdropAlone(), 1));
}

TEST_F(PassThroughLayoutMoved, ALayerUnderAMovedAndScaledGroupCopiesTheScreenWhereItIsDrawn)
{
    ScenePackage package;
    World        world;
    AddBackdrop(package, world);
    world.objects.push_back(Group({ 148.0f, 62.0f, 0.0f }, "2 2 1"));
    world.objects.push_back(PassThroughLayer(package, flavour, kGroupId, false));
    package.SetProject();
    package.SetScene(SceneJson({}, world.objects));
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    const Image frame = scene.Run(3);
    KeepPicture("passthrough_under_scaled_group", frame);
    EXPECT_TRUE(SameAwayFromTheSeams(frame, BackdropAlone()));
}

TEST_F(PassThroughLayoutMoved, AGroupThatAPropertyMovesAndScalesAfterLoadIsFollowedWithOneLayoutPerChange)
{
    ScenePackage package;
    World        world;
    AddBackdrop(package, world);
    Json group = Group({ 128.0f, 72.0f, 0.0f });
    group["scale"]  = PropertyBinding("zoom", "1 1 1");
    group["origin"] = PropertyBinding("shift", "128 72 0");
    world.objects.push_back(group);
    world.objects.push_back(PassThroughLayer(package, flavour, kGroupId, false));
    package.SetProject({ { "zoom", SliderProperty(1.0, 0.5, 4.0) }, { "shift", { { "type", "vec3" }, { "value", "128 72 0" } } } });
    package.SetScene(SceneJson({}, world.objects));
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_NE(scene.runtime(), nullptr);
    const Image backdrop = BackdropAlone();

    // Nothing moves: no card is laid out again, frame after frame.
    const auto before = scene.runtime()->PassthroughCardLayoutCount();
    ASSERT_TRUE(ExpectSamePicture(scene.Run(4), backdrop, 1));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before) << "a still scene lays nothing out";

    // The group is scaled: exactly one more layout, then quiet again.
    ASSERT_TRUE(scene.SetProperty("zoom", 2.0));
    ASSERT_TRUE(scene.Step(1));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before + 1);
    ASSERT_TRUE(scene.Step(3));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before + 1);
    EXPECT_TRUE(SameAwayFromTheSeams(scene.Picture(), backdrop));

    // The group is moved: one more.
    ASSERT_TRUE(scene.SetProperty("shift", "148 62 0"));
    ASSERT_TRUE(scene.Step(1));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before + 2);
    ASSERT_TRUE(scene.Step(3));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before + 2);
    EXPECT_TRUE(SameAwayFromTheSeams(scene.Picture(), backdrop));

    // And back to rest.
    ASSERT_TRUE(scene.SetProperty("zoom", 1.0));
    ASSERT_TRUE(scene.SetProperty("shift", "128 72 0"));
    ASSERT_TRUE(scene.Step(1));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before + 3);
    ASSERT_TRUE(scene.Step(2));
    EXPECT_TRUE(ExpectSamePicture(scene.Picture(), backdrop, 1));
    EXPECT_EQ(scene.RebuildCount(), 0) << "a card the scene says can move is rewritten in place, no new graph";
}

TEST_F(PassThroughLayoutMoved, AGroupThatAScriptMovesAfterLoadIsFollowedWithOneLayoutPerChange)
{
    ScenePackage package;
    World        world;
    AddBackdrop(package, world);
    // The group sits at the canvas centre for the first tenth of a second, then jumps once.
    Json group      = Group({ 128.0f, 72.0f, 0.0f });
    group["origin"] = ScriptedValue(R"('use strict';
export function update(value) {
    value.x = engine.runtime > 0.1 ? 148 : 128;
    value.y = engine.runtime > 0.1 ? 62 : 72;
    return value;
}
)",
                                    "128 72 0");
    group["scale"]  = "2 2 1";
    world.objects.push_back(group);
    world.objects.push_back(PassThroughLayer(package, flavour, kGroupId, false));
    package.SetProject();
    package.SetScene(SceneJson({}, world.objects));
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_NE(scene.runtime(), nullptr);
    const Image backdrop = BackdropAlone();

    // The first frames are before the jump; the layout the load made is the one that serves them.
    ASSERT_TRUE(scene.Step(2));
    const auto before = scene.runtime()->PassthroughCardLayoutCount();
    ASSERT_TRUE(scene.Step(2));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before) << "nothing moved yet";
    EXPECT_TRUE(SameAwayFromTheSeams(scene.Picture(), backdrop));

    // 0.1 s is six frames; run well past it.
    ASSERT_TRUE(scene.Step(12));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before + 1) << "one jump, one layout";
    EXPECT_TRUE(SameAwayFromTheSeams(scene.Picture(), backdrop));
    ASSERT_TRUE(scene.Step(6));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), before + 1);
    EXPECT_EQ(scene.RebuildCount(), 0) << "a card the scene says can move is rewritten in place, no new graph";
}

TEST_F(PassThroughLayoutMoved, AGroupThatNothingInItsOwnFileDrivesIsFollowedWhenAnotherLayersScriptMovesIt)
{
    ScenePackage package;
    World        world;
    // The backdrop's alpha is scripted: after a tenth of a second the script moves and scales the
    // group, which holds only plain values in the scene file.
    ImageLayer backdrop;
    backdrop.id    = kBackdropId;
    backdrop.name  = "backdrop";
    backdrop.model = package.AddImageModel("backdrop", package.AddTexture("backdrop", Backdrop()));
    backdrop.alpha = ScriptedValue(R"('use strict';
export function update(value) {
    if (engine.runtime > 0.1) {
        var group = thisScene.getLayer('group');
        group.origin = new Vec3(148, 62, 0);
        group.scale = new Vec3(2, 2, 1);
    }
    return value;
}
)",
                                   1.0);
    world.objects.push_back(ImageLayerJson(backdrop));
    Json group     = Group({ 128.0f, 72.0f, 0.0f });
    group["scale"] = "1 1 1";
    world.objects.push_back(group);
    world.objects.push_back(PassThroughLayer(package, flavour, kGroupId, false));
    package.SetProject();
    package.SetScene(SceneJson({}, world.objects));
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_NE(scene.runtime(), nullptr);
    const Image backdrop_alone = BackdropAlone();

    ASSERT_TRUE(scene.Step(3));
    const auto layouts  = scene.runtime()->PassthroughCardLayoutCount();
    const int  rebuilds = scene.RebuildCount();
    EXPECT_TRUE(ExpectSamePicture(scene.Picture(), backdrop_alone, 1));

    ASSERT_TRUE(scene.Step(12));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), layouts + 1) << "one move, one layout";
    EXPECT_TRUE(SameAwayFromTheSeams(scene.Picture(), backdrop_alone));
    ASSERT_TRUE(scene.Step(6));
    EXPECT_EQ(scene.runtime()->PassthroughCardLayoutCount(), layouts + 1);
    EXPECT_EQ(scene.RebuildCount(), rebuilds + 1)
        << "a card nothing was meant to move is fixed geometry: the graph is built again once";
}
