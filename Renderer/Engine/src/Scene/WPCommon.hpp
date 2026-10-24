// Clean-room implementation from the WallpaperMachine spec p6-textures-packages.md; written without access to the original source.
#pragma once
#include <array>
#include <cstring>
#include <string_view>
#include <charconv>
#include "Fs/IBinaryStream.h"
#include "Utils/Logging.h"
#include "Core/StringHelper.hpp"

namespace wallpaper
{

// A nine-byte stamp is a family tag (`TEX`, `MDL`, ...), one free letter, four
// decimal digits and a NUL. Returns the number, or 0 when the family differs or the
// digits are missing; the free letter is not checked.
inline int32_t ReadVersion(std::string_view prefix, fs::IBinaryStream& file) {
    std::array<char, 9> stamp {};
    // A short read leaves the rest zero, which matches no family.
    file.Read(stamp.data(), stamp.size());
    if (prefix.size() > stamp.size() || std::memcmp(stamp.data(), prefix.data(), prefix.size()) != 0)
        return 0;
    // The digits start at the fifth character; text after them is ignored.
    const char* const first = stamp.data() + 4;
    const char* const last  = stamp.data() + stamp.size();
    const char*       end   = first;
    while (end != last && *end >= '0' && *end <= '9') ++end;
    int32_t number = 0;
    if (end == first || std::from_chars(first, end, number).ec != std::errc {}) {
        LOG_ERROR("bad version stamp \"%.*s\"", static_cast<int>(prefix.size()), prefix.data());
        return 0;
    }
    return number;
}

// Writes the first four letters of `prefix` and the version as four zero-padded
// digits, then a NUL: nine bytes.
inline void WriteVersion(std::string_view prefix, fs::IBinaryStreamW& file, int ver) {
    std::array<char, 9> stamp {};
    for (std::size_t i = 0; i < 4 && i < prefix.size(); ++i) stamp[i] = prefix[i];
    unsigned left = static_cast<unsigned>(ver < 0 ? 0 : ver) % 10000u;
    for (int i = 7; i >= 4; --i) {
        stamp[static_cast<std::size_t>(i)] = static_cast<char>('0' + left % 10u);
        left /= 10u;
    }
    file.Write(stamp.data(), stamp.size());
}

inline int32_t ReadTexVesion(fs::IBinaryStream& file) { return ReadVersion("TEX", file); }
inline int32_t ReadMDLVesion(fs::IBinaryStream& file) { return ReadVersion("MDL", file); }

inline int32_t ReadSPVVesion(fs::IBinaryStream& file) { return ReadVersion("SPV", file); }
inline void    WriteSPVVesion(fs::IBinaryStreamW& file, int ver) {
    WriteVersion("SPVS", file, ver);
}

} // namespace wallpaper
