#pragma once

#include "Scene/SceneMesh.h"
#include "Utils/Linalg.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace wallpaper {
class SceneNode;

enum class ModelDataBufferType { Float32, UInt16, UInt32 };
struct ModelDataBufferView {
    ModelDataBufferType type {ModelDataBufferType::Float32};
    std::span<const std::byte> bytes;
};
struct ModelDataShapeUpdate {
    bool remove {false};
    std::optional<ModelDataBufferView> vertices;
    std::optional<ModelDataBufferView> indices;
    bool remove_indices {false};
    std::optional<uint32_t> format;
    std::optional<std::string> material;
    std::optional<bool> dynamic_vertices;
    std::optional<bool> dynamic_indices;
};
struct ModelDataUpdate {
    std::vector<ModelDataShapeUpdate> shapes;
    std::optional<linalg::Vector3f> bounds_min;
    std::optional<linalg::Vector3f> bounds_max;
};

// Prepared once from the registered material asset. The layer gets its own
// constants; geometry and translated shader programs remain shared.
struct ModelDataMaterial {
    std::shared_ptr<SceneMaterial> material;
    uint32_t required_format {0};
    std::function<void(const std::shared_ptr<SceneNode>&, uint32_t)> attach;
    std::function<std::shared_ptr<ModelDataMaterial>()> shadow;
};
struct ModelDataLayerOptions {
    bool perspective {false};
    bool castshadow {true};
    bool solid {true};
    bool disablepropagation {false};
    bool reflected {true};
};
using ModelDataMaterialLoader = std::function<std::shared_ptr<ModelDataMaterial>(
    std::string_view, uint32_t, std::string&)>;
using ModelDataLayerSetup = std::function<void(const std::shared_ptr<SceneNode>&,
    const std::vector<std::shared_ptr<ModelDataMaterial>>&, const ModelDataLayerOptions&)>;

struct ModelDataShape {
    uint32_t format {0};
    std::string material_path;
    bool dynamic_vertices {false};
    bool dynamic_indices {false};
    uint32_t submesh {0};
    std::shared_ptr<ModelDataMaterial> material;
};
struct ModelDataResource {
    std::vector<std::optional<ModelDataShape>> shapes;
    std::shared_ptr<SceneMesh> mesh;
    linalg::Vector3f bounds_min {linalg::Vector3f::Zero()};
    linalg::Vector3f bounds_max {linalg::Vector3f::Zero()};
    bool explicit_bounds {false};
    bool destroy_requested {false};
    std::unordered_set<std::string> layers;
};
struct ModelDataLayer {
    uint32_t resource {0};
    std::weak_ptr<SceneNode> node;
    linalg::Vector3f color {linalg::Vector3f::Ones()};
    ModelDataLayerOptions options;
};
struct SceneModelDataState {
    ModelDataMaterialLoader load_material;
    ModelDataLayerSetup setup_layer;
    std::unordered_map<uint32_t, std::shared_ptr<ModelDataResource>> resources;
    std::unordered_map<std::string, ModelDataLayer> layers;
};
} // namespace wallpaper
