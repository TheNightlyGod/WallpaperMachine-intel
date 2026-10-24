// Clean-room implementation from the WallpaperMachine spec e1a-scene-host.md; written without access to the original source.
#include "SceneWallpaper.hpp"
#include "SceneRendererHandle.hpp"
#include "SceneBackendFaults.hpp"
#include "Surface/StillPreview.hpp"
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
#include "Audio/SoundStreamFactory.hpp"
#include "Video/VideoMedia.hpp"
#include "Video/VideoFramePacing.hpp"

#include "RenderGraph/RenderGraph.hpp"

#include "SpecTexs.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <string_view>
#include <cmath>
#include <condition_variable>
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

#include <unistd.h>

#include "RenderCommon/SceneRaster.hpp"

using namespace wallpaper;

#define CASE_CMD(cmd) \
    case CMD::CMD_##cmd: handle_##cmd(msg); break;
#define MHANDLER_CMD(cmd) void handle_##cmd(const std::shared_ptr<looper::Message>& msg)
#define MHANDLER_CMD_IMPL(cl, cmd) \
    void impl_##cl::handle_##cmd(const std::shared_ptr<looper::Message>& msg)
#define CALL_MHANDLER_CMD(cmd, msg) handle_##cmd(msg)

namespace
{
/// A message for `handler` that carries `cmd` under the key the dispatch of both handlers reads.
template<typename T>
std::shared_ptr<looper::Message> CreateMsgWithCmd(const std::shared_ptr<looper::Handler>& handler,
                                                  T cmd) {
    auto msg = looper::Message::create(0, handler);
    msg->setInt32("cmd", static_cast<int32_t>(cmd));
    return msg;
}

/// What a caller blocked on a render-thread surface command waits for. Completed by the handler
/// that ran the command, or with `false` by whoever drops the command unprocessed.
struct SurfaceTicket {
    std::mutex              mutex;
    std::condition_variable wake;
    bool                    done { false };
    bool                    result { false };

