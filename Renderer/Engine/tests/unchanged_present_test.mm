// Native Metal leaves out a frame that would put back exactly the picture
// already on the surface: no drawable and no present.
//
// Driven end to end through `SceneWallpaper` -- the real frame clock, draw
// handler and drawable loop -- on a `CAMetalLayer` that is never attached to a
// window, so no desktop is involved. The renderer counters are the evidence:
// draws executed against presents requested and presents skipped show which
// frames reached the surface. (A plain video is never drawn by the engine, so
// no video wallpaper appears here.)

#include "Core/RendererCounters.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "Scene/SceneResolution.hpp"
#include "Scene/SceneWallpaper.hpp"
#include "Scene/SceneWallpaperSurface.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

#include <gtest/gtest.h>

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include <libproc.h>
#include <mach/mach.h>
#include <sys/resource.h>

// Private libsystem exports, read the way `scripts/power_benchmark.py` and the
// app's energy readout read them: 45 uint64 fields, GPU time at 8, CPU energy
// at 11, GPU energy at 41.
extern "C" int coalition_info_resource_usage(uint64_t coalition_id, void* buffer, size_t size);
extern "C" int proc_listcoalitions(int flavor, int coalition_type, void* buffer, int size);

using namespace wallpaper;
using namespace std::chrono_literals;

namespace
{

using Counters = std::array<uint64_t, OWE_RC_COUNT>;

Counters Delta(const Counters& before, const Counters& after)
{
    Counters delta {};
    for (std::size_t i = 0; i < delta.size(); ++i) delta[i] = after[i] - before[i];
    return delta;
}

/// Counters are read while the render thread runs, so one draw can straddle
/// the edge of a window: counted as executed on one side and as submitted or
/// skipped on the other. Anything more than that one draw is a real mismatch.
void ExpectWithinOneDraw(uint64_t lhs, uint64_t rhs, const char* what)
{
    const uint64_t difference = lhs > rhs ? lhs - rhs : rhs - lhs;
    EXPECT_LE(difference, 1u) << what << ": " << lhs << " vs " << rhs;
}

/// Health and the counters are separate atomics read one after the other while
/// the render thread runs, so a draw can straddle either edge of the window:
/// one draw at the start and one at the end, and no more than that.
void ExpectWithinTwoDraws(uint64_t lhs, uint64_t rhs, const char* what)
{
    const uint64_t difference = lhs > rhs ? lhs - rhs : rhs - lhs;
    EXPECT_LE(difference, 2u) << what << ": " << lhs << " vs " << rhs;
}

void Print(const char* label, const Counters& c)
{
    std::cout << label << " draws_executed=" << c[OWE_RC_DRAWS_EXECUTED]
              << " render_submissions=" << c[OWE_RC_RENDER_SUBMISSIONS]
              << " present_requests=" << c[OWE_RC_PRESENT_REQUESTS]
              << " presents_skipped_unchanged=" << c[OWE_RC_PRESENTS_SKIPPED_UNCHANGED]
              << " render_failures=" << c[OWE_RC_RENDER_FAILURES]
              << " video_frames_selected=" << c[OWE_RC_VIDEO_FRAMES_SELECTED]
              << " video_frames_reused=" << c[OWE_RC_VIDEO_FRAMES_REUSED]
              << " video_frames_skipped=" << c[OWE_RC_VIDEO_FRAMES_SKIPPED] << std::endl;
}

/// Stands in for the host's poster mailbox: one request at a time, taken by
/// the frame that exports it, and asked about without taking it.
struct PosterProbe
{
    std::mutex              mutex;
    std::condition_variable changed;
    bool                    requested { false };
    int                     delivered { 0 };
    std::vector<uint8_t>    pixels;
    /// What the renderer bound for the host to poke it with. A renderer that
    /// can only answer from inside a frame never needs it; the native one
    /// answers an idle wallpaper's request from the request itself.
    std::function<void()>   wake;

    /// Asks for a poster. `wake_renderer` also pokes the renderer the way the
    /// host's mailbox does, which a request that wants an answer from a scene
    /// that is not drawing has to do; without it the request waits for a frame.
    void Request(bool wake_renderer = false)
    {
        std::function<void()> poke;
        {
            std::scoped_lock lock(mutex);
            requested = true;
            if (wake_renderer) poke = wake;
        }
        if (poke) poke();
    }
    bool WaitDelivered(int count)
    {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, 5s, [&] { return delivered >= count; });
    }
};

/// Stands in for the host's render-failure relay: counts the reports and lets a
/// test wait for the next one.
struct FailureProbe
{
    std::mutex              mutex;
    std::condition_variable changed;
    int                     reports { 0 };

    std::shared_ptr<RenderFailureCallback> Callback()
    {
        return std::make_shared<RenderFailureCallback>([this] {
            std::scoped_lock lock(mutex);
            ++reports;
            changed.notify_all();
        });
    }
    bool WaitForReports(int count)
    {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, 5s, [&] { return reports >= count; });
    }
    int Reports()
    {
        std::scoped_lock lock(mutex);
        return reports;
    }
};

void WriteText(const std::filesystem::path& path, const std::string& text)
{
    std::filesystem::create_directories(path.parent_path());
    std::ofstream(path) << text;
}

/// One opaque card drawn through its own shaders, with nothing that varies
/// over time: from its second frame every pass is reusable.
std::filesystem::path WriteStaticScene(const std::filesystem::path& root)
{
    WriteText(root / "project.json",
              R"({"title":"Static card","type":"scene","file":"layout.json",)"
              R"("general":{"properties":{}}})");
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
              R"("origin":[192,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}]})");
    return root / "project.json";
}

