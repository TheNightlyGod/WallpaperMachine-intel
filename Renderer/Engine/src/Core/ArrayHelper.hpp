// Clean-room implementation from the WallpaperMachine spec e6-platform-host-api.md; written without access to the original source.
#pragma once
#include <array>
#include <vector>
#include <span>
#include <algorithm>

namespace wallpaper
{

template<typename T, typename Tarray>
std::array<T, std::tuple_size<Tarray>::value> array_cast(const Tarray& array) noexcept {
    std::array<T, std::tuple_size<Tarray>::value> out {};
    for (std::size_t i = 0; i < out.size(); ++i) out[i] = static_cast<T>(array[i]);
    return out;
}

template<typename T>
class spanone {
public:
    using value_type = T;
    using size_type  = size_t;
    using reference  = T&;
    using pointer    = T*;

    constexpr spanone(reference value) noexcept: m_ptr(&value) {}
    constexpr pointer data() const noexcept {
        return m_ptr;
    }
    constexpr size_type size() const noexcept {
        return 1;
    }
    constexpr pointer begin() const noexcept {
        return m_ptr;
    }
    constexpr pointer end() const noexcept {
        return m_ptr + 1;
    }

private:
    pointer m_ptr;
};

} // namespace wallpaper
