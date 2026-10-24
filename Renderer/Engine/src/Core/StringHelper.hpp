// Clean-room implementation from the WallpaperMachine spec e6-platform-host-api.md; written without access to the original source.
#pragma once
#include <string_view>

namespace wallpaper
{

constexpr bool sstart_with(std::string_view str, std::string_view start) {
    return str.size() >= start.size() && str.compare(0, start.size(), start) == 0;
}
constexpr bool send_with(std::string_view str, std::string_view end) {
    return str.size() >= end.size() && str.compare(str.size() - end.size(), end.size(), end) == 0;
}

} // namespace wallpaper
