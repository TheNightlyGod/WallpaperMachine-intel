#include "Platform/Apple/SceneWallpaperBindings.h"

#include "Audio/AudioResponseService.h"
#include "Core/RendererCounters.hpp"
#include "SceneWallpaper.hpp"
#include "Runtime/MediaArtwork.hpp"
#include "SceneWallpaperSurface.hpp"
#include "Utils/Logging.h"
#include "MetalRender/MetalBackendRouter.hpp"
#include "MetalRender/MetalVideoSupport.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "Video/SharedVideoSession.hpp"
#include "Video/VideoFramePacing.hpp"

#import <QuartzCore/CAMetalLayer.h>

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>

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
#include <string>
#include <string_view>
#include <utility>

namespace
{
thread_local std::string g_last_error;

void clear_last_error()
{
    g_last_error.clear();
}

int finish_with_error(std::string error)
{
    g_last_error = std::move(error);
    return 1;
}

bool valid_scene(owe_scene_wallpaper* scene)
{
    return scene != nullptr;
}

std::string_view view_or_empty(const char* value)
{
    return value == nullptr ? std::string_view {} : std::string_view { value };
}

bool validate_dimensions(uint32_t width, uint32_t height, std::string* error)
{
    if (width == 0 || height == 0) {
        *error = "render dimensions must be non-zero";
        return false;
    }
    if (width > std::numeric_limits<uint16_t>::max() ||
        height > std::numeric_limits<uint16_t>::max()) {
        *error = "render dimensions exceed SceneWallpaper limits";
        return false;
    }
    return true;
}

bool validate_render_resolution(uint32_t width, uint32_t height, std::string* error)
{
    if (width == 0 && height == 0) return true;
    if (width == 0 || height == 0) {
        *error = "render resolution must provide both width and height";
        return false;
    }
    if (width > std::numeric_limits<uint16_t>::max() ||
        height > std::numeric_limits<uint16_t>::max()) {
        *error = "render resolution exceeds SceneWallpaper limits";
        return false;
    }
    return true;
}

// A layer-scoped mailbox keeps requests independent across displays and scene
// replacements. Notifications stay in-process; no screen-recording permission
// or private WindowServer API is involved.
//
// Three threads touch this: the notification thread raises requests, the render
// thread polls `wants_poster`, and the native backend delivers pixels from a
// command-buffer completion handler. One mutex covers every field rather than
// atomics per field, because the interesting invariants span several of them.
struct DesktopPosterMailbox {
    std::mutex guard;
    uint64_t requested { 1 };
    uint64_t delivered { 0 };
    // Ids handed to captures that have started but not reported back, oldest
    // first. A single slot would credit whichever request happens to be in
    // flight when pixels arrive, and a capture that overlaps a newer request
    // would then mark that newer request satisfied with older pixels.
    std::string context;
    std::deque<std::pair<uint64_t, std::string>> handed_out;
    std::chrono::steady_clock::time_point next_attempt {};
    std::function<void()> wake;
    __weak CAMetalLayer* layer;
    id observer;

    // A capture that never reports back would otherwise sit at the head of the
    // queue and misalign every later result. Four is well past the number of
    // captures that can overlap in practice, so dropping the oldest beyond it
    // only ever discards an id nothing is going to answer for.
    static constexpr std::size_t kMaxOutstanding = 4;

