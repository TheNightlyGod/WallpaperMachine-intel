#pragma once

#include <cstdint>

namespace wallpaper::video
{

struct VideoMetadata
{
    uint32_t width { 0 };
    uint32_t height { 0 };
    double   duration_seconds { 0.0 };
};

} // namespace wallpaper::video