/// The static card with a slider on its alpha, which its shader reads. Still, so
/// every pass is reusable from the second frame; only the slider moves it.
std::filesystem::path WriteSliderScene(const std::filesystem::path& root)
{
    const auto project = WriteStaticScene(root);
    WriteText(project,
              R"({"title":"Slider card","type":"scene","file":"layout.json","general":)"
              R"({"properties":{"opacity":{"type":"slider","value":1.0}}}})");
    WriteText(root / "shaders/card.frag",
              "uniform float g_UserAlpha; // {\"material\":\"alpha\",\"default\":1.0}\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_FragColor = vec4(v_TexCoord, 0.4, g_UserAlpha);\n"
              "}\n");
    WriteText(root / "layout.json",
              R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
              R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],)"
              R"("clearcolor":[0.1,0.2,0.3],"cameraparallax":false,)"
              R"("orthogonalprojection":{"width":384,"height":256}},)"
              R"("objects":[{"id":1,"name":"card","image":"models/card.json",)"
              R"("origin":[192,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,)"
              R"("alpha":{"user":"opacity","value":1.0}}]})");
    return project;
}

/// The static card grown to the whole 384 x 256 canvas, in a colour that spells
/// out the raster it was drawn into: the shader reads the texel size the
/// renderer reports, which is the raster's. Canvas-sized, the texel size times
/// the canvas is exactly 1 on both axes.
std::filesystem::path WriteRasterProbeScene(const std::filesystem::path& root)
{
    const auto project = WriteStaticScene(root);
    WriteText(root / "models/card.json",
              R"({"width":384,"height":256,"material":"materials/card.json"})");
    WriteText(root / "shaders/card.frag",
              "uniform vec2 g_TexelSize;\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_FragColor = vec4(g_TexelSize.x * 384.0, g_TexelSize.y * 256.0, 0.0, 1.0);\n"
              "}\n");
    return project;
}

/// The static card grown to fill a 338 x 200 canvas in one flat colour, over a
/// clear colour of its own. The canvas is about 1.69:1, between 16:10 and 16:9,
/// so Fill crops it on a 16:10 surface and Fit leaves bars above and below.
std::filesystem::path WriteFullCanvasScene(const std::filesystem::path& root)
{
    const auto project = WriteStaticScene(root);
    WriteText(root / "models/card.json",
              R"({"width":338,"height":200,"material":"materials/card.json"})");
    WriteText(root / "shaders/card.frag",
              "void main() {\n"
              "gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0);\n"
              "}\n");
    WriteText(root / "layout.json",
              R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
              R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],)"
              R"("clearcolor":[0,0,1],"cameraparallax":false,)"
              R"("orthogonalprojection":{"width":338,"height":200}},)"
              R"("objects":[{"id":1,"name":"card","image":"models/card.json",)"
              R"("origin":[169,100,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}]})");
    return project;
}

/// The static card beside an echo card that shows the scene's previous frame
/// through `_rt_MipMappedFrameBuffer`. The graph fills that buffer from the
/// frame's output only after the echo has drawn, so every frame hands its
/// picture to the next: a history loop, with no shader reading the time.
std::filesystem::path WriteHistoryScene(const std::filesystem::path& root)
{
    const auto project = WriteStaticScene(root);
    WriteText(root / "models/echo.json",
              R"({"width":192,"height":128,"material":"materials/echo.json"})");
    WriteText(root / "materials/echo.json",
              R"({"passes":[{"shader":"echo","blending":"translucent","cullmode":"nocull",)"
              R"("depthtest":"disabled","depthwrite":"disabled",)"
              R"("textures":["_rt_MipMappedFrameBuffer"]}]})");
    WriteText(root / "shaders/echo.vert",
              "uniform mat4 g_ModelViewProjectionMatrix;\n"
              "attribute vec3 a_Position;\n"
              "attribute vec2 a_TexCoord;\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
              "v_TexCoord = a_TexCoord;\n"
              "}\n");
    WriteText(root / "shaders/echo.frag",
              "uniform sampler2D g_Texture0;\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_FragColor = vec4(texture(g_Texture0, v_TexCoord).rgb, 1.0);\n"
              "}\n");
    WriteText(root / "layout.json",
              R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
              R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],)"
              R"("clearcolor":[0.1,0.2,0.3],"cameraparallax":false,)"
              R"("orthogonalprojection":{"width":384,"height":256}},)"
              R"("objects":[{"id":1,"name":"card","image":"models/card.json",)"
              R"("origin":[96,176,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},)"
              R"({"id":2,"name":"echo","image":"models/echo.json",)"
              R"("origin":[288,80,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}]})");
    return project;
}

/// A running wallpaper on a layer no window owns.
class RunningWallpaper {
public:
    RunningWallpaper(const std::filesystem::path& project, const std::filesystem::path& scratch,
                     uint16_t width = kWidth, uint16_t height = kHeight, double scale = 1.0)
    {
        m_layer                 = [CAMetalLayer layer];
        m_layer.device          = MTLCreateSystemDefaultDevice();
        m_layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        m_layer.contentsScale   = scale;
        m_layer.frame           = CGRectMake(0, 0, width / scale, height / scale);
        m_layer.drawableSize    = CGSizeMake(width, height);

        EXPECT_TRUE(m_wallpaper.init());
        m_wallpaper.setPropertyObject(PROPERTY_FIRST_FRAME_CALLBACK,
                                      std::make_shared<FirstFrameCallback>([this] {
                                          std::scoped_lock lock(m_mutex);
                                          m_first_frame = true;
                                          m_changed.notify_all();
                                      }));
        m_wallpaper.initSurface(MakeSurface(width, height, scale));

        std::filesystem::create_directories(scratch / "assets");
        SceneWallpaperConfig config;
        config.source     = project.string();
        config.assets     = (scratch / "assets").string();
        config.cache_path = (scratch / "cache").string();
        config.fps        = 60;
        config.paused     = false;
        m_wallpaper.applyConfig(config);
    }

    ~RunningWallpaper() { m_wallpaper.shutdown(); }

