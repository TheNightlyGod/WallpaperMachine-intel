#pragma once

#include "Runtime/CameraPath.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/ScalarAnimation.hpp"

#include <nlohmann/json_fwd.hpp>

#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{

class SceneRuntimeContext;
class SceneNode;

// `own_animation`, for the resolvers below that take one, is the clock of a keyed setting that a
// script also drives: the script's `thisObject.getAnimation()` with no name answers it.

// Binds a layer's origin, scale and angles as each setting asks: a script or a
// user property writes it, else its authored absolute/relative timeline plays
// it, else it stays the scene file's value and allocates no per-tick binding.
// Settings the editor keyed together (`options.parent`) are one animation and
// share the clock of the first, so holding or playing it moves them all.
// `animate` false leaves timelines to the object that owns them.
void RegisterNodeTransformSettings(SceneRuntimeContext& context, SceneNode* node,
                                   std::string_view layer_name, const nlohmann::json& origin,
                                   const nlohmann::json& scale, const nlohmann::json& angles,
                                   bool animate = true);

// A vec3 setting's own timeline on a clock of its own, for a setting that is
// not part of a transform (an image layer's colour); null when it has none.
std::shared_ptr<const NodeVec3Animation>
ResolveVec3Animation(SceneRuntimeContext& context, std::string_view layer_name,
                     const nlohmann::json& setting);

enum class Vec3SettingSemantic
{
    Generic,
    AnglesDegrees,
};

// `animation_layer_index` is the animation layer of the layer a setting belongs
// to when it is one of that animation layer's own (`animationlayers[i]`): its
// script's `thisObject` is that animation layer. -1 for a setting of the layer.
// `effect_reference` is the reference of the effect (`SceneRuntimeContext::RegisterEffectObject`)
// whose visibility this setting is, which is its script's `thisObject`.
std::unique_ptr<DynamicValue> ResolveBoolSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {},
    int animation_layer_index = -1,
    std::string effect_reference = {});
// A number, or a vec3 (`semantic` says whether three numbers are angles in degrees), bound the
// same way as the bool above. `animation_layer_index` is -1 for a setting of the layer itself.
std::unique_ptr<DynamicValue>
ResolveFloatSetting(SceneRuntimeContext& context, const nlohmann::json& value,
                    std::string_view current_layer_name = {}, int animation_layer_index = -1);
std::unique_ptr<DynamicValue>
ResolveVec3Setting(SceneRuntimeContext& context, const nlohmann::json& value,
                   std::string_view current_layer_name = {},
                   Vec3SettingSemantic semantic = Vec3SettingSemantic::Generic,
                   std::shared_ptr<ScalarAnimationPlayback> own_animation = {});
// Resolves a setting at the component count the shader declares. Handing a two-
// or four-component constant to a property script as a string loses the vector:
// the script reads `.x` off that string and hands back NaN.
std::unique_ptr<DynamicValue> ResolveVectorSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::size_t components,
    std::string_view current_layer_name = {},
    std::shared_ptr<ScalarAnimationPlayback> own_animation = {});
std::unique_ptr<DynamicValue> ResolveStringSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {});
std::vector<CameraPath> ParseCameraPaths(const nlohmann::json& json);

// What a bool setting reads before anything runs: its authored value, which a script's first
// run replaces (the value `ResolveBoolSetting` starts from).
bool InitialBoolSetting(const nlohmann::json& setting);

// The wallpaper property a setting is bound to, in either authored form
// (`{"user": "name"}` or `{"user": {"name": ..., "condition": ...}}`), or empty
// when it is bound to none. The same reading the resolvers above bind with.
std::string UserPropertyName(const nlohmann::json& setting);

// `component` selects the `c0`-`c3` curve and the matching entry of a vector
// initial value; scalar settings keep their single curve at component 0.
std::optional<ScalarAnimation> ResolveScalarAnimation(const nlohmann::json& value,
                                                      std::size_t component = 0);

} // namespace wallpaper
