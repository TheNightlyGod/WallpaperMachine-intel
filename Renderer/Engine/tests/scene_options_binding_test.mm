// The scene quality and Wallpaper Engine's per-wallpaper options through the C bindings:
// values are checked, a value set before the load is what the scene parses with, and the
// quality read-back reports what the renderer actually draws (no MSAA or
// volumetric casting light exists in this fixture, so those read 0; shadows, reflection and post-processing read what
// was applied). The user options load the scene again only when the colour pass changes
// shape; the scene traits and LUT files are read without a scene.
//
// Driven end to end through `SceneWallpaper` on a `CAMetalLayer` no window owns,
// sound on the null backend.

#include "Platform/Apple/SceneWallpaperBindings.h"
#include "Scene/SceneWallpaper.hpp"
#include "Scene/SceneWallpaperSurface.hpp"
#include "mdl_fixtures.hpp"
#include <nlohmann/json.hpp>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <gtest/gtest.h>

#include <cmath>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <functional>
#include <vector>
#include <thread>
#include <unistd.h>

using namespace wallpaper;
using namespace std::chrono_literals;

namespace
{

void WriteText(const std::filesystem::path& path, const std::string& text)
{
    std::filesystem::create_directories(path.parent_path());
    std::ofstream(path) << text;
}

/// One opaque card.
std::filesystem::path WriteCardScene(const std::filesystem::path& root)
{
    WriteText(root / "project.json",
              R"({"title":"Card","type":"scene","file":"layout.json","general":{"properties":{}}})");
    WriteText(root / "models/card.json",
              R"({"width":160,"height":96,"material":"materials/card.json"})");
    WriteText(root / "materials/card.json",
              R"({"passes":[{"shader":"card","blending":"translucent","cullmode":"nocull",)"
              R"("depthtest":"disabled","depthwrite":"disabled"}]})");
    WriteText(root / "shaders/card.vert",
              "uniform mat4 g_ModelViewProjectionMatrix;\n"
              "attribute vec3 a_Position;\n"
              "void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); }\n");
    WriteText(root / "shaders/card.frag", "void main() { gl_FragColor = vec4(0.2, 0.4, 0.6, 1.0); }\n");
    WriteText(root / "layout.json",
              R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
              R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],)"
              R"("clearcolor":[0.1,0.2,0.3],"cameraparallax":false,)"
              R"("orthogonalprojection":{"width":384,"height":256}},)"
              R"("objects":[{"id":1,"name":"card","image":"models/card.json",)"
              R"("origin":[192,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}]})");
    return root / "project.json";
}

/// A wallpaper on a layer no window owns, its sound on the null backend, with
/// the surface already taken when it is configured.
class Loading {
public:
    Loading()
    {
        m_layer               = [CAMetalLayer layer];
        m_layer.device        = MTLCreateSystemDefaultDevice();
        m_layer.pixelFormat   = MTLPixelFormatBGRA8Unorm;
        m_layer.contentsScale = 1.0;
        m_layer.frame         = CGRectMake(0, 0, kWidth, kHeight);
        m_layer.drawableSize  = CGSizeMake(kWidth, kHeight);

        SceneWallpaperInputTestAccess::UseNullSoundOutput(m_wallpaper);
        EXPECT_TRUE(m_wallpaper.init());
        m_wallpaper.setPropertyObject(PROPERTY_FIRST_FRAME_CALLBACK,
                                      std::make_shared<FirstFrameCallback>([this] {
                                          std::scoped_lock lock(m_mutex);
                                          ++m_first_frames;
                                          m_changed.notify_all();
                                      }));
        RenderInitInfo info;
        info.metal_layer   = (__bridge void*)m_layer;
        info.width         = kWidth;
        info.height        = kHeight;
        info.render_width  = kWidth;
        info.render_height = kHeight;
        m_wallpaper.initSurface(info);
    }

    ~Loading() { m_wallpaper.shutdown(); }

    bool WaitForSurface()
    {
        const auto deadline = std::chrono::steady_clock::now() + 10s;
        while (! SceneWallpaperInputTestAccess::SurfaceHandedOver(m_wallpaper)) {
            if (std::chrono::steady_clock::now() > deadline) return false;
            std::this_thread::sleep_for(1ms);
        }
        return true;
    }

