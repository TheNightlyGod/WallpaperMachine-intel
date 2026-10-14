#include "Runtime/SceneRuntimeContext.hpp"

#include "Interface/IShaderValueUpdater.h"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Runtime/ScriptedDynamicValue.hpp"
#include "Scene/include/Scene/Scene.h"
#include "Scene/include/Scene/SceneImageEffectLayer.h"
#include "Scene/include/Scene/SceneMaterial.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "Scene/SceneNode.h"
#include "Scripting/ScriptEngine.hpp"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "WPSoundParser.hpp"

#include <Eigen/Geometry>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <functional>
#include <limits>
#include <sstream>
#include <vector>

namespace wallpaper
{

namespace
{
std::string NormalizeTemplatePath(std::string_view value) {
    if (value.empty()) return {};
    return std::filesystem::path(std::string(value)).generic_string();
}

std::string MakeWorkshopLocalAlias(std::string_view canonical_path) {
    const std::string          normalized = NormalizeTemplatePath(canonical_path);
    constexpr std::string_view prefix     = "models/workshop/";
    if (! normalized.starts_with(prefix)) return {};

    const std::size_t workshop_begin = prefix.size();
    const std::size_t slash          = normalized.find('/', workshop_begin);
    if (slash == std::string::npos || slash + 1 >= normalized.size()) return {};

    return std::string("models/") + normalized.substr(slash + 1);
}

// Where the editor puts an asset imported from the Workshop: `models/bar.json`
// of item 123 lands at `models/workshop/123/bar.json`. Empty for anything that
// is not a numeric item id or already names a workshop folder.
std::string MakeWorkshopAssetPath(std::string_view asset_path, std::string_view workshop_id) {
    if (workshop_id.empty() ||
        ! std::all_of(workshop_id.begin(), workshop_id.end(), [](char c) {
            return c >= '0' && c <= '9';
        }))
        return {};

    const std::string normalized = NormalizeTemplatePath(asset_path);
    const std::size_t slash      = normalized.find('/');
    if (slash == std::string::npos || slash == 0 || slash + 1 >= normalized.size()) return {};

    const std::string folder = normalized.substr(0, slash + 1);
    const std::string rest   = normalized.substr(slash + 1);
    if (rest.starts_with("workshop/")) return {};
    return folder + "workshop/" + std::string(workshop_id) + "/" + rest;
}

bool SetRuntimeTextTexture(Scene& scene, const TextLayerState& state, uint32_t width,
                           uint32_t height, const std::vector<uint8_t>& rgba) {
    if (state.layer_key.empty() || scene.imageParser == nullptr) return false;
    if (width == 0 || height == 0 || rgba.empty()) return false;

    auto* runtime_images = dynamic_cast<RuntimeImageSource*>(scene.imageParser.get());
    if (runtime_images == nullptr) return false;

    runtime_images->SetRgbaImage(
        TextTextureName(state.layer_key), width, height, rgba.data(), rgba.size());
    return true;
}

RuntimePreparedTextLayerImage PrepareTextLayerImage(std::string name, uint64_t revision,
                                                    TextLayerState state) {
    const auto measured_size = MeasureTextLayerSize(state);
    const bool has_explicit_size =
        state.explicit_size.x() > 0.0f && state.explicit_size.y() > 0.0f;
    const Eigen::Vector2f layout_size = has_explicit_size ? state.explicit_size : measured_size;
    const Eigen::Vector2f raster_size =
        has_explicit_size ? state.explicit_size.cwiseMax(measured_size) : measured_size;
    const uint32_t width =
        std::clamp(static_cast<uint32_t>(std::ceil(std::max(1.0f, raster_size.x()))), 1u, 4096u);
    const uint32_t height =
        std::clamp(static_cast<uint32_t>(std::ceil(std::max(1.0f, raster_size.y()))), 1u, 4096u);
    const auto render_frame = TextLayerRenderFrameForRasterSize(state, raster_size);
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    return RuntimePreparedTextLayerImage {
        .name        = std::move(name),
        .revision    = revision,
        .state       = std::move(state),
        .layout_size = layout_size,
        .raster_size = raster_size,
        .render_frame = render_frame,
        .width       = width,
        .height      = height,
        .rgba        = std::move(rgba),
    };
}

Eigen::Vector2f CardMeshSize(const SceneMesh& mesh) {
    if (mesh.VertexCount() == 0) return Eigen::Vector2f::Zero();

    const auto& vertices = mesh.GetVertexArray(0);
    if (vertices.VertexCount() == 0 || vertices.OneSize() < 2) return Eigen::Vector2f::Zero();

    const float* data = vertices.Data();
    if (data == nullptr) return Eigen::Vector2f::Zero();

    float min_x = data[0];
    float max_x = data[0];
    float min_y = data[1];
    float max_y = data[1];
    for (std::size_t index = 1; index < vertices.VertexCount(); ++index) {
        const float x = data[index * vertices.OneSize()];
        const float y = data[index * vertices.OneSize() + 1u];
        min_x         = std::min(min_x, x);
        max_x         = std::max(max_x, x);
        min_y         = std::min(min_y, y);
        max_y         = std::max(max_y, y);
    }

    return Eigen::Vector2f(max_x - min_x, max_y - min_y);
}

bool SizeNearlyEqual(Eigen::Vector2f lhs, Eigen::Vector2f rhs, float tolerance) {
    return (lhs - rhs).cwiseAbs().maxCoeff() <= tolerance;
}

void ResizeCardMesh(SceneMesh& mesh, TextLayerRenderBounds bounds) {
    if (bounds.right <= bounds.left || bounds.top <= bounds.bottom) return;

    SceneMesh replacement(mesh.UpdateDriver());
    constexpr float z  = 0.0f;

    const std::array pos {
        bounds.left,  bounds.bottom, z, bounds.left, bounds.top, z,
        bounds.right, bounds.bottom, z, bounds.right, bounds.top, z,
    };
    constexpr std::array tex_coord {
        0.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f,
    };

    SceneVertexArray vertices(
        {
            { WE_IN_POSITION.data(), VertexType::FLOAT3 },
            { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 },
        },
        4);
    vertices.SetVertex(WE_IN_POSITION, pos);
    vertices.SetVertex(WE_IN_TEXCOORD, tex_coord);
    replacement.AddVertexArray(std::move(vertices));

    mesh.ChangeMeshDataFrom(replacement);
    mesh.SetDirty();
}

void ResizeCardMesh(SceneMesh& mesh, TextLayerRenderBounds bounds, TextLayerTextureBounds texture) {
    if (bounds.right <= bounds.left || bounds.top <= bounds.bottom) return;

    SceneMesh replacement(mesh.UpdateDriver());
    constexpr float z = 0.0f;

    const std::array pos {
        bounds.left,  bounds.bottom, z, bounds.left, bounds.top, z,
        bounds.right, bounds.bottom, z, bounds.right, bounds.top, z,
    };
    const std::array tex_coord {
        texture.left, texture.bottom, texture.left, texture.top,
        texture.right, texture.bottom, texture.right, texture.top,
    };

    SceneVertexArray vertices(
        {
            { WE_IN_POSITION.data(), VertexType::FLOAT3 },
            { WE_IN_TEXCOORD.data(), VertexType::FLOAT2 },
        },
        4);
    vertices.SetVertex(WE_IN_POSITION, pos);
    vertices.SetVertex(WE_IN_TEXCOORD, tex_coord);
    replacement.AddVertexArray(std::move(vertices));

    mesh.ChangeMeshDataFrom(replacement);
    mesh.SetDirty();
}

Eigen::Vector3f CursorHitTestWorldPosition(const ScriptHostContext& host_context) {
    return host_context.cursor_world_position;
}

Eigen::Vector2d CursorWorldToNdc(const CursorViewport& viewport, const Eigen::Vector3f& cursor) {
    if (viewport.content_size.x() == 0.0f || viewport.content_size.y() == 0.0f) {
        return Eigen::Vector2d { 0.0, 0.0 };
    }
    return Eigen::Vector2d {
        2.0 * (static_cast<double>(cursor.x()) - viewport.content_origin.x()) /
                viewport.content_size.x() -
            1.0,
        2.0 * (static_cast<double>(cursor.y()) - viewport.content_origin.y()) /
                viewport.content_size.y() -
            1.0,
    };
}

const SceneCamera* CameraForHitNode(const Scene& scene, const SceneNode& node) {
    if (! node.Camera().empty()) {
        const auto found = scene.cameras.find(node.Camera());
        if (found != scene.cameras.end()) return found->second.get();
    }
    return scene.activeCamera;
}

// Hit tests in the node's local plane so rotated and flipped layers keep
// their authored rectangle, then consults the coverage mask when present.
// A perspective camera unprojects the click through the real view-projection
// onto that plane; an ortho camera keeps the existing canvas-space inverse.
bool HitTestNode(SceneNode& node, Eigen::Vector2f size, const Eigen::Vector3f& cursor,
                 const NodeHitMask* mask, const SceneCamera* camera, Eigen::Vector2d ndc) {
    node.UpdateTrans();
    if (size.x() <= 0.0f && size.y() <= 0.0f) {
        size = Eigen::Vector2f(100.0f, 100.0f);
    }

    Eigen::Vector4d local;
    if (camera != nullptr && camera->IsPerspective()) {
        const auto hit = IntersectNdcWithNodePlane(*camera, node, ndc.x(), ndc.y());
        if (! hit) return false;
        local = Eigen::Vector4d(hit->x(), hit->y(), hit->z(), 1.0);
    } else {
        const Eigen::Matrix4d model = node.ModelTrans();
        if (! std::isfinite(model.determinant()) || std::abs(model.determinant()) < 1e-12) {
            return false;
        }
        local = model.inverse() * Eigen::Vector4d(cursor.x(), cursor.y(), cursor.z(), 1.0);
    }

    const double half_width  = static_cast<double>(size.x()) * 0.5;
    const double half_height = static_cast<double>(size.y()) * 0.5;
    if (local.x() < -half_width || local.x() > half_width || local.y() < -half_height ||
        local.y() > half_height) {
        return false;
    }
    if (mask == nullptr || half_width <= 0.0 || half_height <= 0.0) return true;

    // Card meshes map local (left, top) to texture (0, 0).
    const float u = static_cast<float>((local.x() + half_width) / (2.0 * half_width));
    const float v = static_cast<float>((half_height - local.y()) / (2.0 * half_height));
    return mask->covers(u, v);
}

struct ClonedMaterialBinding {
    std::shared_ptr<SceneMaterial> source_material;
    std::shared_ptr<SceneMaterial> cloned_material;
};

std::shared_ptr<SceneMesh> CloneMesh(SceneMesh&                          mesh,
                                     std::vector<ClonedMaterialBinding>* material_bindings) {
    auto clone = std::make_shared<SceneMesh>(mesh.UpdateDriver());
    clone->SetPrimitive(mesh.Primitive());
    clone->SetPointSize(mesh.PointSize());
    clone->SetID(mesh.ID());
    clone->ChangeMeshDataFrom(mesh);
    if (mesh.Material() != nullptr) {
        clone->AddMaterial(SceneMaterial(*mesh.Material()));
        if (material_bindings != nullptr) {
            material_bindings->push_back(ClonedMaterialBinding {
                .source_material = mesh.MaterialSlotPtr(),
                .cloned_material = clone->MaterialSlotPtr(),
            });
        }
    }
    return clone;
}

std::shared_ptr<SceneNode> CloneNodeShallow(SceneNode& node, std::string name,
                                            std::vector<ClonedMaterialBinding>* material_bindings) {
    auto clone = std::make_shared<SceneNode>(
        node.Translate(), node.Scale(), node.Rotation(), std::move(name));
    clone->SetVisible(node.Visible());
    clone->SetSkipRenderPass(node.SkipRenderPass());
    clone->SetCamera(node.Camera());
    clone->ID() = node.ID();
    if (node.HasRenderTransformOverride()) {
        clone->SetRenderTransformOverride(node.RenderTrans());
    }
    if (node.Mesh() != nullptr) {
        clone->AddMesh(CloneMesh(*node.Mesh(), material_bindings));
    }
    return clone;
}

template<typename ListT>
bool SortNodeInList(ListT& nodes, SceneNode* target, int index) {
    if (target == nullptr) return false;

    auto current = std::find_if(nodes.begin(), nodes.end(), [target](const auto& entry) {
        return entry.get() == target;
    });
    if (current == nodes.end()) return false;

    const int size          = static_cast<int>(nodes.size());
    int       clamped_index = std::clamp(index, 0, std::max(0, size - 1));
    const int current_index = static_cast<int>(std::distance(nodes.begin(), current));
    if (current_index == clamped_index) return false;
    if (clamped_index > current_index) {
        ++clamped_index;
    }
    auto destination = nodes.begin();
    std::advance(destination, std::min(clamped_index, size));
    if (destination == current) return false;

    nodes.splice(destination, nodes, current);
    return true;
}

template<typename ListT>
int NodeIndexInList(const ListT& nodes, const SceneNode* target) {
    if (target == nullptr) return -1;

    int index = 0;
    for (const auto& entry : nodes) {
        if (entry.get() == target) return index;
        ++index;
    }
    return -1;
}

double WrapSeconds(double seconds, double duration_seconds) {
    if (! (duration_seconds > 0.0) || ! std::isfinite(seconds)) return std::max(0.0, seconds);
    double wrapped = std::fmod(seconds, duration_seconds);
    if (wrapped < 0.0) wrapped += duration_seconds;
    if (wrapped >= duration_seconds) wrapped = 0.0;
    return wrapped;
}

// A value of another kind is a change even when both print alike.
bool ProjectPropertyValueChanged(const RuntimeScalarValue& previous,
                                 const RuntimeScalarValue& next) {
    if (previous.kind != next.kind) return true;
    switch (next.kind) {
    case RuntimeScalarValue::Kind::Bool: return previous.bool_value != next.bool_value;
    case RuntimeScalarValue::Kind::Float: return previous.float_value != next.float_value;
    case RuntimeScalarValue::Kind::String: return previous.string_value != next.string_value;
    }
    return false;
}

std::unique_ptr<DynamicValue> MakePropertyValue(const RuntimeScalarValue& value) {
    switch (value.kind) {
    case RuntimeScalarValue::Kind::Bool: return std::make_unique<DynamicValue>(value.asBool());
    case RuntimeScalarValue::Kind::Float: return std::make_unique<DynamicValue>(value.asFloat());
    case RuntimeScalarValue::Kind::String: return std::make_unique<DynamicValue>(value.asString());
    }

    return std::make_unique<DynamicValue>();
}

void ApplyMaterialAlpha(SceneMaterial& material, float alpha) {
    auto& values = material.customShader.constValues;

    values["g_UserAlpha"] = ShaderValue(alpha);

    if (auto alpha_value = values.find("g_Alpha"); alpha_value != values.end()) {
        alpha_value->second = ShaderValue(alpha);
    }

    std::array<float, 4> color { 1.0f, 1.0f, 1.0f, alpha };
    if (const auto color_value = values.find("g_Color4"); color_value != values.end()) {
        const size_t component_count = std::min<size_t>(3, color_value->second.size());
        for (size_t index = 0; index < component_count; ++index) {
            color[index] = color_value->second[index];
        }
    }
    values["g_Color4"] = color;
}

void ApplyMaterialColor(SceneMaterial& material, const Eigen::Vector3f& color) {
    auto& values = material.customShader.constValues;
    const auto color4 = values.find("g_Color4");
    const float alpha = color4 != values.end() && color4->second.size() > 3
                            ? color4->second[3] : 1.0f;
    values["g_Color"] = std::array<float, 3> { color.x(), color.y(), color.z() };
    values["g_Color4"] = std::array<float, 4> { color.x(), color.y(), color.z(), alpha };
}

ShaderValue ShaderValueFromDynamicValue(const DynamicValue& value) {
    switch (value.getType()) {
    case DynamicValue::Vec4: return ShaderValue(value.getVec4().data(), 4);
    case DynamicValue::Vec3: return ShaderValue(value.getVec3().data(), 3);
    case DynamicValue::Vec2: return ShaderValue(value.getVec2().data(), 2);
    case DynamicValue::IVec4: {
        const auto           source = value.getIVec4();
        std::array<float, 4> converted {
            static_cast<float>(source.x()),
            static_cast<float>(source.y()),
            static_cast<float>(source.z()),
            static_cast<float>(source.w()),
        };
        return ShaderValue(converted);
    }
    case DynamicValue::IVec3: {
        const auto           source = value.getIVec3();
        std::array<float, 3> converted {
            static_cast<float>(source.x()),
            static_cast<float>(source.y()),
            static_cast<float>(source.z()),
        };
        return ShaderValue(converted);
    }
    case DynamicValue::IVec2: {
        const auto           source = value.getIVec2();
        std::array<float, 2> converted {
            static_cast<float>(source.x()),
            static_cast<float>(source.y()),
        };
        return ShaderValue(converted);
    }
    case DynamicValue::Boolean:
    case DynamicValue::Float:
    case DynamicValue::Int: return ShaderValue(value.getFloat());
    case DynamicValue::String: {
        std::istringstream stream(value.getString());
        std::vector<float> parsed;
        float              component = 0.0f;
        while (stream >> component) {
            parsed.push_back(component);
        }
        return parsed.empty() ? ShaderValue(0.0f) : ShaderValue(parsed);
    }
    case DynamicValue::Null: return ShaderValue(0.0f);
    }

    return ShaderValue(0.0f);
}


bool AlignmentContains(std::string_view alignment, std::string_view part) {
    return alignment.find(part) != std::string_view::npos;
}

// The rotation `SceneNode::GetLocalTrans` applies to the layer's geometry:
// x first, then y, then z.
Eigen::Matrix3f NodeRotationMatrix(const Eigen::Vector3f& angles) {
    return (Eigen::AngleAxisf(angles.z(), Eigen::Vector3f::UnitZ()) *
            Eigen::AngleAxisf(angles.y(), Eigen::Vector3f::UnitY()) *
            Eigen::AngleAxisf(angles.x(), Eigen::Vector3f::UnitX()))
        .toRotationMatrix();
}

void SyncEffectFinalNode(SceneNode& source, SceneImageEffectLayer& layer) {
    source.UpdateTrans();
    const auto matrix = source.ModelTrans();
    const auto sync_node = [&source, &matrix](SceneNode& target) {
        if (! target.HasRenderTransformOverride() ||
            ! (target.RenderTrans().array() == matrix.array()).all()) {
            target.SetRenderTransformOverride(matrix);
        }
        target.SetTranslate(source.Translate());
        target.SetScale(source.Scale());
        target.SetRotation(source.Rotation());
    };
    sync_node(layer.FinalNode());
    if (auto* resolved = layer.ResolvedFinalRenderNode(); resolved != nullptr) {
        sync_node(*resolved);
    }
}

} // namespace

bool NodeHitMask::covers(float u, float v) const noexcept {
    if (width == 0 || height == 0 || ! std::isfinite(u) || ! std::isfinite(v)) return false;
    if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f) return false;
    const auto x = std::min<uint32_t>(static_cast<uint32_t>(u * static_cast<float>(width)), width - 1);
    const auto y = std::min<uint32_t>(static_cast<uint32_t>(v * static_cast<float>(height)), height - 1);
    return alpha[static_cast<std::size_t>(y) * width + x] >= kOpaqueThreshold;
}

