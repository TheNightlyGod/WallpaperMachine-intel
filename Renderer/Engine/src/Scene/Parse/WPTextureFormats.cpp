// Clean-room implementation from the WallpaperMachine spec p6-textures-packages.md; written without access to the original source.
#include "WPTextureFormats.hpp"

#include <array>

namespace wallpaper
{
namespace
{
using F = TextureFormat;

// Codes and names as `sub_1401E53A0` (WE 2.8.0.42) lists them; the names' case is the binary's
// (`rgba16161616S` and `rgba8888s` differ). How each uploads was read off Wallpaper Engine with
// the texshader probe (artifacts/we-parity/decompiles/E-D3.md): the three-channel and packed names
// (1, 2, 15, 18, 20) are read with the stride of their four-channel twin, and `rgba8888s` reads
// as unsigned; `rgba16161616S` is signed.
constexpr std::array<WeTextureFormat, 19> kFormats { {
    { 0, "rgba8888", F::RGBA8, 4, F::RGBA8 },
    { 1, "rgb888", F::RGBA8, 4, F::RGBA8 },
    { 2, "rgb565", F::RGBA8, 4, F::RGBA8 },
    { 4, "dxt5", F::BC3, 0, F::RGBA8 },
    { 6, "dxt3", F::BC2, 0, F::RGBA8 },
    { 7, "dxt1", F::BC1, 0, F::RGBA8 },
    { 8, "rg88", F::RG8, 2, F::RG8 },
    { 9, "r8", F::R8, 1, F::R8 },
    { 10, "rg1616f", F::RG16F, 4, F::RG16F },
    { 11, "r16f", F::R16F, 2, F::R16F },
    { 12, "bc7", F::BC7, 0, F::RGBA8 },
    { 13, "rgba1010102", F::RGB10A2, 4, F::RGB10A2 },
    { 14, "rgba16161616f", F::RGBA16F, 8, F::RGBA16F },
    { 15, "rgb161616f", F::RGBA16F, 8, F::RGBA16F },
    { 17, "rgba16161616", F::RGBA16, 8, F::RGBA16 },
    { 18, "rgb161616", F::RGBA16, 8, F::RGBA16 },
    { 19, "rgba16161616S", F::RGBA16S, 8, F::RGBA16S },
    { 20, "rgb161616S", F::RGBA16S, 8, F::RGBA16S },
    { 21, "rgba8888s", F::RGBA8, 4, F::RGBA8 },
} };

u64 BlockBytes(TextureFormat format)
{
    switch (format) {
    case F::BC1: return 8;
    case F::BC2:
    case F::BC3:
    case F::BC7: return 16;
    default: return 0;
    }
}
} // namespace

const WeTextureFormat* WeFormatOfCode(i32 code)
{
    for (const auto& row : kFormats) {
        if (row.code == code) return &row;
    }
    return nullptr;
}

const WeTextureFormat* WeFormatOfName(std::string_view name)
{
    for (const auto& row : kFormats) {
        if (row.name == name) return &row;
    }
    return nullptr;
}

u64 WeStoredBytes(const WeTextureFormat& row, i32 width, i32 height, i32 depth)
{
    if (width <= 0 || height <= 0 || depth <= 0) return 0;
    const u64 w = static_cast<u64>(width);
    const u64 h = static_cast<u64>(height);
    const u64 d = static_cast<u64>(depth);
    if (const u64 block = BlockBytes(row.upload); block > 0) return ((w + 3) / 4) * ((h + 3) / 4) * block * d;
    return w * h * d * row.stored_bytes_per_pixel;
}

} // namespace wallpaper
