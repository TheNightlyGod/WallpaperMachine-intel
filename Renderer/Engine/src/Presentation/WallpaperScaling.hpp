#pragma once

#include "Presentation/WallpaperFraming.hpp"

#include <cstdint>
#include <optional>

namespace wallpaper
{

enum class WallpaperScalingMode : std::uint8_t
{
    NONE = 0,
    STRETCH = 1,
    FIT = 2,
    FILL = 3,
    /// Fit, with a blurred copy of the picture in the room the picture leaves.
    FIT_BLURRED = 4,
};

/// The mode a host value names, or nothing when no mode has that value.
std::optional<WallpaperScalingMode> WallpaperScalingModeFromValue(int64_t value);

struct PixelRect {
    int32_t x { 0 };
    int32_t y { 0 };
    int32_t width { 0 };
    int32_t height { 0 };
};

struct WallpaperScalingLayout {
    double scene_width { 0.0 };
    double scene_height { 0.0 };
    double display_logical_width { 0.0 };
    double display_logical_height { 0.0 };
    double scale_x { 1.0 };
    double scale_y { 1.0 };
    PixelRect viewport_px {};
    PixelRect scissor_px {};
    /// Where the backdrop's picture sits: what Fill at a factor of 1 gives the picture,
    /// centred whatever the picture's position. Empty unless the mode has a backdrop.
    PixelRect backdrop_px {};
    /// Whether the picture leaves room (more than a pixel on an axis) for the backdrop.
    bool      backdrop { false };
};

// `pan_x` and `pan_y` are `WallpaperFraming` fractions and are clamped the same
// way. The defaults centre the wallpaper exactly as the layout always has.
WallpaperScalingLayout ComputeWallpaperScalingLayout(
    WallpaperScalingMode mode,
    uint32_t scene_width,
    uint32_t scene_height,
    uint32_t display_logical_width,
    uint32_t display_logical_height,
    double display_scale_factor,
    double wallpaper_scale_factor,
    double pan_x = 0.5,
    double pan_y = 0.5);

// World rectangle the window covers, expressed for a cursor given in
// window-normalized coordinates: world = origin + (x, 1 - y) * size. The
// content rectangle is the part of it the wallpaper actually draws, which is
// smaller than the window whenever the presentation letterboxes.
struct WallpaperCursorMapping {
    double origin_x { 0.0 };
    double origin_y { 0.0 };
    double size_x { 0.0 };
    double size_y { 0.0 };
    double content_origin_x { 0.0 };
    double content_origin_y { 0.0 };
    double content_size_x { 0.0 };
    double content_size_y { 0.0 };
    bool   valid { false };
};

// The presented image is the camera rectangle scaled into layout.viewport_px,
// which FILL deliberately pushes outside the window. Cursor coordinates must
// follow that mapping, or hit testing drifts from what the display shows.
WallpaperCursorMapping ComputeWallpaperCursorMapping(const WallpaperScalingLayout& layout,
                                                     double camera_center_x, double camera_center_y,
                                                     double camera_width, double camera_height);

} // namespace wallpaper