SceneRuntimeContext::SceneRuntimeContext(SceneRuntimeBootstrap bootstrap)
    : m_script_engine(std::make_unique<ScriptEngine>()),
      m_host_context(std::make_unique<ScriptHostContext>()),
      m_default_project_properties(
          bootstrap.authored_project_properties.value_or(bootstrap.project_properties)),
      m_project_properties(bootstrap.project_properties) {
    m_host_context->canvas_size = Eigen::Vector2f(static_cast<float>(bootstrap.canvas_width),
                                                  static_cast<float>(bootstrap.canvas_height));
    m_host_context->screen_resolution = m_host_context->canvas_size;
    // Until the renderer reports its presentation, the window is the canvas.
    m_cursor_viewport = CursorViewport {
        .origin         = Eigen::Vector2f::Zero(),
        .size           = m_host_context->canvas_size,
        .content_origin = Eigen::Vector2f::Zero(),
        .content_size   = m_host_context->canvas_size,
    };
    m_host_context->cursor_normalized_position = Eigen::Vector2f(0.5f, 0.5f);
    m_host_context->cursor_world_position      = Eigen::Vector3f::Zero();
    m_host_context->frame_time                 = 0.0;
    m_host_context->runtime_seconds            = 0.0;

    for (const auto& [name, value] : m_project_properties) {
        m_property_values.emplace(name, MakePropertyValue(value));
    }
    StartTextWorker();
}

SceneRuntimeContext::~SceneRuntimeContext() { StopTextWorker(); }

void SceneRuntimeContext::Tick(double frame_time) {
    ReleaseRetiredLayers();
    m_host_context->frame_time = frame_time;
    m_host_context->runtime_seconds += frame_time;
    // Loading a script-created template can register more scripts. Newly added
    // programs start next tick, and no iterator survives a loader callback.
    const auto scripted_value_count = m_scripted_values.size();
    const auto scene_script_count = m_scene_scripts.size();
    for (auto& [texture_key, playback] : m_video_texture_playback) {
        (void)texture_key;
        if (playback.paused) continue;
        const double scaled_delta = static_cast<double>(playback.rate) * frame_time;
        if (scaled_delta <= 0.0) continue;
        playback.absolute_seconds += scaled_delta;
    }
    for (auto& binding : m_scalar_animations) binding.playback->Advance(frame_time);
    // Property scripts initialize lazily on their first evaluation, so markers
    // crossed by this very tick are delivered to an initialized script.
    for (std::size_t index = 0; index < scripted_value_count; ++index) {
        auto* value = m_scripted_values[index];
        if (value != nullptr) value->reevaluate();
    }
    DispatchPendingAnimationEvents();
    bool shown = false;
    for (auto& [name, binding] : m_node_visibility) {
        (void)name;
        if (binding.node != nullptr && binding.value != nullptr) {
            const bool visible = binding.value->getBool();
            shown = shown || (visible && ! binding.node->Visible());
            binding.node->SetVisible(visible);
        }
    }
    if (shown) RequestGraphForShownLayers();
    for (auto& [name, binding] : m_node_translate) {
        (void)name;
        if (binding.node == nullptr || binding.value == nullptr ||
            binding.transform_node == nullptr || binding.alignment == nullptr) continue;
        ApplyNodeOriginAnimation(binding);
        auto& alignment = *binding.alignment;
        const auto& value = binding.value->getVec3();
        if (! (alignment.origin.array() == value.array()).all()) {
            alignment.origin = value;
            alignment.transform_dirty = true;
        }
        ApplyNodeTransform(*binding.transform_node, alignment,
                           binding.size != nullptr ? *binding.size : Eigen::Vector2f::Zero());
    }
    for (auto& [name, binding] : m_node_scale) {
        (void)name;
        if (binding.node == nullptr || binding.value == nullptr || binding.alignment == nullptr) continue;
        auto& alignment = *binding.alignment;
        const auto& value = binding.value->getVec3();
        if (! (alignment.scale.array() == value.array()).all()) {
            alignment.scale = value;
            alignment.transform_dirty = true;
        }
        if (alignment.alignment.empty()) {
            binding.node->SetScale(value);
        } else if (binding.transform_node != nullptr) {
            ApplyNodeTransform(*binding.transform_node, alignment,
                               binding.size != nullptr ? *binding.size : Eigen::Vector2f::Zero());
        }
    }
    for (auto& [name, binding] : m_node_rotation) {
        (void)name;
        if (binding.node == nullptr || binding.value == nullptr) continue;
        binding.node->SetRotation(binding.value->getVec3());
        // Turning an anchored layer moves its centre, so the translate written
        // above from the previous rotation is re-derived.
        if (binding.alignment != nullptr && ! binding.alignment->alignment.empty() &&
            binding.transform_node != nullptr) {
            ApplyNodeTransform(*binding.transform_node, *binding.alignment,
                               binding.size != nullptr ? *binding.size : Eigen::Vector2f::Zero());
        }
    }
    for (auto& binding : m_text_values) {
        if (binding.value != nullptr) SetNodeText(binding.name, binding.value->toString());
    }
    for (auto& [name, binding] : m_node_effect_final) {
        (void)name;
        if (binding.node == nullptr || binding.layer == nullptr) continue;
        SyncEffectFinalNode(*binding.node, *binding.layer);
    }
    for (auto& binding : m_material_constants) ApplyMaterialConstantBinding(binding);
    for (std::size_t index = 0; index < scene_script_count; ++index) {
        auto* script = m_scene_scripts[index].script.get();
        if (script != nullptr) script->Tick(*m_host_context);
    }
    ApplySceneZoomAnimation();
    // After every visibility and origin writer of this tick, scripts included,
    // so the shot shown is the one this tick left visible, at the origin this
    // tick gave it.
    for (auto& shot : m_camera_shots) shot.origin_pending = false;
    ApplyCameraShots();
    ApplyPerspectiveCameraShots(frame_time);
    for (auto& binding : m_material_alpha) {
        auto material = binding.material.lock();
        if (material == nullptr) continue;
        ApplyMaterialAlpha(*material, binding.animation->Value());
    }
    for (auto& binding : m_material_constants) ApplyMaterialConstantBinding(binding);
}

ScriptEngine& SceneRuntimeContext::scriptEngine() { return *m_script_engine; }

const ScriptHostContext& SceneRuntimeContext::hostContext() const { return *m_host_context; }

const ProjectProperties& SceneRuntimeContext::defaultProjectProperties() const {
    return m_default_project_properties;
}

const ProjectProperties& SceneRuntimeContext::projectProperties() const {
    return m_project_properties;
}

std::vector<std::string> SceneRuntimeContext::ApplyProjectPropertyOverride(
    const ProjectProperties& override_properties) {
    m_project_property_overrides = override_properties;
    return ApplyProjectProperties(
        MergeProjectProperties(m_default_project_properties, m_project_property_overrides));
}

void SceneRuntimeContext::NoteLoadOnlyProperty(std::string_view name) {
    if (name.empty()) return;
    std::string key(name);
    if (m_load_only_properties.contains(key)) return;
    const auto found = m_project_properties.find(key);
    std::optional<RuntimeScalarValue> read_with;
    if (found != m_project_properties.end()) read_with = found->second;
    m_load_only_properties.emplace(std::move(key), std::move(read_with));
}

std::vector<std::string> SceneRuntimeContext::LoadOnlyProperties() const {
    std::vector<std::string> names;
    names.reserve(m_load_only_properties.size());
    for (const auto& entry : m_load_only_properties) names.push_back(entry.first);
    return names;
}

ProjectPropertyPreview SceneRuntimeContext::PreviewProjectPropertyOverride(
    const ProjectProperties& override_properties) {
    m_project_property_overrides = override_properties;
    auto next_properties =
        MergeProjectProperties(m_default_project_properties, m_project_property_overrides);
    ProjectPropertyPreview preview;
    // The map is ordered, so the names come out sorted.
    for (const auto& [name, read_with] : m_load_only_properties) {
        const auto asked = next_properties.find(name);
        const bool asked_for_something_else =
            asked == next_properties.end()
                ? read_with.has_value()
                : ! read_with.has_value() || ProjectPropertyValueChanged(*read_with, asked->second);
        if (asked_for_something_else) preview.deferred.push_back(name);
        if (read_with.has_value()) {
            next_properties.insert_or_assign(name, *read_with);
        } else if (asked != next_properties.end()) {
            next_properties.erase(name);
        }
    }
    preview.changed = ApplyProjectProperties(std::move(next_properties));
    return preview;
}

std::vector<std::string> SceneRuntimeContext::ApplyProjectProperties(
    ProjectProperties next_properties) {
    ProjectProperties changed_properties;
    for (const auto& [name, value] : next_properties) {
        const auto previous = m_project_properties.find(name);
        if (previous == m_project_properties.end() ||
            ProjectPropertyValueChanged(previous->second, value)) {
            changed_properties.emplace(name, value);
        }
    }
    m_project_properties = std::move(next_properties);
    m_project_properties_changing = true;

    for (const auto& [name, value] : m_project_properties) {
        const auto it = m_property_values.find(name);
        if (it == m_property_values.end()) {
            m_property_values.emplace(name, MakePropertyValue(value));
            continue;
        }

        auto next_value = MakePropertyValue(value);
        it->second->update(*next_value);
    }

    m_project_properties_changing = false;
    // A script may create layers from its callback: no registry iterator can
    // survive one, and newly added programs receive their own initial event.
    const auto scripted_value_count = m_scripted_values.size();
    const auto scene_script_count = m_scene_scripts.size();
    for (std::size_t index = 0; index < scripted_value_count; ++index) {
        auto* value = m_scripted_values[index];
        if (value != nullptr) value->ApplyProjectProperties(m_project_properties, changed_properties);
    }
    for (std::size_t index = 0; index < scene_script_count; ++index) {
        auto* script = m_scene_scripts[index].script.get();
        if (script != nullptr) script->ApplyProjectProperties(m_project_properties, changed_properties);
    }

    std::vector<std::string> changed_names;
    changed_names.reserve(changed_properties.size());
    for (const auto& entry : changed_properties) changed_names.push_back(entry.first);
    std::sort(changed_names.begin(), changed_names.end());
    return changed_names;
}

std::vector<std::string> SceneRuntimeContext::ResetProjectPropertyOverride() {
    return ApplyProjectPropertyOverride({});
}

void SceneRuntimeContext::AttachScene(Scene* scene) { m_scene = scene; }

void SceneRuntimeContext::SetCursorWorldPosition(const Eigen::Vector3f& value) {
    m_host_context->cursor_world_position = value;
}

void SceneRuntimeContext::SetCursorViewport(const CursorViewport& viewport) {
    if (! viewport.origin.allFinite() || ! viewport.size.allFinite()) return;
    if (! viewport.content_origin.allFinite() || ! viewport.content_size.allFinite()) return;
    if (viewport.size.x() == 0.0f || viewport.size.y() == 0.0f) return;
    m_cursor_viewport = viewport;
}

/// Publishes the display's pixel resolution, which is what
/// `engine.screenResolution` means.
///
/// This used to be the cursor viewport's size, which is the region of the
/// scene's own world the window shows -- 2560x1080 scene units for a wallpaper
/// authored at that size, whatever display it is on. A script sizing itself
/// against the screen got the author's canvas back instead. The rasterization
/// size is not it either: internal quality may halve that, and a quality
/// setting must not move a layout.
void SceneRuntimeContext::SetScreenResolution(const Eigen::Vector2f& resolution) {
    if (! resolution.allFinite()) return;
    if (resolution.x() <= 0.0f || resolution.y() <= 0.0f) return;
    m_host_context->screen_resolution = resolution;
}

