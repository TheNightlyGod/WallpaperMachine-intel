// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#include "WPImageObject.h"
#include "WPObjectSchema.hpp"
#include "Scene/SpecTexs.hpp"
#include "Utils/Logging.h"
#include "Fs/VFS.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <sstream>

using namespace wallpaper::wpscene;

namespace
{

constexpr const char* kPreviousBuffer = "previous";

bool ReadPlainString(const nlohmann::json& json, const char* key, std::string& out) {
    const auto found = json.find(key);
    return found != json.end() && ReadStringSetting(*found, out);
}

void ReadPlainFlag(const nlohmann::json& json, const char* key, bool& out) {
    if (const auto found = json.find(key); found != json.end()) ReadFlagSetting(*found, out);
}

// A non-negative whole number; anything else leaves `out` as it was.
void ReadUnsigned(const nlohmann::json& json, const char* key, uint32_t& out) {
    const auto found = json.find(key);
    if (found == json.end()) return;
    double number = 0.0;
    if (! ReadNumberSetting(*found, number) || ! std::isfinite(number) || number < 0.0) return;
    out = static_cast<uint32_t>(std::min(number, 4294967295.0));
}

// The scene's lenient JSON of one asset file.
bool ReadAssetJson(wallpaper::fs::VFS& vfs, const std::string& path, nlohmann::json& out) {
    return ParseBoundedJson(wallpaper::fs::GetFileContent(vfs, "/assets/" + path), out);
}

} // namespace

void wallpaper::wpscene::ParsePuppetAnimationLayers(
    const nlohmann::json& json, std::vector<WPPuppetLayer::AnimationLayer>& layers,
    std::vector<nlohmann::json>& settings) {
    if (! json.is_array()) return;
    for (const auto& entry : json) {
        // Entries that are not objects are skipped in both lists, so index i of
        // them is the same entry.
        if (! entry.is_object()) continue;
        WPPuppetLayer::AnimationLayer layer;
        if (const auto found = entry.find("animation"); found != entry.end()) {
            ReadNumberSetting(*found, layer.id);
        }
        if (const auto found = entry.find("id"); found != entry.end()) {
            ReadNumberSetting(*found, layer.layer_id);
        }
        if (const auto found = entry.find("blend"); found != entry.end()) {
            ReadNumberSetting(*found, layer.blend);
        }
        if (const auto found = entry.find("rate"); found != entry.end()) {
            ReadNumberSetting(*found, layer.rate);
        }
        if (const auto found = entry.find("blendtime"); found != entry.end()) {
            ReadNumberSetting(*found, layer.blendtime);
        }
        if (const auto found = entry.find("visible"); found != entry.end()) {
            ReadFlagSetting(*found, layer.visible);
        }
        if (const auto found = entry.find("additive"); found != entry.end()) {
            ReadFlagSetting(*found, layer.additive);
        }
        if (const auto found = entry.find("blendin"); found != entry.end()) {
            ReadFlagSetting(*found, layer.blendin);
        }
        if (const auto found = entry.find("blendout"); found != entry.end()) {
            ReadFlagSetting(*found, layer.blendout);
        }
        if (const auto found = entry.find("name"); found != entry.end()) {
            ReadStringSetting(*found, layer.name);
        }
        layers.push_back(std::move(layer));
        settings.push_back(entry);
    }
}

bool WPEffectCommand::FromJson(const nlohmann::json& json) {
    if (! json.is_object()) return false;
    ReadPlainString(json, "command", command);
    ReadPlainString(json, "target", target);
    ReadPlainString(json, "source", source);
    return true;
}

