// Clean-room implementation from the WallpaperMachine spec e6-platform-host-api.md; written without access to the original source.
#pragma once

#include "WPShaderParser.hpp"

#include <string>

namespace wallpaper::shader
{

/// `TEX<slot>FORMAT` is the Wallpaper Engine format code of the file texture in that slot, for
/// slots 0-9 and every code, 0 included (`sub_1401A5C40` writes tex+24 for each of them, WE
/// 2.8.0.42). Shaders compare it against `FORMAT_*` and some use it bare (`fur4.frag`
/// `ConvertTextureFormat(TEX8FORMAT, ...)`), so it is always defined for a file texture.
inline void ApplyTextureFormatCombo(Combos& combos, usize slot, i32 we_code)
{
    if (slot >= 10) return;
    combos["TEX" + std::to_string(slot) + "FORMAT"] = std::to_string(we_code);
}

} // namespace wallpaper::shader
