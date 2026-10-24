// The synthetic scene harness (tests/support) checked against scenes whose picture is known
// before anything runs. Later tests build on the harness, so these pin what it promises:
// the picture it returns is the picture the scene draws, a run is repeatable, a property change
// shows on the next frame, and the pass counter and the named-target readback tell the truth.
//
// Every GPU image here is private to the process; no window or drawable is shown.

#include <gtest/gtest.h>

#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include "Scene/Scene.h"
#include "SpecTexs.hpp"
#include "Utils/Random.hpp"

#include <algorithm>
#include <cstdlib>

namespace
{
using namespace we_test;

constexpr uint32_t kWidth  = 256;
constexpr uint32_t kHeight = 144;

// Sets and clears an environment variable for the length of a scope.
class ScopedEnv {
public:
    ScopedEnv(const char* name, const char* value) : name_(name)
    {
        if (const char* held = std::getenv(name)) previous_ = held;
        had_ = std::getenv(name) != nullptr;
        ::setenv(name, value, 1);
    }
    ~ScopedEnv()
    {
        if (had_) {
            ::setenv(name_, previous_.c_str(), 1);
        } else {
            ::unsetenv(name_);
        }
    }

private:
    const char* name_;
    std::string previous_;
    bool        had_ { false };
};

// A scene with one picture layer: a 4x4 texture of four coloured quadrants.
void MakeQuadrantScene(ScenePackage& package, const std::vector<Json>& extra_effects = {})
{
    const std::string texture =
        package.AddTexture("quadrants", Image::Quadrants(4, 4, { 255, 0, 0, 255 }, { 0, 255, 0, 255 },
                                                         { 0, 0, 255, 255 }, { 255, 255, 0, 255 }));
    ImageLayer layer;
    layer.model   = package.AddImageModel("quadrants", texture);
    layer.effects = extra_effects;
    package.SetProject();
    package.SetScene(SceneJson({}, { ImageLayerJson(layer) }));
}

class SceneHarness : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }
};

} // namespace

// ---- pixel helpers (no device needed) ----------------------------------------------------

TEST(PixelHelpers, ComparisonsSeeTheDifferencesTheyAreAskedAbout)
{
    const Image base = Image::Solid(8, 4, { 10, 20, 30, 255 });
    Image       other = base;
    other.Set(5, 2, { 10, 20, 40, 255 });

    EXPECT_EQ(MaxChannelDifference(base, base), 0);
    EXPECT_EQ(MaxChannelDifference(base, other), 10);
    EXPECT_EQ(CountDifferingPixels(base, other, 0), 1u);
    EXPECT_EQ(CountDifferingPixels(base, other, 10), 0u) << "a difference equal to the tolerance passes";
    EXPECT_EQ(MaxChannelDifference(base, Image::Solid(4, 4, { 10, 20, 30, 255 })), 256)
        << "pictures of two sizes never match";

    EXPECT_TRUE(ExpectPixel(base, 3, 3, { 10, 20, 30, 255 }));
    EXPECT_FALSE(ExpectPixel(other, 5, 2, { 10, 20, 30, 255 }));
    EXPECT_TRUE(ExpectPixel(other, 5, 2, { 10, 20, 30, 255 }, 10));
    EXPECT_FALSE(ExpectPixel(base, 8, 0, { 0, 0, 0, 0 })) << "a pixel outside the picture fails, it does not read";

    const Image quadrants = Image::Quadrants(8, 4, { 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 },
                                             { 255, 255, 255, 255 });
    const auto  left = RegionAverage(quadrants, 0, 0, 4, 2);
    EXPECT_DOUBLE_EQ(left[0], 255.0);
    EXPECT_DOUBLE_EQ(left[1], 0.0);
    const auto mixed = RegionAverage(quadrants, 0, 0, 8, 2);
    EXPECT_DOUBLE_EQ(mixed[0], 127.5);
    EXPECT_DOUBLE_EQ(mixed[1], 127.5);
    EXPECT_TRUE(ExpectRegionAverage(quadrants, 0, 2, 4, 2, { 0, 0, 255, 255 }));
    EXPECT_FALSE(ExpectRegionAverage(quadrants, 0, 0, 8, 2, { 255, 0, 0, 255 }, 1.0));
}

TEST(PixelHelpers, AFailureIsDescribedByItsFirstDifferingPixelAndCounts)
{
    const Image base = Image::Solid(8, 4, { 10, 20, 30, 255 });
    Image       other = base;
    other.Set(5, 2, { 10, 20, 40, 255 });
    other.Set(6, 3, { 99, 20, 30, 255 });

    const std::string text = DescribeDifference(other, base);
    EXPECT_NE(text.find("2 of 32 pixels"), std::string::npos) << text;
    EXPECT_NE(text.find("first at (5,2)"), std::string::npos) << text;
    EXPECT_EQ(DescribeDifference(base, base), "identical");
    EXPECT_NE(DescribeDifference(base, Image::Solid(4, 4, { 0, 0, 0, 0 })).find("sizes differ"), std::string::npos);
    EXPECT_FALSE(ExpectSamePicture(other, base));
    EXPECT_TRUE(ExpectSamePicture(other, base, 255));
}

