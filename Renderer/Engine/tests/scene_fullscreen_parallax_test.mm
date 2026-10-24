// Camera parallax moves each layer by its depth as the cursor moves. A fullscreen layer
// (post-processing: it copies the whole screen and draws it back) has no depth of its own, whatever
// its scene saved, so the copy it draws back covers the whole screen wherever the cursor is. The
// layers drawn before it, and the layers below it in the tree, still move with their own depth.
// Each case compares with the same backdrop drawn without the fullscreen layer, same cursor.
//
// Every GPU image is private to the process; no window or drawable is shown.

#include <gtest/gtest.h>

#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include <functional>
#include <string>

namespace
{
using namespace we_test;

constexpr uint32_t kWidth  = 256;
constexpr uint32_t kHeight = 144;

constexpr int kBackdropId   = 1;
constexpr int kFullscreenId = 5;

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

struct Flavour {
    const char* name;
    bool        clip_space;
};
constexpr Flavour kFlavours[] = { { "camera", false }, { "clipspace", true } };

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

SceneGeneral ParallaxGeneral()
{
    SceneGeneral general;
    general.parallax                = true;
    general.parallax_amount         = 0.5f;
    general.parallax_delay          = 0.0f;
    general.parallax_mouse_influence = 1.0f;
    general.clear_color             = { 0.0f, 0.0f, 0.0f };
    return general;
}

Json BackdropLayer(ScenePackage& package, int parent = -1, std::array<float, 3> origin = { 128.0f, 72.0f, 0.0f })
{
    ImageLayer layer;
    layer.id     = kBackdropId;
    layer.name   = "backdrop";
    layer.model  = package.AddImageModel("backdrop", package.AddTexture("backdrop", Backdrop()));
    layer.parent = parent;
    layer.origin = origin;
    return ImageLayerJson(layer);
}

// A fullscreen layer: its model is flagged `fullscreen` and `passthrough`, so it copies the screen.
Json FullscreenLayer(ScenePackage& package, const Flavour& flavour, bool with_effect)
{
    ModelOptions options;
    if (flavour.clip_space) {
        package.AddShader("passthrough", kClipSpaceVertex, kCopyFragment);
        options.shader = "passthrough";
    }
    const std::string model = package.AddImageModel("fullscreenlayer", "_rt_FullFrameBuffer", options);
    package.PutJson(model, { { "material", "materials/fullscreenlayer.json" },
                             { "fullscreen", true },
                             { "passthrough", true } });
    ImageLayer layer;
    layer.id    = kFullscreenId;
    layer.name  = "post";
    layer.model = model;
    if (with_effect) layer.effects = { EffectUse(AddOpaqueIdentityEffect(package), Json::object(), 21) };
    return ImageLayerJson(layer);
}

struct CursorPictures {
    Image top_left;
    Image bottom_right;
};

// Draws the scene with the cursor at the top-left corner and then at the bottom-right corner.
CursorPictures DrawAtTheCorners(const std::function<std::vector<Json>(ScenePackage&)>& build)
{
    ScenePackage package;
    const auto   objects = build(package);
    package.SetProject();
    package.SetScene(SceneJson(ParallaxGeneral(), objects));
    GpuScene scene(package);
    EXPECT_TRUE(scene.ok()) << scene.error();
    CursorPictures pictures;
    scene.SetPointer(0.0, 0.0);
    pictures.top_left = scene.Run(10);
    scene.SetPointer(1.0, 1.0);
    pictures.bottom_right = scene.Run(10);
    return pictures;
}

CursorPictures BackdropAlone()
{
    return DrawAtTheCorners([](ScenePackage& package) { return std::vector<Json> { BackdropLayer(package) }; });
}

class FullscreenParallax : public ::testing::TestWithParam<Flavour> {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }

    // The scene drawn with the fullscreen layer must equal the backdrop alone at both corners.
    void ExpectBackdropAtBothCorners(const CursorPictures& drawn)
    {
        const CursorPictures alone = BackdropAlone();
        KeepPicture("fullscreen_parallax_tl", drawn.top_left);
        KeepPicture("fullscreen_parallax_br", drawn.bottom_right);
        EXPECT_TRUE(ExpectSamePicture(drawn.top_left, alone.top_left, 2)) << "cursor at the top-left";
        EXPECT_TRUE(ExpectSamePicture(drawn.bottom_right, alone.bottom_right, 2)) << "cursor at the bottom-right";
    }
};

} // namespace

