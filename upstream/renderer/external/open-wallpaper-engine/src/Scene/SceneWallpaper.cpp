#include "SceneWallpaper.hpp"
#include "SceneRendererHandle.hpp"
#include "MetalRender/MetalBackendRouter.hpp"
#include "MetalRender/MetalRender.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "Shader/SceneMetalVariants.hpp"
#include "SceneWallpaperSurface.hpp"
#include "SceneSourceResolver.hpp"
#include "Project/ProjectProperties.hpp"

#include "Image.hpp"
#include "Utils/Logging.h"
#include "Looper/Looper.hpp"

#include "Timer/FrameTimer.hpp"
#include "Utils/FpsCounter.h"
#include "WPSceneParser.hpp"
#include "WPShaderParser.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneShader.h"
#include "Scene/SceneVertexArray.h"
#include "Particle/ParticleSystem.h"
#include "Interface/IImageParser.h"
#include "Interface/IShaderValueUpdater.h"

#include <nlohmann/json.hpp>

#include "Fs/VFS.h"
#include "Fs/PhysicalFs.h"

#include "Audio/SoundManager.h"
#include "Audio/FfmpegSoundStream.hpp"
#include "Video/FfmpegVideoTextureSource.hpp"
#include "Video/VideoFramePacing.hpp"

#include "RenderGraph/RenderGraph.hpp"

#include "SpecTexs.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "VulkanRender/VulkanRender.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include <algorithm>
#include <atomic>
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <limits>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <utility>
#include <vector>

using namespace wallpaper;

#define CASE_CMD(cmd) \
    case CMD::CMD_##cmd: handle_##cmd(msg); break;
#define MHANDLER_CMD(cmd) void handle_##cmd(const std::shared_ptr<looper::Message>& msg)
#define MHANDLER_CMD_IMPL(cl, cmd) \
    void impl_##cl::handle_##cmd(const std::shared_ptr<looper::Message>& msg)
#define CALL_MHANDLER_CMD(cmd, msg) handle_##cmd(msg)

namespace
{
bool SetError(std::string* error, std::string message) {
    if (error != nullptr) *error = std::move(message);
    return false;
}

template<typename T>
void AddMsgCmd(looper::Message& msg, T cmd) {
    msg.setInt32("cmd", (int32_t)cmd);
}
template<typename T>
std::shared_ptr<looper::Message> CreateMsgWithCmd(const std::shared_ptr<looper::Handler>& handler,
                                                  T                                       cmd) {
    auto msg = looper::Message::create(0, handler);
    AddMsgCmd(*msg, cmd);
    return msg;
}

uint16_t ParsePkgVersionStamp(std::string_view stamp) {
    constexpr std::string_view prefix { "PKGV" };
    if (stamp.size() <= prefix.size() || stamp.substr(0, prefix.size()) != prefix) {
        return SceneParseRequest::kUnknownPkgVersion;
    }

    uint16_t    version { SceneParseRequest::kUnknownPkgVersion };
    const auto* first    = stamp.data() + prefix.size();
    const auto* last     = stamp.data() + stamp.size();
    const auto [ptr, ec] = std::from_chars(first, last, version);
    if (ec != std::errc {} || ptr != last) return SceneParseRequest::kUnknownPkgVersion;
    return version;
}

uint16_t ReadPkgVersionFromFile(const std::string& pkg_path) {
    std::ifstream input(pkg_path, std::ios::binary);
    if (! input.good()) return SceneParseRequest::kUnknownPkgVersion;

    int32_t length { 0 };
    input.read(reinterpret_cast<char*>(&length), sizeof(length));
    if (! input.good() || length <= 0 || length > 64) {
        return SceneParseRequest::kUnknownPkgVersion;
    }

    std::string stamp(static_cast<std::size_t>(length), '\0');
    input.read(stamp.data(), static_cast<std::streamsize>(stamp.size()));
    if (! input.good()) return SceneParseRequest::kUnknownPkgVersion;
    return ParsePkgVersionStamp(stamp);
}

class NoOpShaderValueUpdater final : public wallpaper::IShaderValueUpdater {
public:
    void FrameBegin() override {}
    void InitUniforms(wallpaper::SceneNode*, const wallpaper::ExistsUniformOp&) override {}
    void UpdateUniforms(wallpaper::SceneNode*, wallpaper::sprite_map_t&,
                        const wallpaper::UpdateUniformOp&) override {}
    void FrameEnd() override {}
    void MouseInput(double, double) override {}
    void SetTexelSize(float, float) override {}
    void SetScreenSize(i32, i32) override {}
};

class SingleVideoImageParser final : public wallpaper::IImageParser {
public:
    explicit SingleVideoImageParser(std::shared_ptr<wallpaper::Image> image)
        : m_image(std::move(image)) {}

    std::shared_ptr<wallpaper::Image> Parse(const std::string& name) override {
        if (m_image != nullptr && name == m_image->key) return m_image;
        return nullptr;
    }

    wallpaper::ImageHeader ParseHeader(const std::string& name) override {
        if (m_image != nullptr && name == m_image->key) return m_image->header;
        return {};
    }

private:
    std::shared_ptr<wallpaper::Image> m_image;
};

class ScopedGlslang final {
public:
    ScopedGlslang() { wallpaper::WPShaderParser::InitGlslang(); }
    ~ScopedGlslang() { wallpaper::WPShaderParser::FinalGlslang(); }
};

struct SystemMediaArtworkPayload {
    uint32_t             width { 0 };
    uint32_t             height { 0 };
    std::vector<uint8_t> rgba;
};

bool BuildVideoCopyShader(wallpaper::fs::VFS& vfs, std::string_view scene_id,
                          std::shared_ptr<wallpaper::SceneShader>* shader, std::string* error) {
    if (shader == nullptr) return SetError(error, "video copy shader output must not be null");

    std::string vertex_src = "in vec3 a_Position;\n"
                             "in vec2 a_TexCoord;\n"
                             "void main() {\n"
                             "gl_Position = vec4(a_Position, 1.0);\n"
                             "v_TexCoord = a_TexCoord;\n"
                             "}\n";

    std::string fragment_src = "uniform sampler2D g_Texture0;\n"
                               "in vec2 v_TexCoord;\n"
                               "void main() {\n"
                               "gl_FragColor = texture(g_Texture0, v_TexCoord);\n"
                               "}\n";

    wallpaper::WPShaderInfo                 shader_info;
    std::vector<wallpaper::WPShaderTexInfo> tex_infos(1);
    tex_infos[0].enabled = true;

    std::array units {
        wallpaper::WPShaderUnit {
            .stage           = wallpaper::ShaderType::VERTEX,
            .src             = std::move(vertex_src),
            .preprocess_info = {},
        },
        wallpaper::WPShaderUnit {
            .stage           = wallpaper::ShaderType::FRAGMENT,
            .src             = std::move(fragment_src),
            .preprocess_info = {},
        },
    };

    auto compiled_shader  = std::make_shared<wallpaper::SceneShader>();
    compiled_shader->name = "commands/copy";
    std::string reflection_json;
    if (! wallpaper::WPShaderParser::CompileToSpvRust(
            scene_id, "commands/copy", units, compiled_shader->codes, vfs, &shader_info, tex_infos, &reflection_json)) {
        return SetError(error, "failed to compile pure-video copy shader");
    }

    compiled_shader->rust_reflection_json = std::move(reflection_json);
    compiled_shader->default_uniforms = shader_info.svs;
    *shader                           = std::move(compiled_shader);
    return true;
}

void InstallVideoProjectCameras(wallpaper::Scene& scene) {
    scene.ortho[0] = 2;
    scene.ortho[1] = 2;

    auto global_node = std::make_shared<wallpaper::SceneNode>();
    scene.sceneGraph->AppendChild(global_node);

    auto global_camera = std::make_shared<wallpaper::SceneCamera>(2, 2, -1.0f, 1.0f);
    global_camera->AttatchNode(global_node);
    scene.cameras["global"] = global_camera;
    scene.activeCamera      = global_camera.get();

    auto perspective_node = std::make_shared<wallpaper::SceneNode>();
    scene.sceneGraph->AppendChild(perspective_node);

    auto perspective_camera = std::make_shared<wallpaper::SceneCamera>(1.0f, 0.1f, 1000.0f, 45.0f);
    perspective_camera->AttatchNode(perspective_node);
    scene.cameras["global_perspective"] = perspective_camera;
}

std::shared_ptr<wallpaper::SceneNode>
CreateVideoProjectNode(std::string_view                               texture_name,
                       const std::shared_ptr<wallpaper::SceneShader>& shader) {
    constexpr std::array<float, 12> positions {
        -1.0f, -1.0f, 0.0f, -1.0f, 1.0f, 0.0f, 1.0f, -1.0f, 0.0f, 1.0f, 1.0f, 0.0f,
    };
    constexpr std::array<float, 8> tex_coords {
        0.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f,
    };

    auto                        mesh = std::make_shared<wallpaper::SceneMesh>();
    wallpaper::SceneVertexArray vertex(
        {
            { std::string(wallpaper::WE_IN_POSITION), wallpaper::VertexType::FLOAT3 },
            { std::string(wallpaper::WE_IN_TEXCOORD), wallpaper::VertexType::FLOAT2 },
        },
        4);
    vertex.SetVertex(wallpaper::WE_IN_POSITION, positions);
    vertex.SetVertex(wallpaper::WE_IN_TEXCOORD, tex_coords);
    mesh->AddVertexArray(std::move(vertex));

    wallpaper::SceneMaterial material;
    material.name = "video_project_copy";
    material.textures.push_back(std::string(texture_name));
    material.defines.push_back(std::string(wallpaper::WE_GLTEX_NAMES[0]));
    material.blenmode            = wallpaper::BlendMode::Normal;
    material.customShader.shader = shader;
    mesh->AddMaterial(std::move(material));

    auto node  = std::make_shared<wallpaper::SceneNode>();
    node->ID() = 1;
    node->AddMesh(mesh);
    return node;
}

std::shared_ptr<wallpaper::Scene>
CreateVideoProjectScene(std::unique_ptr<wallpaper::fs::VFS> vfs,
                        const std::filesystem::path&        project_path,
                        const wallpaper::ProjectManifest& manifest, std::string* error) {
    if (vfs == nullptr) {
        SetError(error, "video project VFS must not be null");
        return nullptr;
    }

    if (! wallpaper::InstallVirtualAssets(*vfs)) {
        SetError(error, "failed to install runtime virtual assets for video project");
        return nullptr;
    }

    auto image =
        wallpaper::video::CreateVideoProjectImage(project_path.parent_path(), manifest.file, error);
    if (image == nullptr) return nullptr;

    std::string scene_id = manifest.workshop_id;
    if (scene_id.empty()) {
        scene_id = project_path.parent_path().filename().string();
    }

    std::shared_ptr<wallpaper::SceneShader> shader;
    if (! BuildVideoCopyShader(*vfs, scene_id, &shader, error)) return nullptr;

    auto scene                = std::make_shared<wallpaper::Scene>();
    scene->accepts_pointer_input = false;
    // Everything below this line is what makes the claim true: one video
    // texture, a copy shader, a no-op shader value updater, and no script,
    // particle or audio layer. Keep them together so the marker cannot drift
    // away from the construction that justifies it.
    scene->single_video_source   = true;
    scene->scene_id           = scene_id;
    scene->clearColor         = { 0.0f, 0.0f, 0.0f };
    scene->shaderValueUpdater = std::make_unique<NoOpShaderValueUpdater>();
    scene->imageParser        = std::make_unique<SingleVideoImageParser>(image);
    scene->vfs                = std::move(vfs);

    InstallVideoProjectCameras(*scene);
    // This target holds one decoded frame at the resolution the file was
    // encoded at, so it is media-sized: an internal render scale must not
    // shrink it. Downsampling an already-decoded frame and upsampling it again
    // at present costs quality and saves almost nothing, because the decode it
    // would have to make cheaper is upstream of this target.
    const auto video_width  = std::max(1, image->header.width);
    const auto video_height = std::max(1, image->header.height);
    scene->scene_extent[0]  = video_width;
    scene->scene_extent[1]  = video_height;
    scene->renderTargets[std::string(wallpaper::SpecTex_Default)] = wallpaper::SceneRenderTarget {
        .width           = video_width,
        .height          = video_height,
        .authored_width  = video_width,
        .authored_height = video_height,
        .media_sized     = true,
        .bind            = { .enable = true, .screen = true },
    };
    scene->textures[image->key] = wallpaper::SceneTexture {
        .url     = image->key,
        .sample  = image->header.sample,
        .isVideo = true,
    };
    scene->sceneGraph->AppendChild(CreateVideoProjectNode(image->key, shader));

    return scene;
}
} // namespace

namespace wallpaper
{
class RenderHandler;

class MainHandler : public looper::Handler {
public:
    /// Fixed width for the same reason as the render handler's: the looper
    /// carries the command as an `int32_t` and the cast back has to be defined.
    enum class CMD : int32_t
    {
        CMD_LOAD_SCENE,
        CMD_APPLY_CONFIG,
        CMD_SET_PROPERTY,
        CMD_STOP,
        CMD_FIRST_FRAME,
        CMD_POINTER_INPUT_CHANGED,
        CMD_USER_SHORTCUT,
        CMD_AUDIO_REQUIREMENT_CHANGED,
        CMD_RENDER_FAILED,
        CMD_NO
    };

public:
    MainHandler();
    virtual ~MainHandler() {};

