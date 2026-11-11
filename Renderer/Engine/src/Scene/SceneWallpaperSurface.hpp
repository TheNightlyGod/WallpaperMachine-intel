#pragma once
#include "SceneWallpaper.hpp"

#include <functional>
#include <memory>
#include <cstdint>
#include <span>

namespace wallpaper
{
using ReDrawCB = std::function<void()>;

struct RenderInitInfo {
    bool offscreen { false };

    /// The `CAMetalLayer` this surface presents to, when there is one: the
    /// layer the native Metal renderer adopts. Null off Apple platforms and in
    /// offscreen mode.
    void* metal_layer { nullptr };

    /// Keeps `metal_layer` alive for as long as this description is held, even
    /// if the host replaces its window layer before the renderer adopts it.
    /// Empty when the creator keeps the layer alive some other way.
    std::shared_ptr<void> metal_layer_owner;

    uint16_t width { 1920 };
    uint16_t height { 1080 };
    uint16_t render_width { 0 };
    uint16_t render_height { 0 };
    double   display_scale_factor { 1.0 };
    ReDrawCB redraw_callback;
    /// Output capability only: does not change the saved post-processing quality.
    bool display_hdr_output_allowed {true};
    uint32_t display_id {0};

    std::function<bool()> wants_poster;
    std::function<void(std::span<const uint8_t>, uint32_t, uint32_t, bool)> poster_ready;
    /// Lets the host wake the render handler when a poster is requested.
    ///
    /// `wants_poster` is only ever polled by a frame, so an idle or user-paused
    /// scene would leave a request pending forever. The render handler passes a
    /// closure here when it takes this info and passes an empty one back before
    /// the info is replaced or destroyed; the host holds its lock across both,
    /// so a notification already in flight cannot poke a handler that is going
    /// away.
    std::function<void(std::function<void()>)> bind_poster_wake;
};

} // namespace wallpaper
