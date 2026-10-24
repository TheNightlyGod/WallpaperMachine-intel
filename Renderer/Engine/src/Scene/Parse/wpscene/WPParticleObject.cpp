// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#include "WPParticleObject.h"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"
#include "Fs/VFS.h"
#include "Core/StringHelper.hpp"
#include "Interface/IParticleRawGener.h"

#include <sstream>
#include <algorithm>
#include <cmath>
#include <limits>
#include <string>

using namespace wallpaper::wpscene;

namespace
{

/// How deep a chain of child particle files may nest; a file that names itself
/// (or a cycle of files) stops here instead of recursing for ever.
constexpr int kMaxChildDepth = 8;

/// Counts the child entries being loaded on this thread. The guard unwinds on
/// every way out of `ParticleChild::FromJson`.
thread_local int t_child_depth = 0;

struct ChildDepthGuard {
    ChildDepthGuard() { ++t_child_depth; }
    ~ChildDepthGuard() { --t_child_depth; }
    ChildDepthGuard(const ChildDepthGuard&)            = delete;
    ChildDepthGuard& operator=(const ChildDepthGuard&) = delete;
};

/// A view of one scene-file member as a setting. A setting is written either
/// as its value or as a wrapper object that carries the value in `value` next
/// to a `script` or `user` source. The view never owns the JSON.
class SettingView {
public:
    SettingView() = default;
    SettingView(const nlohmann::json& holder, const char* key) {
        if (! holder.is_object()) return;
        const auto it = holder.find(key);
        if (it != holder.end()) m_raw = &*it;
    }

    bool Present() const { return m_raw != nullptr; }
    /// The member exactly as written.
    const nlohmann::json& Raw() const { return *m_raw; }

    /// True when the member is a wrapper that a script or a property drives.
    bool Driven() const {
        return m_raw != nullptr && m_raw->is_object() &&
               (m_raw->contains("script") || m_raw->contains("user"));
    }

    /// The plain value inside the wrapper, or the member itself.
    const nlohmann::json& Payload() const {
        if (m_raw->is_object()) {
            if (const auto it = m_raw->find("value"); it != m_raw->end()) return *it;
        }
        return *m_raw;
    }

    /// Vector reading: an array of at least three numbers, one number for all
    /// three components, or a string of numbers where a component the string
    /// lacks keeps the value `out` already has. A malformed array leaves `out`.
    void ReadVec3(std::array<float, 3>& out) const {
        if (m_raw == nullptr) return;
        const nlohmann::json& v = Payload();
        try {
            if (v.is_array()) {
                if (v.size() < 3) return;
                std::array<float, 3> got {};
                for (std::size_t i = 0; i < got.size(); ++i) {
                    if (! v[i].is_number()) return;
                    got[i] = v[i].get<float>();
                }
                out = got;
            } else if (v.is_number()) {
                out.fill(v.get<float>());
            } else if (v.is_string()) {
                std::istringstream words(v.get<std::string>());
                for (float& component : out) {
                    if (! (words >> component)) break;
                }
            }
        } catch (const nlohmann::json::exception& e) {
            LOG_INFO("particle object: unreadable vector setting: %s", e.what());
        }
    }

    /// A boolean the file may write as a boolean or as a number.
    void ReadFlag(bool& out) const {
        if (m_raw == nullptr) return;
        const nlohmann::json& v = Payload();
        if (v.is_boolean()) {
            out = v.get<bool>();
        } else if (v.is_number()) {
            out = v.get<double>() != 0.0;
        }
    }

private:
    const nlohmann::json* m_raw { nullptr };
};

/// Whether `key` names a field of the instance override that a project
/// property may drive: the plain fields and `controlpoint0..7` / `controlpointangle0..7`.
bool IsBindableOverrideKey(const std::string& key) {
    static const char* const kPlain[] = { "alpha", "size", "lifetime", "rate",      "speed",
                                          "count", "color", "colorn",   "brightness" };
    for (const char* plain : kPlain) {
        if (key == plain) return true;
    }
    for (const char* stem : { "controlpoint", "controlpointangle" }) {
        const std::size_t n = std::char_traits<char>::length(stem);
        if (key.size() == n + 1 && key.compare(0, n, stem) == 0 && key[n] >= '0' && key[n] <= '7')
            return true;
    }
    return false;
}

/// A non-negative whole number the file may write with a fraction.
uint32_t ClampedWhole(double value) {
    if (! std::isfinite(value) || value <= 0.0) return 0u;
    if (value >= static_cast<double>(std::numeric_limits<uint32_t>::max()))
        return std::numeric_limits<uint32_t>::max();
    return static_cast<uint32_t>(value);
}

/// A particle file or material named by the scene, read from the package.
bool LoadAssetJson(wallpaper::fs::VFS& vfs, const std::string& name, nlohmann::json& out) {
    if (name.empty()) return false;
    return PARSE_JSON(wallpaper::fs::GetFileContent(vfs, "/assets/" + name), out);
}

/// Control point numbers: 0..6 name themselves, anything else names the last.
wallpaper::i32 ClampControlpoint(wallpaper::i32 index) { return (index >= 0 && index <= 6) ? index : 7; }

} // namespace