    ~DesktopPosterMailbox() {
        if (observer != nil) [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
};

void configure_desktop_poster(wallpaper::RenderInitInfo& info, void* metal_layer_handle)
{
    auto mailbox = std::make_shared<DesktopPosterMailbox>();
    mailbox->layer = (__bridge CAMetalLayer*)metal_layer_handle;
    std::weak_ptr<DesktopPosterMailbox> weak_mailbox = mailbox;
    mailbox->observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"WallpaperMachine.requestDesktopPoster"
        object:mailbox->layer queue:nil usingBlock:^(NSNotification* notification) {
            auto state = weak_mailbox.lock();
            if (state == nullptr) return;
            std::scoped_lock lock(state->guard);
            ++state->requested;
            NSString* context = notification.userInfo[@"context"];
            const char* text = [context isKindOfClass:[NSString class]] && context.length <= 4096
                ? context.UTF8String : nullptr;
            state->context = text != nullptr ? text : "";
            // Woken under the lock that unbinding also takes, so a render
            // handler that has already unbound cannot be poked afterwards.
            // The wake only enqueues a message, so it does not re-enter here.
            if (state->wake) state->wake();
        }];
    info.bind_poster_wake = [mailbox](std::function<void()> wake) {
        std::scoped_lock lock(mailbox->guard);
        mailbox->wake = std::move(wake);
    };
    // New apply/refresh requests must export the next presented frame, even if
    // the previous wallpaper was sampled less than two seconds ago. Only
    // retries of a FAILED readback retain the backoff.
    const auto due = [](const DesktopPosterMailbox& state,
                        std::chrono::steady_clock::time_point now) {
        if (state.requested == state.delivered) return false;
        const bool retry =
            ! state.handed_out.empty() && state.handed_out.back().first == state.requested;
        return ! (retry && now < state.next_attempt);
    };
    info.poster_pending = [mailbox, due] {
        std::scoped_lock lock(mailbox->guard);
        return due(*mailbox, std::chrono::steady_clock::now());
    };
    info.wants_poster = [mailbox, due] {
        std::scoped_lock lock(mailbox->guard);
        const auto now = std::chrono::steady_clock::now();
        if (! due(*mailbox, now)) return false;
        mailbox->next_attempt = now + std::chrono::seconds(2);
        mailbox->handed_out.emplace_back(mailbox->requested, mailbox->context);
        if (mailbox->handed_out.size() > DesktopPosterMailbox::kMaxOutstanding) {
            mailbox->handed_out.pop_front();
        }
        return true;
    };
    info.poster_ready = [mailbox](std::span<const uint8_t> pixels, uint32_t width,
                                  uint32_t height, bool bgra) {
        @autoreleasepool {
            CAMetalLayer* layer = nil;
            std::string captured_context;
            {
                std::scoped_lock lock(mailbox->guard);
                // Captures report in the order they were started, so the head
                // is the request these pixels were taken for. Nothing recorded
                // means an old generation answering after the mailbox moved on.
                // A retried capture records its id twice; once the first copy
                // is satisfied the second is already answered, and leaving it
                // at the head would throw away the next request's pixels.
                while (! mailbox->handed_out.empty() &&
                       mailbox->handed_out.front().first <= mailbox->delivered) {
                    mailbox->handed_out.pop_front();
                }
                if (mailbox->handed_out.empty()) return;
                const uint64_t captured = mailbox->handed_out.front().first;
                captured_context = mailbox->handed_out.front().second;
                mailbox->handed_out.pop_front();
                mailbox->delivered = captured;
                layer = mailbox->layer;
            }
            if (layer == nil) return;
            NSData* data = [NSData dataWithBytes:pixels.data() length:pixels.size()];
            NSString* context = [NSString stringWithUTF8String:captured_context.c_str()];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"WallpaperMachine.desktopPosterReady"
                    object:layer userInfo:@{ @"pixels": data, @"width": @(width),
                                            @"height": @(height), @"bgra": @(bgra),
                                            @"context": context != nil ? context : @"" }];
            });
        }
    };
}

wallpaper::RenderInitInfo make_render_init_info(
    void* metal_layer_handle,
    uint32_t width,
    uint32_t height,
    uint32_t render_width,
    uint32_t render_height,
    double display_scale_factor)
{
    // RenderInitInfo owns C++ callbacks and vectors, which bindgen cannot model
    // safely. Keep that construction here and pass only primitive inputs from
    // wallpaper-core.
    wallpaper::RenderInitInfo info;
    info.offscreen = false;
    // Carried alongside the surface closure so a backend that does not create a
    // VkSurfaceKHR can still adopt this layer. Exactly one backend ever owns it.
    info.metal_layer = metal_layer_handle;
    info.width = static_cast<uint16_t>(width);
    info.height = static_cast<uint16_t>(height);
    info.render_width = static_cast<uint16_t>(render_width == 0 ? width : render_width);
    info.render_height = static_cast<uint16_t>(render_height == 0 ? height : render_height);
    info.display_scale_factor =
        display_scale_factor > 0.0 && std::isfinite(display_scale_factor)
            ? display_scale_factor
            : 1.0;
    info.surface_info.instanceExts = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_EXT_METAL_SURFACE_EXTENSION_NAME,
    };
    // Backend selection is deferred until the scene loads. Keep the layer alive
    // even if the host replaces its window layer before that work runs.
    CAMetalLayer* metal_layer = (__bridge CAMetalLayer*)metal_layer_handle;
    info.surface_info.createSurfaceOp =
        [metal_layer](VkInstance instance, VkSurfaceKHR* surface) {
            auto* create_surface = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
                vkGetInstanceProcAddr(instance, "vkCreateMetalSurfaceEXT"));
            if (create_surface == nullptr) return VK_ERROR_EXTENSION_NOT_PRESENT;

            const VkMetalSurfaceCreateInfoEXT create_info {
                .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
                .pNext = nullptr,
                .flags = 0,
                .pLayer = metal_layer,
            };
            return create_surface(instance, &create_info, nullptr, surface);
        };
    configure_desktop_poster(info, metal_layer_handle);
    return info;
}