    bool init();
    void shutdown();
    /// Before `init()`: the loopers adopt the scope when their threads start.
    void setLogScope(uint64_t scope) {
        m_main_loop->setLogScope(scope);
        m_render_loop->setLogScope(scope);
    }
    auto renderHandler() const { return m_render_handler; }
    bool inited() const { return m_inited; }

public:
    void onMessageReceived(const std::shared_ptr<looper::Message>& msg) override {
        int32_t cmd_int = (int32_t)CMD::CMD_NO;
        if (msg->findInt32("cmd", &cmd_int)) {
            CMD cmd = static_cast<CMD>(cmd_int);
            switch (cmd) {
                CASE_CMD(APPLY_CONFIG);
                CASE_CMD(SET_PROPERTY);
                CASE_CMD(LOAD_SCENE);
                CASE_CMD(STOP);
                CASE_CMD(FIRST_FRAME);
                CASE_CMD(POINTER_INPUT_CHANGED);
                CASE_CMD(USER_SHORTCUT);
                CASE_CMD(AUDIO_REQUIREMENT_CHANGED);
                CASE_CMD(RENDER_FAILED);
            case CMD::CMD_NO: break;
                // No `default`, for the same reason the render handler has
                // none: a command that is posted and never dispatched is
                // silent, and the compiler is the only thing that reliably
                // notices.
            }
        }
    }

    void sendCmdLoadScene();
    void sendFirstFrameOk();
    void sendPointerInputCapability(bool accepts_pointer_input);
    void sendUserShortcut(std::string_view property_name, std::string_view property_value);
    /// Reports scene `generation`'s audio requirement. Generations increase
    /// with every scene commit on the render thread.
    void sendAudioRequirement(uint64_t generation, bool requires_audio);
    /// Tells the host's render-failure callback that a scene which had drawn
    /// stopped after a failed frame. Posts only: it runs on the render thread.
    void sendRenderFailure();
    /// The listener a committed scene's runtime runs when it first marks
    /// itself as reading audio, on whatever thread that happens. It only posts.
    std::function<void()> audioRequirementReporter(uint64_t generation);
    bool isGenGraphviz() const { return m_gen_graphviz; }

private:
    bool applyConfig(SceneWallpaperConfig config);
    void setPaused(bool paused);
    bool setProjectPropertyOverrideJson(std::string json);
    bool resetProjectPropertyOverride();
    /// Hands a property document to the render thread to show on the running
    /// scene (`PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON`). Touches no state that a
    /// later load reads, so the saved look is what the next load shows.
    void previewProjectProperties(const std::string& json);
    void loadScene();
    bool loadNonSceneProject(const ProjectManifest& manifest, std::unique_ptr<fs::VFS> vfs);

    MHANDLER_CMD(LOAD_SCENE);
    MHANDLER_CMD(APPLY_CONFIG);
    MHANDLER_CMD(SET_PROPERTY);
    MHANDLER_CMD(STOP);
    MHANDLER_CMD(FIRST_FRAME);
    MHANDLER_CMD(POINTER_INPUT_CHANGED);
    MHANDLER_CMD(USER_SHORTCUT);
    MHANDLER_CMD(AUDIO_REQUIREMENT_CHANGED);
    MHANDLER_CMD(RENDER_FAILED);

private:
    bool m_inited { false };

    std::string m_assets;
    std::string m_source;
    std::string m_cache_path;
    std::string m_project_property_override_json;
    bool        m_gen_graphviz { false };
    bool        m_audio_response_enabled { false };
    bool        m_media_integration_enabled { false };
    bool        m_force_shader_refresh { false };

    WPSceneParser                        m_scene_parser;
    std::unique_ptr<audio::SoundManager> m_sound_manager;
    FirstFrameCallback                   m_first_frame_callback;
    PointerInputCallback                 m_pointer_input_callback;
    UserShortcutCallback                 m_user_shortcut_callback;
    bool                                 m_accepts_pointer_input { true };
    AudioRequirementCallback             m_audio_requirement_callback;
    RenderFailureCallback                m_render_failure_callback;
    /// Latest committed scene generation seen here, and whether that scene
    /// reads audio. Only the main looper touches these.
    uint64_t                             m_audio_requirement_generation { 0 };
    bool                                 m_requires_audio { false };

private:
    std::shared_ptr<looper::Looper> m_main_loop;
    std::shared_ptr<looper::Looper> m_render_loop;
    std::shared_ptr<RenderHandler>  m_render_handler;
};
// for macro
using impl_MainHandler = MainHandler;

class RenderHandler : public looper::Handler {
public:
    /// Fixed width because commands cross the looper as an `int32_t`, so the
    /// cast back has to be defined for every value that can arrive.
    enum class CMD : int32_t
    {
        CMD_INIT_VULKAN,
        CMD_SET_SCENE,
        CMD_SET_FILLMODE,
        CMD_SET_SCALINGMODE,
        CMD_SET_SCALINGFACTOR,
        CMD_SET_FRAMING,
        CMD_SET_RENDER_SCALE,
        CMD_SET_HORIZONTAL_FLIP,
        CMD_SET_AUDIO_RESPONSE_ENABLED,
        CMD_SET_MEDIA_INTEGRATION_ENABLED,
        CMD_MEDIA_EVENT_JSON,
        CMD_SYSTEM_MEDIA_ARTWORK,
        CMD_APPLY_PROJECT_PROPERTIES,
        CMD_SET_SPEED,
        CMD_STOP,
        CMD_DRAW,
        CMD_BEGIN_SURFACE_RECONFIGURE,
        CMD_FINISH_SURFACE_RECONFIGURE,
        CMD_POSTER_REQUEST,
#ifdef WESCENE_BUILD_TESTS
        CMD_INJECT_FRAME_FAILURE,
#endif
        CMD_NO
    };
    MainHandler& main_handler;
    RenderHandler(MainHandler& m)
        : main_handler(m), m_render(std::make_unique<SceneRendererHandle>()) {
        // Installed before anything can tick: the frame clock only ever reads
        // this pointer, and the counters outlive it. The renderer is given the
        // same pointer when it is created, which is not here: no backend exists
        // until a scene has said which one it needs.
        frame_timer.SetCounters(&counters);
        {
            std::scoped_lock lock(m_content_wake->mutex);
            m_content_wake->timer = &frame_timer;
        }
        publishPauseReasons();
    }
    virtual ~RenderHandler() {
        // Before anything else: the host's poster hook can post to this
        // handler from a notification thread, and it must stop being able to
        // while the members it would reach are still alive. A scene's text
        // worker is the same kind of caller and is detached the same way; the
        // scene may still hold the target, but it no longer reaches a timer.
        unbindPosterWake();
        {
            std::scoped_lock lock(m_content_wake->mutex);
            m_content_wake->timer = nullptr;
        }
        frame_timer.Stop();
        m_render->release();
        LOG_INFO("render handler deleted");
    }

    void onMessageReceived(const std::shared_ptr<looper::Message>& msg) override {
        int32_t cmd_int = (int32_t)CMD::CMD_NO;
        if (msg->findInt32("cmd", &cmd_int)) {
            CMD cmd = static_cast<CMD>(cmd_int);
            switch (cmd) {
                CASE_CMD(DRAW);
                CASE_CMD(STOP);
                CASE_CMD(SET_FILLMODE);
                CASE_CMD(SET_SCALINGMODE);
                CASE_CMD(SET_SCALINGFACTOR);
                CASE_CMD(SET_FRAMING);
                CASE_CMD(SET_HORIZONTAL_FLIP);
                CASE_CMD(SET_AUDIO_RESPONSE_ENABLED);
                CASE_CMD(SET_MEDIA_INTEGRATION_ENABLED);
                CASE_CMD(MEDIA_EVENT_JSON);
                CASE_CMD(SYSTEM_MEDIA_ARTWORK);
                CASE_CMD(APPLY_PROJECT_PROPERTIES);
                CASE_CMD(SET_SCENE);
                CASE_CMD(SET_SPEED);
                CASE_CMD(INIT_VULKAN);
                CASE_CMD(BEGIN_SURFACE_RECONFIGURE);
                CASE_CMD(FINISH_SURFACE_RECONFIGURE);
                CASE_CMD(POSTER_REQUEST);
                CASE_CMD(SET_RENDER_SCALE);
#ifdef WESCENE_BUILD_TESTS
                CASE_CMD(INJECT_FRAME_FAILURE);
#endif
            case CMD::CMD_NO: break;
                // No `default`. Every command is named, so the compiler
                // reports the next one that is added and not dispatched —
                // which is how `SET_RENDER_SCALE` came to be posted, handled
                // and silently dropped: the handler existed, the case did not.
            }
            // Every command except the draw itself is an event that may have
            // changed what the next frame should show, so an idle scene takes
            // one. Doing this once here rather than at each call site is
            // deliberate: a command added later wakes the scene by default,
            // and the failure mode of forgetting is a redundant frame rather
            // than a wallpaper that stops responding.
            //
            // The request is dropped when the clock is stopped, so this cannot
            // resume a paused wallpaper, and it coalesces with any frame
            // already pending.
            //
            // A cover is the one exception, because it is the one command that
            // routinely carries no change at all: every new scene handle is
            // replayed the current cover, and a replay that wakes the scene
            // would make the blanket rule cost a frame per display added, per
            // wallpaper switched, per reconcile. Its handler requests a frame
            // when — and only when — the pixels actually moved.
            if (cmd != CMD::CMD_DRAW && cmd != CMD::CMD_SYSTEM_MEDIA_ARTWORK) requestFrame();
        }
    }

    // Vulkan-only: these export a swapchain and a sync fd, which the Metal
    // backend has no equivalent of. Null while Metal is driving, which is what
    // the offscreen export path already treats as "not available".
    ExSwapchain* exSwapchain() const {
        auto* vulkan = m_render->vulkanOnly();
        return vulkan != nullptr ? vulkan->exSwapchain() : nullptr;
    }
    int takeLastFrameSyncFd() {
        auto* vulkan = m_render->vulkanOnly();
        return vulkan != nullptr ? vulkan->takeLastFrameSyncFd() : -1;
    }

    bool renderInited() const { return m_render->inited(); }

    /// Whether a surface has been handed over, whether or not a backend has
    /// been created on it yet.
    ///
    /// Scene loading is gated on this rather than on `renderInited()`: which
    /// backend a scene needs is read off the parsed scene, so waiting for a
    /// renderer before parsing would wait for something parsing has to produce.
    [[nodiscard]] bool renderSurfaceReady() const {
        return m_render_init_info != nullptr || m_render->inited();
    }

    /// Tells the frame clock how often this scene's content can actually
    /// change. Only the engine's own plain-video scene can answer: it is one
    /// video texture behind a copy shader with a no-op shader value updater and
    /// no script, particle, audio or pointer input, so the video's frame period
    /// is the whole scene's period. Rendering faster than that presents
    /// identical pixels. Every other scene reports nothing and keeps the fixed
    /// cadence, because an authored scene may change on a time uniform, a
    /// script, a particle system, audio or a feedback texture that this code
    /// does not enumerate.
    ///
    /// **Opt-in, and the reason is a bound this function cannot remove.** The
    /// period only reaches the frame clock from here, and this runs after a
    /// completed frame. A source whose rate turns out to be tighter than the
    /// interval currently being waited out therefore produces frames that are
    /// superseded before the next frame boundary — up to
    /// `interval / period - 1` of them. Removing that needs the source to wake
    /// the clock itself, which is a different change. Until then the default is
    /// the safe baseline: tick at the configured ceiling.
    ///
    /// Runs on the render thread; the frame clock only reads the value it
    /// stores.
    void refreshFrameDemand() {
        // Also the A/B entry point, so a comparison measures one scheduling
        // strategy in one binary rather than two builds. Read per frame now
        // that it is a live setting rather than an environment variable: the
        // read is one relaxed atomic load, and a user toggling the option has
        // to take effect without restarting the wallpaper.
        const bool pacing_enabled = video::ContentPacingEnabled();

        FrameTimer::FrameDemand demand {};
        if (pacing_enabled && m_scene != nullptr && m_scene->single_video_source &&
            renderInited()) {
            // The source reports a period on the media's own timeline. Playback
            // speed maps it onto the wall clock, so a 2x wallpaper needs twice
            // the tick rate for the same content.
            const double period_seconds = video::ResolveContentPeriodSeconds(
                m_render->ShortestVideoFramePeriod(), static_cast<double>(m_speed));
            if (period_seconds > 0.0) {
                demand.content_period = std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::duration<double>(period_seconds));
            }
        }

        const SceneUpdateDemand update = evaluateSceneUpdateDemand();
        m_scene_demand_reasons.store(update.reasons, std::memory_order_relaxed);
        // Recorded even while the scene is continuous, so the flag is already
        // correct the instant it becomes idle rather than one frame late.
        m_scene_wants_pointer.store(
            renderInited() &&
                SceneShaderInputsUsePointer(m_render->ShaderUpdateDemandReasons()),
            std::memory_order_relaxed);
        switch (update.kind) {
        case SceneUpdateDemand::Kind::WaitingForEvent:
            demand.kind = FrameTimer::FrameDemand::Kind::Idle;
            break;
        case SceneUpdateDemand::Kind::WaitingForDeadline:
            demand.kind     = FrameTimer::FrameDemand::Kind::Timed;
            demand.deadline = update.deadline;
            break;
        case SceneUpdateDemand::Kind::Continuous:
            demand.kind = FrameTimer::FrameDemand::Kind::Continuous;
            break;
        }
        m_scene_update_kind.store(update.kind, std::memory_order_relaxed);
        frame_timer.SetFrameDemand(demand);
    }

