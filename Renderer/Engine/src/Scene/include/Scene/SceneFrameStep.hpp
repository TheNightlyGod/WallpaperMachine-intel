#pragma once

#include <cmath>

namespace wallpaper
{

/// The time one frame advances a scene: the frame's elapsed seconds times the playback rate,
/// clamped as Wallpaper Engine 2.8.0.42 clamps it (`sub_140110630`, before it calls the scene
/// update `sub_14017FA70`). The elapsed time is first held to [1e-4, 0.25] s, then the rate is
/// applied and the product held to [1e-4, 0.25] s again; the result is the scene's frame time
/// (`g_Frametime`) and what its clock (`g_Time`) gains. A hitch therefore never moves a scene
/// more than a quarter second, and a frame never moves it by nothing. Computed in single
/// precision, as there.
inline double SceneFrameStep(double elapsed_seconds, double rate) {
    constexpr float kMin = 0.0001f;
    constexpr float kMax = 0.25f;
    const auto      hold = [](float seconds) {
        const float capped = std::fmin(seconds, kMax);
        return capped < kMin ? kMin : capped;
    };
    return hold(static_cast<float>(rate) * hold(static_cast<float>(elapsed_seconds)));
}

} // namespace wallpaper
