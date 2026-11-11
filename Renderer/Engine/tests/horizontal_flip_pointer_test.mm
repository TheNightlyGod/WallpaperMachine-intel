// The pointer follows the picture when the wallpaper is shown mirrored: with the
// `horizontal_flip` property on, the pointer position a scene reads is mirrored left to right
// (x becomes 1 - x, y is untouched), so cursor interaction stays aligned with what is drawn.
//
// Drives the real host path: a `SceneWallpaper` built through the C bindings on a detached
// Metal layer, a parsed synthetic scene committed to its render thread, and the pointer fed
// through `owe_scene_wallpaper_mouse_input`. What the scene received is read from
// `Scene::pointerPosition`, which the frame loop writes after the mirror.
//
// Creates only a detached CAMetalLayer and private textures; skips without a Metal device.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <gtest/gtest.h>

#include "Audio/SoundManager.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Platform/Apple/SceneWallpaperBindings.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include "Scene/Scene.h"
#include "SceneSourceResolver.hpp"
#include "SceneWallpaper.hpp"
#include "WPSceneParser.hpp"
#include "support/gpu_scene.hpp"
#include "support/scene_package.hpp"

#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <thread>

#include <unistd.h>

namespace
{

using namespace wallpaper;
namespace disk = std::filesystem;

constexpr float kTolerance = 1.0e-5f;

// Parses the package the way the host's control thread does.
std::shared_ptr<Scene> ParseScene(const we_test::ScenePackage& package, const disk::path& scratch,
                                  audio::SoundManager& sound, std::string* error)
{
    SceneSourceResolution resolved;
    if (! ResolveSceneSourcePaths(package.project_file(), &resolved, error)) return nullptr;
    auto vfs = std::make_unique<fs::VFS>();
    auto shared = fs::CreatePhysicalFs((scratch / "shared").string());
    if (shared == nullptr || ! vfs->Mount("/assets", std::move(shared))) {
        *error = "the shared assets cannot be mounted";
        return nullptr;
    }
    if (! MountSceneSource(*vfs, resolved.scene_source, error)) return nullptr;
    auto cache = fs::CreatePhysicalFs((scratch / "cache").string(), true);
    if (cache == nullptr || ! vfs->Mount("/cache", std::move(cache), "cache")) {
        *error = "the shader cache cannot be mounted";
        return nullptr;
    }
    if (! InstallVirtualAssets(*vfs)) {
        *error = "the built-in assets cannot be installed";
        return nullptr;
    }
    const std::string scene_text =
        fs::GetFileContent(*vfs, "/assets/" + resolved.scene_source.pkg_entry);

    ProjectProperties properties;
    if (! ParseProjectProperties(package.project_file(), &properties, error)) return nullptr;
    SceneParseRequest request;
    request.scene_id                    = resolved.scene_source.scene_id;
    request.project_path                = package.project_file();
    request.project_properties          = &properties;
    request.authored_project_properties = &properties;

    WPSceneParser parser;
    auto          scene = parser.Parse(request, scene_text, *vfs, sound);
    if (scene == nullptr) {
        *error = "the parse produced no scene";
        return nullptr;
    }
    scene->project_path = package.project_file();
    scene->vfs          = std::move(vfs);
    return scene;
}

class HorizontalFlipPointerTest : public ::testing::Test {
protected:
    void SetUp() override
    {
        WE_SKIP_WITHOUT_METAL();
        std::string pattern = (disk::temp_directory_path() / "we-flip-pointer-XXXXXX").string();
        ASSERT_NE(::mkdtemp(pattern.data()), nullptr);
        scratch_ = pattern;
        disk::create_directories(scratch_ / "cache");
        disk::create_directories(scratch_ / "shared");

        package_.MakeSolidScene({ 20, 40, 60, 255 });
        sound_ = std::make_unique<audio::SoundManager>(audio::SoundManager::OutputBackend::Null);
        std::string error;
        scene_ = ParseScene(package_, scratch_, *sound_, &error);
        ASSERT_NE(scene_, nullptr) << error;

        ASSERT_EQ(owe_scene_wallpaper_new(&native_), 0) << owe_last_error();
        ASSERT_EQ(owe_scene_wallpaper_init(native_), 0) << owe_last_error();
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            layer_               = [CAMetalLayer layer];
            layer_.device        = device;
            layer_.pixelFormat   = MTLPixelFormatBGRA8Unorm;
            layer_.drawableSize  = CGSizeMake(128, 72);
        }
    }

    void TearDown() override
    {
        if (native_ != nullptr) {
            owe_scene_wallpaper_shutdown(native_);
            owe_scene_wallpaper_delete(native_);
        }
        scene_.reset();
        sound_.reset();
        std::error_code ignored;
        if (! scratch_.empty()) disk::remove_all(scratch_, ignored);
    }

    // Gives the wallpaper its surface and commits the parsed scene to the render thread.
    void Start()
    {
        ASSERT_EQ(owe_scene_wallpaper_init_metal(native_, (__bridge void*)layer_, 128, 72, 128, 72, 1.0),
                  0)
            << owe_last_error();
        ASSERT_EQ(owe_scene_wallpaper_set_target_fps(native_, 60), 0) << owe_last_error();
        SceneWallpaperInputTestAccess::PostScene(
            SceneWallpaperInputTestAccess::FromNative(*native_), scene_);
    }