namespace
{
// A combo or condition value as Wallpaper Engine's JSON reads it as an integer: integers as
// they are, a double truncated, anything else 0 (`sub_1401E63B0`).
int ConditionInt(const nlohmann::json& value) {
    if (value.is_number_integer()) return value.get<int>();
    if (value.is_number_float()) return static_cast<int>(value.get<double>());
    return 0;
}

// `clear` as `sub_1401E7170` reads it: an empty string clears to black; otherwise up to four
// numbers separated by spaces, and only all four ask for the clear when the buffer is made.
void ReadClear(const nlohmann::json& json, WPEffectFbo& fbo) {
    const auto found = json.find("clear");
    if (found == json.end() || ! found->is_string()) return;
    const std::string& text = found->get_ref<const std::string&>();
    const char*        at   = text.c_str();
    if (*at == '\0') {
        fbo.clear = true;
        return;
    }
    for (std::size_t lane = 0; lane < 4; ++lane) {
        fbo.clear_color[lane] = static_cast<float>(std::atof(at));
        while (*at != '\0' && *at != ' ') ++at;
        bool spaced = false;
        while (*at == ' ') {
            ++at;
            spaced = true;
        }
        if (lane == 3) {
            fbo.clear = true;
            return;
        }
        if (! spaced) return;
        if (*at == '\0' && lane < 2) return;
        if (*at == '\0') {
            // A trailing space after the third number: the fourth reads as 0 and counts.
            fbo.clear_color[3] = 0.0f;
            fbo.clear          = true;
            return;
        }
    }
}
} // namespace

bool wallpaper::wpscene::EffectConditionsHold(const nlohmann::json& conditions, const nlohmann::json* combos) {
    if (! conditions.is_array()) return true;
    for (const auto& element : conditions) {
        if (! element.is_object()) continue;
        bool holds = true;
        for (const auto& [key, want] : element.items()) {
            int have = 0;
            if (combos != nullptr && combos->is_object()) {
                if (const auto found = combos->find(key); found != combos->end()) have = ConditionInt(*found);
            }
            if (want.is_number()) {
                holds = holds && have == ConditionInt(want);
            } else if (want.is_object()) {
                const auto value = want.find("value");
                const int  v     = value != want.end() ? ConditionInt(*value) : 0;
                const auto op    = want.find("op");
                const std::string_view word =
                    op != want.end() && op->is_string() ? std::string_view(op->get_ref<const std::string&>())
                                                        : std::string_view();
                if (word == "ge") holds = holds && have >= v;
                else if (word == "gt") holds = holds && have > v;
                else if (word == "le") holds = holds && have <= v;
                else if (word == "lt") holds = holds && have < v;
                else holds = holds && have == v;
            }
        }
        if (! holds) return false;
    }
    return true;
}

bool WPEffectFbo::FromJson(const nlohmann::json& json) {
    if (! json.is_object()) return false;
    const auto name_value   = json.find("name");
    const auto format_value = json.find("format");
    if (name_value == json.end() || ! name_value->is_string() || format_value == json.end() ||
        ! format_value->is_string()) {
        return false;
    }
    name   = name_value->get<std::string>();
    format = format_value->get<std::string>();
    ReadUnsigned(json, "scale", scale);
    if (scale == 0) {
        LOG_INFO("effect buffer '%s' has a scale of 0, reading it as 1", name.c_str());
        scale = 1;
    }
    ReadUnsigned(json, "width", width);
    ReadUnsigned(json, "height", height);
    ReadUnsigned(json, "fit", fit);
    if (const auto found = json.find("unique"); found != json.end() && found->is_boolean()) {
        unique = found->get<bool>();
    }
    if (const auto found = json.find("uvs"); found != json.end() && found->is_string()) {
        repeat = found->get_ref<const std::string&>() == "repeat";
    }
    ReadClear(json, *this);
    return true;
}

bool WPImageEffect::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    if (! json.is_object()) return false;
    std::string file;
    if (! ReadPlainString(json, "file", file) || file.empty()) {
        LOG_ERROR("effect instance has no file");
        return false;
    }
    if (const auto found = json.find("id"); found != json.end()) ReadNumberSetting(*found, id);
    ReadPlainString(json, "name", name);
    instance_name = name;
    if (const auto found = json.find("visible"); found != json.end()) {
        ReadFlagSetting(*found, visible);
        // Only a binding is kept: a user property decides at load, a script
        // keeps deciding while the scene runs.
        if (VisibilityIsBound(*found)) {
            visible_setting  = *found;
            scripted_visible = found->contains("script");
        }
    }

    // The file's `conditions` read the instance's own `combos` (sub_1401E7170: a4["combos"]).
    const auto      combos_found = json.find("combos");
    const auto*     combos       = combos_found != json.end() ? &*combos_found : nullptr;
    nlohmann::json file_json;
    if (! ReadAssetJson(vfs, file, file_json) || ! FromFileJson(file_json, vfs, combos)) {
        LOG_ERROR("cannot load effect file %s", file.c_str());
        return false;
    }

    // The instance's i-th entry overrides the material of the file's i-th `passes` entry, the
    // position Wallpaper Engine reads it by (sub_1401E7170), commands and dropped passes counted.
    if (const auto found = json.find("passes"); found != json.end() && found->is_array()) {
        for (std::size_t pass = 0; pass < passes.size() && pass < material_entries.size(); ++pass) {
            const std::size_t entry = material_entries[pass];
            if (entry >= found->size()) continue;
            WPMaterialPass override_pass;
            if (override_pass.FromJson((*found)[entry])) passes[pass].Update(override_pass);
        }
    }
    return true;
}

