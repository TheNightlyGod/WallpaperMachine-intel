// A picture chosen through a `scenetexture` property fills a solid-colour placeholder layer and
// is drawn as it is: the colour the placeholder was made with (often a scheme colour bound to
// another property) does not tint it, now or when that colour changes later. With no picture,
// or one that cannot be opened, the placeholder keeps its colour and keeps following it.
//
// Every GPU image is private to the process; no window or drawable is shown.

#include <gtest/gtest.h>

#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

namespace
{
using namespace we_test;

constexpr uint32_t kWidth  = 256;
constexpr uint32_t kHeight = 144;

const Rgba kDark { 26, 26, 26, 255 };

// A picture with four distinct, opaque quadrants, the size of the canvas.
Image ChosenPicture()
{
    return Image::Quadrants(kWidth, kHeight, { 200, 40, 40, 255 }, { 40, 200, 40, 255 }, { 40, 40, 200, 255 },
                            { 220, 200, 60, 255 });
}

// A placeholder layer: a plain white card whose colour follows the "scheme" property, and whose
// first texture slot is delegated to the "background" scenetexture property.
class PlaceholderScene {
public:
    explicit PlaceholderScene(const std::string& preset_value = "")
    {
        const std::string model = package.AddImageModel("placeholder");
        ImageLayer        layer;
        layer.model   = model;
        layer.color   = PropertyBinding("scheme", "0.1 0.1 0.1");
        layer.extra   = { { "instance", { { "usertextures", Json::array({ "background" }) } } } };
        package.SetProject({ { "scheme", ColorProperty("0.1 0.1 0.1") },
                             { "background",
                               { { "type", "scenetexture" }, { "text", "picture" }, { "value", preset_value } } } });
        package.SetScene(SceneJson({}, { ImageLayerJson(layer) }));
    }

    // Writes the user's picture as a loose file the way a user pick is stored (an absolute path).
    std::string PutUserPicture(const std::string& file_name, const Image& image)
    {
        package.Put("user/" + file_name, MakePng(image));
        return (package.root() / "user" / file_name).string();
    }

    ScenePackage package;
};

GpuSceneOptions Choosing(const std::string& path)
{
    GpuSceneOptions options;
    options.saved_properties = { { "background", path } };
    return options;
}

class PlaceholderPicture : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }
};

} // namespace

TEST_F(PlaceholderPicture, AChosenPictureIsDrawnAsItIsOverADarkSchemeColour)
{
    PlaceholderScene scene_files;
    const Image      picture = ChosenPicture();
    GpuScene         scene(scene_files.package, Choosing(scene_files.PutUserPicture("pick.png", picture)));
    ASSERT_TRUE(scene.ok()) << scene.error();

    const Image frame = scene.Run(3);
    KeepPicture("placeholder_chosen", frame);
    EXPECT_TRUE(ExpectSamePicture(frame, picture, 2));
}

TEST_F(PlaceholderPicture, ChangingTheSchemeColourWhileRunningLeavesTheChosenPictureAlone)
{
    PlaceholderScene scene_files;
    const Image      picture = ChosenPicture();
    GpuScene         scene(scene_files.package, Choosing(scene_files.PutUserPicture("pick.png", picture)));
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(ExpectSamePicture(scene.Run(2), picture, 2));

    for (const char* colour : { "0 0 0", "1 1 1", "1 0 0" }) {
        ASSERT_TRUE(scene.SetProperty("scheme", colour));
        EXPECT_TRUE(ExpectSamePicture(scene.Run(2), picture, 2)) << "scheme colour " << colour;
    }
}

TEST_F(PlaceholderPicture, AnUnsetPictureLeavesThePlaceholderItsColourAndKeepsItFollowingTheProperty)
{
    PlaceholderScene scene_files;
    GpuScene         scene(scene_files.package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    EXPECT_TRUE(ExpectSamePicture(scene.Run(2), Image::Solid(kWidth, kHeight, kDark), 2));
    ASSERT_TRUE(scene.SetProperty("scheme", "1 0 0"));
    EXPECT_TRUE(ExpectSamePicture(scene.Run(2), Image::Solid(kWidth, kHeight, { 255, 0, 0, 255 }), 2));
}

TEST_F(PlaceholderPicture, APictureThatCannotBeOpenedLeavesThePlaceholderItsColour)
{
    PlaceholderScene scene_files;
    const std::string missing = (scene_files.package.root() / "user" / "gone.png").string();
    ASSERT_FALSE(scene_files.package.Contains("user/gone.png"));
    GpuScene scene(scene_files.package, Choosing(missing));
    ASSERT_TRUE(scene.ok()) << scene.error();

    EXPECT_TRUE(ExpectSamePicture(scene.Run(2), Image::Solid(kWidth, kHeight, kDark), 2));
    ASSERT_TRUE(scene.SetProperty("scheme", "0 0 1"));
    EXPECT_TRUE(ExpectSamePicture(scene.Run(2), Image::Solid(kWidth, kHeight, { 0, 0, 255, 255 }), 2));
}

TEST_F(PlaceholderPicture, ThePicturesAPresetShipsCountLikeTheOnesTheUserChooses)
{
    // The property's own value names a texture inside the project.
    PlaceholderScene scene_files("preset/photo");
    const Image      picture = ChosenPicture();
    scene_files.package.AddTexture("preset/photo", picture);
    GpuScene scene(scene_files.package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    EXPECT_TRUE(ExpectSamePicture(scene.Run(3), picture, 2));
    ASSERT_TRUE(scene.SetProperty("scheme", "0 0 0"));
    EXPECT_TRUE(ExpectSamePicture(scene.Run(2), picture, 2));
}

TEST_F(PlaceholderPicture, ALayerWithItsOwnPictureIsStillTintedByItsColour)
{
    ScenePackage package;
    const Image  picture = ChosenPicture();
    ImageLayer   layer;
    layer.model = package.AddImageModel("tinted", package.AddTexture("tinted", picture));
    layer.color = "0.5 0.5 0.5";
    package.SetProject();
    package.SetScene(SceneJson({}, { ImageLayerJson(layer) }));
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    const Image frame = scene.Run(2);
    EXPECT_TRUE(ExpectPixel(frame, 32, 18, { 100, 20, 20, 255 }, 2));
    EXPECT_TRUE(ExpectPixel(frame, 224, 126, { 110, 100, 30, 255 }, 2));
}