    /// Whether this scene still needs the clock, and why.
    ///
    /// Runs on the render thread after a frame, when the runtime's registries
    /// and the renderer's compiled graph both describe the state the next frame
    /// would start from. Every path that cannot prove stillness returns
    /// `Continuous`, including every early return: the switch being off, no
    /// scene, no renderer, and a scene that has not yet presented a frame.
    [[nodiscard]] SceneUpdateDemand evaluateSceneUpdateDemand() const {
        SceneUpdateDemand demand {};
        demand.kind = SceneUpdateDemand::Kind::Continuous;

        if (! SceneOnDemandEnabled()) {
            demand.reasons = 0;
            return demand;
        }
        if (m_scene == nullptr || ! renderInited() || m_rg == nullptr) {
            demand.reasons = static_cast<uint32_t>(SceneDemandReason::UnknownInput);
            return demand;
        }
        // Idling before the first good frame would leave whatever was on the
        // surface before this wallpaper started.
        if (! m_scene->first_frame_ok) {
            demand.reasons = static_cast<uint32_t>(SceneDemandReason::NoFrameYet);
            return demand;
        }

        uint32_t reasons =
            SceneDemandReasonsFromShaderInputs(m_render->ShaderUpdateDemandReasons());

        if (m_scene->runtime != nullptr) {
            reasons |= m_scene->runtime->DescribeTimeAdvancingWork();
        } else {
            // A scene with no runtime is not a scene with nothing to do; it is
            // a scene this analysis cannot describe.
            reasons |= SceneDemandReason::UnknownInput;
        }

        if (m_scene->paritileSys != nullptr && m_scene->paritileSys->HasEmitters()) {
            reasons |= SceneDemandReason::Particles;
        }

        demand.reasons = reasons;
        if (reasons == 0) demand.kind = SceneUpdateDemand::Kind::WaitingForEvent;
        return demand;
    }

    /// Creates the renderer that draws this scene, and is the only place that
    /// does so for a scene.
    ///
    /// Runs once per scene, after the scene is parsed and before its graph is
    /// built, because the choice depends on what the scene contains — which is
    /// also why nothing is created before this point. The selection is published
    /// only once a backend exists, so the host never names a renderer that is
    /// not drawing.
    void selectSceneBackend() {
        if (m_scene == nullptr || m_render_init_info == nullptr) return;

        const auto selection = metal::SelectSceneBackend(*m_scene);

        if (selection.backend == SceneBackend::NativeMetal) {
            if (m_render->backend() == SceneBackend::NativeMetal && m_render->inited()) {
                setSceneBackendSelection(selection);
                return;
            }
            std::string error;
            if (m_render->createMetal(*m_render_init_info, error)) {
                setSceneBackendSelection(selection);
                reapplySurfaceState();
                return;
            }
            // Prepare failed, and the handle is empty. Remember the failure
            // against this scene so the next reconcile does not try again and
            // produce a native/legacy flip-flop, then create the compatibility
            // backend carrying the concrete reason.
            if (error.empty()) error = "the native renderer could not be prepared";
            metal::RecordMetalPrepareFailure(*m_scene, error);
            if (! m_render->createVulkan(*m_render_init_info)) {
                suspendAfterGraphFailure();
                return;
            }
            setSceneBackendSelection(SceneBackendSelection { SceneBackend::LegacyVulkan, error });
            reapplySurfaceState();
            return;
        }

        // A Vulkan renderer already driving this surface is reused: a wallpaper
        // switch invalidates the scene, not the device or the swapchain, and
        // rebuilding one that works costs a visible gap for nothing.
        if (m_render->backend() == SceneBackend::LegacyVulkan && m_render->inited()) {
            setSceneBackendSelection(selection);
            return;
        }
        if (! m_render->createVulkan(*m_render_init_info)) {
            suspendAfterGraphFailure();
            return;
        }
        setSceneBackendSelection(selection);
        reapplySurfaceState();
    }

    /// Abandons the native backend for this scene and re-establishes the
    /// compatibility one on the same surface.
    ///
    /// The failure is remembered against the scene so the next reconcile does
    /// not try native again and produce a native/legacy flip-flop. Returns
    /// false only when the compatibility backend could not be re-established
    /// either, which is the one case that genuinely has no renderer left.
    bool fallBackToCompatibility() {
        if (m_render->backend() != SceneBackend::NativeMetal) return false;
        auto reason = m_render->lastError();
        if (reason.empty()) reason = "the native renderer could not draw this scene";
        if (m_scene != nullptr) metal::RecordMetalPrepareFailure(*m_scene, reason);
        // `reason` is read off the native renderer above, before creating the
        // compatibility one destroys it.
        if (m_render_init_info == nullptr) return false;
        if (! m_render->createVulkan(*m_render_init_info)) return false;
        setSceneBackendSelection(SceneBackendSelection { SceneBackend::LegacyVulkan, reason });
        reapplySurfaceState();
        return true;
    }

    /// Re-applies the surface state a newly created renderer does not inherit.
    ///
    /// Creating a backend produces an object that holds none of the scaling,
    /// flip, playback rate, pause or counter state the settings commands have
    /// already recorded, so every one of them has to be pushed again. Pause in
    /// particular: a wallpaper the user paused must not start playing because
    /// they changed a renderer preference.
    void reapplySurfaceState() {
        m_render->SetCounters(&counters);
        m_render->SetWallpaperScalingMode(m_scalingmode);
        m_render->SetWallpaperScalingFactor(m_scalingfactor);
        m_render->SetWallpaperFraming(m_framing);
        m_render->SetWallpaperHorizontalFlip(m_horizontal_flip);
        m_render->SetVideoPlaybackRate(m_speed);
        m_render->SetVideoPlaybackPaused(! frame_timer.Running() || m_render_blocked);
        // Seeds the scale the next compile allocates its render targets at, so
        // a backend created after a render-scale change does not start at full
        // size. The rest of the compiled-graph state — the fill mode, and the
        // scale applied to targets that already exist — belongs to
        // `rebuildRenderGraph`, which every creation path runs straight after
        // this.
        if (m_scene != nullptr) {
            m_scene->render_scale = m_render_scale;
            m_scene->resolution   = CurrentSceneResolution();
        }
    }

    /// Asks for one frame because something outside the clock changed.
    ///
    /// Coalescing is inherent: the clock holds at most one pending request and
    /// at most one draw in flight, so a burst of property writes produces one
    /// frame, not one frame each. Whether the clock keeps running afterwards is
    /// decided by that frame's own demand, not here.
    void requestFrame() { frame_timer.RequestFrame(); }

    /// Lets a scene's own background work ask for a frame without knowing
    /// anything about this handler's lifetime.
    ///
    /// A worker thread can be inside the handler while this handler is being
    /// torn down, so the indirection is a shared target rather than a captured
    /// `this`: the destructor clears the timer under the same mutex the handler
    /// takes, and after that no wake reaches anything. The scene may still hold
    /// the target, which is exactly why the target outlives the handler.
    ///
    /// A scene being replaced can leave one wake in flight for a wallpaper that
    /// is already gone. The cost is a single redundant frame of the new one,
    /// which is the same trade the per-command request makes.
    struct ContentWakeTarget {
        std::mutex   mutex;
        FrameTimer*  timer { nullptr };
    };

    void installContentWake(Scene& scene) {
        if (scene.runtime == nullptr) return;
        auto target = m_content_wake;
        scene.runtime->SetContentWakeHandler([target] {
            std::scoped_lock lock(target->mutex);
            if (target->timer != nullptr) target->timer->RequestFrame();
        });
    }

    /// Why this surface is not presenting, as independent bits. Recomputed on
    /// every transition that can change one of them, so a stopped surface can
    /// be told apart from a surface whose renderer was taken away.
    void publishPauseReasons() {
        uint64_t reasons = OWE_RC_PAUSE_NONE;
        if (! frame_timer.Running()) reasons |= OWE_RC_PAUSE_CLOCK_STOPPED;
        if (m_render_blocked || ! renderInited()) reasons |= OWE_RC_PAUSE_RENDER_BLOCKED;
        if (m_scene == nullptr) reasons |= OWE_RC_PAUSE_NO_SCENE;
        counters.Set(OWE_RC_PAUSE_REASONS, reasons);
    }

    struct MouseButtonSnapshot {
        uint32_t down { 0 };
        uint32_t pressed { 0 };
        uint32_t released { 0 };
    };

    void setMousePos(double x, double y) {
        m_mouse_pos.store(std::array {
            std::clamp(static_cast<float>(x), 0.0f, 1.0f),
            std::clamp(static_cast<float>(y), 0.0f, 1.0f),
        });
        wakeForPointer();
    }

    /// Pointer movement is the one event that never passes through the looper,
    /// so an idle scene has to be woken here explicitly.
    ///
    /// Gated on the scene actually consuming the pointer. Waking on every
    /// mouse move regardless would give a still wallpaper a frame rate equal
    /// to the pointer sample rate, which is worse than not idling at all.
    /// Scenes whose scripts read the cursor are never idle in the first place,
    /// because a script is itself a reason to keep ticking.
    void wakeForPointer() {
        if (! m_scene_wants_pointer.load(std::memory_order_relaxed)) return;
        requestFrame();
    }
    void setMouseButton(int button, bool pressed) {
        if (button < 0 || button > 31) return;
        const uint32_t   mask = 1u << static_cast<uint32_t>(button);
        {
            std::scoped_lock lock(m_mouse_buttons_mutex);
            if (pressed) {
                if ((m_mouse_buttons.down & mask) == 0) {
                    m_mouse_buttons.down |= mask;
                    m_mouse_buttons.pressed |= mask;
                }
            } else if ((m_mouse_buttons.down & mask) != 0) {
                m_mouse_buttons.down &= ~mask;
                m_mouse_buttons.released |= mask;
            }
        }
        // A press and a release are each consumed by exactly one frame, so an
        // idle scene has to run one or the event is never delivered.
        wakeForPointer();
    }
    void setMouseButtonBaseline(uint32_t down) {
        std::scoped_lock lock(m_mouse_buttons_mutex);
        m_mouse_buttons.down = down;
    }
    void setMouseInWindow(bool entered) {
        m_cursor_in_window.store(entered);
        wakeForPointer();
    }

    /// Stages the newest property document to show on the running scene
    /// (`PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON`). Latest wins: a document
    /// staged before the render thread has taken the previous one replaces it,
    /// so a burst of edits costs one update on this thread instead of one each.
    /// Returns whether the slot was empty; only then is no
    /// `CMD_APPLY_PROJECT_PROPERTIES` already on its way to take the document,
    /// and the caller posts one. Callable from any thread.
    [[nodiscard]] bool stageProjectPropertyPreview(ProjectProperties document) {
        std::scoped_lock lock(m_property_preview_mutex);
        const bool       was_empty = ! m_property_preview.has_value();
        m_property_preview         = std::move(document);
        return was_empty;
    }

private:
#ifdef WESCENE_BUILD_TESTS
    friend struct SceneWallpaperInputTestAccess;
#endif
    MouseButtonSnapshot consumeMouseButtonSnapshot() {
        std::scoped_lock    lock(m_mouse_buttons_mutex);
        MouseButtonSnapshot snapshot = m_mouse_buttons;
        m_mouse_buttons.pressed      = 0;
        m_mouse_buttons.released     = 0;
        return snapshot;
    }

    void suspendRendering() {
        m_render_blocked = true;
        frame_timer.Stop();
        publishPauseReasons();
    }

    /// Stops rendering because the graph or the backend under it failed, which
    /// nobody asked for. The host sees the difference from a pause: a stop the
    /// host started itself (a surface being reconfigured) goes through
    /// `suspendRendering` alone and is never reported as a failure.
    void suspendAfterGraphFailure() {
        m_health.NoteGraphFailed();
        suspendRendering();
    }

    /// The surface may draw again. The only place `m_render_blocked` is
    /// lowered, so the failure latch the host reads can never outlive the
    /// block it describes.
    void clearRenderBlock() {
        m_render_blocked = false;
        m_health.ClearStop();
    }

    /// A frame failed and nobody asked for the stop. Counts it, latches the
    /// reason the host reads, stops rendering and, for a scene that had drawn
    /// before, tells the host so it can rebuild the surface.
    ///
    /// `reached_draw` is whether the failure came from the draw itself rather
    /// than from building the graph, which has already reported its own.
    /// A scene that never presented a frame does not call back: the host is
    /// still waiting for that first frame and has its own timeout and rollback
    /// for it, and a recovery of its own would race that wait. The call is a
    /// post, so it never runs host code on this thread, and it is made after
    /// rendering has stopped so the host cannot observe a still-running
    /// surface.
    void failFrame(bool reached_draw) {
        counters.Add(OWE_RC_RENDER_FAILURES);
        if (reached_draw) {
            m_health.NoteFrameFailed();
        } else {
            m_health.NoteGraphFailed();
        }
        suspendRendering();
        if (reached_draw && m_scene != nullptr && m_scene->first_frame_ok)
            main_handler.sendRenderFailure();
    }

    /// Runs the frame clock exactly when there is something for it to drive:
    /// a loaded scene, rendering not blocked, and no pause asked for. Before
    /// a scene lands, and after a load that never delivered one, there is
    /// nothing to draw, so the clock thread does not exist. The looper keeps
    /// running either way, so control messages and the first-frame draw that
    /// follows a scene still arrive.
    void syncFrameClock() {
        if (m_clock_requested && ! m_render_blocked && m_scene != nullptr)
            frame_timer.Run();
        else
            frame_timer.Stop();
    }

    /// Retains a surface description and moves the host's poster wake hook onto
    /// it.
    ///
    /// The previous info's hook is dropped first, so a notification raised
    /// against a layer that is gone cannot post work about the new one. The
    /// host holds its own lock across both halves, which is what keeps an
    /// in-flight notification from poking a handler that has unbound.
    void adoptRenderInitInfo(std::shared_ptr<RenderInitInfo> info) {
        unbindPosterWake();
        m_render_init_info = std::move(info);
        if (! m_render_init_info->bind_poster_wake) return;
        std::weak_ptr<looper::Handler> weak_self = weak_from_this();
        m_render_init_info->bind_poster_wake([weak_self] {
            auto self = weak_self.lock();
            if (self == nullptr) return;
            CreateMsgWithCmd(self, CMD::CMD_POSTER_REQUEST)->post();
        });
    }
    void unbindPosterWake() {
        if (m_render_init_info == nullptr || ! m_render_init_info->bind_poster_wake) return;
        m_render_init_info->bind_poster_wake({});
    }

