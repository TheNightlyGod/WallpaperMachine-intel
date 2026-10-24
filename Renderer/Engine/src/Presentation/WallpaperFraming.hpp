#pragma once

#include <algorithm>
#include <cmath>

namespace wallpaper
{

// Where the presented wallpaper sits inside the slack the display leaves around
// it. Each axis is a fraction of that slack: 0 aligns the wallpaper's leading
// edge with the display's (left, and top), 1 its trailing edge (right, and
// bottom), 0.5 centres it. The slack is the display minus the wallpaper, so it
// is positive when the wallpaper leaves bars (Fit, Original size, a scale below
// 1) and negative when it overflows the display (Fill, a scale above 1); one
// fraction places it either way. An axis without slack, such as Stretch at a
// scale of 1, is unmoved by any value.
//
// Kept apart from the layout function so the scene's public header can carry it
// without pulling in the heavier headers that function's result types need.
struct WallpaperFraming {
    double pan_x { 0.5 };
    double pan_y { 0.5 };
};

// Each axis clamped to [0, 1]; a non-finite one becomes the centre.
inline double NormalizeWallpaperPan(double pan)
{
    if (!std::isfinite(pan)) return 0.5;
    return std::clamp(pan, 0.0, 1.0);
}

inline WallpaperFraming NormalizeWallpaperFraming(WallpaperFraming framing)
{
    return WallpaperFraming { NormalizeWallpaperPan(framing.pan_x),
                              NormalizeWallpaperPan(framing.pan_y) };
}

} // namespace wallpaper