void SceneRuntimeContext::SetCursorInput(float x, float y) {
    x                                          = std::clamp(x, 0.0f, 1.0f);
    y                                          = std::clamp(y, 0.0f, 1.0f);
    m_host_context->cursor_normalized_position = Eigen::Vector2f(x, y);
    m_host_context->cursor_world_position =
        Eigen::Vector3f(m_cursor_viewport.origin.x() + x * m_cursor_viewport.size.x(),
                        m_cursor_viewport.origin.y() + (1.0f - y) * m_cursor_viewport.size.y(),
                        0.0f);
    // Published for the parts of the scene that are not scripts. A particle
    // system's mouse-linked control point needs the same scene coordinate, and
    // deriving it a second time from the canvas is how it ended up ignoring
    // the crop.
    if (m_scene != nullptr) {
        m_scene->pointerScenePosition = std::array {
            m_host_context->cursor_world_position.x(),
            m_host_context->cursor_world_position.y(),
        };
    }
}

void SceneRuntimeContext::SetCursorEnter(bool entered) {
    m_host_context->cursor_in_window = entered;
}

void SceneRuntimeContext::SetCursorButton(int button, bool pressed) {
    if (button < 0 || button > 31) return;
    const uint32_t mask = 1u << static_cast<uint32_t>(button);
    if (pressed) {
        if ((m_host_context->mouse_buttons_down & mask) == 0) {
            m_host_context->mouse_buttons_down |= mask;
            m_host_context->mouse_buttons_pressed |= mask;
        }
        return;
    }
    if ((m_host_context->mouse_buttons_down & mask) != 0) {
        m_host_context->mouse_buttons_down &= ~mask;
        m_host_context->mouse_buttons_released |= mask;
    }
}

void SceneRuntimeContext::SetCursorButtons(uint32_t down, uint32_t pressed, uint32_t released) {
    m_host_context->mouse_buttons_down     = down;
    m_host_context->mouse_buttons_pressed  = pressed;
    m_host_context->mouse_buttons_released = released;
}

void SceneRuntimeContext::BeginFrame() {
    m_host_context->mouse_buttons_pressed  = 0;
    m_host_context->mouse_buttons_released = 0;
}

void SceneRuntimeContext::StartTextWorker() {
    std::lock_guard lock { m_text_worker_mutex };
    if (m_text_worker.joinable()) return;
    m_stop_text_worker = false;
    m_text_worker      = std::thread([this] {
        TextWorkerLoop();
    });
}

void SceneRuntimeContext::StopTextWorker() {
    {
        std::lock_guard lock { m_text_worker_mutex };
        m_stop_text_worker = true;
    }
    m_text_worker_cv.notify_all();
    if (m_text_worker.joinable()) m_text_worker.join();
}

void SceneRuntimeContext::EnqueueTextLayerPreparation(std::string name, const TextLayer& layer) {
    if (! layer.layoutPending()) return;

    const auto& state = layer.state();
    if (! state.cache_dirty) return;
    if (state.cache_revision == 0) return;

    {
        std::lock_guard lock { m_text_worker_mutex };
        if (m_queued_text_revisions[name] == state.cache_revision) return;

        auto job = std::find_if(m_pending_text_jobs.begin(), m_pending_text_jobs.end(),
                                [&name](const RuntimePendingTextLayerJob& pending) {
                                    return pending.name == name;
                                });
        if (job == m_pending_text_jobs.end()) {
            m_pending_text_jobs.push_back(RuntimePendingTextLayerJob { .name = name });
            job = std::prev(m_pending_text_jobs.end());
        }
        // Updating a queued caption keeps its place. A busy readout cannot
        // indefinitely outrank an older clock/date update.
        job->revision = state.cache_revision;
        job->state = state;
        job->state.raster_size = layer.rasterSize();
        m_queued_text_revisions[name] = state.cache_revision;
    }
    m_text_worker_cv.notify_one();
}

bool SceneRuntimeContext::TextLayoutInFlight() const {
    // Asked once per frame by the demand analysis, so a scene with no text at
    // all answers without touching the worker's lock.
    if (m_text_layers.empty()) return false;
    {
        std::lock_guard lock { m_text_worker_mutex };
        if (! m_pending_text_jobs.empty() || ! m_prepared_text_layers.empty()) return true;
    }
    // A layer whose layout is pending but whose job has not been queued yet --
    // the text changed during this very tick, and `PumpTextLayerCache` runs
    // after it. Reported as in flight so the frame that made the change does
    // not also conclude the scene is still.
    //
    // Only layers the pump will actually act on. A hidden layer's pending
    // layout is deferred, not in flight: `PumpTextLayerCache` skips it, so
    // counting it would leave the scene drawing forever for work that is not
    // being done. Becoming visible is an event, and the layout happens then.
    return std::any_of(m_text_layers.begin(), m_text_layers.end(), [this](const auto& entry) {
        return entry.second.layoutPending() && TextLayerIsBeingPrepared(entry.first);
    });
}

bool SceneRuntimeContext::TextLayerIsBeingPrepared(const std::string& name) const {
    const auto node = m_nodes.find(name);
    if (node == m_nodes.end() || node->second == nullptr) return true;
    return node->second->EffectiveVisible() || node->second->MustProduce();
}

void SceneRuntimeContext::SetContentWakeHandler(std::function<void()> handler) {
    std::lock_guard lock { m_text_worker_mutex };
    m_content_wake_handler = std::move(handler);
}

void SceneRuntimeContext::TextWorkerLoop() {
    while (true) {
        RuntimePendingTextLayerJob job;
        {
            std::unique_lock lock { m_text_worker_mutex };
            m_text_worker_cv.wait(lock, [this] {
                return m_stop_text_worker || ! m_pending_text_jobs.empty();
            });
            if (m_stop_text_worker) return;
            job = std::move(m_pending_text_jobs.front());
            m_pending_text_jobs.pop_front();
        }

        auto prepared =
            PrepareTextLayerImage(std::move(job.name), job.revision, std::move(job.state));

        std::function<void()> wake;
        {
            std::lock_guard lock { m_text_worker_mutex };
            if (m_stop_text_worker) return;
            m_prepared_text_layers.erase(
                std::remove_if(m_prepared_text_layers.begin(),
                               m_prepared_text_layers.end(),
                               [&prepared](const RuntimePreparedTextLayerImage& existing) {
                                   return existing.name == prepared.name;
                               }),
                m_prepared_text_layers.end());
            m_prepared_text_layers.push_back(std::move(prepared));
            wake = m_content_wake_handler;
        }
        // Outside the lock: the handler asks the frame clock for a frame, and
        // that clock's own mutex must never be taken under this one. Copied
        // rather than called by reference so a detach racing with this call
        // cannot destroy the function while it runs.
        //
        // Without this a scene that went quiet while its text was being laid
        // out would never draw the result: the image is ready, and nothing
        // would ask for the frame that applies it.
        if (wake) wake();
    }
}

void SceneRuntimeContext::CollectPreparedTextLayers() {
    std::vector<RuntimePreparedTextLayerImage> prepared;
    {
        std::lock_guard lock { m_text_worker_mutex };
        prepared.swap(m_prepared_text_layers);
    }

    for (const auto& image : prepared) {
        ApplyPreparedTextLayer(image);
    }
}

bool SceneRuntimeContext::ApplyPreparedTextLayer(const RuntimePreparedTextLayerImage& prepared) {
    const auto iterator = m_text_layers.find(prepared.name);
    if (iterator == m_text_layers.end()) return false;

    auto& layer = iterator->second;
    if (layer.state().texture_cache_key != prepared.state.texture_cache_key) return false;
    const bool raster_size_changed =
        ! SizeNearlyEqual(layer.rasterSize(), prepared.raster_size, 1.0e-3f);
    const bool layout_size_changed =
        ! SizeNearlyEqual(layer.size(), prepared.layout_size, 1.0e-3f);
    // A continuously changing label can always be ahead of its worker. Publish
    // completed revisions monotonically, keeping the newer request pending.
    if (! layer.ApplyPreparedLayout(prepared.revision, prepared.layout_size,
                                    prepared.raster_size)) return false;

    if (raster_size_changed) {
        const auto node_iterator = m_nodes.find(prepared.name);
        if (node_iterator != m_nodes.end() && node_iterator->second != nullptr &&
            node_iterator->second->Mesh() != nullptr) {
            auto* mesh = node_iterator->second->Mesh();
            if (! SizeNearlyEqual(CardMeshSize(*mesh), prepared.raster_size, 1.0f)) {
                ResizeCardMesh(
                    *mesh,
                    TextLayerRenderBoundsForRasterSize(prepared.state, prepared.raster_size));
                if (! mesh->Dynamic()) m_scene_graph_mutated = true;
            }
        }
    }

    if (raster_size_changed || layout_size_changed) {
        // The card the layer shows: the text's own, or the chain's final card.
        TextLayerRenderFrame card = prepared.render_frame;
        if (const auto effect_iterator = m_node_effect_final.find(prepared.name);
            effect_iterator != m_node_effect_final.end() &&
            effect_iterator->second.node != nullptr &&
            effect_iterator->second.node->Mesh() != nullptr &&
            effect_iterator->second.layer != nullptr) {
            auto& target_frame = effect_iterator->second.target_frame;
            const auto& bounds = prepared.render_frame.bounds;
            if (bounds.left < target_frame.bounds.left ||
                bounds.right > target_frame.bounds.right ||
                bounds.bottom < target_frame.bounds.bottom ||
                bounds.top > target_frame.bounds.top) {
                Eigen::Vector2f capacity = target_frame.size;
                for (int axis = 0; axis < 2; ++axis) {
                    while (capacity[axis] < prepared.render_frame.size[axis] &&
                           capacity[axis] < 4096.0f)
                        capacity[axis] = std::min(4096.0f, capacity[axis] * 2.0f);
                }
                const bool grew = ! SizeNearlyEqual(capacity, target_frame.size, 1.0f);
                target_frame = TextLayerRenderFrameForCapacity(
                    prepared.state, prepared.raster_size, capacity);
                auto& binding = effect_iterator->second;
                auto camera = m_scene->cameras.at(binding.node->Camera());
                camera->SetWidth(capacity.x());
                camera->SetHeight(capacity.y());
                camera->GetAttachedNode()->SetTranslate(
                    Eigen::Vector3f(target_frame.center.x(), target_frame.center.y(), 0.0f));
                camera->Update();
                if (grew) {
                    const auto& first = binding.layer->FirstTarget();
                    for (auto& [key, target] : m_scene->renderTargets) {
                        if (key != first && (! target.bind.enable || target.bind.name != first))
                            continue;
                        const double scale = key == first ? 1.0 : target.bind.scale;
                        target.width = target.authored_width =
                            std::max(4, static_cast<int32_t>(std::lround(capacity.x() * scale)));
                        target.height = target.authored_height =
                            std::max(4, static_cast<int32_t>(std::lround(capacity.y() * scale)));
                    }
                    m_scene_graph_mutated = true;
                }
            }
            const auto  final_frame =
                TextLayerRenderFrameClampedToTarget(prepared.render_frame, target_frame);
            const auto texture_bounds = TextLayerTextureBoundsForRenderTarget(
                final_frame, target_frame.size, target_frame.center);
            ResizeCardMesh(
                effect_iterator->second.layer->FinalMesh(), final_frame.bounds, texture_bounds);
            if (auto* resolved =
                    effect_iterator->second.layer->ResolvedFinalRenderNode();
                resolved != nullptr && resolved->Mesh() != nullptr) {
                ResizeCardMesh(*resolved->Mesh(), final_frame.bounds, texture_bounds);
            }
            card = final_frame;
        }
        if (const auto node_iterator = m_nodes.find(prepared.name);
            node_iterator != m_nodes.end() && node_iterator->second != nullptr) {
            FitTextLayerComposite(*node_iterator->second, card);
        }
    }

    RegisterNodeSize(prepared.name, prepared.layout_size);
    ApplyNodeTransform(prepared.name);

    if (m_scene != nullptr) {
        SetRuntimeTextTexture(
            *m_scene, prepared.state, prepared.width, prepared.height, prepared.rgba);
    }
    if (! layer.layoutPending()) layer.ClearDirty();
    return true;
}

void SceneRuntimeContext::FitTextLayerComposite(SceneNode& node,
                                                const TextLayerRenderFrame& card) {
    if (m_scene == nullptr || card.size.x() <= 0.0f || card.size.y() <= 0.0f) return;
    const auto camera = m_scene->cameras.find(LayerCompositeCameraKey(node.ID()));
    if (camera == m_scene->cameras.end() || camera->second == nullptr ||
        camera->second->GetAttachedNode() == nullptr)
        return;
    camera->second->SetWidth(card.size.x());
    camera->second->SetHeight(card.size.y());
    camera->second->GetAttachedNode()->SetTranslate(
        Eigen::Vector3f(card.center.x(), card.center.y(), 0.0f));
    camera->second->Update();
    // One texel per unit of the card, as at parse time: a consumer may place
    // the image by its size (`g_Texture1Resolution`), so stretching a new card
    // over the old target would show the text at another scale. Only a card
    // whose size in texels changed costs a new graph.
    const auto found = m_scene->renderTargets.find(LayerCompositeTargetKey(node.ID()));
    if (found == m_scene->renderTargets.end()) return;
    auto&      target = found->second;
    const auto width  = std::max(4, static_cast<int32_t>(std::lround(card.size.x())));
    const auto height = std::max(4, static_cast<int32_t>(std::lround(card.size.y())));
    const auto current_width  = target.authored_width > 0 ? target.authored_width : target.width;
    const auto current_height = target.authored_height > 0 ? target.authored_height : target.height;
    if (current_width == width && current_height == height) return;
    target.width = target.authored_width = width;
    target.height = target.authored_height = height;
    m_scene_graph_mutated = true;
}

DynamicValue* SceneRuntimeContext::FindPropertyValue(std::string_view name) const {
    const auto iterator = m_property_values.find(std::string(name));
    if (iterator == m_property_values.end()) return nullptr;
    return iterator->second.get();
}

void SceneRuntimeContext::RegisterScriptedValue(ScriptedDynamicValue* value) {
    m_scripted_values.push_back(value);
    constexpr auto hover_mask = static_cast<uint8_t>(ScriptCursorEvent::Enter) |
                                static_cast<uint8_t>(ScriptCursorEvent::Leave) |
                                static_cast<uint8_t>(ScriptCursorEvent::Move);
    if (value != nullptr && (value->CursorHandlerMask() & hover_mask) != 0) {
        m_scripted_value_cursor_inside[value] = false;
    }
}

void SceneRuntimeContext::RegisterNode(std::string name, SceneNode* node) {
    if (node == nullptr || name.empty()) return;
    std::string key     = std::move(name);
    auto&       slot    = m_nodes[key];
    const bool  rebound = slot != node;
    slot                = node;
    auto& alignment     = m_node_alignment[key];
    if (rebound) alignment = NodeAlignmentBinding {};
    // Every Register* helper re-registers the node, and a node carrying a
    // registered anchor already has the offset in its translate. Recapturing it
    // as the anchor origin would double-count on the next ApplyNodeTransform.
    if (alignment.alignment.empty()) {
        alignment.origin = node->Translate();
        alignment.scale  = node->Scale();
        alignment.transform_dirty = true;
    }
    RefreshNodeTransformBindings(key);
}

