// The scene's ambient and skylight colours and its height fog: read from an older package as from
// a newer one, and bound to user properties that are resolved when the scene loads. The shaders
// here print the scene's global lighting and fog values straight into the picture, so what the
// scene hands every material is what the pixels show. Pixel checks through the synthetic scene
// harness; every GPU image is private to the process.

#include <gtest/gtest.h>

#include "render_fixtures.hpp"
#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include "Runtime/SceneRuntimeContext.hpp"

#include <algorithm>
#include <string>

namespace
{
using namespace we_test;
using namespace we_test::fixtures;

// A gradient of squared density between the fog's two heights, over a grey ground.
const char* kFogGradient = R"(varying vec2 v_TexCoord;
uniform vec3 g_FogHeightColor;
uniform vec4 g_FogHeightParams;
void main() {
    float t = v_TexCoord.y;
    float height = g_FogHeightParams.x + g_FogHeightParams.y * t;
    float density = g_FogHeightParams.z + g_FogHeightParams.w * t * t;
    vec3 ground = vec3(0.3 + 0.005 * height, 0.2, 0.2);
    gl_FragColor = vec4(mix(ground, g_FogHeightColor, density), 1.0);
}
)";

// Ambient and skylight, each weighted differently so a pixel tells them apart.
const char* kLighting = R"(varying vec2 v_TexCoord;
uniform vec3 g_LightAmbientColor;
uniform vec3 g_LightSkylightColor;
void main() {
    gl_FragColor = vec4(g_LightAmbientColor * 0.5 + g_LightSkylightColor * 0.25, 1.0);
}
)";

const char* kDistanceFogColour = R"(varying vec2 v_TexCoord;
uniform vec3 g_FogDistanceColor;
void main() {
    gl_FragColor = vec4(g_FogDistanceColor, 1.0);
}
)";

struct Rendering {
    Image      picture;
    PassCounts first_frame;
    bool       ok { false };
    std::string error;
};

// One canvas-sized layer running `fragment`, in a scene whose `general` block carries `general`
// and whose project declares `properties`.
Rendering Draw(const char* fragment, const Json& general, const Json& properties = Json::object(),
               const Json& saved = Json::object(), uint16_t version = 0)
{
    ScenePackage package;
    ImageLayer   layer;
    layer.id    = 1;
    layer.model = AddShaderModel(package, "print", "print_globals", fragment, Json::array({ "util/white" }), "disabled");
    SceneGeneral scene_general;
    scene_general.extra = general;
    package.SetProject(properties);
    package.SetScene(SceneJson(scene_general, { ImageLayerJson(layer) }));

    GpuSceneOptions options;
    options.saved_properties  = saved.is_null() ? Json::object() : saved;
    options.package_version   = version;
    options.scene_optimization = false;
    GpuScene scene(package, options);
    Rendering out;
    out.ok    = scene.ok();
    out.error = scene.error();
    if (!out.ok) return out;
    out.picture     = scene.Run(3);
    out.first_frame = scene.FirstFramePasses();
    out.ok          = !out.picture.empty();
    out.error       = scene.error();
    KeepPicture("lighting_fog", out.picture);
    return out;
}

// The fog the literal scenes use, and the same fog with every setting taken from a property.
Json LiteralFog()
{
    return { { "fogheight", true },
             { "fogheightstart", 10.0 },
             { "fogheightend", -10.0 },
             { "fogheightstartdensity", 0.1 },
             { "fogheightenddensity", 0.9 },
             { "fogheightcolor", "0.9 0.3 0.1" } };
}

Json BoundFog()
{
    // The values saved in the scene file are stale on purpose: the properties decide.
    return { { "fogheight", true },
             { "fogheightstart", PropertyBinding("fog_start", 0.0) },
             { "fogheightend", PropertyBinding("fog_end", 0.0) },
             { "fogheightstartdensity", PropertyBinding("fog_density_near", 0.0) },
             { "fogheightenddensity", PropertyBinding("fog_density_far", 0.0) },
             { "fogheightcolor", PropertyBinding("fog_colour", "0 0 0") } };
}

Json FogProperties(double start = 10.0, double end = -10.0, double near_density = 0.1, double far_density = 0.9,
                   const std::string& colour = "0.9 0.3 0.1")
{
    return { { "fog_start", SliderProperty(start, -100.0, 100.0) },
             { "fog_end", SliderProperty(end, -100.0, 100.0) },
             { "fog_density_near", SliderProperty(near_density) },
             { "fog_density_far", SliderProperty(far_density) },
             { "fog_colour", ColorProperty(colour) } };
}

class LightingFog : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }
};

} // namespace

TEST_F(LightingFog, HeightFogReadsTheSameFromAnOlderPackageAsFromANewerOne)
{
    const auto newer   = Draw(kFogGradient, LiteralFog(), Json::object(), Json::object(), 23);
    const auto older   = Draw(kFogGradient, LiteralFog(), Json::object(), Json::object(), 22);
    const auto loose   = Draw(kFogGradient, LiteralFog());
    const auto no_fog  = Draw(kFogGradient, Json::object());
    ASSERT_TRUE(newer.ok && older.ok && loose.ok && no_fog.ok) << older.error << newer.error;
    EXPECT_GT(MaxChannelDifference(newer.picture, no_fog.picture), 40) << "the fog changes the picture at all";
    EXPECT_TRUE(ExpectSamePicture(older.picture, newer.picture)) << DescribeDifference(older.picture, newer.picture);
    EXPECT_TRUE(ExpectSamePicture(loose.picture, newer.picture));
}

