// Clean-room implementation from the WallpaperMachine spec p1-scene-structure.md; written without access to the original source.
#include "WPMaterial.h"
#include "WPObjectSchema.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <cstddef>
#include <sstream>

using namespace wallpaper::wpscene;

namespace
{

// Reads a JSON array into a list, one `decode` call per element. Anything that
// is not an array reads as an empty list.
template<typename Item, typename Decode>
std::vector<Item> DecodeArray(const nlohmann::json& json, Decode decode) {
    std::vector<Item> items;
    if (! json.is_array()) return items;
    items.reserve(json.size());
    std::transform(json.begin(), json.end(), std::back_inserter(items), decode);
    return items;
}

// The slot-indexed lists of a pass (`textures`, `usertextures`) layer on top of
// each other: the list grows to the longer one, and a slot of `top` that is not
// `vacant` replaces the slot below it.
template<typename Item, typename Vacant>
void OverlaySlots(std::vector<Item>& base, const std::vector<Item>& top, Vacant vacant) {
    if (top.size() > base.size()) base.resize(top.size());
    for (std::size_t i = 0; i < top.size(); ++i) {
        if (! vacant(top[i])) base[i] = top[i];
    }
}

// A `usertextures` entry: a bare string names a project property; an object
// holds `name` and, for the runtime's own images, `type`. Anything else
// (`null`, an empty object, a number) leaves the slot as it is.
WPUserTexture DecodeUserTexture(const nlohmann::json& json) {
    const auto text = [&json](const char* key) {
        const auto found = json.find(key);
        return found != json.end() && found->is_string() ? found->get<std::string>()
                                                         : std::string();
    };
    WPUserTexture texture;
    if (json.is_string()) {
        texture.name = json.get<std::string>();
    } else if (json.is_object()) {
        texture.name = text("name");
        texture.type = text("type");
    }
    return texture;
}

std::string DecodeTexturePath(const nlohmann::json& json) {
    return json.is_string() ? json.get<std::string>() : std::string();
}

std::unordered_map<std::string, int32_t> ReadCombos(const nlohmann::json& json) {
    std::unordered_map<std::string, int32_t> combos;
    if (! json.is_object()) return combos;
    for (const auto& [name, value] : json.items()) {
        if (value.is_boolean()) {
            combos[name] = value.get<bool>() ? 1 : 0;
        } else if (value.is_number()) {
            int32_t number = 0;
            if (ReadNumberSetting(value, number)) combos[name] = number;
        }
    }
    return combos;
}

// The numbers a constant's `value` holds. A string is split at white space and a
// piece that is not a number reads as 0; an array keeps its numbers (and reads
// any other element as 0); a bare number is one component.
std::vector<float> ReadConstantComponents(const nlohmann::json& value) {
    std::vector<float> lanes;
    if (value.is_number()) {
        lanes.push_back(value.get<float>());
    } else if (value.is_string()) {
        std::istringstream words(value.get<std::string>());
        std::string        piece;
        while (words >> piece) {
            float number = 0.0f;
            if (! detail::ParseNumberToken(piece, number)) number = 0.0f;
            lanes.push_back(number);
        }
    } else if (value.is_array()) {
        for (const auto& element : value) {
            lanes.push_back(element.is_number() ? element.get<float>() : 0.0f);
        }
    }
    return lanes;
}

// One `constantshadervalues` entry. An entry that cannot be read has no
// components and does not fail the material.
WPConstantShaderValue ReadConstant(const nlohmann::json& json) {
    WPConstantShaderValue constant;
    if (! json.is_object()) {
        if (json.is_number() || json.is_string()) constant.value = ReadConstantComponents(json);
        return constant;
    }
    if (const auto value = json.find("value"); value != json.end()) {
        constant.value = ReadConstantComponents(*value);
    }
    // A constant's property is a plain name, or the `{name, condition}` form: then the
    // constant is the flag "the choice equals the condition", 1 or 0.
    if (const auto user = json.find("user"); user != json.end()) {
        if (user->is_string()) {
            constant.user = user->get<std::string>();
        } else if (user->is_object()) {
            const auto name = user->find("name");
            if (name != user->end() && name->is_string()) {
                constant.user = name->get<std::string>();
                const auto condition = user->find("condition");
                if (condition != user->end() && condition->is_string()) {
                    constant.user_condition = condition->get<std::string>();
                }
            }
        }
    }
    if (const auto script = json.find("script"); script != json.end() && script->is_string()) {
        constant.script = script->get<std::string>();
    }
    if (const auto props = json.find("scriptproperties"); props != json.end() && props->is_object()) {
        constant.scriptproperties = *props;
    }
    if (const auto animation = json.find("animation");
        animation != json.end() && animation->is_object()) {
        constant.animation = *animation;
    }
    return constant;
}

std::unordered_map<std::string, WPConstantShaderValue> ReadConstants(const nlohmann::json& json) {
    std::unordered_map<std::string, WPConstantShaderValue> constants;
    if (! json.is_object()) return constants;
    for (const auto& [name, entry] : json.items()) constants[name] = ReadConstant(entry);
    return constants;
}

// What every layer of a pass has in common: slots, user textures, combos and
// constants (the pass-shaped keys a later layer may override).
template<typename Target>
void ReadPassShape(const nlohmann::json& json, Target& target) {
    if (const auto found = json.find("textures"); found != json.end()) {
        target.textures = DecodeArray<std::string>(*found, DecodeTexturePath);
    }
    if (const auto found = json.find("usertextures"); found != json.end()) {
        target.usertextures = DecodeArray<WPUserTexture>(*found, DecodeUserTexture);
    }
    if (const auto found = json.find("combos"); found != json.end()) {
        target.combos = ReadCombos(*found);
    }
    if (const auto found = json.find("constantshadervalues"); found != json.end()) {
        target.constantshadervalues = ReadConstants(*found);
    }
}

template<typename Target>
void OverlayPassShape(Target& target, const WPMaterialPass& later) {
    OverlaySlots(target.textures, later.textures,
                 [](const std::string& path) { return path.empty(); });
    OverlaySlots(target.usertextures, later.usertextures, [](const WPUserTexture& user) {
        return user.name.empty() && user.type.empty();
    });
    for (const auto& [name, value] : later.combos) target.combos[name] = value;
    for (const auto& [name, value] : later.constantshadervalues) {
        target.constantshadervalues[name] = value;
    }
}

} // namespace

