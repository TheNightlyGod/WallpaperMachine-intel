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

// Binds scripts/properties as before, or an authored absolute/relative origin
// timeline. Static settings allocate no per-tick binding.
void RegisterNodeOriginSetting(SceneRuntimeContext& context, SceneNode* node,
                               std::string_view layer_name, const nlohmann::json& setting,
                               bool animate = true);

enum class Vec3SettingSemantic
{
    Generic,
    AnglesDegrees,
};

std::unique_ptr<DynamicValue> ResolveBoolSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {});
std::unique_ptr<DynamicValue> ResolveFloatSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {});
std::unique_ptr<DynamicValue> ResolveVec3Setting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {},
    Vec3SettingSemantic semantic = Vec3SettingSemantic::Generic);
// Resolves a setting at the component count the shader declares. Handing a two-
// or four-component constant to a property script as a string loses the vector:
// the script reads `.x` off that string and hands back NaN.
std::unique_ptr<DynamicValue> ResolveVectorSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::size_t components,
    std::string_view current_layer_name = {});
std::unique_ptr<DynamicValue> ResolveStringSetting(
    SceneRuntimeContext& context,
    const nlohmann::json& value,
    std::string_view current_layer_name = {});
std::vector<CameraPath> ParseCameraPaths(const nlohmann::json& json);

// The wallpaper property a setting is bound to, in either authored form
// (`{"user": "name"}` or `{"user": {"name": ..., "condition": ...}}`), or empty
// when it is bound to none. The same reading the resolvers above bind with.
std::string UserPropertyName(const nlohmann::json& setting);

// `component` selects the `c0`-`c3` curve and the matching entry of a vector
// initial value; scalar settings keep their single curve at component 0.
std::optional<ScalarAnimation> ResolveScalarAnimation(const nlohmann::json& value,
                                                      std::size_t component = 0);

} // namespace wallpaper