TEST_F(LightingFog, DistanceFogOfAnOlderPackageStillFollowsItsOwnVersion)
{
    // Distance fog arrived with version 22: a package older than that does not carry it.
    const Json fog = { { "fogdistance", true }, { "fogdistancecolor", "0.2 0.6 0.4" } };
    const auto newer = Draw(kDistanceFogColour, fog, Json::object(), Json::object(), 22);
    const auto older = Draw(kDistanceFogColour, fog, Json::object(), Json::object(), 21);
    ASSERT_TRUE(newer.ok && older.ok);
    EXPECT_TRUE(ExpectPixel(newer.picture, 128, 72, { 51, 153, 102, 255 }, 2));
    EXPECT_TRUE(ExpectPixel(older.picture, 128, 72, { 0, 0, 0, 255 }, 2));
}

TEST_F(LightingFog, HeightFogBoundToPropertiesEqualsTheSameFogWrittenOut)
{
    const auto literal = Draw(kFogGradient, LiteralFog());
    const auto bound   = Draw(kFogGradient, BoundFog(), FogProperties());
    ASSERT_TRUE(literal.ok && bound.ok) << bound.error;
    EXPECT_TRUE(ExpectSamePicture(bound.picture, literal.picture)) << DescribeDifference(bound.picture, literal.picture);
    EXPECT_EQ(bound.first_frame.total(), literal.first_frame.total()) << "no pass is added";
}

TEST_F(LightingFog, ASavedPropertyValueIsWhatTheFogLoadsWith)
{
    const auto literal = Draw(kFogGradient, LiteralFog());
    const Json saved   = { { "fog_colour", "0.9 0.3 0.1" }, { "fog_density_far", 0.9 } };
    const auto bound =
        Draw(kFogGradient, BoundFog(), FogProperties(10.0, -10.0, 0.1, 0.2, "0 0 0"), saved);
    ASSERT_TRUE(literal.ok && bound.ok) << bound.error;
    EXPECT_TRUE(ExpectSamePicture(bound.picture, literal.picture)) << DescribeDifference(bound.picture, literal.picture);
}

TEST_F(LightingFog, AmbientAndSkylightAreEachBoundAndEachCounted)
{
    const Json properties = { { "ambient", ColorProperty("0.8 0.4 0.2") }, { "sky", ColorProperty("0.4 0.8 0.8") } };
    const Json bound      = { { "ambientcolor", PropertyBinding("ambient", "0 0 0") },
                              { "skylightcolor", PropertyBinding("sky", "0 0 0") } };
    const Json literal    = { { "ambientcolor", "0.8 0.4 0.2" }, { "skylightcolor", "0.4 0.8 0.8" } };
    const Json ambient_only = { { "ambientcolor", PropertyBinding("ambient", "0 0 0") }, { "skylightcolor", "0 0 0" } };
    const Json sky_only     = { { "ambientcolor", "0 0 0" }, { "skylightcolor", PropertyBinding("sky", "0 0 0") } };

    const auto both = Draw(kLighting, bound, properties);
    const auto same = Draw(kLighting, literal);
    const auto from_ambient = Draw(kLighting, ambient_only, properties);
    const auto from_sky     = Draw(kLighting, sky_only, properties);
    ASSERT_TRUE(both.ok && same.ok && from_ambient.ok && from_sky.ok);

    EXPECT_TRUE(ExpectSamePicture(both.picture, same.picture));
    // 0.8, 0.4, 0.2 at half; 0.4, 0.8, 0.8 at a quarter.
    EXPECT_TRUE(ExpectPixel(from_ambient.picture, 128, 72, { 102, 51, 26, 255 }, 2)) << "ambient alone";
    EXPECT_TRUE(ExpectPixel(from_sky.picture, 128, 72, { 26, 51, 51, 255 }, 2)) << "skylight alone";
    EXPECT_TRUE(ExpectPixel(both.picture, 128, 72, { 128, 102, 77, 255 }, 2)) << "the two together";
}

TEST_F(LightingFog, ChangingABoundPropertyIsAppliedByTheNextFrame)
{
    const Json properties = { { "ambient", ColorProperty("0.8 0.4 0.2") } };
    const Json bound      = { { "ambientcolor", PropertyBinding("ambient", "0 0 0") } };

    ScenePackage package;
    ImageLayer   layer;
    layer.id    = 1;
    layer.model = AddShaderModel(package, "print", "print_globals", kLighting, Json::array({ "util/white" }), "disabled");
    SceneGeneral general;
    general.extra = bound;
    package.SetProject(properties);
    package.SetScene(SceneJson(general, { ImageLayerJson(layer) }));

    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(ExpectPixel(scene.Run(3), 128, 72, { 102, 51, 26, 255 }, 2));

    // Wallpaper Engine evaluates the scene's ambient colour every frame: a live edit is drawn
    // without a load, and no load is asked for.
    const auto held = scene.runtime()->LoadOnlyProperties();
    EXPECT_EQ(std::find(held.begin(), held.end(), "ambient"), held.end());
    ASSERT_TRUE(scene.SetProperty("ambient", "0.2 0.2 0.2"));
    EXPECT_TRUE(ExpectPixel(scene.Run(2), 128, 72, { 26, 26, 26, 255 }, 2));
}

TEST_F(LightingFog, DistanceFogBoundToAPropertyFollowsIt)
{
    const Json properties = { { "distance_colour", ColorProperty("0.1 0.1 0.9") } };
    const Json fog        = { { "fogdistance", true }, { "fogdistancecolor", PropertyBinding("distance_colour", "0.2 0.6 0.4") } };
    const auto drawn = Draw(kDistanceFogColour, fog, properties, { { "distance_colour", "0.1 0.1 0.9" } });
    ASSERT_TRUE(drawn.ok) << drawn.error;
    EXPECT_TRUE(ExpectPixel(drawn.picture, 128, 72, { 26, 26, 230, 255 }, 2));
}
