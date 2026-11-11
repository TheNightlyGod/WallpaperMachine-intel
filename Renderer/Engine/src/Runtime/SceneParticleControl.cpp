#include "Runtime/SceneRuntimeContext.hpp"
#include "Particle/ParticleSystem.h"
#include "Scene/Scene.h"
#include "wpscene/WPParticleObject.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace wallpaper {
namespace {
using Override = wpscene::ParticleInstanceoverride;
constexpr std::pair<std::string_view, float Override::*> scalars[] {
    { "alpha", &Override::alpha }, { "size", &Override::size },
    { "count", &Override::count }, { "speed", &Override::speed },
    { "lifetime", &Override::lifetime }, { "rate", &Override::rate },
    { "brightness", &Override::brightness }
};
constexpr std::size_t kColour = std::size(scalars), kPoints = kColour + 1, kAngles = kPoints + 8;
static_assert(kAngles + 8 == ParticleInstanceUpdate::kFields);
constexpr float kUnsetPoint = std::numeric_limits<float>::max();

int PointIndex(std::string_view member, std::string_view prefix) {
    if (member.size() != prefix.size() + 1 || ! member.starts_with(prefix)) return -1;
    const char digit = member.back();
    return digit >= '0' && digit <= '7' ? digit - '0' : -1;
}

int FieldIndex(std::string_view member) {
    for (std::size_t index = 0; index < std::size(scalars); ++index)
        if (member == scalars[index].first) return static_cast<int>(index);
    if (member == "colorn") return kColour;
    if (const int index = PointIndex(member, "controlpoint"); index >= 0) return kPoints + index;
    if (const int index = PointIndex(member, "controlpointangle"); index >= 0) return kAngles + index;
    return -1;
}

std::array<float, 3> ReadField(const Override& instance, std::size_t field) {
    if (field < kColour) return { instance.*scalars[field].second, 0, 0 };
    if (field == kColour) {
        if (instance.overColor) {
            const auto& color = instance.color;
            return { color[0] / 255.0f, color[1] / 255.0f, color[2] / 255.0f };
        }
        return instance.overColorn ? instance.colorn : std::array<float, 3> { -1, -1, -1 };
    }
    const bool angle = field >= kAngles;
    const auto slot = field - (angle ? kAngles : kPoints);
    auto value = angle ? instance.controlpointangle[slot] : instance.controlpoint[slot];
    if (!(angle ? instance.controlpointangleSet[slot] : instance.controlpointSet[slot]))
        value[0] = kUnsetPoint;
    return value;
}

void StoreField(Override& instance, std::size_t field, const std::array<float, 3>& value) {
    if (field < kColour) instance.*scalars[field].second = value[0];
    else if (field == kColour) {
        instance.colorn = value;
        instance.overColor = false;
        instance.overColorn = true;
    } else {
        const bool angle = field >= kAngles;
        const auto slot = field - (angle ? kAngles : kPoints);
        (angle ? instance.controlpointangle : instance.controlpoint)[slot] = value;
        // FLT_MAX leaves the last effective point/rotation alone, as the native
        // rebind does; it is not a point at an enormous coordinate.
        (angle ? instance.controlpointangleSet : instance.controlpointSet)[slot] = value[0] != kUnsetPoint;
    }
    instance.enabled = true;
}
} // namespace

bool SceneRuntimeContext::HasParticleLayer(std::string_view name) const {
    return m_scene != nullptr && m_scene->paritileSys != nullptr &&
           m_scene->paritileSys->ForLayer(ResolveLayerName(name)) != nullptr;
}

bool SceneRuntimeContext::ParticlePlayback(std::string_view name, std::string_view operation,
                                           int32_t count) {
    auto* system = m_scene != nullptr && m_scene->paritileSys != nullptr
        ? m_scene->paritileSys->ForLayer(ResolveLayerName(name)) : nullptr;
    if (system == nullptr) return false;
    if (operation == "isPlaying") return system->IsPlaying();
    if (operation == "play") system->Play();
    else if (operation == "pause") system->Pause();
    else if (operation == "stop") system->Stop();
    else if (operation == "emit") system->EmitParticles(count);
    else return false;
    return true;
}

std::optional<std::vector<double>> SceneRuntimeContext::ParticleInstanceValue(
    std::string_view name, std::string_view member) const {
    if (m_scene == nullptr || m_scene->paritileSys == nullptr) return std::nullopt;
    auto& system = *m_scene->paritileSys;
    const auto key = ResolveLayerName(name);
    const auto instance = system.InstanceForLayer(key);
    const int field = FieldIndex(member);
    if (instance == nullptr || field < 0) return std::nullopt;
    const auto* pending = system.PendingInstanceForLayer(key);
    const auto value = pending != nullptr && (pending->fields & (1u << field)) != 0
        ? pending->values[field] : ReadField(*instance, field);
    return std::vector<double>(value.begin(), value.begin() + (field < int(kColour) ? 1 : 3));
}

bool SceneRuntimeContext::SetParticleInstanceValue(std::string_view name, std::string_view member,
                                                   std::span<const double> values) {
    if (m_scene == nullptr || m_scene->paritileSys == nullptr) return false;
    const int field = FieldIndex(member);
    if (field < 0 || values.size() != (field < int(kColour) ? 1u : 3u) ||
        !std::all_of(values.begin(), values.end(), [](double value) {
            return std::isfinite(value) && std::isfinite(static_cast<float>(value));
        })) return false;
    auto& system = *m_scene->paritileSys;
    const auto key = ResolveLayerName(name);
    const auto instance = system.InstanceForLayer(key);
    if (instance == nullptr) return false;
    auto& pending = *system.PendingInstanceForLayer(key, true);
    if (!pending.apply) {
        pending.apply = [instance](ParticleInstanceUpdate& update) {
            for (std::size_t index = 0; index < ParticleInstanceUpdate::kFields; ++index)
                if ((update.fields & (1u << index)) != 0) StoreField(*instance, index, update.values[index]);
            instance->rate = std::fmax(.01f, instance->rate);
        };
    }
    std::transform(values.begin(), values.end(), pending.values[field].begin(),
                   [](double value) { return static_cast<float>(value); });
    pending.fields |= 1u << field;
    system.QueueInstanceUpdate(key);
    return true;
}
} // namespace wallpaper
