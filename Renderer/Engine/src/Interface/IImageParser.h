#pragma once
#include "Image.hpp"
#include <algorithm>
#include <memory>
#include <string>
#include <string_view>
#include <functional>

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

    /// Answers a texture variant record's condition (TEXB0004, `sub_14015C8D0`): whether the
    /// user property `name` currently is the choice `condition` names. An empty condition
    /// asks whether `name` is set at all. Without one every record falls back to its default.
    using VariantCondition = std::function<bool(std::string_view name, std::string_view condition)>;
    virtual void SetVariantCondition(VariantCondition condition) { m_variant_condition = std::move(condition); }

protected:
    uint64_t m_texture_surface_longest_side { 0 };
    VariantCondition m_variant_condition;
};
} // namespace wallpaper