    void complete(bool value) {
        {
            std::scoped_lock lock(mutex);
            if (done) return;
            done   = true;
            result = value;
        }
        wake.notify_all();
    }
    bool wait() {
        std::unique_lock lock(mutex);
        wake.wait(lock, [this] { return done; });
        return result;
    }
};

/// Completes the ticket a command carried, with failure unless the handler said otherwise, on
/// every way out of the handler (an early return or an exception included).
class TicketGuard {
public:
    explicit TicketGuard(const std::shared_ptr<looper::Message>& msg) {
        msg->findObject("ticket", &m_ticket);
    }
    TicketGuard(const TicketGuard&)            = delete;
    TicketGuard& operator=(const TicketGuard&) = delete;
    ~TicketGuard() {
        if (m_ticket != nullptr) m_ticket->complete(m_result);
    }
    void succeed(bool value) { m_result = value; }

private:
    std::shared_ptr<SurfaceTicket> m_ticket;
    bool                           m_result { false };
};

/// Pixels of a media cover on their way to the render thread.
struct ArtworkPayload {
    uint32_t             width { 0 };
    uint32_t             height { 0 };
    std::vector<uint8_t> rgba;
};

/// Two normalised pointer axes in one 64-bit word, so a reader takes one sample of both.
uint64_t PackPointer(float x, float y) {
    uint32_t bx, by;
    std::memcpy(&bx, &x, sizeof(bx));
    std::memcpy(&by, &y, sizeof(by));
    return (static_cast<uint64_t>(bx) << 32) | by;
}
void UnpackPointer(uint64_t bits, float& x, float& y) {
    const auto bx = static_cast<uint32_t>(bits >> 32);
    const auto by = static_cast<uint32_t>(bits & 0xFFFFFFFFu);
    std::memcpy(&x, &bx, sizeof(x));
    std::memcpy(&y, &by, sizeof(y));
}

/// The version a package's leading tag names ("PKGV" then decimal digits to the end), or the
/// unknown value when the tag is anything else (R-H6).
uint16_t VersionFromPackageTag(std::string_view tag) {
    constexpr std::string_view kPrefix = "PKGV";
    if (tag.size() <= kPrefix.size() || tag.substr(0, kPrefix.size()) != kPrefix) {
        return SceneParseRequest::kUnknownPkgVersion;
    }
    const std::string_view digits = tag.substr(kPrefix.size());
    if (! std::all_of(digits.begin(), digits.end(),
                      [](char c) { return c >= '0' && c <= '9'; })) {
        return SceneParseRequest::kUnknownPkgVersion;
    }
    uint16_t value = 0;
    const auto [stop, status] = std::from_chars(digits.data(), digits.data() + digits.size(), value);
    if (status != std::errc {} || stop != digits.data() + digits.size()) {
        return SceneParseRequest::kUnknownPkgVersion;
    }
    return value;
}

/// The version of the package file at `path`, or the unknown value (R-H6).
uint16_t ReadPackageVersion(const std::string& path) {
    constexpr int32_t kLongestTag = 64;
    std::ifstream     in(path, std::ios::binary);
    int32_t           declared = 0;
    if (! in.read(reinterpret_cast<char*>(&declared), sizeof(declared))) {
        return SceneParseRequest::kUnknownPkgVersion;
    }
    if (declared < 1 || declared > kLongestTag) return SceneParseRequest::kUnknownPkgVersion;
    std::array<char, kLongestTag> field {};
    if (! in.read(field.data(), declared)) return SceneParseRequest::kUnknownPkgVersion;
    return VersionFromPackageTag(
        std::string_view(field.data(), static_cast<std::size_t>(declared)));
}

/// Whether `folder` can be written to.
bool IsWritableFolder(const std::string& folder) {
    return ::access(folder.c_str(), W_OK) == 0;
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
    bool inited() const { return m_inited.load(); }
    /// Runs `BEGIN_SURFACE_RECONFIGURE` (`begin`) or `FINISH_SURFACE_RECONFIGURE` on the render
    /// thread and waits for its verdict. False at once when no render thread is running, and
    /// false when the host shuts down while the command is waiting.
    bool runSurfaceCommand(bool begin, std::shared_ptr<RenderInitInfo> info);

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

    /// Asks for the scene to be loaded because surface hand-over `epoch` completed.
    void sendCmdLoadScene(uint64_t epoch);
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
    bool loadNonSceneProject(const ProjectManifest& manifest);

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
#ifdef WESCENE_BUILD_TESTS
    friend struct SceneWallpaperInputTestAccess;
#endif
    std::atomic<bool> m_inited { false };

    /// Guards `m_accepting` and `m_tickets`: whether commands that block may still be posted, and
    /// who is waiting for one.
    std::mutex                                  m_ticket_mutex;
    bool                                        m_accepting { false };
    std::vector<std::shared_ptr<SurfaceTicket>> m_tickets;

    /// Configuration as the control thread last stored it.
    /// The newest surface hand-over a load has already seen. Control thread.
    uint64_t                   m_loaded_epoch { 0 };
    std::string                m_source;
    std::string                m_assets;
    std::string                m_cache_path;
    /// The saved property document; empty means there is none.
    std::string                m_override_json;
    bool                       m_audio_response_enabled { false };
    bool                       m_media_integration_enabled { false };
    bool                       m_force_refresh { false };
    FirstFrameCallback         m_first_frame_callback;

    std::unique_ptr<audio::SoundManager> m_sound_manager;
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
using impl_MainHandler = MainHandler;

class RenderHandler : public looper::Handler {
public:
    /// Fixed width because commands cross the looper as an `int32_t`, so the
    /// cast back has to be defined for every value that can arrive.
    enum class CMD : int32_t
    {
        CMD_INIT_SURFACE,
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
        // The frame clock goes before the renderer: a tick that is still on its way would post a
        // draw for a handler that is going away.
        frame_timer.Stop();
        m_render->release();
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
                CASE_CMD(INIT_SURFACE);
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

    bool renderInited() const { return m_render->inited(); }

    /// Destroys the renderer, after the GPU work in flight has finished. For a handler whose
    /// thread has ended.
    void releaseRenderer() { m_render->release(); }

    /// Whether a surface has been handed over, whether or not a backend has
    /// been created on it yet.
    ///
    /// Scene loading is gated on this rather than on `renderInited()`: which
    /// backend a scene needs is read off the parsed scene, so waiting for a
    /// renderer before parsing would wait for something parsing has to produce.
    [[nodiscard]] bool renderSurfaceReady() const {
        // An atomic of its own: the control thread asks this while the render thread may be
        // replacing the description it describes.
        return m_surface_handed.load(std::memory_order_acquire);
    }

    /// How many surfaces have been handed over by `INIT_SURFACE`. Lets the
    /// control thread tell a hand-over that a load already answered from one it
    /// has yet to answer.
    [[nodiscard]] uint64_t surfaceEpoch() const {
        return m_surface_epoch.load(std::memory_order_acquire);
    }

    /// Tells the frame clock whether this scene's content is still changing: it
    /// keeps its configured cadence while it is, and waits for an event or a
    /// deadline once the scene proves it is still.
    ///
    /// Runs on the render thread; the frame clock only reads the value it
    /// stores.
    void refreshFrameDemand() {
        FrameTimer::FrameDemand demand {};

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

    /// Whether this scene still needs the clock, and why (R-H16, R-Q1 to R-Q4).
    ///
    /// Runs on the render thread after a frame. The inputs are classified once,
    /// by precedence; only a scene that is fully set up and has presented is
    /// analysed, and that analysis is one union of what keeps it moving.
    [[nodiscard]] SceneUpdateDemand evaluateSceneUpdateDemand() const {
        using Kind   = SceneUpdateDemand::Kind;
        using Reason = SceneDemandReason;
        enum class Standing { SwitchedOff, NotSetUp, NothingShownYet, Analysable };

        const Standing standing = ! SceneOnDemandEnabled()                      ? Standing::SwitchedOff
                                  : (m_scene == nullptr || ! renderInited() ||
                                     m_rg == nullptr)                           ? Standing::NotSetUp
                                  : ! m_scene->first_frame_ok                   ? Standing::NothingShownYet
                                                                                : Standing::Analysable;

        SceneUpdateDemand result {};
        result.kind = Kind::Continuous;
        switch (standing) {
        case Standing::SwitchedOff: result.reasons = 0; return result;
        case Standing::NotSetUp: result.reasons = static_cast<uint32_t>(Reason::UnknownInput); return result;
        case Standing::NothingShownYet:
            result.reasons = static_cast<uint32_t>(Reason::NoFrameYet);
            return result;
        case Standing::Analysable: break;
        }

        const Scene&   scene     = *m_scene;
        const uint32_t from_gpu  = SceneDemandReasonsFromShaderInputs(m_render->ShaderUpdateDemandReasons());
        const uint32_t from_logic = scene.runtime != nullptr
                                        ? scene.runtime->DescribeTimeAdvancingWork()
                                        : static_cast<uint32_t>(Reason::UnknownInput);
        const bool     emitting  = scene.paritileSys != nullptr && scene.paritileSys->HasEmitters();
        result.reasons = from_gpu | from_logic | (emitting ? static_cast<uint32_t>(Reason::Particles) : 0u);
        if (result.reasons == 0) result.kind = Kind::WaitingForEvent;
        return result;
    }

    /// Creates the renderer that draws this scene, and is the only place that
    /// does so for a scene.
    ///
    /// Runs once per scene, after the scene is parsed and before its graph is
    /// built, because whether the scene can be drawn depends on what it
    /// contains -- which is also why nothing is created before this point. The
    /// selection is published only once the renderer exists, so the host never
    /// names a renderer that is not drawing.
    void selectSceneBackend() {
        if (m_scene == nullptr || m_render_init_info == nullptr) return;

        auto selection = metal::SelectSceneBackend(*m_scene);
#ifdef WESCENE_BUILD_TESTS
        if (auto forced = testing::SceneBackendFaults::Instance().Consume(
                testing::SceneBackendFault::Admission)) {
            selection = metal::NativeRefusal(*forced);
        }
#endif

        // Refused, and nothing else may draw it instead. No renderer is
        // created: not another one, and not a native one that would only have
        // been torn down again.
        if (selection.failed()) {
            holdFailedScene(selection.failure_stage, selection.failure_reason);
            return;
        }

        // A renderer already driving this surface is reused: a wallpaper switch
        // invalidates the scene, not the device or the drawable loop, and
        // rebuilding one that works costs a visible gap for nothing.
        if (m_render->hasBackend() && m_render->inited()) {
            setSceneBackendSelection(selection);
            return;
        }
        std::string error;
        if (m_render->createMetal(*m_render_init_info, error)) {
            setSceneBackendSelection(selection);
            reapplySurfaceState();
            return;
        }
        // Prepare failed, and the handle is empty. Nothing else may draw the
        // scene, so the failure is held and reported with its reason.
        if (error.empty()) error = "the native renderer could not be prepared";
        holdFailedScene(SceneFailureStage::Prepare, error);
    }

    /// A scene that cannot be drawn with the native backend: nothing else may
    /// draw it, so the surface keeps what it shows, the failure is said once,
    /// and rendering stops. The picture on a layer that has already drawn is its
    /// last frame, which the layer holds on its own; a layer that has drawn
    /// nothing gets the project's preview picture instead of staying black.
    ///
    /// The host is told a first picture exists even then: it waits for one, and
    /// without it the activation would sit out the host's whole first-frame
    /// deadline and then put the previous wallpaper back, which is a rollback
    /// the user never asked for and a failure nobody can read.
    void holdFailedScene(SceneFailureStage stage, std::string reason) {
        // A refused scene must not be drawn by a renderer that is still alive
        // from the scene it replaced: the next surface rebuild would compile
        // the refused scene on it and draw it natively, which is the silent
        // drawing this policy exists to stop. The layer keeps the last picture
        // on its own, so releasing the renderer costs the held picture
        // nothing. (A failed prepare has already released it.)
        if (stage == SceneFailureStage::Unsupported) {
            m_render->release();
            m_rg.reset();
        }
        reportFailure(stage, std::move(reason));
        suspendAfterGraphFailure();
        settleFailedScene();
    }

    /// Latches the failure, publishes it to the host and logs it. Once per
    /// failure: the first reason is the root cause, and a retry that fails
    /// again is a new failure only after `clearFailure`.
    void reportFailure(SceneFailureStage stage, std::string reason) {
        if (m_failure_stage != SceneFailureStage::None) return;
        if (reason.empty()) reason = "the native renderer could not draw this wallpaper";
        m_failure_stage = stage;
        SceneBackendSelection selection;
        selection.failure_stage  = stage;
        selection.failure_reason = std::move(reason);
        setSceneBackendSelection(std::move(selection));
    }

    /// What a held failure leaves on the surface, and what the host is told.
    /// Safe to call again for the same failure.
    void settleFailedScene() {
        if (m_failure_stage == SceneFailureStage::None || m_scene == nullptr) return;
        showStillIfNothingDrawn();
        if (! m_failure_first_frame_sent && ! m_scene->first_frame_ok) {
            m_failure_first_frame_sent = true;
            main_handler.sendFirstFrameOk();
        }
    }

    /// The project's preview picture on a layer that has drawn nothing. A layer
    /// that has drawn keeps its last frame, so it is left exactly as it is.
    void showStillIfNothingDrawn() {
        if (m_layer_has_picture || m_scene == nullptr) return;
        if (m_render_init_info == nullptr || m_render_init_info->metal_layer == nullptr) return;
        const auto image = surface::FindPreviewImage(m_scene->project_path);
        if (image.empty()) {
            LOG_INFO("no preview picture to show for the wallpaper that cannot be drawn: %s",
                     m_scene->project_path.c_str());
            return;
        }
        std::string error;
        if (! m_still.Show(m_render_init_info->metal_layer, image, error)) {
            LOG_INFO("preview picture not shown: %s", error.c_str());
        }
    }

    /// The failure is over: a renderer is about to draw this scene again. The
    /// preview picture stays until a real frame replaces it, so a recovery
    /// never opens a black gap.
    void clearFailure() {
        if (m_failure_stage == SceneFailureStage::None) return;
        m_failure_stage = SceneFailureStage::None;
        std::scoped_lock lock(m_backend_selection_mutex);
        if (! m_backend_selection.failed()) return;
        m_backend_selection = SceneBackendSelection {};
        if (m_render->hasBackend()) m_backend_selection.created = true;
    }

    /// Re-applies the surface state a newly created renderer does not inherit.
    ///
    /// Creating a renderer produces an object that holds none of the scaling,
    /// flip, playback rate, pause or counter state the settings commands have
    /// already recorded, so every one of them has to be pushed again. Pause in
    /// particular: a wallpaper the user paused must not start playing because
    /// its renderer was created after the pause.
    void reapplySurfaceState() {
        m_render->SetCounters(&counters);
        m_render->SetWallpaperScalingMode(m_scaling_mode);
        m_render->SetWallpaperScalingFactor(m_scaling_factor);
        m_render->SetWallpaperHorizontalFlip(m_mirror);
        m_render->SetVideoPlaybackRate(m_speed);
        m_render->SetWallpaperFraming(m_framing);
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
        // Each axis on its own: one that is not a number leaves the stored one where it was.
        const auto unit = [](double v) { return static_cast<float>(std::clamp(v, 0.0, 1.0)); };
        uint64_t   seen = m_pointer_bits.load(std::memory_order_relaxed);
        for (;;) {
            float nx, ny;
            UnpackPointer(seen, nx, ny);
            if (std::isfinite(x)) nx = unit(x);
            if (std::isfinite(y)) ny = unit(y);
            if (m_pointer_bits.compare_exchange_weak(seen, PackPointer(nx, ny),
                                                     std::memory_order_relaxed)) {
                break;
            }
        }
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
        const uint32_t bit        = 1u << button;
        bool           transition = false;
        {
            std::scoped_lock lock(m_mouse_mutex);
            const bool       held = (m_mouse_buttons.down & bit) != 0;
            if (pressed && ! held) {
                m_mouse_buttons.down |= bit;
                m_mouse_buttons.pressed |= bit;
                transition = true;
            } else if (! pressed && held) {
                m_mouse_buttons.down &= ~bit;
                m_mouse_buttons.released |= bit;
                transition = true;
            }
        }
        if (transition) wakeForPointer();
    }
    void setMouseButtonBaseline(uint32_t down) {
        std::scoped_lock lock(m_mouse_mutex);
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
        std::scoped_lock    lock(m_mouse_mutex);
        const auto          taken = m_mouse_buttons;
        m_mouse_buttons.pressed   = 0;
        m_mouse_buttons.released  = 0;
        return taken;
    }

    void suspendRendering() {
        m_render_blocked = true;
        frame_timer.Stop();
        // Videos stop with the clock: nothing is drawn, so nothing may keep decoding.
        m_render->SetVideoPlaybackPaused(true);
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
        clearFailure();
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
        // A layer the display replaced carries nothing the old one drew, and
        // the preview picture went with the old one.
        if (m_render_init_info == nullptr || info == nullptr ||
            m_render_init_info->metal_layer != info->metal_layer) {
            m_layer_has_picture = false;
            m_still.Hide();
        }
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
        if (! m_render->hasBackend()) {
            // Nothing to compile on. Either a failure is already held, or no surface has reached
            // this scene yet and nothing failed: the surface only stops, and the hand-over that
            // comes later lifts the stop and loads again.
            m_rg.reset();
            if (m_failure_stage == SceneFailureStage::None) suspendAfterGraphFailure();
            return false;
        }
        if (m_rg != nullptr && ! m_render->clearLastRenderGraphForRebuild()) {
            m_rg.reset();
            suspendAfterGraphFailure();
            return false;
        }
        m_rg.reset();
        // Targets are allocated once, at the size they will keep.
        m_scene->render_scale = m_render_scale;
        m_scene->resolution   = CurrentSceneResolution();
        auto graph            = sceneToRenderGraph(*m_scene);
        if (graph == nullptr || ! m_render->compileRenderGraph(*m_scene, *graph)) {
            std::string reason = m_render->lastError();
            if (reason.empty() && graph == nullptr) reason = "the scene produced no render graph";
            holdFailedScene(SceneFailureStage::Compile, std::move(reason));
            return false;
        }
        m_rg = std::move(graph);
        m_render->SetWallpaperScalingMode(m_scaling_mode);
        m_render->SetWallpaperScalingFactor(m_scaling_factor);
        m_render->SetWallpaperFraming(m_framing);
        m_render->SetWallpaperHorizontalFlip(m_mirror);
        if (m_fill_explicit) m_render->UpdateCameraFillMode(*m_scene, m_fill_mode);
        m_render->SetVideoPlaybackRate(m_speed);
        if (m_scene->runtime != nullptr) {
            (void)m_scene->runtime->ConsumeSceneGraphMutationFlag();
            (void)m_scene->runtime->ConsumeRenderTargetResizeFlag();
        }
        // A graph is compiled under the optimisation setting that holds now.
        m_scene_optimization_applied.store(render::SceneOptimizationEnabled(),
                                           std::memory_order_relaxed);
        clearRenderBlock();
        m_render->SetVideoPlaybackPaused(! frame_timer.Running() || m_render_blocked);
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

    /// One frame of the committed scene: input sampled once, the simulation advanced once, graph
    /// changes applied, then the draw. Runs only with a scene, a compiled graph and a renderer.
    void runFrame() {
        Scene&       scene   = *m_scene;
        auto* const  updater = scene.shaderValueUpdater.get();
        auto* const  runtime = scene.runtime.get();
        const double step    = frame_timer.IdeaTime() * static_cast<double>(m_speed);

        // The one sample of this frame. The mirror applies after the clamp and before anything
        // stores or delivers the position.
        float px = 0.5f, py = 0.5f;
        UnpackPointer(m_pointer_bits.load(std::memory_order_relaxed), px, py);
        if (m_mirror) px = 1.0f - px;
        scene.pointerPosition = { px, py };
        const MouseButtonSnapshot buttons   = consumeMouseButtonSnapshot();
        const bool                in_window = m_cursor_in_window.load();

        if (updater != nullptr) {
            updater->MouseInput(px, py);
            updater->MouseButtonsInput(buttons.down | buttons.pressed);
            updater->FrameBegin();
        }

        if (runtime != nullptr) {
            const WallpaperCursorMapping mapping = m_render->CursorMapping(scene);
            if (mapping.valid) {
                CursorViewport viewport;
                viewport.origin = linalg::Vector2f(static_cast<float>(mapping.origin_x),
                                                   static_cast<float>(mapping.origin_y));
                viewport.size = linalg::Vector2f(static_cast<float>(mapping.size_x),
                                                 static_cast<float>(mapping.size_y));
                viewport.content_origin = linalg::Vector2f(
                    static_cast<float>(mapping.content_origin_x),
                    static_cast<float>(mapping.content_origin_y));
                viewport.content_size = linalg::Vector2f(
                    static_cast<float>(mapping.content_size_x),
                    static_cast<float>(mapping.content_size_y));
                runtime->SetCursorViewport(viewport);
            }
            runtime->SetCursorInput(px, py);
            runtime->SetCursorEnter(in_window);
            runtime->SetCursorButtons(buttons.down, buttons.pressed, buttons.released);
            m_cursor_was_in_window = runtime->DispatchCursorFrameEvents(m_cursor_was_in_window);
        }
        if (scene.paritileSys != nullptr) scene.paritileSys->Emitt();
        if (runtime != nullptr) {
            runtime->Tick(step);
            runtime->PumpTextLayerCache();
            for (const auto& request : runtime->TakeUserShortcutRequests()) {
                main_handler.sendUserShortcut(request.first, request.second);
            }
        }

        // What the advance asked of the graph, before the frame is drawn.
        bool ok = true;
        if (runtime != nullptr) {
            const bool mutated = runtime->ConsumeSceneGraphMutationFlag();
            const bool resized = runtime->ConsumeRenderTargetResizeFlag();
            if (mutated) {
                ok = rebuildRenderGraph();
            } else if (resized && ! m_render->ResizeRenderTargets(scene)) {
                ok = rebuildRenderGraph();
            }
        }
        if (ok) {
            // Never waited for: a program that has a variant, is compiling one or was refused
            // one is not asked again, and this frame draws with what it has.
            RequestSceneMetalVariants(scene, metal::MetalVideoPlaneSamplingEnabled(),
                                      m_shader_cache_path);
            if (m_scene_optimization_applied.load(std::memory_order_relaxed) !=
                render::SceneOptimizationEnabled()) {
                if (m_render->ApplySceneOptimization(scene, *m_rg)) {
                    m_scene_optimization_applied.store(render::SceneOptimizationEnabled(),
                                                       std::memory_order_relaxed);
                } else {
                    ok = rebuildRenderGraph();
                }
            }
        }
        if (! ok) {
            failFrame(false);
            if (updater != nullptr) updater->FrameEnd();
            return;
        }
        // Visibility is final only after the runtime tick, so a skipped rebuild is made up now.
        if (scene.paritileSys != nullptr) scene.paritileSys->RebuildVisibleMeshes();

        bool presented = false;
        if (! m_render->drawFrame(scene, &presented)) {
            reportFailure(SceneFailureStage::Frame, m_render->lastError());
            failFrame(true);
            settleFailedScene();
            if (updater != nullptr) updater->FrameEnd();
            return;
        }
        m_video_path.store(static_cast<uint8_t>(m_render->VideoPath()), std::memory_order_relaxed);
        scene.PassFrameTime(step);
        counters.Add(OWE_RC_SIMULATION_TICKS);
        m_health.NoteFrameCompleted();
        if (updater != nullptr) updater->FrameEnd();
        if (! presented) return;
        m_health.NotePresented();
        if (! m_layer_has_picture) {
            // The layer has a picture of its own now; the preview has nothing left to cover.
            m_layer_has_picture = true;
            m_still.Hide();
        }
        if (! scene.first_frame_ok) {
            scene.first_frame_ok = true;
            if (! m_failure_first_frame_sent) main_handler.sendFirstFrameOk();
        }
    }

    /// Replays what is playing to a scene that has just been attached.
    void replayMediaEvents() {
        if (! m_media_integration || m_scene == nullptr || m_scene->runtime == nullptr) return;
        for (const auto& retained : m_pending_media_events) {
            m_scene->runtime->DispatchMediaEventJson(retained.second);
        }
    }

    /// The runtime image source of the scene, when its images accept pixels from the host.
    [[nodiscard]] RuntimeImageSource* runtimeImages() const {
        if (m_scene == nullptr) return nullptr;
        return dynamic_cast<RuntimeImageSource*>(m_scene->imageParser.get());
    }

    /// Hands the parked cover to the scene when the scene can take it. Never rebuilds anything.
    void publishParkedArtwork() {
        if (! m_parked_artwork.has_value()) return;
        auto* images = runtimeImages();
        if (images == nullptr) return;
        PublishSystemMediaArtwork(*images, m_parked_artwork->width, m_parked_artwork->height,
                                  m_parked_artwork->rgba.data(), m_parked_artwork->rgba.size());
        m_parked_artwork.reset();
    }
    /// Publishes the display's pixel resolution to the scene's scripts.
    ///
    /// `RenderInitInfo::width`/`height` are already physical pixels -- the host
    /// fills them from `DisplayDesc`, and the renderer divides by
    /// `display_scale_factor` when they want logical points -- so they are
    /// published as they are. Not the render size: internal quality may halve
    /// that, and a quality setting must not move a script's layout.
    void publishScreenResolution() {
        if (m_scene == nullptr || m_scene->runtime == nullptr) return;
        if (m_render_init_info == nullptr) return;
        m_scene->runtime->SetScreenResolution(
            linalg::Vector2f(static_cast<float>(m_render_init_info->width),
                            static_cast<float>(m_render_init_info->height)));
    }

    MHANDLER_CMD(STOP) {
        bool paused = false;
        if (! msg->findBool("paused", &paused)) return;
        m_clock_requested = ! paused;
        // e1 R-R5: a resume forgets which frame was last presented.
        if (! paused) m_render->InvalidatePresentedFrame();
        syncFrameClock();
        m_render->SetVideoPlaybackPaused(! frame_timer.Running() || m_render_blocked);
        refreshFrameDemand();
        publishPauseReasons();
    }
    MHANDLER_CMD(DRAW) {
        (void)msg;
        if (m_render_blocked) {
            counters.Add(OWE_RC_DRAWS_DROPPED);
            return;
        }
        counters.Add(OWE_RC_DRAWS_EXECUTED);
        frame_timer.FrameBegin();
        if (m_scene != nullptr && m_rg != nullptr && renderInited()) runFrame();
        frame_timer.FrameEnd();
        refreshFrameDemand();
    }
    MHANDLER_CMD(SET_FILLMODE) {
        int32_t value = 0;
        if (! msg->findInt32("value", &value) || value < 0 || value > 2) return;
        m_fill_mode     = static_cast<FillMode>(value);
        m_fill_explicit = true;
        if (m_scene != nullptr && m_render->hasBackend()) {
            m_render->UpdateCameraFillMode(*m_scene, m_fill_mode);
        }
    }
    MHANDLER_CMD(SET_SCALINGMODE) {
        int32_t value = 0;
        if (! msg->findInt32("value", &value)) return;
        // A value no mode has is ignored, not cast into a layout that draws nothing scaled.
        const auto mode = WallpaperScalingModeFromValue(value);
        if (! mode) return;
        m_scaling_mode = *mode;
        m_render->SetWallpaperScalingMode(m_scaling_mode);
    }
    MHANDLER_CMD(SET_SCALINGFACTOR) {
        float value = 1.0f;
        if (! msg->findFloat("value", &value)) return;
        m_scaling_factor = value;
        m_render->SetWallpaperScalingFactor(m_scaling_factor);
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
        float value = 1.0f;
        if (! msg->findFloat("value", &value) || ! std::isfinite(value) || value <= 0.0f) return;
        m_render_scale = static_cast<float>(
            std::clamp(static_cast<double>(value), render::kMinRenderScale, 1.0));
        if (m_scene == nullptr) return;
        // The raster choice is re-read here too, so a host that changed it only has to send the
        // scale again.
        const SceneResolution resolution = CurrentSceneResolution();
        if (m_rg == nullptr || m_render_blocked || ! renderInited()) {
            // Nothing compiled to resize: the next build allocates at these values.
            m_scene->render_scale = m_render_scale;
            m_scene->resolution   = resolution;
            return;
        }
        if (! m_render->ApplyRenderScale(*m_scene, *m_rg, m_render_scale, resolution)) {
            // The graph was dropped to be compiled again and that failed: build it again rather
            // than leave nothing to present.
            (void)rebuildRenderGraph();
        }
    }
    MHANDLER_CMD(SET_HORIZONTAL_FLIP) {
        bool value = false;
        if (! msg->findBool("value", &value)) return;
        m_mirror = value;
        // Without a renderer yet the flag waits in `m_mirror` for `reapplySurfaceState`.
        if (renderInited()) {
            m_render->SetWallpaperHorizontalFlip(m_mirror);
        }
    }
    MHANDLER_CMD(SET_AUDIO_RESPONSE_ENABLED) {
        bool value = false;
        if (! msg->findBool("value", &value)) return;
        if (m_scene != nullptr && m_scene->runtime != nullptr) {
            m_scene->runtime->SetAudioResponseEnabled(value);
        }
    }
    MHANDLER_CMD(SET_MEDIA_INTEGRATION_ENABLED) {
        bool value = false;
        if (! msg->findBool("value", &value)) return;
        m_media_integration = value;
        if (m_scene != nullptr && m_scene->runtime != nullptr) {
            m_scene->runtime->SetMediaIntegrationEnabled(value);
        }
        if (! value) {
            // e6 R63.
            m_pending_media_events.clear();
            m_parked_artwork.reset();
        }
    }
    MHANDLER_CMD(MEDIA_EVENT_JSON) {
        std::string json;
        if (! msg->findString("value", &json) || ! m_media_integration) return;
        retainMediaEvent(json);
        if (m_scene != nullptr && m_scene->runtime != nullptr) {
            m_scene->runtime->DispatchMediaEventJson(json);
        }
    }
    MHANDLER_CMD(SYSTEM_MEDIA_ARTWORK) {
        std::shared_ptr<ArtworkPayload> artwork;
        if (! msg->findObject("artwork", &artwork) || artwork == nullptr) return;
        if (auto* images = runtimeImages(); images != nullptr) {
            // Replaces whatever was parked: this is newer.
            m_parked_artwork.reset();
            if (PublishSystemMediaArtwork(*images, artwork->width, artwork->height,
                                          artwork->rgba.data(), artwork->rgba.size())) {
                requestFrame();
            }
            return;
        }
        // No scene that takes pixels yet: the newest cover waits for the next commit.
        m_parked_artwork = std::move(*artwork);
    }
    /// Puts `incoming` in place of the current scene (R-H22 a to c). Returns false, with the
    /// outgoing scene still current, when the outgoing graph cannot be released. Whether the
    /// incoming scene refuses pointer input is reported through `incoming_takes_pointer`.
    bool replaceCurrentScene(std::shared_ptr<Scene> incoming, bool& incoming_takes_pointer) {
        if (m_render->hasBackend() && ! m_render->clearLastRenderGraph()) {
            m_rg.reset();
            suspendAfterGraphFailure();
            return false;
        }
        m_rg.reset();

        if (m_scene != nullptr && m_scene->runtime != nullptr) {
            m_scene->runtime->SetAudioRequirementListener({});
        }
        const bool outgoing_takes_pointer = m_scene == nullptr || m_scene->accepts_pointer_input;
        incoming_takes_pointer            = incoming == nullptr || incoming->accepts_pointer_input;

        std::shared_ptr<Scene> outgoing;
        {
            std::scoped_lock lock(m_mouse_mutex);
            outgoing = std::exchange(m_scene, std::move(incoming));
            if (! outgoing_takes_pointer || ! incoming_takes_pointer) {
                m_mouse_buttons.pressed  = 0;
                m_mouse_buttons.released = 0;
            }
        }
        return true;
    }

    /// Gives the current scene's runtime what scripts may read on their first frame (R-H22 f).
    void equipSceneRuntime() {
        if (m_scene == nullptr || m_scene->runtime == nullptr) return;
        installContentWake(*m_scene);
        publishScreenResolution();
        m_scene->runtime->SetMediaIntegrationEnabled(m_media_integration);
        replayMediaEvents();
    }

    /// Commits a scene the control thread loaded (e6 R20, R-H22).
    MHANDLER_CMD(SET_SCENE) {
        std::shared_ptr<Scene> incoming;
        // A null scene is a commit of no scene; a message without the key is not a commit.
        if (! msg->findObject("scene", &incoming)) return;
        std::string cache_path;
        (void)msg->findString("cache_path", &cache_path);

        bool takes_pointer = true;
        if (! replaceCurrentScene(std::move(incoming), takes_pointer)) return;

        m_failure_first_frame_sent = false;
        // A surface the host has released stays blocked: the scene waits for the one that
        // replaces it, and only the failure of the scene it replaces ends here.
        const bool surface_released = m_surface_released;
        m_scene_awaits_surface      = surface_released;
        if (surface_released) {
            clearFailure();
        } else {
            clearRenderBlock();
        }
        syncFrameClock();
        equipSceneRuntime();

        CancelSceneMetalVariants();
        m_shader_cache_path = std::move(cache_path);
        m_render->SetPipelineArchivePath(m_shader_cache_path);

        commitAudioRequirement();
        main_handler.sendPointerInputCapability(takes_pointer);

        if (! surface_released) selectSceneBackend();
        publishParkedArtwork();
        if (! surface_released && m_failure_stage == SceneFailureStage::None) {
            (void)rebuildRenderGraph();
        }

        publishPauseReasons();
        refreshFrameDemand();
    }
    MHANDLER_CMD(SET_SPEED) {
        float value = 1.0f;
        if (! msg->findFloat("value", &value) || ! std::isfinite(value)) return;
        m_speed = value;
        if (m_render->hasBackend()) m_render->SetVideoPlaybackRate(m_speed);
        refreshFrameDemand();
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
    /// Takes over a surface description. No GPU renderer is created here.
    ///
    /// Whether the scene can be drawn is decided from the parsed scene, so
    /// building a renderer now would mean tearing it down again the moment the
    /// scene turns out to be refused.
    MHANDLER_CMD(INIT_SURFACE) {
        std::shared_ptr<RenderInitInfo> info;
        if (! msg->findObject("info", &info) || info == nullptr) return;
        adoptRenderInitInfo(std::move(info));
        const uint64_t epoch = m_surface_epoch.fetch_add(1, std::memory_order_acq_rel) + 1;
        m_surface_handed.store(true, std::memory_order_release);
        m_surface_released     = false;
        m_scene_awaits_surface = false;
        clearRenderBlock();
        syncFrameClock();
        publishScreenResolution();
        main_handler.sendCmdLoadScene(epoch);
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
        switch (m_render->ServicePosterRequest(*m_scene)) {
        case metal::PosterServiceResult::Failed:
            // The scene still draws, only this export failed, and the mailbox's
            // own backoff decides when to try again.
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
    /// A host-initiated stop: no stop reason, no failure counted, nobody called back.
    MHANDLER_CMD(BEGIN_SURFACE_RECONFIGURE) {
        TicketGuard ticket(msg);
        m_surface_released = true;
        suspendRendering();
        // Nothing the preview picture holds may refer to the layer that is about to go.
        m_still.Hide();
        if (m_render->hasBackend() && m_render->inited()) {
            if (! m_render->releaseSurface()) return;
        }
        ticket.succeed(true);
    }
    MHANDLER_CMD(FINISH_SURFACE_RECONFIGURE) {
        TicketGuard ticket(msg);
        std::shared_ptr<RenderInitInfo> info;
        if (! msg->findObject("info", &info) || info == nullptr) return;
        adoptRenderInitInfo(std::move(info));
        m_surface_handed.store(true, std::memory_order_release);
        m_surface_released = false;
        // A display change is news to scripts that size themselves against the screen.
        publishScreenResolution();
        // A scene that landed while the surface was out chose no renderer and built no graph.
        const bool scene_waited = std::exchange(m_scene_awaits_surface, false) && m_scene != nullptr;

        if (! m_render->hasBackend()) {
            if (m_failure_stage != SceneFailureStage::None) {
                // Held without a renderer: nothing to reset. The clock stays stopped and the
                // failure stays; only the preview picture moves to the new layer.
                settleFailedScene();
            } else {
                // The scene has not chosen a renderer yet: it will be created from this
                // description when the scene lands.
                clearRenderBlock();
                syncFrameClock();
                if (scene_waited) {
                    selectSceneBackend();
                    if (m_failure_stage == SceneFailureStage::None && ! rebuildRenderGraph()) {
                        publishPauseReasons();
                        return;
                    }
                }
            }
            publishPauseReasons();
            ticket.succeed(true);
            return;
        }
        if (! m_render->resetSurface(*m_render_init_info)) {
            holdFailedScene(SceneFailureStage::Surface, m_render->lastError());
            return;
        }
        m_render->InvalidatePresentedFrame();
        if (scene_waited) {
            selectSceneBackend();
            if (m_failure_stage != SceneFailureStage::None) {
                // Refused: held like any refusal, which is not a failure of the surface.
                publishPauseReasons();
                ticket.succeed(true);
                return;
            }
        }
        if (m_scene == nullptr) {
            clearRenderBlock();
        } else if (! rebuildRenderGraph()) {
            publishPauseReasons();
            return;
        }
        syncFrameClock();
        m_render->SetVideoPlaybackPaused(! frame_timer.Running() || m_render_blocked);
        refreshFrameDemand();
        publishPauseReasons();
        ticket.succeed(true);
    }

public:
    FrameTimer       frame_timer;
    /// Whether the host wants this surface playing. The clock runs only while
    /// this holds and a scene is loaded; see `syncFrameClock`. Render thread.
    bool             m_clock_requested { true };
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
               render::SceneOptimizationEnabled();
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
        if (selection.failed()) {
            // Once per failure, at error level: this is the line a user quotes
            // when a wallpaper shows a still picture, or stops on its last
            // frame, instead of playing.
            LOG_ERROR("scene cannot be drawn with native Metal (%s): %s; holding the %s",
                      ToString(selection.failure_stage),
                      selection.failure_reason.c_str(),
                      m_layer_has_picture ? "last frame" : "preview picture");
        } else {
            // Once per scene: the first thing to know about a wallpaper that looks
            // wrong is whether a renderer is drawing it.
            LOG_INFO("scene backend: native_metal");
        }
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
        const uint64_t generation   = ++m_audio_requirement_generation;
        bool           requires_now = false;
        if (m_scene != nullptr && m_scene->runtime != nullptr) {
            // Installed before the flag is read: a mark that races the commit is then reported
            // by the listener, by this report, or by both.
            m_scene->runtime->SetAudioRequirementListener(
                main_handler.audioRequirementReporter(generation));
            requires_now = m_scene->runtime->SceneRequiresAudioResponse();
        }
        main_handler.sendAudioRequirement(generation, requires_now);
    }

private:
    std::shared_ptr<Scene> m_scene { nullptr };
    /// Bumped on every scene commit; the main looper drops audio-requirement
    /// reports carrying an older one.
    uint64_t               m_audio_requirement_generation { 0 };

    std::unique_ptr<SceneRendererHandle> m_render;
    /// Why this scene is held without a renderer drawing it, or `None`. Render
    /// thread only; the host reads the published copy in `m_backend_selection`.
    SceneFailureStage                    m_failure_stage { SceneFailureStage::None };
    /// Whether the host has been told a first picture exists for the scene
    /// whose failure is being held, so it is told once.
    bool                                 m_failure_first_frame_sent { false };
    /// Whether the surface's current layer has had a real frame presented on it
    /// (or is about to keep one). A layer that has is held on that frame; one
    /// that has not shows the preview picture.
    bool                                 m_layer_has_picture { false };
    /// The preview picture shown instead of a frame nothing could draw.
    surface::StillPreview                m_still;
    /// Retained from `INIT_SURFACE` so the renderer can be created, or
    /// re-created, on the same surface once the scene is known to be drawable.
    std::shared_ptr<RenderInitInfo>      m_render_init_info;
    std::unique_ptr<rg::RenderGraph>      m_rg { nullptr };
    bool                                m_render_blocked { false };
    /// Between `BEGIN_SURFACE_RECONFIGURE` and the surface that follows it: the layer the
    /// description names is the one the host gave up, so nothing may be created on it or drawn.
    bool                                m_surface_released { false };
    /// A scene was committed while the surface was released: its renderer choice and its graph
    /// wait for the surface that comes back.
    bool                                m_scene_awaits_surface { false };
    /// Whether the frame loop is alive and why it stopped. Unlike the
    /// counters, never gated: a stop nobody can see cannot be told apart from
    /// a pause.
    SurfaceHealth                       m_health;

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
        render::SceneOptimizationEnabled()
    };
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

    /// Guards `m_mouse_buttons` for the few instructions of an update or a take.
    std::mutex                        m_mouse_mutex;
    MouseButtonSnapshot               m_mouse_buttons {};
    std::atomic<bool>                 m_cursor_in_window { false };
    /// Whether the pointer was over the window when the previous frame dispatched its events.
    bool                              m_cursor_was_in_window { false };
    /// The newest normalised pointer, both axes in one word so a frame reads one sample.
    std::atomic<uint64_t>             m_pointer_bits { PackPointer(0.5f, 0.5f) };
    /// Whether a surface description has ever been handed over.
    std::atomic<bool>                 m_surface_handed { false };
    std::atomic<uint64_t>             m_surface_epoch { 0 };
    /// Host settings kept on this thread and pushed to every renderer it creates.
    float                             m_speed { 1.0f };
    FillMode                          m_fill_mode { FillMode::ASPECTFIT };
    bool                              m_fill_explicit { false };
    WallpaperScalingMode              m_scaling_mode { WallpaperScalingMode::FIT };
    double                            m_scaling_factor { 1.0 };
    bool                              m_mirror { false };
    bool                              m_media_integration { false };
    /// The newest cover that could not be given to a scene yet.
    std::optional<ArtworkPayload>     m_parked_artwork {};
    /// Published for the host without enabling diagnostic counting: these are
    /// live state a settings pane reads, not instrumentation. Written on the
    /// render thread, read from whichever thread asks.
    std::atomic<SceneUpdateDemand::Kind> m_scene_update_kind {
        SceneUpdateDemand::Kind::Continuous
    };
    std::atomic<uint32_t> m_scene_demand_reasons {
        static_cast<uint32_t>(SceneDemandReason::UnknownInput)
    };
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
    m_main_handler->shutdown();
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

void SceneWallpaperInputTestAccess::UseNullSoundOutput(SceneWallpaper& wallpaper) {
    auto& handler           = *wallpaper.m_main_handler;
    handler.m_sound_manager = std::make_unique<audio::SoundManager>(
        audio::SoundManager::OutputBackend::Null);
    // Running, as the one it replaces was made.
    handler.m_sound_manager->Play();
}

uint64_t SceneWallpaperInputTestAccess::SoundOutputStarts(SceneWallpaper& wallpaper) {
    return wallpaper.m_main_handler->m_sound_manager->OutputStarts();
}

bool SceneWallpaperInputTestAccess::SurfaceHandedOver(SceneWallpaper& wallpaper) {
    return wallpaper.m_main_handler->renderHandler()->renderSurfaceReady();
}

#endif

void SceneWallpaper::initSurface(const RenderInitInfo& info) {
    auto msg = CreateMsgWithCmd(m_main_handler->renderHandler(),
                                RenderHandler::CMD::CMD_INIT_SURFACE);
    msg->setObject("info", std::make_shared<RenderInitInfo>(info));
    msg->post();
}

bool SceneWallpaper::beginSurfaceReconfigure() {
    return m_main_handler->runSurfaceCommand(true, nullptr);
}

bool SceneWallpaper::finishSurfaceReconfigure(const RenderInitInfo& info) {
    return m_main_handler->runSurfaceCommand(false, std::make_shared<RenderInitInfo>(info));
}

void SceneWallpaper::applyConfig(const SceneWallpaperConfig& config) {
    auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_APPLY_CONFIG);
    msg->setObject("config", std::make_shared<SceneWallpaperConfig>(config));
    msg->post();
}

namespace
{
void PostPause(const std::shared_ptr<MainHandler>& handler, bool paused) {
    auto msg = CreateMsgWithCmd(handler, MainHandler::CMD::CMD_STOP);
    msg->setBool("paused", paused);
    msg->post();
}
} // namespace

void SceneWallpaper::play() { PostPause(m_main_handler, false); }
void SceneWallpaper::pause() { PostPause(m_main_handler, true); }

void SceneWallpaper::setPaused(bool paused) { PostPause(m_main_handler, paused); }

// The scene source, assets folder, cache folder and frame rate are properties like any other:
// the setters only name the property.
void SceneWallpaper::setSceneSource(std::string source) {
    return setPropertyString(PROPERTY_SOURCE, std::move(source));
}
void SceneWallpaper::setAssetsPath(std::string assets) {
    return setPropertyString(PROPERTY_ASSETS, std::move(assets));
}
void SceneWallpaper::setCachePath(std::string cache_path) {
    return setPropertyString(PROPERTY_CACHE_PATH, std::move(cache_path));
}
void SceneWallpaper::setTargetFps(uint32_t fps) {
    return setPropertyInt32(PROPERTY_FPS, static_cast<int32_t>(fps));
}

// Pointer input goes straight to the render handler, which owns the sampled position.
void SceneWallpaper::mouseInput(double x, double y) {
    auto render = m_main_handler->renderHandler();
    render->setMousePos(x, y);
}
void SceneWallpaper::mouseButton(int button, bool pressed) {
    auto render = m_main_handler->renderHandler();
    render->setMouseButton(button, pressed);
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
    // The pixels are copied here, so the caller's buffer need not outlive the call.
    auto artwork    = std::make_shared<ArtworkPayload>();
    artwork->width  = width;
    artwork->height = height;
    if (rgba_len > 0) artwork->rgba.assign(rgba, rgba + rgba_len);
    auto msg = CreateMsgWithCmd(m_main_handler->renderHandler(),
                                RenderHandler::CMD::CMD_SYSTEM_MEDIA_ARTWORK);
    msg->setObject("artwork", std::move(artwork));
    msg->post();
}

#define BASIC_TYPE(NAME, TYPENAME)                                                       \
    void SceneWallpaper::setProperty##NAME(std::string_view name, TYPENAME value) {      \
        auto msg = CreateMsgWithCmd(m_main_handler, MainHandler::CMD::CMD_SET_PROPERTY);  \
        msg->setString("property", std::string(name));                                    \
        msg->set##NAME("value", std::move(value));                                        \
        msg->post();                                                                      \
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

std::size_t SceneWallpaper::counters(uint64_t* out, std::size_t len) const {
    if (m_main_handler == nullptr) return 0;
    const auto handler = m_main_handler->renderHandler();
    if (handler == nullptr) return 0;
    return handler->counters.Snapshot(out, len);
}

MHANDLER_CMD_IMPL(MainHandler, LOAD_SCENE) {
    // A configuration that arrived after the hand-over may already have loaded the scene; the
    // same scene is not parsed a second time (the second commit would replace a running one).
    std::shared_ptr<uint64_t> epoch;
    if (msg->findObject("epoch", &epoch) && epoch != nullptr && *epoch <= m_loaded_epoch) return;
    loadScene();
}

MHANDLER_CMD_IMPL(MainHandler, APPLY_CONFIG) {
    std::shared_ptr<SceneWallpaperConfig> config;
    if (! msg->findObject("config", &config) || config == nullptr) return;
    if (applyConfig(*config)) loadScene();
}

namespace
{
/// Posts one message to the render thread whose payload `fill` writes.
template<typename Fill>
void PostToRender(const std::shared_ptr<RenderHandler>& render, RenderHandler::CMD cmd,
                  Fill&& fill) {
    auto msg = CreateMsgWithCmd(render, cmd);
    fill(*msg);
    msg->post();
}
} // namespace

MHANDLER_CMD_IMPL(MainHandler, SET_PROPERTY) {
    std::string name;
    if (! msg->findString("property", &name)) return;
    using CMD = RenderHandler::CMD;

    std::string text;
    int32_t     integer = 0;
    float       real    = 0.0f;
    bool        flag    = false;

    if (name == PROPERTY_SOURCE) {
        if (! msg->findString("value", &text)) return;
        m_source = std::move(text);
        loadScene();
    } else if (name == PROPERTY_ASSETS) {
        if (! msg->findString("value", &text)) return;
        m_assets = std::move(text);
        loadScene();
    } else if (name == PROPERTY_CACHE_PATH) {
        if (! msg->findString("value", &text)) return;
        m_cache_path = std::move(text);
    } else if (name == PROPERTY_FPS) {
        if (! msg->findInt32("value", &integer) || integer <= 0) return;
        m_render_handler->frame_timer.SetRequiredFps(
            static_cast<u16>(std::min<int32_t>(integer, 65535)));
    } else if (name == PROPERTY_FILLMODE) {
        if (! msg->findInt32("value", &integer)) return;
        PostToRender(m_render_handler, CMD::CMD_SET_FILLMODE,
                     [&](looper::Message& out) { out.setInt32("value", integer); });
    } else if (name == PROPERTY_SCALINGMODE) {
        if (! msg->findInt32("value", &integer)) return;
        PostToRender(m_render_handler, CMD::CMD_SET_SCALINGMODE,
                     [&](looper::Message& out) { out.setInt32("value", integer); });
    } else if (name == PROPERTY_SCALINGFACTOR) {
        if (! msg->findFloat("value", &real)) return;
        PostToRender(m_render_handler, CMD::CMD_SET_SCALINGFACTOR,
                     [&](looper::Message& out) { out.setFloat("value", real); });
    } else if (name == PROPERTY_RENDER_SCALE) {
        if (! msg->findFloat("value", &real)) return;
        PostToRender(m_render_handler, CMD::CMD_SET_RENDER_SCALE,
                     [&](looper::Message& out) { out.setFloat("value", real); });
    } else if (name == PROPERTY_SPEED) {
        if (! msg->findFloat("value", &real)) return;
        PostToRender(m_render_handler, CMD::CMD_SET_SPEED,
                     [&](looper::Message& out) { out.setFloat("value", real); });
    } else if (name == PROPERTY_HORIZONTAL_FLIP) {
        if (! msg->findBool("value", &flag)) return;
        PostToRender(m_render_handler, CMD::CMD_SET_HORIZONTAL_FLIP,
                     [&](looper::Message& out) { out.setBool("value", flag); });
    } else if (name == PROPERTY_FRAMING) {
        std::shared_ptr<WallpaperFraming> framing;
        if (! msg->findObject("value", &framing) || framing == nullptr) return;
        PostToRender(m_render_handler, CMD::CMD_SET_FRAMING,
                     [&](looper::Message& out) { out.setObject("value", framing); });
    } else if (name == PROPERTY_GRAPHIVZ) {
        // A developer switch that dumped the graph to a file; nothing writes outside the cache.
    } else if (name == PROPERTY_VOLUME) {
        if (! msg->findFloat("value", &real) || ! std::isfinite(real)) return;
        m_sound_manager->SetVolume(real);
    } else if (name == PROPERTY_MUTED) {
        if (! msg->findBool("value", &flag)) return;
        m_sound_manager->SetMuted(flag);
    } else if (name == PROPERTY_AUDIO_RESPONSE_ENABLED) {
        if (! msg->findBool("value", &flag)) return;
        m_audio_response_enabled = flag;
        PostToRender(m_render_handler, CMD::CMD_SET_AUDIO_RESPONSE_ENABLED,
                     [&](looper::Message& out) { out.setBool("value", flag); });
    } else if (name == PROPERTY_MEDIA_INTEGRATION_ENABLED) {
        if (! msg->findBool("value", &flag)) return;
        m_media_integration_enabled = flag;
        PostToRender(m_render_handler, CMD::CMD_SET_MEDIA_INTEGRATION_ENABLED,
                     [&](looper::Message& out) { out.setBool("value", flag); });
    } else if (name == PROPERTY_MEDIA_EVENT_JSON) {
        if (! msg->findString("value", &text)) return;
        // Accepted and dropped while the user has not consented.
        if (! m_media_integration_enabled) return;
        PostToRender(m_render_handler, CMD::CMD_MEDIA_EVENT_JSON,
                     [&](looper::Message& out) { out.setString("value", text); });
    } else if (name == PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON) {
        if (! msg->findString("value", &text)) return;
        if (setProjectPropertyOverrideJson(std::move(text))) loadScene();
    } else if (name == PROPERTY_PROJECT_PROPERTY_RESET) {
        if (! msg->findBool("value", &flag) || ! flag) return;
        if (resetProjectPropertyOverride()) loadScene();
    } else if (name == PROPERTY_FORCE_SHADER_REFRESH) {
        if (! msg->findBool("value", &flag)) return;
        m_force_refresh = flag;
    } else if (name == PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON) {
        if (! msg->findString("value", &text)) return;
        previewProjectProperties(text);
    } else if (name == PROPERTY_FIRST_FRAME_CALLBACK) {
        std::shared_ptr<FirstFrameCallback> callback;
        if (! msg->findObject("value", &callback) || callback == nullptr) return;
        m_first_frame_callback = *callback;
    } else if (name == PROPERTY_POINTER_INPUT_CALLBACK) {
        std::shared_ptr<PointerInputCallback> callback;
        if (! msg->findObject("value", &callback) || callback == nullptr) return;
        m_pointer_input_callback = *callback;
        if (m_pointer_input_callback) m_pointer_input_callback(m_accepts_pointer_input);
    } else if (name == PROPERTY_USER_SHORTCUT_CALLBACK) {
        std::shared_ptr<UserShortcutCallback> callback;
        if (! msg->findObject("value", &callback) || callback == nullptr) return;
        m_user_shortcut_callback = *callback;
    } else if (name == PROPERTY_AUDIO_REQUIREMENT_CALLBACK) {
        std::shared_ptr<AudioRequirementCallback> callback;
        if (! msg->findObject("value", &callback) || callback == nullptr) return;
        m_audio_requirement_callback = *callback;
        if (m_audio_requirement_callback) m_audio_requirement_callback(m_requires_audio);
    } else if (name == PROPERTY_RENDER_FAILURE_CALLBACK) {
        std::shared_ptr<RenderFailureCallback> callback;
        if (! msg->findObject("value", &callback) || callback == nullptr) return;
        m_render_failure_callback = *callback;
    }
    // Any other name is accepted and ignored.
}

MHANDLER_CMD_IMPL(MainHandler, STOP) {
    bool paused = false;
    if (! msg->findBool("paused", &paused)) return;
    setPaused(paused);
}

MHANDLER_CMD_IMPL(MainHandler, FIRST_FRAME) {
    (void)msg;
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
    if (config.source.empty() || config.fps == 0) return false;
    const std::string saved = config.has_project_property_override
                                  ? std::move(config.project_property_override_json)
                                  : std::string {};
    const bool        reload = config.source != m_source || config.assets != m_assets ||
                        config.cache_path != m_cache_path || saved != m_override_json ||
                        config.force_shader_refresh || m_force_refresh;
    if (config.source != m_source) LOG_INFO("scene source: %s", config.source.c_str());
    m_source        = std::move(config.source);
    m_assets        = std::move(config.assets);
    m_cache_path    = std::move(config.cache_path);
    m_override_json = saved;
    // Replaced by every configuration: the flag acts only on the call after which it was set.
    m_force_refresh = config.force_shader_refresh;
    m_render_handler->frame_timer.SetRequiredFps(static_cast<u16>(std::min<uint32_t>(config.fps, 65535)));
    // A wallpaper that arrives paused or muted must not make a sound while it loads, nor
    // one that arrives quieter play louder.
    m_sound_manager->SetVolume(config.volume);
    m_sound_manager->SetMuted(config.muted);
    setPaused(config.paused);
    return reload;
}

void MainHandler::setPaused(bool paused) {
    if (paused) {
        m_sound_manager->Pause();
    } else {
        m_sound_manager->Play();
    }
    PostToRender(m_render_handler, RenderHandler::CMD::CMD_STOP,
                 [&](looper::Message& out) { out.setBool("paused", paused); });
}

bool MainHandler::setProjectPropertyOverrideJson(std::string json) {
    if (json == m_override_json) return false;
    m_override_json = std::move(json);
    return true;
}

bool MainHandler::resetProjectPropertyOverride() {
    if (m_override_json.empty()) return false;
    m_override_json.clear();
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
    // Nothing to load, or nowhere to show it yet: the surface hand-over asks again.
    if (m_source.empty() || ! m_render_handler->renderSurfaceReady()) return;
    m_loaded_epoch = m_render_handler->surfaceEpoch();
    LOG_INFO("loading scene: %s", m_source.c_str());

    SceneSourceResolution resolved;
    std::string           error;
    if (! ResolveSceneSourcePaths(m_source, &resolved, &error)) {
        LOG_ERROR("scene not loaded, the source cannot be resolved: %s", error.c_str());
        return;
    }
    if (resolved.kind != SceneSourceResolutionKind::Scene) {
        (void)loadNonSceneProject(resolved.manifest);
        return;
    }

    // The file space the scene reads for the whole of its life, lowest layer first.
    auto vfs = std::make_unique<fs::VFS>();
    {
        auto shared = fs::CreatePhysicalFs(m_assets);
        if (shared == nullptr || ! vfs->Mount("/assets", std::move(shared))) {
            LOG_ERROR("scene not loaded, the shared assets cannot be mounted: %s",
                      m_assets.c_str());
            return;
        }
    }
    if (! MountSceneSource(*vfs, resolved.scene_source, &error)) {
        LOG_ERROR("scene not loaded, the wallpaper's files cannot be mounted: %s", error.c_str());
        return;
    }
    if (! m_cache_path.empty()) {
        // Optional: a scene without a cache only compiles its shaders again.
        auto cache = fs::CreatePhysicalFs(m_cache_path, true);
        if (cache == nullptr || ! IsWritableFolder(m_cache_path) ||
            ! vfs->Mount("/cache", std::move(cache), "cache")) {
            LOG_ERROR("shader cache not available, loading without it: %s", m_cache_path.c_str());
        }
    }
    if (! InstallVirtualAssets(*vfs)) {
        LOG_ERROR("scene not loaded, the built-in assets cannot be installed");
        return;
    }
    const std::string scene_text =
        fs::GetFileContent(*vfs, "/assets/" + resolved.scene_source.pkg_entry);
    if (scene_text.empty()) {
        LOG_ERROR("scene not loaded, the scene file is missing or empty: %s",
                  resolved.scene_source.pkg_entry.c_str());
        return;
    }

    ProjectProperties authored;
    if (! ParseProjectProperties(m_source, &authored, &error)) {
        LOG_ERROR("scene not loaded, the project properties cannot be read: %s", error.c_str());
        return;
    }
    ProjectProperties merged = authored;
    if (! m_override_json.empty()) {
        ProjectProperties saved;
        if (! ParseFlatProjectPropertyOverrideJson(m_override_json, &saved, &error)) {
            LOG_ERROR("scene not loaded, the saved property choices cannot be read: %s",
                      error.c_str());
            return;
        }
        merged = MergeProjectProperties(authored, saved);
    }

    SceneParseRequest request;
    request.scene_id                    = resolved.scene_source.scene_id;
    request.project_path                = m_source;
    request.project_properties          = &merged;
    request.authored_project_properties = &authored;
    request.pkg_version                 = ReadPackageVersion(resolved.scene_source.pkg_path);

    // The previous scene's sounds are released only now that a parse is certain to start.
    m_sound_manager->UnMountAll();
    WPSceneParser parser;
    auto          scene = parser.Parse(request, scene_text, *vfs, *m_sound_manager);
    if (scene == nullptr) {
        LOG_ERROR("scene not loaded, the parse produced no scene: %s", m_source.c_str());
        return;
    }
    scene->project_path = m_source;
    if (scene->runtime != nullptr) {
        scene->runtime->SetAudioResponseEnabled(m_audio_response_enabled);
        scene->runtime->SetMediaIntegrationEnabled(m_media_integration_enabled);
    }
    // The file space now lives exactly as long as the scene that reads from it.
    scene->vfs = std::move(vfs);

    PostToRender(m_render_handler, RenderHandler::CMD::CMD_SET_SCENE, [&](looper::Message& out) {
        out.setObject("scene", std::shared_ptr<Scene>(std::move(scene)));
        out.setString("cache_path", m_cache_path);
    });
    PostToRender(m_render_handler, RenderHandler::CMD::CMD_DRAW, [](looper::Message&) {});
}

bool MainHandler::loadNonSceneProject(const ProjectManifest& manifest) {
    LOG_ERROR("scene not loaded, the project is not a scene (%s)", ToString(manifest.type));
    return false;
}

void MainHandler::sendCmdLoadScene(uint64_t epoch) {
    auto msg = CreateMsgWithCmd(shared_from_this(), CMD::CMD_LOAD_SCENE);
    msg->setObject("epoch", std::make_shared<uint64_t>(epoch));
    msg->post();
}
void MainHandler::sendFirstFrameOk() {
    CreateMsgWithCmd(shared_from_this(), CMD::CMD_FIRST_FRAME)->post();
}

void MainHandler::sendPointerInputCapability(bool accepts_pointer_input) {
    auto msg = CreateMsgWithCmd(shared_from_this(), CMD::CMD_POINTER_INPUT_CHANGED);
    msg->setBool("accepts_pointer_input", accepts_pointer_input);
    msg->post();
}

void MainHandler::sendAudioRequirement(uint64_t generation, bool requires_audio) {
    auto msg = CreateMsgWithCmd(shared_from_this(), CMD::CMD_AUDIO_REQUIREMENT_CHANGED);
    msg->setObject("generation", std::make_shared<uint64_t>(generation));
    msg->setBool("requires_audio", requires_audio);
    msg->post();
}

void MainHandler::sendRenderFailure() {
    CreateMsgWithCmd(shared_from_this(), CMD::CMD_RENDER_FAILED)->post();
}

std::function<void()> MainHandler::audioRequirementReporter(uint64_t generation) {
    return [weak = weak_from_this(), generation] {
        auto self = std::static_pointer_cast<MainHandler>(weak.lock());
        if (self != nullptr) self->sendAudioRequirement(generation, true);
    };
}

void MainHandler::sendUserShortcut(std::string_view property_name,
                                   std::string_view property_value) {
    auto msg = CreateMsgWithCmd(shared_from_this(), CMD::CMD_USER_SHORTCUT);
    msg->setString("property_name", std::string(property_name));
    msg->setString("property_value", std::string(property_value));
    msg->post();
}

bool MainHandler::init() {
    if (m_inited.load()) return true;
    m_main_loop->setName("main");
    m_render_loop->setName("render");
    // A tick asks the render thread for one draw. The handler is reached through a weak pointer:
    // the clock must not keep it alive.
    m_render_handler->frame_timer.SetCallback([weak = std::weak_ptr<RenderHandler>(m_render_handler)] {
        if (auto render = weak.lock()) {
            CreateMsgWithCmd(render, RenderHandler::CMD::CMD_DRAW)->post();
        }
    });
    m_render_handler->frame_timer.SetRequiredFps(30);

    const auto self = shared_from_this();
    if (m_main_loop->registerHandler(self) == looper::Handler::INVALID_HANDLER_ID) return false;
    if (m_render_loop->registerHandler(m_render_handler) == looper::Handler::INVALID_HANDLER_ID) {
        m_main_loop->unregisterHandler(self->id());
        return false;
    }
    const auto undo = [&] {
        m_main_loop->stop();
        m_render_loop->stop();
        m_main_loop->unregisterHandler(self->id());
        m_render_loop->unregisterHandler(m_render_handler->id());
    };
    if (m_main_loop->start() != looper::status_t::OK || m_render_loop->start() != looper::status_t::OK) {
        undo();
        return false;
    }
    {
        std::scoped_lock lock(m_ticket_mutex);
        m_accepting = true;
        m_inited    = true;
    }
    return true;
}

bool MainHandler::runSurfaceCommand(bool begin, std::shared_ptr<RenderInitInfo> info) {
    // A surface description that did not arrive is a failure before anything is posted.
    if (! begin && info == nullptr) return false;
    auto ticket = std::make_shared<SurfaceTicket>();
    {
        std::scoped_lock lock(m_ticket_mutex);
        if (! m_accepting) return false;
        m_tickets.push_back(ticket);
    }
    auto msg = CreateMsgWithCmd(m_render_handler,
                                begin ? RenderHandler::CMD::CMD_BEGIN_SURFACE_RECONFIGURE
                                      : RenderHandler::CMD::CMD_FINISH_SURFACE_RECONFIGURE);
    msg->setObject("ticket", ticket);
    if (info != nullptr) msg->setObject("info", std::move(info));
    bool result = false;
    if (msg->post() == looper::status_t::OK) result = ticket->wait();
    std::scoped_lock lock(m_ticket_mutex);
    m_tickets.erase(std::remove(m_tickets.begin(), m_tickets.end(), ticket), m_tickets.end());
    return result;
}

void MainHandler::shutdown() {
    {
        std::scoped_lock lock(m_ticket_mutex);
        if (! m_inited.load()) return;
        // From here no blocking command is accepted.
        m_accepting = false;
        m_inited    = false;
    }
    // The render thread ends first, so nothing starts the clock again; then the clock and the
    // renderer (the one synchronous GPU wait); then the control thread.
    m_render_loop->stop();
    m_render_handler->frame_timer.Stop();
    m_render_handler->releaseRenderer();
    m_main_loop->stop();
    m_main_loop->unregisterHandler(id());
    m_render_loop->unregisterHandler(m_render_handler->id());
    // Silent from here on, whatever the scene still holds.
    m_sound_manager->Pause();
    m_sound_manager->UnMountAll();
    // A caller still waiting on a command that was dropped unprocessed is told it failed.
    std::vector<std::shared_ptr<SurfaceTicket>> waiting;
    {
        std::scoped_lock lock(m_ticket_mutex);
        waiting = m_tickets;
    }
    for (const auto& ticket : waiting) ticket->complete(false);
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
