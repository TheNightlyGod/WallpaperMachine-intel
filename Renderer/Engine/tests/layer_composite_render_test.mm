// What a layer drawn through effects leaves in its composite (the picture other layers sample),
// and what a layer with no area does. Pixel checks through the synthetic scene harness; every
// GPU image is private to the process.

#include <gtest/gtest.h>

#include "render_fixtures.hpp"
#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

namespace
{
using namespace we_test;
using namespace we_test::fixtures;

constexpr uint32_t kWidth  = 256;
constexpr uint32_t kHeight = 144;

// Multiplies the chain's picture by a colour; the chain starts from a white card, so the
// result is the colour itself, alpha included.
const char* kTranslucentColour = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * vec4(0.8, 0.4, 0.2, 0.25);
}
)";

// Shows only the alpha channel of the picture it samples.
const char* kShowAlpha = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = vec4(texSample2D(g_Texture0, v_TexCoord).aaa, 1.0);
}
)";

constexpr const char* kComposite = "_rt_imageLayerComposite_1";

// Layer 1 is the helper: a white card at the left of the canvas whose effect writes a
// translucent colour. Layer 2 shows the helper's composite on the right half of the canvas,
// without blending, as a colour or as its alpha.
void BuildScene(ScenePackage& package, std::array<float, 2> helper_size, const Json& helper_extra = Json::object(),
                bool show_alpha = false)
{
    const std::string effect = AddFragmentEffect(package, "translucent", kTranslucentColour);
    ImageLayer        helper;
    helper.id      = 1;
    helper.name    = "helper";
    helper.model   = package.AddImageModel("helper", "util/white");
    helper.origin  = { 64.0f, 72.0f, 0.0f };
    helper.size    = helper_size;
    helper.effects = { EffectUse(effect, Json::object(), 7) };
    helper.extra   = helper_extra;

    ImageLayer viewer;
    viewer.id     = 2;
    viewer.name   = "viewer";
    viewer.origin = { 192.0f, 72.0f, 0.0f };
    viewer.size   = { 128.0f, 144.0f };
    viewer.model  = show_alpha ? AddShaderModel(package, "alpha_view", "show_alpha", kShowAlpha,
                                                Json::array({ kComposite }), "disabled")
                               : package.AddImageModel("view", kComposite, { .blending = "disabled" });

    SceneGeneral general;
    general.clear_color = { 0.1f, 0.2f, 0.3f };
    package.SetProject();
    package.SetScene(SceneJson(general, { ImageLayerJson(helper), ImageLayerJson(viewer) }));
}

// The clear colour of the scenes above.
constexpr Rgba kClear { 26, 51, 77, 255 };

class LayerComposite : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }
};

} // namespace

TEST_F(LayerComposite, ATranslucentResultKeepsItsColourAndAlphaInTheComposite)
{
    ScenePackage package;
    BuildScene(package, { 64.0f, 64.0f });
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(4);
    ASSERT_FALSE(picture.empty());
    KeepPicture("composite_translucent", picture);

    // The viewer copies the composite without blending: colour as the chain wrote it.
    EXPECT_TRUE(ExpectPixel(picture, 192, 72, { 204, 102, 51, 255 }, 3));

    const Image target = scene.RenderTarget(kComposite);
    ASSERT_FALSE(target.empty());
    EXPECT_TRUE(ExpectPixel(target, target.width / 2, target.height / 2, { 204, 102, 51, 64 }, 3))
        << "the composite holds colour and alpha as written";
}

TEST_F(LayerComposite, TheAlphaOfTheChainIsWhatAnotherLayerReads)
{
    ScenePackage package;
    BuildScene(package, { 64.0f, 64.0f }, Json::object(), true);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(4);
    ASSERT_FALSE(picture.empty());
    EXPECT_TRUE(ExpectPixel(picture, 192, 72, { 64, 64, 64, 255 }, 3))
        << "an alpha of 0.25, neither squared nor lost";
}

