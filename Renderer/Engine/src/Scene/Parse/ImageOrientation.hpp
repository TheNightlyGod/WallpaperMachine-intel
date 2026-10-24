#pragma once
#include <cstdint>
#include <cstring>
#include <span>
#include <vector>
#include <utility>

namespace wallpaper {
// stb_image returns stored pixels, not the display orientation in JPEG EXIF.
inline int JpegOrientation(std::span<const uint8_t> bytes) {
    if (bytes.size() < 2 || bytes[0] != 0xff || bytes[1] != 0xd8) return 1;
    for (size_t p = 2; p + 4 <= bytes.size();) {
        if (bytes[p++] != 0xff) return 1;
        while (p < bytes.size() && bytes[p] == 0xff) ++p;
        if (p >= bytes.size()) return 1;
        const auto marker = bytes[p++];
        if (marker == 0xda || marker == 0xd9) return 1;
        if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (p + 2 > bytes.size()) return 1;
        const size_t length = (bytes[p] << 8) | bytes[p + 1];
        if (length < 2 || length > bytes.size() - p) return 1;
        if (marker == 0xe1 && length >= 16 &&
            std::memcmp(bytes.data() + p + 2, "Exif\0\0", 6) == 0) {
            auto t = bytes.subspan(p + 8, length - 8);
            const bool le = t[0] == 'I' && t[1] == 'I';
            if (!le && !(t[0] == 'M' && t[1] == 'M')) return 1;
            auto u16 = [&](size_t o) -> uint32_t {
                return le ? t[o] | (t[o+1] << 8) : (t[o] << 8) | t[o+1];
            };
            auto u32 = [&](size_t o) -> uint32_t {
                return le ? u16(o) | (u16(o+2) << 16) : (u16(o) << 16) | u16(o+2);
            };
            if (u16(2) != 42) return 1;
            size_t ifd = u32(4);
            if (ifd > t.size() || t.size() - ifd < 2) return 1;
            const size_t count = u16(ifd);
            ifd += 2;
            if (count > (t.size() - ifd) / 12) return 1;
            for (size_t i = 0; i < count; ++i) {
                const size_t e = ifd + i * 12;
                if (u16(e) == 0x112 && u16(e+2) == 3 && u32(e+4) == 1) {
                    const int orientation = u16(e+8);
                    return orientation >= 1 && orientation <= 8 ? orientation : 1;
                }
            }
        }
        p += length;
    }
    return 1;
}

inline void OrientRGBA(uint8_t* pixels, int& width, int& height, int orientation) {
    if (orientation < 2 || orientation > 8) return;
    const int w = width, h = height;
    const int ow = orientation >= 5 ? h : w;
    const int oh = orientation >= 5 ? w : h;
    std::vector<uint8_t> output(size_t(w) * h * 4);
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int dx = x, dy = y;
        switch (orientation) {
        case 2: dx = w-1-x; break;
        case 3: dx = w-1-x; dy = h-1-y; break;
        case 4: dy = h-1-y; break;
        case 5: dx = y; dy = x; break;
        case 6: dx = h-1-y; dy = x; break;
        case 7: dx = h-1-y; dy = w-1-x; break;
        case 8: dx = y; dy = w-1-x; break;
        }
        std::memcpy(output.data() + (size_t(dy)*ow+dx)*4,
                    pixels + (size_t(y)*w+x)*4, 4);
    }
    std::memcpy(pixels, output.data(), output.size());
    width = ow; height = oh;
}
} // namespace wallpaper
