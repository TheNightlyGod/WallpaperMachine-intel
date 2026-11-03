#pragma once

// The scene quality a headless harness is asked to draw with, read from the
// environment the same way by every harness, so one setting means one thing
// in the energy test, the poster harness and the local-project run.

#include "Scene/SceneQuality.hpp"

#include <cstdlib>
#include <stdexcept>
#include <string>
#include <string_view>

namespace wallpaper::tests
{

/// `WE_TEST_REFLECTION` (0 or 1), `WE_TEST_MSAA` (0, 2, 4 or 8),
/// `WE_TEST_POSTPROCESSING` (0, 2, 4 or 5), `WE_TEST_SHADOWS` and
/// `WE_TEST_VOLUMETRICS` (0..4). Unset keeps the default, Wallpaper Engine's
/// medium preset; anything else throws. The parser and the device still decide
/// which pipeline and sample count can be drawn.
inline SceneQuality SceneQualityFromEnvironment()
{
    const auto integer = [](const char* name, const char* text, auto accepted) {
        char*      end   = nullptr;
        const long value = std::strtol(text, &end, 10);
        if (end == text || *end != '\0' || ! accepted(value)) {
            throw std::runtime_error(std::string(name) + " is out of range: " + text);
        }
        return static_cast<int>(value);
    };
    SceneQuality quality;
    if (const char* text = std::getenv("WE_TEST_REFLECTION")) {
        const std::string_view value(text);
        if (value != "0" && value != "1")
            throw std::runtime_error("WE_TEST_REFLECTION must be 0 or 1");
        quality.reflection = value == "1";
    }
    if (const char* text = std::getenv("WE_TEST_MSAA")) {
        quality.msaa = integer("WE_TEST_MSAA (0, 2, 4 or 8)", text, [](long samples) {
            return samples == 0 || samples == 2 || samples == 4 || samples == 8;
        });
    }
    if (const char* text = std::getenv("WE_TEST_POSTPROCESSING")) {
        quality.post_processing =
            integer("WE_TEST_POSTPROCESSING (0, 2, 4 or 5)", text, [](long level) {
                return level == 0 || level == 2 || level == 4 || level == 5;
            });
    }
    const auto level = [](long value) { return value >= 0 && value <= 4; };
    if (const char* text = std::getenv("WE_TEST_SHADOWS")) {
        quality.shadows = integer("WE_TEST_SHADOWS (0..4)", text, level);
    }
    if (const char* text = std::getenv("WE_TEST_VOLUMETRICS")) {
        quality.volumetrics = integer("WE_TEST_VOLUMETRICS (0..4)", text, level);
    }
    return quality;
}

} // namespace wallpaper::tests