TEST_F(LayerComposite, ALayerWithNoHeightFillsItsCompositeAndShowsNothing)
{
    for (const bool hidden : { true, false }) {
        SCOPED_TRACE(hidden ? "scaled to zero" : "shown");
        ScenePackage package;
        BuildScene(package, { 64.0f, 0.0f }, hidden ? Json { { "scale", "0 0 0" } } : Json::object());
        GpuScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        const Image picture = scene.Run(4);
        ASSERT_FALSE(picture.empty());
        KeepPicture(hidden ? "composite_no_height_hidden" : "composite_no_height_shown", picture);

        // What its effect made reaches the layer that reads it, colour and alpha.
        EXPECT_TRUE(ExpectPixel(picture, 192, 72, { 204, 102, 51, 255 }, 3));

        // Nothing of the card itself appears on the scene, where it would stand.
        EXPECT_TRUE(ExpectRegionAverage(picture, 0, 0, 128, kHeight, kClear, 0.5));

        // The composite is as wide as the card and as tall as the canvas.
        const Image target = scene.RenderTarget(kComposite);
        ASSERT_FALSE(target.empty());
        EXPECT_EQ(target.width, 64u);
        EXPECT_EQ(target.height, kHeight);
    }
}

TEST_F(LayerComposite, ALayerWithNoWidthTakesTheCanvasWidthForItsComposite)
{
    ScenePackage package;
    BuildScene(package, { 0.0f, 48.0f }, Json { { "scale", "0 0 0" } });
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(4);
    ASSERT_FALSE(picture.empty());
    EXPECT_TRUE(ExpectPixel(picture, 192, 72, { 204, 102, 51, 255 }, 3));
    EXPECT_TRUE(ExpectRegionAverage(picture, 0, 0, 128, kHeight, kClear, 0.5));
    const Image target = scene.RenderTarget(kComposite);
    ASSERT_FALSE(target.empty());
    EXPECT_EQ(target.width, kWidth);
    EXPECT_EQ(target.height, 48u);
}

TEST_F(LayerComposite, ALayerOneUnitThinKeepsItsSize)
{
    // Not a card with no area: it is not widened to the canvas, with or without an effect.
    for (const bool through_effect : { false, true }) {
        SCOPED_TRACE(through_effect ? "through an effect" : "plain");
        ScenePackage package;
        ImageLayer   thin;
        thin.id     = 1;
        thin.model  = package.AddImageModel("thin", "util/white");
        thin.origin = { 128.0f, 71.5f, 0.0f };
        thin.size   = { 64.0f, 1.0f };
        thin.color  = "1 0 0";
        if (through_effect) thin.effects = { EffectUse(package.AddTintEffect("warm"), { { "tint", "1 1 1" } }, 7) };
        SceneGeneral general;
        general.clear_color = { 0.1f, 0.2f, 0.3f };
        package.SetProject();
        package.SetScene(SceneJson(general, { ImageLayerJson(thin) }));

        GpuScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        const Image picture = scene.Run(3);
        ASSERT_FALSE(picture.empty());
        KeepPicture(through_effect ? "composite_thin_effect" : "composite_thin", picture);
        if (!through_effect) {
            EXPECT_TRUE(ExpectPixel(picture, 128, 72, { 255, 0, 0, 255 }, 3));
            EXPECT_TRUE(ExpectPixel(picture, 100, 72, { 255, 0, 0, 255 }, 3));
            EXPECT_TRUE(ExpectPixel(picture, 40, 72, kClear, 3)) << "and 64 wide";
        }
        EXPECT_TRUE(ExpectPixel(picture, 128, 71, kClear, 3)) << "it stays one row thin";
        EXPECT_TRUE(ExpectPixel(picture, 128, 73, kClear, 3));
        EXPECT_TRUE(ExpectRegionAverage(picture, 0, 0, kWidth, 70, kClear, 0.5));
        EXPECT_TRUE(ExpectRegionAverage(picture, 0, 74, kWidth, 70, kClear, 0.5));
    }
}
