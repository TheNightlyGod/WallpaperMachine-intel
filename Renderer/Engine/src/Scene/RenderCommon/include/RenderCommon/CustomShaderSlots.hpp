// Clean-room implementation from the WallpaperMachine spec e1c-render-graph.md; written without access to the original source.
#pragma once

#include "SpecTexs.hpp"
#include "Type.hpp"
#include "Utils/Algorism.h"

#include <charconv>
#include <optional>
#include <string_view>
#include <system_error>

namespace wallpaper
{
namespace render
{

// Which `g_TextureN` slot a shader binding name stands for. Everything
// reads the shader's own reflected names this way, so the slot a
// sampler or texture binds to has one definition.
inline std::optional<usize> CustomShaderTextureSlot(std::string_view name) {
    constexpr std::string_view prefix { "g_Texture" };
    if (name.size() <= prefix.size() || name.substr(0, prefix.size()) != prefix) return std::nullopt;
    const std::string_view digits = name.substr(prefix.size());
    for (char c : digits) {
        if (c < '0' || c > '9') return std::nullopt;
    }
    if (digits.size() > 1 && digits.front() == '0') return std::nullopt;
    usize slot { 0 };
    const auto [end, error] = std::from_chars(digits.data(), digits.data() + digits.size(), slot);
    if (error != std::errc {} || end != digits.data() + digits.size()) return std::nullopt;
    if (slot >= WE_GLTEX_NAMES.size()) return std::nullopt;
    return slot;
}

inline std::optional<usize> CustomShaderSamplerSlot(std::string_view name) {
    constexpr std::string_view prefix { "_we_Sampler_" };
    if (name.size() <= prefix.size() || name.substr(0, prefix.size()) != prefix) return std::nullopt;
    return CustomShaderTextureSlot(name.substr(prefix.size()));
}

} // namespace render
} // namespace wallpaper