    bool WaitForFirstFrame()
    {
        std::unique_lock lock(m_mutex);
        return m_changed.wait_for(lock, 30s, [&] { return m_first_frame; });
    }

    Counters Read() const
    {
        Counters values {};
        m_wallpaper.counters(values.data(), values.size());
        return values;
    }

    SceneWallpaper& wallpaper() { return m_wallpaper; }
    PosterProbe&    poster() { return *m_poster; }

    bool FirstFrameSeen()
    {
        std::scoped_lock lock(m_mutex);
        return m_first_frame;
    }

    /// Rebuilds the surface and swapchain at a new size, the way the host
    /// does when the display it covers changes resolution.
    bool Resize(uint16_t width, uint16_t height, double scale = 1.0)
    {
        if (! m_wallpaper.beginSurfaceReconfigure()) return false;
        m_layer.contentsScale = scale;
        m_layer.frame         = CGRectMake(0, 0, width / scale, height / scale);
        m_layer.drawableSize  = CGSizeMake(width, height);
        return m_wallpaper.finishSurfaceReconfigure(MakeSurface(width, height, scale));
    }

private:
    static constexpr uint16_t kWidth  = 1280;
    static constexpr uint16_t kHeight = 720;

    RenderInitInfo MakeSurface(uint16_t width = kWidth, uint16_t height = kHeight,
                               double scale = 1.0)
    {
        RenderInitInfo info;
        info.metal_layer      = (__bridge void*)m_layer;
        info.width            = width;
        info.height           = height;
        info.render_width     = width;
        info.render_height    = height;
        info.display_scale_factor = scale;
        auto poster       = m_poster;
        info.bind_poster_wake = [poster](std::function<void()> wake) {
            std::scoped_lock lock(poster->mutex);
            poster->wake = std::move(wake);
        };
        info.wants_poster = [poster] {
            std::scoped_lock lock(poster->mutex);
            const bool wanted = poster->requested;
            poster->requested = false;
            return wanted;
        };
        info.poster_ready = [poster](std::span<const uint8_t> pixels, uint32_t, uint32_t, bool) {
            std::scoped_lock lock(poster->mutex);
            poster->pixels.assign(pixels.begin(), pixels.end());
            ++poster->delivered;
            poster->changed.notify_all();
        };
        return info;
    }

    CAMetalLayer*                m_layer { nil };
    std::shared_ptr<PosterProbe> m_poster { std::make_shared<PosterProbe>() };
    SceneWallpaper               m_wallpaper;
    std::mutex                   m_mutex;
    std::condition_variable      m_changed;
    bool                         m_first_frame { false };
};

class UnchangedPresent : public ::testing::Test {
protected:
    void SetUp() override
    {
        if (MTLCreateSystemDefaultDevice() == nil) {
            GTEST_SKIP() << "no Metal device on this machine; no swapchain could be created";
        }
        static int serial = 0;
        root_ = std::filesystem::temp_directory_path() /
                ("owe-unchanged-present-" + std::to_string(::getpid()) + "-" +
                 std::to_string(serial++));
        std::filesystem::remove_all(root_);
        std::filesystem::create_directories(root_);
        RendererCounters::SetEnabled(true);
    }

    void TearDown() override
    {
        render::SetSceneOptimizationEnabled(true);
        SetSceneOnDemandEnabled(false);
        RendererCounters::SetEnabled(false);
        std::error_code ignored;
        std::filesystem::remove_all(root_, ignored);
    }

    std::filesystem::path root_;
};

} // namespace

TEST_F(UnchangedPresent, PinnedTargetAccountingReturnsToBaselineWhenScenesClose)
{
    render::SetSceneOptimizationEnabled(true);
    const auto baseline = render::CurrentSceneOptimizationTotals().pinned_bytes;
    const auto project = WriteStaticScene(root_ / "static");
    for (int load = 0; load < 2; ++load) {
        {
            RunningWallpaper running(project, root_ / ("load-" + std::to_string(load)));
            ASSERT_TRUE(running.WaitForFirstFrame());
            EXPECT_GT(render::CurrentSceneOptimizationTotals().pinned_bytes, baseline);
        }
        EXPECT_EQ(render::CurrentSceneOptimizationTotals().pinned_bytes, baseline);
    }
}

