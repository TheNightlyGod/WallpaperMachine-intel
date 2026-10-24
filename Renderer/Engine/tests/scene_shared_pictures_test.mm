// One wallpaper on several displays: every display parses the scene's pictures itself, but a
// picture another display of the same GPU already holds is not uploaded again. The displays bind
// one texture, which lives while any of them shows it, and which a display gets only when its
// own parsed bytes equal the bytes already uploaded.
//
// Each display here is a `GpuScene`: a renderer on a detached layer, with private textures.
#include "support/gpu_scene.hpp"

#include "MetalRender/MetalRender.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using namespace we_test;
using wallpaper::metal::MetalRender;

namespace
{

// A picture whose every pixel differs from its neighbours, in four flat-ish quadrants so a
// drawn frame can be checked by eye: the quadrant colour is in the high bits, the position in
// the low ones.
Image Pattern(uint32_t width, uint32_t height, uint8_t salt)
{
    Image image = Image::Quadrants(width, height, { 200, 20, 20, 255 }, { 20, 200, 20, 255 },
                                   { 20, 20, 200, 255 }, { 200, 200, 20, 255 });
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            Rgba pixel = image.At(x, y);
            pixel[0]   = static_cast<uint8_t>(pixel[0] + ((x + salt) & 7));
            pixel[1]   = static_cast<uint8_t>(pixel[1] + ((y + salt) & 7));
            pixel[2]   = static_cast<uint8_t>(pixel[2] + ((x ^ y) & 7));
            image.Set(x, y, pixel);
        }
    }
    return image;
}

// One layer filling the canvas with texture `name`, point sampled.
void MakePictureScene(ScenePackage& package, const std::string& name, const Image& picture, int mip_levels = 1)
{
    TexOptions options;
    options.mip_levels = mip_levels;
    const std::string texture = package.AddTexture(name, picture, options);
    ImageLayer        layer;
    layer.model = package.AddImageModel(name, texture);
    package.SetProject();
    package.SetScene(SceneJson({}, { ImageLayerJson(layer) }));
}

const void* HandleOf(GpuScene& scene, const std::string& key, std::size_t slot = 0)
{
    return scene.renderer().ImportedImageForTests(key, slot);
}

// Starts two displays on one package at the same moment.
void LoadTogether(const ScenePackage& package, std::unique_ptr<GpuScene>& first,
                  std::unique_ptr<GpuScene>& second, GpuSceneOptions first_options = {},
                  GpuSceneOptions second_options = {})
{
    std::thread one([&] { first = std::make_unique<GpuScene>(package, first_options); });
    std::thread two([&] { second = std::make_unique<GpuScene>(package, second_options); });
    one.join();
    two.join();
}

class SharedPictures : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }
};

constexpr uint64_t RgbaBytes(uint64_t width, uint64_t height) { return width * height * 4; }

} // namespace

TEST_F(SharedPictures, TwoDisplaysLoadingTogetherBindOneTextureAndUploadItOnce)
{
    ScenePackage package;
    MakePictureScene(package, "shared_pic", Pattern(64, 64, 0));
    const uint64_t bytes_before   = MetalRender::SharedImageBytesForTests();
    const uint64_t uploads_before = MetalRender::ImageUploadsForTests();

    std::unique_ptr<GpuScene> first, second;
    LoadTogether(package, first, second);
    ASSERT_TRUE(first->ok()) << first->error();
    ASSERT_TRUE(second->ok()) << second->error();

    ASSERT_NE(HandleOf(*first, "shared_pic"), nullptr);
    EXPECT_EQ(HandleOf(*first, "shared_pic"), HandleOf(*second, "shared_pic")) << "one texture between the displays";
    EXPECT_EQ(MetalRender::SharedImageBytesForTests() - bytes_before, RgbaBytes(64, 64))
        << "the cache holds one display's bytes for both";
    EXPECT_EQ(MetalRender::ImageUploadsForTests() - uploads_before, 1u) << "the second display uploaded nothing";

    const Image a = first->Run(2);
    const Image b = second->Run(2);
    EXPECT_TRUE(ExpectSamePicture(a, b)) << "both draw the same picture";
    EXPECT_TRUE(ExpectRegionAverage(a, 8, 8, 100, 50, { 200, 20, 20, 255 }, 8.0)) << "and it is the picture";
}