bool WPImageEffect::FromFileJson(const nlohmann::json& json, fs::VFS& vfs, const nlohmann::json* combos) {
    if (! json.is_object()) return false;
    if (const auto found = json.find("version"); found != json.end()) {
        ReadNumberSetting(*found, version);
    }
    ReadPlainString(json, "name", name);
    // A buffer, a pass or a bind whose `conditions` do not hold is left out (sub_1401E7170).
    const auto holds = [combos](const nlohmann::json& entry) {
        const auto found = entry.find("conditions");
        return found == entry.end() || EffectConditionsHold(*found, combos);
    };
    if (const auto found = json.find("fbos"); found != json.end() && found->is_array()) {
        for (const auto& entry : *found) {
            if (! entry.is_object() || ! holds(entry)) continue;
            WPEffectFbo fbo;
            if (fbo.FromJson(entry)) fbos.push_back(std::move(fbo));
        }
    }

    const auto list = json.find("passes");
    if (list == json.end() || ! list->is_array() || list->empty()) {
        LOG_ERROR("effect file has no passes");
        return false;
    }
    bool compose = false;
    for (std::size_t position = 0; position < list->size(); ++position) {
        const auto& entry = (*list)[position];
        if (! entry.is_object()) return false;
        if (! holds(entry)) continue;
        std::string material_path;
        if (ReadPlainString(entry, "material", material_path)) {
            nlohmann::json material_json;
            WPMaterial     material;
            if (! ReadAssetJson(vfs, material_path, material_json) ||
                ! material.FromJson(material_json)) {
                LOG_ERROR("effect pass material %s cannot be loaded", material_path.c_str());
                return false;
            }
            WPMaterialPass pass;
            const auto     binds = entry.find("bind");
            if (binds != entry.end() && binds->is_array() &&
                std::any_of(binds->begin(), binds->end(),
                            [](const nlohmann::json& bind) { return bind.is_object() && bind.contains("conditions"); })) {
                nlohmann::json kept = entry;
                auto&          list_of_binds = kept["bind"];
                list_of_binds.erase(std::remove_if(list_of_binds.begin(), list_of_binds.end(),
                                                   [&holds](const nlohmann::json& bind) {
                                                       return bind.is_object() && ! holds(bind);
                                                   }),
                                    list_of_binds.end());
                pass.FromJson(kept);
            } else {
                pass.FromJson(entry);
            }
            materials.push_back(std::move(material));
            material_paths.push_back(material_path);
            passes.push_back(std::move(pass));
            material_entries.push_back(position);
            if (const auto flag = entry.find("compose"); flag != entry.end()) {
                bool value = false;
                if (ReadFlagSetting(*flag, value) && value) compose = true;
            }
        } else if (entry.contains("command")) {
            WPEffectCommand command;
            command.FromJson(entry);
            // It runs once this many material passes have been drawn (passes left out do not count).
            command.afterpos = static_cast<i32>(materials.size());
            commands.push_back(std::move(command));
        } else {
            LOG_ERROR("effect pass has neither a material nor a command");
            return false;
        }
    }

    // `functions`: a name a script runs, kept only for `"action": "clear"` with at least one of
    // its `fbos` naming a buffer of the effect (sub_1401E7170).
    if (const auto found = json.find("functions"); found != json.end() && found->is_object()) {
        for (const auto& [function_name, function] : found->items()) {
            if (function_name.empty() || ! function.is_object()) continue;
            const auto action = function.find("action");
            if (action == function.end() || ! action->is_string() ||
                action->get_ref<const std::string&>() != "clear") {
                continue;
            }
            const auto listed = function.find("fbos");
            if (listed == function.end() || ! listed->is_array()) continue;
            WPEffectFunction kept { .name = function_name, .fbos = {} };
            for (const auto& buffer : *listed) {
                if (! buffer.is_string()) continue;
                const auto at = std::find_if(fbos.begin(), fbos.end(), [&buffer](const WPEffectFbo& fbo) {
                    return fbo.name == buffer.get_ref<const std::string&>();
                });
                if (at != fbos.end()) kept.fbos.push_back(static_cast<uint32_t>(at - fbos.begin()));
            }
            if (! kept.fbos.empty()) functions.push_back(std::move(kept));
        }
    }

    if (compose) {
        if (materials.size() != 2) {
            LOG_ERROR("compose effect needs exactly two passes, has %zu", materials.size());
            return false;
        }
        // The two passes meet in a buffer of the instance's own, which no
        // buffer the file declares may share a name with.
        std::string buffer;
        for (int serial = 1;; ++serial) {
            buffer = std::string(WE_FULL_COMPO_BUFFER_PREFIX) + std::to_string(serial);
            if (std::none_of(fbos.begin(), fbos.end(),
                             [&buffer](const WPEffectFbo& fbo) { return fbo.name == buffer; })) {
                break;
            }
        }
        WPEffectFbo link;
        link.name   = buffer;
        link.format = "rgba_backbuffer";
        link.scale  = 1;
        link.unique = true;
        fbos.push_back(std::move(link));
        passes[0].target = buffer;
        passes[0].bind.push_back({ kPreviousBuffer, 0 });
        passes[1].bind.push_back({ buffer, 0 });
    }
    return true;
}