    bool rebuildRenderGraph() {
        if (m_scene == nullptr) return true;

        // The same scene's graph again: its videos stay open for the compile below
        // instead of starting over at the head of their clips.
        if (m_rg && ! m_render->clearLastRenderGraphForRebuild()) {
            suspendAfterGraphFailure();
            return false;
        }
        // Seed the scale before the graph is compiled so render targets are
        // allocated at the requested size once, instead of at full size and
        // then immediately resized. The resolution is seeded with it for the
        // same reason, and this is also where a scene that was just opened
        // takes the process-wide choice.
        m_scene->render_scale = m_render_scale;
        m_scene->resolution   = CurrentSceneResolution();
        m_rg = sceneToRenderGraph(*m_scene);

        if (main_handler.isGenGraphviz()) m_rg->ToGraphviz("graph.dot");
        if (! m_render->compileRenderGraph(*m_scene, *m_rg)) {
            // Shader libraries and pipeline states are created here, not at
            // init, so this is where a scene that passed the capability gate
            // actually trips the Metal compiler. Suspending would leave that
            // wallpaper black; the compatibility backend draws it.
            if (! fallBackToCompatibility()) {
                suspendAfterGraphFailure();
                return false;
            }
            if (! m_render->compileRenderGraph(*m_scene, *m_rg)) {
                suspendAfterGraphFailure();
                return false;
            }
        }
        m_render->SetWallpaperScalingMode(m_scalingmode);
        m_render->SetWallpaperScalingFactor(m_scalingfactor);
        m_render->SetWallpaperFraming(m_framing);
        m_render->SetWallpaperHorizontalFlip(m_horizontal_flip);
        if (m_fillmode_explicit) {
            m_render->UpdateCameraFillMode(*m_scene, m_fillmode);
        }
        if (m_scene->runtime != nullptr) {
            m_scene->runtime->ConsumeSceneGraphMutationFlag();
        }
        clearRenderBlock();
        return true;
    }

    /// Publishes a now-playing cover into the scene's runtime images.
    ///
    /// A cover is pixels behind a name both backends already re-read on their
    /// own: Vulkan replaces the texture from the pass's per-frame update when
    /// `Image::key` moves (`CustomShaderPass.cpp`), Metal from
    /// `refreshRuntimeImages` when `Version()` moves. Rebuilding the render
    /// graph here on top of that idled the device, destroyed every pipeline
    /// and framebuffer, dropped every uploaded texture and reopened every
    /// video — once per track change, and once more per replay — to change one
    /// thumbnail. Both backends also mark a pass that samples a runtime image
    /// dynamic, so the new pixels are never held back by the static cache.
    ///
    /// Returns false only when there is nowhere to publish to yet, which is
    /// what makes the caller hold the payload until there is.
    bool applySystemMediaArtworkPayload(const SystemMediaArtworkPayload& artwork) {
        if (m_scene == nullptr || m_scene->imageParser == nullptr) return false;

        auto* runtime_images = dynamic_cast<RuntimeImageSource*>(m_scene->imageParser.get());
        if (runtime_images == nullptr) return false;

        if (PublishSystemMediaArtwork(*runtime_images,
                                      artwork.width,
                                      artwork.height,
                                      artwork.rgba.data(),
                                      artwork.rgba.size())) {
            // New pixels are a real state change, so an idle scene has to be
            // told; the frame clock decides when, and the FPS ceiling bounds
            // it. An unchanged cover asks for nothing.
            requestFrame();
        }
        return true;
    }
    /// Records `json` as the latest event of its type, keeping the order the
    /// types first arrived so a replay reaches a script in the same sequence a
    /// live session would.
    void retainMediaEvent(const std::string& json) {
        const auto parsed = nlohmann::json::parse(json, nullptr, false);
        if (parsed.is_discarded() || ! parsed.is_object()) return;
        const auto type = parsed.find("type");
        if (type == parsed.end() || ! type->is_string()) return;
        const auto name = type->get<std::string>();
        for (auto& retained : m_pending_media_events) {
            if (retained.first == name) {
                retained.second = json;
                return;
            }
        }
        // An unbounded set of types would be a leak; the protocol has five and
        // a wallpaper that invents more does not get to grow this forever.
        if (m_pending_media_events.size() >= 16) return;
        m_pending_media_events.emplace_back(name, json);
    }

    /// Replays what is playing to a scene that has just been attached.
    void replayMediaEvents() {
        if (! m_media_integration_enabled || m_scene == nullptr || m_scene->runtime == nullptr)
            return;
        for (const auto& [name, json] : m_pending_media_events) {
            m_scene->runtime->DispatchMediaEventJson(json);
        }
    }
    /// Publishes the display's pixel resolution to the scene's scripts.
    ///
    /// `RenderInitInfo::width`/`height` are already physical pixels -- the host
    /// fills them from `DisplayDesc`, and both backends divide by
    /// `display_scale_factor` when they want logical points -- so they are
    /// published as they are. Not the render size: internal quality may halve
    /// that, and a quality setting must not move a script's layout.
    void publishScreenResolution() {
        if (m_scene == nullptr || m_scene->runtime == nullptr) return;
        if (m_render_init_info == nullptr) return;
        m_scene->runtime->SetScreenResolution(
            Eigen::Vector2f(static_cast<float>(m_render_init_info->width),
                            static_cast<float>(m_render_init_info->height)));
    }