void SceneRuntimeContext::RegisterLayerAlias(std::string authored_name, std::string runtime_name) {
    // The parser registers these in authored order. Duplicate names still
    // have independent binding keys; name lookup selects the first layer.
    m_layer_aliases.try_emplace(std::move(authored_name), std::move(runtime_name));
}

std::string SceneRuntimeContext::ResolveLayerName(std::string_view name) const {
    const std::string key(name);
    if (m_nodes.contains(key)) return key;
    const auto alias = m_layer_aliases.find(key);
    return alias != m_layer_aliases.end() ? alias->second : key;
}

void SceneRuntimeContext::UnregisterNode(std::string_view name) {
    const std::string key(name);
    m_node_visibility.erase(key);
    m_node_translate.erase(key);
    m_node_scale.erase(key);
    m_node_rotation.erase(key);
    m_node_effect_final.erase(key);
    m_node_alpha.erase(key);
    m_nodes.erase(key);
    m_node_size.erase(key);
    m_node_hit_masks.erase(key);
    m_puppet_layers.erase(key);
    m_text_layers.erase(key);
    m_text_values.erase(std::remove_if(m_text_values.begin(),
                                       m_text_values.end(),
                                       [&key](const auto& binding) {
                                           return binding.name == key;
                                       }),
                        m_text_values.end());
    m_node_alignment.erase(key);
    m_node_template_paths.erase(key);
    m_node_video_textures.erase(key);
    m_sound_layers.erase(key);
}

void SceneRuntimeContext::RollbackNodeRegistration(
    std::string_view name,
    SceneNode* node,
    std::shared_ptr<const NodeRegistrationSnapshot> previous) {
    if (node == nullptr) return;
    const std::string key(name);
    const auto        node_iterator = m_nodes.find(key);
    if (node_iterator == m_nodes.end() || node_iterator->second != node) return;

    UnregisterNode(key);
    if (previous == nullptr) return;

    m_material_constants.resize(previous->material_constants_size);
    m_material_alpha.resize(previous->material_alpha_size);
    m_scalar_animations.resize(previous->scalar_animations_size);
    for (std::size_t index = previous->dynamic_value_listeners_size;
         index < m_dynamic_value_listeners.size(); ++index) {
        auto& binding = m_dynamic_value_listeners[index];
        if (binding.deregister) binding.deregister();
    }
    m_dynamic_value_listeners.resize(previous->dynamic_value_listeners_size);

    for (std::size_t index = previous->scripted_values_size; index < m_scripted_values.size();
         ++index) {
        m_scripted_value_cursor_inside.erase(m_scripted_values[index]);
        // A press held across this teardown has nothing left to release onto,
        // and the pointer is about to dangle.
        for (auto& [mask, held] : m_scripted_value_cursor_held) {
            std::erase(held, m_scripted_values[index]);
        }
    }
    for (auto& [mask, held] : m_scene_script_cursor_held) {
        std::erase_if(held, [&](std::size_t index) {
            return index >= m_scene_scripts.size();
        });
    }
    m_scripted_values.resize(previous->scripted_values_size);
    m_owned_values.resize(previous->owned_values_size);

    if (previous->has_node) m_nodes[key] = previous->node;
    if (previous->visibility.has_value()) m_node_visibility[key] = *previous->visibility;
    if (previous->translate.has_value()) m_node_translate[key] = *previous->translate;
    if (previous->scale.has_value()) m_node_scale[key] = *previous->scale;
    if (previous->rotation.has_value()) m_node_rotation[key] = *previous->rotation;
    if (previous->effect_final.has_value()) m_node_effect_final[key] = *previous->effect_final;
    if (previous->size.has_value()) m_node_size[key] = *previous->size;
    if (previous->hit_mask.has_value()) m_node_hit_masks[key] = *previous->hit_mask;
    if (previous->puppet_layer.has_value()) m_puppet_layers[key] = *previous->puppet_layer;
    if (previous->text_layer.has_value()) m_text_layers.emplace(key, *previous->text_layer);
    m_text_values.insert(m_text_values.end(),
                         previous->text_values.begin(),
                         previous->text_values.end());
    if (previous->alignment.has_value()) {
        auto& alignment = m_node_alignment[key];
        alignment = *previous->alignment;
        alignment.transform_dirty = true;
    }
    if (previous->template_path.has_value()) m_node_template_paths[key] = *previous->template_path;
    if (! previous->video_textures.empty()) {
        m_node_video_textures[key] = previous->video_textures;
    }
    if (previous->has_sound_layer) m_sound_layers[key] = previous->sound_layer;
    RefreshNodeTransformBindings(key);
}

std::shared_ptr<SceneRuntimeContext::NodeRegistrationSnapshot>
SceneRuntimeContext::CaptureNodeRegistration(std::string_view name) const {
    const std::string key(name);
    auto              snapshot = std::make_shared<NodeRegistrationSnapshot>();

    if (const auto iterator = m_nodes.find(key); iterator != m_nodes.end()) {
        snapshot->has_node = true;
        snapshot->node     = iterator->second;
    }
    if (const auto iterator = m_node_visibility.find(key); iterator != m_node_visibility.end()) {
        snapshot->visibility = iterator->second;
    }
    if (const auto iterator = m_node_translate.find(key); iterator != m_node_translate.end()) {
        snapshot->translate = iterator->second;
    }
    if (const auto iterator = m_node_scale.find(key); iterator != m_node_scale.end()) {
        snapshot->scale = iterator->second;
    }
    if (const auto iterator = m_node_rotation.find(key); iterator != m_node_rotation.end()) {
        snapshot->rotation = iterator->second;
    }
    if (const auto iterator = m_node_effect_final.find(key); iterator != m_node_effect_final.end()) {
        snapshot->effect_final = iterator->second;
    }
    if (const auto iterator = m_node_size.find(key); iterator != m_node_size.end()) {
        snapshot->size = iterator->second;
    }
    if (const auto iterator = m_node_hit_masks.find(key); iterator != m_node_hit_masks.end()) {
        snapshot->hit_mask = iterator->second;
    }
    if (const auto iterator = m_puppet_layers.find(key); iterator != m_puppet_layers.end()) {
        snapshot->puppet_layer = iterator->second;
    }
    if (const auto iterator = m_text_layers.find(key); iterator != m_text_layers.end()) {
        snapshot->text_layer = iterator->second;
    }
    for (const auto& binding : m_text_values) {
        if (binding.name == key) snapshot->text_values.push_back(binding);
    }
    if (const auto iterator = m_node_alignment.find(key); iterator != m_node_alignment.end()) {
        snapshot->alignment = iterator->second;
    }
    if (const auto iterator = m_node_template_paths.find(key);
        iterator != m_node_template_paths.end()) {
        snapshot->template_path = iterator->second;
    }
    if (const auto iterator = m_node_video_textures.find(key);
        iterator != m_node_video_textures.end()) {
        snapshot->video_textures = iterator->second;
    }
    if (const auto iterator = m_sound_layers.find(key); iterator != m_sound_layers.end()) {
        snapshot->sound_layer     = iterator->second;
        snapshot->has_sound_layer = true;
    }
    snapshot->owned_values_size    = m_owned_values.size();
    snapshot->scripted_values_size = m_scripted_values.size();
    snapshot->material_constants_size = m_material_constants.size();
    snapshot->dynamic_value_listeners_size = m_dynamic_value_listeners.size();
    snapshot->material_alpha_size = m_material_alpha.size();
    snapshot->scalar_animations_size = m_scalar_animations.size();

    return snapshot;
}

void SceneRuntimeContext::RegisterNodeSize(std::string name, Eigen::Vector2f value) {
    if (name.empty()) return;
    const auto previous = m_node_size.find(name);
    if (previous != m_node_size.end() && (previous->second.array() == value.array()).all()) return;
    m_node_size[name] = value;
    if (const auto alignment = m_node_alignment.find(name); alignment != m_node_alignment.end()) {
        alignment->second.transform_dirty = true;
    }
    RefreshNodeTransformBindings(name);
}

void SceneRuntimeContext::RegisterNodeHitMask(std::string name, NodeHitMask mask) {
    if (name.empty() || mask.width == 0 || mask.height == 0 ||
        mask.alpha.size() != static_cast<std::size_t>(mask.width) * mask.height) {
        return;
    }
    m_node_hit_masks[std::move(name)] = std::move(mask);
}

void SceneRuntimeContext::RegisterPuppetLayer(std::string name, WPPuppetLayer layer) {
    if (name.empty() || ! layer.hasPuppet()) return;
    m_puppet_layers[std::move(name)] = std::move(layer);
}

WPPuppetLayer* SceneRuntimeContext::FindPuppetLayer(std::string_view name) {
    const auto iterator = m_puppet_layers.find(std::string(name));
    return iterator == m_puppet_layers.end() ? nullptr : &iterator->second;
}

double SceneRuntimeContext::PuppetAnimationControl(std::string_view layer_name,
                                                   std::string_view animation_layer,
                                                   std::string_view operation, double value,
                                                   bool has_value) {
    auto* puppet = FindPuppetLayer(layer_name);
    if (puppet == nullptr) return 0.0;
    const i32 index = puppet->findLayer(animation_layer);
    if (index < 0) return 0.0;
    if (operation == "play") return puppet->play(index) ? 1.0 : 0.0;
    if (operation == "pause") return puppet->pause(index) ? 1.0 : 0.0;
    if (operation == "stop") return puppet->stop(index) ? 1.0 : 0.0;
    if (operation == "isPlaying") return puppet->isPlaying(index) ? 1.0 : 0.0;
    if (operation == "exists") return 1.0;
    if (operation == "frame") return puppet->frame(index);
    if (operation == "frameCount") return puppet->frameCount(index);
    if (operation == "fps") return puppet->fps(index);
    if (operation == "rate") return puppet->rate(index);
    if (operation == "blend") return puppet->blend(index);
    if (operation == "visible") return puppet->visible(index) ? 1.0 : 0.0;
    if (! has_value) return 0.0;
    if (operation == "setFrame") return puppet->setFrame(index, value) ? 1.0 : 0.0;
    if (operation == "setRate") return puppet->setRate(index, value) ? 1.0 : 0.0;
    if (operation == "setBlend") return puppet->setBlend(index, value) ? 1.0 : 0.0;
    if (operation == "setVisible") return puppet->setVisible(index, value != 0.0) ? 1.0 : 0.0;
    return 0.0;
}

void SceneRuntimeContext::RegisterLayerTemplate(std::string                template_path,
                                                std::shared_ptr<SceneNode> node,
                                                Eigen::Vector2f            size) {
    if (node == nullptr) return;

    const std::string canonical_path = NormalizeTemplatePath(template_path);
    if (canonical_path.empty()) return;

    LayerTemplateBinding binding {
        .canonical_path = canonical_path,
        .node           = std::move(node),
        .size           = size,
    };
    m_layer_templates[canonical_path] = binding;

    if (const auto alias = MakeWorkshopLocalAlias(canonical_path); ! alias.empty()) {
        m_layer_templates[alias] = binding;
    }

    if (! binding.node->Name().empty()) {
        m_node_template_paths[binding.node->Name()] = canonical_path;
    }
}

void SceneRuntimeContext::SetLayerTemplateLoader(std::function<bool(std::string_view)> loader) {
    m_layer_template_loader = std::move(loader);
    m_failed_layer_templates.clear();
}

void SceneRuntimeContext::RegisterNodeVisibility(std::string name, SceneNode* node,
                                                 std::unique_ptr<DynamicValue> value) {
    if (node == nullptr || value == nullptr) return;

    RegisterNode(name, node);
    node->SetVisible(value->getBool());
    auto* raw = value.get();
    m_owned_values.push_back(std::move(value));
    m_node_visibility[std::move(name)] = NodeVisibilityBinding {
        .node  = node,
        .value = raw,
    };
}

void SceneRuntimeContext::ApplyNodeOriginAnimation(NodeVec3Binding& binding) {
    if (binding.animation == nullptr || binding.animation->playback == nullptr) return;
    const auto& animation = *binding.animation;
    const double frame = animation.playback->frame;
    if (frame == binding.sampled_animation_frame) return;
    Eigen::Vector3f origin;
    for (std::size_t i = 0; i < animation.components.size(); ++i) {
        const auto& curve = animation.components[i];
        origin[i] = animation.offset[i] + curve.Evaluate(curve.fps > 0.0 ? frame / curve.fps : 0.0);
    }
    binding.value->update(origin);
    binding.sampled_animation_frame = frame;
}

void SceneRuntimeContext::RegisterNodeTranslate(std::string name, SceneNode* node,
                                                std::unique_ptr<DynamicValue> value,
                                                std::shared_ptr<const NodeOriginAnimation> animation) {
    if (node == nullptr || value == nullptr) return;

    RegisterNode(name, node);
    auto* raw = value.get();
    m_owned_values.push_back(std::move(value));
    auto& binding = m_node_translate[name];
    binding = NodeVec3Binding {
        .node  = node,
        .value = raw,
        .animation = std::move(animation),
    };
    ApplyNodeOriginAnimation(binding);
    SetNodeTranslate(name, raw->getVec3());
    RefreshNodeTransformBindings(name);
}

void SceneRuntimeContext::RegisterNodeScale(std::string name, SceneNode* node,
                                            std::unique_ptr<DynamicValue> value) {
    if (node == nullptr || value == nullptr) return;

    RegisterNode(name, node);
    SetNodeScale(name, value->getVec3());
    auto* raw = value.get();
    m_owned_values.push_back(std::move(value));
    m_node_scale[name] = NodeVec3Binding {
        .node  = node,
        .value = raw,
    };
    RefreshNodeTransformBindings(name);
}

void SceneRuntimeContext::RegisterNodeRotation(std::string name, SceneNode* node,
                                               std::unique_ptr<DynamicValue> value) {
    if (node == nullptr || value == nullptr) return;

    RegisterNode(name, node);
    node->SetRotation(value->getVec3());
    auto* raw = value.get();
    m_owned_values.push_back(std::move(value));
    m_node_rotation[name] = NodeVec3Binding {
        .node  = node,
        .value = raw,
    };
    RefreshNodeTransformBindings(name);
    ApplyAnchoredNodeTransform(name);
}

void SceneRuntimeContext::RegisterTextLayer(std::string name, TextLayerState state) {
    if (name.empty()) return;
    if (state.layer_key.empty()) state.layer_key = name;
    auto layer        = TextLayer(std::move(state));
    RegisterNodeSize(name, layer.size());
    m_text_layers.insert_or_assign(std::move(name), std::move(layer));
}

void SceneRuntimeContext::RegisterTextValue(std::string name,
                                            std::unique_ptr<DynamicValue> value,
                                            bool apply_current_value) {
    if (name.empty() || value == nullptr) return;
    if (apply_current_value) SetNodeText(name, value->toString());
    auto* raw = value.get();
    m_owned_values.push_back(std::move(value));
    m_text_values.push_back(TextValueBinding {
        .name  = std::move(name),
        .value = raw,
    });
}

void SceneRuntimeContext::RegisterMaterialConstant(
    std::shared_ptr<SceneMaterial> material, std::string name,
    std::unique_ptr<DynamicValue> value,
    std::shared_ptr<const MaterialConstantAnimation> animation) {
    if (material == nullptr || name.empty() || value == nullptr) return;

    auto* raw = value.get();
    m_owned_values.push_back(std::move(value));
    MaterialConstantBinding binding {
        .material = material,
        .name = std::move(name),
        .value = raw,
        .animation = std::move(animation),
    };
    // A shared timeline may already be running when a clone registers, so the
    // binding samples its current frame instead of resetting anyone's clock.
    ApplyMaterialConstantBinding(binding);
    m_material_constants.push_back(std::move(binding));
}

