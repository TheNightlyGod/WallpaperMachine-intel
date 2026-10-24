// Clean-room implementation from the WallpaperMachine spec e6-platform-host-api.md; written without access to the original source.
#include "Platform/Apple/SceneWallpaperBindings.h"

#include "Audio/AudioResponseService.h"
#include "Core/RendererCounters.hpp"
#include "Presentation/WallpaperScaling.hpp"
#include "SceneWallpaper.hpp"
#include "Runtime/MediaArtwork.hpp"
#include "SceneWallpaperSurface.hpp"
#include "Utils/Logging.h"
#include "MetalRender/MetalVideoSupport.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Video/VideoFramePacing.hpp"

#import <QuartzCore/CAMetalLayer.h>

#include <algorithm>
#include <cstring>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace
{
// ---------------------------------------------------------------------------
// Last-error text (status protocol): one string per calling thread.
// ---------------------------------------------------------------------------
thread_local std::string t_last_error;

void clear_last_error()
{
    t_last_error.clear();
}

// Records the text and returns the failure status. Storing the text may itself
// run out of memory; the call still fails.
int fail(std::string_view text)
{
    try {
        t_last_error.assign(text.data(), text.size());
    } catch (...) {
    }
    return 1;
}

// Same as `fail`, for a text made of a fixed lead and a detail: building it may
// run out of memory too, and that must not unwind out of the interface.
int fail_detail(std::string_view lead, std::string_view detail)
{
    try {
        t_last_error.assign(lead.data(), lead.size());
        t_last_error.append(detail.data(), detail.size());
    } catch (...) {
    }
    return 1;
}

// Runs a body that may allocate or call into the scene host. No exception of
// any kind leaves the interface: it becomes status 1 with a text.
template<class Body>
int guarded(Body&& body)
{
    try {
        return body();
    } catch (const std::exception& error) {
        return fail_detail("the scene host failed internally: ", error.what());
    } catch (...) {
        return fail("the scene host failed internally");
    }
}

// Property names are delivered through one buffer per thread, valid until the
// next accessor call on the same thread.
const char* property_name(std::string_view value)
{
    thread_local std::string buffer;
    try {
        buffer.assign(value.data(), value.size());
    } catch (...) {
        return "";
    }
    return buffer.c_str();
}

// ---------------------------------------------------------------------------
// Callback registrations.
// ---------------------------------------------------------------------------

// One registration of a host callback together with the host's opaque data and
// the function that releases it. The scene host's forwarder and the handle both
// share it, so the data is released only when the last of them lets go.
template<class Callback, class Drop>
class Registration {
public:
    Registration(Callback callback, void* user_data, Drop drop) noexcept
        : m_callback(callback), m_user_data(user_data), m_drop(drop) {}
    Registration(const Registration&)            = delete;
    Registration& operator=(const Registration&) = delete;
    ~Registration() { release(); }

    Callback callback() const noexcept { return m_callback; }
    void*    userData() const noexcept { return m_user_data; }

    // The host data is released only once the registration is installed: until
    // then a failure on the way leaves it with the host.
    void arm() noexcept { m_armed.store(true, std::memory_order_release); }

    // Stops every later invocation, then releases the host data (once).
    void close() noexcept
    {
        m_closed.store(true, std::memory_order_release);
        release();
    }
    bool closed() const noexcept { return m_closed.load(std::memory_order_acquire); }

private:
    void release() noexcept
    {
        if (! m_armed.exchange(false, std::memory_order_acq_rel)) return;
        if (m_drop == nullptr) return;
        try {
            m_drop(m_user_data);
        } catch (...) {
        }
    }

    Callback          m_callback;
    void*             m_user_data;
    Drop              m_drop;
    std::atomic<bool> m_armed { false };
    std::atomic<bool> m_closed { false };
};

using FirstFrameRegistration =
    Registration<owe_first_frame_callback, owe_first_frame_callback_drop>;
using PointerRegistration =
    Registration<owe_pointer_input_callback, owe_pointer_input_callback_drop>;
using ShortcutRegistration =
    Registration<owe_user_shortcut_callback, owe_user_shortcut_callback_drop>;
using AudioRegistration =
    Registration<owe_audio_requirement_callback, owe_audio_requirement_callback_drop>;
using FailureRegistration =
    Registration<owe_render_failure_callback, owe_render_failure_callback_drop>;

// ---------------------------------------------------------------------------
// The desktop poster mailbox: one per drawing layer.
// ---------------------------------------------------------------------------

constexpr std::size_t kPosterContextLimit = 4096; // UTF-16 units
constexpr std::size_t kPosterLedgerSize   = 4;
constexpr auto        kPosterRetryWindow  = std::chrono::seconds(2);

NSString* const kPosterRequestName = @"WallpaperMachine.requestDesktopPoster";
NSString* const kPosterReadyName   = @"WallpaperMachine.desktopPosterReady";

using PosterTime = std::chrono::steady_clock::time_point;

// What has been asked for: requests are numbered tickets, and answering a ticket
// satisfies it and every older one. Requests that pile up are one open demand.
class PosterDemand {
public:
    void ask(std::string text)
    {
        ++m_newest;
        m_text = std::move(text);
    }
    bool satisfied(uint64_t ticket) const noexcept { return ticket <= m_answered_up_to; }
    bool open() const noexcept { return ! satisfied(m_newest); }
    uint64_t newest() const noexcept { return m_newest; }
    const std::string& text() const noexcept { return m_text; }
    void settle(uint64_t ticket) noexcept { m_answered_up_to = std::max(m_answered_up_to, ticket); }

private:
    uint64_t    m_newest { 1 }; // a fresh surface owes its first frame
    uint64_t    m_answered_up_to { 0 };
    std::string m_text;
};

// The captures that were started and have not been answered yet, oldest first.
class PosterLedger {
public:
    struct Entry {
        uint64_t    ticket;
        std::string text;
        PosterTime  started;
    };

    void enter(uint64_t ticket, std::string text, PosterTime started)
    {
        m_entries.push_back(Entry { ticket, std::move(text), started });
        if (m_entries.size() > kPosterLedgerSize) m_entries.pop_front();
    }
    // When the newest capture was started, if it served exactly this ticket.
    std::optional<PosterTime> newest_start_for(uint64_t ticket) const
    {
        if (m_entries.empty() || m_entries.back().ticket != ticket) return std::nullopt;
        return m_entries.back().started;
    }
    template <class Pred>
    void forget_if(Pred&& pred)
    {
        std::erase_if(m_entries, pred);
    }
    std::optional<Entry> take_oldest()
    {
        if (m_entries.empty()) return std::nullopt;
        Entry oldest = std::move(m_entries.front());
        m_entries.pop_front();
        return oldest;
    }

private:
    std::deque<Entry> m_entries;
};

// The render thread's wake hook. Firing and rebinding exclude each other, so once
// an unbind returns the old hook is neither running nor going to run.
class PosterWakeSlot {
public:
    void bind(std::function<void()> hook)
    {
        std::lock_guard guard(m_lock);
        m_hook = std::move(hook);
    }
    void fire()
    {
        std::lock_guard guard(m_lock);
        if (m_hook) m_hook();
    }

private:
    std::mutex            m_lock;
    std::function<void()> m_hook;
};

class PosterMailbox : public std::enable_shared_from_this<PosterMailbox> {
public:
    using Clock = std::function<PosterTime()>;

    PosterMailbox(CAMetalLayer* layer, NSNotificationCenter* center, Clock clock)
        : m_now(std::move(clock)), m_notifications(center), m_target(layer) {}

    ~PosterMailbox()
    {
        if (m_listener != nil) [m_notifications removeObserver:m_listener];
    }

    // Listens for requests aimed at the layer; the listener only holds the mailbox
    // weakly, so this needs the mailbox to be owned by a shared pointer already.
    void start()
    {
        std::weak_ptr<PosterMailbox> weak = weak_from_this();
        m_listener = [m_notifications addObserverForName:kPosterRequestName
                                                  object:m_target
                                                   queue:nil
                                              usingBlock:^(NSNotification* note) {
                                                  if (auto alive = weak.lock()) alive->noteRequest(note.userInfo);
                                              }];
    }

    void noteRequest(NSDictionary* info)
    {
        std::string text;
        if (id raw = info[@"context"]; [raw isKindOfClass:[NSString class]]) {
            NSString* candidate = raw;
            if (candidate.length <= kPosterContextLimit) {
                if (const char* utf8 = candidate.UTF8String) text = utf8;
            }
        }
        {
            std::lock_guard guard(m_state_lock);
            m_demand.ask(std::move(text));
        }
        m_wake.fire();
    }

    void bindWake(std::function<void()> hook) { m_wake.bind(std::move(hook)); }

    bool wants()
    {
        std::lock_guard guard(m_state_lock);
        if (! m_demand.open()) return false;
        const uint64_t ticket = m_demand.newest();
        const PosterTime now  = m_now();
        if (const auto last = m_ledger.newest_start_for(ticket)) {
            // already handed to a capture: only a retry after the window
            if (now - *last < kPosterRetryWindow) return false;
        }
        m_ledger.enter(ticket, m_demand.text(), now);
        return true;
    }

    void ready(std::span<const uint8_t> pixels, uint32_t width, uint32_t height, bool bgra)
    {
        @autoreleasepool {
            CAMetalLayer* layer = m_target;
            if (layer == nil) return;
            const std::optional<std::string> text = creditOldestCapture();
            if (! text) return;

            NSData*   bytes   = [NSData dataWithBytes:pixels.data() length:pixels.size()];
            NSString* context = [NSString stringWithUTF8String:text->c_str()] ?: @"";
            NSNotificationCenter* center = m_notifications;
            __weak CAMetalLayer*  weakLayer = layer;
            dispatch_async(dispatch_get_main_queue(), ^{
                CAMetalLayer* target = weakLayer;
                if (target == nil) return;
                [center postNotificationName:kPosterReadyName
                                      object:target
                                    userInfo:@{
                                        @"pixels" : bytes,
                                        @"width" : @(width),
                                        @"height" : @(height),
                                        @"bgra" : @(bgra),
                                        @"context" : context,
                                    }];
            });
        }
    }

private:
    // The oldest capture whose request is still unanswered becomes the answered one.
    std::optional<std::string> creditOldestCapture()
    {
        std::lock_guard guard(m_state_lock);
        m_ledger.forget_if([this](const PosterLedger::Entry& e) { return m_demand.satisfied(e.ticket); });
        auto oldest = m_ledger.take_oldest();
        if (! oldest) return std::nullopt;
        m_demand.settle(oldest->ticket);
        return std::move(oldest->text);
    }

    Clock                 m_now;
    NSNotificationCenter* m_notifications;
    __weak CAMetalLayer*  m_target;
    id                    m_listener { nil };
    std::mutex            m_state_lock;
    PosterDemand          m_demand;
    PosterLedger          m_ledger;
    PosterWakeSlot        m_wake;
};

// Validation shared by `init_metal` and `finish_surface_reconfigure`. Returns
// an empty string when the arguments are acceptable.
const char* surface_argument_problem(void* layer, uint32_t width, uint32_t height,
                                     uint32_t render_width, uint32_t render_height)
{
    constexpr uint32_t kMaxDimension = 65535;
    if (layer == nullptr) return "the metal layer is NULL";
    if (width == 0 || width > kMaxDimension) return "the width must be between 1 and 65535";
    if (height == 0 || height > kMaxDimension) return "the height must be between 1 and 65535";
    if ((render_width == 0) != (render_height == 0)) {
        return "the render width and render height must both be zero or both be set";
    }
    if (render_width > kMaxDimension) return "the render width is above 65535";
    if (render_height > kMaxDimension) return "the render height is above 65535";
    return "";
}

// The surface description of one layer, with its own poster mailbox.
wallpaper::RenderInitInfo make_surface_info(void* layer, uint32_t width, uint32_t height,
                                            uint32_t render_width, uint32_t render_height,
                                            double display_scale_factor)
{
    wallpaper::RenderInitInfo info;
    info.offscreen   = false;
    info.metal_layer = layer;
    CFRetain(layer);
    info.metal_layer_owner = std::shared_ptr<void>(layer, [](void* held) { CFRelease(held); });
    info.width             = static_cast<uint16_t>(width);
    info.height            = static_cast<uint16_t>(height);
    const bool same_size   = render_width == 0 && render_height == 0;
    info.render_width      = static_cast<uint16_t>(same_size ? width : render_width);
    info.render_height     = static_cast<uint16_t>(same_size ? height : render_height);
    info.display_scale_factor =
        std::isfinite(display_scale_factor) && display_scale_factor > 0.0 ? display_scale_factor : 1.0;

    auto mailbox = std::make_shared<PosterMailbox>(
        (__bridge CAMetalLayer*)layer, [NSNotificationCenter defaultCenter],
        [] { return std::chrono::steady_clock::now(); });
    mailbox->start();
    info.wants_poster = [mailbox] { return mailbox->wants(); };
    info.poster_ready = [mailbox](std::span<const uint8_t> pixels, uint32_t w, uint32_t h,
                                  bool bgra) { mailbox->ready(pixels, w, h, bgra); };
    info.bind_poster_wake = [mailbox](std::function<void()> hook) {
        mailbox->bindWake(std::move(hook));
    };
    return info;
}

// What a property name carries: the setter type that may write it.
enum class PropertyKind { Unknown, Bool, Int32, Float, String, Object };

PropertyKind property_kind(std::string_view name)
{
    using namespace wallpaper;
    struct Entry {
        std::string_view name;
        PropertyKind     kind;
    };
    static constexpr Entry kTable[] = {
        { PROPERTY_SOURCE, PropertyKind::String },
        { PROPERTY_ASSETS, PropertyKind::String },
        { PROPERTY_CACHE_PATH, PropertyKind::String },
        { PROPERTY_FPS, PropertyKind::Int32 },
        { PROPERTY_FILLMODE, PropertyKind::Int32 },
        { PROPERTY_SCALINGMODE, PropertyKind::Int32 },
        { PROPERTY_SCALINGFACTOR, PropertyKind::Float },
        { PROPERTY_FRAMING, PropertyKind::Object },
        { PROPERTY_RENDER_SCALE, PropertyKind::Float },
        { PROPERTY_HORIZONTAL_FLIP, PropertyKind::Bool },
        { PROPERTY_SPEED, PropertyKind::Float },
        { PROPERTY_GRAPHIVZ, PropertyKind::Bool },
        { PROPERTY_VOLUME, PropertyKind::Float },
        { PROPERTY_MUTED, PropertyKind::Bool },
        { PROPERTY_AUDIO_RESPONSE_ENABLED, PropertyKind::Bool },
        { PROPERTY_MEDIA_INTEGRATION_ENABLED, PropertyKind::Bool },
        { PROPERTY_MEDIA_EVENT_JSON, PropertyKind::String },
        { PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON, PropertyKind::String },
        { PROPERTY_PROJECT_PROPERTY_RESET, PropertyKind::Bool },
        { PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON, PropertyKind::String },
        { PROPERTY_FORCE_SHADER_REFRESH, PropertyKind::Bool },
        { PROPERTY_FIRST_FRAME_CALLBACK, PropertyKind::Object },
        { PROPERTY_POINTER_INPUT_CALLBACK, PropertyKind::Object },
        { PROPERTY_USER_SHORTCUT_CALLBACK, PropertyKind::Object },
        { PROPERTY_AUDIO_REQUIREMENT_CALLBACK, PropertyKind::Object },
        { PROPERTY_RENDER_FAILURE_CALLBACK, PropertyKind::Object },
    };
    for (const auto& entry : kTable) {
        if (entry.name == name) return entry.kind;
    }
    return PropertyKind::Unknown;
}

const char* kind_word(PropertyKind kind)
{
    switch (kind) {
    case PropertyKind::Bool: return "a boolean";
    case PropertyKind::Int32: return "an integer";
    case PropertyKind::Float: return "a float";
    case PropertyKind::String: return "a string";
    case PropertyKind::Object: return "a callback registration";
    case PropertyKind::Unknown: break;
    }
    return "unknown";
}

// Checks of a generic property setter, in the order of the interface table.
// Returns 0 when the write may go ahead.
int check_property_write(owe_scene_wallpaper* scene, const char* name, PropertyKind written)
{
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (name == nullptr || *name == '\0') return fail("the property name is NULL or empty");
    const PropertyKind expected = property_kind(name);
    if (expected != PropertyKind::Unknown && expected != written) {
        try {
            return fail(std::string("the property '") + name + "' takes " + kind_word(expected) +
                        ", not " + kind_word(written));
        } catch (...) {
            return 1;
        }
    }
    return 0;
}
} // namespace