    void SetFlip(bool on)
    {
        ASSERT_EQ(owe_scene_wallpaper_set_property_bool(native_, owe_property_horizontal_flip(), on),
                  0)
            << owe_last_error();
    }

    // Moves the pointer and waits until the frame loop has delivered `expected` to the scene.
    bool PointerArrivesAs(double x, double y, std::array<float, 2> expected)
    {
        EXPECT_EQ(owe_scene_wallpaper_mouse_input(native_, x, y), 0);
        const auto give_up = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (std::chrono::steady_clock::now() < give_up) {
            const std::array<float, 2> seen = scene_->pointerPosition;
            if (std::fabs(seen[0] - expected[0]) < kTolerance &&
                std::fabs(seen[1] - expected[1]) < kTolerance) {
                return true;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        ADD_FAILURE() << "the scene saw (" << scene_->pointerPosition[0] << ", "
                      << scene_->pointerPosition[1] << "), expected (" << expected[0] << ", "
                      << expected[1] << ")";
        return false;
    }

    we_test::ScenePackage                package_;
    disk::path                           scratch_;
    std::unique_ptr<audio::SoundManager> sound_;
    std::shared_ptr<Scene>               scene_;
    owe_scene_wallpaper*                 native_ { nullptr };
    CAMetalLayer*                        layer_ { nil };
};

TEST_F(HorizontalFlipPointerTest, ThePropertyNameIsHorizontalFlip)
{
    EXPECT_STREQ(owe_property_horizontal_flip(), "horizontal_flip");
}

TEST_F(HorizontalFlipPointerTest, AWallpaperThatIsNotFlippedDeliversThePointerAsItIs)
{
    Start();
    EXPECT_TRUE(PointerArrivesAs(0.25, 0.4, { 0.25f, 0.4f }));
}

TEST_F(HorizontalFlipPointerTest, FlippingMirrorsTheHorizontalAxisOnly)
{
    Start();
    SetFlip(true);
    EXPECT_TRUE(PointerArrivesAs(0.25, 0.4, { 0.75f, 0.4f }));
    EXPECT_TRUE(PointerArrivesAs(0.9, 0.1, { 0.1f, 0.1f }));
}

TEST_F(HorizontalFlipPointerTest, TurningTheFlipOffRestoresThePointer)
{
    Start();
    SetFlip(true);
    ASSERT_TRUE(PointerArrivesAs(0.25, 0.4, { 0.75f, 0.4f }));
    SetFlip(false);
    EXPECT_TRUE(PointerArrivesAs(0.25, 0.4, { 0.25f, 0.4f }));
}

TEST_F(HorizontalFlipPointerTest, AFlipSetBeforeTheSurfaceExistsAppliesOnceItDoes)
{
    SetFlip(true);
    Start();
    EXPECT_TRUE(PointerArrivesAs(0.25, 0.4, { 0.75f, 0.4f }));
}

TEST_F(HorizontalFlipPointerTest, TheFlipSurvivesAGraphRebuild)
{
    Start();
    SetFlip(true);
    ASSERT_TRUE(PointerArrivesAs(0.25, 0.4, { 0.75f, 0.4f }));
    // A render-scale change rebuilds the compiled graph.
    ASSERT_EQ(owe_scene_wallpaper_set_render_scale(native_, 0.5), 0) << owe_last_error();
    EXPECT_TRUE(PointerArrivesAs(0.6, 0.5, { 0.4f, 0.5f }));
}

// Wallpaper Engine's per-wallpaper "flip horizontally" option goes through the same mirror,
// so the pointer follows the picture.
TEST_F(HorizontalFlipPointerTest, TheUserOptionsFlipMirrorsThePointer)
{
    Start();
    owe_user_options options {};
    options.brightness = options.contrast = options.saturation = options.hue = 50.0f;
    options.lut_strength    = 100.0f;
    options.mouse_parallax  = true;
    options.playback_rate   = 100.0f;
    options.flip_horizontal = true;
    ASSERT_EQ(owe_scene_wallpaper_set_user_options(native_, &options), 0) << owe_last_error();
    EXPECT_TRUE(PointerArrivesAs(0.25, 0.4, { 0.75f, 0.4f }));
    options.flip_horizontal = false;
    ASSERT_EQ(owe_scene_wallpaper_set_user_options(native_, &options), 0) << owe_last_error();
    EXPECT_TRUE(PointerArrivesAs(0.25, 0.4, { 0.25f, 0.4f }));
}

TEST_F(HorizontalFlipPointerTest, ThePropertyIsABoolAndOtherKindsAreRefused)
{
    EXPECT_NE(owe_scene_wallpaper_set_property_int32(native_, owe_property_horizontal_flip(), 1), 0);
    EXPECT_NE(owe_scene_wallpaper_set_property_float(native_, owe_property_horizontal_flip(), 1.0f), 0);
    EXPECT_NE(owe_scene_wallpaper_set_property_string(native_, owe_property_horizontal_flip(), "true"), 0);
}

} // namespace