bool WPImageObject::FromJson(const nlohmann::json& json, fs::VFS& vfs) {
    if (! json.is_object()) return false;
    if (! ReadPlainString(json, "image", image) || image.empty()) {
        LOG_ERROR("image object has no image");
        return false;
    }
    if (const auto found = json.find("id"); found != json.end()) ReadInt32(*found, id);
    if (const auto found = json.find("parent"); found != json.end()) ReadInt32(*found, parent_id);
    ReadPlainString(json, "name", name);

    const auto read_vec3 = [&json](const char* key, std::array<float, 3>& lanes,
                                   nlohmann::json& setting) {
        const auto found = json.find(key);
        if (found == json.end()) return false;
        setting = *found;
        ReadTolerantVec3(setting, lanes);
        return true;
    };
    if (read_vec3("origin", origin, origin_setting)) dynamic_origin = SettingIsDriven(origin_setting);
    read_vec3("scale", scale, scale_setting);
    read_vec3("angles", angles, angles_setting);

    if (const auto found = json.find("visible"); found != json.end()) {
        visible_setting = *found;
        ReadFlagSetting(visible_setting, visible);
        dynamic_visible = VisibilityIsBound(visible_setting);
    }
    if (const auto found = json.find("alpha"); found != json.end()) {
        alpha_setting = *found;
        ReadNumberSetting(alpha_setting, alpha);
        dynamic_alpha = alpha_setting.is_object() && (alpha_setting.contains("user") ||
                                                      alpha_setting.contains("script") ||
                                                      alpha_setting.contains("animation"));
    }
    if (const auto found = json.find("brightness"); found != json.end()) {
        ReadNumberSetting(*found, brightness);
    }
    if (const auto found = json.find("color"); found != json.end()) ReadStrictVec(*found, color);
    if (const auto found = json.find("colorBlendMode"); found != json.end()) {
        ReadNumberSetting(*found, colorBlendMode);
    }
    ReadPlainString(json, "alignment", alignment);
    ReadPlainString(json, "attachment", attachment);
    ReadPlainFlag(json, "copybackground", copybackground);
    ReadPlainFlag(json, "clampuvs", clampuvs);
    ReadPlainFlag(json, "perspective", perspective);
    ReadPlainFlag(json, "nointerpolation", nointerpolation);
    ReadPlainFlag(json, "ledsource", ledsource);
    ReadPlainFlag(json, "castshadow", castshadow);
    ReadPlainFlag(json, "solid", solid);
    ReadPlainFlag(json, "disablepropagation", disablepropagation);
    ParseDependencies(json, dependencies);
    AbsorbFieldBindings(json, field_bindings);

    // The model file decides the kind of layer, and its size when it has one.
    nlohmann::json model_json;
    if (! ReadAssetJson(vfs, image, model_json) || ! model_json.is_object()) {
        LOG_ERROR("cannot load model file %s", image.c_str());
        return false;
    }
    std::string material_path;
    if (! ReadPlainString(model_json, "material", material_path) || material_path.empty()) {
        LOG_ERROR("model %s has no material", image.c_str());
        return false;
    }
    ReadPlainFlag(model_json, "fullscreen", fullscreen);
    ReadPlainFlag(model_json, "autosize", autosize);
    ReadPlainFlag(model_json, "projectlayer", projectlayer);
    ReadPlainFlag(model_json, "solidlayer", solidlayer);
    ReadPlainFlag(model_json, "nopadding", nopadding);
    ReadPlainFlag(model_json, "instanced", instanced);
    config.model_passthrough = false;
    ReadPlainFlag(model_json, "passthrough", config.model_passthrough);
    config.passthrough = config.model_passthrough;
    ReadPlainString(model_json, "puppet", puppet);
    if (const auto found = json.find("config"); found != json.end() && found->is_object()) {
        ReadPlainFlag(*found, "passthrough", config.passthrough);
    }

    // Size: the object's own `size`, else the one its model states, else twice the origin. A
    // model states a size for a layer that saved none (the editor writes a sprite sheet's frame
    // there), never over one the scene saved. A fullscreen layer reads none of them, and has no
    // parallax depth: the screen it copies is drawn back over the whole screen wherever the
    // cursor is, so its saved depth is not read either.
    if (fullscreen) {
        parallaxDepth = { 0.0f, 0.0f };
    } else {
        if (const auto found = json.find("size"); found != json.end()) {
            ReadStrictVec(*found, size);
        } else if (const auto width = model_json.find("width"); width != model_json.end()) {
            int32_t w = 0, h = 0;
            ReadNumberSetting(*width, w);
            if (const auto height = model_json.find("height"); height != model_json.end()) {
                ReadNumberSetting(*height, h);
            }
            size = { static_cast<float>(w), static_cast<float>(h) };
        } else {
            size = { origin[0] * 2.0f, origin[1] * 2.0f };
        }
        if (const auto found = json.find("parallaxDepth"); found != json.end()) {
            ReadStrictVec(*found, parallaxDepth);
        }
    }
    if (const auto found = model_json.find("cropoffset"); found != model_json.end()) {
        ReadStrictVec(*found, cropoffset);
    }

    nlohmann::json material_json;
    if (! ReadAssetJson(vfs, material_path, material_json)) {
        LOG_ERROR("cannot load material file %s", material_path.c_str());
        return false;
    }
    // A material that reads but has no shader is the shader loader's to refuse.
    if (! material.FromJson(material_json)) {
        LOG_ERROR("material %s is not valid", material_path.c_str());
    }
    material.use_puppet = ! puppet.empty();
    if (const auto found = json.find("instance"); found != json.end() && found->is_object()) {
        WPMaterialPass instance_pass;
        if (instance_pass.FromJson(*found)) {
            material.MergePass(instance_pass);
            // A runtime picture that replaces the placeholder white takes the tint with it. (A
            // picture a property chooses does too, but only the scene's property table says
            // whether the property has one: the loader decides that.)
            for (std::size_t slot = 0; slot < instance_pass.usertextures.size(); ++slot) {
                const bool white = slot < material.textures.size() && material.textures[slot] == "util/white";
                if (white && IsSystemUserTexture(instance_pass.usertextures[slot])) {
                    color        = { 1.0f, 1.0f, 1.0f };
                    colorIgnored = true;
                    if (field_bindings.is_object()) field_bindings.erase("color");
                }
            }
        }
    }

    if (const auto found = json.find("animationlayers"); found != json.end()) {
        ParsePuppetAnimationLayers(*found, puppet_layers, puppet_layer_settings);
    }
    if (const auto found = json.find("effects"); found != json.end() && found->is_array()) {
        for (const auto& entry : *found) {
            WPImageEffect effect;
            if (effect.FromJson(entry, vfs)) effects.push_back(std::move(effect));
        }
    }
    return true;
}