TEST_F(UnchangedPresent, AStaticSceneStopsPresentingOnceEveryPassIsReused)
{
    const auto project = WriteStaticScene(root_ / "scene");

    std::array<std::vector<uint8_t>, 2> pictures;
    for (const bool optimise : { false, true }) {
        render::SetSceneOptimizationEnabled(optimise);
        RunningWallpaper running(project, root_ / (optimise ? "on" : "off"));
        ASSERT_TRUE(running.WaitForFirstFrame()) << "the scene never reached the surface";
        std::this_thread::sleep_for(600ms);
        const auto before        = running.Read();
        const auto health_before = running.wallpaper().surfaceHealth();
        std::this_thread::sleep_for(1000ms);
        const auto after        = running.Read();
        const auto health_after = running.wallpaper().surfaceHealth();
        const auto delta        = Delta(before, after);
        Print(optimise ? "static scene, skip on: " : "static scene, baseline:", delta);
        ASSERT_GT(delta[OWE_RC_DRAWS_EXECUTED], 10u);
        EXPECT_EQ(delta[OWE_RC_RENDER_FAILURES], 0u);

        // The always-on health reading, with counting on here only because the
        // test reads the counters too. A skipped frame is a completed frame
        // that was not presented, so completion tracks the draws that ran
        // while presents may stand still; a liveness check built on presents
        // would call this healthy scene stalled.
        const uint64_t completed = health_after.frames_completed - health_before.frames_completed;
        const uint64_t presented = health_after.frames_presented - health_before.frames_presented;
        ExpectWithinTwoDraws(completed, delta[OWE_RC_DRAWS_EXECUTED],
                             "frames completed against draws executed");
        EXPECT_EQ(health_after.stop_reason, SurfaceStopReason::Running);
        EXPECT_EQ(health_after.failed_frames, 0u);
        if (optimise) {
            EXPECT_EQ(presented, 0u)
                << "frames that repeat the picture complete without presenting";
        } else {
            ExpectWithinTwoDraws(presented, delta[OWE_RC_DRAWS_EXECUTED],
                                 "baseline presents against draws executed");
        }
        if (optimise) {
            EXPECT_EQ(delta[OWE_RC_PRESENT_REQUESTS], 0u)
                << "a scene with every pass reused was still submitted";
            ExpectWithinOneDraw(delta[OWE_RC_PRESENTS_SKIPPED_UNCHANGED],
                                delta[OWE_RC_DRAWS_EXECUTED], "every reused tick skipped");
        } else {
            ExpectWithinOneDraw(delta[OWE_RC_PRESENT_REQUESTS], delta[OWE_RC_DRAWS_EXECUTED],
                                "baseline submissions against draws");
            EXPECT_EQ(delta[OWE_RC_PRESENTS_SKIPPED_UNCHANGED], 0u);
        }

        // The presented picture, read back through the poster path: with the
        // skip on it is the frame the reused passes produced.
        running.poster().Request(true);
        ASSERT_TRUE(running.poster().WaitDelivered(1));
        {
            std::scoped_lock lock(running.poster().mutex);
            pictures[optimise ? 1 : 0] = running.poster().pixels;
        }

        if (optimise) {
            // Scaling moves the picture while every pass stays reused.
            running.wallpaper().setPropertyInt32(PROPERTY_SCALINGMODE, 2);
            std::this_thread::sleep_for(400ms);
            const auto rescaled = Delta(after, running.Read());
            // The scaling change presents once; the poster is read back from the
            // last finished composition and presents nothing.
            EXPECT_EQ(rescaled[OWE_RC_PRESENT_REQUESTS], 1u);
        }
    }
    ASSERT_FALSE(pictures[0].empty());
    EXPECT_EQ(pictures[0], pictures[1])
        << "the picture presented with the skip on differs from the baseline";
}

// "Update only when the scene changes": a history loop keeps changing the
// picture with nothing else changing -- a trail keeps fading, an accumulation
// keeps converging -- so it must keep the clock running although no shader
// reads the time, with pixel reuse off and on. The same card without the loop
// is the control: it goes idle, so the loop is what keeps the clock.
TEST_F(UnchangedPresent, AHistoryLoopKeepsTheClockRunningWithoutATimeUniform)
{
    SetSceneOnDemandEnabled(true);
    struct Case
    {
        const char* name;
        bool        history;
        bool        optimise;
    };
    for (const auto& run : { Case { "still card", false, true },
                             Case { "history loop, reuse off", true, false },
                             Case { "history loop, reuse on", true, true } }) {
        SCOPED_TRACE(run.name);
        render::SetSceneOptimizationEnabled(run.optimise);
        const auto scene = root_ / (std::string(run.name) + " scene");
        const auto project = run.history ? WriteHistoryScene(scene) : WriteStaticScene(scene);
        RunningWallpaper running(project, root_ / (std::string(run.name) + " run"));
        ASSERT_TRUE(running.WaitForFirstFrame()) << "the scene never reached the surface";
        ASSERT_FALSE(running.wallpaper().sceneBackendSelection().failed())
            << running.wallpaper().sceneBackendSelection().failure_reason;
        std::this_thread::sleep_for(600ms);

        const uint32_t reasons = running.wallpaper().sceneDemandReasons();
        const auto     before  = running.Read();
        std::this_thread::sleep_for(500ms);
        const auto delta = Delta(before, running.Read());
        Print(run.name, delta);
        EXPECT_FALSE(reasons & SceneDemandReason::TimeUniform)
            << "the fixture reads the time, so it cannot show what the loop does";
        EXPECT_EQ(delta[OWE_RC_RENDER_FAILURES], 0u);
        if (run.history) {
            EXPECT_TRUE(reasons & SceneDemandReason::Feedback) << "reasons " << reasons;
            EXPECT_EQ(running.wallpaper().sceneUpdateKind(), SceneUpdateDemand::Kind::Continuous);
            EXPECT_GT(delta[OWE_RC_DRAWS_EXECUTED], 10u) << "the clock stopped on a history loop";
        } else {
            EXPECT_EQ(reasons, 0u);
            EXPECT_EQ(running.wallpaper().sceneUpdateKind(),
                      SceneUpdateDemand::Kind::WaitingForEvent);
            EXPECT_LE(delta[OWE_RC_DRAWS_EXECUTED], 1u) << "the still card kept the clock";
        }
    }
}