bool ParticleChild::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    if (t_child_depth >= kMaxChildDepth) {
        LOG_ERROR("particle child nests deeper than %d files; entry dropped", kMaxChildDepth);
        return false;
    }
    ChildDepthGuard guard;

    std::string file;
    GET_JSON_NAME_VALUE_NOWARN(json, "name", file);
    if (file.empty()) return false;
    nlohmann::json child_json;
    if (! LoadAssetJson(vfs, file, child_json)) {
        LOG_ERROR("can't load child particle json: %s", file.c_str());
        return false;
    }
    name = file;
    if (! obj.FromJson(child_json, vfs)) {
        LOG_ERROR("child particle '%s' is not a usable particle file", file.c_str());
        return false;
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "type", type);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxcount", maxcount);
    GET_JSON_NAME_VALUE_NOWARN(json, "controlpointstartindex", controlpointstartindex);
    GET_JSON_NAME_VALUE_NOWARN(json, "probability", probability);
    GET_JSON_NAME_VALUE_NOWARN(json, "origin", origin);
    GET_JSON_NAME_VALUE_NOWARN(json, "scale", scale);
    GET_JSON_NAME_VALUE_NOWARN(json, "angles", angles);
    return true;
}

bool ParticleControlpoint::FromJson(const nlohmann::json& json) {
    uint32_t raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", raw_flags);
    GET_JSON_NAME_VALUE_NOWARN(json, "offset", offset);
    flags = EFlags(raw_flags);
    return true;
}

bool ParticleRender::FromJson(const nlohmann::json& json) {
    // Every call starts from the member defaults, so one object can be read again.
    *this = ParticleRender {};
    GET_JSON_NAME_VALUE_NOWARN(json, "name", name);

    const bool is_rope  = sstart_with(name, "rope");
    const bool is_trail = send_with(name, "trail");
    if (is_rope && is_trail) {
        length      = 1.0f;
        segments    = 4.0f;
        subdivision = 1.0f;
    } else if (is_rope) {
        subdivision = 4.0f;
        uvsmoothing = true;
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "length", length);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxlength", maxlength);
    GET_JSON_NAME_VALUE_NOWARN(json, "minlength", minlength);
    if (is_rope) {
        GET_JSON_NAME_VALUE_NOWARN(json, "subdivision", subdivision);
        subdivision = std::isfinite(subdivision) ? std::clamp(std::trunc(subdivision), 0.0f, 32.0f)
                                                 : 0.0f;
        if (is_trail) {
            GET_JSON_NAME_VALUE_NOWARN(json, "segments", segments);
            segments = std::isfinite(segments) ? std::clamp(std::trunc(segments), 2.0f, 32.0f)
                                               : 2.0f;
            length   = std::isfinite(length) ? std::max(length, 0.001f) : 0.001f;
        }
    }

    // The three uv settings may be bound to a property or a script; the raw
    // value goes to the scene loader, which follows it at run time.
    const SettingView uv_scale_view(json, "uvscale");
    const SettingView uv_scroll_view(json, "uvscrolling");
    const SettingView uv_smooth_view(json, "uvsmoothing");
    if (uv_scale_view.Present()) {
        uvscale_setting = uv_scale_view.Raw();
        float value { uvscale };
        if (GET_JSON_NAME_VALUE_NOWARN(json, "uvscale", value)) uvscale = RopeUvScaleOrOne(value);
    }
    if (uv_scroll_view.Present()) uvscrolling_setting = uv_scroll_view.Raw();
    if (uv_smooth_view.Present()) uvsmoothing_setting = uv_smooth_view.Raw();
    uv_scroll_view.ReadFlag(uvscrolling);
    uv_smooth_view.ReadFlag(uvsmoothing);
    // Smoothing eases the strip position, which scrolling already owns; a trail
    // never smooths.
    if (uvscrolling || is_trail) uvsmoothing = false;
    return true;
}

