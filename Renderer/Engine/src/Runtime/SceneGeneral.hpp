#pragma once

#include "Scene/Parse/wpscene/WPScene.h"
#include "Scene/SceneShader.h"

#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>

namespace wallpaper {
class DynamicValue;
struct SceneMaterial;

// Requested values are separate from quality-gated renderer state. Drivers are
// owned by SceneRuntimeContext; these aliases do not evaluate them a second time.
struct SceneGeneralState {
    wpscene::WPSceneGeneral values;
    std::map<std::string, DynamicValue*, std::less<>> drivers;
    std::map<std::string, ShaderValue, std::less<>> uniform_overrides;
    std::set<std::weak_ptr<SceneMaterial>, std::owner_less<>> uniform_materials;
    bool uniform_materials_collected { false };
    uint32_t pending { 0 };
    std::function<bool(uint32_t)> factory;
    std::function<void(std::string_view, const ShaderValue&)> bloom_uniform_writer;
};
} // namespace wallpaper