    MHANDLER_CMD(STOP) {
        bool stop { false };
        if (msg->findBool("value", &stop)) {
            if (renderInited()) {
                m_render->SetVideoPlaybackPaused(stop || m_render_blocked);
                // The first frame after a resume presents, even if it repeats
                // the last picture: the surface may have been shown something
                // else while this wallpaper was stopped.
                if (! stop) m_render->InvalidatePresentedFrame();
            }
            m_clock_requested = ! stop;
            syncFrameClock();
            refreshFrameDemand();
            publishPauseReasons();
        }
    }
    MHANDLER_CMD(DRAW) {
        if (m_render_blocked) {
            // The tick that posted this draw still counted; the work it asked
            // for did not happen, and that difference is the whole point.
            counters.Add(OWE_RC_DRAWS_DROPPED);
            return;
        }
        counters.Add(OWE_RC_DRAWS_EXECUTED);
        frame_timer.FrameBegin();
        if (m_rg) {
            const double frame_time = frame_timer.IdeaTime() * m_speed;
            // LOG_INFO("frame info, fps: %.1f, frametime: %.1f", 1.0f, 1000.0f*m_scene->frameTime);
            m_scene->shaderValueUpdater->FrameBegin();
            {
                auto pos = m_mouse_pos.load();
                if (m_horizontal_flip) {
                    pos[0] = 1.0f - pos[0];
                }
                m_scene->pointerPosition = pos;
                m_scene->shaderValueUpdater->MouseInput(pos[0], pos[1]);
                const MouseButtonSnapshot buttons = consumeMouseButtonSnapshot();
                // A click released before this frame ran still held the button
                // for it, so shaders see the press at least once.
                m_scene->shaderValueUpdater->MouseButtonsInput(buttons.down | buttons.pressed);
                if (m_scene->runtime != nullptr) {
                    const auto mapping = m_render->CursorMapping(*m_scene);
                    if (mapping.valid) {
                        m_scene->runtime->SetCursorViewport(CursorViewport {
                            .origin = Eigen::Vector2f(static_cast<float>(mapping.origin_x),
                                                      static_cast<float>(mapping.origin_y)),
                            .size   = Eigen::Vector2f(static_cast<float>(mapping.size_x),
                                                    static_cast<float>(mapping.size_y)),
                            .content_origin =
                                Eigen::Vector2f(static_cast<float>(mapping.content_origin_x),
                                                static_cast<float>(mapping.content_origin_y)),
                            .content_size =
                                Eigen::Vector2f(static_cast<float>(mapping.content_size_x),
                                                static_cast<float>(mapping.content_size_y)),
                        });
                    }
                    m_scene->runtime->SetCursorInput(pos[0], pos[1]);
                    m_scene->runtime->SetCursorEnter(m_cursor_in_window.load());
                    m_scene->runtime->SetCursorButtons(
                        buttons.down, buttons.pressed, buttons.released);
                    m_cursor_was_in_window =
                        m_scene->runtime->DispatchCursorFrameEvents(m_cursor_was_in_window);
                }
            }
            m_scene->paritileSys->Emitt();
            bool frame_ok = true;
            if (m_scene->runtime != nullptr) {
                m_scene->runtime->Tick(frame_time);
                m_scene->runtime->PumpTextLayerCache();
                // After the tick that produced them, and on the main looper
                // rather than here: what a press means is the host's to decide,
                // and deciding it must never sit in front of a frame.
                for (const auto& [name, value] : m_scene->runtime->TakeUserShortcutRequests()) {
                    main_handler.sendUserShortcut(name, value);
                }
                if (m_scene->runtime->ConsumeSceneGraphMutationFlag()) {
                    frame_ok = rebuildRenderGraph();
                }
            }

            // Optional programs, asked for at a frame boundary and never
            // waited for. The setting is process-wide and arrives without a
            // message, so this is where a user who has just turned it on is
            // noticed; a program already compiled, already in flight or already
            // refused is not asked for again, so the ordinary case is a walk
            // over a short list and nothing else. The wallpaper draws with the
            // programs it already has meanwhile.
            if (frame_ok && m_scene != nullptr) {
                RequestSceneMetalVariants(
                    *m_scene,
                    m_render->hasBackend() && m_render->backend() == SceneBackend::NativeMetal &&
                        metal::MetalVideoPlaneSamplingEnabled(),
                    m_shader_cache_path);
            }

            // At the frame boundary, before the frame is drawn: the setting is
            // process-wide and arrives without a message, so a change is
            // noticed here rather than waited for until the graph is next
            // compiled. Nothing is reparsed, no video is reopened and no
            // timeline is reset; the copy plan, the targets it governs and the
            // reuse table are rebuilt from the graph that is already compiled.
            if (frame_ok && m_scene != nullptr && m_rg) {
                const bool optimization = vulkan::SceneOptimizationEnabled();
                if (optimization !=
                    m_scene_optimization_applied.load(std::memory_order_relaxed)) {
                    if (m_render->ApplySceneOptimization(*m_scene, *m_rg)) {
                        m_scene_optimization_applied.store(optimization,
                                                           std::memory_order_relaxed);
                    } else {
                        LOG_ERROR("scene optimisation change failed, rebuilding render graph");
                        frame_ok = rebuildRenderGraph();
                        m_scene_optimization_applied.store(optimization,
                                                           std::memory_order_relaxed);
                    }
                }
            }

            // Tick, above, is what finalizes visibility for this frame,
            // including a script that shows a layer Emitt thought was hidden.
            // Rebuild only the meshes that skip left stale, from the
            // simulation Emitt already advanced; neither backend draws yet.
            if (frame_ok && m_scene->paritileSys != nullptr) {
                m_scene->paritileSys->RebuildVisibleMeshes();
            }

            bool presented = false;
            // A failure from here on belongs to the draw; one before it came
            // from building the graph, which has already said so.
            const bool reached_draw = frame_ok;
            if (frame_ok) {
                frame_ok = m_render->drawFrame(*m_scene, &presented);
                // A native frame can fail after the graph compiled -- a video
                // texture that stops decoding, a copy that cannot be encoded.
                // Suspending would leave that wallpaper black; the scene is
                // handed to the compatibility backend as a whole instead, and
                // the failure is remembered so it does not flip back.
                if (! frame_ok && m_render->hasBackend() &&
                    m_render->backend() == SceneBackend::NativeMetal) {
                    frame_ok = fallBackToCompatibility() && rebuildRenderGraph() &&
                               m_render->drawFrame(*m_scene, &presented);
                }
            }
            if (frame_ok) {
                m_video_path.store(static_cast<uint8_t>(m_render->VideoPath()),
                                   std::memory_order_relaxed);
                m_scene->PassFrameTime(frame_time);
                counters.Add(OWE_RC_SIMULATION_TICKS);
                // Completed, not presented: a frame that would repeat the
                // picture returns success without reaching the surface, and a
                // healthy still scene must keep this number moving.
                m_health.NoteFrameCompleted();
                if (presented) m_health.NotePresented();
            } else {
                failFrame(reached_draw);
            }

            m_scene->shaderValueUpdater->FrameEnd();
            // fps_counter.RegisterFrame();

            // The edge the host waits on, so it is taken from a frame that
            // actually reached the surface. A tick that succeeded without
            // presenting -- no drawable was free -- is not that frame, and
            // claiming it would start the wallpaper on whatever was there
            // before.
            if (frame_ok && presented && ! m_scene->first_frame_ok) {
                m_scene->first_frame_ok = true;
                main_handler.sendFirstFrameOk();
            }
        }
        frame_timer.FrameEnd();
        refreshFrameDemand();
    }
    MHANDLER_CMD(SET_FILLMODE) {
        int32_t value;
        if (msg->findInt32("value", &value)) {
            m_fillmode          = (FillMode)value;
            m_fillmode_explicit = true;
            if (m_scene && renderInited()) {
                m_render->UpdateCameraFillMode(*m_scene, m_fillmode);
            }
        }
    }
    MHANDLER_CMD(SET_SCALINGMODE) {
        int32_t value;
        if (msg->findInt32("value", &value)) {
            m_scalingmode = static_cast<WallpaperScalingMode>(value);
            if (renderInited()) {
                m_render->SetWallpaperScalingMode(m_scalingmode);
            }
        }
    }
    MHANDLER_CMD(SET_SCALINGFACTOR) {
        float value;
        if (msg->findFloat("value", &value)) {
            m_scalingfactor = value;
            if (renderInited()) {
                m_render->SetWallpaperScalingFactor(m_scalingfactor);
            }
        }
    }
    MHANDLER_CMD(SET_FRAMING) {
        std::shared_ptr<WallpaperFraming> value;
        if (msg->findObject("value", &value) && value != nullptr) {
            m_framing = NormalizeWallpaperFraming(*value);
            if (renderInited()) {
                m_render->SetWallpaperFraming(m_framing);
            }
        }
    }
    MHANDLER_CMD(SET_RENDER_SCALE) {
        float value { 1.0f };
        if (msg->findFloat("value", &value)) {
            m_render_scale = value;
            // The 2D scene resolution is a process-wide choice with no message
            // of its own: the host re-pushes the render scale to every open
            // scene when the choice changes, and this is where a running scene
            // takes it, resizing in place exactly as it does for a new scale.
            const auto resolution = CurrentSceneResolution();
            if (renderInited() && m_scene != nullptr && m_rg) {
                if (! m_render->ApplyRenderScale(*m_scene, *m_rg, m_render_scale, resolution)) {
                    // A failed resize leaves the passes unprepared, so fall back
                    // to the full graph rebuild rather than presenting nothing.
                    LOG_ERROR("render scale change failed, rebuilding render graph");
                    rebuildRenderGraph();
                }
            } else if (m_scene != nullptr) {
                m_scene->render_scale = value;
                m_scene->resolution   = resolution;
            }
        }
    }
    MHANDLER_CMD(SET_HORIZONTAL_FLIP) {
        bool value { false };
        if (msg->findBool("value", &value)) {
            m_horizontal_flip = value;
            if (renderInited()) {
                m_render->SetWallpaperHorizontalFlip(m_horizontal_flip);
            }
        }
    }
    MHANDLER_CMD(SET_AUDIO_RESPONSE_ENABLED) {
        bool enabled { false };
        if (msg->findBool("value", &enabled)) {
            if (m_scene != nullptr && m_scene->runtime != nullptr) {
                m_scene->runtime->SetAudioResponseEnabled(enabled);
            }
        }
    }
    MHANDLER_CMD(SET_MEDIA_INTEGRATION_ENABLED) {
        bool enabled { false };
        if (msg->findBool("value", &enabled)) {
            m_media_integration_enabled = enabled;
            // Consent withdrawn drops what was retained; nothing is replayed to
            // a wallpaper whose user turned this off.
            if (! enabled) {
                m_pending_media_events.clear();
                m_pending_system_media_artwork.reset();
            }
            if (m_scene != nullptr && m_scene->runtime != nullptr) {
                m_scene->runtime->SetMediaIntegrationEnabled(enabled);
            }
        }
    }
    MHANDLER_CMD(MEDIA_EVENT_JSON) {
        if (! m_media_integration_enabled) return;

        std::string json;
        if (! msg->findString("value", &json)) return;
        retainMediaEvent(json);
        if (m_scene == nullptr || m_scene->runtime == nullptr) return;
        m_scene->runtime->DispatchMediaEventJson(json);
    }
    MHANDLER_CMD(SYSTEM_MEDIA_ARTWORK) {
        std::shared_ptr<SystemMediaArtworkPayload> artwork;
        if (! msg->findObject("artwork", &artwork) || artwork == nullptr)
            return;
        if (! applySystemMediaArtworkPayload(*artwork)) {
            m_pending_system_media_artwork = *artwork;
        } else {
            m_pending_system_media_artwork.reset();
        }
    }
    MHANDLER_CMD(SET_SCENE) {
        std::shared_ptr<Scene> scene;
        if (msg->findObject("scene", &scene)) {
            // Absent on the test entry point, which has no cache: the variant
            // path then keeps its result in memory for this process only.
            std::string cache_path;
            m_shader_cache_path = msg->findString("cache_path", &cache_path) ? cache_path
                                                                            : std::string {};
            // Compiled pipelines live beside this scene's translated shaders,
            // in the same regenerable store, so clearing one clears both and
            // neither is ever mistaken for something the user imported. Set on
            // this surface's renderer rather than process-wide: another display
            // may be showing a different wallpaper with its own cache.
            m_render->SetPipelineArchivePath(m_shader_cache_path);
            // Whatever optional work the wallpaper being replaced had queued is
            // dropped here. A compile already inside the shader compiler is not
            // interrupted -- nothing can interrupt it -- but its result belongs
            // to a program this process is about to stop drawing with, and it
            // goes away with the scene that owned it.
            CancelSceneMetalVariants();
            // A graph that never reached a backend owns nothing to release;
            // refusing the next scene over it would leave the surface holding
            // a scene nobody can replace.
            if (m_rg && m_render->hasBackend() && ! m_render->clearLastRenderGraph()) {
                suspendAfterGraphFailure();
                return;
            }
            m_rg.reset();
            // What the last scene could not preview says nothing about this one.
            m_logged_deferred_properties.clear();
            // The outgoing scene's own late marks must not reach the host; the
            // generation check drops any already in flight.
            if (m_scene != nullptr && m_scene->runtime != nullptr) {
                m_scene->runtime->SetAudioRequirementListener({});
            }
            const bool previous_accepts_pointer_input =
                m_scene == nullptr || m_scene->accepts_pointer_input;
            const bool accepts_pointer_input = scene == nullptr || scene->accepts_pointer_input;
            {
                std::scoped_lock lock(m_mouse_buttons_mutex);
                m_scene = std::move(scene);
                if (!previous_accepts_pointer_input || !accepts_pointer_input) {
                    m_mouse_buttons.pressed  = 0;
                    m_mouse_buttons.released = 0;
                }
            }
            commitAudioRequirement();
            main_handler.sendPointerInputCapability(accepts_pointer_input);
            clearRenderBlock();
            // Before the backend is chosen: creating one re-applies the video
            // pause from whether the clock runs.
            syncFrameClock();
            publishPauseReasons();
            if (m_scene != nullptr && m_scene->runtime != nullptr) {
                m_scene->runtime->SetMediaIntegrationEnabled(m_media_integration_enabled);
                // Before the graph is built, so a script that reveals a layer
                // on `mediaPlaybackChanged` has done it by the first frame
                // rather than one event later, and so a script that sizes
                // itself against the screen has the real one to size against.
                publishScreenResolution();
                replayMediaEvents();
                installContentWake(*m_scene);
            }
            selectSceneBackend();
            // A scene that just arrived has no graph at all — `m_rg` was reset
            // above — so one is always built here. The pending cover is only
            // pixels: publishing it first means the compile below already binds
            // the right image, and it no longer decides whether the graph gets
            // built, which is what it used to do by rebuilding as a side
            // effect.
            if (m_pending_system_media_artwork.has_value() &&
                applySystemMediaArtworkPayload(*m_pending_system_media_artwork)) {
                m_pending_system_media_artwork.reset();
            }
            if (! m_render_blocked && ! rebuildRenderGraph()) return;
        }
    }
    MHANDLER_CMD(SET_SPEED) {
        if (msg->findFloat("value", &m_speed) && renderInited()) {
            m_render->SetVideoPlaybackRate(m_speed);
            // Speed maps the content's own timeline onto the wall clock, so the
            // tick rate a video needs changes with it.
            refreshFrameDemand();
        }
    }
    /// Shows the newest staged property document on the scene that is running,
    /// without loading it again. Runs here because this thread is the only one
    /// that ticks the runtime, so the runtime needs no lock for it.
    ///
    /// Nothing is remembered for a later scene: a scene committed afterwards
    /// shows its own loaded values until the host sends the next document, so a
    /// document for one wallpaper can never reach another by sharing a property
    /// name. A document that finds no scene, or a scene without a runtime (a
    /// plain video), is dropped.
    ///
    /// What a changed property shows needs nothing more from here. The command
    /// asks for a frame like every command but the draw, so an idle scene
    /// takes one and a paused one shows it when it resumes; that frame's tick
    /// applies the bindings, and a layer the document reveals that the graph
    /// left out asks for one new graph there (`RequestGraphForShownLayers`).
    MHANDLER_CMD(APPLY_PROJECT_PROPERTIES) {
#ifdef WESCENE_BUILD_TESTS
        m_property_preview_commands.fetch_add(1, std::memory_order_relaxed);
#endif
        std::optional<ProjectProperties> document;
        {
            std::scoped_lock lock(m_property_preview_mutex);
            document = std::move(m_property_preview);
            m_property_preview.reset();
        }
        if (! document.has_value()) return;
        if (m_scene == nullptr || m_scene->runtime == nullptr) return;
        const auto preview = m_scene->runtime->PreviewProjectPropertyOverride(*document);
        // Said when the set of properties the scene could not apply changes, not
        // on every edit: a drag sends many documents that all defer the same few.
        if (preview.deferred != m_logged_deferred_properties) {
            m_logged_deferred_properties = preview.deferred;
            if (! preview.deferred.empty()) {
                std::string names;
                for (const auto& name : preview.deferred) {
                    names += (names.empty() ? "" : ", ") + name;
                }
                LOG_INFO("property preview: held at the loaded value until the scene loads "
                         "again: %s",
                         names.c_str());
            }
        }
    }
    /// Takes over a surface description. No GPU backend is created here.
    ///
    /// Which backend this surface needs is decided from the parsed scene, so
    /// building a Vulkan device and swapchain now would mean tearing them down
    /// again the moment the scene turns out to want the native one. The name is
    /// kept because it is part of the host-facing message vocabulary.
    MHANDLER_CMD(INIT_VULKAN) {
        std::shared_ptr<RenderInitInfo> info;
        if (! msg->findObject("info", &info) || info == nullptr) return;

        adoptRenderInitInfo(std::move(info));
        clearRenderBlock();
        // A surface this wallpaper is already running on can be replaced when
        // the display changes, so the resolution is republished here too.
        publishScreenResolution();

        // Offscreen surfaces and surfaces with no layer have no native option
        // at all, so there is nothing to wait for: the probe and test paths
        // keep behaving exactly as they did.
        if (m_render_init_info->offscreen || m_render_init_info->metal_layer == nullptr) {
            if (! m_render->createVulkan(*m_render_init_info)) {
                suspendAfterGraphFailure();
                return;
            }
            setSceneBackendSelection(SceneBackendSelection { SceneBackend::LegacyVulkan, {} });
            reapplySurfaceState();
        }

        main_handler.sendCmdLoadScene();
        publishPauseReasons();
    }
    /// Completes a desktop poster request that arrived from outside the clock.
    ///
    /// Deliberately does not touch the clock or scene time: a wallpaper the
    /// user paused stays paused, and an idle one is sampled rather than
    /// re-simulated. The single frame this may need is the one the generic
    /// post-command `requestFrame()` already asks for, and that request is
    /// dropped while the clock is stopped.
    MHANDLER_CMD(POSTER_REQUEST) {
        // Nothing to service yet, or nothing valid to read back: the request
        // stays pending in the host's mailbox and the first drawn frame polls
        // it. `m_render_blocked` covers a surface mid-reconfigure; a wallpaper
        // the user merely paused is not blocked and is still sampled.
        if (! m_render->hasBackend() || m_scene == nullptr || m_render_blocked) return;
        // The Vulkan path can only answer from inside a frame, so the frame
        // already requested for this command is how it answers. While the user
        // has paused the wallpaper that request is dropped, and no poster is
        // exported — drawing behind the user's back would be worse.
        if (m_render->backend() != SceneBackend::NativeMetal) return;

        switch (m_render->ServicePosterRequest(*m_scene)) {
        case metal::PosterServiceResult::Failed:
            // Not a fallback: the scene still draws, only this export failed,
            // and the mailbox's own backoff decides when to try again.
            LOG_ERROR("desktop poster export failed: %s", m_render->lastError().c_str());
            break;
        case metal::PosterServiceResult::NoFrameYet:
        case metal::PosterServiceResult::NotRequested:
        case metal::PosterServiceResult::Submitted:
        case metal::PosterServiceResult::Busy:
            break;
        }
    }
#ifdef WESCENE_BUILD_TESTS
    /// What a draw that fails after the scene has drawn does, without needing
    /// the GPU to fail.
    MHANDLER_CMD(INJECT_FRAME_FAILURE) {
        failFrame(true);
        refreshFrameDemand();
    }
#endif
    MHANDLER_CMD(BEGIN_SURFACE_RECONFIGURE) {
        std::shared_ptr<std::promise<bool>> promise;
        if (! msg->findObject("promise", &promise) || promise == nullptr) {
            return;
        }
        try {
            suspendRendering();
            bool ok = true;
            if (renderInited()) {
                m_render->SetVideoPlaybackPaused(true);
                ok = m_render->releaseSurface();
            }
            promise->set_value(ok);
        } catch (...) {
            promise->set_value(false);
        }
    }
    MHANDLER_CMD(FINISH_SURFACE_RECONFIGURE) {
        std::shared_ptr<std::promise<bool>> promise;
        std::shared_ptr<RenderInitInfo>     info;
        if (! msg->findObject("promise", &promise) || promise == nullptr) {
            return;
        }
        suspendRendering();
        if (! msg->findObject("info", &info) || info == nullptr) {
            promise->set_value(false);
            return;
        }
        try {
            // A display change replaces the CAMetalLayer, so the retained info
            // has to be replaced with it: a later creation or fallback works
            // from this, and the old layer is gone.
            adoptRenderInitInfo(std::move(info));
            if (! m_render->hasBackend()) {
                // The scene has not chosen a backend yet, so there is no
                // surface to reset and no graph to compile. Replacing the info
                // is the whole job; the backend is created from it when the
                // scene lands.
                clearRenderBlock();
                syncFrameClock();
                refreshFrameDemand();
                publishPauseReasons();
                promise->set_value(true);
                return;
            }
            // A Metal surface that cannot take the new layer falls back here
            // rather than inside the holder, so the backend change is recorded
            // and published exactly once, by the routine that owns it.
            bool surface_ok = m_render->resetSurface(*m_render_init_info);
            if (! surface_ok) surface_ok = fallBackToCompatibility();
            const bool ok = surface_ok && rebuildRenderGraph();
            // The host asked for this stop; failing to end it is not the host's
            // doing. A graph that failed to rebuild has already said so.
            if (! ok) m_health.NoteGraphFailed();
            if (ok) {
                clearRenderBlock();
                // A paused wallpaper stays paused across a display change.
                syncFrameClock();
                m_render->SetVideoPlaybackPaused(! frame_timer.Running());
                refreshFrameDemand();
                publishPauseReasons();
            }
            promise->set_value(ok);
        } catch (...) {
            m_health.NoteGraphFailed();
            suspendRendering();
            promise->set_value(false);
        }
    }

public:
    FrameTimer       frame_timer;
    /// Whether the host wants this surface playing. The clock runs only while
    /// this holds and a scene is loaded; see `syncFrameClock`. Render thread.
    bool             m_clock_requested { true };
    FpsCounter       fps_counter;
    /// Handed to every scene's runtime so its text worker can ask for the frame
    /// that shows what it produced. Declared here, after `frame_timer`, so it
    /// is destroyed before the timer it points at.
    std::shared_ptr<ContentWakeTarget> m_content_wake { std::make_shared<ContentWakeTarget>() };
    /// The regenerable shader cache the current scene was loaded against.
    /// Delivered with the scene and read only on this thread.
    std::string m_shader_cache_path;
    /// Written by the frame clock, the render thread and the decode thread;
    /// read by whoever asks for a snapshot. The destructor stops the frame
    /// clock and destroys the renderer before any member is destroyed, so no
    /// writer outlives it.
    RendererCounters counters;