void SceneRuntimeContext::RegisterSceneZoomAnimation(
    std::shared_ptr<ScalarAnimationPlayback> animation) {
    m_scene_zoom_animation = std::move(animation);
    ApplySceneZoomAnimation();
}

void SceneRuntimeContext::ApplySceneZoomAnimation() {
    if (m_scene == nullptr || m_scene_zoom_animation == nullptr) return;
    double zoom = m_scene_zoom_animation->Value();
    if (!std::isfinite(zoom) || zoom <= 0.0) zoom = 1.0;
    const auto dimension = [zoom](int32_t value) {
        return std::clamp(static_cast<double>(value) / zoom, 1.0,
                          static_cast<double>(std::numeric_limits<int32_t>::max()));
    };
    auto& camera = *m_scene->cameras.at("global");
    camera.SetWidth(dimension(m_scene->ortho[0]));
    camera.SetHeight(dimension(m_scene->ortho[1]));
    camera.Update();
    auto& perspective = *m_scene->cameras.at("global_perspective");
    perspective.SetAspect(camera.Aspect());
    if (! perspective.FovLocked()) {
        perspective.SetFov(algorism::CalculatePersperctiveFov(1000.0, camera.VisibleHeight()));
    }
    perspective.Update();
    m_scene->UpdateLinkedCamera("global");
}

void SceneRuntimeContext::RegisterCameraShot(SceneNode* node, std::unique_ptr<DynamicValue> zoom,
                                             CameraShotTimeline timeline, bool origin_bound) {
    if (node == nullptr || zoom == nullptr) return;
    auto* raw = zoom.get();
    m_owned_values.push_back(std::move(zoom));
    m_camera_shots.push_back(CameraShotBinding {
        .node           = node,
        .zoom           = raw,
        .timeline       = std::move(timeline),
        .origin_pending = origin_bound,
    });
    ApplyCameraShots();
}

void SceneRuntimeContext::ApplyCameraShots() {
    if (m_scene == nullptr || m_camera_shots.empty()) return;

    double          zoom   = 1.0;
    Eigen::Vector2f offset = Eigen::Vector2f::Zero();
    for (auto& shot : m_camera_shots) {
        const auto& timeline = shot.timeline;
        const auto  sample   = [&timeline](const ScalarAnimation& curve) {
            const double frame = timeline.clock->frame;
            return curve.Evaluate(curve.fps > 0.0 ? frame / curve.fps : 0.0);
        };
        // The timeline moves the layer whether or not it is the shot shown, so
        // a shot revealed later picks up where its playhead stands, and a
        // script reading the layer's origin sees where the view is going.
        if (timeline.clock != nullptr &&
            std::any_of(timeline.origin.begin(), timeline.origin.end(),
                        [](const auto& curve) { return curve.has_value(); })) {
            Eigen::Vector3f origin = timeline.origin_base;
            for (std::size_t index = 0; index < timeline.origin.size(); ++index) {
                const auto& curve = timeline.origin[index];
                if (! curve.has_value()) continue;
                origin[index] = (timeline.origin_relative ? timeline.origin_base[index] : 0.0f) +
                                sample(*curve);
            }
            shot.node->SetTranslate(origin);
        }
        if (! shot.node->EffectiveVisible()) continue;
        zoom = timeline.clock != nullptr && timeline.zoom.has_value() ? sample(*timeline.zoom)
                                                                      : shot.zoom->getFloat();
        offset = shot.origin_pending ? Eigen::Vector2f(Eigen::Vector2f::Zero())
                                     : Eigen::Vector2f(shot.node->Translate().head<2>());
    }

    if (m_framed_camera_shot.has_value() && m_framed_camera_shot->first == zoom &&
        m_framed_camera_shot->second == offset) {
        return;
    }
    m_framed_camera_shot = std::make_pair(zoom, offset);
    m_scene->FrameCanvas(zoom, offset);
}

void SceneRuntimeContext::RegisterPerspectiveCameraShot(
    std::shared_ptr<SceneNode> node, SceneCamera* camera, double fov, CameraPathPlayback path) {
    if (!node || !camera || !m_scene) return;
    if (m_perspective_camera_groups.empty()) m_fallback_active_camera = m_scene->activeCamera;
    auto group = std::find_if(m_perspective_camera_groups.begin(), m_perspective_camera_groups.end(),
                             [camera](const auto& value) { return value.camera == camera; });
    if (group == m_perspective_camera_groups.end()) {
        m_perspective_camera_groups.push_back(
            { camera, camera->GetAttachedNode(), camera->Fov(), {} });
        group = std::prev(m_perspective_camera_groups.end());
    }
    group->shots.push_back({ std::move(node), fov, std::move(path), ++m_perspective_shot_count });
    ApplyPerspectiveCameraShots(0.0);
}

void SceneRuntimeContext::ApplyPerspectiveCameraShots(double seconds) {
    if (!m_scene || m_perspective_camera_groups.empty()) return;
    auto* active = m_fallback_active_camera;
    std::size_t last_order = 0;
    for (auto& group : m_perspective_camera_groups) {
        PerspectiveCameraShot* selected = nullptr;
        for (auto& shot : group.shots) {
            if (shot.node->EffectiveVisible()) selected = &shot;
        }
        const auto& node = selected ? selected->node : group.fallback_node;
        if (node && group.camera->GetAttachedNode() != node) group.camera->AttatchNode(node);
        group.camera->SetFov(selected ? selected->fov : group.fallback_fov);
        if (!selected) continue;
        selected->path.Advance(seconds);
        selected->path.Apply(*selected->node, *group.camera);
        if (selected->order > last_order) {
            last_order = selected->order;
            active = group.camera;
        }
    }
    m_scene->activeCamera = active;
}

void SceneRuntimeContext::RegisterSceneClearColor(std::unique_ptr<DynamicValue> value) {
    if (m_scene == nullptr || value == nullptr) return;

    RegisterDynamicValueListener(std::move(value), [this](const DynamicValue& color) {
        if (m_scene == nullptr) return;
        const auto vec = color.getVec3();
        m_scene->clearColor = { vec.x(), vec.y(), vec.z() };
    });
}

void SceneRuntimeContext::RegisterDynamicValueListener(
    std::unique_ptr<DynamicValue> value,
    std::function<void(const DynamicValue&)> callback) {
    if (value == nullptr || ! callback) return;

    callback(*value);
    auto* raw        = value.get();
    auto  deregister = raw->listen(std::move(callback));
    m_owned_values.push_back(std::move(value));
    m_dynamic_value_listeners.push_back(DynamicValueListenerBinding {
        .value      = raw,
        .deregister = std::move(deregister),
    });
}

void SceneRuntimeContext::RegisterNodeEffectFinal(std::string name,
                                                  SceneNode* node,
                                                  SceneImageEffectLayer* layer,
                                                  TextLayerRenderFrame target_frame) {
    if (node == nullptr || layer == nullptr) return;
    if (const auto iterator = m_nodes.find(name);
        iterator == m_nodes.end() || iterator->second != node) {
        RegisterNode(name, node);
    }
    m_node_effect_final[std::move(name)] = NodeEffectFinalBinding {
        .node         = node,
        .layer        = layer,
        .target_frame = target_frame,
    };
}

void SceneRuntimeContext::RegisterMaterialAlphaAnimation(
    std::shared_ptr<SceneMaterial> material, std::shared_ptr<ScalarAnimationPlayback> animation) {
    if (material == nullptr || animation == nullptr) return;
    ApplyMaterialAlpha(*material, animation->Value());
    m_material_alpha.push_back(MaterialAlphaBinding {
        .material = material,
        .animation = std::move(animation),
    });
}

void SceneRuntimeContext::BindMaterialAlpha(std::shared_ptr<SceneMaterial> material,
                                            std::unique_ptr<DynamicValue> value) {
    if (material == nullptr || value == nullptr) return;
    RegisterDynamicValueListener(std::move(value), [material](const DynamicValue& current) {
        ApplyMaterialAlpha(*material, current.getFloat());
    });
}

void SceneRuntimeContext::BindMaterialColor(std::vector<std::shared_ptr<SceneMaterial>> materials,
                                            std::unique_ptr<DynamicValue> value) {
    if (materials.empty() || value == nullptr) return;
    RegisterDynamicValueListener(
        std::move(value), [materials = std::move(materials)](const DynamicValue& current) {
            const auto color = current.getVec3();
            for (const auto& material : materials) {
                if (material != nullptr) ApplyMaterialColor(*material, color);
            }
        });
}

std::shared_ptr<ScalarAnimationPlayback> SceneRuntimeContext::RegisterScalarAnimation(
    std::string_view layer_name, ScalarAnimation animation) {
    if (!animation.name.empty()) {
        for (const auto& binding : m_scalar_animations) {
            if (binding.layer_name == layer_name && binding.playback->animation.name == animation.name) {
                return binding.playback;
            }
        }
    }
    auto playback = std::make_shared<ScalarAnimationPlayback>();
    playback->playing = !animation.start_paused;
    playback->animation = std::move(animation);
    m_scalar_animations.push_back({ std::string(layer_name), playback });
    return playback;
}

ScalarAnimationPlayback* SceneRuntimeContext::FindScalarAnimation(
    std::string_view layer_name, std::string_view animation_name) const {
    for (const auto& binding : m_scalar_animations) {
        if (binding.layer_name == layer_name && binding.playback->animation.name == animation_name) {
            return binding.playback.get();
        }
    }
    return nullptr;
}

ScalarAnimationPlayback* SceneRuntimeContext::FindAnimationByName(
    std::string_view animation_name) const {
    if (animation_name.empty()) return nullptr;
    for (const auto& binding : m_scalar_animations) {
        if (binding.playback->animation.name == animation_name) return binding.playback.get();
    }
    return nullptr;
}

void SceneRuntimeContext::RegisterSceneScript(std::string script_source, std::string layer_name) {
    auto script = m_script_engine->CreateSceneScriptProgram(*this,
                                                            std::move(script_source),
                                                            std::move(layer_name),
                                                            m_project_properties,
                                                            *m_host_context);
    if (script != nullptr && script->Valid()) {
        m_scene_scripts.push_back(SceneScriptBinding {
            .script = std::move(script),
        });
    }
}

void SceneRuntimeContext::RegisterNodeVideoTexture(std::string name, std::string texture_key) {
    if (name.empty() || texture_key.empty()) return;
    auto& texture_keys = m_node_video_textures[name];
    if (std::find(texture_keys.begin(), texture_keys.end(), texture_key) == texture_keys.end()) {
        texture_keys.push_back(texture_key);
    }
    if (! m_video_texture_playback.contains(texture_key)) {
        m_video_texture_playback.emplace(std::move(texture_key), VideoTexturePlaybackBinding {});
    }
}

void SceneRuntimeContext::RegisterSoundLayer(std::string                    name,
                                             std::shared_ptr<WPSoundStream> stream) {
    if (name.empty() || stream == nullptr) return;
    m_sound_layers[std::move(name)] = std::move(stream);
}

std::size_t SceneRuntimeContext::sceneScriptCount() const {
    return m_scripted_values.size() + m_scene_scripts.size();
}

uint32_t SceneRuntimeContext::DescribeTimeAdvancingWork() const {
    // Mirrors `Tick` step for step. Anything `Tick` advances has to be
    // represented here, or a scene would be allowed to sleep through work it
    // still performs. The ordering below is deliberately the ordering of the
    // loops in `Tick`, so the two can be diffed by eye.
    uint32_t reasons = 0;

    for (const auto& [texture_key, playback] : m_video_texture_playback) {
        (void)texture_key;
        // A paused source, or one stopped by a zero rate, advances nothing.
        // That is the same condition `Tick` uses to skip it.
        if (playback.paused || playback.rate <= 0.0F) continue;
        reasons |= SceneDemandReason::Video;
        break;
    }

    // A playback that has stopped -- a single-play timeline past its end, one
    // that starts paused, one a script paused -- holds its value:
    // `ScalarAnimationPlayback::Advance` does nothing until something plays it
    // again, and only a script command does (`play`, `setFrame`), which keeps
    // its own reason. Counting every registered playback kept a scene whose
    // only motion was a camera intro awake for good after the intro ended.
    const auto advances = [](const std::shared_ptr<ScalarAnimationPlayback>& playback) {
        return playback != nullptr && playback->playing && playback->rate != 0.0;
    };
    if (std::any_of(m_scalar_animations.begin(), m_scalar_animations.end(),
                    [&advances](const ScalarAnimationBinding& binding) {
                        return advances(binding.playback);
                    }) ||
        advances(m_scene_zoom_animation) ||
        std::any_of(m_material_alpha.begin(), m_material_alpha.end(),
                    [&advances](const MaterialAlphaBinding& binding) {
                        return advances(binding.animation);
                    })) {
        reasons |= SceneDemandReason::Animation;
    }

    for (const auto& group : m_perspective_camera_groups) {
        const PerspectiveCameraShot* selected = nullptr;
        for (const auto& shot : group.shots) {
            if (shot.node->EffectiveVisible()) selected = &shot;
        }
        if (selected && !selected->path.empty()) reasons |= SceneDemandReason::Animation;
    }

    // Scripted values re-evaluate every tick and may read the clock, the
    // pointer or anything else the script engine exposes. Their bodies are not
    // analysed; their presence is the answer.
    if (! m_scripted_values.empty() || ! m_scene_scripts.empty()) {
        reasons |= SceneDemandReason::Script;
    }

    // A binding existing is not a reason to keep ticking; a binding whose value
    // moves by itself is. The parser registers a visibility binding for every
    // layer it produces, so reading the registries' emptiness made every scene
    // with a single image layer report `NodeBinding` forever -- and made this
    // whole analysis unable to answer "still" about anything the parser built.
    //
    // What can move a value is a closed set. `ScriptedDynamicValue` is the only
    // subclass of `DynamicValue` in this runtime, and it re-evaluates every
    // tick. Anything else moves only when something calls `update()` on it: a
    // user property write, a script propagating into it, or an animation
    // sampling into it -- each of which is either an event that requests its
    // own frame or is already represented by `Script` or `Animation` below.
    const auto advances_on_its_own = [](const DynamicValue* value) {
        return dynamic_cast<const ScriptedDynamicValue*>(value) != nullptr;
    };
    const auto any_binding_advances = [&advances_on_its_own](const auto& bindings) {
        return std::any_of(bindings.begin(), bindings.end(), [&](const auto& entry) {
            if constexpr (requires { entry.second.value; }) {
                return advances_on_its_own(entry.second.value);
            } else {
                return advances_on_its_own(entry.value);
            }
        });
    };

    // `m_node_effect_final` holds no value at all: `SyncEffectFinalNode`
    // mirrors a node onto its effect layer's final node, so it moves when the
    // node it mirrors moves and never on its own.
    if (any_binding_advances(m_node_visibility) || any_binding_advances(m_node_translate) ||
        any_binding_advances(m_node_scale) || any_binding_advances(m_node_rotation) ||
        std::any_of(m_material_constants.begin(),
                    m_material_constants.end(),
                    [&advances_on_its_own](const MaterialConstantBinding& binding) {
                        // An animation writes the constant on a timeline of its
                        // own, which is exactly the case the value pointer
                        // cannot describe.
                        return binding.animation != nullptr ||
                               advances_on_its_own(binding.value);
                    })) {
        reasons |= SceneDemandReason::NodeBinding;
    }

    if (any_binding_advances(m_text_values)) reasons |= SceneDemandReason::TextBinding;

    // Text whose layout is still being produced is work in flight, not a still
    // scene. Bounded by the worker finishing: a completed job clears the flag,
    // and the worker wakes the clock when the scene has already gone quiet.
    if (TextLayoutInFlight()) reasons |= SceneDemandReason::TextLayoutPending;

    if (! m_puppet_layers.empty()) reasons |= SceneDemandReason::Puppet;

    // A sound layer that has been released by its owner is gone; one that is
    // still held may be playing. Image stillness is not a licence to stop
    // audio the user asked for, and this analysis cannot yet prove a given
    // sound is independent of the tick, so its presence keeps the clock.
    for (const auto& [name, stream] : m_sound_layers) {
        (void)name;
        if (stream.expired()) continue;
        reasons |= SceneDemandReason::Sound;
        break;
    }

    return reasons;
}

