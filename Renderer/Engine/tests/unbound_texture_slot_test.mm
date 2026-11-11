// A texture slot an active shader samples and nobody bound reads zero in all four channels, as a
// null resource does in Direct3D. Pixel checks through the synthetic scene harness; every GPU
// image is private to the process.

#include <gtest/gtest.h>

#include <optional>

#include "render_fixtures.hpp"
#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

namespace
{
using namespace we_test;
using namespace we_test::fixtures;

constexpr Rgba kClear { 26, 51, 77, 255 };

// Adds a quarter to what the second texture holds.
const char* kQuarterPlusSecond = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture1;
void main() {
    gl_FragColor = texSample2D(g_Texture1, v_TexCoord) + vec4(0.25, 0.25, 0.25, 0.25);
}
)";

// Blue while nothing is bound to the second texture, red once something is; the texture is
// read on both paths, so the slot is active either way.
const char* kPresenceSwitch = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture1; // {"material":"mask","label":"mask","combo":"MASK"}
void main() {
    vec4 sampled = texSample2D(g_Texture1, v_TexCoord);
#if MASK == 1
    gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0) + sampled * 0.0;
#else
    gl_FragColor = vec4(0.0, 0.0, 1.0, 1.0) + sampled * 0.0;
#endif
}
)";

// The second texture is white unless the material says otherwise.
const char* kDefaultedSecond = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture1; // {"material":"second","default":"util/white"}
void main() {
    gl_FragColor = texSample2D(g_Texture1, v_TexCoord) * 0.5;
}
)";

class UnboundSlot : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }

    // A 64 by 64 white card through one effect running `fragment` with the given texture list;
    // the card replaces what is behind it, so the picture at its centre is the pass's output.
    static std::optional<Image> Draw(const char* fragment, const Json& textures, const Json& extra_files = Json::object())
    {
        last_error.clear();
        ScenePackage package;
        for (const auto& [path, bytes] : extra_files.items()) package.Put(path, bytes.get<std::string>());
        const std::string effect = AddFragmentEffect(package, "probe", fragment, textures);
        ImageLayer        card;
        card.id      = 1;
        card.size    = { 64.0f, 64.0f };
        card.model   = package.AddImageModel("card", "util/white", { .blending = "disabled" });
        card.effects = { EffectUse(effect, Json::object(), 7) };
        SceneGeneral general;
        general.clear_color = { 0.1f, 0.2f, 0.3f };
        package.SetProject();
        package.SetScene(SceneJson(general, { ImageLayerJson(card) }));

        GpuScene scene(package);
        if (!scene.ok()) {
            last_error = scene.error();
            return std::nullopt;
        }
        Image picture = scene.Run(3);
        if (picture.empty()) {
            last_error = scene.error();
            return std::nullopt;
        }
        KeepPicture("unbound_slot", picture);
        return picture;
    }

    static inline std::string last_error;
};

} // namespace

TEST_F(UnboundSlot, ATextureTheMaterialDoesNotListReadsZero)
{
    const auto picture = Draw(kQuarterPlusSecond, Json::array({ nullptr }));
    ASSERT_TRUE(picture.has_value()) << last_error;
    EXPECT_TRUE(ExpectPixel(*picture, 128, 72, { 64, 64, 64, 255 }, 2)) << "zero plus a quarter, not a dropped pass";
    EXPECT_TRUE(ExpectPixel(*picture, 10, 10, kClear, 2));
}

TEST_F(UnboundSlot, AnExplicitNullEntryReadsZeroToo)
{
    const auto picture = Draw(kQuarterPlusSecond, Json::array({ nullptr, nullptr }));
    ASSERT_TRUE(picture.has_value()) << last_error;
    EXPECT_TRUE(ExpectPixel(*picture, 128, 72, { 64, 64, 64, 255 }, 2));
}

TEST_F(UnboundSlot, AnAuthoredTextureAlwaysWins)
{
    const auto   grey = MakeTex(Image::Solid(2, 2, { 128, 128, 128, 255 }));
    const auto   picture = Draw(kQuarterPlusSecond, Json::array({ nullptr, "grey" }), { { "materials/grey.tex", grey } });
    ASSERT_TRUE(picture.has_value()) << last_error;
    EXPECT_TRUE(ExpectPixel(*picture, 128, 72, { 192, 192, 192, 255 }, 3)) << "128/255 + 0.25";
}