    /// Live update mode and the reasons behind it.
    ///
    /// Pull-only and always available: this is state a settings pane shows, so
    /// it must not depend on diagnostic counting being switched on. Reports
    /// `Continuous` with no reasons while on-demand updating is off, because
    /// that is then the literal truth rather than a placeholder.
    [[nodiscard]] SceneUpdateDemand::Kind sceneUpdateKind() const {
        return m_scene_update_kind.load(std::memory_order_relaxed);
    }
    [[nodiscard]] uint32_t sceneDemandReasons() const {
        return m_scene_demand_reasons.load(std::memory_order_relaxed);
    }

    /// Always-on frame-loop health; see `SurfaceHealth`. Written by the render
    /// thread, read by the host without one.
    [[nodiscard]] SurfaceHealthSnapshot surfaceHealth() const {
        return m_health.Snapshot();
    }

    /// Published by the render thread after each drawn frame, read by the host
    /// without one.
    [[nodiscard]] SceneVideoPath videoPath() const {
        return static_cast<SceneVideoPath>(m_video_path.load(std::memory_order_relaxed));
    }

    /// Whether this wallpaper's compiled graph is running under the current
    /// scene optimisation setting, as opposed to still carrying the plan the
    /// previous value produced.
    [[nodiscard]] bool sceneOptimizationApplied() const {
        return m_scene_optimization_applied.load(std::memory_order_relaxed) ==
               vulkan::SceneOptimizationEnabled();
    }

    /// Which renderer drew this scene. Published when the renderer is created,
    /// never before: until then `created` is false and the host reports that it
    /// is still preparing rather than naming a backend.
    [[nodiscard]] SceneBackendSelection sceneBackendSelection() const {
        std::scoped_lock lock(m_backend_selection_mutex);
        return m_backend_selection;
    }
    void setSceneBackendSelection(SceneBackendSelection selection) {
        // Every caller publishes a backend that exists, so the flag is set here
        // rather than at each site, where forgetting it would silently report
        // "preparing" for the rest of the wallpaper's life.
        selection.created = true;
        // Once per scene: the first thing to know about a wallpaper that looks
        // wrong is which renderer drew it, and why not the preferred one.
        LOG_INFO("scene backend: %s%s%s",
                 selection.backend == SceneBackend::NativeMetal ? "native_metal" : "legacy_vulkan",
                 selection.fell_back() ? "; fell back: " : "",
                 selection.fallback_reason.c_str());
        std::scoped_lock lock(m_backend_selection_mutex);
        m_backend_selection = std::move(selection);
    }

    /// Starts the just-committed scene's audio-requirement generation: the
    /// host hears `false` for a scene that has not (yet) marked itself, and
    /// then one `true` when it does -- at parse, at shader init or from a
    /// script, whichever comes first. The listener is installed before the
    /// flag is read so a mark racing the commit is reported by one or both.
    /// Scenes without a runtime (plain video projects) never mark.
    void commitAudioRequirement() {
        const uint64_t generation = ++m_audio_requirement_generation;
        bool           requires_audio { false };
        if (m_scene != nullptr && m_scene->runtime != nullptr) {
            m_scene->runtime->SetAudioRequirementListener(
                main_handler.audioRequirementReporter(generation));
            requires_audio = m_scene->runtime->SceneRequiresAudioResponse();
        }
        main_handler.sendAudioRequirement(generation, requires_audio);
    }

private:
    std::shared_ptr<Scene> m_scene { nullptr };
    /// Bumped on every scene commit; the main looper drops audio-requirement
    /// reports carrying an older one.
    uint64_t               m_audio_requirement_generation { 0 };
    float                  m_speed { 1.0f };

    std::unique_ptr<SceneRendererHandle> m_render;
    /// Retained from `INIT_VULKAN` so either backend can be created, or
    /// re-created, on the same surface once the choice is known.
    std::shared_ptr<RenderInitInfo>      m_render_init_info;
    std::unique_ptr<rg::RenderGraph>      m_rg { nullptr };
    bool                                m_render_blocked { false };
    /// Whether the frame loop is alive and why it stopped. Unlike the
    /// counters, never gated: a stop nobody can see cannot be told apart from
    /// a pause.
    SurfaceHealth                       m_health;

    FillMode                                 m_fillmode { FillMode::ASPECTFIT };
    bool                                     m_fillmode_explicit { false };
    WallpaperScalingMode                     m_scalingmode { WallpaperScalingMode::FIT };
    float                                    m_scalingfactor { 1.0f };
    /// Where the presented image sits in the slack around it. Held here, not
    /// in a backend, so it outlives a backend change, a surface rebuild and a
    /// graph rebuild like the scaling mode and factor beside it.
    WallpaperFraming                         m_framing {};
    /// Internal rasterization scale, independent of `m_scalingfactor`: that one
    /// scales the presented image on the output, this one only changes how many
    /// pixels the scene is drawn with.
    float                                    m_render_scale { 1.0f };
    /// The path the last drawn frame's video textures took, as the enumerator's
    /// underlying value so it can live in an atomic.
    std::atomic<uint8_t>                     m_video_path { 0 };
    /// The scene optimisation setting the compiled graph was last applied for.
    /// Starts matching the default so a wallpaper that never sees the setting
    /// change never rebuilds anything. Atomic because the render thread writes
    /// it and the host reads it to tell a saved preference apart from one that
    /// is actually in force.
    std::atomic<bool>                        m_scene_optimization_applied {
        vulkan::SceneOptimizationEnabled()
    };
    bool                                     m_horizontal_flip { false };
    bool                                     m_media_integration_enabled { false };
    std::optional<SystemMediaArtworkPayload> m_pending_system_media_artwork {};
    /// The latest media event of each type, in the order the types first
    /// arrived.
    ///
    /// A scene being rebuilt has no runtime for a moment, and that is exactly
    /// when the host replays what it knows: it replays because the handle is
    /// new. The artwork already survives that window by being parked here; the
    /// events describing what is playing did not, so a wallpaper whose cover
    /// group is revealed by `mediaPlaybackChanged` stayed blank until the user
    /// pressed pause and play again. Latest-per-type, because a burst of
    /// timeline updates is one fact repeated, not a queue to drain.
    std::vector<std::pair<std::string, std::string>> m_pending_media_events {};
    /// The newest property document waiting to be shown (see
    /// `stageProjectPropertyPreview`). Not part of the scene: it is taken by the
    /// command that was posted for it and never replayed.
    std::mutex                       m_property_preview_mutex;
    std::optional<ProjectProperties> m_property_preview {};
    /// The deferred names the last preview reported, to log a change of them
    /// once. Render thread only.
    std::vector<std::string>         m_logged_deferred_properties {};
#ifdef WESCENE_BUILD_TESTS
    /// How many property-preview commands this thread has handled, so a test
    /// can show that a burst of documents queues one command and not one each.
    std::atomic<uint64_t>            m_property_preview_commands { 0 };
#endif

    std::atomic<std::array<float, 2>> m_mouse_pos { std::array { 0.5f, 0.5f } };
    std::mutex                        m_mouse_buttons_mutex;
    MouseButtonSnapshot               m_mouse_buttons {};
    std::atomic<bool>                 m_cursor_in_window { false };
    bool                              m_cursor_was_in_window { false };
    /// Published for the host without enabling diagnostic counting: these are
    /// live state a settings pane reads, not instrumentation. Written on the
    /// render thread, read from whichever thread asks.
    std::atomic<SceneUpdateDemand::Kind> m_scene_update_kind {
        SceneUpdateDemand::Kind::Continuous
    };
    std::atomic<uint32_t> m_scene_demand_reasons { 0 };
    /// Whether any pass samples the pointer. Starts true so a scene whose
    /// graph has not been analysed still receives pointer events.
    std::atomic<bool>     m_scene_wants_pointer { true };
    /// Guards the backend selection, which holds a string and so cannot be an
    /// atomic. Written once at renderer creation, read by whoever asks.
    mutable std::mutex    m_backend_selection_mutex;
    SceneBackendSelection m_backend_selection {};
};
} // namespace wallpaper

SceneWallpaper::SceneWallpaper(): m_main_handler(std::make_shared<MainHandler>()) {}

SceneWallpaper::~SceneWallpaper() { shutdown(); }

bool SceneWallpaper::inited() const { return m_main_handler->inited(); }

bool SceneWallpaper::init() { return m_main_handler->init(); }

void SceneWallpaper::setLogScope(uint64_t scope) { m_main_handler->setLogScope(scope); }

void SceneWallpaper::shutdown() {
    if (m_main_handler != nullptr) {
        m_main_handler->shutdown();
    }
    // After the handlers, and before this process starts tearing down what the
    // background compile uses: a compile still running is waited for, because
    // it is writing into memory this process owns.
    ShutdownSceneMetalVariants();
}

#ifdef WESCENE_BUILD_TESTS
void SceneWallpaperInputTestAccess::PostScene(SceneWallpaper& wallpaper,
                                             std::shared_ptr<Scene> scene) {
    auto msg = CreateMsgWithCmd(wallpaper.m_main_handler->renderHandler(),
                               RenderHandler::CMD::CMD_SET_SCENE);
    msg->setObject("scene", std::move(scene));
    msg->post();
}

SceneWallpaperInputTestAccess::MouseButtonSnapshot
SceneWallpaperInputTestAccess::ConsumeMouseButtons(SceneWallpaper& wallpaper) {
    const auto snapshot =
        wallpaper.m_main_handler->renderHandler()->consumeMouseButtonSnapshot();
    return { snapshot.down, snapshot.pressed, snapshot.released };
}

uint64_t SceneWallpaperInputTestAccess::PropertyPreviewCommandsHandled(SceneWallpaper& wallpaper) {
    return wallpaper.m_main_handler->renderHandler()->m_property_preview_commands.load(
        std::memory_order_relaxed);
}

void SceneWallpaperInputTestAccess::InjectFrameFailure(SceneWallpaper& wallpaper) {
    CreateMsgWithCmd(wallpaper.m_main_handler->renderHandler(),
                     RenderHandler::CMD::CMD_INJECT_FRAME_FAILURE)
        ->post();
}

std::shared_ptr<Scene>
SceneWallpaperInputTestAccess::CreateVideoProjectScene(const std::string& project_json,
                                                       std::string*       error) {
    SceneSourceResolution resolution;
    if (! ResolveSceneSourcePaths(project_json, &resolution, error)) return nullptr;
    if (resolution.kind != SceneSourceResolutionKind::NotSceneProject ||
        resolution.manifest.type != WallpaperProjectType::Video) {
        SetError(error, "not a video project");
        return nullptr;
    }
    return ::CreateVideoProjectScene(std::make_unique<fs::VFS>(),
                                     std::filesystem::path(project_json),
                                     resolution.manifest,
                                     error);
}

std::shared_ptr<SceneNode>
SceneWallpaperInputTestAccess::CreateVideoProjectNode(const std::string& texture,
                                                      std::string*       error) {
    fs::VFS vfs;
    if (! InstallVirtualAssets(vfs)) {
        SetError(error, "failed to install runtime virtual assets for video project");
        return nullptr;
    }
    std::shared_ptr<SceneShader> shader;
    if (! BuildVideoCopyShader(vfs, "video-project-test", &shader, error)) return nullptr;
    return ::CreateVideoProjectNode(texture, shader);
}
#endif

void SceneWallpaper::initVulkan(const RenderInitInfo& info) {
    m_offscreen                             = info.offscreen;
    std::shared_ptr<RenderInitInfo> sp_info = std::make_shared<RenderInitInfo>(info);
    auto                            msg =
        CreateMsgWithCmd(m_main_handler->renderHandler(), RenderHandler::CMD::CMD_INIT_VULKAN);
    msg->setObject("info", sp_info);
    msg->post();
}

bool SceneWallpaper::beginSurfaceReconfigure() {
    if (m_main_handler == nullptr || m_main_handler->renderHandler() == nullptr) {
        return false;
    }
    auto promise = std::make_shared<std::promise<bool>>();
    auto future  = promise->get_future();
    auto msg     = CreateMsgWithCmd(m_main_handler->renderHandler(),
                                RenderHandler::CMD::CMD_BEGIN_SURFACE_RECONFIGURE);
    msg->setObject("promise", promise);
    msg->post();
    return future.get();
}

bool SceneWallpaper::finishSurfaceReconfigure(const RenderInitInfo& info) {
    if (m_main_handler == nullptr || m_main_handler->renderHandler() == nullptr) {
        return false;
    }
    auto promise = std::make_shared<std::promise<bool>>();
    auto future  = promise->get_future();
    auto sp_info = std::make_shared<RenderInitInfo>(info);
    auto msg     = CreateMsgWithCmd(m_main_handler->renderHandler(),
                                RenderHandler::CMD::CMD_FINISH_SURFACE_RECONFIGURE);
    msg->setObject("promise", promise);
    msg->setObject("info", sp_info);
    msg->post();
    return future.get();
}

void SceneWallpaper::applyConfig(const SceneWallpaperConfig& config) {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_APPLY_CONFIG);
    msg->setObject("config", std::make_shared<SceneWallpaperConfig>(config));
    msg->post();
}