bool SceneRuntimeContext::HasNodeNamed(std::string_view name) const {
    return m_nodes.count(std::string(name)) != 0;
}

bool SceneRuntimeContext::HasSoundLayer(std::string_view name) const {
    return LockSoundLayer(name) != nullptr;
}

bool SceneRuntimeContext::PlaySoundLayer(std::string_view name) {
    auto stream = LockSoundLayer(name);
    if (stream == nullptr) return false;
    stream->Play();
    DispatchMediaPlaybackChanged(name, true);
    return true;
}

bool SceneRuntimeContext::PauseSoundLayer(std::string_view name) {
    auto stream = LockSoundLayer(name);
    if (stream == nullptr) return false;
    stream->Pause();
    DispatchMediaPlaybackChanged(name, false);
    return true;
}

bool SceneRuntimeContext::StopSoundLayer(std::string_view name) {
    auto stream = LockSoundLayer(name);
    if (stream == nullptr) return false;
    stream->Stop();
    DispatchMediaPlaybackChanged(name, false);
    return true;
}

bool SceneRuntimeContext::SoundLayerPlaying(std::string_view name) const {
    auto stream = LockSoundLayer(name);
    return stream != nullptr && stream->IsPlaying();
}

bool SceneRuntimeContext::SetSoundLayerVolume(std::string_view name, float volume) {
    auto stream = LockSoundLayer(name);
    if (stream == nullptr) return false;
    stream->SetVolume(volume);
    return true;
}

float SceneRuntimeContext::SoundLayerVolume(std::string_view name) const {
    auto stream = LockSoundLayer(name);
    return stream != nullptr ? stream->Volume() : 0.0f;
}

bool SceneRuntimeContext::SetSoundLayerMuted(std::string_view name, bool muted) {
    auto stream = LockSoundLayer(name);
    if (stream == nullptr) return false;
    stream->SetMuted(muted);
    return true;
}

bool SceneRuntimeContext::SoundLayerMuted(std::string_view name) const {
    auto stream = LockSoundLayer(name);
    return stream != nullptr && stream->Muted();
}

int SceneRuntimeContext::NodeSiblingIndex(std::string_view name) const {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return -1;

    const SceneNode* node = iterator->second;
    if (node->Parent() != nullptr) {
        return NodeIndexInList(node->Parent()->GetChildren(), node);
    }

    if (m_scene == nullptr || m_scene->sceneGraph == nullptr) return -1;
    return NodeIndexInList(m_scene->sceneGraph->GetChildren(), node);
}

std::string SceneRuntimeContext::CreateLayerFromTemplate(std::string_view requested_template_path,
                                                         std::string_view current_layer_name,
                                                         std::string_view script_workshop_id) {
    if (m_scene == nullptr || m_scene->sceneGraph == nullptr) return {};

    const std::string requested_path = NormalizeTemplatePath(requested_template_path);
    if (requested_path.empty()) return {};
    std::string loading_path;

    auto template_iterator = m_layer_templates.find(requested_path);
    if (template_iterator == m_layer_templates.end()) {
        if (const auto owner = m_node_template_paths.find(std::string(current_layer_name));
            owner != m_node_template_paths.end()) {
            if (const auto alias = MakeWorkshopLocalAlias(owner->second);
                ! alias.empty() && alias == requested_path) {
                loading_path = owner->second;
                template_iterator = m_layer_templates.find(owner->second);
            } else if (owner->second.starts_with("models/workshop/") &&
                       requested_path.starts_with("models/")) {
                constexpr std::string_view prefix         = "models/workshop/";
                const std::size_t          workshop_begin = prefix.size();
                const std::size_t          slash          = owner->second.find('/', workshop_begin);
                if (slash != std::string::npos) {
                    loading_path = owner->second.substr(0, slash + 1) +
                                   requested_path.substr(std::string("models/").size());
                    template_iterator = m_layer_templates.find(loading_path);
                }
            }
        }
    }
    const auto& resolved_path = loading_path.empty() ? requested_path : loading_path;

    // A path the scene never registered is loaded on demand, once: one that
    // failed stays failed until the loader is replaced.
    bool       newly_failed  = false;
    const auto load_template = [&](const std::string& path) {
        if (m_failed_layer_templates.contains(path) || m_loading_layer_templates.contains(path))
            return m_layer_templates.end();
        auto loaded_iterator = m_layer_templates.end();
        if (m_layer_template_loader) {
            m_loading_layer_templates.insert(path);
            struct LoadingGuard {
                std::unordered_set<std::string>& paths;
                const std::string& path;
                ~LoadingGuard() { paths.erase(path); }
            } loading_guard { m_loading_layer_templates, path };
            if (m_layer_template_loader(path)) loaded_iterator = m_layer_templates.find(path);
        }
        if (loaded_iterator == m_layer_templates.end()) {
            m_failed_layer_templates.insert(path);
            newly_failed = true;
        }
        return loaded_iterator;
    };

    if (template_iterator == m_layer_templates.end()) {
        template_iterator = load_template(resolved_path);
    }

    // A script imported from the Workshop declares `__workshopId` and keeps
    // naming its assets as they were in its own project (`models/bar.json`),
    // while the editor stored them under that item's workshop folder. Tried
    // only after everything above, so a path that resolves without it resolves
    // to the same template as before.
    if (template_iterator == m_layer_templates.end()) {
        if (const auto workshop_path = MakeWorkshopAssetPath(requested_path, script_workshop_id);
            ! workshop_path.empty() && workshop_path != resolved_path) {
            template_iterator = m_layer_templates.find(workshop_path);
            if (template_iterator == m_layer_templates.end()) {
                template_iterator = load_template(workshop_path);
            }
        }
    }

    if (template_iterator == m_layer_templates.end()) {
        if (newly_failed) {
            LOG_INFO(
                "scene runtime createLayer template not found: current=\"%s\" template=\"%s\"",
                std::string(current_layer_name).c_str(),
                requested_path.c_str());
        }
        return {};
    }

    // The scene layer registered under a model is copied, but one with an
    // effect chain (its own camera) or child layers cannot be. The model itself
    // still makes a layer, as when no scene layer uses it; loading it replaces
    // that registration, so later calls copy the loaded layer directly.
    const auto copyable = [](const LayerTemplateBinding& candidate) {
        return candidate.node != nullptr && candidate.node->Camera().empty() &&
               candidate.node->GetChildren().empty();
    };
    if (! copyable(template_iterator->second)) {
        const std::string model_path = template_iterator->second.canonical_path;
        template_iterator            = load_template(model_path);
        if (template_iterator == m_layer_templates.end() || ! copyable(template_iterator->second)) {
            // A model that loads into a shape that cannot be copied always will.
            m_failed_layer_templates.insert(model_path);
            LOG_INFO(
                "scene runtime createLayer unsupported template shape: current=\"%s\" template=\"%s\"",
                std::string(current_layer_name).c_str(),
                model_path.c_str());
            return {};
        }
    }

    const auto& binding = template_iterator->second;

    const std::string generated_name =
        "__generated_layer_" + std::to_string(m_next_generated_layer_id++) + ":" + requested_path;
    std::vector<ClonedMaterialBinding> material_bindings;
    auto generated = CloneNodeShallow(*binding.node, generated_name, &material_bindings);
    if (generated == nullptr) return {};

    SceneNode* parent = nullptr;
    if (const auto current = m_nodes.find(std::string(current_layer_name));
        current != m_nodes.end() && current->second != nullptr) {
        parent = current->second->Parent();
    }

    if (parent != nullptr) {
        parent->AppendChild(generated);
    } else {
        m_scene->sceneGraph->AppendChild(generated);
    }

    RegisterNode(generated_name, generated.get());
    m_script_created_layers.insert(generated_name);
    RegisterNodeSize(generated_name, binding.size);
    m_node_template_paths[generated_name] = binding.canonical_path;
    if (generated->Mesh() != nullptr && generated->Mesh()->MaterialSlotPtr() != nullptr) {
        const auto& values = generated->Mesh()->Material()->customShader.constValues;
        const auto alpha = values.find("g_UserAlpha");
        RegisterNodeAlpha(generated_name, generated->Mesh()->MaterialSlotPtr(),
                          alpha != values.end() && alpha->second.size() > 0
                              ? alpha->second[0] : 1.0f);
    }
    const auto source_constant_count      = m_material_constants.size();
    for (const auto& material_binding : material_bindings) {
        if (material_binding.source_material == nullptr ||
            material_binding.cloned_material == nullptr) {
            continue;
        }
        for (std::size_t index = 0; index < source_constant_count; ++index) {
            const auto& constant_binding = m_material_constants[index];
            const auto  locked_material  = constant_binding.material.lock();
            if (locked_material == nullptr ||
                locked_material != material_binding.source_material ||
                constant_binding.value == nullptr) {
                continue;
            }
            MaterialConstantBinding cloned_binding {
                .material = material_binding.cloned_material,
                .name = constant_binding.name,
                .value = constant_binding.value,
                .animation = constant_binding.animation,
            };
            ApplyMaterialConstantBinding(cloned_binding);
            m_material_constants.push_back(std::move(cloned_binding));
        }
    }
    m_scene_graph_mutated = true;
    return generated_name;
}

bool SceneRuntimeContext::DestroyLayer(std::string_view name) {
    const auto created = m_script_created_layers.find(std::string(name));
    if (created == m_script_created_layers.end()) return false;
    const std::string key = *created;
    m_script_created_layers.erase(created);

    const auto registered = m_nodes.find(key);
    SceneNode* node       = registered != m_nodes.end() ? registered->second : nullptr;
    UnregisterNode(key);
    if (node == nullptr || node->Parent() == nullptr) return true;

    auto&      siblings = node->Parent()->GetChildren();
    const auto entry    = std::find_if(siblings.begin(), siblings.end(), [node](const auto& child) {
        return child.get() == node;
    });
    if (entry == siblings.end()) return true;
    m_retired_layers.push_back(*entry);
    siblings.erase(entry);
    m_scene_graph_mutated = true;
    return true;
}

void SceneRuntimeContext::ReleaseRetiredLayers() {
    if (m_retired_layers.empty() || m_scene_graph_mutated) return;
    // Their copies of the template's material bindings write to materials
    // nothing draws any more.
    std::unordered_set<const SceneMaterial*> materials;
    for (const auto& node : m_retired_layers) {
        if (node->Mesh() != nullptr && node->Mesh()->MaterialSlotPtr() != nullptr) {
            materials.insert(node->Mesh()->MaterialSlotPtr().get());
        }
        if (m_scene != nullptr && m_scene->shaderValueUpdater != nullptr) {
            m_scene->shaderValueUpdater->ForgetNode(node.get());
        }
    }
    std::erase_if(m_material_constants, [&materials](const MaterialConstantBinding& binding) {
        const auto material = binding.material.lock();
        return material != nullptr && materials.contains(material.get());
    });
    m_retired_layers.clear();
}

Eigen::Vector3f SceneRuntimeContext::NodeColor(std::string_view name) const {
    const auto node = m_nodes.find(std::string(name));
    if (node == m_nodes.end() || node->second == nullptr || node->second->Mesh() == nullptr ||
        node->second->Mesh()->Material() == nullptr) return Eigen::Vector3f::Ones();
    const auto& values = node->second->Mesh()->Material()->customShader.constValues;
    const auto color = values.find("g_Color");
    if (color == values.end() || color->second.size() < 3) return Eigen::Vector3f::Ones();
    return Eigen::Vector3f(color->second[0], color->second[1], color->second[2]);
}

bool SceneRuntimeContext::SetNodeColor(std::string_view name, const Eigen::Vector3f& color) {
    const auto node = m_nodes.find(std::string(name));
    if (node == m_nodes.end() || node->second == nullptr || node->second->Mesh() == nullptr ||
        node->second->Mesh()->Material() == nullptr) return false;
    ApplyMaterialColor(*node->second->Mesh()->Material(), color);
    return true;
}

bool SceneRuntimeContext::SortNode(std::string_view name, int index) {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;

    SceneNode* node   = iterator->second;
    bool       sorted = false;
    if (node->Parent() != nullptr) {
        sorted = SortNodeInList(node->Parent()->GetChildren(), node, index);
    } else {
        if (m_scene == nullptr || m_scene->sceneGraph == nullptr) return false;
        sorted = SortNodeInList(m_scene->sceneGraph->GetChildren(), node, index);
    }
    if (sorted) m_scene_graph_mutated = true;
    return sorted;
}

bool SceneRuntimeContext::NodeVisible(std::string_view name) const {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;
    return iterator->second->Visible();
}

std::string SceneRuntimeContext::NodeParentName(std::string_view name) const {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return {};
    const auto* parent = iterator->second->Parent();
    // The graph root and the camera anchors carry no author name. A layer that
    // hangs off one of them has no parent layer, which is what the caller is
    // asking about, so the empty name is the answer rather than a miss.
    return parent != nullptr ? parent->Name() : std::string {};
}

void SceneRuntimeContext::RegisterNodeAlpha(std::string name,
                                            std::shared_ptr<SceneMaterial> material, float value) {
    if (name.empty() || material == nullptr) return;
    m_node_alpha[std::move(name)] = NodeAlphaBinding { .material = std::move(material),
                                                       .value    = value };
}

std::optional<float> SceneRuntimeContext::NodeAlpha(std::string_view name) const {
    const auto iterator = m_node_alpha.find(std::string(name));
    if (iterator == m_node_alpha.end()) return std::nullopt;
    return iterator->second.value;
}

bool SceneRuntimeContext::SetNodeAlpha(std::string_view name, float value) {
    const auto iterator = m_node_alpha.find(std::string(name));
    if (iterator == m_node_alpha.end() || iterator->second.material == nullptr) return false;
    if (iterator->second.value == value) return true;
    iterator->second.value = value;
    ApplyMaterialAlpha(*iterator->second.material, value);
    return true;
}

bool SceneRuntimeContext::SetNodeVisible(std::string_view name, bool visible) {
    if (const auto binding = m_node_visibility.find(std::string(name));
        binding != m_node_visibility.end() && binding->second.value != nullptr) {
        binding->second.value->update(visible);
    }
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;
    auto* node = iterator->second;
    const bool shown = visible && ! node->Visible();
    node->SetVisible(visible);
    // The script decides this layer's visibility from now on, so no later
    // graph may leave it out for being hidden.
    node->SetVisibilitySettled(false);
    if (shown) RequestGraphForShownLayers();
    return true;
}

