// A material slot bound to the now-playing cover shows the texture its author put there until a
// cover is published: a colour picture, or another layer's composite (a default cover drawn by a
// hidden layer). Pixel checks through the synthetic scene harness; every GPU image is private to
// the process.

#include <gtest/gtest.h>

#include "render_fixtures.hpp"
#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include "Runtime/RuntimeImageSource.hpp"
#include "Scene/Scene.h"

#include <vector>

namespace
{
using namespace we_test;
using namespace we_test::fixtures;

// Shows the first texture, with the coordinates stretched to repeat it twice across the card.
const char* kTwice = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord * 2.0);
}
)";

const char* kShow = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
}
)";

constexpr const char* kComposite = "_rt_imageLayerComposite_1";

constexpr Rgba kRed { 255, 0, 0, 255 };
constexpr Rgba kGreen { 0, 255, 0, 255 };
constexpr Rgba kBlue { 0, 0, 255, 255 };
constexpr Rgba kYellow { 255, 255, 0, 255 };

// Where each viewer is looked at: the previous-cover viewer fills the left half of the canvas,
// the current-cover viewer the right half.
constexpr uint32_t kPreviousX = 64;
constexpr uint32_t kCurrentX  = 192;
constexpr uint32_t kY         = 72;

class CoverSlot : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }

    enum class Authored { Composite, Picture };

    // Layer 1 holds the authored art (hidden, read as a composite) and layers 2 and 3 show the
    // previous and the current cover slots, each over that art.
    void Build(Authored authored, const char* fragment = kShow, bool quadrant_art = false)
    {
        const Image art = quadrant_art ? Image::Quadrants(4, 4, kRed, kGreen, kBlue, kYellow)
                                       : Image::Solid(4, 4, authored == Authored::Picture ? kBlue : kRed);
        const std::string art_texture = package.AddTexture("art", art);

        ImageLayer source;
        source.id      = 1;
        source.name    = "default cover";
        source.model   = package.AddImageModel("default_cover", art_texture);
        source.visible = false;
        // The composite repeats when the layer says so; a cover never does.
        if (quadrant_art) source.extra = { { "clampuvs", false } };

        const std::string slot_texture = authored == Authored::Composite ? kComposite : art_texture;
        const Json        cover_slot   = Json::array({ { { "name", "$mediaThumbnail" }, { "type", "system" } } });
        const Json previous_slot = Json::array({ { { "name", "$mediaPreviousThumbnail" }, { "type", "system" } } });

        ImageLayer previous;
        previous.id     = 2;
        previous.name   = "previous";
        previous.origin = { 64.0f, 72.0f, 0.0f };
        previous.size   = { 128.0f, 144.0f };
        previous.model  = AddShaderModel(package, "previous_view", "cover_view", fragment, Json::array({ slot_texture }),
                                         "disabled", { { "usertextures", previous_slot } });

        ImageLayer current;
        current.id     = 3;
        current.name   = "current";
        current.origin = { 192.0f, 72.0f, 0.0f };
        current.size   = { 128.0f, 144.0f };
        current.model  = AddShaderModel(package, "current_view", "cover_view", fragment, Json::array({ slot_texture }),
                                        "disabled", { { "usertextures", cover_slot } });

        package.SetProject();
        package.SetScene(SceneJson({}, { ImageLayerJson(source), ImageLayerJson(previous), ImageLayerJson(current) }));
    }

    static bool Publish(GpuScene& scene, const Image& cover)
    {
        auto* source = dynamic_cast<wallpaper::RuntimeImageSource*>(scene.scene().imageParser.get());
        if (source == nullptr) return false;
        wallpaper::PublishSystemMediaArtwork(*source, cover.width, cover.height, cover.rgba.data(), cover.rgba.size());
        return true;
    }

    static bool Clear(GpuScene& scene)
    {
        auto* source = dynamic_cast<wallpaper::RuntimeImageSource*>(scene.scene().imageParser.get());
        if (source == nullptr) return false;
        wallpaper::PublishSystemMediaArtwork(*source, 0, 0, nullptr, 0);
        return true;
    }

    ScenePackage package;
};

} // namespace

TEST_F(CoverSlot, ASlotOverAnotherLayersCompositeShowsThatCompositeUntilACoverArrives)
{
    Build(Authored::Composite);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image idle = scene.Run(4);
    ASSERT_FALSE(idle.empty());
    KeepPicture("cover_composite_idle", idle);
    EXPECT_TRUE(ExpectPixel(idle, kCurrentX, kY, kRed, 2)) << "no cover yet: the composite";
    EXPECT_TRUE(ExpectPixel(idle, kPreviousX, kY, kRed, 2));
}