TEST(PixelHelpers, PicturesAreWrittenOnlyWhenAskedFor)
{
    const Image image = Image::Solid(2, 2, { 1, 2, 3, 255 });
    {
        ::unsetenv("WE_TEST_KEEP_PICTURES");
        EXPECT_FALSE(KeepPicture("harness_selftest_unwanted", image));
    }
    ScenePackage folder; // any scratch directory of the harness will do as the destination
    ScopedEnv    env("WE_TEST_KEEP_PICTURES", (folder.root() / "kept").c_str());
    EXPECT_TRUE(KeepPicture("harness_selftest_wanted", image));
    EXPECT_TRUE(folder.Contains("kept/harness_selftest_wanted.png"));
}

TEST(ScenePackageFixture, WritesALooseProjectAndRemovesItAfterwards)
{
    std::filesystem::path root;
    {
        ScenePackage package;
        root = package.root();
        package.MakeSolidScene({ 1, 2, 3, 255 });
        EXPECT_TRUE(package.Contains("project.json"));
        EXPECT_TRUE(package.Contains("scene.json"));
        EXPECT_TRUE(package.Contains("materials/util/white.tex"));
        EXPECT_TRUE(package.Contains("shaders/harness_image.frag"));
        EXPECT_TRUE(std::filesystem::exists(root));
    }
    EXPECT_FALSE(std::filesystem::exists(root));
}

TEST(ScenePackageFixture, TheTextureContainerHoldsTheLevelsItWasGiven)
{
    const Image base = Image::Solid(4, 4, { 9, 8, 7, 255 });
    const std::string one  = MakeTex(base);
    const std::string mips = MakeTex(base, { .mip_levels = 3 });
    // 4x4, 2x2 and 1x1 texels of four bytes each, plus a 20 byte description per level.
    EXPECT_EQ(mips.size() - one.size(), (2 * 2 * 4 + 20) + (1 * 1 * 4 + 20));
    EXPECT_EQ(one.rfind("TEXV0005", 0), 0u);
}

// ---- what a scene draws ------------------------------------------------------------------

TEST_F(SceneHarness, ASolidColourLayerFillsTheFrameWithThatColour)
{
    ScenePackage package;
    package.MakeSolidScene({ 200, 100, 50, 255 });
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    const Image picture = scene.Run(2);
    ASSERT_EQ(picture.width, kWidth);
    ASSERT_EQ(picture.height, kHeight);
    KeepPicture("solid", picture);
    EXPECT_TRUE(ExpectSamePicture(picture, Image::Solid(kWidth, kHeight, { 200, 100, 50, 255 })));
}

TEST_F(SceneHarness, ATexturedLayerShowsTheFourQuadrantsOfItsTexture)
{
    ScenePackage package;
    MakeQuadrantScene(package);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    const Image picture = scene.Run(2);
    ASSERT_EQ(picture.width, kWidth);
    KeepPicture("quadrants", picture);
    // The texture's first row is its top, and the layer shows it upright.
    EXPECT_TRUE(ExpectPixel(picture, 32, 18, { 255, 0, 0, 255 }));
    EXPECT_TRUE(ExpectPixel(picture, 224, 18, { 0, 255, 0, 255 }));
    EXPECT_TRUE(ExpectPixel(picture, 32, 126, { 0, 0, 255, 255 }));
    EXPECT_TRUE(ExpectPixel(picture, 224, 126, { 255, 255, 0, 255 }));
    EXPECT_TRUE(ExpectRegionAverage(picture, 8, 8, 100, 50, { 255, 0, 0, 255 }));
}

TEST_F(SceneHarness, ALooseImageFileLoadsLikeTheEquivalentContainer)
{
    const Image quadrants = Image::Quadrants(4, 4, { 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 },
                                             { 255, 255, 0, 255 });
    ScenePackage package;
    const std::string texture = package.AddPngTexture("loose", quadrants);
    ImageLayer        layer;
    layer.model = package.AddImageModel("loose", texture);
    package.SetProject();
    package.SetScene(SceneJson({}, { ImageLayerJson(layer) }));

    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(2);
    ASSERT_EQ(picture.width, kWidth);
    EXPECT_TRUE(ExpectPixel(picture, 32, 18, { 255, 0, 0, 255 }, 2));
    EXPECT_TRUE(ExpectPixel(picture, 224, 126, { 255, 255, 0, 255 }, 2));
}