const char* property_name(std::string_view value)
{
    // std::string_view constants in SceneWallpaper.hpp need stable C pointers
    // for Rust. The thread-local buffer is valid until the next property-name
    // request on the same thread, which is longer than each setter call needs.
    thread_local std::string name;
    name.assign(value);
    return name.c_str();
}

struct FirstFrameCallbackRegistration {
    owe_first_frame_callback      callback { nullptr };
    void*                         user_data { nullptr };
    owe_first_frame_callback_drop drop_user_data { nullptr };

    FirstFrameCallbackRegistration(
        owe_first_frame_callback callback,
        void* user_data,
        owe_first_frame_callback_drop drop_user_data):
        callback(callback), user_data(user_data), drop_user_data(drop_user_data)
    {
    }

    ~FirstFrameCallbackRegistration()
    {
        if (drop_user_data != nullptr) drop_user_data(user_data);
    }

    void operator()() const
    {
        if (callback != nullptr) callback(user_data);
    }
};

struct PointerInputCallbackRegistration {
    owe_pointer_input_callback callback { nullptr };
    void* user_data { nullptr };
    owe_pointer_input_callback_drop drop_user_data { nullptr };

    PointerInputCallbackRegistration(owe_pointer_input_callback callback, void* user_data)
        : callback(callback), user_data(user_data) {}

    ~PointerInputCallbackRegistration() {
        if (drop_user_data != nullptr) drop_user_data(user_data);
    }

    void operator()(bool accepts_pointer_input) const {
        if (callback != nullptr) callback(user_data, accepts_pointer_input);
    }
};

struct UserShortcutCallbackRegistration {
    owe_user_shortcut_callback callback { nullptr };
    void* user_data { nullptr };
    owe_user_shortcut_callback_drop drop_user_data { nullptr };

    UserShortcutCallbackRegistration(owe_user_shortcut_callback callback, void* user_data)
        : callback(callback), user_data(user_data) {}

    ~UserShortcutCallbackRegistration() {
        if (drop_user_data != nullptr) drop_user_data(user_data);
    }

    void operator()(std::string_view property_name, std::string_view property_value) const {
        if (callback == nullptr) return;
        // The engine's strings are not null-terminated views of storage the
        // callee may keep; both are copied for the length of the call only.
        const std::string name(property_name);
        const std::string value(property_value);
        callback(user_data, name.c_str(), value.c_str());
    }
};

struct AudioRequirementCallbackRegistration {
    owe_audio_requirement_callback callback { nullptr };
    void* user_data { nullptr };
    owe_audio_requirement_callback_drop drop_user_data { nullptr };

    AudioRequirementCallbackRegistration(owe_audio_requirement_callback callback, void* user_data)
        : callback(callback), user_data(user_data) {}

    ~AudioRequirementCallbackRegistration() {
        if (drop_user_data != nullptr) drop_user_data(user_data);
    }

    void operator()(bool requires_audio) const {
        if (callback != nullptr) callback(user_data, requires_audio);
    }
};

struct RenderFailureCallbackRegistration {
    owe_render_failure_callback callback { nullptr };
    void* user_data { nullptr };
    owe_render_failure_callback_drop drop_user_data { nullptr };

    RenderFailureCallbackRegistration(owe_render_failure_callback callback, void* user_data)
        : callback(callback), user_data(user_data) {}

    ~RenderFailureCallbackRegistration() {
        if (drop_user_data != nullptr) drop_user_data(user_data);
    }

    void operator()() const {
        if (callback != nullptr) callback(user_data);
    }
};

int finish_with_error_noexcept(const char* message) noexcept {
    try {
        return finish_with_error(message);
    } catch (...) {
        // Even reporting an allocation failure must not unwind through the C ABI.
        return 1;
    }
}
} // namespace

struct owe_scene_wallpaper {
    wallpaper::SceneWallpaper scene;
    std::shared_ptr<FirstFrameCallbackRegistration> first_frame_callback;
    std::shared_ptr<PointerInputCallbackRegistration> pointer_input_callback;
    std::shared_ptr<UserShortcutCallbackRegistration> user_shortcut_callback;
    std::shared_ptr<AudioRequirementCallbackRegistration> audio_requirement_callback;
    std::shared_ptr<RenderFailureCallbackRegistration> render_failure_callback;
};

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
    if (out_scene == nullptr) return finish_with_error("out_scene must not be null");

    *out_scene = new owe_scene_wallpaper();
    return 0;
}

