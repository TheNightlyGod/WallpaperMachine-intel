// Clean-room implementation from the WallpaperMachine spec e6-platform-host-api.md; written without access to the original source.
#pragma once

#include "WPShaderParser.hpp"

#include <string>

namespace wallpaper::shader
{

inline void ApplyTextureFormatCombo(Combos& combos, usize slot, TextureFormat format)
{
    const char* value = nullptr;
    switch (format) {
    case TextureFormat::R8: value = "9"; break;
    case TextureFormat::RG8: value = "8"; break;
    default: return;
    }
    combos["TEX" + std::to_string(slot) + "FORMAT"] = value;
}

} // namespace wallpaper::shader