// The 2D scene resolution is a process-wide choice with no message of its own:
// the host sets it and re-sends the render scale every open scene already has,
// and a running scene resizes its targets in place, with nothing reloaded. The scene's own shader reports the raster it was drawn
// into, so the poster says what was rasterized rather than what was asked for.
TEST_F(UnchangedPresent, ARunningSceneTakesTheResolutionTheHostChooses)
{
    struct Restore
    {
        ~Restore() { SetSceneResolution(SceneResolution::Canvas); }
    } restore;
    const auto project = WriteRasterProbeScene(root_ / "probe");

    {
        SetSceneResolution(SceneResolution::Canvas);
        RunningWallpaper running(project, root_ / "run");
        ASSERT_TRUE(running.WaitForFirstFrame());
        ASSERT_FALSE(running.wallpaper().sceneBackendSelection().failed())
            << running.wallpaper().sceneBackendSelection().failure_reason;

        // The colour at the middle of the 1280 x 720 poster.
        int delivered = 0;
        const auto centre = [&]() -> int {
            running.poster().Request(true);
            if (! running.poster().WaitDelivered(++delivered)) return -1;
            std::scoped_lock lock(running.poster().mutex);
            const auto&      pixels = running.poster().pixels;
            if (pixels.size() != 1280u * 720u * 4u) return -2;
            const auto* middle = pixels.data() + (360u * 1280u + 640u) * 4u;
            // Blue is 0 in either byte order, red and green are equal.
            return std::max({ int(middle[0]), int(middle[1]), int(middle[2]) });
        };
        // The host's push: the choice, then the render scale it already had.
        const auto choose = [&](SceneResolution resolution, float scale, int expected) {
            SetSceneResolution(resolution);
            running.wallpaper().setPropertyFloat(PROPERTY_RENDER_SCALE, scale);
            int seen = -1;
            for (int attempt = 0; attempt < 40; ++attempt) {
                std::this_thread::sleep_for(100ms);
                seen = centre();
                if (std::abs(seen - expected) <= 2) break;
            }
            return seen;
        };

        EXPECT_EQ(centre(), 255) << "a scene starts at the canvas it was authored at";
        // 1280 x 720 filled with a 384 x 256 canvas is 1280 x 853 pixels, and the
        // texel size times the canvas is then 0.3 on both axes.
        EXPECT_NEAR(choose(SceneResolution::Display, 1.0f, 76), 76, 2);
        // The render scale divides the display raster: 640 x 427, and 0.6.
        EXPECT_NEAR(choose(SceneResolution::Display, 0.5f, 153), 153, 2);
        EXPECT_NEAR(choose(SceneResolution::Canvas, 0.5f, 255), 255, 2)
            << "the canvas at half scale is 192 x 128, which saturates";
        EXPECT_NEAR(choose(SceneResolution::Canvas, 1.0f, 255), 255, 2);
        EXPECT_EQ(running.wallpaper().surfaceHealth().failed_frames, 0u);
    }
}

// A property edit shown on the running scene, with nothing reloaded, reaches the
// surface through the ordinary frame loop: a still scene whose passes are all
// reused presents the new picture once and goes back to repeating, and a scene
// the on-demand clock has stopped is woken for exactly the frame it needs and goes
// back to sleep.
TEST_F(UnchangedPresent, APropertyPreviewShowsOnAStillSceneAndWakesAnIdleOneForOneFrame)
{
    struct RestoreOnDemand
    {
        bool was { SceneOnDemandEnabled() };
        ~RestoreOnDemand() { SetSceneOnDemandEnabled(was); }
    } restore;
    const auto project = WriteSliderScene(root_ / "slider");
    render::SetSceneOptimizationEnabled(true);

    for (const bool on_demand : { false, true }) {
        SCOPED_TRACE(on_demand ? "on-demand clock" : "fixed cadence");
        SetSceneOnDemandEnabled(on_demand);
        RunningWallpaper running(project, root_ / (on_demand ? "on-demand" : "fixed"));
        ASSERT_TRUE(running.WaitForFirstFrame()) << "the scene never reached the surface";
        std::this_thread::sleep_for(600ms);

        // A poster is answered by a frame, which a stopped clock does not draw
        // for a request nobody wakes it for; the picture is read back only while
        // the clock runs, and the stopped one is judged by what it presented.
        std::vector<uint8_t> before;
        if (! on_demand) {
            running.poster().Request(true);
            ASSERT_TRUE(running.poster().WaitDelivered(1));
            std::scoped_lock lock(running.poster().mutex);
            before = running.poster().pixels;
        }
        std::this_thread::sleep_for(300ms);
        const auto still = running.Read();

        running.wallpaper().setPropertyString(PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON,
                                              R"({"opacity":0.5})");
        std::this_thread::sleep_for(400ms);
        const auto previewed = running.Read();
        EXPECT_EQ(Delta(still, previewed)[OWE_RC_PRESENT_REQUESTS], 1u)
            << "a previewed slider must present exactly once and then repeat again";
        if (on_demand) {
            EXPECT_EQ(Delta(still, previewed)[OWE_RC_DRAWS_EXECUTED], 1u)
                << "a preview must wake an idle scene for one frame";
        }

        std::this_thread::sleep_for(400ms);
        const auto settled = running.Read();
        EXPECT_EQ(Delta(previewed, settled)[OWE_RC_PRESENT_REQUESTS], 0u)
            << "the scene did not go back to repeating";
        if (on_demand) {
            EXPECT_EQ(Delta(previewed, settled)[OWE_RC_DRAWS_EXECUTED], 0u)
                << "the scene did not go back to sleep";
        }

        if (! on_demand) {
            running.poster().Request(true);
            ASSERT_TRUE(running.poster().WaitDelivered(2));
            std::scoped_lock lock(running.poster().mutex);
            ASSERT_FALSE(before.empty());
            EXPECT_NE(before, running.poster().pixels)
                << "the previewed slider changed nothing that was presented";
        }
    }
}