bool wallpaper::wpscene::IsSystemUserTexture(const WPUserTexture& user_texture) {
    // The two cover slots a wallpaper may bind. Anything else named `system` is
    // a slot this renderer does not supply.
    return user_texture.type == "system" &&
           (user_texture.name == "$mediaThumbnail" ||
            user_texture.name == "$mediaPreviousThumbnail");
}

bool WPMaterialPassBindItem::FromJson(const nlohmann::json& json) {
    if (! json.is_object()) return false;
    const auto name = json.find("name");
    if (name == json.end() || ! name->is_string()) return false;
    this->name = name->get<std::string>();
    index      = 0;
    if (const auto slot = json.find("index"); slot != json.end()) {
        ReadNumberSetting(*slot, index);
    }
    return true;
}

// A later layer of the same pass: textures and user textures replace by slot
// where it names one, constants and combos replace by key. `target` and `bind`
// belong to the effect file's entry and are never overridden.
void WPMaterialPass::Update(const WPMaterialPass& p) {
    OverlayPassShape(*this, p);
}

void WPMaterial::MergePass(const WPMaterialPass& p) {
    OverlayPassShape(*this, p);
}

bool WPMaterialPass::FromJson(const nlohmann::json& json) {
    if (! json.is_object()) return false;
    ReadPassShape(json, *this);
    if (const auto found = json.find("target"); found != json.end() && found->is_string()) {
        target = found->get<std::string>();
    }
    if (const auto found = json.find("bind"); found != json.end() && found->is_array()) {
        for (const auto& entry : *found) {
            WPMaterialPassBindItem item;
            if (item.FromJson(entry)) bind.push_back(std::move(item));
        }
    }
    return true;
}

bool WPMaterial::FromJson(const nlohmann::json& json) {
    if (! json.is_object()) return false;
    const auto passes = json.find("passes");
    if (passes == json.end() || ! passes->is_array() || passes->empty()) {
        LOG_ERROR("material has no passes");
        return false;
    }
    // Only the first pass is a layer's material.
    const auto& first = passes->front();
    if (! first.is_object()) return false;
    const auto shader_name = first.find("shader");
    if (shader_name == first.end() || ! shader_name->is_string()) {
        LOG_ERROR("material pass has no shader");
        return false;
    }
    shader = shader_name->get<std::string>();
    const auto word = [&first](const char* key, std::string& out) {
        if (const auto found = first.find(key); found != first.end() && found->is_string()) {
            out = found->get<std::string>();
        }
    };
    word("blending", blending);
    word("cullmode", cullmode);
    word("depthtest", depthtest);
    word("depthwrite", depthwrite);
    word("alphawriting", alphawriting);
    ReadPassShape(first, *this);
    return true;
}