extern "C" int owe_scene_wallpaper_delete(owe_scene_wallpaper* scene)
{
    clear_last_error();
    delete scene;
    return 0;
}

extern "C" int owe_scene_wallpaper_set_log_scope(owe_scene_wallpaper* scene, uint64_t scope)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (scene->scene.inited()) return finish_with_error("log scope must be set before init");
    scene->scene.setLogScope(scope);
    return 0;
}

extern "C" int owe_scene_wallpaper_init(owe_scene_wallpaper* scene)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (!scene->scene.init()) return finish_with_error("failed to initialize SceneWallpaper");
    return 0;
}

extern "C" int owe_scene_wallpaper_shutdown(owe_scene_wallpaper* scene)
{
    clear_last_error();
    if (scene == nullptr) return 0;

    scene->scene.shutdown();
    return 0;
}

extern "C" int owe_scene_wallpaper_init_metal_vulkan(
    owe_scene_wallpaper* scene,
    void* metal_layer,
    uint32_t width,
    uint32_t height,
    uint32_t render_width,
    uint32_t render_height,
    double display_scale_factor)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (metal_layer == nullptr) return finish_with_error("metal_layer must not be null");

    std::string error;
    if (!validate_dimensions(width, height, &error)) return finish_with_error(error);
    if (!validate_render_resolution(render_width, render_height, &error)) {
        return finish_with_error(error);
    }

    scene->scene.initVulkan(make_render_init_info(
        metal_layer,
        width,
        height,
        render_width,
        render_height,
        display_scale_factor));
    return 0;
}

extern "C" int owe_scene_wallpaper_begin_surface_reconfigure(owe_scene_wallpaper* scene)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");

    if (!scene->scene.beginSurfaceReconfigure()) {
        return finish_with_error("surface reconfigure begin failed");
    }
    return 0;
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
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (metal_layer == nullptr) return finish_with_error("metal_layer must not be null");

    std::string error;
    if (!validate_dimensions(width, height, &error)) return finish_with_error(error);
    if (!validate_render_resolution(render_width, render_height, &error)) {
        return finish_with_error(error);
    }

    if (!scene->scene.finishSurfaceReconfigure(make_render_init_info(
            metal_layer,
            width,
            height,
            render_width,
            render_height,
            display_scale_factor)))
    {
        return finish_with_error("surface reconfigure finish failed");
    }
    return 0;
}

extern "C" int owe_scene_wallpaper_apply_config(
    owe_scene_wallpaper* scene,
    const char* source,
    const char* assets,
    const char* cache_path,
    uint32_t fps,
    bool paused,
    bool force_shader_refresh,
    const char* project_property_override_json)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (source == nullptr || source[0] == '\0') {
        return finish_with_error("source must not be empty");
    }
    if (fps == 0) return finish_with_error("fps must be greater than zero");

    wallpaper::SceneWallpaperConfig config;
    config.source = std::string(view_or_empty(source));
    config.assets = std::string(view_or_empty(assets));
    config.cache_path = std::string(view_or_empty(cache_path));
    config.fps = fps;
    config.paused = paused;
    config.force_shader_refresh = force_shader_refresh;
    config.has_project_property_override = project_property_override_json != nullptr;
    config.project_property_override_json =
        std::string(view_or_empty(project_property_override_json));
    scene->scene.applyConfig(config);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_target_fps(owe_scene_wallpaper* scene, uint32_t fps)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (fps == 0) return finish_with_error("fps must be greater than zero");

    scene->scene.setTargetFps(fps);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_paused(owe_scene_wallpaper* scene, bool paused)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");

    scene->scene.setPaused(paused);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_render_scale(owe_scene_wallpaper* scene, double scale)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (!std::isfinite(scale) || scale <= 0.0) {
        return finish_with_error("render scale must be a positive finite value");
    }

    scene->scene.setPropertyFloat(wallpaper::PROPERTY_RENDER_SCALE, static_cast<float>(scale));
    return 0;
}

