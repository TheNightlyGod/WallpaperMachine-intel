#include "Media/VideoTypes.hpp"

namespace wallpaper::media
{

std::string FourCCString(std::uint32_t code)
{
    std::string text(4, '?');
    for (int index = 0; index < 4; ++index) {
        const auto byte = static_cast<unsigned char>((code >> (24 - 8 * index)) & 0xFFU);
        if (byte >= 0x20 && byte < 0x7F) text[static_cast<std::size_t>(index)] = static_cast<char>(byte);
    }
    return text;
}

} // namespace wallpaper::media
