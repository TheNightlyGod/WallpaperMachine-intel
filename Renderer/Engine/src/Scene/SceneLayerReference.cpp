#include "Scene/SceneLayerReference.hpp"
#include "SpecTexs.hpp"

#include "Fs/VFS.h"

#include <cctype>
#include <regex>

namespace wallpaper
{
namespace
{

bool LooksLikeFileTextureName(std::string_view name) {
    if (name.empty()) return false;
    if (name.find('/') != std::string_view::npos) return true;
    if (name.find('.') != std::string_view::npos) return true;
    return false;
}

bool TextureNameHasFile(fs::VFS* vfs, std::string_view name) {
    if (vfs == nullptr || name.empty() || LooksLikeFileTextureName(name)) return false;
    const std::string tex_path = "/assets/materials/" + std::string(name) + ".tex";
    if (vfs->Contains(tex_path)) return true;
    return vfs->Contains("/assets/" + std::string(name) + ".tex");
}

int32_t ObjectId(const nlohmann::json& object) {
    if (! object.contains("id") || ! object.at("id").is_number_integer()) return 0;
    return object.at("id").get<int32_t>();
}

bool ObjectVisibleRoot(const nlohmann::json& object) {
    if (! object.contains("image") || object.at("image").is_null()) return false;
    if (! object.contains("visible")) return true;
    const auto& visible = object.at("visible");
    if (visible.is_object()) return true;
    if (visible.is_boolean()) return visible.get<bool>();
    return true;
}

void HarvestTextureString(std::string_view value, int32_t consumer_id, bool in_own_effects,
                          const LayerObjectIndex& index, fs::VFS* vfs,
                          std::vector<LayerTextureRef>& out) {
    if (in_own_effects && IsOwnEffectChainInput(value, consumer_id)) return;
    auto resolved = ResolveLayerTextureName(std::string(value), index, vfs);
    if (! resolved.is_layer || resolved.source_id == 0) return;
    LayerCompositeSlot slot = LayerCompositeSlot::None;
    ParseImageLayerCompositeId(value, &slot);
    out.push_back(LayerTextureRef {
        .consumer_id = consumer_id,
        .source_id   = resolved.source_id,
        .slot        = slot,
    });
}

/// `in_own_effects`: `node` is inside the consumer's own `effects`, where its
/// `_a` and `_b` name the chain's buffers rather than the layer.
void HarvestTextures(const nlohmann::json& node, int32_t consumer_id, const LayerObjectIndex& index,
                     fs::VFS* vfs, std::vector<LayerTextureRef>& out, bool in_own_effects = false) {
    if (node.is_object()) {
        if (node.contains("textures") && node.at("textures").is_array()) {
            for (const auto& item : node.at("textures")) {
                if (item.is_string()) {
                    HarvestTextureString(
                        item.get<std::string>(), consumer_id, in_own_effects, index, vfs, out);
                }
            }
        }
        if (node.contains("dependencies") && node.at("dependencies").is_array()) {
            for (const auto& item : node.at("dependencies")) {
                if (! item.is_number_integer()) continue;
                const auto source_id = item.get<int32_t>();
                // The editor lists the layers the object's textures name; older
                // versions list the layer itself too, once for each name its own
                // effects bind. An id carries no slot, so it cannot ask for the
                // last frame, and the layer waits on nothing of its own: whatever
                // it does sample of itself is a texture name, harvested above.
                if (source_id == 0 || source_id == consumer_id) continue;
                out.push_back(LayerTextureRef {
                    .consumer_id = consumer_id,
                    .source_id   = source_id,
                    .slot        = LayerCompositeSlot::None,
                });
            }
        }
        for (const auto& item : node.items()) {
            HarvestTextures(item.value(), consumer_id, index, vfs, out,
                            in_own_effects || item.key() == "effects");
        }
        return;
    }
    if (node.is_array()) {
        for (const auto& item : node) {
            HarvestTextures(item, consumer_id, index, vfs, out, in_own_effects);
        }
    }
}

enum class VisitColor
{
    White,
    Gray,
    Black,
};

std::string WalkCycle(int32_t id,
                      const std::unordered_map<int32_t, std::vector<int32_t>>& edges,
                      std::unordered_map<int32_t, VisitColor>& color) {
    color[id] = VisitColor::Gray;
    const auto found = edges.find(id);
    if (found != edges.end()) {
        for (const auto next : found->second) {
            auto& next_color = color[next];
            if (next_color == VisitColor::Gray) return std::string(kLayerTextureIllegalCycle);
            if (next_color == VisitColor::White) {
                if (auto reason = WalkCycle(next, edges, color); ! reason.empty()) return reason;
            }
        }
    }
    color[id] = VisitColor::Black;
    return {};
}

} // namespace

std::optional<int32_t> ParseImageLayerCompositeId(std::string_view name, LayerCompositeSlot* slot) {
    if (slot != nullptr) *slot = LayerCompositeSlot::None;
    static const std::regex re { R"(^_rt_imageLayerComposite_([0-9]+)(?:_([abAB]))?$)" };
    std::string             text { name };
    std::smatch             match;
    if (! std::regex_match(text, match, re)) return std::nullopt;
    int32_t id = 0;
    try {
        id = std::stoi(match[1].str());
    } catch (...) {
        return std::nullopt;
    }
    if (slot != nullptr && match[2].matched) {
        const char suffix = static_cast<char>(std::tolower(static_cast<unsigned char>(match[2].str()[0])));
        *slot = suffix == 'b' ? LayerCompositeSlot::B : LayerCompositeSlot::A;
    } else if (slot != nullptr) {
        *slot = LayerCompositeSlot::A;
    }
    return id;
}

bool IsImageLayerCompositeName(std::string_view name) {
    return ParseImageLayerCompositeId(name).has_value();
}

bool IsOwnEffectChainInput(std::string_view name, int32_t layer_id) {
    return layer_id != 0 && ParseImageLayerCompositeId(name) == layer_id;
}

LayerObjectIndex BuildLayerObjectIndex(const nlohmann::json& objects) {
    LayerObjectIndex index;
    if (! objects.is_array()) return index;
    std::size_t order = 0;
    for (const auto& object : objects) {
        const auto id = ObjectId(object);
        if (id == 0) continue;
        LayerObjectIndex::Entry entry;
        entry.id    = id;
        entry.order = order++;
        if (object.contains("name") && object.at("name").is_string()) {
            entry.name = object.at("name").get<std::string>();
        }
        ++index.id_counts[id];
        if (index.by_id.find(id) == index.by_id.end()) index.by_id.emplace(id, entry);
        if (! entry.name.empty()) index.ids_by_name[entry.name].push_back(id);
    }
    return index;
}

LayerTextureResolution ResolveLayerTextureName(std::string name, const LayerObjectIndex& index,
                                               fs::VFS* vfs) {
    LayerTextureResolution result;
    result.resolved = name;
    if (name.empty()) return result;

    LayerCompositeSlot slot = LayerCompositeSlot::None;
    if (const auto composite_id = ParseImageLayerCompositeId(name, &slot)) {
        result.is_layer  = true;
        result.source_id = *composite_id;
        const auto count = index.id_counts.find(*composite_id);
        if (count == index.id_counts.end() || count->second == 0) {
            result.error = std::string(kLayerTextureMissingTarget);
        } else if (count->second > 1) {
            result.error = std::string(kLayerTextureDuplicateId);
        }
        result.resolved = GenLinkTex(*composite_id);
        return result;
    }

    if (IsSpecTex(name)) return result;
    if (LooksLikeFileTextureName(name) || TextureNameHasFile(vfs, name)) return result;

    const auto names = index.ids_by_name.find(name);
    if (names == index.ids_by_name.end() || names->second.empty()) return result;
    result.is_layer = true;
    if (names->second.size() > 1) {
        result.error = std::string(kLayerTextureDuplicateName);
        return result;
    }
    result.source_id = names->second.front();
    const auto count = index.id_counts.find(result.source_id);
    if (count != index.id_counts.end() && count->second > 1) {
        result.error = std::string(kLayerTextureDuplicateId);
        return result;
    }
    result.resolved = GenLinkTex(result.source_id);
    return result;
}

std::vector<LayerTextureRef> CollectLayerTextureRefs(const nlohmann::json&   objects,
                                                     const LayerObjectIndex& index, fs::VFS* vfs) {
    std::vector<LayerTextureRef> refs;
    if (! objects.is_array()) return refs;
    for (const auto& object : objects) {
        HarvestTextures(object, ObjectId(object), index, vfs, refs);
    }
    return refs;
}

std::unordered_set<int32_t> CollectReachableLayerIds(const nlohmann::json&   objects,
                                                     const LayerObjectIndex& index, fs::VFS* vfs) {
    std::unordered_map<int32_t, std::vector<int32_t>> edges;
    std::vector<int32_t>                              pending;
    if (! objects.is_array()) return {};

    for (const auto& object : objects) {
        const auto id = ObjectId(object);
        if (id == 0) continue;
        std::vector<LayerTextureRef> refs;
        HarvestTextures(object, id, index, vfs, refs);
        auto& destinations = edges[id];
        for (const auto& ref : refs) {
            if (ref.source_id == 0) continue;
            destinations.push_back(ref.source_id);
        }
        if (ObjectVisibleRoot(object)) {
            pending.insert(pending.end(), destinations.begin(), destinations.end());
        }
    }

    std::unordered_set<int32_t> reachable;
    while (! pending.empty()) {
        const auto id = pending.back();
        pending.pop_back();
        if (! reachable.insert(id).second) continue;
        const auto found = edges.find(id);
        if (found == edges.end()) continue;
        pending.insert(pending.end(), found->second.begin(), found->second.end());
    }
    return reachable;
}

std::string ClassifyLayerTextureReferences(const std::vector<LayerTextureRef>& refs,
                                           const LayerObjectIndex&             index) {
    std::unordered_map<int32_t, std::vector<int32_t>> edges;
    for (const auto& ref : refs) {
        if (ref.source_id == 0) continue;
        const auto count = index.id_counts.find(ref.source_id);
        if (count == index.id_counts.end() || count->second == 0) {
            return std::string(kLayerTextureMissingTarget);
        }
        if (count->second > 1) return std::string(kLayerTextureDuplicateId);
        if (ref.consumer_id != 0 && ref.consumer_id != ref.source_id) {
            edges[ref.consumer_id].push_back(ref.source_id);
        }
    }

    std::unordered_map<int32_t, VisitColor> color;
    for (const auto& [id, _] : edges) {
        (void)_;
        if (color[id] != VisitColor::White) continue;
        if (auto reason = WalkCycle(id, edges, color); ! reason.empty()) return reason;
    }
    return {};
}

} // namespace wallpaper