void SceneRuntimeContext::RequestGraphForShownLayers() {
    if (m_scene == nullptr) return;
    for (const auto& excluded : m_scene->render_excluded_nodes) {
        const auto node = excluded.lock();
        if (node != nullptr && node->EffectiveVisible()) {
            m_scene_graph_mutated = true;
            return;
        }
    }
}

bool SceneRuntimeContext::SetNodeTranslate(std::string_view name, const Eigen::Vector3f& value) {
    if (const auto binding = m_node_translate.find(std::string(name));
        binding != m_node_translate.end() && binding->second.value != nullptr) {
        binding->second.value->update(value);
    }
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;
    auto& alignment = m_node_alignment[std::string(name)];
    if (! (alignment.origin.array() == value.array()).all()) {
        alignment.origin = value;
        alignment.transform_dirty = true;
    }
    ApplyNodeTransform(name);
    return true;
}

bool SceneRuntimeContext::SetNodeScale(std::string_view name, const Eigen::Vector3f& value) {
    if (const auto binding = m_node_scale.find(std::string(name));
        binding != m_node_scale.end() && binding->second.value != nullptr) {
        binding->second.value->update(value);
    }
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;
    auto& binding = m_node_alignment[std::string(name)];
    if (! (binding.scale.array() == value.array()).all()) {
        binding.scale = value;
        binding.transform_dirty = true;
    }
    if (binding.alignment.empty()) {
        iterator->second->SetScale(value);
    } else {
        ApplyNodeTransform(name);
    }
    return true;
}

bool SceneRuntimeContext::SetNodeAlignment(std::string_view name, std::string alignment) {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;

    auto& binding = m_node_alignment[std::string(name)];
    if (binding.alignment.empty()) {
        // No anchor yet: the node translate is the authored placement, so only
        // the scale delta belongs to the offset.
        binding.origin      = iterator->second->Translate();
        binding.scale       = iterator->second->Scale();
        binding.size_anchor = false;
        binding.transform_dirty = true;
    }
    if (binding.alignment != alignment) binding.transform_dirty = true;
    binding.alignment = std::move(alignment);
    ApplyNodeTransform(name);
    return true;
}

bool SceneRuntimeContext::SetNodeAnchorAlignment(std::string_view name, std::string alignment,
                                                 const Eigen::Vector3f& origin) {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;

    auto& binding       = m_node_alignment[std::string(name)];
    if (binding.alignment != alignment || ! binding.size_anchor ||
        ! (binding.origin.array() == origin.array()).all() ||
        ! (binding.scale.array() == iterator->second->Scale().array()).all()) {
        binding.transform_dirty = true;
    }
    binding.alignment   = std::move(alignment);
    binding.origin      = origin;
    binding.scale       = iterator->second->Scale();
    binding.size_anchor = true;
    ApplyNodeTransform(name);
    return true;
}

bool SceneRuntimeContext::SetNodeRotation(std::string_view name, const Eigen::Vector3f& value) {
    if (const auto binding = m_node_rotation.find(std::string(name));
        binding != m_node_rotation.end() && binding->second.value != nullptr) {
        binding->second.value->update(value);
    }
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;
    iterator->second->SetRotation(value);
    ApplyAnchoredNodeTransform(name);
    return true;
}

Eigen::Vector3f SceneRuntimeContext::NodeTranslate(std::string_view name) const {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return Eigen::Vector3f::Zero();
    const auto alignment = m_node_alignment.find(std::string(name));
    if (alignment != m_node_alignment.end() && ! alignment->second.alignment.empty())
        return alignment->second.origin;
    return iterator->second->Translate();
}

Eigen::Vector3f SceneRuntimeContext::NodeScale(std::string_view name) const {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return Eigen::Vector3f::Zero();
    return iterator->second->Scale();
}

Eigen::Vector3f SceneRuntimeContext::NodeRotation(std::string_view name) const {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return Eigen::Vector3f::Zero();
    return iterator->second->Rotation();
}

Eigen::Vector2f SceneRuntimeContext::NodeSize(std::string_view name) const {
    const auto iterator = m_node_size.find(std::string(name));
    if (iterator == m_node_size.end()) return Eigen::Vector2f::Zero();
    return iterator->second;
}

std::string SceneRuntimeContext::NodeText(std::string_view name) const {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return {};
    return iterator->second.text();
}

bool SceneRuntimeContext::NodeTextDirty(std::string_view name) const {
    const auto iterator = m_text_layers.find(std::string(name));
    return iterator != m_text_layers.end() && iterator->second.dirty();
}

std::optional<TextLayerState> SceneRuntimeContext::NodeTextState(std::string_view name) const {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return std::nullopt;
    return iterator->second.state();
}

bool SceneRuntimeContext::SetNodeText(std::string_view name, std::string text) {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return false;
    if (iterator->second.text() == text) return true;

    iterator->second.SetText(std::move(text));
    return true;
}

bool SceneRuntimeContext::ClearNodeTextDirty(std::string_view name) {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return false;
    iterator->second.ClearDirty();
    return true;
}

void SceneRuntimeContext::PumpTextLayerCache() {
    CollectPreparedTextLayers();
    for (auto& [name, layer] : m_text_layers) {
        // `TextLayoutInFlight` asks the same question, so that what the demand
        // analysis calls work in flight is exactly what this loop will do.
        if (! TextLayerIsBeingPrepared(name)) continue;
        if (layer.layoutPending()) {
            EnqueueTextLayerPreparation(name, layer);
            continue;
        }
    }
}

bool SceneRuntimeContext::SetNodeTextureFrame(std::string_view name, double frame) {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr || !std::isfinite(frame)) return false;
    it->second->SetTextureFrame(frame);
    return true;
}

double SceneRuntimeContext::NodeTextureFrame(std::string_view name) const {
    const auto it = m_nodes.find(std::string(name));
    return it != m_nodes.end() && it->second != nullptr
               ? it->second->TextureFrame().value_or(0.0) : 0.0;
}

bool SceneRuntimeContext::NodeHasVideoTexture(std::string_view name) const {
    const auto iterator = m_node_video_textures.find(std::string(name));
    return iterator != m_node_video_textures.end() && ! iterator->second.empty();
}

bool SceneRuntimeContext::PlayNodeVideoTexture(std::string_view name) {
    const auto iterator = m_node_video_textures.find(std::string(name));
    if (iterator == m_node_video_textures.end()) return false;
    bool controlled = false;
    for (const auto& texture_key : iterator->second) {
        auto& playback  = m_video_texture_playback[texture_key];
        playback.paused = false;
        controlled      = true;
    }
    return controlled;
}

bool SceneRuntimeContext::NodeVideoTextureIsPlaying(std::string_view name) const {
    const auto iterator = m_node_video_textures.find(std::string(name));
    if (iterator == m_node_video_textures.end()) return false;
    for (const auto& key : iterator->second) {
        const auto playback = m_video_texture_playback.find(key);
        if (playback != m_video_texture_playback.end() && !playback->second.paused) return true;
    }
    return false;
}

bool SceneRuntimeContext::PauseNodeVideoTexture(std::string_view name) {
    const auto iterator = m_node_video_textures.find(std::string(name));
    if (iterator == m_node_video_textures.end()) return false;
    bool controlled = false;
    for (const auto& texture_key : iterator->second) {
        auto& playback  = m_video_texture_playback[texture_key];
        playback.paused = true;
        controlled      = true;
    }
    return controlled;
}

bool SceneRuntimeContext::SetNodeVideoTextureCurrentTime(std::string_view name, double seconds) {
    const auto iterator = m_node_video_textures.find(std::string(name));
    if (iterator == m_node_video_textures.end()) return false;
    bool controlled = false;
    for (const auto& texture_key : iterator->second) {
        auto& playback = m_video_texture_playback[texture_key];
        playback.absolute_seconds =
            playback.duration_seconds > 0.0
                ? WrapSeconds(std::max(0.0, seconds), playback.duration_seconds)
                : std::max(0.0, seconds);
        controlled = true;
    }
    return controlled;
}

double SceneRuntimeContext::NodeVideoTextureCurrentTime(std::string_view name) const {
    const auto node_iterator = m_node_video_textures.find(std::string(name));
    if (node_iterator == m_node_video_textures.end() || node_iterator->second.empty()) return 0.0;
    const auto playback_iterator = m_video_texture_playback.find(node_iterator->second.front());
    if (playback_iterator == m_video_texture_playback.end()) return 0.0;
    const auto& playback = playback_iterator->second;
    return playback.duration_seconds > 0.0
               ? WrapSeconds(playback.absolute_seconds, playback.duration_seconds)
               : std::max(0.0, playback.absolute_seconds);
}

bool SceneRuntimeContext::SetNodeVideoTextureRate(std::string_view name, float rate) {
    const auto iterator = m_node_video_textures.find(std::string(name));
    if (iterator == m_node_video_textures.end()) return false;
    bool controlled = false;
    for (const auto& texture_key : iterator->second) {
        auto& playback = m_video_texture_playback[texture_key];
        playback.rate  = std::max(0.0f, rate);
        controlled     = true;
    }
    return controlled;
}

float SceneRuntimeContext::NodeVideoTextureRate(std::string_view name) const {
    const auto node_iterator = m_node_video_textures.find(std::string(name));
    if (node_iterator == m_node_video_textures.end() || node_iterator->second.empty()) return 1.0f;
    const auto playback_iterator = m_video_texture_playback.find(node_iterator->second.front());
    if (playback_iterator == m_video_texture_playback.end()) return 1.0f;
    return playback_iterator->second.rate;
}

double SceneRuntimeContext::NodeVideoTextureDuration(std::string_view name) const {
    const auto node_iterator = m_node_video_textures.find(std::string(name));
    if (node_iterator == m_node_video_textures.end() || node_iterator->second.empty()) return 0.0;
    const auto playback_iterator = m_video_texture_playback.find(node_iterator->second.front());
    if (playback_iterator == m_video_texture_playback.end()) return 0.0;
    return playback_iterator->second.duration_seconds;
}

void SceneRuntimeContext::SetVideoTextureDuration(std::string_view texture_key, double seconds) {
    if (texture_key.empty() || ! std::isfinite(seconds) || seconds <= 0.0) return;
    auto found = m_video_texture_playback.find(texture_key);
    if (found == m_video_texture_playback.end()) {
        found = m_video_texture_playback.emplace(std::string(texture_key), VideoTexturePlaybackBinding {}).first;
    }
    auto& playback            = found->second;
    playback.duration_seconds = seconds;
    playback.absolute_seconds = WrapSeconds(playback.absolute_seconds, seconds);
}

video::VideoPlaybackState
SceneRuntimeContext::ResolveVideoPlaybackState(std::string_view texture_key,
                                               double fallback_scene_elapsed_seconds) const {
    video::VideoPlaybackState state {};
    const auto                iterator = m_video_texture_playback.find(texture_key);
    if (iterator == m_video_texture_playback.end()) {
        state.scene_elapsed_seconds = fallback_scene_elapsed_seconds;
        return state;
    }

    const auto& playback        = iterator->second;
    state.paused                = playback.paused;
    state.rate                  = playback.rate;
    state.scene_elapsed_seconds = std::max(0.0, playback.absolute_seconds);
    return state;
}

std::shared_ptr<WPSoundStream> SceneRuntimeContext::LockSoundLayer(std::string_view name) const {
    const auto iterator = m_sound_layers.find(std::string(name));
    if (iterator == m_sound_layers.end()) return nullptr;
    return iterator->second.lock();
}

void SceneRuntimeContext::RefreshNodeTransformBindings(const std::string& name) {
    const auto node = m_nodes.find(name);
    const auto alignment = m_node_alignment.find(name);
    const auto size = m_node_size.find(name);
    const auto refresh = [&](auto& bindings) {
        const auto iterator = bindings.find(name);
        if (iterator == bindings.end()) return;
        auto& binding = iterator->second;
        binding.transform_node = node != m_nodes.end() ? node->second : nullptr;
        binding.alignment = alignment != m_node_alignment.end() ? &alignment->second : nullptr;
        binding.size = size != m_node_size.end() ? &size->second : nullptr;
    };
    refresh(m_node_translate);
    refresh(m_node_scale);
    refresh(m_node_rotation);
}

void SceneRuntimeContext::ApplyMaterialConstantBinding(MaterialConstantBinding& binding) {
    auto material = binding.material.lock();
    if (material == nullptr || (binding.value == nullptr && binding.animation == nullptr)) return;
    if (binding.animation != nullptr) {
        // Components share the timeline's frame but keep their own curves, so a
        // stable frame reuses the sampled value instead of re-solving Beziers.
        const double frame =
            binding.animation->playback != nullptr ? binding.animation->playback->frame : 0.0;
        if (! binding.cached_value_valid || ! (binding.sampled_animation_frame == frame)) {
            const std::size_t count =
                std::max<std::size_t>(binding.animation->component_count, 1);
            binding.cached_value.setSize(count);
            for (std::size_t index = 0; index < count; ++index) {
                const auto& curve = binding.animation->components[index];
                binding.cached_value[index] =
                    curve.Evaluate(curve.fps > 0.0 ? frame / curve.fps : 0.0);
            }
            binding.sampled_animation_frame = frame;
            binding.cached_value_valid      = true;
        }
    } else {
        const uint64_t generation = binding.value->Generation();
        if (! binding.cached_value_valid || binding.observed_generation != generation) {
            binding.cached_value = ShaderValueFromDynamicValue(*binding.value);
            binding.observed_generation = generation;
            binding.cached_value_valid = true;
        }
    }
    auto& values = material->customShader.constValues;
    const auto current = values.find(binding.name);
    const auto& cached = binding.cached_value;
    if (current == values.end()) {
        values.emplace(binding.name, cached);
    } else if (current->second.size() != cached.size() ||
               std::memcmp(current->second.data(), cached.data(), cached.size() * sizeof(float)) != 0) {
        current->second = cached;
    }
}

void SceneRuntimeContext::ApplyNodeTransform(std::string_view name) {
    const auto node_iterator = m_nodes.find(std::string(name));
    if (node_iterator == m_nodes.end() || node_iterator->second == nullptr) return;

    ApplyNodeTransform(*node_iterator->second, m_node_alignment[std::string(name)], NodeSize(name));
}

// Only an anchored node's translate depends on its rotation; the others keep
// whatever translate they were given.
void SceneRuntimeContext::ApplyAnchoredNodeTransform(std::string_view name) {
    const auto alignment = m_node_alignment.find(std::string(name));
    if (alignment == m_node_alignment.end() || alignment->second.alignment.empty()) return;
    ApplyNodeTransform(name);
}

