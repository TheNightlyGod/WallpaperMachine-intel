#pragma once
#include <array>
#include <string_view>

#include "WPPuppet.hpp"

namespace wallpaper
{

// Column-major 4x4 matrices of the bone simulation.
using PhysicsMatrix = std::array<double, 16>;

// One simulation step of one bone, as Wallpaper Engine's puppet composer 0x1401FDF90 runs it
// (0x140201377..0x140202a28, B-D2): `current` is the bone's world matrix composed from the
// animation this frame, `previous` its final world matrix of the last step, `layer_scale` the
// mean column length of the layer's world matrix and `dt` the frame step in seconds. Advances
// `state` and returns the local matrix the bone's model matrix is multiplied by.
PhysicsMatrix StepBonePhysics(const WPPuppet::BoneSimulation& sim, BonePhysicsState& state,
                              const PhysicsMatrix& current, const PhysicsMatrix& previous,
                              double layer_scale, double dt) noexcept;

// applyBonePhysicsImpulse 0x140210990 on one bone's state.
void ApplyBonePhysicsImpulse(BonePhysicsState& state, const std::array<double, 3>& linear,
                             const std::array<double, 3>& angular_degrees) noexcept;

// we_ParseBoneSimulationJson 0x140265C30: the settings the JSON text names; false (and the
// defaults, no flags) for text that is not a JSON object or names no simulation and no IK.
bool ParseBoneSimulation(std::string_view json, WPPuppet::BoneSimulation& out);

} // namespace wallpaper