struct owe_scene_wallpaper {
    // First member, at offset 0: the pull-only readers receive the handle's
    // address as a plain pointer to the scene.
    wallpaper::SceneWallpaper scene;

    std::shared_ptr<FirstFrameRegistration> first_frame;
    std::shared_ptr<PointerRegistration>    pointer_input;
    std::shared_ptr<ShortcutRegistration>   user_shortcut;
    std::shared_ptr<AudioRegistration>      audio_requirement;
    std::shared_ptr<FailureRegistration>    render_failure;

    // No callback runs after the scene stopped, and the host data of every
    // registration still held is released exactly once.
    void closeRegistrations() noexcept
    {
        if (first_frame) first_frame->close();
        if (pointer_input) pointer_input->close();
        if (user_shortcut) user_shortcut->close();
        if (audio_requirement) audio_requirement->close();
        if (render_failure) render_failure->close();
    }
};

namespace
{
// Installs one forwarder under `property`, then arms the registration and keeps
// it in `slot`. The local `registration` owner pins the host data across the
// install, whose replay may call back before this function returns.
template<class Registered, class Callable>
int install_callback(owe_scene_wallpaper* scene,
                     std::shared_ptr<Registered>& slot,
                     std::string_view property,
                     std::shared_ptr<Registered> registration,
                     Callable&& make_forwarder)
{
    auto forwarder = make_forwarder(registration);
    scene->scene.setPropertyObject(
        property, std::static_pointer_cast<void>(std::move(forwarder)));
    registration->arm();
    slot = std::move(registration);
    return 0;
}
} // namespace