    /// The first frame is reported on the thread that loads, after everything the
    /// host sent with the configuration.
    bool WaitForFirstFrame()
    {
        std::unique_lock lock(m_mutex);
        return m_changed.wait_for(lock, 30s, [&] { return m_first_frames > 0; });
    }

    /// Each load reports its own first frame, so this counts the loads.
    bool WaitForFirstFrames(int count, std::chrono::milliseconds limit = 30s)
    {
        std::unique_lock lock(m_mutex);
        return m_changed.wait_for(lock, limit, [&] { return m_first_frames >= count; });
    }
    int FirstFrames()
    {
        std::scoped_lock lock(m_mutex);
        return m_first_frames;
    }

    SceneWallpaperConfig Config(const std::filesystem::path& project,
                                const std::filesystem::path& scratch)
    {
        std::filesystem::create_directories(scratch / "assets");
        SceneWallpaperConfig config;
        config.source     = project.string();
        config.assets     = (scratch / "assets").string();
        config.cache_path = (scratch / "cache").string();
        config.fps        = 60;
        return config;
    }

    SceneWallpaper& wallpaper() { return m_wallpaper; }
    
private:
    static constexpr uint16_t kWidth  = 640;
    static constexpr uint16_t kHeight = 360;

    CAMetalLayer*           m_layer { nil };
    SceneWallpaper          m_wallpaper;
    std::mutex              m_mutex;
    std::condition_variable m_changed;
    int                     m_first_frames { 0 };
};

bool WaitFor(const std::function<bool()>& done)
{
    const auto deadline = std::chrono::steady_clock::now() + 30s;
    while (! done()) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(2ms);
    }
    return true;
}

owe_scene_quality Quality(int32_t msaa, int32_t shadows, int32_t volumetrics, bool reflection, int32_t post)
{
    return owe_scene_quality { msaa, shadows, volumetrics, reflection, post };
}

class SceneQualityBinding : public ::testing::Test {
protected:
    void SetUp() override
    {
        static int serial = 0;
        root_ = std::filesystem::temp_directory_path() /
                ("owe-scene-quality-" + std::to_string(::getpid()) + "-" + std::to_string(serial++));
        std::filesystem::remove_all(root_);
        std::filesystem::create_directories(root_);
    }
    void TearDown() override
    {
        std::error_code ignored;
        std::filesystem::remove_all(root_, ignored);
    }
    std::filesystem::path root_;
};

} // namespace

TEST_F(SceneQualityBinding, ANullSceneOrQualityIsRefused)
{
    const owe_scene_quality quality = Quality(0, 2, 2, true, OWE_POST_PROCESSING_ENABLED);
    EXPECT_NE(owe_scene_wallpaper_set_quality(nullptr, &quality), 0);
    owe_scene_wallpaper* native = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&native), 0) << owe_last_error();
    EXPECT_NE(owe_scene_wallpaper_set_quality(native, nullptr), 0);
    owe_scene_quality out {};
    EXPECT_NE(owe_scene_wallpaper_quality_in_force(nullptr, &out), 0);
    owe_scene_wallpaper_delete(native);
}

TEST_F(SceneQualityBinding, ValuesOutsideWallpaperEnginesSetsAreRefused)
{
    owe_scene_wallpaper* native = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&native), 0) << owe_last_error();
    ASSERT_EQ(owe_scene_wallpaper_init(native), 0) << owe_last_error();
    const owe_scene_quality three_samples = Quality(3, 2, 2, true, OWE_POST_PROCESSING_ENABLED);
    const owe_scene_quality shadows_five  = Quality(0, 5, 2, true, OWE_POST_PROCESSING_ENABLED);
    const owe_scene_quality post_low      = Quality(0, 2, 2, true, 1);
    const owe_scene_quality good          = Quality(8, 4, 0, false, OWE_POST_PROCESSING_DISPLAY_HDR);
    EXPECT_NE(owe_scene_wallpaper_set_quality(native, &three_samples), 0);
    EXPECT_NE(owe_scene_wallpaper_set_quality(native, &shadows_five), 0);
    EXPECT_NE(owe_scene_wallpaper_set_quality(native, &post_low), 0);
    EXPECT_EQ(owe_scene_wallpaper_set_quality(native, &good), 0) << owe_last_error();
    owe_scene_wallpaper_shutdown(native);
    owe_scene_wallpaper_delete(native);
}

