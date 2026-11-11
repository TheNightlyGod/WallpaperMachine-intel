#include "Runtime/SceneGeneral.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneForces.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/SceneCamera.h"
#include "Scene/SceneImageEffectLayer.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "WPShaderValueUpdater.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <variant>

namespace wallpaper {
namespace {
using General = wpscene::WPSceneGeneral;
using Member = std::variant<bool General::*, float General::*, int32_t General::*, std::array<float, 3> General::*>;
struct Field { std::string_view name; Member member; };
const Field fields[] {
    { "bloom", &General::bloom }, { "bloomstrength", &General::bloomstrength },
    { "bloomthreshold", &General::bloomthreshold }, { "clearenabled", &General::clearenabled },
    { "clearcolor", &General::clearcolor }, { "ambientcolor", &General::ambientcolor },
    { "skylightcolor", &General::skylightcolor }, { "fov", &General::fov },
    { "nearz", &General::nearz }, { "farz", &General::farz }, { "camerafade", &General::camerafade },
    { "camerashake", &General::camerashake }, { "camerashakespeed", &General::camerashakespeed },
    { "camerashakeamplitude", &General::camerashakeamplitude },
    { "camerashakeroughness", &General::camerashakeroughness },
    { "cameraparallax", &General::cameraparallax }, { "cameraparallaxamount", &General::cameraparallaxamount },
    { "cameraparallaxdelay", &General::cameraparallaxdelay },
    { "cameraparallaxmouseinfluence", &General::cameraparallaxmouseinfluence },
    { "hdr", &General::hdr }, { "fogdistance", &General::fogdistance }, { "fogheight", &General::fogheight },
    { "perspectiveoverridefov", &General::perspectiveoverridefov }, { "zoom", &General::zoom },
    { "transparentsorting", &General::transparentsorting }, { "customsortorder", &General::customsortorder },
    { "bloomtint", &General::bloomtint }, { "bloomhdrstrength", &General::bloomhdrstrength },
    { "bloomhdrthreshold", &General::bloomhdrthreshold }, { "bloomhdrscatter", &General::bloomhdrscatter },
    { "bloomhdrfeather", &General::bloomhdrfeather }, { "bloomhdriterations", &General::bloomhdriterations },
    { "fogdistancecolor", &General::fogdistancecolor }, { "fogheightcolor", &General::fogheightcolor },
    { "fogdistancestart", &General::fogdistancestart }, { "fogdistanceend", &General::fogdistanceend },
    { "fogdistancestartdensity", &General::fogdistancestartdensity },
    { "fogdistanceenddensity", &General::fogdistanceenddensity },
    { "fogheightstart", &General::fogheightstart }, { "fogheightend", &General::fogheightend },
    { "fogheightstartdensity", &General::fogheightstartdensity },
    { "fogheightenddensity", &General::fogheightenddensity },
    { "windenabled", &General::windenabled }, { "winddirection", &General::winddirection },
    { "windstrength", &General::windstrength }, { "gravitydirection", &General::gravitydirection },
    { "gravitystrength", &General::gravitystrength }
};

const Field* Find(std::string_view name) {
    for (const auto& field : fields) if (field.name == name) return &field;
    return nullptr;
}

ShaderValue Read(const General& general, const Field& field) {
    return std::visit([&](auto member) {
        using T = std::remove_cvref_t<decltype(general.*member)>;
        if constexpr (std::is_same_v<T, std::array<float, 3>>) return ShaderValue(general.*member);
        else return ShaderValue(float(general.*member));
    }, field.member);
}

bool Store(General& general, const Field& field, std::span<const float> value) {
    if (!std::all_of(value.begin(), value.end(), [](float v) { return std::isfinite(v); })) return false;
    return std::visit([&](auto member) {
        using T = std::remove_cvref_t<decltype(general.*member)>;
        if constexpr (std::is_same_v<T, std::array<float, 3>>) {
            if (value.size() != 3) return false;
            std::copy(value.begin(), value.end(), (general.*member).begin());
        } else {
            if (value.size() != 1) return false;
            if constexpr (std::is_same_v<T, int32_t>)
                general.*member = static_cast<int32_t>(std::clamp(double(value[0]),
                    double(std::numeric_limits<int32_t>::min()), double(std::numeric_limits<int32_t>::max())));
            else general.*member = T(value[0]);
        }
        return true;
    }, field.member);
}

bool Same(const ShaderValue& current, std::span<const float> next) {
    return current.size() == next.size() && std::equal(next.begin(), next.end(), current.data());
}

void WriteUniform(SceneMaterial& material, const std::string& name, const ShaderValue& value) {
    auto& constants = material.customShader.constValues;
    const auto found = constants.find(name);
    if (found != constants.end()) found->second = value;
}
} // namespace

void SceneRuntimeContext::RegisterSceneGeneral(const wpscene::WPSceneGeneral& general) {
    if (!m_scene_general) m_scene_general = std::make_unique<SceneGeneralState>();
    // Copy values, not the original JSON/script payloads already owned by drivers and factories.
    for (const auto& field : fields) {
        const auto value = Read(general, field);
        Store(m_scene_general->values, field, std::span(value.data(), value.size()));
    }
    if (!(m_scene_general->values.perspectiveoverridefov > 0))
        m_scene_general->values.perspectiveoverridefov = 95;
    m_initial_static_camera[9] = std::isfinite(general.zoom) && general.zoom > 0 ? general.zoom : 1;
    SetCameraFadeEnabled(general.camerafade);
}

void SceneRuntimeContext::SeedSceneGeneralValue(std::string_view name, std::span<const float> value) {
    if (m_scene_general) if (const auto* field = Find(name)) Store(m_scene_general->values, *field, value);
    if (name.starts_with("wind") || name.starts_with("gravity")) RefreshSceneForces();
}

void SceneRuntimeContext::RefreshSceneForces() {
    if (!m_scene_forces || !m_scene_general) return;
    // Drivers commit valid values through SeedSceneGeneralValue. Reading a driver
    // again here would bypass Store's finite-value check and poison Verlet history.
    const auto& value=m_scene_general->values;
    m_scene_forces->wind_enabled = value.windenabled;
    m_scene_forces->wind_direction = value.winddirection;
    m_scene_forces->wind_strength = value.windstrength;
    m_scene_forces->gravity_direction = value.gravitydirection;
    m_scene_forces->gravity_strength = value.gravitystrength;
}

void SceneRuntimeContext::BindPuppetSceneForces(WPPuppetLayer& layer) {
    if (!layer.usesSceneForces()) return;
    if (!m_scene_forces) {
        m_scene_forces=std::make_shared<SceneForceState>();
        RefreshSceneForces();
    }
    layer.setSceneForces(m_scene_forces);
}

void SceneRuntimeContext::RegisterSceneForceSettings(const wpscene::WPSceneGeneral& general) {
    if (!general.force_settings.is_object()) return;
    for (const auto& [name,setting] : general.force_settings.items()) {
        std::unique_ptr<DynamicValue> value;
        if (name == "windenabled") value=ResolveBoolSetting(*this,setting);
        else if (name.ends_with("direction")) value=ResolveVec3Setting(*this,setting);
        else value=ResolveFloatSetting(*this,setting);
        if (!value) continue;
        AliasSceneGeneralDriver(name,value.get());
        RegisterDynamicValueListener(std::move(value),[this,name](const DynamicValue&) {
            if (const auto current=SceneGeneralValue(name))
                SeedSceneGeneralValue(name,std::span(current->data(),current->size()));
        });
    }
}

void SceneRuntimeContext::AliasSceneGeneralDriver(std::string_view name, DynamicValue* value) {
    if (m_scene_general && value && Find(name)) m_scene_general->drivers[std::string(name)] = value;
}

std::optional<ShaderValue> SceneRuntimeContext::SceneGeneralValue(std::string_view name) const {
    if (!m_scene_general) return std::nullopt;
    const auto* field = Find(name);
    if (!field) return std::nullopt;
    if (name == "zoom") return ShaderValue(float(m_static_camera_started ? m_static_camera[9] : m_initial_static_camera[9]));
    if (name == "camerafade") return ShaderValue(CameraFadeEnabled() ? 1.0f : 0.0f);
    const auto driver = m_scene_general->drivers.find(name);
    if (driver == m_scene_general->drivers.end()) return Read(m_scene_general->values, *field);
    if (std::holds_alternative<std::array<float, 3> General::*>(field->member)) {
        const auto value = driver->second->getVec3();
        return ShaderValue(value.data(), 3);
    }
    return ShaderValue(std::holds_alternative<bool General::*>(field->member)
        ? float(driver->second->getBool()) : driver->second->getFloat());
}

void SceneRuntimeContext::CopySceneGeneralSettings(wpscene::WPSceneGeneral& general) const {
    for (const auto& field : fields) if (const auto value = SceneGeneralValue(field.name))
        Store(general, field, std::span(value->data(), value->size()));
}

void SceneRuntimeContext::SetSceneGeneralFactory(std::function<bool(uint32_t)> factory) {
    if (m_scene_general) m_scene_general->factory = std::move(factory);
}

bool SceneRuntimeContext::RefreshSceneGeneralPostProcesses() {
    return m_scene_general && m_scene_general->factory && m_scene_general->factory(0);
}

void SceneRuntimeContext::CommitSceneGeneralChanges() {
    if (!m_scene_general || !m_scene_general->pending || !m_scene_general->factory) return;
    const auto pending = std::exchange(m_scene_general->pending, 0);
    if (m_scene_general->factory(pending)) MarkSceneGraphMutated("scene-general");
}

bool SceneRuntimeContext::HasSceneUniforms() const noexcept {
    return !m_scene_uniforms.empty() || (m_scene_general && !m_scene_general->uniform_overrides.empty());
}

void SceneRuntimeContext::SetSceneGeneralBloomWriter(
    std::function<void(std::string_view, const ShaderValue&)> writer) {
    if (m_scene_general) m_scene_general->bloom_uniform_writer = std::move(writer);
}

void SceneRuntimeContext::ForgetSceneUniformMaterial(const std::shared_ptr<SceneMaterial>& material) {
    for (auto& binding : m_scene_uniforms) binding.materials.erase(material);
    if (m_scene_general) m_scene_general->uniform_materials.erase(material);
}

void SceneRuntimeContext::AddSceneGeneralUniformMaterial(const std::shared_ptr<SceneMaterial>& material) {
    if (!material || !m_scene_general || m_scene_general->uniform_overrides.empty()) return;
    auto& recipients = m_scene_general->uniform_materials;
    std::erase_if(recipients, [](const auto& weak) { return weak.expired(); });
    if (!recipients.insert(material).second) return;
    for (const auto& [name, value] : m_scene_general->uniform_overrides) WriteUniform(*material, name, value);
}

void SceneRuntimeContext::WriteSceneGeneralUniform(const std::string& name, const ShaderValue& value) {
    // Reuse an existing live input's recipients. A static direct write has an event-only
    // recipient set instead of adding another binding to the per-frame generation poll.
    for (auto& binding : m_scene_uniforms) if (binding.uniform == name) {
        binding.value = value;
        for (const auto& weak : binding.materials) if (const auto material = weak.lock())
            WriteUniform(*material, name, value);
        return;
    }
    auto& state = *m_scene_general;
    state.uniform_overrides[name] = value;
    if (!state.uniform_materials_collected && m_scene) {
        state.uniform_materials_collected = true;
        const auto add = [&](SceneNode* node) {
            if (node && node->Mesh()) for (const auto& material : node->Mesh()->MaterialSlots())
                AddSceneGeneralUniformMaterial(material);
        };
        std::vector<SceneNode*> nodes;
        if (m_scene->sceneGraph) nodes.push_back(m_scene->sceneGraph.get());
        for (std::size_t i = 0; i < nodes.size(); ++i) {
            add(nodes[i]);
            for (const auto& child : nodes[i]->GetChildren()) nodes.push_back(child.get());
        }
        for (const auto& [key, camera] : m_scene->cameras) if (camera && camera->HasImgEffect()) {
            auto chain = camera->GetImgEffect();
            add(chain->ResolvedFinalRenderNode());
            for (std::size_t i = 0; i < chain->EffectCount(); ++i)
                for (const auto& pass : chain->GetEffect(i)->nodes) add(pass.sceneNode.get());
        }
        for (const auto& post : m_scene->post_processes) if (post)
            for (const auto& step : post->steps) if (const auto* pass = std::get_if<ScenePostProcessPass>(&step))
                add(pass->node.get());
    }
    std::erase_if(state.uniform_materials, [&](const auto& weak) {
        const auto material = weak.lock();
        if (!material) return true;
        WriteUniform(*material, name, value);
        return false;
    });
}

bool SceneRuntimeContext::SetSceneGeneralValue(std::string_view name, std::span<const float> value) {
    if (!m_scene || !m_scene_general) return false;
    const auto* field = Find(name);
    const auto current = SceneGeneralValue(name);
    if (!field || !current) return false;
    auto proposed = Read(m_scene_general->values, *field);
    if (value.size() != proposed.size() ||
        !std::all_of(value.begin(), value.end(), [](float v) { return std::isfinite(v); })) return false;
    float canonical = 0;
    if (std::holds_alternative<int32_t General::*>(field->member)) {
        canonical = static_cast<float>(static_cast<int32_t>(std::clamp(double(value[0]),
            double(std::numeric_limits<int32_t>::min()), double(std::numeric_limits<int32_t>::max()))));
        value = std::span(&canonical, 1);
    }
    if (name == "zoom") {
        if (!(value[0] > 0)) return false;
        auto camera = GetStaticCameraTransforms(); camera[9] = value[0];
        if (const auto input = m_scene_general->drivers.find(name); input != m_scene_general->drivers.end())
            input->second->update(value[0]);
        Store(m_scene_general->values, *field, value);
        return SetStaticCameraTransforms(camera, 8);
    }
    if (Same(*current, value)) return true;
    // WE keeps the loaded HDR/fog shader variants and layer-buffer formats when
    // these raw members change. Only a live post-process switch needs a factory.
    const bool mode = name == "bloom" || name == "bloomhdriterations" ||
        (name == "camerafade" && value[0] != 0 && HasCameraPaths() && !HasCameraFadeNode());
    // Init may write before the parser has installed its event factory. Keep the
    // request pending; the first tick commits it after every layer and hook exists.
    const bool before_custom = CustomSortOrder(), before_transparent = m_scene->transparent_sorting;
    Store(m_scene_general->values, *field, value);
    if (const auto input = m_scene_general->drivers.find(name); input != m_scene_general->drivers.end()) {
        if (value.size() == 3) input->second->update(linalg::Vector3f(value.data()));
        else if (std::holds_alternative<bool General::*>(field->member)) input->second->update(value[0] != 0);
        else input->second->update(value[0]);
    }
    const auto& g = m_scene_general->values;
    if (name == "clearcolor") m_scene->clearColor = { value[0], value[1], value[2] };
    else if (name == "clearenabled") {
        m_scene->clearEnabled = value[0] != 0;
        MarkSceneGraphMutated("scene-clear-mode");
    } else if (name == "ambientcolor" || name == "skylightcolor") {
        WriteSceneGeneralUniform(name == "ambientcolor" ? "g_LightAmbientColor" : "g_LightSkylightColor",
                                 ShaderValue(value.data(), 3));
    } else if (name.starts_with("bloom") && name != "bloom" && name != "bloomhdriterations") {
        if (m_scene_general->bloom_uniform_writer)
            m_scene_general->bloom_uniform_writer(name, ShaderValue(value.data(), value.size()));
    } else if (name.starts_with("fog") && name != "fogdistance" && name != "fogheight") {
        const bool height = name.starts_with("fogheight");
        if (name.ends_with("color")) {
            WriteSceneGeneralUniform(height ? "g_FogHeightColor" : "g_FogDistanceColor", ShaderValue(value.data(), 3));
        } else {
            const auto scalar = [this](const char* key) { return (*SceneGeneralValue(key))[0]; };
            const float start = scalar(height ? "fogheightstart" : "fogdistancestart");
            const float end = scalar(height ? "fogheightend" : "fogdistanceend");
            const float near = scalar(height ? "fogheightstartdensity" : "fogdistancestartdensity");
            const float far = scalar(height ? "fogheightenddensity" : "fogdistanceenddensity");
            const std::array<float, 4> packed {start, end - start, near, far - near};
            WriteSceneGeneralUniform(height ? "g_FogHeightParams" : "g_FogDistanceParams", ShaderValue(packed));
        }
    } else if (name.starts_with("wind") || name.starts_with("gravity")) {
        RefreshSceneForces();
    } else if (name == "transparentsorting" || name == "customsortorder") {
        SetCustomSortOrder(g.customsortorder && !g.transparentsorting);
        m_scene->transparent_sorting = g.transparentsorting && m_scene->display_sized;
        if (before_custom != CustomSortOrder() || before_transparent != m_scene->transparent_sorting)
            MarkSceneGraphMutated("scene-sort-mode");
    } else if (name.starts_with("cameraparallax")) {
        auto* updater = dynamic_cast<WPShaderValueUpdater*>(m_scene->shaderValueUpdater.get());
        if (!updater) return false;
        auto parallax = updater->CameraParallax();
        if (name == "cameraparallax") parallax.enable = value[0] != 0;
        if (name == "cameraparallaxamount") parallax.amount = value[0];
        if (name == "cameraparallaxdelay") parallax.delay = value[0];
        if (name == "cameraparallaxmouseinfluence") parallax.mouseinfluence = value[0];
        updater->SetCameraParallax(parallax);
    } else if (name.starts_with("camerashake")) {
        m_camera_shake.registered = true;
        m_camera_shake.enabled = SceneGeneralValue("camerashake")->operator[](0) != 0;
        m_camera_shake.amplitude = SceneGeneralValue("camerashakeamplitude")->operator[](0);
        m_camera_shake.speed = SceneGeneralValue("camerashakespeed")->operator[](0);
        m_camera_shake.roughness = SceneGeneralValue("camerashakeroughness")->operator[](0);
    } else if (name == "camerafade") SetCameraFadeEnabled(value[0] != 0);
    else if (name == "fov" || name == "nearz" || name == "farz" || name == "perspectiveoverridefov") {
        const auto found = m_scene->cameras.find("global_perspective");
        if (found != m_scene->cameras.end() && found->second) {
            auto& camera = *found->second;
            camera.SetFov(std::clamp(m_scene->display_sized ? g.fov : g.perspectiveoverridefov, 0.1f, 179.9f));
            if (m_scene->display_sized) camera.SetClip(g.nearz, g.farz);
            else if (const auto canvas = m_scene->cameras.find("global"); canvas != m_scene->cameras.end() && canvas->second)
                FitCanvasPerspective(camera, *canvas->second);
            camera.Update();
        }
    }
    if (mode) m_scene_general->pending |= name == "camerafade" ? 4u : 1u;
    return true;
}
} // namespace wallpaper
