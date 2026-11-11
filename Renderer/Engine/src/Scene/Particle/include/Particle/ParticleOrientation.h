#pragma once

#include <cstdint>

namespace wallpaper {

/// Camera is the existing non-particle uniform path. The other values encode
/// the particle renderer's screen/upright/fixed modes in one metadata byte.
enum class ParticleOrientation : uint8_t { Camera, Screen, Upright, Fixed };
inline constexpr uint8_t kParticleOrientationWorldspace = 4;

} // namespace wallpaper