TEST_F(SceneQualityBinding, NothingIsInForceBeforeAScene)
{
    SceneWallpaper    wallpaper;
    owe_scene_quality out {};
    EXPECT_NE(owe_scene_wallpaper_quality_in_force(&wallpaper, &out), 0);
}

TEST_F(SceneQualityBinding, AQualitySetBeforeTheLoadIsInForceAndReportsOnlyWhatIsDrawn)
{
    if (MTLCreateSystemDefaultDevice() == nil) GTEST_SKIP() << "no Metal device";
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    SceneQuality asked;
    asked.msaa            = 4;
    asked.shadows         = static_cast<int>(QualityLevel::Ultra);
    asked.volumetrics     = static_cast<int>(QualityLevel::High);
    asked.reflection      = false;
    asked.post_processing = static_cast<int>(PostProcessing::Ultra);
    loading.wallpaper().setSceneQuality(asked);
    loading.wallpaper().applyConfig(loading.Config(WriteCardScene(root_ / "scene"), root_ / "run"));
    ASSERT_TRUE(loading.WaitForFirstFrame());

    owe_scene_quality out {};
    ASSERT_EQ(owe_scene_wallpaper_quality_in_force(&loading.wallpaper(), &out), 0);
    EXPECT_EQ(out.msaa, 0) << "no multisampled pass is drawn yet, and a card-only scene never gets one";
    EXPECT_EQ(out.shadows, OWE_QUALITY_OFF) << "the scene has no shadow-casting light or model";
    EXPECT_EQ(out.volumetrics, OWE_QUALITY_OFF) << "this scene has no volumetric casting light";
    EXPECT_FALSE(out.reflection);
    EXPECT_EQ(out.post_processing, OWE_POST_PROCESSING_ULTRA);
}

TEST_F(SceneQualityBinding, AChangeAfterTheLoadLoadsTheSceneAgain)
{
    if (MTLCreateSystemDefaultDevice() == nil) GTEST_SKIP() << "no Metal device";
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    loading.wallpaper().applyConfig(loading.Config(WriteCardScene(root_ / "scene"), root_ / "run"));
    ASSERT_TRUE(loading.WaitForFirstFrame());
    ASSERT_TRUE(loading.wallpaper().qualityInForce().has_value());
    EXPECT_EQ(loading.wallpaper().qualityInForce()->post_processing, static_cast<int>(PostProcessing::Enabled))
        << "the default is Wallpaper Engine's first-run medium preset";

    SceneQuality changed;
    changed.post_processing = static_cast<int>(PostProcessing::Disabled);
    loading.wallpaper().setSceneQuality(changed);
    EXPECT_TRUE(WaitFor([&] {
        const auto now = loading.wallpaper().qualityInForce();
        return now.has_value() && now->post_processing == static_cast<int>(PostProcessing::Disabled);
    }));
}