TEST_F(UnboundSlot, ADefaultTheShaderNamesFillsTheSlotBeforeAnythingIsZero)
{
    const auto picture = Draw(kDefaultedSecond, Json::array({ nullptr }));
    ASSERT_TRUE(picture.has_value()) << last_error;
    EXPECT_TRUE(ExpectPixel(*picture, 128, 72, { 128, 128, 128, 255 }, 3))
        << "a white default times a half";
}

TEST_F(UnboundSlot, ASwitchDrivenByWhetherATextureIsBoundIsNotFlippedByTheZeroBinding)
{
    const auto unbound = Draw(kPresenceSwitch, Json::array({ nullptr }));
    ASSERT_TRUE(unbound.has_value()) << last_error;
    EXPECT_TRUE(ExpectPixel(*unbound, 128, 72, { 0, 0, 255, 255 }, 2)) << "nothing bound: the switch stays off";

    const auto bound = Draw(kPresenceSwitch, Json::array({ nullptr, "grey" }),
                            { { "materials/grey.tex", MakeTex(Image::Solid(2, 2, { 128, 128, 128, 255 })) } });
    ASSERT_TRUE(bound.has_value()) << last_error;
    EXPECT_TRUE(ExpectPixel(*bound, 128, 72, { 255, 0, 0, 255 }, 2)) << "a texture bound: the switch turns on";
}

TEST_F(UnboundSlot, ATextureNamedByAPathThatDoesNotExistIsNotANullBinding)
{
    // A named missing asset keeps its own failure: the render graph is refused and the error
    // names the asset, so the scene is not drawn as if the slot read zero and an unrelated
    // failure (a shader that does not compile, a harness error) does not pass for this one.
    const auto picture = Draw(kQuarterPlusSecond, Json::array({ nullptr, "no/such/texture" }));
    EXPECT_FALSE(picture.has_value()) << "the missing asset must not read as zero";
    EXPECT_NE(last_error.find("no/such/texture"), std::string::npos)
        << "the failure must name the missing texture, got: " << last_error;
}

TEST_F(UnboundSlot, AReferenceToALayerThatDoesNotResolveIsNotANullBindingEither)
{
    // The scene still draws, but the effect that samples the missing layer produces nothing:
    // its step is skipped, so the frame is the unwritten transparent black, neither the picture
    // a zero read would make nor the clear colour.
    const auto picture = Draw(kQuarterPlusSecond, Json::array({ nullptr, "_rt_imageLayerComposite_99" }));
    ASSERT_TRUE(picture.has_value()) << "the draw must succeed: " << last_error;
    EXPECT_FALSE(ExpectPixel(*picture, 128, 72, { 64, 64, 64, 255 }, 2))
        << "a layer that is not there must not read as zero";
    EXPECT_TRUE(ExpectPixel(*picture, 128, 72, { 0, 0, 0, 0 }, 0)) << "the sampling step is skipped";
}

// Wallpaper Engine describes a slot with no texture as two texels square: g_Texture<N>Resolution
// (2, 2, 2, 2) and g_Texture<N>Texel (0.5, 0.5, 2, 2) (`sub_1400D8300` cases 0x3E-0x51), whatever
// stands in for the texture here.
TEST_F(UnboundSlot, ASlotNobodyBoundDescribesItselfAsTwoTexelsSquare)
{
    const char* fragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture1;
uniform vec4 g_Texture1Resolution;
uniform vec4 g_Texture1Texel;
void main() {
    gl_FragColor = vec4(g_Texture1Resolution.x / 8.0, g_Texture1Texel.x, g_Texture1Texel.z / 8.0, 1.0)
                 + texSample2D(g_Texture1, v_TexCoord) * 0.0;
}
)";
    const auto picture = Draw(fragment, Json::array({ nullptr }));
    ASSERT_TRUE(picture.has_value()) << last_error;
    EXPECT_TRUE(ExpectPixel(*picture, 128, 72, { 64, 128, 64, 255 }, 2)) << "2/8, 1/2, 2/8";
}