TEST_F(SceneHarness, TheSurfaceSizeAndBackingScaleDecideThePictureSize)
{
    ScenePackage package;
    package.MakeSolidScene({ 10, 200, 30, 255 });
    GpuSceneOptions options;
    options.width         = 96;
    options.height        = 54;
    options.backing_scale = 2.0;
    GpuScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(1);
    EXPECT_EQ(picture.width, 192u);
    EXPECT_EQ(picture.height, 108u);
    EXPECT_TRUE(ExpectPixel(picture, 100, 50, { 10, 200, 30, 255 }));
}

TEST_F(SceneHarness, TwoRunsWithTheSameSeedGiveIdenticalBytes)
{
    const auto run = [] {
        ScenePackage package;
        MakeQuadrantScene(package, { EffectUse(package.AddTintEffect("warm"), { { "tint", "1 0.5 0.25" } }, 7) });
        GpuScene scene(package);
        EXPECT_TRUE(scene.ok()) << scene.error();
        return scene.Run(5);
    };
    const Image first  = run();
    const Image second = run();
    ASSERT_FALSE(first.empty());
    EXPECT_EQ(first.rgba, second.rgba);
}

TEST_F(SceneHarness, TheSeedRestartsTheEnginesRandomSourceAtTheSameSequence)
{
    ScenePackage package;
    package.MakeSolidScene({ 1, 2, 3, 255 });
    const auto draw = [] { return wallpaper::Random::get<uint32_t>(0, 1u << 30); };

    GpuSceneOptions options;
    options.seed = 77;
    GpuScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Reseed();
    const uint32_t first = draw();
    const uint32_t next  = draw();
    scene.Reseed();
    EXPECT_EQ(draw(), first);
    EXPECT_EQ(draw(), next);

    options.seed = 78;
    GpuScene other(package, options);
    ASSERT_TRUE(other.ok()) << other.error();
    other.Reseed();
    EXPECT_NE(draw(), first) << "another seed gives another sequence";
}

TEST_F(SceneHarness, ChangingAPropertyMidRunChangesABoundColourOnTheNextFrame)
{
    ScenePackage package;
    ImageLayer   layer;
    layer.model = package.AddImageModel("bound");
    layer.color = PropertyBinding("fill", "1 0 0");
    package.SetProject({ { "fill", ColorProperty("1 0 0") } });
    package.SetScene(SceneJson({}, { ImageLayerJson(layer) }));

    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(ExpectPixel(scene.Run(3), 100, 70, { 255, 0, 0, 255 }));

    ASSERT_TRUE(scene.SetProperty("fill", "0 0 1"));
    ASSERT_TRUE(scene.Step(1)) << scene.error();
    const Image after = scene.Picture();
    EXPECT_TRUE(ExpectPixel(after, 100, 70, { 0, 0, 255, 255 }));
    EXPECT_TRUE(ExpectPixel(after, 5, 5, { 0, 0, 255, 255 }));
}

TEST_F(SceneHarness, ASavedPropertyValueIsWhatTheSceneLoadsWith)
{
    ScenePackage package;
    ImageLayer   layer;
    layer.model = package.AddImageModel("bound");
    layer.color = PropertyBinding("fill", "1 0 0");
    package.SetProject({ { "fill", ColorProperty("1 0 0") } });
    package.SetScene(SceneJson({}, { ImageLayerJson(layer) }));

    GpuSceneOptions options;
    options.saved_properties = { { "fill", "0 1 0" } };
    GpuScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(ExpectPixel(scene.Run(2), 100, 70, { 0, 255, 0, 255 }));
}

// ---- looking inside ----------------------------------------------------------------------

TEST_F(SceneHarness, TheFirstFrameOpensAFewPassesForASimpleSceneAndMoreOnceAnEffectIsAdded)
{
    GpuSceneOptions options;
    options.scene_optimization = false;

    ScenePackage simple;
    MakeQuadrantScene(simple);
    GpuScene plain(simple, options);
    ASSERT_TRUE(plain.ok()) << plain.error();
    ASSERT_TRUE(plain.Step(3)) << plain.error();
    const PassCounts plain_counts = plain.FirstFramePasses();
    EXPECT_GE(plain_counts.total(), 1u);
    EXPECT_LE(plain_counts.total(), 4u);
    ASSERT_EQ(plain.FramePasses().size(), 3u);
    EXPECT_EQ(plain.LastFramePasses().total(), plain_counts.total())
        << "without static reuse every frame draws everything again";

    ScenePackage effected;
    MakeQuadrantScene(effected, { EffectUse(effected.AddTintEffect("warm"), { { "tint", "1 0.5 0.25" } }) });
    GpuScene with_effect(effected, options);
    ASSERT_TRUE(with_effect.ok()) << with_effect.error();
    ASSERT_TRUE(with_effect.Step(1)) << with_effect.error();
    EXPECT_GT(with_effect.FirstFramePasses().total(), plain_counts.total());
}