TEST_F(CoverSlot, ACoverReplacesTheCompositeAndTheClearBringsItBack)
{
    Build(Authored::Composite);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_FALSE(scene.Run(4).empty());

    ASSERT_TRUE(Publish(scene, Image::Solid(8, 8, kGreen)));
    ASSERT_TRUE(scene.Step(4)) << scene.error();
    const Image with_cover = scene.Picture();
    KeepPicture("cover_composite_cover", with_cover);
    EXPECT_TRUE(ExpectPixel(with_cover, kCurrentX, kY, kGreen, 2)) << "a cover exists: the slot shows it";
    EXPECT_TRUE(ExpectPixel(with_cover, kPreviousX, kY, kRed, 2))
        << "one track has no predecessor: the previous slot keeps the composite";

    ASSERT_TRUE(Clear(scene));
    ASSERT_TRUE(scene.Step(4)) << scene.error();
    const Image cleared = scene.Picture();
    EXPECT_TRUE(ExpectPixel(cleared, kCurrentX, kY, kRed, 2)) << "cleared: the composite again";
    EXPECT_TRUE(ExpectPixel(cleared, kPreviousX, kY, kRed, 2));
}

TEST_F(CoverSlot, ThePreviousSlotShowsTheFirstCoverOnceASecondTrackArrives)
{
    Build(Authored::Composite);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_FALSE(scene.Run(3).empty());

    ASSERT_TRUE(Publish(scene, Image::Solid(8, 8, kGreen)));
    ASSERT_TRUE(scene.Step(5)) << scene.error();
    ASSERT_TRUE(Publish(scene, Image::Solid(8, 8, kBlue)));
    ASSERT_TRUE(scene.Step(5)) << scene.error();
    const Image two_tracks = scene.Picture();
    KeepPicture("cover_composite_two_tracks", two_tracks);
    EXPECT_TRUE(ExpectPixel(two_tracks, kCurrentX, kY, kBlue, 2));
    EXPECT_TRUE(ExpectPixel(two_tracks, kPreviousX, kY, kGreen, 2));
}

TEST_F(CoverSlot, ACoverKeepsItsOwnClampedSamplerWhateverTheCompositeAsked)
{
    // The card repeats its texture twice. A composite is sampled as its layer asked (repeating);
    // a cover is always clamped, so the second repeat is its last row and column stretched.
    Build(Authored::Composite, kTwice, true);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image idle = scene.Run(4);
    ASSERT_FALSE(idle.empty());
    // x at five eighths of the card is 1.25 repeats: the first quadrant row again, left half.
    constexpr uint32_t kPast = kCurrentX + 16; // inside the current-cover viewer, uv.x = 0.625
    constexpr uint32_t kTop  = 18;             // uv.y = 0.125, so the sample is a quarter of the way down
    EXPECT_TRUE(ExpectPixel(idle, kPast, kTop, kRed, 2)) << "the composite repeats";

    ASSERT_TRUE(Publish(scene, Image::Quadrants(4, 4, kRed, kGreen, kBlue, kYellow)));
    ASSERT_TRUE(scene.Step(4)) << scene.error();
    const Image with_cover = scene.Picture();
    KeepPicture("cover_composite_clamped", with_cover);
    EXPECT_TRUE(ExpectPixel(with_cover, kPast, kTop, kGreen, 2))
        << "the cover is clamped: past its right edge the last column continues";
}

TEST_F(CoverSlot, APictureAuthoredSlotStillShowsItsPictureUntilACoverArrives)
{
    Build(Authored::Picture);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image idle = scene.Run(4);
    ASSERT_FALSE(idle.empty());
    EXPECT_TRUE(ExpectPixel(idle, kCurrentX, kY, kBlue, 2));
    EXPECT_TRUE(ExpectPixel(idle, kPreviousX, kY, kBlue, 2));

    ASSERT_TRUE(Publish(scene, Image::Solid(8, 8, kGreen)));
    ASSERT_TRUE(scene.Step(4)) << scene.error();
    const Image with_cover = scene.Picture();
    EXPECT_TRUE(ExpectPixel(with_cover, kCurrentX, kY, kGreen, 2));
    EXPECT_TRUE(ExpectPixel(with_cover, kPreviousX, kY, kBlue, 2));

    ASSERT_TRUE(Clear(scene));
    ASSERT_TRUE(scene.Step(4)) << scene.error();
    EXPECT_TRUE(ExpectPixel(scene.Picture(), kCurrentX, kY, kBlue, 2));
}