TEST_F(SceneQualityBinding, ShadowsInForceFollowsTheLiveCasterVisibility)
{
    if (MTLCreateSystemDefaultDevice() == nil) GTEST_SKIP() << "no Metal device";
    const auto root = root_ / "shadows";
    const auto project = WriteCardScene(root);
    mdltest::MeshSpec mesh;
    mesh.material = "materials/card.json";
    mesh.flag = mdltest::kPosition;
    mesh.vertices = 3;
    mesh.indices = { 0, 1, 2 };
    const auto bytes = mdltest::mdlFile(23, { mesh });
    std::ofstream model(root / "models/caster.mdl", std::ios::binary);
    model.write(reinterpret_cast<const char*>(bytes.data().data()), bytes.size());
    model.close();
    WriteText(root / "materials/util/shadowcaster.json",
              R"({"passes":[{"shader":"shadowcaster","cullmode":"nocull"}]})");
    WriteText(root / "shaders/shadowcaster.vert",
              "uniform mat4 g_ModelMatrix; uniform mat4 g_ViewportViewProjectionMatrices[6];\n"
              "attribute vec3 a_Position; void main() { gl_Position = mul(mul(vec4(a_Position,1),g_ModelMatrix),g_ViewportViewProjectionMatrices[0]); }\n");
    WriteText(root / "shaders/shadowcaster.frag", "void main() {}\n");
    auto config = nlohmann::json::parse(std::ifstream(project));
    config["general"]["properties"]["shadow"] = { { "type", "bool" }, { "value", true } };
    WriteText(project, config.dump());
    auto document = nlohmann::json::parse(std::ifstream(root / "layout.json"));
    document["general"]["bloom"] = false;
    document["general"]["lightconfig"] = { { "spot", 1 }, { "spotshadow", 1 } };
    document["objects"].push_back({ { "id", 2 }, { "name", "caster" }, { "model", "models/caster.mdl" },
        { "origin", { 192, 128, 10 } }, { "scale", { 1, 1, 1 } }, { "angles", { 0, 0, 0 } },
        { "visible", { { "value", true }, { "user", "shadow" } } } });
    document["objects"].push_back({ { "id", 3 }, { "name", "lamp" }, { "light", "lspot" },
        { "origin", { 300, 128, 300 } }, { "radius", 1000 }, { "castshadow", true } });
    WriteText(root / "layout.json", document.dump());
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    SceneQuality asked;
    asked.shadows = static_cast<int>(QualityLevel::High);
    loading.wallpaper().setSceneQuality(asked);
    loading.wallpaper().applyConfig(loading.Config(project, root_ / "run"));
    ASSERT_TRUE(loading.WaitForFirstFrame());
    const auto sees = [&](int quality) {
        return WaitFor([&] {
            const auto current = loading.wallpaper().qualityInForce();
            return current && current->shadows == quality;
        });
    };
    ASSERT_TRUE(sees(static_cast<int>(QualityLevel::High)));
    loading.wallpaper().setPropertyString(PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON, R"({"shadow":false})");
    ASSERT_TRUE(sees(static_cast<int>(QualityLevel::Off)));
    loading.wallpaper().setPropertyString(PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON, R"({"shadow":true})");
    EXPECT_TRUE(sees(static_cast<int>(QualityLevel::High)));
}

TEST_F(SceneQualityBinding, VolumetricsInForceFollowsLiveVisibility) {
    if (MTLCreateSystemDefaultDevice() == nil) GTEST_SKIP() << "no Metal device";
    const auto root=root_/"volume";
    const auto project=WriteCardScene(root);
    WriteText(project,R"({"title":"Volume quality","type":"scene","file":"layout.json",)"
        R"("general":{"properties":{"visible":{"type":"bool","value":true}}}})");
    // Quality read-back observes a compiled utility chain. The separate volume
    // pixel tests exercise the integration shader and camera/depth calculations.
    for (const char* name : {"volumetrics_back","volumetrics_front","volumetrics_fullscreen",
                             "volumetrics_blur_h","volumetrics_blur_v","volumetrics_combine"})
        WriteText(root/"materials"/"util"/(std::string(name)+".json"),
            R"({"passes":[{"shader":"card","blending":"additive","cullmode":"nocull",)"
            R"("depthtest":"disabled","depthwrite":"disabled"}]})");
    auto document=nlohmann::json::parse(std::ifstream(root/"layout.json"));
    document["general"]["bloom"]=false;
    document["general"]["lightconfig"]={{"point",1}};
    document["objects"].push_back({{"id",2},{"name","bulb"},{"light","lpoint"},
        {"origin",{192,128,0}},{"radius",80},{"color","1 0 0"},{"intensity",4},
        {"castvolumetrics",true},
        {"visible",{{"value",true},{"user","visible"}}}});
    WriteText(root/"layout.json",document.dump());
    Loading loading;ASSERT_TRUE(loading.WaitForSurface());
    SceneQuality asked;asked.volumetrics=static_cast<int>(QualityLevel::High);
    loading.wallpaper().setSceneQuality(asked);
    loading.wallpaper().applyConfig(loading.Config(project,root_/"run"));
    ASSERT_TRUE(loading.WaitForFirstFrame());
    const auto sees=[&](QualityLevel level) { return WaitFor([&] {
        const auto quality=loading.wallpaper().qualityInForce();
        return quality && quality->volumetrics==static_cast<int>(level);
    }); };
    ASSERT_TRUE(sees(QualityLevel::High));
    loading.wallpaper().setPropertyString(PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON,R"({"visible":false})");
    ASSERT_TRUE(sees(QualityLevel::Off));
    loading.wallpaper().setPropertyString(PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON,R"({"visible":true})");
    EXPECT_TRUE(sees(QualityLevel::High));
}