extern "C" int owe_scene_wallpaper_set_framing(owe_scene_wallpaper* scene, double pan_x,
                                               double pan_y)
{
    // No log line on this path: a drag sets it many times a second.
    try {
        clear_last_error();
        if (!valid_scene(scene)) return finish_with_error("scene must not be null");
        if (!std::isfinite(pan_x) || !std::isfinite(pan_y)) {
            return finish_with_error("framing must be finite");
        }

        scene->scene.setFraming(wallpaper::WallpaperFraming { pan_x, pan_y });
        return 0;
    } catch (...) {
        return finish_with_error_noexcept("failed to set framing");
    }
}

extern "C" int owe_scene_wallpaper_set_first_frame_callback(
    owe_scene_wallpaper* scene,
    owe_first_frame_callback callback,
    void* user_data,
    owe_first_frame_callback_drop drop_user_data)
{
    try {
        clear_last_error();
        if (!valid_scene(scene)) return finish_with_error("scene must not be null");

        auto registration = std::make_shared<FirstFrameCallbackRegistration>(
            callback, user_data, nullptr);
        auto forwarder = std::make_shared<wallpaper::FirstFrameCallback>(
            [registration]() { (*registration)(); });
        scene->scene.setPropertyObject(wallpaper::PROPERTY_FIRST_FRAME_CALLBACK, forwarder);
        registration->drop_user_data = drop_user_data;
        scene->first_frame_callback = std::move(registration);
        return 0;
    } catch (...) {
        return finish_with_error_noexcept("failed to register first-frame callback");
    }
}

extern "C" int owe_scene_wallpaper_set_pointer_input_callback(
    owe_scene_wallpaper* scene,
    owe_pointer_input_callback callback,
    void* user_data,
    owe_pointer_input_callback_drop drop_user_data)
{
    try {
        clear_last_error();
        if (!valid_scene(scene)) return finish_with_error("scene must not be null");
        if (!scene->scene.inited()) return finish_with_error("scene must be initialized");

        // Keep drop unarmed until enqueue succeeds. The local owner pins the
        // registration even when the looper executes the replay before return.
        auto registration =
            std::make_shared<PointerInputCallbackRegistration>(callback, user_data);
        auto forwarder = std::make_shared<wallpaper::PointerInputCallback>(
            [registration](bool accepts) { (*registration)(accepts); });
        scene->scene.setPropertyObject(wallpaper::PROPERTY_POINTER_INPUT_CALLBACK, forwarder);
        registration->drop_user_data = drop_user_data;
        scene->pointer_input_callback = std::move(registration);
        return 0;
    } catch (...) {
        return finish_with_error_noexcept("failed to register pointer-input callback");
    }
}

extern "C" int owe_scene_wallpaper_set_user_shortcut_callback(
    owe_scene_wallpaper* scene,
    owe_user_shortcut_callback callback,
    void* user_data,
    owe_user_shortcut_callback_drop drop_user_data)
{
    try {
        clear_last_error();
        if (!valid_scene(scene)) return finish_with_error("scene must not be null");
        if (!scene->scene.inited()) return finish_with_error("scene must be initialized");

        // Keep drop unarmed until the registration is installed, exactly as the
        // pointer callback does: a failure here must not consume user_data.
        auto registration =
            std::make_shared<UserShortcutCallbackRegistration>(callback, user_data);
        auto forwarder = std::make_shared<wallpaper::UserShortcutCallback>(
            [registration](std::string_view name, std::string_view value) {
                (*registration)(name, value);
            });
        scene->scene.setPropertyObject(wallpaper::PROPERTY_USER_SHORTCUT_CALLBACK, forwarder);
        registration->drop_user_data = drop_user_data;
        scene->user_shortcut_callback = std::move(registration);
        return 0;
    } catch (...) {
        return finish_with_error_noexcept("failed to register user-shortcut callback");
    }
}

extern "C" int owe_scene_wallpaper_set_audio_requirement_callback(
    owe_scene_wallpaper* scene,
    owe_audio_requirement_callback callback,
    void* user_data,
    owe_audio_requirement_callback_drop drop_user_data)
{
    try {
        clear_last_error();
        if (!valid_scene(scene)) return finish_with_error("scene must not be null");
        if (!scene->scene.inited()) return finish_with_error("scene must be initialized");

        // Keep drop unarmed until the registration is installed, as the pointer
        // callback does: a failure here must not consume user_data.
        auto registration =
            std::make_shared<AudioRequirementCallbackRegistration>(callback, user_data);
        auto forwarder = std::make_shared<wallpaper::AudioRequirementCallback>(
            [registration](bool requires_audio) { (*registration)(requires_audio); });
        scene->scene.setPropertyObject(wallpaper::PROPERTY_AUDIO_REQUIREMENT_CALLBACK, forwarder);
        registration->drop_user_data = drop_user_data;
        scene->audio_requirement_callback = std::move(registration);
        return 0;
    } catch (...) {
        return finish_with_error_noexcept("failed to register audio-requirement callback");
    }
}

