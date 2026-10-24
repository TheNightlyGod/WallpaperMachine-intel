#pragma once
#include "Image.hpp"
#include <algorithm>
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

    virtual void SetTextureSurfaceSize(uint32_t width, uint32_t height) {
        m_texture_surface_longest_side = width && height ? uint64_t(std::max(width, height)) : 0;
    }

protected:
    uint64_t m_texture_surface_longest_side { 0 };
};
} // namespace wallpaper
