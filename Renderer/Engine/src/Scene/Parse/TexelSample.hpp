#pragma once
// One texel of a decoded image's mip-0 payload, for the CPU readers of a layer's
// picture: hit masks (alpha) and the `layerimage` particle emitter's emission map.

#include "Image.hpp"
#include "Type.hpp"

#include <array>
#include <cstdint>

namespace wallpaper
{

/// Whether `TexelRgba` can read `format`.
inline bool TexelSampleReads(TextureFormat format) {
    return format == TextureFormat::RGBA8 || format == TextureFormat::BC1 || format == TextureFormat::BC2 ||
           format == TextureFormat::BC3 || format == TextureFormat::R8 || format == TextureFormat::RG8;
}

namespace texel_detail
{
inline std::array<uint8_t, 3> Expand565(uint16_t v) {
    const uint16_t r = (v >> 11) & 31, g = (v >> 5) & 63, b = v & 31;
    return { static_cast<uint8_t>((r << 3) | (r >> 2)), static_cast<uint8_t>((g << 2) | (g >> 4)),
             static_cast<uint8_t>((b << 3) | (b >> 2)) };
}

/// RGB of texel (x, y) from the 8-byte BC1 colour block at `block`. `four_colour`
/// forces the opaque four-colour mode, as BC2 and BC3 colour blocks use.
inline std::array<uint8_t, 4> Bc1Colour(const uint8_t* block, int x, int y, bool four_colour) {
    const uint16_t c0 = static_cast<uint16_t>(block[0] | (block[1] << 8));
    const uint16_t c1 = static_cast<uint16_t>(block[2] | (block[3] << 8));
    const uint32_t bits =
        static_cast<uint32_t>(block[4]) | (static_cast<uint32_t>(block[5]) << 8) |
        (static_cast<uint32_t>(block[6]) << 16) | (static_cast<uint32_t>(block[7]) << 24);
    const unsigned index = (bits >> (2 * ((y % 4) * 4 + (x % 4)))) & 3u;
    const auto     a     = Expand565(c0);
    const auto     b     = Expand565(c1);
    std::array<uint8_t, 4> out { 0, 0, 0, 255 };
    const bool opaque = four_colour || c0 > c1;
    for (int k = 0; k < 3; ++k) {
        switch (index) {
        case 0: out[k] = a[k]; break;
        case 1: out[k] = b[k]; break;
        case 2: out[k] = static_cast<uint8_t>(opaque ? (2 * a[k] + b[k]) / 3 : (a[k] + b[k]) / 2); break;
        default: out[k] = static_cast<uint8_t>(opaque ? (a[k] + 2 * b[k]) / 3 : 0); break;
        }
    }
    if (! opaque && index == 3) out[3] = 0;
    return out;
}
} // namespace texel_detail

/// RGBA of one texel. Unsupported formats read as opaque white; invalid
/// coordinates and truncated payloads read as transparent black.
inline std::array<uint8_t, 4> TexelRgba(const ImageData& mip, TextureFormat format, i32 x, i32 y) {
    if (!mip.data || x < 0 || y < 0 || x >= mip.width || y >= mip.height || mip.size <= 0)
        return { 0, 0, 0, 0 };
    const auto* data = mip.data.get();
    const isize texel = static_cast<isize>(y) * mip.width + x;
    switch (format) {
    case TextureFormat::RGBA8: {
        const isize offset = texel * 4;
        if (offset + 4 > mip.size) return { 0, 0, 0, 0 };
        return { data[offset], data[offset + 1], data[offset + 2], data[offset + 3] };
    }
    case TextureFormat::R8: {
        if (texel >= mip.size) return { 0, 0, 0, 0 };
        return { data[texel], 0, 0, 255 };
    }
    case TextureFormat::RG8: {
        if (texel * 2 + 2 > mip.size) return { 0, 0, 0, 0 };
        return { data[texel * 2], data[texel * 2 + 1], 0, 255 };
    }
    case TextureFormat::BC1:
    case TextureFormat::BC2:
    case TextureFormat::BC3: {
        const isize block_bytes    = format == TextureFormat::BC1 ? 8 : 16;
        const isize blocks_per_row = (mip.width + 3) / 4;
        const isize offset         = ((static_cast<isize>(y) / 4) * blocks_per_row + x / 4) * block_bytes;
        if (offset + block_bytes > mip.size) return { 0, 0, 0, 0 };
        const uint8_t* block  = data + offset;
        auto           colour = texel_detail::Bc1Colour(block + (block_bytes - 8), x, y,
                                                        format != TextureFormat::BC1);
        const int slot = (y % 4) * 4 + (x % 4);
        if (format == TextureFormat::BC2) {
            const uint8_t pair = block[slot / 2];
            colour[3] = static_cast<uint8_t>(((slot % 2) == 0 ? (pair & 0x0F) : (pair >> 4)) * 17);
        } else if (format == TextureFormat::BC3) {
            const uint8_t a0 = block[0];
            const uint8_t a1 = block[1];
            uint64_t      bits = 0;
            for (int i = 0; i < 6; ++i) bits |= static_cast<uint64_t>(block[2 + i]) << (8 * i);
            const unsigned index = static_cast<unsigned>((bits >> (3 * slot)) & 0x7);
            if (index == 0) colour[3] = a0;
            else if (index == 1) colour[3] = a1;
            else if (a0 > a1) colour[3] = static_cast<uint8_t>(((8 - index) * a0 + (index - 1) * a1) / 7);
            else if (index == 6) colour[3] = 0;
            else if (index == 7) colour[3] = 255;
            else colour[3] = static_cast<uint8_t>(((6 - index) * a0 + (index - 1) * a1) / 5);
        }
        return colour;
    }
    default: return { 255, 255, 255, 255 };
    }
}

} // namespace wallpaper
