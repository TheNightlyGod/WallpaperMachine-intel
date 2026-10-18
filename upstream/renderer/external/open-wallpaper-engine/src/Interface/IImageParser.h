#pragma once
#include "Image.hpp"
#include <algorithm>
//#include "Fs/VFS.h"
#include <memory>
#include <string>

namespace wallpaper
{
class IImageParser {
public:
    IImageParser()                                                 = default;
    virtual ~IImageParser()                                        = default;
    virtual std::shared_ptr<Image> Parse(const std::string&)       = 0;
    virtual ImageHeader            ParseHeader(const std::string&) = 0;

    // Set before preparing textures, including parallel prefetch. A zero-sized
    // surface keeps the authored resolution for asset-only callers. A leading
    // mip is dropped only while the next one is still at least as long as the
    // surface's longest side, so the level kept covers the surface unless the
    // texture itself is smaller; a texture is never drawn magnified for the sake
    // of memory.
    // ponytail: display-sized budget; use projected layer coverage if zoom needs finer detail.
    virtual void SetTextureSurfaceSize(uint32_t width, uint32_t height) {
        m_texture_surface_longest_side = width && height ? uint64_t(std::max(width, height)) : 0;
    }

protected:
    uint64_t m_texture_surface_longest_side { 0 };
};
} // namespace wallpaper
