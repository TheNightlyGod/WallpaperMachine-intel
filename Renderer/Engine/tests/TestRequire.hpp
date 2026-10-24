#pragma once

#include <stdexcept>
#include <string>

namespace wallpaper::test
{
// Helpers returning values cannot use gtest's fatal assertions (which return
// void). Throwing stops both helper and test; gtest reports the exception as a
// failure in every build configuration.
inline void Require(bool condition, const char* expression, const char* file, int line) {
    if (! condition) {
        throw std::runtime_error(std::string(file) + ":" + std::to_string(line) +
                                 ": required " + expression);
    }
}
} // namespace wallpaper::test

#define REQUIRE(...) \
    ::wallpaper::test::Require(static_cast<bool>((__VA_ARGS__)), #__VA_ARGS__, __FILE__, __LINE__)