// A surface that has been drawing and then fails a frame stops, says so, and
// tells the host once; the host heals it by rebuilding the surface. The failure
// itself is injected, because a real presentation failure cannot be produced
// without breaking the GPU, but everything after it is the production routine:
// the same latch, the same stopped clock, the same callback and the same
// surface reconfigure the host runs.
TEST_F(UnchangedPresent, ADrawFailureAfterTheFirstFrameIsReportedOnceAndASurfaceRebuildHealsIt)
{
    const auto project = WriteStaticScene(root_ / "scene");
    // Declared first, so it outlives the renderer whose callback points at it.
    FailureProbe probe;
    RunningWallpaper running(project, root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());
    running.wallpaper().setPropertyObject(PROPERTY_RENDER_FAILURE_CALLBACK, probe.Callback());
    std::this_thread::sleep_for(300ms);
    ASSERT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
    EXPECT_EQ(probe.Reports(), 0) << "installing the callback must not replay anything";

    SceneWallpaperInputTestAccess::InjectFrameFailure(running.wallpaper());
    ASSERT_TRUE(probe.WaitForReports(1)) << "the host was never told the scene stopped";

    // Stopped, and saying why.
    const auto stopped = running.wallpaper().surfaceHealth();
    EXPECT_EQ(stopped.stop_reason, SurfaceStopReason::FrameFailed);
    EXPECT_EQ(stopped.failed_frames, 1u);
    // The clock is stopped: nothing completes after the report, and the report
    // is not repeated for a surface that is already down.
    std::this_thread::sleep_for(400ms);
    const auto later = running.wallpaper().surfaceHealth();
    EXPECT_EQ(later.frames_completed, stopped.frames_completed)
        << "a stopped surface kept drawing";
    EXPECT_EQ(probe.Reports(), 1);

    // Rebuilding the surface, as the host does, ends the stop and restarts the
    // clock. The count of failed frames is history and stays.
    ASSERT_TRUE(running.Resize(1280, 720));
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::Running);
    std::this_thread::sleep_for(500ms);
    const auto healed = running.wallpaper().surfaceHealth();
    EXPECT_GT(healed.frames_completed, later.frames_completed + 5)
        << "the rebuilt surface never started drawing again";
    EXPECT_EQ(healed.stop_reason, SurfaceStopReason::Running);
    EXPECT_EQ(healed.failed_frames, 1u);
    EXPECT_EQ(probe.Reports(), 1) << "a healthy surface reported a failure";

    // The report re-arms with the surface: the next failure is a new report.
    SceneWallpaperInputTestAccess::InjectFrameFailure(running.wallpaper());
    ASSERT_TRUE(probe.WaitForReports(2));
    EXPECT_EQ(running.wallpaper().surfaceHealth().stop_reason, SurfaceStopReason::FrameFailed);
}

// A scene that has not yet shown a frame is still inside the host's first-frame
// wait, which has its own timeout and rollback; a recovery of its own would race
// that wait. The failure is still counted for anyone who reads the health.
TEST_F(UnchangedPresent, ADrawFailureBeforeTheFirstFrameIsCountedButNotReported)
{
    const auto project = WriteStaticScene(root_ / "scene");
    FailureProbe probe;
    RunningWallpaper running(project, root_ / "run");
    running.wallpaper().setPropertyObject(PROPERTY_RENDER_FAILURE_CALLBACK, probe.Callback());
    // Posted before the scene can have compiled and drawn anything.
    if (running.FirstFrameSeen()) GTEST_SKIP() << "the scene had already drawn";
    SceneWallpaperInputTestAccess::InjectFrameFailure(running.wallpaper());

    const auto deadline = std::chrono::steady_clock::now() + 5s;
    while (running.wallpaper().surfaceHealth().failed_frames == 0 &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(5ms);
    }
    ASSERT_EQ(running.wallpaper().surfaceHealth().failed_frames, 1u)
        << "the injected failure never ran";
    std::this_thread::sleep_for(400ms);
    EXPECT_EQ(probe.Reports(), 0) << "a scene that never presented called the host back";
}

// A scene moved to a display of another shape and scale (an external 16:9
// display at 1x unplugged, its scene resized in place onto a 16:10 built-in
// panel at 2x) is laid out for the new surface: it fills it exactly as a scene
// opened there would, with no bars left over from the old shape.
TEST_F(UnchangedPresent, ASceneResizedOntoADisplayOfAnotherShapeFillsItLikeAFreshOne)
{
    const auto project = WriteFullCanvasScene(root_ / "scene");
    constexpr uint16_t kWidth  = 1280;
    constexpr uint16_t kHeight = 800;

    const auto poster = [](RunningWallpaper& running) {
        running.poster().Request(true);
        EXPECT_TRUE(running.poster().WaitDelivered(1));
        std::scoped_lock lock(running.poster().mutex);
        return running.poster().pixels;
    };
    // Red is the card, blue the clear colour and black the room outside the
    // picture; in either byte order red and blue are the outer channels.
    const auto is_card = [](const std::vector<uint8_t>& pixels, uint32_t x, uint32_t y) {
        const auto* pixel = pixels.data() + (static_cast<std::size_t>(y) * kWidth + x) * 4u;
        const bool  red   = (pixel[0] > 200 && pixel[2] < 50) || (pixel[2] > 200 && pixel[0] < 50);
        return red && pixel[1] < 50;
    };
    const auto rows_of_card = [&](const std::vector<uint8_t>& pixels) {
        std::vector<bool> rows;
        for (uint32_t y : { 0u, 1u, 10u, 400u, 789u, 798u, 799u }) {
            rows.push_back(is_card(pixels, 640, y) && is_card(pixels, 2, y) &&
                           is_card(pixels, kWidth - 3, y));
        }
        return rows;
    };

    // Fill, the host's default, which covers the display and crops the canvas.
    const auto fill = [](RunningWallpaper& running) {
        running.wallpaper().setPropertyInt32(PROPERTY_SCALINGMODE,
                                             static_cast<int32_t>(WallpaperScalingMode::FILL));
    };

    std::vector<uint8_t> fresh;
    {
        RunningWallpaper running(project, root_ / "fresh", kWidth, kHeight, 2.0);
        fill(running);
        ASSERT_TRUE(running.WaitForFirstFrame());
        std::this_thread::sleep_for(300ms);
        fresh = poster(running);
    }
    ASSERT_EQ(fresh.size(), std::size_t { kWidth } * kHeight * 4u);
    ASSERT_EQ(rows_of_card(fresh), std::vector<bool>(7, true))
        << "a scene opened on the 16:10 surface does not fill it";

    RunningWallpaper running(project, root_ / "moved", 1920, 1080, 1.0);
    fill(running);
    ASSERT_TRUE(running.WaitForFirstFrame());
    std::this_thread::sleep_for(300ms);
    ASSERT_TRUE(running.Resize(kWidth, kHeight, 2.0));
    std::this_thread::sleep_for(300ms);
    const auto moved = poster(running);
    ASSERT_EQ(moved.size(), fresh.size());
    EXPECT_EQ(rows_of_card(moved), std::vector<bool>(7, true))
        << "the resized scene left rows unfilled at the top or bottom";
}