void SceneRuntimeContext::ApplyNodeTransform(SceneNode& node, NodeAlignmentBinding& binding,
                                             const Eigen::Vector2f& size) {
    if (! (binding.rotation.array() == node.Rotation().array()).all()) {
        binding.rotation        = node.Rotation();
        binding.transform_dirty = true;
    }
    if (binding.transform_dirty) {
        // Offset from the anchor to the layer centre along the layer's own axes.
        // An axis without a named edge keeps -0, which adds to the origin
        // without changing a single bit of it.
        const auto half = [&](int axis) {
            const float scale = binding.scale[axis];
            return size[axis] * (binding.size_anchor ? scale : scale - 1.0f) * 0.5f;
        };
        Eigen::Vector3f offset = Eigen::Vector3f::Constant(-0.0f);
        bool            anchored = false;
        if (AlignmentContains(binding.alignment, "bottom")) {
            offset.y() = half(1);
            anchored   = true;
        } else if (AlignmentContains(binding.alignment, "top")) {
            offset.y() = -half(1);
            anchored   = true;
        }
        if (AlignmentContains(binding.alignment, "left")) {
            offset.x() = half(0);
            anchored   = true;
        } else if (AlignmentContains(binding.alignment, "right")) {
            offset.x() = -half(0);
            anchored   = true;
        }
        // The layer turns about its anchor, so the offset turns with it.
        if (anchored && ! binding.rotation.isZero(0.0f)) {
            offset = NodeRotationMatrix(binding.rotation) * offset;
        }
        binding.cached_translate = binding.origin + offset;
        binding.transform_dirty = false;
    }
    node.SetScale(binding.scale);
    node.SetTranslate(binding.cached_translate);
}

void SceneRuntimeContext::DispatchMediaPlaybackChanged(std::string_view name, bool playing) {
    (void)name;
    (void)playing;
}

// Letterboxed presentations leave window area the wallpaper never draws. The
// cursor still maps to a scene coordinate there, extrapolated past the drawn
// image, so layers reaching beyond the canvas must not answer to those bars.
bool SceneRuntimeContext::CursorInsidePresentedContent() const {
    const auto& origin = m_cursor_viewport.content_origin;
    const auto& size   = m_cursor_viewport.content_size;
    if (size.x() <= 0.0f || size.y() <= 0.0f) return true;
    const auto& cursor = m_host_context->cursor_world_position;
    return cursor.x() >= origin.x() && cursor.x() <= origin.x() + size.x() &&
           cursor.y() >= origin.y() && cursor.y() <= origin.y() + size.y();
}

bool SceneRuntimeContext::CursorHitsLayer(std::string_view name) const {
    if (name.empty()) return true;
    if (! CursorInsidePresentedContent()) return false;
    const std::string key(name);
    const auto        node_iterator = m_nodes.find(key);
    if (node_iterator == m_nodes.end() || node_iterator->second == nullptr) return false;
    const auto         mask_iterator = m_node_hit_masks.find(key);
    const NodeHitMask* mask =
        mask_iterator == m_node_hit_masks.end() ? nullptr : &mask_iterator->second;
    const SceneCamera* camera =
        m_scene != nullptr ? CameraForHitNode(*m_scene, *node_iterator->second) : nullptr;
    const Eigen::Vector2d ndc =
        CursorWorldToNdc(m_cursor_viewport, CursorHitTestWorldPosition(*m_host_context));
    return HitTestNode(*node_iterator->second,
                       NodeSize(name),
                       CursorHitTestWorldPosition(*m_host_context),
                       mask,
                       camera,
                       ndc);
}

bool SceneRuntimeContext::CursorHitsScriptLayer(const ScriptedDynamicValue& value) const {
    return CursorHitsLayer(value.LayerName());
}

bool SceneRuntimeContext::CursorHitsScriptLayer(const SceneScriptProgram& script) const {
    return CursorHitsLayer(script.LayerName());
}

// An authored timeline can name frames its layer's scripts react to. Handlers
// may create, hide or destroy layers, so every crossed marker is collected
// before any of them runs and the script lists are re-checked while dispatching.
void SceneRuntimeContext::DispatchPendingAnimationEvents() {
    struct QueuedEvent {
        std::string layer_name;
        std::string name;
        double      frame { 0.0 };
    };
    std::vector<QueuedEvent> events;
    for (auto& binding : m_scalar_animations) {
        if (binding.playback == nullptr || binding.playback->pending_events.empty()) continue;
        for (auto& event : binding.playback->pending_events) {
            events.push_back(QueuedEvent {
                .layer_name = binding.layer_name,
                .name       = std::move(event.name),
                .frame      = event.frame,
            });
        }
        binding.playback->pending_events.clear();
    }
    if (events.empty()) return;

    for (const auto& event : events) {
        for (std::size_t index = 0; index < m_scripted_values.size(); ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr || value->LayerName() != event.layer_name) continue;
            value->DispatchAnimationEvent(*m_host_context, event.name, event.frame);
        }
        for (std::size_t index = 0; index < m_scene_scripts.size(); ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr || script->LayerName() != event.layer_name) continue;
            script->DispatchAnimationEvent(*m_host_context, event.name, event.frame);
        }
        // One shared global listener list, so it runs once per event whether or
        // not a scene script happens to be bound to this layer.
        m_script_engine->RunAnimationEventCallbacks(*m_host_context, event.name, event.frame);
    }
}

void SceneRuntimeContext::DispatchCursorClick(int button) {
    m_host_context->cursor_button = button;
    ForEachEventScript([&](auto* script) { script->DispatchCursorClick(*m_host_context); });
}

void SceneRuntimeContext::DispatchCursorDown(int button) {
    m_host_context->cursor_button = button;
    ForEachEventScript([&](auto* script) { script->DispatchCursorDown(*m_host_context); });
}

void SceneRuntimeContext::DispatchCursorEnter() {
    ForEachEventScript([&](auto* script) { script->DispatchCursorEnter(*m_host_context); });
}

void SceneRuntimeContext::DispatchCursorLeave() {
    ForEachEventScript([&](auto* script) { script->DispatchCursorLeave(*m_host_context); });
}

void SceneRuntimeContext::DispatchCursorMove() {
    ForEachEventScript([&](auto* script) { script->DispatchCursorMove(*m_host_context); });
}

void SceneRuntimeContext::DispatchCursorUp(int button) {
    m_host_context->cursor_button = button;
    ForEachEventScript([&](auto* script) { script->DispatchCursorUp(*m_host_context); });
}

bool SceneRuntimeContext::DispatchCursorFrameEvents(bool cursor_was_in_window) {
    // Callbacks can load templates and append to either registry. Keep only
    // stable pointees across a callback and let new registrations join the next event.
    const auto value_count = m_scripted_values.size();
    const auto script_count = m_scene_scripts.size();
    constexpr auto hover_mask = static_cast<uint8_t>(ScriptCursorEvent::Enter) |
                                static_cast<uint8_t>(ScriptCursorEvent::Leave) |
                                static_cast<uint8_t>(ScriptCursorEvent::Move);
    constexpr auto press_mask = static_cast<uint8_t>(ScriptCursorEvent::Down) |
                                static_cast<uint8_t>(ScriptCursorEvent::Click);
    const bool cursor_in_window = m_host_context->cursor_in_window;
    if (cursor_in_window && ! cursor_was_in_window) {
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value != nullptr && (value->CursorHandlerMask() & hover_mask) != 0 &&
                CursorHitsScriptLayer(*value)) {
                value->DispatchCursorEnter(*m_host_context);
                m_scripted_value_cursor_inside[value] = true;
            }
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr) continue;
            m_scene_scripts[index].cursor_inside = CursorHitsScriptLayer(*script);
            if (m_scene_scripts[index].cursor_inside) script->DispatchCursorEnter(*m_host_context);
        }
    } else if (! cursor_in_window && cursor_was_in_window) {
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr || (value->CursorHandlerMask() & hover_mask) == 0) continue;
            if (m_scripted_value_cursor_inside[value]) {
                value->DispatchCursorLeave(*m_host_context);
            }
            m_scripted_value_cursor_inside[value] = false;
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr) continue;
            if (m_scene_scripts[index].cursor_inside) script->DispatchCursorLeave(*m_host_context);
            m_scene_scripts[index].cursor_inside = false;
        }
    }

    if (cursor_in_window) {
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr || (value->CursorHandlerMask() & hover_mask) == 0) continue;
            const bool now_inside = CursorHitsScriptLayer(*value);
            bool&      was_inside = m_scripted_value_cursor_inside[value];
            if (now_inside != was_inside) {
                if (now_inside) {
                    value->DispatchCursorEnter(*m_host_context);
                } else {
                    value->DispatchCursorLeave(*m_host_context);
                }
                was_inside = now_inside;
            }
            if (now_inside) value->DispatchCursorMove(*m_host_context);
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr) continue;
            const bool now_inside = CursorHitsScriptLayer(*script);
            if (now_inside != m_scene_scripts[index].cursor_inside) {
                if (now_inside) {
                    script->DispatchCursorEnter(*m_host_context);
                } else {
                    script->DispatchCursorLeave(*m_host_context);
                }
                m_scene_scripts[index].cursor_inside = now_inside;
            }
            if (now_inside) script->DispatchCursorMove(*m_host_context);
        }
    }

    for (int button = 0; button < 32; ++button) {
        const uint32_t mask = 1u << static_cast<uint32_t>(button);
        if (cursor_in_window && (m_host_context->mouse_buttons_pressed & mask) != 0) {
            m_host_context->cursor_button = button;
            auto& held_values  = m_scripted_value_cursor_held[mask];
            auto& held_scripts = m_scene_script_cursor_held[mask];
            held_values.clear();
            held_scripts.clear();
            for (std::size_t index = 0; index < value_count; ++index) {
                auto* value = m_scripted_values[index];
                if (value == nullptr || (value->CursorHandlerMask() & press_mask) == 0 ||
                    ! CursorHitsScriptLayer(*value)) continue;
                value->DispatchCursorDown(*m_host_context);
                value->DispatchCursorClick(*m_host_context);
                held_values.push_back(value);
            }
            for (std::size_t index = 0; index < script_count; ++index) {
                auto* script = m_scene_scripts[index].script.get();
                if (script == nullptr || ! CursorHitsScriptLayer(*script)) continue;
                script->DispatchCursorDown(*m_host_context);
                script->DispatchCursorClick(*m_host_context);
                held_scripts.push_back(index);
            }
        }
        if ((m_host_context->mouse_buttons_released & mask) != 0) {
            m_host_context->cursor_button = button;
            // The release belongs to whoever took the press, wherever the
            // cursor is now. Re-testing the layer here loses it for anything
            // that moved or shrank while held, and a script that only clears
            // its pressed state on the way up never gets to.
            auto  held_values  = std::move(m_scripted_value_cursor_held[mask]);
            auto  held_scripts = std::move(m_scene_script_cursor_held[mask]);
            m_scripted_value_cursor_held.erase(mask);
            m_scene_script_cursor_held.erase(mask);
            const auto took_press = [](const auto& held, const auto& item) {
                return std::find(held.begin(), held.end(), item) != held.end();
            };
            for (std::size_t index = 0; index < value_count; ++index) {
                auto* value = m_scripted_values[index];
                if (value == nullptr ||
                    (value->CursorHandlerMask() & static_cast<uint8_t>(ScriptCursorEvent::Up)) == 0) continue;
                if (! took_press(held_values, value)) {
                    // Nothing was pressed here, so the old rule decides: a
                    // layer has to be under the cursor, and a scene-wide
                    // script hears the release from anywhere.
                    if (cursor_in_window) {
                        if (! CursorHitsScriptLayer(*value)) continue;
                    } else if (! value->LayerName().empty()) {
                        continue;
                    }
                }
                value->DispatchCursorUp(*m_host_context);
            }
            for (std::size_t index = 0; index < script_count; ++index) {
                auto* script = m_scene_scripts[index].script.get();
                if (script == nullptr) continue;
                if (! took_press(held_scripts, index)) {
                    if (cursor_in_window) {
                        if (! CursorHitsScriptLayer(*script)) continue;
                    } else if (! script->LayerName().empty()) {
                        continue;
                    }
                }
                script->DispatchCursorUp(*m_host_context);
            }
        }
    }

    return cursor_in_window;
}

void SceneRuntimeContext::DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                        const Eigen::Vector3f& text_color) {
    ForEachEventScript([&](auto* script) { script->DispatchMediaThumbnailChanged(primary_color, text_color); });
}

void SceneRuntimeContext::SetMediaIntegrationEnabled(bool enabled) {
    m_media_integration_enabled = enabled;
}

bool SceneRuntimeContext::MediaIntegrationEnabled() const { return m_media_integration_enabled; }

void SceneRuntimeContext::DispatchMediaEventJson(std::string_view event_json) {
    if (! m_media_integration_enabled || event_json.empty()) return;
    ForEachEventScript([&](auto* script) { script->DispatchMediaEventJson(event_json); });
}

void SceneRuntimeContext::RequestUserShortcut(std::string_view property_name,
                                              std::string_view property_value) {
    // A wallpaper that asks on every cursor event while nothing drains would
    // otherwise grow this forever. Sixteen is far more than a user can press
    // between two host turns, and dropping the oldest keeps the newest press --
    // the one still being waited on -- rather than the stalest.
    constexpr std::size_t kMaxPendingRequests = 16;
    if (m_user_shortcut_requests.size() >= kMaxPendingRequests) {
        m_user_shortcut_requests.erase(m_user_shortcut_requests.begin());
    }
    m_user_shortcut_requests.emplace_back(std::string(property_name), std::string(property_value));
}

std::vector<std::pair<std::string, std::string>> SceneRuntimeContext::TakeUserShortcutRequests() {
    return std::exchange(m_user_shortcut_requests, {});
}

void SceneRuntimeContext::MarkSceneRequiresAudioResponse() {
    // Shader init and scripts may mark repeatedly; after the first time this
    // is a load, not a read-modify-write every thread contends on.
    if (m_scene_requires_audio_response.load(std::memory_order_acquire)) return;
    if (m_scene_requires_audio_response.exchange(true, std::memory_order_acq_rel)) return;
    std::function<void()> listener;
    {
        std::lock_guard lock(m_audio_requirement_mutex);
        listener = m_audio_requirement_listener;
    }
    if (listener) listener();
}

bool SceneRuntimeContext::SceneRequiresAudioResponse() const {
    return m_scene_requires_audio_response.load(std::memory_order_acquire);
}

void SceneRuntimeContext::SetAudioRequirementListener(std::function<void()> listener) {
    std::lock_guard lock(m_audio_requirement_mutex);
    m_audio_requirement_listener = std::move(listener);
}

void SceneRuntimeContext::SetAudioResponseEnabled(bool enabled) {
    m_audio_response_enabled.store(enabled, std::memory_order_release);
}

bool SceneRuntimeContext::AudioResponseEnabled() const {
    return m_audio_response_enabled.load(std::memory_order_acquire);
}

bool SceneRuntimeContext::AudioResponseActive() const {
    return AudioResponseEnabled() && SceneRequiresAudioResponse();
}

bool SceneRuntimeContext::ConsumeSceneGraphMutationFlag() {
    const bool mutated    = m_scene_graph_mutated;
    m_scene_graph_mutated = false;
    return mutated;
}

audio::AudioSpectrumSnapshot SceneRuntimeContext::CurrentAudioSpectrumSnapshot() const {
    if (! AudioResponseActive()) {
        return {};
    }
    return audio::CurrentAudioSpectrumSnapshot();
}

void SceneRuntimeContext::RecordScriptError(std::string message) {
    if (message.empty()) return;
    m_script_errors.push_back(std::move(message));
}

std::size_t SceneRuntimeContext::scriptErrorCount() const { return m_script_errors.size(); }

const std::vector<std::string>& SceneRuntimeContext::scriptErrors() const {
    return m_script_errors;
}

void SceneRuntimeContext::ClearScriptErrors() { m_script_errors.clear(); }

std::unique_ptr<SceneRuntimeContext> CreateSceneRuntimeContext(SceneRuntimeBootstrap bootstrap) {
    return std::make_unique<SceneRuntimeContext>(std::move(bootstrap));
}

} // namespace wallpaper