TEST_F(SharedPictures, TheTextureLivesWhileEitherDisplayShowsItAndIsGoneWhenBothUnloaded)
{
    ScenePackage package;
    MakePictureScene(package, "lifetime_pic", Pattern(64, 64, 1));
    const uint64_t bytes_before = MetalRender::SharedImageBytesForTests();

    auto first  = std::make_unique<GpuScene>(package);
    auto second = std::make_unique<GpuScene>(package);
    ASSERT_TRUE(first->ok() && second->ok());
    const void* handle = HandleOf(*first, "lifetime_pic");
    ASSERT_NE(handle, nullptr);
    ASSERT_EQ(handle, HandleOf(*second, "lifetime_pic"));

    first->Release();
    EXPECT_EQ(HandleOf(*second, "lifetime_pic"), handle);
    EXPECT_EQ(MetalRender::SharedImageBytesForTests() - bytes_before, RgbaBytes(64, 64))
        << "the picture is alive while the second display shows it";
    EXPECT_TRUE(ExpectRegionAverage(second->Run(2), 8, 8, 100, 50, { 200, 20, 20, 255 }, 8.0));

    second->Release();
    EXPECT_EQ(MetalRender::SharedImageBytesForTests(), bytes_before) << "freed with the last display that held it";

    // A dead key is dropped by the next import, not kept for ever.
    ScenePackage other;
    MakePictureScene(other, "lifetime_other", Pattern(32, 32, 2));
    const std::size_t entries_with_dead_key = MetalRender::SharedImageEntriesForTests();
    GpuScene          third(other);
    ASSERT_TRUE(third.ok()) << third.error();
    EXPECT_LE(MetalRender::SharedImageEntriesForTests(), entries_with_dead_key)
        << "the new import pruned the dead key and added its own";
}

TEST_F(SharedPictures, ADisplayThatKeepsAnotherMipRangeGetsItsOwnTexture)
{
    ScenePackage package;
    // 256 down to 1: nine levels. A small surface does not need the big ones.
    MakePictureScene(package, "mip_pic", Pattern(256, 256, 3), 9);

    GpuSceneOptions large;
    large.width  = 1024;
    large.height = 576;
    GpuSceneOptions small;
    small.width  = 100;
    small.height = 56;

    auto big_display   = std::make_unique<GpuScene>(package, large);
    auto small_display = std::make_unique<GpuScene>(package, small);
    auto small_again   = std::make_unique<GpuScene>(package, small);
    ASSERT_TRUE(big_display->ok()) << big_display->error();
    ASSERT_TRUE(small_display->ok()) << small_display->error();
    ASSERT_TRUE(small_again->ok()) << small_again->error();

    ASSERT_NE(HandleOf(*big_display, "mip_pic"), nullptr);
    ASSERT_NE(HandleOf(*small_display, "mip_pic"), nullptr);
    EXPECT_NE(HandleOf(*big_display, "mip_pic"), HandleOf(*small_display, "mip_pic"))
        << "a display that drops a leading level does not bind the full chain";
    EXPECT_EQ(HandleOf(*small_display, "mip_pic"), HandleOf(*small_again, "mip_pic"))
        << "displays keeping the same levels still share";

    // Both draw the picture; the canvas sits in the middle of the surface.
    for (auto* display : { big_display.get(), small_display.get() }) {
        const Image    picture = display->Run(2);
        const uint32_t cx      = picture.width / 2;
        const uint32_t cy      = picture.height / 2;
        EXPECT_TRUE(ExpectPixel(picture, cx - 40, cy - 20, { 200, 20, 20, 255 }, 12)) << picture.width;
        EXPECT_TRUE(ExpectPixel(picture, cx + 40, cy - 20, { 20, 200, 20, 255 }, 12)) << picture.width;
        EXPECT_TRUE(ExpectPixel(picture, cx - 40, cy + 20, { 20, 20, 200, 255 }, 12)) << picture.width;
        EXPECT_TRUE(ExpectPixel(picture, cx + 40, cy + 20, { 200, 200, 20, 255 }, 12)) << picture.width;
    }
}