INSTANTIATE_TEST_SUITE_P(Shaders, FullscreenParallax, ::testing::ValuesIn(kFlavours),
                         [](const ::testing::TestParamInfo<Flavour>& info) { return std::string(info.param.name); });

TEST(FullscreenParallaxBaseline, ANormalLayerAtDepthOneMovesWithTheCursor)
{
    WE_SKIP_WITHOUT_METAL();
    const CursorPictures alone = BackdropAlone();
    ASSERT_FALSE(alone.top_left.empty());
    EXPECT_GT(CountDifferingPixels(alone.top_left, alone.bottom_right, 8), 500u)
        << "the scene has to show parallax for the other tests to mean anything";
}

TEST_P(FullscreenParallax, WithNoEffectItDrawsNothingAndTheBackdropMoves)
{
    const Flavour flavour = GetParam();
    ExpectBackdropAtBothCorners(DrawAtTheCorners([&](ScenePackage& package) {
        return std::vector<Json> { BackdropLayer(package), FullscreenLayer(package, flavour, false) };
    }));
}

TEST_P(FullscreenParallax, WithAnEffectItsCopyCoversTheWholeScreenWhereverTheCursorIs)
{
    const Flavour flavour = GetParam();
    ExpectBackdropAtBothCorners(DrawAtTheCorners([&](ScenePackage& package) {
        return std::vector<Json> { BackdropLayer(package), FullscreenLayer(package, flavour, true) };
    }));
}

TEST_P(FullscreenParallax, ASavedDepthOfZeroChangesNothing)
{
    const Flavour flavour = GetParam();
    ExpectBackdropAtBothCorners(DrawAtTheCorners([&](ScenePackage& package) {
        Json fullscreen             = FullscreenLayer(package, flavour, true);
        fullscreen["parallaxDepth"] = "0 0";
        return std::vector<Json> { BackdropLayer(package), fullscreen };
    }));
}

TEST_P(FullscreenParallax, ADepthTheSceneSavedIsIgnored)
{
    const Flavour flavour = GetParam();
    ExpectBackdropAtBothCorners(DrawAtTheCorners([&](ScenePackage& package) {
        Json fullscreen             = FullscreenLayer(package, flavour, true);
        fullscreen["parallaxDepth"] = "0.5 0.5";
        return std::vector<Json> { BackdropLayer(package), fullscreen };
    }));
}

TEST_P(FullscreenParallax, AnOriginOffTheMiddleLeavesTheScreenCopyWhereItIs)
{
    const Flavour flavour = GetParam();
    ExpectBackdropAtBothCorners(DrawAtTheCorners([&](ScenePackage& package) {
        Json fullscreen      = FullscreenLayer(package, flavour, true);
        fullscreen["origin"] = "40.000000 20.000000 0.000000";
        return std::vector<Json> { BackdropLayer(package), fullscreen };
    }));
}

TEST_P(FullscreenParallax, ADepthAndAnOriginTheSceneSavedAreBothIgnored)
{
    const Flavour flavour = GetParam();
    ExpectBackdropAtBothCorners(DrawAtTheCorners([&](ScenePackage& package) {
        Json fullscreen             = FullscreenLayer(package, flavour, true);
        fullscreen["parallaxDepth"] = "0.5 0.5";
        fullscreen["origin"]        = "40.000000 20.000000 0.000000";
        return std::vector<Json> { BackdropLayer(package), fullscreen };
    }));
}

TEST_P(FullscreenParallax, TheLayersBelowItInTheTreeKeepMovingWithTheirOwnDepth)
{
    const Flavour flavour = GetParam();
    // The backdrop hangs from the fullscreen layer, which is saved where the backdrop is. Alone,
    // the backdrop is the same layer without a parent: both move by the tree's depth, one.
    ExpectBackdropAtBothCorners(DrawAtTheCorners([&](ScenePackage& package) {
        Json fullscreen      = FullscreenLayer(package, flavour, true);
        fullscreen["origin"] = "128.000000 72.000000 0.000000";
        Json backdrop        = BackdropLayer(package, kFullscreenId, { 0.0f, 0.0f, 0.0f });
        return std::vector<Json> { fullscreen, backdrop };
    }));
}