void SceneWallpaper::play() {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_STOP);
    msg->setBool("value", false);
    msg->post();
}
void SceneWallpaper::pause() {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_STOP);
    msg->setBool("value", true);
    msg->post();
}

void SceneWallpaper::setPaused(bool paused) {
    if (paused) {
        pause();
        return;
    }
    play();
}

void SceneWallpaper::setSceneSource(std::string source) {
    setPropertyString(PROPERTY_SOURCE, std::move(source));
}

void SceneWallpaper::setAssetsPath(std::string assets) {
    setPropertyString(PROPERTY_ASSETS, std::move(assets));
}

void SceneWallpaper::setCachePath(std::string cache_path) {
    setPropertyString(PROPERTY_CACHE_PATH, std::move(cache_path));
}

void SceneWallpaper::setTargetFps(uint32_t fps) {
    setPropertyInt32(PROPERTY_FPS, static_cast<int32_t>(fps));
}

void SceneWallpaper::mouseInput(double x, double y) {
    m_main_handler->renderHandler()->setMousePos(x, y);
}

void SceneWallpaper::mouseButton(int button, bool pressed) {
    m_main_handler->renderHandler()->setMouseButton(button, pressed);
}

void SceneWallpaper::mouseButtonBaseline(uint32_t down) {
    m_main_handler->renderHandler()->setMouseButtonBaseline(down);
}

void SceneWallpaper::mouseEnter(bool entered) {
    m_main_handler->renderHandler()->setMouseInWindow(entered);
}

SceneUpdateDemand::Kind SceneWallpaper::sceneUpdateKind() const {
    if (m_main_handler == nullptr) return SceneUpdateDemand::Kind::Continuous;
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return SceneUpdateDemand::Kind::Continuous;
    return handler->sceneUpdateKind();
}

SurfaceHealthSnapshot SceneWallpaper::surfaceHealth() const {
    if (m_main_handler == nullptr) return SurfaceHealthSnapshot {};
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return SurfaceHealthSnapshot {};
    return handler->surfaceHealth();
}

SceneBackendSelection SceneWallpaper::sceneBackendSelection() const {
    if (m_main_handler == nullptr) return SceneBackendSelection {};
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return SceneBackendSelection {};
    return handler->sceneBackendSelection();
}

bool SceneWallpaper::sceneOptimizationApplied() const {
    if (m_main_handler == nullptr) return false;
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return false;
    return handler->sceneOptimizationApplied();
}

SceneVideoPath SceneWallpaper::sceneVideoPath() const {
    if (m_main_handler == nullptr) return SceneVideoPath::None;
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return SceneVideoPath::None;
    return handler->videoPath();
}

uint32_t SceneWallpaper::sceneDemandReasons() const {
    if (m_main_handler == nullptr) return static_cast<uint32_t>(SceneDemandReason::UnknownInput);
    auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return static_cast<uint32_t>(SceneDemandReason::UnknownInput);
    return handler->sceneDemandReasons();
}

void SceneWallpaper::applySystemMediaArtwork(uint32_t width, uint32_t height, const uint8_t* rgba,
                                             std::size_t rgba_len) {
    if (! IsValidSystemMediaArtwork(width, height, rgba, rgba_len)) return;

    auto artwork    = std::make_shared<SystemMediaArtworkPayload>();
    artwork->width  = width;
    artwork->height = height;
    artwork->rgba.resize(rgba_len);
    if (rgba_len != 0) std::memcpy(artwork->rgba.data(), rgba, rgba_len);

    auto msg = CreateMsgWithCmd(m_main_handler->renderHandler(),
                                RenderHandler::CMD::CMD_SYSTEM_MEDIA_ARTWORK);
    msg->setObject("artwork", artwork);
    msg->post();
}

#define BASIC_TYPE(NAME, TYPENAME)                                                       \
    void SceneWallpaper::setProperty##NAME(std::string_view name, TYPENAME value) {      \
        auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_SET_PROPERTY); \
        msg->setString("property", std::string(name));                                   \
        msg->set##NAME("value", value);                                                  \
        msg->post();                                                                     \
    }

BASIC_TYPE(Bool, bool);
BASIC_TYPE(Int32, int32_t);
BASIC_TYPE(Float, float);
BASIC_TYPE(String, std::string);
void SceneWallpaper::setPropertyObject(std::string_view name, std::shared_ptr<void> value) {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_SET_PROPERTY);
    if (! msg->setString("property", std::string(name)) || ! msg->setObject("value", value)) {
        throw std::runtime_error("failed to prepare object property message");
    }
    if (msg->post() != looper::status_t::OK) {
        throw std::runtime_error("failed to enqueue object property message");
    }
}

void SceneWallpaper::setFraming(const WallpaperFraming& framing) {
    // One object, so a reader of the render thread sees both axes change
    // together; normalised here so what travels is already in range.
    setPropertyObject(PROPERTY_FRAMING,
                      std::make_shared<WallpaperFraming>(NormalizeWallpaperFraming(framing)));
}

int SceneWallpaper::takeLastFrameSyncFd() {
    return m_main_handler->renderHandler()->takeLastFrameSyncFd();
}

ExSwapchain* SceneWallpaper::exSwapchain() const {
    return m_main_handler->renderHandler()->exSwapchain();
}

std::size_t SceneWallpaper::counters(uint64_t* out, std::size_t len) const {
    if (m_main_handler == nullptr) return 0;
    const auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return 0;
    return handler->counters.Snapshot(out, len);
}

MHANDLER_CMD_IMPL(MainHandler, LOAD_SCENE) {
    if (m_render_handler->renderSurfaceReady()) {
        loadScene();
    }
}

MHANDLER_CMD_IMPL(MainHandler, APPLY_CONFIG) {
    std::shared_ptr<SceneWallpaperConfig> config;
    if (! msg->findObject("config", &config) || config == nullptr) return;

    const bool paused      = config->paused;
    // Before the load, not only after it: loading mounts sound layers, and a
    // wallpaper that arrives paused must not start output for the moment
    // between the mount and the pause below.
    if (paused) m_sound_manager->Pause();
    const bool should_load = applyConfig(std::move(*config));
    if (should_load && m_render_handler != nullptr) CALL_MHANDLER_CMD(LOAD_SCENE, msg);
    setPaused(paused);
}

