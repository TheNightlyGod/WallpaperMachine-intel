// Clean-room implementation from the WallpaperMachine spec e6-platform-host-api.md; written without access to the original source.
#include "Presentation/WallpaperScaling.hpp"

#include <algorithm>
#include <cmath>

namespace wallpaper
{

std::optional<WallpaperScalingMode> WallpaperScalingModeFromValue(int64_t value)
{
    if (value < static_cast<int64_t>(WallpaperScalingMode::NONE) ||
        value > static_cast<int64_t>(WallpaperScalingMode::FIT_BLURRED)) {
        return std::nullopt;
    }
    return static_cast<WallpaperScalingMode>(value);
}

WallpaperScalingLayout ComputeWallpaperScalingLayout(
    WallpaperScalingMode mode,
    uint32_t scene_width,
    uint32_t scene_height,
    uint32_t display_logical_width,
    uint32_t display_logical_height,
    double display_scale_factor,
    double wallpaper_scale_factor,
    double pan_x,
    double pan_y)
{
    const auto usable = [](double v) { return std::isfinite(v) && v > 0.0 ? v : 1.0; };
    const double user_factor = usable(wallpaper_scale_factor);
    const double dpr         = usable(display_scale_factor);
    const WallpaperFraming pan = NormalizeWallpaperFraming(WallpaperFraming { pan_x, pan_y });

    const double scene_w   = std::max<uint32_t>(1, scene_width);
    const double scene_h   = std::max<uint32_t>(1, scene_height);
    const double display_w = std::max<uint32_t>(1, display_logical_width);
    const double display_h = std::max<uint32_t>(1, display_logical_height);
    const double ratio_x   = display_w / scene_w;
    const double ratio_y   = display_h / scene_h;

    double scale_x = 1.0;
    double scale_y = 1.0;
    switch (mode) {
    case WallpaperScalingMode::STRETCH:
        scale_x = ratio_x;
        scale_y = ratio_y;
        break;
    case WallpaperScalingMode::FIT:
    case WallpaperScalingMode::FIT_BLURRED: scale_x = scale_y = std::min(ratio_x, ratio_y); break;
    case WallpaperScalingMode::FILL: scale_x = scale_y = std::max(ratio_x, ratio_y); break;
    case WallpaperScalingMode::NONE:
    default: break;
    }
    scale_x *= user_factor;
    scale_y *= user_factor;

    const double content_w = scene_w * scale_x;
    const double content_h = scene_h * scale_y;
    const double x         = (display_w - content_w) * pan.pan_x;
    const double y         = (display_h - content_h) * pan.pan_y;
    const auto   px        = [](double v) { return static_cast<int32_t>(std::lround(v)); };

    WallpaperScalingLayout layout;
    layout.scene_width            = scene_w;
    layout.scene_height           = scene_h;
    layout.display_logical_width  = display_w;
    layout.display_logical_height = display_h;
    layout.scale_x                = scale_x;
    layout.scale_y                = scale_y;
    layout.viewport_px = PixelRect { px(x * dpr), px(y * dpr), px(content_w * dpr),
                                     px(content_h * dpr) };
    layout.scissor_px  = PixelRect { 0, 0, px(display_w * dpr), px(display_h * dpr) };

    if (mode == WallpaperScalingMode::FIT_BLURRED) {
        // The copy covers the display the way Fill at a factor of 1 would and stays centred:
        // neither the picture's position nor its factor moves it.
        const double fill_scale = std::max(ratio_x, ratio_y);
        const double fill_w     = scene_w * fill_scale;
        const double fill_h     = scene_h * fill_scale;
        layout.backdrop_px = PixelRect { px((display_w - fill_w) * 0.5 * dpr), px((display_h - fill_h) * 0.5 * dpr),
                                         px(fill_w * dpr), px(fill_h * dpr) };
        // One pixel of gap is what rounding leaves when the shapes match: no room.
        layout.backdrop = layout.scissor_px.width - layout.viewport_px.width > 1 ||
                          layout.scissor_px.height - layout.viewport_px.height > 1;
    }
    return layout;
}

WallpaperCursorMapping ComputeWallpaperCursorMapping(const WallpaperScalingLayout& layout,
                                                     double camera_center_x, double camera_center_y,
                                                     double camera_width, double camera_height) {
    const double viewport_width  = layout.viewport_px.width;
    const double viewport_height = layout.viewport_px.height;
    const double window_width    = layout.scissor_px.width;
    const double window_height   = layout.scissor_px.height;
    if (viewport_width <= 0.0 || viewport_height <= 0.0 || window_width <= 0.0 ||
        window_height <= 0.0 || ! std::isfinite(camera_width) || ! std::isfinite(camera_height) ||
        camera_width <= 0.0 || camera_height <= 0.0 || ! std::isfinite(camera_center_x) ||
        ! std::isfinite(camera_center_y)) {
        return {};
    }

    // Window pixel -> presented-image fraction -> camera world coordinate.
    const auto world_x = [&](double pixel) {
        return camera_center_x +
               ((pixel - layout.viewport_px.x) / viewport_width - 0.5) * camera_width;
    };
    const auto world_y = [&](double pixel) {
        return camera_center_y +
               (0.5 - (pixel - layout.viewport_px.y) / viewport_height) * camera_height;
    };

    const double left   = world_x(0.0);
    const double bottom = world_y(window_height);
    return WallpaperCursorMapping {
        .origin_x = left,
        .origin_y = bottom,
        .size_x   = world_x(window_width) - left,
        .size_y   = world_y(0.0) - bottom,
        // The drawn image is exactly the camera rectangle, however the viewport
        // is cropped or letterboxed against the window.
        .content_origin_x = camera_center_x - 0.5 * camera_width,
        .content_origin_y = camera_center_y - 0.5 * camera_height,
        .content_size_x   = camera_width,
        .content_size_y   = camera_height,
        .valid            = true,
    };
}

} // namespace wallpaper
