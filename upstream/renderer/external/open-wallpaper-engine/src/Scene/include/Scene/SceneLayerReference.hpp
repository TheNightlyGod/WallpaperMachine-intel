#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <nlohmann/json.hpp>

namespace wallpaper
{

namespace fs
{
class VFS;
}

/// Authored "layer as texture" names. Wallpaper Engine writes the composite of
/// another layer as `_rt_imageLayerComposite_<id>` with an optional `_a` / `_b`
/// ping-pong suffix. `_a` (or no suffix) is that layer's produced output.
/// Inside the layer's own effect chain both are the chain's ping-pong buffers,
/// the image the effect works on (`IsOwnEffectChainInput`); a self `_b`
/// anywhere else is still taken as last-frame history.
inline constexpr std::string_view kLayerTextureMissingTarget =
    "a texture names a layer that does not exist";
inline constexpr std::string_view kLayerTextureDuplicateName =
    "a texture names a layer whose name is not unique";
inline constexpr std::string_view kLayerTextureDuplicateId =
    "a texture names a layer whose id is not unique";
inline constexpr std::string_view kLayerTextureIllegalCycle =
    "layer texture references form a cycle";
inline constexpr std::string_view kLayerTextureHistoryFeedback =
    "a layer texture reference reads a previous frame";

struct LayerObjectIndex {
    struct Entry {
        int32_t     id { 0 };
        std::string name;
        std::size_t order { 0 };
    };

    std::unordered_map<int32_t, Entry>                    by_id;
    std::unordered_map<int32_t, std::size_t>              id_counts;
    std::unordered_map<std::string, std::vector<int32_t>> ids_by_name;
};

enum class LayerCompositeSlot
{
    None,
    A,
    B,
};

struct LayerTextureRef {
    int32_t            consumer_id { 0 };
    int32_t            source_id { 0 };
    LayerCompositeSlot slot { LayerCompositeSlot::None };
};

struct LayerTextureResolution {
    std::string resolved;
    int32_t     source_id { 0 };
    std::string error;
    bool        is_layer { false };
};

LayerObjectIndex BuildLayerObjectIndex(const nlohmann::json& objects);

std::optional<int32_t> ParseImageLayerCompositeId(std::string_view name,
                                                  LayerCompositeSlot* slot = nullptr);

bool IsImageLayerCompositeName(std::string_view name);

/// Whether `name`, bound by an effect of layer `layer_id` itself, is one of that
/// chain's ping-pong buffers, `_a` (or the bare name) or `_b`: the image the
/// effect works on, the one `previous` names (for the first effect, the layer
/// before any effect). The editor writes the buffer `previous` was in when the
/// effect was set up, so the suffix alternates along the chain and can be stale
/// after effects are reordered; either way it is the effect's input. The layer's
/// composite is what its chain ends in, so read here it could only be a
/// texture the same frame has yet to draw. Other layers binding the same name
/// still get the composite.
bool IsOwnEffectChainInput(std::string_view name, int32_t layer_id);

/// Resolve one authored texture string. File names still go through VFS: a
/// unique layer name is only treated as a layer if no material file exists.
LayerTextureResolution ResolveLayerTextureName(std::string name, const LayerObjectIndex& index,
                                               fs::VFS* vfs);

std::vector<LayerTextureRef> CollectLayerTextureRefs(const nlohmann::json&   objects,
                                                     const LayerObjectIndex& index, fs::VFS* vfs);

std::unordered_set<int32_t> CollectReachableLayerIds(const nlohmann::json&   objects,
                                                     const LayerObjectIndex& index, fs::VFS* vfs);

/// First non-empty reason for missing/duplicate/cycle/history. Empty if every
/// reference is a same-frame legal dependency or a same-frame snapshot.
std::string ClassifyLayerTextureReferences(const std::vector<LayerTextureRef>& refs,
                                           const LayerObjectIndex&             index);

} // namespace wallpaper