// ---- Wallpaper Engine's per-wallpaper options, scene traits and LUT files ----------------

namespace
{

owe_user_options Identity()
{
    owe_user_options options {};
    options.brightness = options.contrast = options.saturation = options.hue = 50.0f;
    options.lut            = "";
    options.lut_strength   = 100.0f;
    options.mouse_parallax = true;
    options.playback_rate  = 100.0f;
    return options;
}

/// A loose scene project whose `general` is `general_json`.
std::filesystem::path WriteGeneralScene(const std::filesystem::path& root, const std::string& general_json)
{
    WriteText(root / "project.json", R"({"title":"Traits","type":"scene","file":"scene.json"})");
    WriteText(root / "scene.json", R"({"general":)" + general_json + R"(,"objects":[]})");
    return root / "project.json";
}

void PutI32(std::string& out, int32_t value)
{
    out.append(reinterpret_cast<const char*>(&value), sizeof(value));
}

/// A raw RGBA8 volume .tex (flag 0x40 with clamp), `edge` voxels to a side, `voxels` laid
/// out slice by slice.
void WriteVolumeTex(const std::filesystem::path& path, int32_t edge, const std::string& voxels)
{
    std::string bytes;
    bytes.append("TEXV0005", 9);
    bytes.append("TEXI0001", 9);
    PutI32(bytes, 0);    // rgba8888
    PutI32(bytes, 0x42); // clamp | volume
    for (int i = 0; i < 4; ++i) PutI32(bytes, edge);
    PutI32(bytes, edge); // depth
    PutI32(bytes, 0);    // colour
    bytes.append("TEXB0003", 9);
    PutI32(bytes, 1);  // one picture
    PutI32(bytes, -1); // type
    PutI32(bytes, 1);  // one level
    PutI32(bytes, edge);
    PutI32(bytes, edge);
    PutI32(bytes, edge);
    PutI32(bytes, 0);
    PutI32(bytes, static_cast<int32_t>(voxels.size()));
    PutI32(bytes, static_cast<int32_t>(voxels.size()));
    bytes += voxels;
    std::filesystem::create_directories(path.parent_path());
    std::ofstream(path, std::ios::binary) << bytes;
}

class SceneUserOptionsBinding : public SceneQualityBinding {};

} // namespace

TEST_F(SceneUserOptionsBinding, ANullSceneOrOptionsAreRefused)
{
    const owe_user_options options = Identity();
    EXPECT_NE(owe_scene_wallpaper_set_user_options(nullptr, &options), 0);
    owe_scene_wallpaper* native = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&native), 0) << owe_last_error();
    EXPECT_NE(owe_scene_wallpaper_set_user_options(native, nullptr), 0);
    owe_scene_wallpaper_delete(native);
}

TEST_F(SceneUserOptionsBinding, ValuesOutsideWallpaperEnginesRangesAreRefused)
{
    owe_scene_wallpaper* native = nullptr;
    ASSERT_EQ(owe_scene_wallpaper_new(&native), 0) << owe_last_error();
    ASSERT_EQ(owe_scene_wallpaper_init(native), 0) << owe_last_error();
    auto bright = Identity();
    bright.brightness = 100.5f;
    auto slow = Identity();
    slow.playback_rate = 9.0f;
    auto not_a_number = Identity();
    not_a_number.hue = std::nanf("");
    auto path = Identity();
    path.lut = "../lut/neutral";
    auto dots = Identity();
    dots.lut = "..";
    EXPECT_NE(owe_scene_wallpaper_set_user_options(native, &bright), 0);
    EXPECT_NE(owe_scene_wallpaper_set_user_options(native, &slow), 0);
    EXPECT_NE(owe_scene_wallpaper_set_user_options(native, &not_a_number), 0);
    EXPECT_NE(owe_scene_wallpaper_set_user_options(native, &path), 0);
    EXPECT_NE(owe_scene_wallpaper_set_user_options(native, &dots), 0);
    auto good = Identity();
    good.color_enabled = true;
    good.brightness    = 100.0f;
    good.lut           = "lutx32_amber";
    good.playback_rate = 200.0f;
    EXPECT_EQ(owe_scene_wallpaper_set_user_options(native, &good), 0) << owe_last_error();
    good.lut = nullptr;
    EXPECT_EQ(owe_scene_wallpaper_set_user_options(native, &good), 0) << owe_last_error();
    owe_scene_wallpaper_shutdown(native);
    owe_scene_wallpaper_delete(native);
}

