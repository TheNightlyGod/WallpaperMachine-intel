// What a scene's sound does while the scene loads.
//
// A scene's sounds are mounted on its output as the scene is parsed, and the
// output starts as soon as one is mounted, playing and not muted. So the sound a
// wallpaper is meant to have must be in force before the load, or the first part
// of its music plays before the host's choice arrives. The load runs at once when
// the surface was taken before the configuration, which is the order these tests
// force: they wait for the hand-over first.
//
// Driven end to end through `SceneWallpaper` on a `CAMetalLayer` no window owns,
// with the output on miniaudio's null backend: no audio device is opened and
// nothing is heard. The evidence is how many times the output started.

#include "Scene/SceneWallpaper.hpp"
#include "Scene/SceneWallpaperSurface.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <gtest/gtest.h>

#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace wallpaper;
using namespace std::chrono_literals;

namespace
{

void WriteText(const std::filesystem::path& path, const std::string& text)
{
    std::filesystem::create_directories(path.parent_path());
    std::ofstream(path) << text;
}

/// Half a second of a 440 Hz tone as 16-bit stereo PCM WAV.
void WriteTone(const std::filesystem::path& path)
{
    constexpr uint32_t rate     = 48'000;
    constexpr uint32_t frames   = rate / 2;
    constexpr uint16_t channels = 2;
    std::vector<int16_t> samples;
    samples.reserve(frames * channels);
    for (uint32_t i = 0; i < frames; ++i) {
        const auto value = static_cast<int16_t>(8'000 * std::sin(2.0 * M_PI * 440.0 * i / rate));
        samples.push_back(value);
        samples.push_back(value);
    }
    const uint32_t data_bytes = static_cast<uint32_t>(samples.size() * sizeof(int16_t));
    std::filesystem::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary);
    const auto    u32 = [&](uint32_t value) { out.write(reinterpret_cast<const char*>(&value), 4); };
    const auto    u16 = [&](uint16_t value) { out.write(reinterpret_cast<const char*>(&value), 2); };
    out.write("RIFF", 4);
    u32(36 + data_bytes);
    out.write("WAVEfmt ", 8);
    u32(16);
    u16(1);
    u16(channels);
    u32(rate);
    u32(rate * channels * 2);
    u16(channels * 2);
    u16(16);
    out.write("data", 4);
    u32(data_bytes);
    out.write(reinterpret_cast<const char*>(samples.data()), data_bytes);
}

/// One opaque card and one looping sound, the music of a typical wallpaper.
std::filesystem::path WriteSceneWithMusic(const std::filesystem::path& root)
{
    WriteText(root / "project.json",
              R"({"title":"Music","type":"scene","file":"layout.json","general":{"properties":{}}})");
    WriteTone(root / "sounds/music.wav");
    WriteText(root / "models/card.json",
              R"({"width":160,"height":96,"material":"materials/card.json"})");
    WriteText(root / "materials/card.json",
              R"({"passes":[{"shader":"card","blending":"translucent","cullmode":"nocull",)"
              R"("depthtest":"disabled","depthwrite":"disabled"}]})");
    WriteText(root / "shaders/card.vert",
              "uniform mat4 g_ModelViewProjectionMatrix;\n"
              "attribute vec3 a_Position;\n"
              "attribute vec2 a_TexCoord;\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
              "v_TexCoord = a_TexCoord;\n"
              "}\n");
    WriteText(root / "shaders/card.frag",
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_FragColor = vec4(v_TexCoord, 0.4, 1.0);\n"
              "}\n");
    WriteText(root / "layout.json",
              R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
              R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],)"
              R"("clearcolor":[0.1,0.2,0.3],"cameraparallax":false,)"
              R"("orthogonalprojection":{"width":384,"height":256}},)"
              R"("objects":[{"id":1,"name":"card","image":"models/card.json",)"
              R"("origin":[192,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},)"
              R"({"id":2,"name":"music","sound":["sounds/music.wav"],"playbackmode":"loop",)"
              R"("volume":1.0}]})");
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
    uint64_t        OutputStarts() { return SceneWallpaperInputTestAccess::SoundOutputStarts(m_wallpaper); }

private:
    static constexpr uint16_t kWidth  = 640;
    static constexpr uint16_t kHeight = 360;

    CAMetalLayer*           m_layer { nil };
    SceneWallpaper          m_wallpaper;
    std::mutex              m_mutex;
    std::condition_variable m_changed;
    int                     m_first_frames { 0 };
};

class SceneLoadSound : public ::testing::Test {
protected:
    void SetUp() override
    {
        if (MTLCreateSystemDefaultDevice() == nil) {
            GTEST_SKIP() << "no Metal device on this machine; no surface could be created";
        }
        static int serial = 0;
        root_             = std::filesystem::temp_directory_path() /
                ("owe-load-sound-" + std::to_string(::getpid()) + "-" + std::to_string(serial++));
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

// The fixture's music is real: a wallpaper nobody muted starts its output once,
// when the scene loads. Without this, a muted run that never starts proves nothing.
TEST_F(SceneLoadSound, AWallpaperWithSoundStartsItsOutputWhenItLoads)
{
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    loading.wallpaper().applyConfig(loading.Config(WriteSceneWithMusic(root_ / "scene"), root_ / "run"));
    ASSERT_TRUE(loading.WaitForFirstFrame());

    EXPECT_EQ(loading.OutputStarts(), 1u);
}

// A wallpaper the user muted (or every wallpaper muted, or a rule muting them)
// switches in silently: its music never starts, not even for the moment it takes
// to load.
TEST_F(SceneLoadSound, AMutedWallpaperNeverStartsItsOutputWhileItLoads)
{
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    auto config   = loading.Config(WriteSceneWithMusic(root_ / "scene"), root_ / "run");
    config.volume = 0.5f;
    config.muted  = true;
    loading.wallpaper().applyConfig(config);
    ASSERT_TRUE(loading.WaitForFirstFrame());

    EXPECT_EQ(loading.OutputStarts(), 0u) << "the music played before the mute arrived";
}

// A wallpaper that arrives paused is silent too, and still shows its first
// picture: the host waits for it before it lets the previous wallpaper go.
TEST_F(SceneLoadSound, AWallpaperThatArrivesPausedDrawsItsFirstFrameSilently)
{
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    auto config   = loading.Config(WriteSceneWithMusic(root_ / "scene"), root_ / "run");
    config.paused = true;
    loading.wallpaper().applyConfig(config);
    ASSERT_TRUE(loading.WaitForFirstFrame()) << "the host would have waited for ever";

    EXPECT_EQ(loading.OutputStarts(), 0u);
}

// Unmuting it later starts the music then, once.
TEST_F(SceneLoadSound, AWallpaperThatLoadedMutedStartsItsOutputWhenUnmuted)
{
    Loading loading;
    ASSERT_TRUE(loading.WaitForSurface());
    auto config  = loading.Config(WriteSceneWithMusic(root_ / "scene"), root_ / "run");
    config.muted = true;
    loading.wallpaper().applyConfig(config);
    ASSERT_TRUE(loading.WaitForFirstFrame());
    ASSERT_EQ(loading.OutputStarts(), 0u);

    loading.wallpaper().setPropertyBool(PROPERTY_MUTED, false);
    const auto deadline = std::chrono::steady_clock::now() + 10s;
    while (loading.OutputStarts() == 0 && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(1ms);
    }
    EXPECT_EQ(loading.OutputStarts(), 1u);
}
