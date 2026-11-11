// An image layer with the `perspective` flag in a 2D scene is seen through the scene's perspective
// camera, seated as a particle system or a model with the flag is: the distance from the canvas
// plane is (canvas height / 2) / tan(fov / 2). The width of a card in pixels tells which view
// drew it. Pixel checks through the synthetic scene harness.

#include <gtest/gtest.h>

#include "render_fixtures.hpp"
#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include <cmath>
#include <numbers>

namespace
{
using namespace we_test;
using namespace we_test::fixtures;

constexpr uint32_t kWidth  = 256;
constexpr uint32_t kHeight = 144;
constexpr Rgba     kClear { 0, 0, 0, 255 };

// The scene's field of view when the file does not say: the lens of its perspective layers.
constexpr double kDefaultFov = 95.0;

double CameraDistance(double canvas_height, double fov_degrees)
{
    return (canvas_height / 2.0) / std::tan(fov_degrees * std::numbers::pi / 360.0);
}

// How many pixels of one row are lit: the width the card is drawn at.
double LitWidth(const Image& picture, uint32_t row)
{
    double lit = 0.0;
    for (uint32_t x = 0; x < picture.width; ++x) lit += picture.At(x, row)[0] / 255.0;
    return lit;
}

class PerspectiveImage : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }

    // A red card 30 units wide, `lift` units in front of the canvas plane.
    static Image Draw(bool flag, bool through_effect, double lift, const Json& general_extra = Json::object(),
                      bool fullscreen = false)
    {
        ScenePackage package;
        ImageLayer   card;
        card.id     = 1;
        card.origin = { 128.0f, 72.0f, static_cast<float>(lift) };
        card.size   = { 30.0f, 30.0f };
        card.color  = "1 0 0";
        if (fullscreen) {
            card.model = package.AddImageModel("fullscreen", "util/white");
            Json model = Json::parse(std::string("{\"material\":\"materials/fullscreen.json\",\"fullscreen\":true}"));
            package.PutJson("models/fullscreen.json", model);
        } else {
            card.model = package.AddImageModel("card", "util/white");
        }
        if (flag) card.extra = { { "perspective", true } };
        if (through_effect) card.effects = { EffectUse(package.AddTintEffect("warm"), { { "tint", "1 1 1" } }, 7) };
        SceneGeneral general;
        general.extra = general_extra;
        package.SetProject();
        package.SetScene(SceneJson(general, { ImageLayerJson(card) }));

        GpuScene scene(package);
        EXPECT_TRUE(scene.ok()) << scene.error();
        Image picture = scene.Run(3);
        EXPECT_FALSE(picture.empty());
        KeepPicture(std::string("perspective_") + (flag ? "flag" : "flat") + (through_effect ? "_effect" : "") +
                        (fullscreen ? "_fullscreen" : ""),
                    picture);
        return picture;
    }
};

} // namespace

TEST_F(PerspectiveImage, ACardWithTheFlagIsEnlargedByItsDistanceFromTheCameraPlane)
{
    constexpr double lift     = 20.0;
    const double     distance = CameraDistance(kHeight, kDefaultFov);
    const double     expected = 30.0 * distance / (distance - lift);

    const Image flat = Draw(false, false, lift);
    EXPECT_NEAR(LitWidth(flat, 72), 30.0, 1.0) << "without the flag the depth changes nothing";

    const Image seen = Draw(true, false, lift);
    EXPECT_NEAR(LitWidth(seen, 72), expected, 1.5);
}

TEST_F(PerspectiveImage, ACardWithEffectsIsSeenThroughTheCameraByThePassThatPutsItOnTheScene)
{
    constexpr double lift     = 20.0;
    const double     distance = CameraDistance(kHeight, kDefaultFov);
    const double     expected = 30.0 * distance / (distance - lift);

    const Image flat = Draw(false, true, lift);
    EXPECT_NEAR(LitWidth(flat, 72), 30.0, 1.0);

    const Image seen = Draw(true, true, lift);
    EXPECT_NEAR(LitWidth(seen, 72), expected, 1.5);
}

TEST_F(PerspectiveImage, TheSceneFieldOfViewDecidesTheLens)
{
    constexpr double lift = 20.0;
    for (const double fov : { 60.0, 120.0 }) {
        SCOPED_TRACE(fov);
        const double distance = CameraDistance(kHeight, fov);
        const double expected = 30.0 * distance / (distance - lift);
        const Image  seen     = Draw(true, false, lift, { { "perspectiveoverridefov", fov } });
        EXPECT_NEAR(LitWidth(seen, 72), expected, 1.5);
    }
}