#ifdef WESCENE_BUILD_TESTS
wallpaper::SceneWallpaper&
wallpaper::SceneWallpaperInputTestAccess::FromNative(owe_scene_wallpaper& scene) {
    return scene.scene;
}
#endif

extern "C" void owe_set_log_callback(owe_log_callback callback)
{
    SetWallpaperLogCallback(callback);
}

extern "C" uint64_t owe_current_log_scope(void) { return WallpaperLogScope(); }

extern "C" int owe_scene_wallpaper_new(owe_scene_wallpaper** out_scene)
{
    clear_last_error();
    if (out_scene == nullptr) return fail("the output scene pointer is NULL");
    return guarded([&] {
        *out_scene = new owe_scene_wallpaper();
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_delete(owe_scene_wallpaper* scene)
{
    clear_last_error();
    if (scene == nullptr) return 0;
    try {
        scene->scene.shutdown();
        // Nothing runs any more: release the host data of every registration
        // that is still held, then the scene itself.
        scene->closeRegistrations();
    } catch (...) {
    }
    try {
        delete scene;
    } catch (...) {
    }
    clear_last_error();
    return 0;
}

extern "C" int owe_scene_wallpaper_set_log_scope(owe_scene_wallpaper* scene, uint64_t scope)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (scene->scene.inited()) return fail("the log scope must be set before the scene host is initialised");
    return guarded([&] {
        scene->scene.setLogScope(scope);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_init(owe_scene_wallpaper* scene)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    return guarded([&] {
        if (! scene->scene.init()) return fail("the scene host could not start its threads");
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_shutdown(owe_scene_wallpaper* scene)
{
    clear_last_error();
    if (scene == nullptr) return 0;
    return guarded([&] {
        scene->scene.shutdown();
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_init_metal(
    owe_scene_wallpaper* scene,
    void* metal_layer,
    uint32_t width,
    uint32_t height,
    uint32_t render_width,
    uint32_t render_height,
    double display_scale_factor)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (const char* problem = surface_argument_problem(metal_layer, width, height, render_width,
                                                       render_height);
        *problem != '\0') {
        return fail(problem);
    }
    if (! scene->scene.inited()) return fail("the scene host is not initialised");
    return guarded([&] {
        scene->scene.initSurface(make_surface_info(metal_layer, width, height, render_width,
                                                   render_height, display_scale_factor));
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_begin_surface_reconfigure(owe_scene_wallpaper* scene)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! scene->scene.inited()) return fail("the scene host is not initialised");
    return guarded([&] {
        if (! scene->scene.beginSurfaceReconfigure()) return fail("the surface could not be released");
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_finish_surface_reconfigure(
    owe_scene_wallpaper* scene,
    void* metal_layer,
    uint32_t width,
    uint32_t height,
    uint32_t render_width,
    uint32_t render_height,
    double display_scale_factor)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (const char* problem = surface_argument_problem(metal_layer, width, height, render_width,
                                                       render_height);
        *problem != '\0') {
        return fail(problem);
    }
    if (! scene->scene.inited()) return fail("the scene host is not initialised");
    return guarded([&] {
        const auto info = make_surface_info(metal_layer, width, height, render_width,
                                            render_height, display_scale_factor);
        if (! scene->scene.finishSurfaceReconfigure(info)) {
            return fail("the surface could not be rebuilt on the new layer");
        }
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_apply_config(
    owe_scene_wallpaper* scene,
    const char* source,
    const char* assets,
    const char* cache_path,
    uint32_t fps,
    bool paused,
    float volume,
    bool muted,
    bool force_shader_refresh,
    const char* project_property_override_json)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (source == nullptr || *source == '\0') return fail("the wallpaper source is NULL or empty");
    if (fps == 0) return fail("the frame rate must not be zero");
    if (! std::isfinite(volume) || volume < 0.0f || volume > 1.0f) {
        return fail("the audio volume must be between 0 and 1");
    }
    return guarded([&] {
        wallpaper::SceneWallpaperConfig config;
        config.source     = source;
        config.assets     = assets != nullptr ? assets : "";
        config.cache_path = cache_path != nullptr ? cache_path : "";
        config.fps        = std::min<uint32_t>(fps, 65535);
        config.paused     = paused;
        config.volume     = volume;
        config.muted      = muted;
        config.force_shader_refresh          = force_shader_refresh;
        config.has_project_property_override = project_property_override_json != nullptr;
        if (project_property_override_json != nullptr) {
            config.project_property_override_json = project_property_override_json;
        }
        scene->scene.applyConfig(config);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_target_fps(owe_scene_wallpaper* scene, uint32_t fps)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (fps == 0) return fail("the frame rate must not be zero");
    return guarded([&] {
        scene->scene.setTargetFps(std::min<uint32_t>(fps, 65535));
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_paused(owe_scene_wallpaper* scene, bool paused)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    return guarded([&] {
        scene->scene.setPaused(paused);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_render_scale(owe_scene_wallpaper* scene, double scale)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! std::isfinite(scale) || scale <= 0.0) return fail("the render scale must be finite and above zero");
    return guarded([&] {
        // Anything above 1 means 1; clamping first keeps the narrowing to float defined.
        scene->scene.setPropertyFloat(wallpaper::PROPERTY_RENDER_SCALE,
                                      static_cast<float>(std::min(scale, 1.0e6)));
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_framing(owe_scene_wallpaper* scene, double pan_x,
                                               double pan_y)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! std::isfinite(pan_x) || ! std::isfinite(pan_y)) return fail("the framing values must be finite");
    return guarded([&] {
        scene->scene.setFraming(wallpaper::WallpaperFraming { pan_x, pan_y });
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_first_frame_callback(
    owe_scene_wallpaper* scene,
    owe_first_frame_callback callback,
    void* user_data,
    owe_first_frame_callback_drop drop_user_data)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    return guarded([&] {
        auto registration = std::make_shared<FirstFrameRegistration>(callback, user_data, drop_user_data);
        return install_callback(scene, scene->first_frame, wallpaper::PROPERTY_FIRST_FRAME_CALLBACK, registration,
                                [](const std::shared_ptr<FirstFrameRegistration>& held) {
                                    return std::make_shared<wallpaper::FirstFrameCallback>(
                                        [held] {
                                            if (held->closed() || held->callback() == nullptr) return;
                                            try {
                                                held->callback()(held->userData());
                                            } catch (...) {
                                            }
                                        });
                                });
    });
}

extern "C" int owe_scene_wallpaper_set_pointer_input_callback(
    owe_scene_wallpaper* scene,
    owe_pointer_input_callback callback,
    void* user_data,
    owe_pointer_input_callback_drop drop_user_data)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! scene->scene.inited()) return fail("the scene host is not initialised");
    return guarded([&] {
        auto registration = std::make_shared<PointerRegistration>(callback, user_data, drop_user_data);
        return install_callback(scene, scene->pointer_input, wallpaper::PROPERTY_POINTER_INPUT_CALLBACK, registration,
                                [](const std::shared_ptr<PointerRegistration>& held) {
                                    return std::make_shared<wallpaper::PointerInputCallback>(
                                        [held](bool accepts) {
                                            if (held->closed() || held->callback() == nullptr) return;
                                            try {
                                                held->callback()(held->userData(), accepts);
                                            } catch (...) {
                                            }
                                        });
                                });
    });
}

extern "C" int owe_scene_wallpaper_set_user_shortcut_callback(
    owe_scene_wallpaper* scene,
    owe_user_shortcut_callback callback,
    void* user_data,
    owe_user_shortcut_callback_drop drop_user_data)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! scene->scene.inited()) return fail("the scene host is not initialised");
    return guarded([&] {
        auto registration = std::make_shared<ShortcutRegistration>(callback, user_data, drop_user_data);
        return install_callback(scene, scene->user_shortcut, wallpaper::PROPERTY_USER_SHORTCUT_CALLBACK, registration,
                                [](const std::shared_ptr<ShortcutRegistration>& held) {
                                    return std::make_shared<wallpaper::UserShortcutCallback>(
                                        [held](std::string_view name, std::string_view value) {
                                            if (held->closed() || held->callback() == nullptr) return;
                                            try {
                                                const std::string name_copy(name);
                                                const std::string value_copy(value);
                                                held->callback()(held->userData(), name_copy.c_str(),
                                                                 value_copy.c_str());
                                            } catch (...) {
                                            }
                                        });
                                });
    });
}

extern "C" int owe_scene_wallpaper_set_audio_requirement_callback(
    owe_scene_wallpaper* scene,
    owe_audio_requirement_callback callback,
    void* user_data,
    owe_audio_requirement_callback_drop drop_user_data)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! scene->scene.inited()) return fail("the scene host is not initialised");
    return guarded([&] {
        auto registration = std::make_shared<AudioRegistration>(callback, user_data, drop_user_data);
        return install_callback(scene, scene->audio_requirement, wallpaper::PROPERTY_AUDIO_REQUIREMENT_CALLBACK, registration,
                                [](const std::shared_ptr<AudioRegistration>& held) {
                                    return std::make_shared<wallpaper::AudioRequirementCallback>(
                                        [held](bool requires_audio) {
                                            if (held->closed() || held->callback() == nullptr) return;
                                            try {
                                                held->callback()(held->userData(), requires_audio);
                                            } catch (...) {
                                            }
                                        });
                                });
    });
}

extern "C" int owe_scene_wallpaper_set_render_failure_callback(
    owe_scene_wallpaper* scene,
    owe_render_failure_callback callback,
    void* user_data,
    owe_render_failure_callback_drop drop_user_data)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! scene->scene.inited()) return fail("the scene host is not initialised");
    return guarded([&] {
        auto registration = std::make_shared<FailureRegistration>(callback, user_data, drop_user_data);
        return install_callback(scene, scene->render_failure, wallpaper::PROPERTY_RENDER_FAILURE_CALLBACK, registration,
                                [](const std::shared_ptr<FailureRegistration>& held) {
                                    return std::make_shared<wallpaper::RenderFailureCallback>(
                                        [held] {
                                            if (held->closed() || held->callback() == nullptr) return;
                                            try {
                                                held->callback()(held->userData());
                                            } catch (...) {
                                            }
                                        });
                                });
    });
}

extern "C" int owe_scene_wallpaper_mouse_input(owe_scene_wallpaper* scene, double x, double y)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! std::isfinite(x) || ! std::isfinite(y)) return fail("the pointer position must be finite");
    return guarded([&] {
        scene->scene.mouseInput(x, y);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_mouse_button(owe_scene_wallpaper* scene, int button, bool pressed)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (button < 0 || button > 31) return fail("the mouse button must be between 0 and 31");
    return guarded([&] {
        scene->scene.mouseButton(button, pressed);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_mouse_button_baseline(
    owe_scene_wallpaper* scene, uint32_t down)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! scene->scene.inited()) return fail("the scene host is not initialised");
    return guarded([&] {
        scene->scene.mouseButtonBaseline(down);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_mouse_enter(owe_scene_wallpaper* scene, bool entered)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    return guarded([&] {
        scene->scene.mouseEnter(entered);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_property_bool(
    owe_scene_wallpaper* scene,
    const char* name,
    bool value)
{
    clear_last_error();
    if (const int status = check_property_write(scene, name, PropertyKind::Bool); status != 0) {
        return status;
    }
    return guarded([&] {
        scene->scene.setPropertyBool(name, value);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_property_int32(
    owe_scene_wallpaper* scene,
    const char* name,
    int32_t value)
{
    clear_last_error();
    if (const int status = check_property_write(scene, name, PropertyKind::Int32); status != 0) {
        return status;
    }
    if (std::string_view(name) == wallpaper::PROPERTY_SCALINGMODE &&
        ! wallpaper::WallpaperScalingModeFromValue(value)) {
        return fail("the scaling mode must be between 0 and 4");
    }
    return guarded([&] {
        scene->scene.setPropertyInt32(name, value);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_property_float(
    owe_scene_wallpaper* scene,
    const char* name,
    float value)
{
    clear_last_error();
    if (const int status = check_property_write(scene, name, PropertyKind::Float); status != 0) {
        return status;
    }
    return guarded([&] {
        scene->scene.setPropertyFloat(name, value);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_property_string(
    owe_scene_wallpaper* scene,
    const char* name,
    const char* value)
{
    clear_last_error();
    if (const int status = check_property_write(scene, name, PropertyKind::String); status != 0) {
        return status;
    }
    return guarded([&] {
        scene->scene.setPropertyString(name, std::string(value != nullptr ? value : ""));
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_audio_volume(owe_scene_wallpaper* scene, float volume)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! std::isfinite(volume) || volume < 0.0f || volume > 1.0f) {
        return fail("the audio volume must be between 0 and 1");
    }
    return guarded([&] {
        scene->scene.setPropertyFloat(wallpaper::PROPERTY_VOLUME, volume);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_set_audio_muted(owe_scene_wallpaper* scene, bool muted)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    return guarded([&] {
        scene->scene.setPropertyBool(wallpaper::PROPERTY_MUTED, muted);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_submit_media_event_json(
    owe_scene_wallpaper* scene,
    const char* event_json)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (event_json == nullptr || *event_json == '\0') return fail("the media event text is NULL or empty");
    return guarded([&] {
        scene->scene.setPropertyString(wallpaper::PROPERTY_MEDIA_EVENT_JSON, event_json);
        return 0;
    });
}

extern "C" int owe_scene_wallpaper_apply_system_media_artwork(
    owe_scene_wallpaper* scene,
    uint32_t width,
    uint32_t height,
    const uint8_t* rgba,
    uintptr_t rgba_len)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (! wallpaper::IsValidSystemMediaArtwork(width, height, rgba, rgba_len)) {
        return fail("the artwork is neither the clear value nor a complete RGBA image");
    }
    return guarded([&] {
        scene->scene.applySystemMediaArtwork(width, height, rgba, rgba_len);
        return 0;
    });
}

// One C accessor per property: the name text of a `wallpaper::PROPERTY_*` constant, handed out
// through `property_name` so the pointer stays valid. No error state is touched.
#define OWE_PROPERTY_ACCESSOR(accessor, constant) \
    extern "C" const char* accessor(void) { return property_name(wallpaper::constant); }

OWE_PROPERTY_ACCESSOR(owe_property_scaling_mode, PROPERTY_SCALINGMODE)
OWE_PROPERTY_ACCESSOR(owe_property_scaling_factor, PROPERTY_SCALINGFACTOR)
OWE_PROPERTY_ACCESSOR(owe_property_horizontal_flip, PROPERTY_HORIZONTAL_FLIP)
OWE_PROPERTY_ACCESSOR(owe_property_audio_response_enabled, PROPERTY_AUDIO_RESPONSE_ENABLED)
OWE_PROPERTY_ACCESSOR(owe_property_media_integration_enabled, PROPERTY_MEDIA_INTEGRATION_ENABLED)
OWE_PROPERTY_ACCESSOR(owe_property_force_shader_refresh, PROPERTY_FORCE_SHADER_REFRESH)
OWE_PROPERTY_ACCESSOR(owe_property_project_property_override_json,
                      PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON)
OWE_PROPERTY_ACCESSOR(owe_property_project_property_reset, PROPERTY_PROJECT_PROPERTY_RESET)

#undef OWE_PROPERTY_ACCESSOR

extern "C" const char* owe_property_project_property_preview_json(void)
{
    return property_name(wallpaper::PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON);
}

extern "C" int owe_audio_spectrum_is_stereo(void)
{
    const auto snapshot = wallpaper::audio::CurrentAudioSpectrumSnapshot();
    if (snapshot.generation == 0) return -1;
    return snapshot.stereo ? 1 : 0;
}

extern "C" void owe_set_scene_optimization_enabled(bool enabled)
{
    wallpaper::render::SetSceneOptimizationEnabled(enabled);
}

extern "C" bool owe_scene_optimization_enabled(void)
{
    return wallpaper::render::SceneOptimizationEnabled();
}

extern "C" void owe_scene_optimization_stats(
    uint64_t* out_executed_passes,
    uint64_t* out_skipped_passes,
    uint64_t* out_elided_copies,
    uint64_t* out_pinned_bytes)
{
    const auto totals = wallpaper::render::CurrentSceneOptimizationTotals();
    if (out_executed_passes != nullptr) *out_executed_passes = totals.executed_passes;
    if (out_skipped_passes != nullptr) *out_skipped_passes = totals.skipped_passes;
    if (out_elided_copies != nullptr) *out_elided_copies = totals.elided_copies;
    if (out_pinned_bytes != nullptr) *out_pinned_bytes = totals.pinned_bytes;
}

extern "C" void owe_set_scene_on_demand_enabled(bool enabled)
{
    wallpaper::SetSceneOnDemandEnabled(enabled);
}

extern "C" bool owe_scene_on_demand_enabled(void)
{
    return wallpaper::SceneOnDemandEnabled();
}

extern "C" void owe_set_scene_resolution(int resolution)
{
    // An unrecognised value keeps the canvas rather than being stored: it is
    // the size a scene has always been rasterized at, so a host built against a
    // newer enum degrades to the behaviour it had before the choice existed.
    wallpaper::SetSceneResolution(resolution == OWE_SCENE_RESOLUTION_DISPLAY
                                      ? wallpaper::SceneResolution::Display
                                      : wallpaper::SceneResolution::Canvas);
}

extern "C" int owe_current_scene_resolution(void)
{
    return wallpaper::CurrentSceneResolution() == wallpaper::SceneResolution::Display
               ? OWE_SCENE_RESOLUTION_DISPLAY
               : OWE_SCENE_RESOLUTION_CANVAS;
}

extern "C" int owe_scene_wallpaper_update_mode(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    // -1 rather than any enumerated mode: a caller with no scene has observed
    // nothing, which is different from observing a scene that is idle.
    if (wallpaper_scene == nullptr) return -1;
    switch (wallpaper_scene->sceneUpdateKind()) {
    case wallpaper::SceneUpdateDemand::Kind::WaitingForEvent:
        return OWE_SCENE_UPDATE_WAITING_FOR_EVENT;
    case wallpaper::SceneUpdateDemand::Kind::WaitingForDeadline:
        return OWE_SCENE_UPDATE_WAITING_FOR_DEADLINE;
    case wallpaper::SceneUpdateDemand::Kind::Continuous:
        return OWE_SCENE_UPDATE_CONTINUOUS;
    }
    return OWE_SCENE_UPDATE_UNKNOWN;
}

extern "C" int owe_scene_wallpaper_surface_health(void* scene, owe_surface_health* out)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    // Nothing observed is not a healthy surface: the caller is told it got no
    // reading instead of being handed zeroes that read as "running, no frames".
    if (wallpaper_scene == nullptr || out == nullptr) return 1;
    const auto health = wallpaper_scene->surfaceHealth();
    out->frames_completed = health.frames_completed;
    out->frames_presented = health.frames_presented;
    out->failed_frames = health.failed_frames;
    out->last_present_age_ms = health.last_present_age_ms;
    out->stop_reason = static_cast<uint32_t>(health.stop_reason);
    return 0;
}

extern "C" int owe_scene_wallpaper_backend(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return -1;
    const auto selection = wallpaper_scene->sceneBackendSelection();
    // Same -1 as "no scene": the host shows it as preparing. A renderer is only
    // created once the scene is parsed, and naming one before that would make
    // the panel claim a renderer that has not been created.
    // A scene held in a failure has no renderer drawing it right now, whatever
    // renderer it had before; the failure accessors say why.
    if (! selection.created || selection.failed()) return -1;
    return OWE_SCENE_BACKEND_NATIVE_METAL;
}

extern "C" void owe_set_scene_video_plane_sampling_enabled(bool enabled)
{
    wallpaper::metal::SetMetalVideoPlaneSamplingEnabled(enabled);
}

extern "C" bool owe_scene_video_plane_sampling_enabled(void)
{
    return wallpaper::metal::MetalVideoPlaneSamplingEnabled();
}

extern "C" int owe_scene_wallpaper_video_path(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return OWE_SCENE_VIDEO_PATH_NONE;
    switch (wallpaper_scene->sceneVideoPath()) {
    case wallpaper::SceneVideoPath::Bgra: return OWE_SCENE_VIDEO_PATH_BGRA;
    case wallpaper::SceneVideoPath::Nv12Direct: return OWE_SCENE_VIDEO_PATH_NV12_DIRECT;
    case wallpaper::SceneVideoPath::Nv12Converted: return OWE_SCENE_VIDEO_PATH_NV12_CONVERTED;
    case wallpaper::SceneVideoPath::Nv12Mixed: return OWE_SCENE_VIDEO_PATH_NV12_MIXED;
    // The host already decodes 5 as "converted, preparing"; only this end was
    // missing, so a scene between choosing that path and having it ready was
    // reported as having no video path at all.
    case wallpaper::SceneVideoPath::Nv12ConvertedPreparing:
        return OWE_SCENE_VIDEO_PATH_NV12_CONVERTED_PREPARING;
    case wallpaper::SceneVideoPath::Yuv10Converted: return OWE_SCENE_VIDEO_PATH_YUV10_CONVERTED;
    case wallpaper::SceneVideoPath::None: break;
    }
    return OWE_SCENE_VIDEO_PATH_NONE;
}

extern "C" int owe_scene_wallpaper_scene_optimization_applied(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return -1;
    return wallpaper_scene->sceneOptimizationApplied() ? 1 : 0;
}

extern "C" int owe_scene_wallpaper_backend_failure(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return OWE_SCENE_FAILURE_NONE;
    return static_cast<int>(wallpaper_scene->sceneBackendSelection().failure_stage);
}

extern "C" size_t owe_scene_wallpaper_backend_failure_reason(void* scene, char* out,
                                                             size_t out_len)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return 0;
    const auto reason = wallpaper_scene->sceneBackendSelection().failure_reason;
    if (reason.empty()) return 0;
    if (out == nullptr || out_len == 0) return reason.size();
    const size_t copied = std::min(reason.size(), out_len - 1);
    std::memcpy(out, reason.data(), copied);
    out[copied] = '\0';
    return reason.size();
}

extern "C" uint32_t owe_scene_wallpaper_demand_reasons(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return 0;
    return wallpaper_scene->sceneDemandReasons();
}

extern "C" int owe_audio_submit_mono_frames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames)
{
    clear_last_error();
    return guarded([&] {
        std::string error;
        if (! wallpaper::audio::SubmitMonoAudioFrames(sample_rate, frame_count, pcm_frames, &error)) {
            return fail(error.empty() ? std::string_view("the audio frames were refused") : std::string_view(error));
        }
        return 0;
    });
}

extern "C" int owe_audio_submit_frames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames)
{
    clear_last_error();
    return guarded([&] {
        std::string error;
        if (! wallpaper::audio::SubmitAudioFrames(sample_rate, frame_count, pcm_frames, &error)) {
            return fail(error.empty() ? std::string_view("the audio frames were refused") : std::string_view(error));
        }
        return 0;
    });
}

extern "C" int owe_audio_current_spectrum_128(
    float* out_bins,
    uintptr_t out_len,
    uint64_t* out_generation)
{
    clear_last_error();
    if (out_bins == nullptr) return fail("the spectrum buffer is NULL");
    constexpr std::size_t kHalf = 64;
    if (out_len < 2 * kHalf) return fail("the spectrum buffer must hold at least 128 values");
    const auto snapshot = wallpaper::audio::CurrentAudioSpectrumSnapshot();
    const auto usable = [](float level) {
        return std::isfinite(level) ? std::clamp(level, 0.0f, 1.0f) : 0.0f;
    };
    for (std::size_t i = 0; i < kHalf; ++i) {
        out_bins[i] = usable(snapshot.left64[i]);
        out_bins[kHalf + i] = usable(snapshot.right64[i]);
    }
    if (out_generation != nullptr) *out_generation = snapshot.generation;
    return 0;
}

extern "C" int owe_renderer_counters_set_enabled(bool enabled)
{
    clear_last_error();
    wallpaper::RendererCounters::SetEnabled(enabled);
    return 0;
}

extern "C" bool owe_renderer_counters_enabled(void)
{
    return wallpaper::RendererCounters::Enabled();
}

extern "C" int owe_scene_wallpaper_counters(
    owe_scene_wallpaper* scene,
    uint64_t* out_values,
    uintptr_t out_len,
    uintptr_t* out_written)
{
    clear_last_error();
    if (scene == nullptr) return fail("the scene host handle is NULL");
    if (out_values == nullptr) return fail("the counter buffer is NULL");
    return guarded([&] {
        const std::size_t written = scene->scene.counters(out_values, static_cast<std::size_t>(out_len));
        if (out_written != nullptr) *out_written = static_cast<uintptr_t>(written);
        return 0;
    });
}

extern "C" int owe_renderer_shared_counters(
    uint64_t* out_values,
    uintptr_t out_len,
    uintptr_t* out_written)
{
    clear_last_error();
    if (out_values == nullptr) return fail("the counter buffer is NULL");
    static_assert(OWE_RC_SHARED_COUNT == 2, "one slot per shared counter below");
    const std::size_t written =
        out_len < static_cast<uintptr_t>(OWE_RC_SHARED_COUNT) ? static_cast<std::size_t>(out_len)
                                                              : static_cast<std::size_t>(OWE_RC_SHARED_COUNT);
    const auto analysis = wallpaper::audio::CurrentAudioSpectrumSnapshot();
    if (written > 0) out_values[0] = analysis.generation;
    if (written > 1) out_values[1] = analysis.accepted_frame_count;
    if (out_written != nullptr) *out_written = static_cast<uintptr_t>(written);
    return 0;
}

extern "C" const char* owe_last_error(void)
{
    return t_last_error.c_str();
}