namespace
{

/// GPU time of every Metal command buffer this process commits, whichever
/// code made it: they are all command buffers of the one device.
/// Counted from each buffer's own GPU start and end, so other processes'
/// work on the GPU is not in it.
std::atomic<uint64_t> g_command_buffer_gpu_ns { 0 };
std::atomic<uint64_t> g_command_buffers { 0 };
IMP                   g_original_commit = nullptr;

void CountedCommit(id self, SEL command)
{
    [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        const double seconds = buffer.GPUEndTime - buffer.GPUStartTime;
        if (seconds > 0.0) g_command_buffer_gpu_ns += static_cast<uint64_t>(seconds * 1e9);
        ++g_command_buffers;
    }];
    reinterpret_cast<void (*)(id, SEL)>(g_original_commit)(self, command);
}

/// Wraps `commit` of the device's command buffer class once per process.
bool CountCommandBufferGpuTime(id<MTLDevice> device)
{
    if (g_original_commit != nullptr) return true;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    Class retained   = [[queue commandBuffer] class];
    Class unretained = [[queue commandBufferWithUnretainedReferences] class];
    // One implementation of `commit` serves both kinds on this GPU; were they
    // ever two, one of the renderers would go uncounted, so say so instead.
    Method method = class_getInstanceMethod(retained, @selector(commit));
    if (method == nullptr ||
        method != class_getInstanceMethod(unretained, @selector(commit))) {
        return false;
    }
    g_original_commit = method_setImplementation(method, reinterpret_cast<IMP>(&CountedCommit));
    return true;
}

/// Whole-GPU and process counters at one instant.
struct EnergySample
{
    std::chrono::steady_clock::time_point at;
    double   cpu_seconds { 0.0 };
    uint64_t own_gpu_ns { 0 };
    uint64_t own_command_buffers { 0 };
    uint64_t cpu_energy_nj { 0 };
    uint64_t gpu_energy_nj { 0 };
    uint64_t gpu_time_ns { 0 };
    uint64_t footprint { 0 };
    SurfaceHealthSnapshot health;
};

EnergySample SampleEnergy(const SceneWallpaper& wallpaper)
{
    EnergySample sample;
    sample.at                  = std::chrono::steady_clock::now();
    sample.own_gpu_ns          = g_command_buffer_gpu_ns.load();
    sample.own_command_buffers = g_command_buffers.load();
    rusage usage {};
    getrusage(RUSAGE_SELF, &usage);
    sample.cpu_seconds = double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
                         double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
    rusage_info_v6 info {};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, reinterpret_cast<rusage_info_t*>(&info)) == 0) {
        sample.cpu_energy_nj = info.ri_energy_nj;
    }
    // Every coalition: the GPU's whole energy, which the kernel only shares
    // out between coalitions, and this process shares one with whatever
    // launched it.
    std::vector<uint64_t> entries(2 * 4096);
    const int bytes = proc_listcoalitions(2, 0, entries.data(), int(entries.size() * 8));
    for (int i = 0; bytes > 0 && i < bytes / 16; ++i) {
        std::array<uint64_t, 45> fields {};
        if (coalition_info_resource_usage(entries[std::size_t(i) * 2], fields.data(),
                                          sizeof(fields)) != 0) {
            continue;
        }
        sample.gpu_time_ns += fields[8];
        sample.gpu_energy_nj += fields[41];
    }
    task_vm_info_data_t vm {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm), &count) ==
        KERN_SUCCESS) {
        sample.footprint = vm.phys_footprint;
    }
    sample.health = wallpaper.surfaceHealth();
    return sample;
}

} // namespace

