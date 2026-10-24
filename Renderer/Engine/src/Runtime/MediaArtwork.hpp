#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>

namespace wallpaper
{
inline bool IsClearSystemMediaArtwork(uint32_t width, uint32_t height, size_t length) {
    return width == 0 && height == 0 && length == 0;
}

inline bool IsValidSystemMediaArtwork(uint32_t width, uint32_t height,
                                      const uint8_t* rgba, size_t length) {
    if (IsClearSystemMediaArtwork(width, height, length)) return true;
    if (width == 0 || height == 0 || rgba == nullptr ||
        width > uint32_t(std::numeric_limits<int32_t>::max()) ||
        height > uint32_t(std::numeric_limits<int32_t>::max())) return false;
    if (size_t(width) > std::numeric_limits<size_t>::max() / height / 4) return false;
    return length == size_t(width) * height * 4;
}
} // namespace wallpaper