TEST_F(SharedPictures, AFileRewrittenWithOtherPixelsUnderTheSameNameIsLoadedFresh)
{
    // Large enough to be read back in several bands.
    constexpr uint32_t kSide        = 1100;
    const Image        old_picture  = Pattern(kSide, kSide, 4);
    Image              block_change = old_picture; // the lower right quarter turns white
    for (uint32_t y = kSide / 2; y < kSide; ++y) {
        for (uint32_t x = kSide / 2; x < kSide; ++x) block_change.Set(x, y, { 255, 255, 255, 255 });
    }
    Image last_texel_change = old_picture; // one texel, the last one in the file
    last_texel_change.Set(kSide - 1, kSide - 1, { 1, 2, 3, 255 });

    ScenePackage package;
    MakePictureScene(package, "rewritten_pic", old_picture);
    GpuScene shown(package);
    ASSERT_TRUE(shown.ok()) << shown.error();
    const void* old_handle = HandleOf(shown, "rewritten_pic");
    ASSERT_NE(old_handle, nullptr);

    // The file changes while the old picture is still shown: the same name, the same layout.
    package.AddTexture("rewritten_pic", block_change);
    GpuScene reloaded(package);
    ASSERT_TRUE(reloaded.ok()) << reloaded.error();
    const void* new_handle = HandleOf(reloaded, "rewritten_pic");
    ASSERT_NE(new_handle, nullptr);
    EXPECT_NE(new_handle, old_handle) << "name and layout alone are never trusted";

    // The display that loaded the new file shows it, and the old one still shows its picture.
    const Image fresh = reloaded.Run(2);
    const Image stale = shown.Run(2);
    EXPECT_TRUE(ExpectRegionAverage(fresh, 160, 90, 80, 40, { 255, 255, 255, 255 }, 1.0));
    EXPECT_TRUE(ExpectRegionAverage(stale, 160, 90, 80, 40, { 200, 200, 20, 255 }, 8.0));

    // A third display on the new file shares the new texture.
    GpuScene third(package);
    ASSERT_TRUE(third.ok()) << third.error();
    EXPECT_EQ(HandleOf(third, "rewritten_pic"), new_handle);

    // A change to the last texel of the file alone is found too: the whole picture is compared.
    package.AddTexture("rewritten_pic", last_texel_change);
    GpuScene last(package);
    ASSERT_TRUE(last.ok()) << last.error();
    EXPECT_NE(HandleOf(last, "rewritten_pic"), new_handle);
    EXPECT_NE(HandleOf(last, "rewritten_pic"), old_handle);
}

TEST_F(SharedPictures, AnotherWallpapersFileOfTheSameNameGetsItsOwnUpload)
{
    ScenePackage first_package;
    MakePictureScene(first_package, "homonym", Pattern(64, 64, 5));
    ScenePackage second_package;
    MakePictureScene(second_package, "homonym", Pattern(64, 64, 6)); // same name and layout, other pixels

    GpuScene first(first_package);
    GpuScene second(second_package);
    ASSERT_TRUE(first.ok()) << first.error();
    ASSERT_TRUE(second.ok()) << second.error();
    ASSERT_NE(HandleOf(first, "homonym"), nullptr);
    EXPECT_NE(HandleOf(first, "homonym"), HandleOf(second, "homonym"));
    EXPECT_GT(CountDifferingPixels(first.Run(2), second.Run(2)), 0u);
}

TEST_F(SharedPictures, PicturesTheRuntimeFillsStayPerDisplay)
{
    // A text layer is drawn from an image the runtime rasterises and replaces; it is not a
    // file, and no display may bind another's.
    ScenePackage package;
    package.InstallStandardAssets();
    Json text = { { "id", 1 },
                  { "name", "label" },
                  { "text", "shared?" },
                  { "pointsize", 24.0 },
                  { "origin", "128 72 0" },
                  { "size", "200 60" },
                  { "color", "1 1 1" },
                  { "alpha", 1.0 },
                  { "visible", true } };
    package.SetProject();
    package.SetScene(SceneJson({}, { text }));

    const uint64_t bytes_before   = MetalRender::SharedImageBytesForTests();
    const uint64_t uploads_before = MetalRender::ImageUploadsForTests();
    std::unique_ptr<GpuScene> first, second;
    LoadTogether(package, first, second);
    ASSERT_TRUE(first->ok()) << first->error();
    ASSERT_TRUE(second->ok()) << second->error();
    const Image drawn = first->Run(2);
    second->Step(2);
    ASSERT_FALSE(drawn.empty());
    EXPECT_GT(CountDifferingPixels(drawn, Image::Solid(drawn.width, drawn.height, { 0, 0, 0, 255 })), 0u)
        << "the text was drawn, from an image the runtime made";
    EXPECT_EQ(MetalRender::SharedImageBytesForTests(), bytes_before) << "no runtime picture is shared";
    EXPECT_EQ(MetalRender::ImageUploadsForTests(), uploads_before);
}