TEST_F(SceneUserOptionsBinding, OnlyAChangeOfTheColourPassShapeLoadsTheSceneAgain)
{
    if (MTLCreateSystemDefaultDevice() == nil) GTEST_SKIP() << "no Metal device";
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    loading.wallpaper().applyConfig(loading.Config(WriteCardScene(root_ / "scene"), root_ / "run"));
    ASSERT_TRUE(loading.WaitForFirstFrame());
    ASSERT_EQ(loading.FirstFrames(), 1);

    // Flip, rate and mouse parallax are live.
    WeUserOptions live;
    live.flip_horizontal = true;
    live.playback_rate   = 150.0f;
    live.mouse_parallax  = false;
    loading.wallpaper().setUserOptions(live);
    EXPECT_FALSE(loading.WaitForFirstFrames(2, 1500ms)) << "a value change is applied without a load";

    // Colour options moved off the identity: the pass has to be built.
    WeUserOptions colour = live;
    colour.color_enabled = true;
    colour.brightness    = 60.0f;
    loading.wallpaper().setUserOptions(colour);
    EXPECT_TRUE(loading.WaitForFirstFrames(2)) << "turning the colour pass on loads the scene again";

    // Another value of the same pass is written into it.
    WeUserOptions brighter = colour;
    brighter.brightness    = 70.0f;
    loading.wallpaper().setUserOptions(brighter);
    EXPECT_FALSE(loading.WaitForFirstFrames(3, 1500ms)) << "a value of a built pass is applied live";

    // Back at the identity the pass goes away.
    loading.wallpaper().setUserOptions(WeUserOptions {});
    EXPECT_TRUE(loading.WaitForFirstFrames(3));
}

TEST_F(SceneUserOptionsBinding, TheSceneTraitsOfferMouseParallaxOnlyWhenTheCursorMovesTheCamera)
{
    owe_scene_traits traits {};
    EXPECT_NE(owe_read_scene_traits(nullptr, &traits), 0);

    const auto offered = WriteGeneralScene(root_ / "offered",
                                           R"({"cameraparallax":true,"cameraparallaxmouseinfluence":0.5})");
    EXPECT_NE(owe_read_scene_traits(offered.c_str(), nullptr), 0);
    ASSERT_EQ(owe_read_scene_traits(offered.c_str(), &traits), 0) << owe_last_error();
    EXPECT_TRUE(traits.camera_parallax_offered);

    // A user-bound setting is read by its authored value, as WE's sub_14010D850 does.
    const auto bound = WriteGeneralScene(
        root_ / "bound",
        R"({"cameraparallax":{"user":"parallax","value":true},"cameraparallaxmouseinfluence":{"value":1}})");
    ASSERT_EQ(owe_read_scene_traits(bound.c_str(), &traits), 0) << owe_last_error();
    EXPECT_TRUE(traits.camera_parallax_offered);

    for (const char* general : { R"({"cameraparallax":true,"cameraparallaxmouseinfluence":0})",
                                 R"({"cameraparallax":false,"cameraparallaxmouseinfluence":1})",
                                 R"({"cameraparallax":1,"cameraparallaxmouseinfluence":1})",
                                 R"({"cameraparallax":true})", R"({})" }) {
        SCOPED_TRACE(general);
        const auto project = WriteGeneralScene(root_ / "not-offered", general);
        traits.camera_parallax_offered = true;
        ASSERT_EQ(owe_read_scene_traits(project.c_str(), &traits), 0) << owe_last_error();
        EXPECT_FALSE(traits.camera_parallax_offered);
    }

    WriteText(root_ / "video/project.json", R"({"title":"Clip","type":"video","file":"clip.mp4"})");
    EXPECT_NE(owe_read_scene_traits((root_ / "video/project.json").c_str(), &traits), 0)
        << "a project that is not a scene has no scene traits";
}