bool Emitter::FromJson(const nlohmann::json& json) {
    // A missing or mistyped key leaves the member as it is, without a warning.
    const auto lenient = [&json](const char* key, auto& member) {
        GET_JSON_NAME_VALUE_NOWARN(json, key, member);
    };

    id = 0;  // the member has no initialiser; an absent key must read 0
    lenient("name", name);
    lenient("id", id);
    lenient("rate", rate);
    lenient("instantaneous", instantaneous);
    lenient("speedmin", speedmin);
    lenient("speedmax", speedmax);
    lenient("directions", directions);
    lenient("origin", origin);
    lenient("distancemin", distancemin);
    lenient("distancemax", distancemax);
    lenient("cone", cone);

    // Only the direction of each axis matters, so the sign is reduced to -1, 0 or 1.
    lenient("sign", sign);
    for (int32_t& axis : sign) axis = (axis > 0) - (axis < 0);

    lenient("controlpoint", controlpoint);
    if (controlpoint >= 8) LOG_ERROR("emitter names control point %d; using 7", controlpoint);
    controlpoint = ClampControlpoint(controlpoint);

    uint32_t raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", raw_flags);
    flags = EFlags(raw_flags);

    GET_JSON_NAME_VALUE_NOWARN(json, "delay", delay);
    GET_JSON_NAME_VALUE_NOWARN(json, "duration", duration);
    GET_JSON_NAME_VALUE_NOWARN(json, "minperiodicduration", minperiodicduration);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxperiodicduration", maxperiodicduration);
    GET_JSON_NAME_VALUE_NOWARN(json, "minperiodicdelay", minperiodicdelay);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxperiodicdelay", maxperiodicdelay);
    GET_JSON_NAME_VALUE_NOWARN(json, "maxtoemitperperiod", maxtoemitperperiod);

    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingmode", audioprocessingmode);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingbounds", audioprocessingbounds);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingexponent", audioprocessingexponent);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingfrequencystart", audioprocessingfrequencystart);
    GET_JSON_NAME_VALUE_NOWARN(json, "audioprocessingfrequencyend", audioprocessingfrequencyend);
    return true;
}

bool ParticleInstanceoverride::FromJosn(const nlohmann::json& json) {
    enabled = true;
    if (! json.is_object()) return true;

    // Scalars: every one is a plain value under its own key.
    const std::pair<const char*, float*> scalars[] = {
        { "alpha", &alpha },     { "size", &size }, { "lifetime", &lifetime },
        { "rate", &rate },       { "speed", &speed }, { "count", &count },
        { "brightness", &brightness },
    };
    for (const auto& [key, target] : scalars) GET_JSON_NAME_VALUE_NOWARN(json, key, *target);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);

    // Colour: `color` wins; `colorn` is the same override on a 0..1 scale.
    if (const auto it = json.find("color"); it != json.end() && ! it->is_null()) {
        overColor = GET_JSON_NAME_VALUE_NOWARN(json, "color", color) || overColor;
    } else {
        overColorn = GET_JSON_NAME_VALUE_NOWARN(json, "colorn", colorn) || overColorn;
    }

    // Control points: eight slots each for the offset and the angles.
    struct PointGroup {
        const char*                         stem;
        std::array<bool, 8>&                set;
        std::array<std::array<float, 3>, 8>& value;
    };
    for (const PointGroup& group : { PointGroup { "controlpoint", controlpointSet, controlpoint },
                                     PointGroup { "controlpointangle", controlpointangleSet,
                                                  controlpointangle } }) {
        for (std::size_t slot = 0; slot < group.value.size(); ++slot) {
            std::array<float, 3> got {};
            if (GET_JSON_NAME_VALUE_NOWARN(json, std::string(group.stem) + std::to_string(slot), got)) {
                group.value[slot] = got;
                group.set[slot]   = true;
            }
        }
    }

    // Bindings: a bindable field whose value is an object naming a project property.
    for (const auto& [key, field] : json.items()) {
        if (! field.is_object() || ! IsBindableOverrideKey(key)) continue;
        const auto user = field.find("user");
        if (user != field.end() && user->is_string()) bindings[key] = user->get<std::string>();
    }
    return true;
}