TEST_F(PerspectiveImage, ACardAtTheCanvasPlaneKeepsItsSizeWhateverTheFlag)
{
    const Image seen = Draw(true, false, 0.0);
    EXPECT_NEAR(LitWidth(seen, 72), 30.0, 1.0);
    const Image seen_through_effect = Draw(true, true, 0.0);
    EXPECT_NEAR(LitWidth(seen_through_effect, 72), 30.0, 1.0);
}

// In a 3D scene WE draws a card with the flag through the scene camera's orientation, pulled
// back to 2000 units in front of the look-at point and zoomed by 2000 (probes pcam-a..f,
// matrices read back from WE 2.8.0.42). A card at the look-at point keeps its framing; a
// card off the camera axis lands about 2000 / (2000 - depth) as far out as an orthographic
// view would put it, so the flag in 3D reads as a near-orthographic view at the scene's scale.
TEST_F(PerspectiveImage, InA3DSceneTheFlagLooksFromTwoThousandUnitsAtTheSceneCameraZoom)
{
    const auto draw = [](bool flag, float x) {
        ScenePackage package;
        ImageLayer   card;
        card.id     = 1;
        card.origin = { x, 0.0f, 0.0f };
        card.size   = { 10.0f, 10.0f };
        card.color  = "1 0 0";
        card.model  = package.AddImageModel("card", "util/white");
        card.extra  = { { "scale", "0.1 0.1 0.1" } };
        if (flag) card.extra["perspective"] = true;
        SceneGeneral general;
        general.extra = { { "orthogonalprojection", nullptr }, { "fov", 50 }, { "nearz", 0.1 }, { "farz", 1000 } };
        package.SetProject();
        Json scene = SceneJson(general, { ImageLayerJson(card) });
        scene["camera"] = { { "eye", "0 0 10" }, { "center", "0 0 0" }, { "up", "0 1 0" } };
        package.SetScene(scene);
        GpuScene gpu(package);
        EXPECT_TRUE(gpu.ok()) << gpu.error();
        return gpu.Run(3);
    };
    const auto centre_x = [](const Image& picture) {
        double sum = 0.0, weight = 0.0;
        for (uint32_t x = 0; x < picture.width; ++x) {
            const double w = picture.At(x, kHeight / 2)[0] / 255.0;
            sum += w * x;
            weight += w;
        }
        return weight > 0.0 ? sum / weight : -1.0;
    };
    // WE's matrix (probe pcam-a, read back from WE 2.8.0.42 and matched by this port in x, y
    // and w): the far view puts a point x units across the look-at plane at 2000 cot(fov/2)
    // x / (aspect x 2000.4) in clip space, where the scene camera, 10 units away, puts it at
    // cot(fov/2) x / (aspect x 10.0): the card is 2000 / 2000.4 x 10 / 1 = ~10 times wider.
    const Image flat = draw(false, 0.0f), seen = draw(true, 0.0f);
    ASSERT_FALSE(flat.empty());
    ASSERT_FALSE(seen.empty());
    // Both edges are clipped to whole pixels, so the plain card's 2-3 px decide the ratio's spread.
    const double ratio = LitWidth(seen, kHeight / 2) / LitWidth(flat, kHeight / 2);
    EXPECT_GT(ratio, 8.0);
    EXPECT_LT(ratio, 12.0);
    EXPECT_NEAR(centre_x(seen), kWidth / 2.0, 1.0);
    // 0.2 units off axis: 0.2 x 2000 cot(25 deg) / (16/9 x 2000.4) of the half width.
    const double cot   = 1.0 / std::tan(25.0 * std::numbers::pi / 180.0);
    const double shift = 0.2 * 2000.0 * cot / ((double(kWidth) / kHeight) * 2000.0) * (kWidth / 2.0);
    const Image off = draw(true, 0.2f);
    EXPECT_NEAR(centre_x(off) - kWidth / 2.0, shift, 1.5);
}

TEST_F(PerspectiveImage, AFullscreenLayerIgnoresTheFlag)
{
    const Image flat = Draw(false, false, 20.0, Json::object(), true);
    const Image seen = Draw(true, false, 20.0, Json::object(), true);
    ASSERT_FALSE(flat.empty());
    EXPECT_TRUE(ExpectSamePicture(seen, flat));
    EXPECT_TRUE(ExpectPixel(seen, 3, 3, { 255, 0, 0, 255 }, 1)) << "it still fills the canvas";
    EXPECT_TRUE(ExpectPixel(seen, kWidth - 4, kHeight - 4, { 255, 0, 0, 255 }, 1));
}
