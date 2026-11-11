// Clean-room implementation from the WallpaperMachine spec p6-textures-packages.md; written without access to the original source.
#pragma once

#include "Core/Literals.hpp"
#include "Type.hpp"

#include <string_view>

namespace wallpaper
{

/// One row of Wallpaper Engine's texture format table (`sub_1401E53A0`, WE 2.8.0.42).
struct WeTextureFormat {
    i32              code;
    std::string_view name;
    TextureFormat    upload;                 // what the GPU texture holds
    u32              stored_bytes_per_pixel; // 0 for block formats
    TextureFormat    target;                 // the render-target format the name stands for
};

/// The row for a file's format code; nullptr for a code the reference refuses (3, 5, 16, ...).
const WeTextureFormat* WeFormatOfCode(i32 code);
/// The row for a format name as written in effect/material JSON; nullptr when unknown
/// (the reference answers 0 for an unknown name).
const WeTextureFormat* WeFormatOfName(std::string_view name);

/// Bytes a level of `width` x `height` x `depth` needs in the file for `row`.
u64 WeStoredBytes(const WeTextureFormat& row, i32 width, i32 height, i32 depth = 1);

} // namespace wallpaper