TEST_F(SceneHarness, AStaticSceneOpensNoPassOnceEveryPassIsReused)
{
    ScenePackage package;
    MakeQuadrantScene(package, { EffectUse(package.AddTintEffect("warm"), { { "tint", "1 0.5 0.25" } }) });
    GpuScene scene(package); // static reuse is on unless an option turns it off
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(scene.Step(6)) << scene.error();
    EXPECT_GT(scene.FirstFramePasses().total(), 0u);
    EXPECT_EQ(scene.LastFramePasses().total(), 0u);
}

TEST_F(SceneHarness, AnEffectChangesThePictureAndLeavesItsBufferToBeRead)
{
    ScenePackage package;
    MakeQuadrantScene(package, { EffectUse(package.AddTintEffect("warm"), { { "tint", "0.5 1 0.25" } }, 7) });
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image picture = scene.Run(2);
    KeepPicture("tinted", picture);
    // Red keeps half of its red; green keeps all of its green.
    EXPECT_TRUE(ExpectPixel(picture, 32, 18, { 128, 0, 0, 255 }, 2));
    EXPECT_TRUE(ExpectPixel(picture, 224, 18, { 0, 255, 0, 255 }, 2));
    EXPECT_TRUE(ExpectPixel(picture, 224, 126, { 128, 255, 0, 255 }, 2));

    const auto owned = scene.RenderTargetsOfLayer(1);
    EXPECT_FALSE(owned.empty()) << "the layer's effect buffers belong to its id";
}

TEST_F(SceneHarness, ANamedRenderTargetCanBeReadBackAtItsOwnSize)
{
    ScenePackage package;
    MakeQuadrantScene(package);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(scene.Step(2)) << scene.error();

    const std::string output = scene.scene().ResolveRenderTargetName(wallpaper::SpecTex_Default);
    const auto        names  = scene.RenderTargetNames();
    ASSERT_NE(std::find(names.begin(), names.end(), output), names.end()) << "the scene's output target is listed";

    const Image target = scene.RenderTarget(output);
    ASSERT_FALSE(target.empty());
    EXPECT_EQ(target.width, kWidth);
    EXPECT_EQ(target.height, kHeight);
    EXPECT_TRUE(ExpectPixel(target, 32, 18, { 255, 0, 0, 255 }));
    EXPECT_TRUE(ExpectPixel(target, 224, 126, { 255, 255, 0, 255 }));

    EXPECT_TRUE(scene.RenderTarget("no such target").empty());
    Image unused;
    EXPECT_FALSE(scene.ReadRenderTarget("no such target", &unused));
}

TEST_F(SceneHarness, RebuildingTheGraphKeepsThePictureAndRedrawsEveryPass)
{
    GpuSceneOptions options;
    options.scene_optimization = true;
    ScenePackage package;
    MakeQuadrantScene(package, { EffectUse(package.AddTintEffect("warm"), { { "tint", "1 0.5 0.25" } }) });
    GpuScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const Image before = scene.Run(4);
    EXPECT_EQ(scene.RebuildCount(), 0);

    ASSERT_TRUE(scene.Rebuild()) << scene.error();
    EXPECT_EQ(scene.RebuildCount(), 1);
    const Image after = scene.Run(1);
    EXPECT_TRUE(ExpectSamePicture(after, before));
    EXPECT_GT(scene.LastFramePasses().total(), 0u) << "the first frame of a new graph draws its passes";
}

TEST_F(SceneHarness, ReleasingTheRendererLeavesNothingToRunOn)
{
    ScenePackage package;
    package.MakeSolidScene({ 5, 6, 7, 255 });
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_FALSE(scene.Run(1).empty());
    scene.Release();
    EXPECT_TRUE(scene.released());
    EXPECT_FALSE(scene.ok());
    EXPECT_FALSE(scene.Step(1));
    EXPECT_TRUE(scene.Picture().empty());
}

// ---- skipping ----------------------------------------------------------------------------

TEST(SceneHarnessSkip, NoDeviceMeansNothingRunsAndNothingFails)
{
    ScenePackage package;
    package.MakeSolidScene({ 1, 1, 1, 255 });
    ScopedEnv simulate("WE_TEST_SIMULATE_NO_METAL", "1");
    EXPECT_FALSE(MetalAvailable());

    GpuScene scene(package);
    EXPECT_FALSE(scene.ok());
    EXPECT_NE(scene.error().find("no Metal device"), std::string::npos) << scene.error();
    EXPECT_FALSE(scene.Step(1));
    EXPECT_TRUE(scene.Picture().empty());
    EXPECT_TRUE(scene.RenderTargetNames().empty());
}