extern "C" int owe_scene_wallpaper_set_render_failure_callback(
    owe_scene_wallpaper* scene,
    owe_render_failure_callback callback,
    void* user_data,
    owe_render_failure_callback_drop drop_user_data)
{
    try {
        clear_last_error();
        if (!valid_scene(scene)) return finish_with_error("scene must not be null");
        if (!scene->scene.inited()) return finish_with_error("scene must be initialized");

        // Keep drop unarmed until the registration is installed, as the other
        // callbacks do: a failure here must not consume user_data.
        auto registration =
            std::make_shared<RenderFailureCallbackRegistration>(callback, user_data);
        auto forwarder = std::make_shared<wallpaper::RenderFailureCallback>(
            [registration]() { (*registration)(); });
        scene->scene.setPropertyObject(wallpaper::PROPERTY_RENDER_FAILURE_CALLBACK, forwarder);
        registration->drop_user_data = drop_user_data;
        scene->render_failure_callback = std::move(registration);
        return 0;
    } catch (...) {
        return finish_with_error_noexcept("failed to register render-failure callback");
    }
}

extern "C" int owe_scene_wallpaper_mouse_input(owe_scene_wallpaper* scene, double x, double y)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (!std::isfinite(x) || !std::isfinite(y)) return finish_with_error("mouse coordinates must be finite");

    scene->scene.mouseInput(x, y);
    return 0;
}

extern "C" int owe_scene_wallpaper_mouse_button(owe_scene_wallpaper* scene, int button, bool pressed)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (button < 0 || button > 31) return finish_with_error("mouse button must be in range 0..31");

    scene->scene.mouseButton(button, pressed);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_mouse_button_baseline(
    owe_scene_wallpaper* scene, uint32_t down)
{
    try {
        clear_last_error();
        if (!valid_scene(scene)) return finish_with_error("scene must not be null");
        if (!scene->scene.inited()) return finish_with_error("scene must be initialized");

        scene->scene.mouseButtonBaseline(down);
        return 0;
    } catch (...) {
        return finish_with_error_noexcept("failed to set mouse-button baseline");
    }
}

extern "C" int owe_scene_wallpaper_mouse_enter(owe_scene_wallpaper* scene, bool entered)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");

    scene->scene.mouseEnter(entered);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_property_bool(
    owe_scene_wallpaper* scene,
    const char* name,
    bool value)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (name == nullptr || name[0] == '\0') return finish_with_error("property name is empty");

    scene->scene.setPropertyBool(name, value);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_property_int32(
    owe_scene_wallpaper* scene,
    const char* name,
    int32_t value)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (name == nullptr || name[0] == '\0') return finish_with_error("property name is empty");

    scene->scene.setPropertyInt32(name, value);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_property_float(
    owe_scene_wallpaper* scene,
    const char* name,
    float value)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (name == nullptr || name[0] == '\0') return finish_with_error("property name is empty");

    scene->scene.setPropertyFloat(name, value);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_property_string(
    owe_scene_wallpaper* scene,
    const char* name,
    const char* value)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (name == nullptr || name[0] == '\0') return finish_with_error("property name is empty");

    scene->scene.setPropertyString(name, std::string(view_or_empty(value)));
    return 0;
}

extern "C" int owe_scene_wallpaper_set_audio_volume(owe_scene_wallpaper* scene, float volume)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (!std::isfinite(volume) || volume < 0.0f || volume > 1.0f) {
        return finish_with_error("audio volume must be finite and between 0.0 and 1.0");
    }

    scene->scene.setPropertyFloat(wallpaper::PROPERTY_VOLUME, volume);
    return 0;
}

extern "C" int owe_scene_wallpaper_set_audio_muted(owe_scene_wallpaper* scene, bool muted)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");

    scene->scene.setPropertyBool(wallpaper::PROPERTY_MUTED, muted);
    return 0;
}

extern "C" int owe_scene_wallpaper_submit_media_event_json(
    owe_scene_wallpaper* scene,
    const char* event_json)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (event_json == nullptr || event_json[0] == '\0') {
        return finish_with_error("media event json must not be empty");
    }

    scene->scene.setPropertyString(
        wallpaper::PROPERTY_MEDIA_EVENT_JSON,
        std::string(event_json));
    return 0;
}