// Headless A/B of what one real wallpaper costs on one renderer: the
// production `SceneWallpaper` with its own frame clock at 60 FPS, drawing into
// an unattached layer, so nothing reaches the desktop. One scene and one
// renderer per process, so footprint and compiled state belong to that run.
// Prints one `ENERGY {json}` line; asserts only that the scene kept drawing on
// the renderer asked for. Skipped unless `WE_TEST_ENERGY_PROJECT` is set.
//
// Process CPU time and CPU energy are this process's own, and so is the GPU
// time of its command buffers (`gpu_own_s`), whichever renderer committed
// them. GPU energy and busy time over all coalitions are the whole GPU's,
// other processes included: compare those only in alternating windows
// against an idle window of the same length on an otherwise quiet machine.
TEST_F(UnchangedPresent, LocalProjectEnergyIsMeasuredHeadlessly)
{
    const char* project = std::getenv("WE_TEST_ENERGY_PROJECT");
    const char* assets  = std::getenv("WE_TEST_ASSETS");
    if (project == nullptr || assets == nullptr) {
        GTEST_SKIP() << "WE_TEST_ENERGY_PROJECT and WE_TEST_ASSETS name no wallpaper";
    }
    const auto number = [](const char* name, double fallback) {
        const char* value = std::getenv(name);
        return value != nullptr ? std::strtod(value, nullptr) : fallback;
    };
    // The 2D scene resolution the run draws at, and the backing scale of the
    // surface it draws on: a 3456 x 2234 surface at 2 is a laptop panel.
    const char* resolution_name = std::getenv("WE_TEST_ENERGY_RESOLUTION");
    const bool  display =
        resolution_name != nullptr && std::string_view(resolution_name) == "display";
    const double scale_factor = number("WE_TEST_ENERGY_SCALE_FACTOR", 1.0);
    // The scaling mode the host pushes: `fill`, `fit`, `fit_blurred`,
    // `stretch` or `none`. Unset, none is pushed and the scene keeps its own.
    const std::string_view scaling_name = std::getenv("WE_TEST_ENERGY_SCALING") != nullptr
                                              ? std::getenv("WE_TEST_ENERGY_SCALING")
                                              : "default";
    const std::map<std::string_view, WallpaperScalingMode> scaling_modes {
        { "none", WallpaperScalingMode::NONE },
        { "stretch", WallpaperScalingMode::STRETCH },
        { "fit", WallpaperScalingMode::FIT },
        { "fill", WallpaperScalingMode::FILL },
        { "fit_blurred", WallpaperScalingMode::FIT_BLURRED },
    };
    ASSERT_TRUE(scaling_name == "default" || scaling_modes.contains(scaling_name))
        << "no scaling mode " << scaling_name;
    const double warmup  = number("WE_TEST_ENERGY_WARMUP", 5.0);
    const double window  = number("WE_TEST_ENERGY_SECONDS", 20.0);
    const auto   width   = static_cast<uint16_t>(number("WE_TEST_ENERGY_WIDTH", 1920));
    const auto   height  = static_cast<uint16_t>(number("WE_TEST_ENERGY_HEIGHT", 1080));
    const auto   cache   = std::getenv("WE_TEST_ENERGY_CACHE") != nullptr
                               ? std::filesystem::path(std::getenv("WE_TEST_ENERGY_CACHE"))
                               : root_ / "cache";

    // Production defaults: counting off, scene optimisation on.
    RendererCounters::SetEnabled(false);
    render::SetSceneOptimizationEnabled(true);
    SetSceneResolution(display ? SceneResolution::Display : SceneResolution::Canvas);
    struct RestoreResolution
    {
        ~RestoreResolution() { SetSceneResolution(SceneResolution::Canvas); }
    } restore_resolution;

    std::mutex              mutex;
    std::condition_variable changed;
    bool                    first_frame = false;
    CAMetalLayer*           layer = [CAMetalLayer layer];
    layer.device                  = MTLCreateSystemDefaultDevice();
    ASSERT_TRUE(CountCommandBufferGpuTime(layer.device))
        << "this GPU's command buffers could not be counted";
    layer.pixelFormat             = MTLPixelFormatBGRA8Unorm;
    layer.contentsScale           = 1.0;
    layer.frame                   = CGRectMake(0, 0, width, height);
    layer.drawableSize            = CGSizeMake(width, height);

    SceneWallpaper wallpaper;
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyObject(PROPERTY_FIRST_FRAME_CALLBACK,
                                std::make_shared<FirstFrameCallback>([&] {
                                    std::scoped_lock lock(mutex);
                                    first_frame = true;
                                    changed.notify_all();
                                }));
    RenderInitInfo info;
    info.metal_layer      = (__bridge void*)layer;
    info.width            = width;
    info.height           = height;
    info.render_width     = width;
    info.render_height    = height;
    info.display_scale_factor = scale_factor;
    wallpaper.initSurface(info);
    if (scaling_name != "default") {
        wallpaper.setPropertyInt32(PROPERTY_SCALINGMODE,
                                   static_cast<int32_t>(scaling_modes.at(scaling_name)));
    }
    SceneWallpaperConfig config;
    config.source     = project;
    config.assets     = assets;
    config.cache_path = cache.string();
    config.fps        = 60;
    config.paused     = false;
    // A measurement makes no sound, whatever the scene mounts: muted in its
    // configuration, so no output device is ever started for it.
    config.volume     = 0.0f;
    config.muted      = true;
    wallpaper.applyConfig(config);
    {
        std::unique_lock lock(mutex);
        ASSERT_TRUE(changed.wait_for(lock, 120s, [&] { return first_frame; }))
            << "the wallpaper never drew a frame";
    }
    std::this_thread::sleep_for(std::chrono::duration<double>(warmup));

    const auto selection = wallpaper.sceneBackendSelection();
    const auto before    = SampleEnergy(wallpaper);
    std::this_thread::sleep_for(std::chrono::duration<double>(window));
    const auto after = SampleEnergy(wallpaper);
    wallpaper.shutdown();

    const double seconds = std::chrono::duration<double>(after.at - before.at).count();
    const uint64_t completed = after.health.frames_completed - before.health.frames_completed;
    const uint64_t presented = after.health.frames_presented - before.health.frames_presented;
    std::cout << "ENERGY {\"renderer\":\"native\",\"scaling\":\"" << scaling_name
              << "\",\"resolution\":\""
              << (display ? "display" : "canvas") << "\",\"backend\":\""
              << (selection.failed() ? "held" : "native")
              << "\",\"seconds\":" << seconds
              << ",\"cpu_seconds\":" << (after.cpu_seconds - before.cpu_seconds)
              << ",\"cpu_mj\":" << double(after.cpu_energy_nj - before.cpu_energy_nj) / 1e6
              << ",\"gpu_own_s\":" << double(after.own_gpu_ns - before.own_gpu_ns) / 1e9
              << ",\"command_buffers\":" << (after.own_command_buffers - before.own_command_buffers)
              << ",\"gpu_all_mj\":" << double(after.gpu_energy_nj - before.gpu_energy_nj) / 1e6
              << ",\"gpu_all_busy_s\":" << double(after.gpu_time_ns - before.gpu_time_ns) / 1e9
              << ",\"frames_completed\":" << completed << ",\"frames_presented\":" << presented
              << ",\"footprint_mb\":" << double(after.footprint) / 1048576.0
              << ",\"failed_frames\":" << after.health.failed_frames << "}" << std::endl;
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
    EXPECT_GT(completed, 0u) << "the wallpaper stopped drawing during the window";
    EXPECT_EQ(after.health.failed_frames, 0u);
}