bool Particle::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    if (! json.is_object() || ! json.contains("emitter")) {
        LOG_ERROR("particle file has no emitter key");
        return false;
    }

    std::string material_path;
    GET_JSON_NAME_VALUE_NOWARN(json, "material", material_path);
    nlohmann::json material_json;
    if (! LoadAssetJson(vfs, material_path, material_json)) {
        LOG_ERROR("can't load particle material json: %s", material_path.c_str());
        return false;
    }
    material.FromJson(material_json);

    // The list-valued keys: absent or null is an empty list.
    const auto list_of = [&json](const char* key) -> const nlohmann::json* {
        const auto found = json.find(key);
        return (found != json.end() && found->is_array()) ? &*found : nullptr;
    };

    emitters.clear();
    if (const auto* list = list_of("emitter")) {
        for (const auto& entry : *list) {
            Emitter emitter;
            emitter.FromJson(entry);
            emitters.push_back(std::move(emitter));
        }
    }

    initializers.clear();
    if (const auto* list = list_of("initializer")) {
        initializers.assign(list->begin(), list->end());
    }
    operators.clear();
    if (const auto* list = list_of("operator")) {
        operators.assign(list->begin(), list->end());
    }

    renderers.clear();
    if (const auto* list = list_of("renderer")) {
        for (const auto& entry : *list) {
            ParticleRender renderer;
            renderer.FromJson(entry);
            renderers.push_back(std::move(renderer));
        }
    } else {
        ParticleRender sprite;
        sprite.FromJson(nlohmann::json { { "name", "sprite" } });
        renderers.push_back(std::move(sprite));
    }

    controlpoints.clear();
    if (const auto* list = list_of("controlpoint")) {
        for (const auto& entry : *list) {
            ParticleControlpoint point;
            point.FromJson(entry);
            controlpoints.push_back(std::move(point));
        }
    }

    children.clear();
    if (const auto* list = list_of("children")) {
        for (const auto& entry : *list) {
            ParticleChild child;
            if (child.FromJson(entry, vfs)) children.push_back(std::move(child));
        }
    }

    GET_JSON_NAME_VALUE_NOWARN(json, "animationmode", animationmode);
    GET_JSON_NAME_VALUE_NOWARN(json, "sequencemultiplier", sequencemultiplier);
    if (json.contains("maxcount")) {
        double count { static_cast<double>(maxcount) };
        if (GET_JSON_NAME_VALUE_NOWARN(json, "maxcount", count)) maxcount = ClampedWhole(count);
    }
    GET_JSON_NAME_VALUE_NOWARN(json, "starttime", starttime);
    uint32_t raw_flags { 0 };
    GET_JSON_NAME_VALUE_NOWARN(json, "flags", raw_flags);
    flags = EFlags(raw_flags);
    return true;
}

bool WPParticleObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    // Resources first: a scene object whose particle file is unusable is dropped.
    GET_JSON_NAME_VALUE_NOWARN(json, "particle", particle);
    bool usable = false;
    {
        nlohmann::json file_json;
        if (! LoadAssetJson(vfs, particle, file_json)) {
            LOG_ERROR("can't load particle json: %s", particle.c_str());
        } else if (! particleObj.FromJson(file_json, vfs)) {
            LOG_ERROR("particle '%s' is not a usable particle file", particle.c_str());
        } else {
            usable = true;
        }
    }

    // Identity.
    id = 0;
    GET_JSON_NAME_VALUE_NOWARN(json, "name", name);
    GET_JSON_NAME_VALUE_NOWARN(json, "id", id);
    GET_JSON_NAME_VALUE_NOWARN(json, "parent", parent_id);
    ParseDependencies(json, dependencies);

    // Placement; each setting keeps its raw JSON for the scene loader.
    const SettingView origin_view(json, "origin");
    const SettingView angles_view(json, "angles");
    const SettingView scale_view(json, "scale");
    origin_view.ReadVec3(origin);
    angles_view.ReadVec3(angles);
    scale_view.ReadVec3(scale);
    if (origin_view.Present()) origin_setting = origin_view.Raw();
    if (angles_view.Present()) angles_setting = angles_view.Raw();
    if (scale_view.Present()) scale_setting = scale_view.Raw();
    GET_JSON_NAME_VALUE_NOWARN(json, "parallaxDepth", parallaxDepth);

    // Settings a script or a property may drive.
    GET_JSON_NAME_VALUE_NOWARN(json, "visible", visible);
    if (const SettingView visible_view(json, "visible"); visible_view.Present()) {
        visible_setting = visible_view.Raw();
        dynamic_visible = visible_view.Driven();
    }
    dynamic_origin = origin_view.Driven();

    if (const SettingView override_view(json, "instanceoverride");
        override_view.Present() && override_view.Raw().is_object()) {
        instanceoverride.FromJosn(override_view.Raw());
    }

    if (! usable) return false;
    if (json.is_object()) AbsorbFieldBindings(json, field_bindings);
    return true;
}