MHANDLER_CMD_IMPL(MainHandler, SET_PROPERTY) {
    std::string property;
    if (msg->findString("property", &property)) {
        if (property == PROPERTY_SOURCE) {
            msg->findString("value", &m_source);
            LOG_INFO("source: %s", m_source.c_str());
            CALL_MHANDLER_CMD(LOAD_SCENE, msg);
        } else if (property == PROPERTY_ASSETS) {
            msg->findString("value", &m_assets);
            CALL_MHANDLER_CMD(LOAD_SCENE, msg);
        } else if (property == PROPERTY_FPS) {
            int32_t fps { 0 };
            msg->findInt32("value", &fps);
            if (fps > 0) {
                m_render_handler->frame_timer.SetRequiredFps(
                    (u16)std::min<int32_t>(fps, UINT16_MAX));
            }
        } else if (property == PROPERTY_FILLMODE) {
            int32_t value;
            if (msg->findInt32("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_FILLMODE);
                nmsg->setInt32("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_SCALINGMODE) {
            int32_t value;
            if (msg->findInt32("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SCALINGMODE);
                nmsg->setInt32("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_SCALINGFACTOR) {
            float value;
            if (msg->findFloat("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SCALINGFACTOR);
                nmsg->setFloat("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_FRAMING) {
            std::shared_ptr<WallpaperFraming> value;
            if (msg->findObject("value", &value) && value != nullptr) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_FRAMING);
                nmsg->setObject("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_RENDER_SCALE) {
            float value { 1.0f };
            if (msg->findFloat("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_RENDER_SCALE);
                nmsg->setFloat("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_HORIZONTAL_FLIP) {
            bool value { false };
            if (msg->findBool("value", &value)) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_HORIZONTAL_FLIP);
                nmsg->setBool("value", value);
                nmsg->post();
            }
        } else if (property == PROPERTY_GRAPHIVZ) {
            msg->findBool("value", &m_gen_graphviz);
        } else if (property == PROPERTY_MUTED) {
            bool muted { false };
            msg->findBool("value", &muted);
            m_sound_manager->SetMuted(muted);
        } else if (property == PROPERTY_VOLUME) {
            float volume { 1.0f };
            msg->findFloat("value", &volume);
            m_sound_manager->SetVolume(volume);
        } else if (property == PROPERTY_AUDIO_RESPONSE_ENABLED) {
            bool enabled { false };
            msg->findBool("value", &enabled);
            m_audio_response_enabled = enabled;
            auto nmsg                = CreateMsgWithCmd(m_render_handler,
                                         RenderHandler::CMD::CMD_SET_AUDIO_RESPONSE_ENABLED);
            nmsg->setBool("value", enabled);
            nmsg->post();
        } else if (property == PROPERTY_MEDIA_INTEGRATION_ENABLED) {
            bool enabled { false };
            msg->findBool("value", &enabled);
            m_media_integration_enabled = enabled;
            if (m_render_handler != nullptr) {
                auto nmsg = CreateMsgWithCmd(m_render_handler,
                                             RenderHandler::CMD::CMD_SET_MEDIA_INTEGRATION_ENABLED);
                nmsg->setBool("value", enabled);
                nmsg->post();
            }
        } else if (property == PROPERTY_MEDIA_EVENT_JSON) {
            std::string json;
            if (msg->findString("value", &json) && m_media_integration_enabled &&
                m_render_handler != nullptr) {
                auto nmsg =
                    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_MEDIA_EVENT_JSON);
                nmsg->setString("value", json);
                nmsg->post();
            }
        } else if (property == PROPERTY_CACHE_PATH) {
            std::string path;
            msg->findString("value", &path);
            m_cache_path = path;
        } else if (property == PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON) {
            std::string json;
            msg->findString("value", &json);
            if (setProjectPropertyOverrideJson(std::move(json)) && m_render_handler != nullptr)
                CALL_MHANDLER_CMD(LOAD_SCENE, msg);
        } else if (property == PROPERTY_PROJECT_PROPERTY_RESET) {
            bool reset { false };
            msg->findBool("value", &reset);
            if (reset && resetProjectPropertyOverride()) {
                if (m_render_handler != nullptr) CALL_MHANDLER_CMD(LOAD_SCENE, msg);
            }
        } else if (property == PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON) {
            std::string json;
            if (msg->findString("value", &json) && m_render_handler != nullptr) {
                previewProjectProperties(json);
            }
        } else if (property == PROPERTY_FORCE_SHADER_REFRESH) {
            msg->findBool("value", &m_force_shader_refresh);
        } else if (property == PROPERTY_FIRST_FRAME_CALLBACK) {
            std::shared_ptr<FirstFrameCallback> cb;
            msg->findObject("value", &cb);
            m_first_frame_callback = *cb;
        } else if (property == PROPERTY_POINTER_INPUT_CALLBACK) {
            std::shared_ptr<PointerInputCallback> cb;
            if (msg->findObject("value", &cb) && cb != nullptr) {
                m_pointer_input_callback = std::move(*cb);
                if (m_pointer_input_callback) m_pointer_input_callback(m_accepts_pointer_input);
            }
        } else if (property == PROPERTY_USER_SHORTCUT_CALLBACK) {
            std::shared_ptr<UserShortcutCallback> cb;
            if (msg->findObject("value", &cb) && cb != nullptr) {
                m_user_shortcut_callback = std::move(*cb);
            }
        } else if (property == PROPERTY_AUDIO_REQUIREMENT_CALLBACK) {
            std::shared_ptr<AudioRequirementCallback> cb;
            if (msg->findObject("value", &cb) && cb != nullptr) {
                m_audio_requirement_callback = std::move(*cb);
                if (m_audio_requirement_callback) m_audio_requirement_callback(m_requires_audio);
            }
        } else if (property == PROPERTY_RENDER_FAILURE_CALLBACK) {
            std::shared_ptr<RenderFailureCallback> cb;
            if (msg->findObject("value", &cb) && cb != nullptr) {
                m_render_failure_callback = std::move(*cb);
            }
        } else if (property == PROPERTY_SPEED) {
            float speed { 1.0f };
            if (msg->findFloat("value", &speed)) {
                auto nmsg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SPEED);
                nmsg->setFloat("value", speed);
                nmsg->post();
            }
        }
    }
}

MHANDLER_CMD_IMPL(MainHandler, STOP) {
    bool stop { false };
    if (msg->findBool("value", &stop)) {
        setPaused(stop);
    }
}

MHANDLER_CMD_IMPL(MainHandler, FIRST_FRAME) {
    if (m_first_frame_callback) m_first_frame_callback();
}

MHANDLER_CMD_IMPL(MainHandler, USER_SHORTCUT) {
    std::string name;
    std::string value;
    // Both, or neither: a request with no property is not a request, and a
    // host told only the name would have to guess what its user chose.
    const bool has_request =
        msg->findString("property_name", &name) && msg->findString("property_value", &value);
    LOG_INFO("user shortcut reported: request=%d callback=%d name=%s value=\"%s\"",
             static_cast<int>(has_request), static_cast<int>(m_user_shortcut_callback != nullptr),
             name.c_str(), value.c_str());
    if (has_request && m_user_shortcut_callback) {
        m_user_shortcut_callback(name, value);
    }
}

MHANDLER_CMD_IMPL(MainHandler, POINTER_INPUT_CHANGED) {
    if (msg->findBool("accepts_pointer_input", &m_accepts_pointer_input) &&
        m_pointer_input_callback) {
        m_pointer_input_callback(m_accepts_pointer_input);
    }
}

MHANDLER_CMD_IMPL(MainHandler, AUDIO_REQUIREMENT_CHANGED) {
    std::shared_ptr<uint64_t> generation;
    bool                      requires_audio { false };
    if (! msg->findObject("generation", &generation) || generation == nullptr ||
        ! msg->findBool("requires_audio", &requires_audio)) {
        return;
    }
    // A report from a scene that has since been replaced says nothing about
    // the one now showing.
    if (*generation < m_audio_requirement_generation) return;
    // A newer generation is a new scene and starts from its own report; within
    // one scene the requirement only ever rises. A mark posted from another
    // thread may overtake its scene's commit message, so `true` can arrive
    // first and the commit's `false` must not lower it.
    const bool next = *generation > m_audio_requirement_generation
                          ? requires_audio
                          : (m_requires_audio || requires_audio);
    m_audio_requirement_generation = *generation;
    if (next == m_requires_audio) return;
    m_requires_audio = next;
    if (m_audio_requirement_callback) m_audio_requirement_callback(next);
}

MHANDLER_CMD_IMPL(MainHandler, RENDER_FAILED) {
    if (m_render_failure_callback) m_render_failure_callback();
}

bool MainHandler::applyConfig(SceneWallpaperConfig config) {
    bool should_load = false;

    if (m_source != config.source) {
        m_source = std::move(config.source);
        LOG_INFO("source: %s", m_source.c_str());
        should_load = true;
    }
    if (m_assets != config.assets) {
        m_assets    = std::move(config.assets);
        should_load = true;
    }
    if (m_cache_path != config.cache_path) {
        m_cache_path = std::move(config.cache_path);
        should_load  = true;
    }

    if (config.has_project_property_override) {
        should_load =
            setProjectPropertyOverrideJson(std::move(config.project_property_override_json)) ||
            should_load;
    } else {
        should_load = resetProjectPropertyOverride() || should_load;
    }

    m_force_shader_refresh = config.force_shader_refresh;
    if (m_force_shader_refresh) should_load = true;

    if (config.fps > 0) {
        m_render_handler->frame_timer.SetRequiredFps(
            (u16)std::min<uint32_t>(config.fps, UINT16_MAX));
    }

    return should_load;
}

void MainHandler::setPaused(bool paused) {
    if (paused) {
        m_sound_manager->Pause();
    } else {
        m_sound_manager->Play();
    }

    auto msg_r = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_STOP);
    msg_r->setBool("value", paused);
    msg_r->post();
}

bool MainHandler::setProjectPropertyOverrideJson(std::string json) {
    if (m_project_property_override_json == json) return false;
    m_project_property_override_json = std::move(json);
    return true;
}

bool MainHandler::resetProjectPropertyOverride() {
    if (m_project_property_override_json.empty()) return false;
    m_project_property_override_json.clear();
    return true;
}

void MainHandler::previewProjectProperties(const std::string& json) {
    ProjectProperties document;
    std::string       error;
    if (! ParseFlatProjectPropertyOverrideJson(json, &document, &error)) {
        LOG_ERROR("property preview ignored: %s", error.c_str());
        return;
    }
    // The saved override above is deliberately left alone: a preview is not a
    // choice, so a scene loaded again shows the saved look.
    if (! m_render_handler->stageProjectPropertyPreview(std::move(document))) return;
    // The slot was empty, so no command is on its way to take it; one is posted
    // now, and the documents that follow before it runs only replace the slot.
    CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_APPLY_PROJECT_PROPERTIES)->post();
}

void MainHandler::loadScene() {
    if (m_source.empty()) return;

    LOG_INFO("loading scene: %s", m_source.c_str());

    // The output device starts only once a sound layer or video audio track
    // mounts; a scene without sound never opens output IO.
    m_sound_manager->UnMountAll();

    std::shared_ptr<Scene> scene { nullptr };

    // mount assets dir
    std::unique_ptr<fs::VFS> pVfs = std::make_unique<fs::VFS>();
    auto&                    vfs  = *pVfs;
    SceneSourceResolution source_resolution;
    std::string           source_error;
    if (! ResolveSceneSourcePaths(m_source, &source_resolution, &source_error)) {
        LOG_ERROR("failed to resolve scene source %s: %s", m_source.c_str(), source_error.c_str());
        return;
    }
    if (source_resolution.kind != SceneSourceResolutionKind::Scene) {
        loadNonSceneProject(source_resolution.manifest, std::move(pVfs));
        return;
    }
    if (! vfs.IsMounted("assets")) {
        bool sus = vfs.Mount("/assets", fs::CreatePhysicalFs(m_assets), "assets");
        if (! sus) {
            LOG_ERROR("Mount assets dir failed");
            return;
        }
    }
    const auto& source_paths = source_resolution.scene_source;

    if (! MountSceneSource(vfs, source_paths, &source_error)) {
        LOG_ERROR("%s", source_error.c_str());
        return;
    }
    if (! m_cache_path.empty()) {
        if (! vfs.Mount("/cache", fs::CreatePhysicalFs(m_cache_path, true), "cache")) {
            LOG_ERROR("can't load cache folder: %s", m_cache_path.c_str());
        } else {
            LOG_INFO("cache folder: %s", m_cache_path.c_str());
        }
    }

    if (! InstallVirtualAssets(vfs)) {
        LOG_ERROR("failed to install virtual assets");
        return;
    }

    {
        std::string       scene_src;
        ProjectProperties project_properties;
        const std::string base { "/assets/" };
        {
            std::string scenePath = base + source_paths.pkg_entry;
            if (vfs.Contains(scenePath)) {
                auto f = vfs.Open(scenePath);
                if (f) scene_src = f->ReadAllStr();
            }
        }
        if (scene_src.empty()) {
            LOG_ERROR("Not supported scene type");
            return;
        }
        if (! ParseProjectProperties(m_source, &project_properties, &source_error)) {
            LOG_ERROR("failed to parse project properties %s: %s",
                      m_source.c_str(),
                      source_error.c_str());
            return;
        }
        // What the project declares, before the saved choices go over it: a
        // property the renderer is later told to drop returns to this value.
        const ProjectProperties authored_properties = project_properties;
        if (! m_project_property_override_json.empty()) {
            ProjectProperties override_properties;
            if (! ParseFlatProjectPropertyOverrideJson(
                    m_project_property_override_json, &override_properties, &source_error)) {
                LOG_ERROR("failed to parse project override json %s: %s",
                          m_source.c_str(),
                          source_error.c_str());
                return;
            }
            project_properties = MergeProjectProperties(project_properties, override_properties);
        }
        SceneParseRequest request {
            .scene_id           = source_paths.scene_id,
            .project_path       = m_source,
            .project_properties = &project_properties,
            .authored_project_properties = &authored_properties,
            .pkg_version        = ReadPkgVersionFromFile(source_paths.pkg_path),
        };
        scene = m_scene_parser.Parse(request, scene_src, vfs, *m_sound_manager);
        if (scene != nullptr && scene->runtime != nullptr) {
            scene->runtime->SetAudioResponseEnabled(m_audio_response_enabled);
            scene->runtime->SetMediaIntegrationEnabled(m_media_integration_enabled);
        }
        if (scene == nullptr) {
            LOG_ERROR("failed to parse scene: %s", m_source.c_str());
            return;
        }
        scene->vfs.swap(pVfs);
    }

    {
        auto msg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SCENE);
        msg->setObject("scene", scene);
        // Travels with the scene rather than being read across threads later:
        // the programs this scene holds were translated against this cache, and
        // a later variant of one of them has to be looked up in the same place.
        msg->setString("cache_path", m_cache_path);
        msg->post();
    }

    // draw first frame
    {
        auto msg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_DRAW);
        msg->post();
    }
}

bool MainHandler::loadNonSceneProject(const ProjectManifest&   manifest,
                                      std::unique_ptr<fs::VFS> vfs) {
    switch (manifest.type) {
    case WallpaperProjectType::Video: {
        std::string error;
        auto        scene = CreateVideoProjectScene(
            std::move(vfs), std::filesystem::path(m_source), manifest, &error);
        if (scene == nullptr) {
            LOG_ERROR("failed to load video wallpaper project: %s", error.c_str());
            return false;
        }

        std::filesystem::path media_path(manifest.file);
        if (media_path.is_relative()) {
            media_path = std::filesystem::path(m_source).parent_path() / media_path;
        }
        if (auto stream = audio::CreateFfmpegSoundStream(media_path, &error, {}, true); stream != nullptr) {
            m_sound_manager->MountStream(std::move(stream));
        } else if (!error.empty()) {
            LOG_ERROR("failed to create pure-video wallpaper audio stream: %s", error.c_str());
        }

        auto msg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_SET_SCENE);
        msg->setObject("scene", scene);
        msg->setString("cache_path", m_cache_path);
        msg->post();

        auto draw_msg = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_DRAW);
        draw_msg->post();
        return true;
    }
    case WallpaperProjectType::Web:
        LOG_ERROR("web wallpaper projects are not supported: %s", manifest.file.c_str());
        return false;
    case WallpaperProjectType::Unknown:
        LOG_ERROR("unsupported wallpaper project type for %s", m_source.c_str());
        return false;
    case WallpaperProjectType::Scene:
        LOG_ERROR("scene project was routed through the non-scene project path: %s",
                  m_source.c_str());
        return false;
    }

    return false;
}

void MainHandler::sendCmdLoadScene() {
    auto self = weak_from_this().lock();
    if (self == nullptr) {
        LOG_ERROR("skip load-scene dispatch because MainHandler no longer has shared ownership");
        return;
    }
    auto msg = CreateMsgWithCmd(self, MainHandler::CMD::CMD_LOAD_SCENE);
    msg->post();
}
void MainHandler::sendFirstFrameOk() {
    auto self = weak_from_this().lock();
    if (self == nullptr) {
        LOG_ERROR("skip first-frame dispatch because MainHandler no longer has shared ownership");
        return;
    }
    auto msg = CreateMsgWithCmd(self, MainHandler::CMD::CMD_FIRST_FRAME);
    msg->post();
}

void MainHandler::sendPointerInputCapability(bool accepts_pointer_input) {
    auto self = weak_from_this().lock();
    if (self == nullptr) return;
    auto msg = CreateMsgWithCmd(self, MainHandler::CMD::CMD_POINTER_INPUT_CHANGED);
    msg->setBool("accepts_pointer_input", accepts_pointer_input);
    msg->post();
}

void MainHandler::sendAudioRequirement(uint64_t generation, bool requires_audio) {
    auto self = weak_from_this().lock();
    if (self == nullptr) return;
    auto msg = CreateMsgWithCmd(self, MainHandler::CMD::CMD_AUDIO_REQUIREMENT_CHANGED);
    msg->setObject("generation", std::make_shared<uint64_t>(generation));
    msg->setBool("requires_audio", requires_audio);
    msg->post();
}

void MainHandler::sendRenderFailure() {
    auto self = weak_from_this().lock();
    if (self == nullptr) return;
    CreateMsgWithCmd(self, MainHandler::CMD::CMD_RENDER_FAILED)->post();
}

std::function<void()> MainHandler::audioRequirementReporter(uint64_t generation) {
    return [weak = weak_from_this(), generation] {
        auto self = std::static_pointer_cast<MainHandler>(weak.lock());
        if (self != nullptr) self->sendAudioRequirement(generation, true);
    };
}

void MainHandler::sendUserShortcut(std::string_view property_name,
                                   std::string_view property_value) {
    auto self = weak_from_this().lock();
    if (self == nullptr) return;
    auto msg = CreateMsgWithCmd(self, MainHandler::CMD::CMD_USER_SHORTCUT);
    msg->setString("property_name", std::string(property_name));
    msg->setString("property_value", std::string(property_value));
    msg->post();
}

bool MainHandler::init() {
    if (m_inited) return true;
    m_main_loop->setName("main");
    m_render_loop->setName("render");

    if (m_main_loop->start() != looper::status_t::OK) {
        LOG_ERROR("failed to start main looper");
        return false;
    }
    if (m_render_loop->start() != looper::status_t::OK) {
        LOG_ERROR("failed to start render looper");
        m_main_loop->stop();
        return false;
    }

    if (m_main_loop->registerHandler(shared_from_this()) == looper::Handler::INVALID_HANDLER_ID) {
        LOG_ERROR("failed to register main handler");
        m_render_loop->stop();
        m_main_loop->stop();
        return false;
    }
    if (m_render_loop->registerHandler(m_render_handler) == looper::Handler::INVALID_HANDLER_ID) {
        LOG_ERROR("failed to register render handler");
        m_main_loop->unregisterHandler(id());
        m_render_loop->stop();
        m_main_loop->stop();
        return false;
    }

    {
        auto  msg        = CreateMsgWithCmd(m_render_handler, RenderHandler::CMD::CMD_DRAW);
        auto& frameTimer = m_render_handler->frame_timer;
        frameTimer.SetCallback([msg]() {
            msg->post();
        });
        frameTimer.SetRequiredFps(30);
        // Not started here: the render handler starts it when a scene lands,
        // so a surface still parsing, or one whose load failed, has no clock.
    }

    m_inited = true;
    return true;
}

void MainHandler::shutdown() {
    if (! m_inited) return;

    m_sound_manager->Pause();

    if (m_render_handler != nullptr) {
        m_render_handler->frame_timer.Stop();
    }

    if (m_render_loop != nullptr && m_render_handler != nullptr &&
        m_render_handler->id() != looper::Handler::INVALID_HANDLER_ID) {
        m_render_loop->unregisterHandler(m_render_handler->id());
    }
    if (m_main_loop != nullptr && id() != looper::Handler::INVALID_HANDLER_ID) {
        m_main_loop->unregisterHandler(id());
    }

    if (m_render_loop != nullptr) m_render_loop->stop();
    if (m_main_loop != nullptr) m_main_loop->stop();

    m_inited = false;
}

MainHandler::MainHandler()
    : m_sound_manager(std::make_unique<audio::SoundManager>()),
      m_main_loop(std::make_shared<looper::Looper>()),
      m_render_loop(std::make_shared<looper::Looper>()),
      m_render_handler(std::make_shared<RenderHandler>(*this)) {
    // Playback runs until the host pauses it. Nothing starts here: the output
    // device opens on the first mounted channel and runs only while playing
    // and unmuted, so running is only the state a mount will see.
    m_sound_manager->Play();
}