extern "C" int owe_scene_wallpaper_apply_system_media_artwork(
    owe_scene_wallpaper* scene,
    uint32_t width,
    uint32_t height,
    const uint8_t* rgba,
    uintptr_t rgba_len)
{
    clear_last_error();
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (!wallpaper::IsValidSystemMediaArtwork(width, height, rgba, static_cast<std::size_t>(rgba_len))) {
        return finish_with_error("media artwork must be complete RGBA pixels or the empty clear value");
    }

    scene->scene.applySystemMediaArtwork(
        width,
        height,
        rgba,
        static_cast<std::size_t>(rgba_len));
    return 0;
}

extern "C" const char* owe_property_scaling_mode(void)
{
    return property_name(wallpaper::PROPERTY_SCALINGMODE);
}

extern "C" const char* owe_property_scaling_factor(void)
{
    return property_name(wallpaper::PROPERTY_SCALINGFACTOR);
}

extern "C" const char* owe_property_horizontal_flip(void)
{
    return property_name(wallpaper::PROPERTY_HORIZONTAL_FLIP);
}

extern "C" const char* owe_property_audio_response_enabled(void)
{
    return property_name(wallpaper::PROPERTY_AUDIO_RESPONSE_ENABLED);
}

extern "C" const char* owe_property_media_integration_enabled(void)
{
    return property_name(wallpaper::PROPERTY_MEDIA_INTEGRATION_ENABLED);
}

extern "C" const char* owe_property_force_shader_refresh(void)
{
    return property_name(wallpaper::PROPERTY_FORCE_SHADER_REFRESH);
}

extern "C" const char* owe_property_project_property_override_json(void)
{
    return property_name(wallpaper::PROPERTY_PROJECT_PROPERTY_OVERRIDE_JSON);
}

extern "C" const char* owe_property_project_property_reset(void)
{
    return property_name(wallpaper::PROPERTY_PROJECT_PROPERTY_RESET);
}

extern "C" const char* owe_property_project_property_preview_json(void)
{
    return property_name(wallpaper::PROPERTY_PROJECT_PROPERTY_PREVIEW_JSON);
}

extern "C" void owe_set_content_pacing_enabled(bool enabled)
{
    wallpaper::video::SetContentPacingEnabled(enabled);
}

extern "C" bool owe_content_pacing_enabled(void)
{
    return wallpaper::video::ContentPacingEnabled();
}

extern "C" void owe_set_shared_video_decode_enabled(bool enabled)
{
    wallpaper::video::SetSharedVideoDecodeEnabled(enabled);
}

extern "C" bool owe_shared_video_decode_enabled(void)
{
    return wallpaper::video::SharedVideoDecodeEnabled();
}

extern "C" uint32_t owe_shared_video_decode_session_count(void)
{
    return wallpaper::video::SharedVideoDecodeSessionCount();
}

extern "C" uint32_t owe_shared_video_decode_consumer_count(void)
{
    return wallpaper::video::SharedVideoDecodeConsumerCount();
}

extern "C" int owe_audio_spectrum_is_stereo(void)
{
    const auto snapshot = wallpaper::audio::CurrentAudioSpectrumSnapshot();
    if (snapshot.generation == 0) return -1;
    return snapshot.stereo ? 1 : 0;
}

extern "C" void owe_set_scene_optimization_enabled(bool enabled)
{
    wallpaper::vulkan::SetSceneOptimizationEnabled(enabled);
}

extern "C" bool owe_scene_optimization_enabled(void)
{
    return wallpaper::vulkan::SceneOptimizationEnabled();
}