TEST_F(SceneUserOptionsBinding, AVolumeLutDecodesToItsCubeRedFastest)
{
    constexpr int32_t edge = 2;
    std::string       voxels;
    for (int z = 0; z < edge; ++z) {
        for (int y = 0; y < edge; ++y) {
            for (int x = 0; x < edge; ++x) {
                voxels.push_back(static_cast<char>(x * 255));
                voxels.push_back(static_cast<char>(y * 255));
                voxels.push_back(static_cast<char>(z * 255));
                voxels.push_back(static_cast<char>(255));
            }
        }
    }
    const auto lut = root_ / "materials/lut/tiny.tex";
    WriteVolumeTex(lut, edge, voxels);

    uint32_t size = 0;
    ASSERT_EQ(owe_lut_load_rgba8(lut.c_str(), &size, nullptr, 0), 0) << owe_last_error();
    EXPECT_EQ(size, 2u);
    std::vector<uint8_t> small(size * size * size * 4 - 1);
    EXPECT_NE(owe_lut_load_rgba8(lut.c_str(), &size, small.data(), small.size()), 0);
    std::vector<uint8_t> rgba(size * size * size * 4);
    ASSERT_EQ(owe_lut_load_rgba8(lut.c_str(), &size, rgba.data(), rgba.size()), 0) << owe_last_error();
    EXPECT_EQ(std::string(rgba.begin(), rgba.end()), voxels);

    // Voxel (r=1, g=0, b=1) is at x + y*edge + z*edge*edge.
    const size_t at = (1 + 0 * edge + 1 * edge * edge) * 4;
    EXPECT_EQ(rgba[at + 0], 255);
    EXPECT_EQ(rgba[at + 1], 0);
    EXPECT_EQ(rgba[at + 2], 255);

    EXPECT_NE(owe_lut_load_rgba8((root_ / "materials/lut/missing.tex").c_str(), &size, nullptr, 0), 0);
    EXPECT_NE(owe_lut_load_rgba8(nullptr, &size, nullptr, 0), 0);
    EXPECT_NE(owe_lut_load_rgba8(lut.c_str(), nullptr, nullptr, 0), 0);
}

TEST_F(SceneQualityBinding, MultisamplingInForceIsTheCountTheDeviceActuallyDraws)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) GTEST_SKIP() << "no Metal device";
    int expected = 0;
    for (const int count : { 8, 4, 2 }) {
        if ([device supportsTextureSampleCount:count]) { expected = count; break; }
    }
    const auto root = root_ / "msaa-quality";
    const auto project = WriteCardScene(root);
    mdltest::MeshSpec mesh;
    mesh.material = "materials/card.json";
    mesh.flag = mdltest::kPosition;
    mesh.vertices = 3;
    mesh.indices = { 0, 1, 2 };
    const auto bytes = mdltest::mdlFile(23, { mesh });
    std::ofstream model(root / "models/model.mdl", std::ios::binary);
    model.write(reinterpret_cast<const char*>(bytes.data().data()), bytes.size());
    model.close();
    auto document = nlohmann::json::parse(std::ifstream(root / "layout.json"));
    document["general"]["bloom"] = false;
    document["objects"].push_back({ { "id", 2 }, { "name", "model" }, { "model", "models/model.mdl" },
        { "origin", { 192, 128, 10 } }, { "scale", { 1, 1, 1 } }, { "angles", { 0, 0, 0 } },
        { "visible", true } });
    WriteText(root / "layout.json", document.dump());
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    SceneQuality asked;
    asked.msaa = 8;
    loading.wallpaper().setSceneQuality(asked);
    loading.wallpaper().applyConfig(loading.Config(project, root_ / "run"));
    ASSERT_TRUE(loading.WaitForFirstFrame());
    ASSERT_TRUE(WaitFor([&] { const auto q=loading.wallpaper().qualityInForce(); return q && q->msaa==expected; }));
    asked.msaa = 0;
    loading.wallpaper().setSceneQuality(asked);
    EXPECT_TRUE(WaitFor([&] { const auto q=loading.wallpaper().qualityInForce(); return q && q->msaa==0; }));
}
