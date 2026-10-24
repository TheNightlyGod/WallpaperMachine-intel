#pragma once
#include <chrono>
#include <cmath>
#include <ctime>
#include <optional>

namespace wallpaper
{

// The local wall-clock time as a fraction of the day: 00:00 is 0, noon is 0.5,
// and the value wraps back to 0 at midnight. Shaders read it as `g_Daytime`
// and SceneScript as `engine.timeOfDay`, so an effect and a script that follow
// the hour agree. Empty when the platform cannot convert to local time.
inline std::optional<double> LocalTimeOfDay(std::chrono::system_clock::time_point now) {
    const auto seconds = std::chrono::system_clock::to_time_t(now);
    std::tm    local {};
#if defined(_WIN32)
    if (localtime_s(&local, &seconds) != 0) return std::nullopt;
#else
    if (localtime_r(&seconds, &local) == nullptr) return std::nullopt;
#endif
    const double fraction =
        std::chrono::duration<double>(now - std::chrono::system_clock::from_time_t(seconds)).count();
    return std::fmod(local.tm_hour * 3600.0 + local.tm_min * 60.0 + local.tm_sec + fraction,
                     86400.0) /
           86400.0;
}

} // namespace wallpaper