extern "C" void owe_scene_optimization_stats(
    uint64_t* out_executed_passes,
    uint64_t* out_skipped_passes,
    uint64_t* out_elided_copies,
    uint64_t* out_pinned_bytes)
{
    const auto totals = wallpaper::vulkan::CurrentSceneOptimizationTotals();
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

extern "C" void owe_set_scene_renderer_preference(int preference)
{
    // An unrecognised value falls back to compatibility rather than being
    // stored: a host built against a newer enum must not silently select a
    // backend this binary does not have.
    const auto value = preference == OWE_SCENE_RENDERER_NATIVE_METAL_PREFERRED
                           ? wallpaper::SceneRendererPreference::NativeMetalPreferred
                           : wallpaper::SceneRendererPreference::Compatibility;
    wallpaper::SetSceneRendererPreference(value);
    // A remembered prepare failure is only meaningful for the preference that
    // was in force when it happened. Turning the preference off and on again is
    // the one deliberate act that makes the question worth asking a second
    // time, so the record is cleared here rather than aged out on a timer.
    wallpaper::metal::ForgetMetalPrepareFailures();
}

extern "C" int owe_current_scene_renderer_preference(void)
{
    switch (wallpaper::CurrentSceneRendererPreference()) {
    case wallpaper::SceneRendererPreference::NativeMetalPreferred:
        return OWE_SCENE_RENDERER_NATIVE_METAL_PREFERRED;
    case wallpaper::SceneRendererPreference::Compatibility:
        break;
    }
    return OWE_SCENE_RENDERER_COMPATIBILITY;
}

extern "C" int owe_scene_wallpaper_backend(void* scene)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return -1;
    const auto selection = wallpaper_scene->sceneBackendSelection();
    // Same -1 as "no scene": the host shows it as preparing. A backend is only
    // chosen once the scene is parsed, and naming one before that would make
    // the panel claim a renderer that has not been created.
    if (! selection.created) return -1;
    switch (selection.backend) {
    case wallpaper::SceneBackend::NativeMetal: return OWE_SCENE_BACKEND_NATIVE_METAL;
    case wallpaper::SceneBackend::LegacyVulkan: break;
    }
    return OWE_SCENE_BACKEND_LEGACY_VULKAN;
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

extern "C" size_t owe_scene_wallpaper_backend_fallback_reason(void* scene, char* out,
                                                              size_t out_len)
{
    auto* wallpaper_scene = static_cast<wallpaper::SceneWallpaper*>(scene);
    if (wallpaper_scene == nullptr) return 0;
    const auto reason = wallpaper_scene->sceneBackendSelection().fallback_reason;
    if (reason.empty()) return 0;
    // Sizing call: report what would be needed without writing anything.
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
    std::string error;
    if (!wallpaper::audio::SubmitMonoAudioFrames(sample_rate, frame_count, pcm_frames, &error)) {
        return finish_with_error(error);
    }
    return 0;
}

extern "C" int owe_audio_submit_frames(
    uint32_t sample_rate,
    uint32_t frame_count,
    const float* pcm_frames)
{
    clear_last_error();
    std::string error;
    if (!wallpaper::audio::SubmitAudioFrames(sample_rate, frame_count, pcm_frames, &error)) {
        return finish_with_error(error);
    }
    return 0;
}

extern "C" int owe_audio_current_spectrum_128(
    float* out_bins,
    uintptr_t out_len,
    uint64_t* out_generation)
{
    clear_last_error();
    if (out_bins == nullptr) {
        return finish_with_error("out_bins must not be null");
    }
    if (out_len < 128u) {
        return finish_with_error("out_len must be at least 128");
    }

    const auto sanitize_audio_bin = [](float value) -> float {
        if (! std::isfinite(value)) {
            return 0.0f;
        }
        return std::clamp(value, 0.0f, 1.0f);
    };

    const auto snapshot = wallpaper::audio::CurrentAudioSpectrumSnapshot();
    for (size_t i = 0; i < 64u; ++i) {
        out_bins[i]       = sanitize_audio_bin(snapshot.left64[i]);
        out_bins[i + 64u] = sanitize_audio_bin(snapshot.right64[i]);
    }
    if (out_generation != nullptr) {
        *out_generation = snapshot.generation;
    }
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
    if (!valid_scene(scene)) return finish_with_error("scene must not be null");
    if (out_values == nullptr) return finish_with_error("out_values must not be null");

    const std::size_t written = scene->scene.counters(out_values, static_cast<std::size_t>(out_len));
    if (out_written != nullptr) *out_written = written;
    return 0;
}

extern "C" int owe_renderer_shared_counters(
    uint64_t* out_values,
    uintptr_t out_len,
    uintptr_t* out_written)
{
    clear_last_error();
    if (out_values == nullptr) return finish_with_error("out_values must not be null");

    // The audio analysis worker already accounts for itself; reading its
    // snapshot avoids adding any bookkeeping to the real-time callback.
    const auto        snapshot = wallpaper::audio::CurrentAudioSpectrumSnapshot();
    const uint64_t    values[OWE_RC_SHARED_COUNT] = {
        snapshot.generation,
        snapshot.accepted_frame_count,
    };
    const std::size_t written =
        std::min(static_cast<std::size_t>(out_len), static_cast<std::size_t>(OWE_RC_SHARED_COUNT));
    for (std::size_t i = 0; i < written; ++i) out_values[i] = values[i];
    if (out_written != nullptr) *out_written = written;
    return 0;
}

extern "C" const char* owe_last_error(void)
{
    return g_last_error.c_str();
}
