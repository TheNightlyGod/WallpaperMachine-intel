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
#include "Scene/Parse/PassthroughCard.hpp"
#include "Scripting/ScriptEngine.hpp"
#include "SpecTexs.hpp"
#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "WPSoundParser.hpp"

#include <Eigen/Geometry>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
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
    const auto layout = MeasureTextLayerLayout(state);
    const Eigen::Vector2f raster_size = TextLayerRasterSizeForLayout(state, layout);
    const uint32_t width =
        std::clamp(static_cast<uint32_t>(std::ceil(std::max(1.0f, raster_size.x()))), 1u, 4096u);
    const uint32_t height =
        std::clamp(static_cast<uint32_t>(std::ceil(std::max(1.0f, raster_size.y()))), 1u, 4096u);
    const auto render_frame = TextLayerRenderFrameForLayout(state, layout);
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    return RuntimePreparedTextLayerImage {
        .name        = std::move(name),
        .revision    = revision,
        .state       = std::move(state),
        .layout      = layout,
        .render_frame = render_frame,
        .width       = width,
        .height      = height,
        .rgba        = std::move(rgba),
    };
}

// The box a card mesh covers, by its size and its centre in the layer's own plane.
struct CardMeshBox {
    Eigen::Vector2f size { Eigen::Vector2f::Zero() };
    Eigen::Vector2f centre { Eigen::Vector2f::Zero() };
};

CardMeshBox CardMeshBoxOf(const SceneMesh& mesh) {
    if (mesh.VertexCount() == 0) return {};

    const auto& vertices = mesh.GetVertexArray(0);
    if (vertices.VertexCount() == 0 || vertices.OneSize() < 2) return {};

    const float* data = vertices.Data();
    if (data == nullptr) return {};

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

    return { .size   = Eigen::Vector2f(max_x - min_x, max_y - min_y),
             .centre = Eigen::Vector2f((min_x + max_x) * 0.5f, (min_y + max_y) * 0.5f) };
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
// The rectangle is `size` across, centred on `centre` in the layer's own plane (a
// text layer's card hangs off its origin by its alignment) and drawn where the
// node's draw offset puts it.
bool HitTestNode(SceneNode& node, Eigen::Vector2f size, Eigen::Vector2f centre,
                 const Eigen::Vector3f& cursor, const NodeHitMask* mask,
                 const SceneCamera* camera, Eigen::Vector2d ndc) {
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
        Eigen::Matrix4d model = node.ModelTrans();
        model.block<3, 1>(0, 3) += node.DrawOffset().cast<double>();
        if (! std::isfinite(model.determinant()) || std::abs(model.determinant()) < 1e-12) {
            return false;
        }
        local = model.inverse() * Eigen::Vector4d(cursor.x(), cursor.y(), cursor.z(), 1.0);
    }

    const double half_width  = static_cast<double>(size.x()) * 0.5;
    const double half_height = static_cast<double>(size.y()) * 0.5;
    const double across      = local.x() - static_cast<double>(centre.x());
    const double down        = local.y() - static_cast<double>(centre.y());
    if (across < -half_width || across > half_width || down < -half_height ||
        down > half_height) {
        return false;
    }
    if (mask == nullptr || half_width <= 0.0 || half_height <= 0.0) return true;

    // Card meshes map local (left, top) to texture (0, 0).
    const float u = static_cast<float>((across + half_width) / (2.0 * half_width));
    const float v = static_cast<float>((half_height - down) / (2.0 * half_height));
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
    clone->SetIgnoreParentTransform(node.IgnoresParentTransform());
    clone->CopyChildFrame(node);
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

// The layer's alpha in a material that takes it: the `g_Color4` and `g_Alpha` every
// pass of the layer is given and, on the layer's own pass, its `g_UserAlpha`. An
// effect's is the effect's own opacity (`own_user_alpha`): it starts from the
// layer's authored alpha, the effect's own `alpha` replaces that, and either is
// left alone, or the layer's alpha would be applied again by every effect that has
// an alpha.
void ApplyMaterialAlpha(SceneMaterial& material, float alpha) {
    auto& values = material.customShader.constValues;

    if (! material.own_user_alpha) values["g_UserAlpha"] = ShaderValue(alpha);

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

// The layer's colour times its brightness where the scene renders HDR, with the
// alpha `g_Color4` already holds.
void ApplyMaterialTint(SceneMaterial& material) {
    auto& values = material.customShader.constValues;
    const auto color4 = values.find("g_Color4");
    const float alpha = color4 != values.end() && color4->second.size() > 3
                            ? color4->second[3] : 1.0f;
    const auto& tint = material.tint;
    values["g_Color4"] = std::array<float, 4> {
        tint.color[0] * tint.brightness,
        tint.color[1] * tint.brightness,
        tint.color[2] * tint.brightness,
        alpha,
    };
}

void ApplyMaterialColor(SceneMaterial& material, const Eigen::Vector3f& color) {
    material.tint.color = { color.x(), color.y(), color.z() };
    material.customShader.constValues["g_Color"] =
        std::array<float, 3> { color.x(), color.y(), color.z() };
    ApplyMaterialTint(material);
}

void ApplyMaterialBrightness(SceneMaterial& material, float brightness) {
    material.tint.brightness = brightness;
    ApplyMaterialTint(material);
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

void SyncEffectFinalNode(SceneNode& source, SceneImageEffectLayer& layer,
                         PassthroughCard* passthrough_card) {
    source.UpdateTrans();
    // The final card is what reaches the scene, so it is drawn where the source layer
    // is drawn: its world matrix with the offset a screen anchor adds to the draw.
    auto matrix = source.ModelTrans();
    if (! source.DrawOffset().isZero()) matrix.block<3, 1>(0, 3) += source.DrawOffset().cast<double>();
    // A pass-through layer's card copies the screen from the same place, so a group
    // that moves the layer moves both; the card's corners change only when it does.
    if (passthrough_card != nullptr && source.Mesh() != nullptr) {
        passthrough_card->LayOut(*source.Mesh(), matrix);
    }
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

SceneRuntimeContext::~SceneRuntimeContext() {
    // Scripts end while the layers and values they could still touch exist.
    TearDownScripts();
    // From here on the registry is going away with the other members, and a
    // scripted value destroyed with them has nothing to leave.
    m_scripted_value_registry.reset();
    StopTextWorker();
}

void SceneRuntimeContext::TearDownScripts() {
    // A `destroy()` may create layers, which can register more scripts: those
    // are never started, so only the ones present now are ended, by index.
    const auto value_count  = m_scripted_values.size();
    const auto script_count = m_scene_scripts.size();
    for (std::size_t index = 0; index < value_count; ++index) {
        if (auto* value = m_scripted_values[index]; value != nullptr) value->Destroy();
    }
    for (std::size_t index = 0; index < script_count; ++index) {
        if (auto* script = m_scene_scripts[index].script.get(); script != nullptr) script->Destroy();
    }
}

void SceneRuntimeContext::Tick(double frame_time) {
    ReleaseRetiredLayers();
    m_host_context->frame_time = frame_time;
    m_host_context->runtime_seconds += frame_time;
    // Loading a script-created template can register more scripts. Newly added
    // programs start next tick, and no iterator survives a loader callback.
    const auto scripted_value_count = m_scripted_values.size();
    const auto scene_script_count = m_scene_scripts.size();
    // What changed about the environment since the scripts last looked: the
    // display's size and the interface language. A script that has not started
    // learns the current ones from its own `init`.
    if (m_screen_resize_pending || m_general_settings_pending) {
        const bool resized  = m_screen_resize_pending;
        const bool language = m_general_settings_pending;
        m_screen_resize_pending     = false;
        m_general_settings_pending = false;
        for (std::size_t index = 0; index < scripted_value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr) continue;
            if (resized) value->DispatchResizeScreen(*m_host_context);
            if (language) value->DispatchGeneralSettings(*m_host_context);
        }
        for (std::size_t index = 0; index < scene_script_count; ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr) continue;
            if (resized) script->DispatchResizeScreen(*m_host_context);
            if (language) script->DispatchGeneralSettings(*m_host_context);
        }
        // `engine.on('resizeScreen', ...)` listeners can only exist where a script does.
        if (resized && (scripted_value_count != 0 || scene_script_count != 0)) {
            m_script_engine->RunResizeScreenCallbacks(*m_host_context);
        }
    }
    DispatchPuppetLayerEvents();
    for (auto& [texture_key, playback] : m_video_texture_playback) {
        (void)texture_key;
        if (playback.paused) continue;
        const double scaled_delta = static_cast<double>(playback.rate) * frame_time;
        if (scaled_delta <= 0.0) continue;
        playback.absolute_seconds += scaled_delta;
    }
    for (auto& binding : m_scalar_animations) binding.playback->Advance(frame_time);
    // Scripts the scene has not started all run `init`, in the scene's order,
    // before any of them is told the user properties, and that before any
    // `update`: one script's first `applyUserProperties` may call what a later
    // layer's `init` set up. They start on this tick, so markers crossed by it
    // are delivered to started scripts.
    const auto first_unstarted = std::min(m_scripted_values_started, scripted_value_count);
    for (std::size_t index = first_unstarted; index < scripted_value_count; ++index) {
        if (auto* value = m_scripted_values[index]; value != nullptr) value->Start();
    }
    for (std::size_t index = first_unstarted; index < scripted_value_count; ++index) {
        if (auto* value = m_scripted_values[index]; value != nullptr) {
            value->DeliverInitialUserProperties();
        }
    }
    m_scripted_values_started = scripted_value_count;
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
        ApplyNodeVec3Animation(binding);
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
        ApplyNodeVec3Animation(binding);
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
        ApplyNodeVec3Animation(binding);
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
        SyncEffectFinalNode(*binding.node, *binding.layer, binding.passthrough_card.get());
    }
    for (auto& binding : m_material_constants) ApplyMaterialConstantBinding(binding);
    for (std::size_t index = 0; index < scene_script_count; ++index) {
        auto* script = m_scene_scripts[index].script.get();
        if (script != nullptr) script->Tick(*m_host_context);
    }
    // Once every script has started and before anything is drawn: a widget that
    // hides itself on `PLAYBACK_STOPPED` is not on screen for a frame first.
    DispatchIdleMediaState();
    ApplySceneZoomAnimation();
    // After every visibility and origin writer of this tick, scripts included,
    // so the shot shown is the one this tick left visible, at the origin this
    // tick gave it.
    for (auto& shot : m_camera_shots) shot.origin_pending = false;
    ApplyCameraShots();
    ApplyPerspectiveCameraShots(frame_time);
    ApplyCameraShake();
    for (auto& binding : m_material_alpha) {
        auto material = binding.material.lock();
        if (material == nullptr) continue;
        ApplyMaterialAlpha(*material, binding.animation->Value());
    }
    for (auto& binding : m_material_colors) ApplyMaterialColorAnimation(binding);
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
    m_cursor_plane_position               = value;
    m_host_context->cursor_world_position = value;
}

void SceneRuntimeContext::SetCursorViewport(const CursorViewport& viewport) {
    if (! viewport.origin.allFinite() || ! viewport.size.allFinite()) return;
    if (! viewport.content_origin.allFinite() || ! viewport.content_size.allFinite()) return;
    if (viewport.size.x() == 0.0f || viewport.size.y() == 0.0f) return;
    m_cursor_viewport = viewport;
    UpdatePresentedMargins();
}

void SceneRuntimeContext::UpdatePresentedMargins() {
    // The area the window shows, against the canvas the scene was authored for.
    // A scene without an orthogonal canvas is not framed this way.
    PresentedMargins margins;
    const auto&      canvas = m_host_context->canvas_size;
    const bool       framed = (m_scene == nullptr || ! m_scene->display_sized) &&
                        canvas.x() > 0.0f && canvas.y() > 0.0f;
    if (framed) {
        const auto& origin = m_cursor_viewport.origin;
        const auto& size   = m_cursor_viewport.size;
        margins.left   = origin.x();
        margins.bottom = origin.y();
        margins.right  = canvas.x() - (origin.x() + size.x());
        margins.top    = canvas.y() - (origin.y() + size.y());
    }
    if (margins == m_presented_margins) return;
    m_presented_margins = margins;
    for (auto& [name, binding] : m_node_alignment) {
        if (binding.screen_anchor == TextScreenAnchor::None) continue;
        binding.screen_offset   = TextScreenAnchorOffset(binding.screen_anchor, margins);
        binding.transform_dirty = true;
        ApplyNodeTransform(name);
    }
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
    // A new size is news to the scripts, which are told on the next tick.
    if (! SizeNearlyEqual(m_host_context->screen_resolution, resolution, 0.5f)) {
        m_screen_resize_pending = true;
    }
    m_host_context->screen_resolution = resolution;
}

void SceneRuntimeContext::SetLanguage(std::string_view language) {
    std::string normalized;
    normalized.reserve(language.size());
    for (const char character : language) {
        normalized.push_back(character == '_'
                                 ? '-'
                                 : static_cast<char>(std::tolower(static_cast<unsigned char>(character))));
    }
    if (normalized.empty()) normalized = "en-us";
    if (normalized == m_host_context->language) return;
    m_host_context->language = std::move(normalized);
    m_general_settings_pending = true;
}

const std::string& SceneRuntimeContext::Language() const { return m_host_context->language; }

void SceneRuntimeContext::SetCursorInput(float x, float y) {
    x                                          = std::clamp(x, 0.0f, 1.0f);
    y                                          = std::clamp(y, 0.0f, 1.0f);
    m_host_context->cursor_normalized_position = Eigen::Vector2f(x, y);
    m_cursor_plane_position =
        Eigen::Vector3f(m_cursor_viewport.origin.x() + x * m_cursor_viewport.size.x(),
                        m_cursor_viewport.origin.y() + (1.0f - y) * m_cursor_viewport.size.y(),
                        0.0f);
    m_host_context->cursor_world_position = ScriptCursorWorldPosition();
    // Published for the parts of the scene that are not scripts. A particle
    // system's mouse-linked control point needs the same scene coordinate, and
    // deriving it a second time from the canvas is how it ended up ignoring
    // the crop.
    if (m_scene != nullptr) {
        m_scene->pointerScenePosition = std::array {
            m_cursor_plane_position.x(),
            m_cursor_plane_position.y(),
        };
    }
}

// `input.cursorWorldPosition`. Wallpaper Engine unprojects the pointer through
// the scene camera at window depth 0.5, which its [-1, 1] depth remap turns
// into 0, and its perspective projection stores depth reversed (1 at the near
// plane, 0 at the far one): the script gets the cursor ray's point at the far
// plane, `farz` in front of the eye, in the same world as layer origins. A
// scene authored on a canvas gets canvas units with z = 0 (it hands over its
// 2D point whatever the camera). Wallpaper Engine unprojects when a script
// reads; this is worked out when the cursor is sampled, before the tick's
// scripts and camera shake move the camera, so it is the pose the last tick
// left. A camera with no usable view (a far plane or aspect that is not
// positive) keeps the canvas point rather than a made-up depth.
Eigen::Vector3f SceneRuntimeContext::ScriptCursorWorldPosition() const {
    const SceneCamera* camera =
        m_scene != nullptr && m_scene->display_sized ? m_scene->activeCamera : nullptr;
    if (camera == nullptr || ! camera->IsPerspective()) return m_cursor_plane_position;
    const Eigen::Vector2d ndc = CursorWorldToNdc(m_cursor_viewport, m_cursor_plane_position);
    const auto point = UnprojectNdcAtDepth(*camera, ndc.x(), ndc.y(), camera->FarClip());
    return point.has_value() ? Eigen::Vector3f(point->cast<float>()) : m_cursor_plane_position;
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
    const Eigen::Vector2f raster_size = TextLayerRasterSizeForLayout(prepared.state, prepared.layout);
    // The card is the text and its padding, and the raster the card and the style's
    // margin, so the two change together. Where the card hangs from the layer's origin
    // changes with its width for a text aligned to one side, and with the alignment
    // itself, which moves the card without resizing it.
    const bool card_changed = ! SizeNearlyEqual(layer.rasterSize(), raster_size, 1.0e-3f) ||
                              ! SizeNearlyEqual(layer.size(), prepared.layout.card, 1.0e-3f) ||
                              ! SizeNearlyEqual(layer.layout().centre, prepared.layout.centre, 1.0e-3f);
    // A continuously changing label can always be ahead of its worker. Publish
    // completed revisions monotonically, keeping the newer request pending.
    if (! layer.ApplyPreparedLayout(prepared.revision, prepared.layout)) return false;

    if (card_changed) {
        const auto node_iterator = m_nodes.find(prepared.name);
        if (node_iterator != m_nodes.end() && node_iterator->second != nullptr &&
            node_iterator->second->Mesh() != nullptr) {
            auto* mesh = node_iterator->second->Mesh();
            const auto drawn = CardMeshBoxOf(*mesh);
            if (! SizeNearlyEqual(drawn.size, raster_size, 1.0f) ||
                ! SizeNearlyEqual(drawn.centre, prepared.layout.centre, 1.0e-3f)) {
                ResizeCardMesh(*mesh, TextLayerRenderBoundsForLayout(prepared.state, prepared.layout));
                if (! mesh->Dynamic()) m_scene_graph_mutated = true;
            }
        }
    }

    if (card_changed) {
        // The card the layer shows: the text's own, or the chain's final card.
        TextLayerRenderFrame card = prepared.render_frame;
        if (const auto effect_iterator = m_node_effect_final.find(prepared.name);
            effect_iterator != m_node_effect_final.end() &&
            effect_iterator->second.node != nullptr &&
            effect_iterator->second.node->Mesh() != nullptr &&
            effect_iterator->second.layer != nullptr) {
            auto& binding = effect_iterator->second;
            // The chain's buffers are the card with the fraction cut off, as Wallpaper Engine
            // builds them again for every layout. A card that is the same number of texels
            // as before (a clock whose digits differ by a fraction, a text that only changed
            // sides) keeps them: the camera and the final card follow it and nothing else
            // is touched. One that is another size asks for the graph that owns the buffers
            // to be built once, however many frames the text takes to settle.
            const auto frame   = TextLayerEffectFrame(prepared.render_frame);
            const bool resized = ! SizeNearlyEqual(frame.size, binding.target_frame.size, 0.5f);
            binding.target_frame = frame;
            auto camera = m_scene->cameras.at(binding.node->Camera());
            camera->SetWidth(frame.size.x());
            camera->SetHeight(frame.size.y());
            camera->GetAttachedNode()->SetTranslate(
                Eigen::Vector3f(frame.center.x(), frame.center.y(), 0.0f));
            camera->Update();
            if (resized) {
                // The first buffer and every buffer sized from it.
                const auto& first = binding.layer->FirstTarget();
                for (auto& [key, target] : m_scene->renderTargets) {
                    if (key != first && (! target.bind.enable || target.bind.name != first))
                        continue;
                    const double scale = key == first ? 1.0 : target.bind.scale;
                    target.width = target.authored_width =
                        std::max(4, static_cast<int32_t>(std::lround(frame.size.x() * scale)));
                    target.height = target.authored_height =
                        std::max(4, static_cast<int32_t>(std::lround(frame.size.y() * scale)));
                }
                m_scene_graph_mutated = true;
            }
            ResizeCardMesh(binding.layer->FinalMesh(), frame.bounds);
            if (auto* resolved = binding.layer->ResolvedFinalRenderNode();
                resolved != nullptr && resolved->Mesh() != nullptr) {
                ResizeCardMesh(*resolved->Mesh(), frame.bounds);
            }
            card = frame;
        }
        if (const auto node_iterator = m_nodes.find(prepared.name);
            node_iterator != m_nodes.end() && node_iterator->second != nullptr) {
            FitTextLayerComposite(*node_iterator->second, card);
        }
    }

    if (card_changed) {
        // The card of an opaque background lies this far in from the raster's edges.
        if (const auto gate = m_text_effect_gates.find(prepared.name);
            gate != m_text_effect_gates.end() && gate->second.card_inset != nullptr) {
            gate->second.card_inset->update(TextCardInsetInRaster(prepared.state, prepared.layout));
        }
    }

    RegisterNodeSize(prepared.name, prepared.layout.card);
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
    // One texel per unit of the card with the fraction cut off, as at parse
    // time: a consumer may place the image by its size (`g_Texture1Resolution`),
    // so stretching a new card over the old target would show the text at
    // another scale. Only a card whose size in texels changed costs a new graph.
    const auto found = m_scene->renderTargets.find(LayerCompositeTargetKey(node.ID()));
    if (found == m_scene->renderTargets.end()) return;
    auto&      target = found->second;
    const auto [width, height] = TextCardTexelExtent(card.size);
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

void SceneRuntimeContext::UnregisterScriptedValue(ScriptedDynamicValue* value) {
    if (value == nullptr) return;
    // Slots are emptied, not erased: a tick that is walking the list keeps its indices.
    std::replace(m_scripted_values.begin(), m_scripted_values.end(), value,
                 static_cast<ScriptedDynamicValue*>(nullptr));
    m_scripted_value_cursor_inside.erase(value);
    for (auto& [button, held] : m_scripted_value_cursor_held) std::erase(held, value);
}

void SceneRuntimeContext::RegisterNode(std::string name, SceneNode* node) {
    if (node == nullptr || name.empty()) return;
    std::string key     = std::move(name);
    if (! m_nodes.contains(key)) {
        m_node_order.push_back(key);
        m_node_rank_valid = false;
    }
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
    m_node_color.erase(key);
    if (m_nodes.erase(key) != 0) {
        std::erase(m_node_order, key);
        m_node_rank_valid = false;
        std::erase_if(m_layer_ids, [&key](const auto& entry) { return entry.second == key; });
    }
    m_node_size.erase(key);
    m_node_hit_masks.erase(key);
    m_node_cursor_targets.erase(key);
    m_puppet_layers.erase(key);
    m_text_layers.erase(key);
    m_text_effect_gates.erase(key);
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
    m_layer_authored_names.erase(key);
    m_queued_text_revisions.erase(key);
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
    // Back where the layer stood in the scene's order.
    if (previous->has_node) {
        const auto position = std::min(previous->order_index, m_node_order.size());
        m_node_order.insert(m_node_order.begin() + static_cast<std::ptrdiff_t>(position), key);
        m_node_rank_valid = false;
    }

    m_material_constants.resize(previous->material_constants_size);
    m_material_alpha.resize(previous->material_alpha_size);
    m_material_colors.resize(previous->material_colors_size);
    m_scalar_animations.resize(previous->scalar_animations_size);
    for (std::size_t index = previous->dynamic_value_listeners_size;
         index < m_dynamic_value_listeners.size(); ++index) {
        auto& binding = m_dynamic_value_listeners[index];
        if (binding.deregister) binding.deregister();
    }
    m_dynamic_value_listeners.resize(previous->dynamic_value_listeners_size);

    for (std::size_t index = previous->scripted_values_size; index < m_scripted_values.size();
         ++index) {
        // A script that started before its layer was rolled back ends with it.
        if (m_scripted_values[index] != nullptr) m_scripted_values[index]->Destroy();
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
    m_scripted_values_started = std::min(m_scripted_values_started, m_scripted_values.size());
    m_owned_values.resize(previous->owned_values_size);

    if (previous->has_node) m_nodes[key] = previous->node;
    if (previous->visibility.has_value()) m_node_visibility[key] = *previous->visibility;
    if (previous->translate.has_value()) m_node_translate[key] = *previous->translate;
    if (previous->scale.has_value()) m_node_scale[key] = *previous->scale;
    if (previous->rotation.has_value()) m_node_rotation[key] = *previous->rotation;
    if (previous->effect_final.has_value()) m_node_effect_final[key] = *previous->effect_final;
    if (previous->size.has_value()) m_node_size[key] = *previous->size;
    if (previous->hit_mask.has_value()) m_node_hit_masks[key] = *previous->hit_mask;
    if (previous->cursor_target.has_value()) {
        m_node_cursor_targets[key] = *previous->cursor_target;
        if (previous->cursor_target->blocks) m_any_cursor_blocker = true;
    }
    if (previous->puppet_layer.has_value()) m_puppet_layers[key] = *previous->puppet_layer;
    if (previous->text_layer.has_value()) m_text_layers.emplace(key, *previous->text_layer);
    if (previous->text_effect_gate.has_value()) {
        m_text_effect_gates.insert_or_assign(key, *previous->text_effect_gate);
    }
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
        const auto position = std::find(m_node_order.begin(), m_node_order.end(), key);
        snapshot->order_index = static_cast<std::size_t>(position - m_node_order.begin());
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
    if (const auto iterator = m_node_cursor_targets.find(key);
        iterator != m_node_cursor_targets.end()) {
        snapshot->cursor_target = iterator->second;
    }
    if (const auto iterator = m_puppet_layers.find(key); iterator != m_puppet_layers.end()) {
        snapshot->puppet_layer = iterator->second;
    }
    if (const auto iterator = m_text_layers.find(key); iterator != m_text_layers.end()) {
        snapshot->text_layer = iterator->second;
    }
    if (const auto iterator = m_text_effect_gates.find(key); iterator != m_text_effect_gates.end()) {
        snapshot->text_effect_gate = iterator->second;
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
    snapshot->material_colors_size = m_material_colors.size();
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
    // A question about the whole stack, answered before any one layer is named.
    if (operation == "layerCount") return static_cast<double>(puppet->layerCount());
    const i32 index = puppet->findLayer(animation_layer);
    // The stack index of the layer, which a listener is filed under.
    if (operation == "index") return static_cast<double>(index);
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

std::string SceneRuntimeContext::PuppetAnimationLayerName(std::string_view layer_name,
                                                          std::string_view animation_layer) {
    auto* puppet = FindPuppetLayer(layer_name);
    return puppet != nullptr ? puppet->layerName(puppet->findLayer(animation_layer)) : std::string {};
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

void SceneRuntimeContext::RegisterEffectVisibility(std::shared_ptr<SceneImageEffect> effect,
                                                   std::unique_ptr<DynamicValue> value) {
    if (effect == nullptr || value == nullptr) return;
    // The value as the scene loads is what the first graph is built with, so
    // only a later switch asks for a rebuild.
    effect->visible = value->getBool();
    RegisterDynamicValueListener(std::move(value), [this, effect](const DynamicValue& current) {
        const bool visible = current.getBool();
        if (effect->visible == visible) return;
        effect->visible       = visible;
        m_scene_graph_mutated = true;
        // A text layer counts its visible effects: the switch may pad it or take its padding
        // away, and decides whether its glyphs are composited.
        for (const auto& [name, gate] : m_text_effect_gates) {
            if (std::find(gate.effects.begin(), gate.effects.end(), effect) != gate.effects.end()) {
                RefreshTextEffectGate(name);
            }
        }
    });
}

void SceneRuntimeContext::RegisterTextEffectGate(std::string name, TextEffectGate gate) {
    if (name.empty()) return;
    m_text_effect_gates.insert_or_assign(name, std::move(gate));
    RefreshTextEffectGate(name);
}

void SceneRuntimeContext::RefreshTextEffectGate(const std::string& name) {
    const auto gate = m_text_effect_gates.find(name);
    if (gate == m_text_effect_gates.end()) return;
    const bool visible = std::any_of(gate->second.effects.begin(), gate->second.effects.end(),
                                     [](const auto& effect) { return effect->visible; });
    if (const auto layer = m_text_layers.find(name); layer != m_text_layers.end()) {
        layer->second.SetPaddingApplies(gate->second.padded_regardless || visible);
    }
    if (gate->second.composite != nullptr) gate->second.composite->update(visible ? 1.0f : 0.0f);
}

void SceneRuntimeContext::ApplyNodeVec3Animation(NodeVec3Binding& binding) {
    if (binding.animation == nullptr || binding.animation->playback == nullptr) return;
    const double frame = binding.animation->playback->frame;
    if (frame == binding.sampled_animation_frame) return;
    const auto value = binding.animation->Value();
    binding.value->update(Eigen::Vector3f(value[0], value[1], value[2]));
    binding.sampled_animation_frame = frame;
}

void SceneRuntimeContext::ApplyMaterialColorAnimation(MaterialColorBinding& binding) {
    if (binding.animation == nullptr || binding.animation->playback == nullptr) return;
    const double frame = binding.animation->playback->frame;
    if (frame == binding.sampled_animation_frame) return;
    const auto value = binding.animation->Value();
    const Eigen::Vector3f color(value[0], value[1], value[2]);
    for (const auto& weak : binding.materials) {
        if (const auto material = weak.lock()) ApplyMaterialColor(*material, color);
    }
    binding.sampled_animation_frame = frame;
}

void SceneRuntimeContext::RegisterNodeTranslate(std::string name, SceneNode* node,
                                                std::unique_ptr<DynamicValue> value,
                                                std::shared_ptr<const NodeVec3Animation> animation) {
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
    ApplyNodeVec3Animation(binding);
    SetNodeTranslate(name, raw->getVec3());
    RefreshNodeTransformBindings(name);
}

void SceneRuntimeContext::RegisterNodeScale(std::string name, SceneNode* node,
                                            std::unique_ptr<DynamicValue> value,
                                            std::shared_ptr<const NodeVec3Animation> animation) {
    if (node == nullptr || value == nullptr) return;

    RegisterNode(name, node);
    auto* raw = value.get();
    m_owned_values.push_back(std::move(value));
    auto& binding = m_node_scale[name];
    binding = NodeVec3Binding {
        .node  = node,
        .value = raw,
        .animation = std::move(animation),
    };
    ApplyNodeVec3Animation(binding);
    SetNodeScale(name, raw->getVec3());
    RefreshNodeTransformBindings(name);
}

void SceneRuntimeContext::RegisterNodeRotation(std::string name, SceneNode* node,
                                               std::unique_ptr<DynamicValue> value,
                                               std::shared_ptr<const NodeVec3Animation> animation) {
    if (node == nullptr || value == nullptr) return;

    RegisterNode(name, node);
    auto* raw = value.get();
    m_owned_values.push_back(std::move(value));
    auto& binding = m_node_rotation[name];
    binding = NodeVec3Binding {
        .node  = node,
        .value = raw,
        .animation = std::move(animation),
    };
    ApplyNodeVec3Animation(binding);
    node->SetRotation(raw->getVec3());
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

void SceneRuntimeContext::RegisterTextLayer(std::string name, TextLayerState state,
                                            TextLayerLayout layout) {
    if (name.empty()) return;
    if (state.layer_key.empty()) state.layer_key = name;
    auto layer        = TextLayer(std::move(state), std::move(layout));
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

void SceneRuntimeContext::RegisterSceneZoom(std::unique_ptr<DynamicValue> zoom) {
    RegisterDynamicValueListener(std::move(zoom), [this](const DynamicValue& value) {
        ApplySceneZoom(value.getFloat());
    });
}

void SceneRuntimeContext::ApplySceneZoomAnimation() {
    if (m_scene_zoom_animation == nullptr) return;
    ApplySceneZoom(m_scene_zoom_animation->Value());
}

void SceneRuntimeContext::ApplySceneZoom(double zoom) {
    if (m_scene == nullptr) return;
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
    FitCanvasPerspective(perspective, camera);
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

void SceneRuntimeContext::RegisterCameraShake(std::unique_ptr<DynamicValue> enabled,
                                              std::unique_ptr<DynamicValue> amplitude,
                                              std::unique_ptr<DynamicValue> speed,
                                              std::unique_ptr<DynamicValue> roughness) {
    if (enabled == nullptr || amplitude == nullptr || speed == nullptr || roughness == nullptr) {
        return;
    }
    m_camera_shake.registered = true;
    RegisterDynamicValueListener(std::move(enabled), [this](const DynamicValue& value) {
        m_camera_shake.enabled = value.getBool();
    });
    RegisterDynamicValueListener(std::move(amplitude), [this](const DynamicValue& value) {
        m_camera_shake.amplitude = value.getFloat();
    });
    RegisterDynamicValueListener(std::move(speed), [this](const DynamicValue& value) {
        m_camera_shake.speed = value.getFloat();
    });
    RegisterDynamicValueListener(std::move(roughness), [this](const DynamicValue& value) {
        m_camera_shake.roughness = value.getFloat();
    });
}

// Wallpaper Engine's camera shake: t = speed^2 * time, the offset
// (cos t, sin 1.333t, sin t), its length raised to roughness^3 (unless that is
// about 0 or exactly 1), scaled by amplitude / 10, and in a 2D scene by a tenth
// of the canvas height with no depth. The eye and what it looks at move by it
// together.
void SceneRuntimeContext::ApplyCameraShake() {
    if (! m_camera_shake.registered || m_scene == nullptr || m_scene->activeCamera == nullptr) {
        return;
    }
    auto& camera = *m_scene->activeCamera;
    if (! m_camera_shake.enabled) {
        camera.SetShakeOffset(Eigen::Vector3d::Zero());
        return;
    }
    const double t =
        double(m_camera_shake.speed) * m_camera_shake.speed * m_host_context->runtime_seconds;
    Eigen::Vector3d offset(std::cos(t), std::sin(t * 1.333), std::sin(t));
    double amplitude = m_camera_shake.amplitude * 0.1;
    if (! camera.IsPerspective()) {
        offset.z() = 0.0;
        amplitude *= m_scene->ortho[1] * 0.1;
    }
    const double roughness = std::pow(double(m_camera_shake.roughness), 3.0);
    const double length    = offset.norm();
    if (roughness > 0.001 && roughness != 1.0 && length > 0.0) {
        offset *= std::pow(length, roughness) / length;
    }
    camera.SetShakeOffset(offset * amplitude);
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
                                                  TextLayerRenderFrame target_frame,
                                                  std::shared_ptr<PassthroughCard> passthrough_card) {
    if (node == nullptr || layer == nullptr) return;
    if (const auto iterator = m_nodes.find(name);
        iterator == m_nodes.end() || iterator->second != node) {
        RegisterNode(name, node);
    }
    m_node_effect_final[std::move(name)] = NodeEffectFinalBinding {
        .node             = node,
        .layer            = layer,
        .target_frame     = target_frame,
        .passthrough_card = std::move(passthrough_card),
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

void SceneRuntimeContext::BindMaterialColor(std::string layer_name,
                                            std::vector<std::shared_ptr<SceneMaterial>> materials,
                                            std::unique_ptr<DynamicValue> value) {
    if (materials.empty() || value == nullptr) return;
    if (! layer_name.empty()) m_node_color[std::move(layer_name)] = value.get();
    RegisterDynamicValueListener(
        std::move(value), [materials = std::move(materials)](const DynamicValue& current) {
            const auto color = current.getVec3();
            for (const auto& material : materials) {
                if (material != nullptr) ApplyMaterialColor(*material, color);
            }
        });
}

void SceneRuntimeContext::BindMaterialBrightness(
    std::vector<std::shared_ptr<SceneMaterial>> materials, std::unique_ptr<DynamicValue> value) {
    if (value == nullptr) return;
    // A brightness nothing draws with (outside an HDR scene) is still the runtime's
    // to keep: a script drives it.
    if (materials.empty()) {
        m_owned_values.push_back(std::move(value));
        return;
    }
    RegisterDynamicValueListener(
        std::move(value), [materials = std::move(materials)](const DynamicValue& current) {
            const float brightness = current.getFloat();
            if (! std::isfinite(brightness)) return;
            for (const auto& material : materials) {
                if (material != nullptr) ApplyMaterialBrightness(*material, brightness);
            }
        });
}

void SceneRuntimeContext::RegisterMaterialColorAnimation(
    std::vector<std::shared_ptr<SceneMaterial>> materials,
    std::shared_ptr<const NodeVec3Animation> animation) {
    if (materials.empty() || animation == nullptr) return;
    MaterialColorBinding binding;
    for (const auto& material : materials) {
        if (material != nullptr) binding.materials.push_back(material);
    }
    binding.animation = std::move(animation);
    ApplyMaterialColorAnimation(binding);
    m_material_colors.push_back(std::move(binding));
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

uint64_t SceneRuntimeContext::RegisterPropertyAnimation(
    std::shared_ptr<ScalarAnimationPlayback> playback) {
    m_property_animations.push_back(std::move(playback));
    return m_property_animations.size();
}

ScalarAnimationPlayback* SceneRuntimeContext::FindPropertyAnimation(uint64_t handle) const {
    if (handle == 0 || handle > m_property_animations.size()) return nullptr;
    // The timeline is held by `m_scalar_animations`, which a rolled-back layer
    // load may shorten; a handle to one that went finds nothing.
    return m_property_animations[handle - 1].lock().get();
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

    if (m_camera_shake.registered && m_camera_shake.enabled && m_camera_shake.amplitude != 0.0f &&
        m_camera_shake.speed != 0.0f) {
        reasons |= SceneDemandReason::Animation;
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
    // mirrors a node onto its effect layer's final node, and lays a pass-through
    // card out again, so it moves when the node it mirrors moves and never on
    // its own.
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

namespace
{
// Every node at or below `root`, `root` first.
std::vector<SceneNode*> SubtreeOf(SceneNode& root) {
    std::vector<SceneNode*> nodes { &root };
    for (std::size_t next = 0; next < nodes.size(); ++next) {
        for (const auto& child : nodes[next]->GetChildren()) nodes.push_back(child.get());
    }
    return nodes;
}
} // namespace

bool SceneRuntimeContext::DestroyLayer(std::string_view name, std::vector<std::string>* destroyed) {
    const auto created = m_script_created_layers.find(std::string(name));
    if (created == m_script_created_layers.end()) return false;
    const std::string key = *created;

    const auto registered = m_nodes.find(key);
    SceneNode* node       = registered != m_nodes.end() ? registered->second : nullptr;

    // The layer and every layer registered below it: the nodes under this one
    // are freed with it, so nothing may keep pointing at them.
    std::vector<std::string> doomed { key };
    if (node != nullptr && ! node->GetChildren().empty()) {
        const auto                                 subtree = SubtreeOf(*node);
        const std::unordered_set<const SceneNode*> below(subtree.begin() + 1, subtree.end());
        for (const auto& [layer_name, layer_node] : m_nodes) {
            if (layer_name != key && below.contains(layer_node)) doomed.push_back(layer_name);
        }
    }
    for (const auto& layer_name : doomed) {
        m_script_created_layers.erase(layer_name);
        // The name a script gave the layer goes with it.
        std::erase_if(m_layer_aliases,
                      [&layer_name](const auto& alias) { return alias.second == layer_name; });
        if (m_text_layers.contains(layer_name)) {
            m_retired_text_textures.push_back(TextTextureName(layer_name));
        }
        UnregisterNode(layer_name);
        if (destroyed != nullptr) destroyed->push_back(layer_name);
    }
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
    if ((m_retired_layers.empty() && m_retired_text_textures.empty()) || m_scene_graph_mutated) {
        return;
    }
    // Their copies of the template's material bindings write to materials
    // nothing draws any more. A retired layer takes the layers below it along,
    // and each of those is forgotten too.
    std::unordered_set<const SceneMaterial*> materials;
    for (const auto& top : m_retired_layers) {
        for (SceneNode* node : SubtreeOf(*top)) {
            if (node->Mesh() != nullptr && node->Mesh()->MaterialSlotPtr() != nullptr) {
                materials.insert(node->Mesh()->MaterialSlotPtr().get());
            }
            if (m_scene != nullptr && m_scene->shaderValueUpdater != nullptr) {
                m_scene->shaderValueUpdater->ForgetNode(node);
            }
        }
    }
    std::erase_if(m_material_constants, [&materials](const MaterialConstantBinding& binding) {
        const auto material = binding.material.lock();
        return material != nullptr && materials.contains(material.get());
    });
    // The rasters of text layers that no longer exist.
    if (m_scene != nullptr) {
        auto* runtime_images = dynamic_cast<RuntimeImageSource*>(m_scene->imageParser.get());
        for (const auto& texture : m_retired_text_textures) {
            m_scene->textures.erase(texture);
            if (runtime_images != nullptr) runtime_images->RemoveImage(texture);
        }
    }
    m_retired_text_textures.clear();
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
    // A colour bound to a property or a script takes what a script writes as
    // its value, as a script's visibility and origin writes do: the next
    // evaluation continues from it, where an `update()` that returns nothing
    // would otherwise put the old value straight back, and every material
    // that takes the layer's colour follows, not only the layer's own.
    if (const auto binding = m_node_color.find(std::string(name));
        binding != m_node_color.end() && binding->second != nullptr) {
        binding->second->update(color);
    }
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

void SceneRuntimeContext::RegisterNodeAlpha(
    std::string name, std::vector<std::shared_ptr<SceneMaterial>> materials, float value) {
    std::erase(materials, nullptr);
    if (name.empty() || materials.empty()) return;
    m_node_alpha[std::move(name)] = NodeAlphaBinding { .materials = std::move(materials),
                                                       .value     = value };
}

void SceneRuntimeContext::RegisterNodeAlpha(std::string name,
                                            std::shared_ptr<SceneMaterial> material, float value) {
    RegisterNodeAlpha(std::move(name),
                      std::vector<std::shared_ptr<SceneMaterial>> { std::move(material) }, value);
}

std::optional<float> SceneRuntimeContext::NodeAlpha(std::string_view name) const {
    const auto iterator = m_node_alpha.find(std::string(name));
    if (iterator == m_node_alpha.end()) return std::nullopt;
    return iterator->second.value;
}

bool SceneRuntimeContext::SetNodeAlpha(std::string_view name, float value) {
    const auto iterator = m_node_alpha.find(std::string(name));
    if (iterator == m_node_alpha.end()) return false;
    if (iterator->second.value == value) return true;
    iterator->second.value = value;
    for (const auto& material : iterator->second.materials) ApplyMaterialAlpha(*material, value);
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
    // A text object has no `alignment` (its `horizontalalign` and `verticalalign` hang its
    // card from its origin), so there is nothing to set; anchoring it here would shift the
    // node by half its card.
    if (m_text_layers.contains(std::string(name))) return false;

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

bool SceneRuntimeContext::SetNodeScreenAnchor(std::string_view name, TextScreenAnchor anchor) {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) return false;

    auto& binding = m_node_alignment[std::string(name)];
    binding.screen_anchor   = anchor;
    binding.screen_offset   = TextScreenAnchorOffset(anchor, m_presented_margins);
    binding.transform_dirty = true;
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

Eigen::Matrix4d SceneRuntimeContext::NodeTransformMatrix(std::string_view name) const {
    const auto iterator = m_nodes.find(std::string(name));
    if (iterator == m_nodes.end() || iterator->second == nullptr) {
        return Eigen::Matrix4d::Identity();
    }
    // The node's own matrix, not the one it is drawn with: a layer drawn
    // through its effects renders from an identity of its own and a camera
    // parallax moves only the copy the shader reads.
    iterator->second->UpdateTrans();
    return iterator->second->ModelTrans();
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

Eigen::Vector2f SceneRuntimeContext::NodeBoxCentre(std::string_view name) const {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return Eigen::Vector2f::Zero();
    return iterator->second.layout().centre;
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

std::optional<TextLayerLayout> SceneRuntimeContext::NodeTextLayout(std::string_view name) const {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return std::nullopt;
    return iterator->second.layout();
}

bool SceneRuntimeContext::SetNodeText(std::string_view name, std::string text) {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return false;
    if (m_own_text_write != nullptr) {
        const auto bound = std::any_of(
            m_text_values.begin(), m_text_values.end(), [&](const TextValueBinding& binding) {
                return binding.value == &m_own_text_write->m_owner && binding.name == name;
            });
        if (bound) m_own_text_write->m_written = text;
    }
    if (iterator->second.text() == text) return true;

    iterator->second.SetText(std::move(text));
    return true;
}

SceneRuntimeContext::OwnTextWrite::OwnTextWrite(SceneRuntimeContext& runtime,
                                                const DynamicValue&  owner) noexcept
    : m_runtime(runtime), m_owner(owner), m_outer(runtime.m_own_text_write) {
    runtime.m_own_text_write = this;
}

SceneRuntimeContext::OwnTextWrite::~OwnTextWrite() {
    m_runtime.m_own_text_write = m_outer;
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
    return NodeTextureAnimationFrame(name);
}

double SceneRuntimeContext::NodeTextureAnimationFrame(std::string_view name) const {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return 0.0;
    // The frame a script pinned, else the one the renderer last drew.
    return it->second->TextureFrame().value_or(it->second->TextureAnimationFrame().value_or(0.0));
}

namespace
{
// The sprite sheet a layer draws: the first texture of its material that is one.
const SceneTexture* SpriteSheetOf(const Scene* scene, SceneNode& node, std::string* key) {
    if (scene == nullptr || node.Mesh() == nullptr) return nullptr;
    const auto* material = node.Mesh()->Material();
    if (material == nullptr) return nullptr;
    for (const auto& texture : material->textures) {
        const auto found = scene->textures.find(texture);
        if (found == scene->textures.end() || found->second.spriteAnim.numFrames() == 0) continue;
        if (key != nullptr) *key = texture;
        return &found->second;
    }
    return nullptr;
}
} // namespace

std::optional<SceneRuntimeContext::TextureAnimationInfo>
SceneRuntimeContext::NodeTextureAnimation(std::string_view name) const {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return std::nullopt;
    TextureAnimationInfo info;
    const auto* sheet = SpriteSheetOf(m_scene, *it->second, &info.name);
    if (sheet == nullptr) return std::nullopt;
    info.frame_count = sheet->spriteAnim.numFrames();
    for (std::size_t frame = 0; frame < info.frame_count; ++frame) {
        const float frametime = sheet->spriteAnim.FrameAt(frame).frametime;
        if (std::isfinite(frametime) && frametime > 0.0f) info.duration += frametime;
    }
    info.fps = info.duration > 0.0 ? static_cast<double>(info.frame_count) / info.duration : 0.0;
    return info;
}

bool SceneRuntimeContext::PlayNodeTextureAnimation(std::string_view name) {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return false;
    // The sheet runs on from the frame it was left on, a pinned one included.
    it->second->ClearTextureFrame();
    it->second->SetTextureAnimationPaused(false);
    return true;
}

bool SceneRuntimeContext::PauseNodeTextureAnimation(std::string_view name) {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return false;
    it->second->SetTextureAnimationPaused(true);
    return true;
}

bool SceneRuntimeContext::StopNodeTextureAnimation(std::string_view name) {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return false;
    it->second->SetTextureAnimationPaused(true);
    it->second->SetTextureFrame(0.0);
    return true;
}

bool SceneRuntimeContext::NodeTextureAnimationPlaying(std::string_view name) const {
    const auto it = m_nodes.find(std::string(name));
    return it != m_nodes.end() && it->second != nullptr && ! it->second->TextureAnimationPaused() &&
           ! it->second->TextureFrame().has_value();
}

bool SceneRuntimeContext::SetNodeTextureAnimationRate(std::string_view name, double rate) {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr || ! std::isfinite(rate)) return false;
    it->second->SetTextureAnimationRate(rate);
    return true;
}

double SceneRuntimeContext::NodeTextureAnimationRate(std::string_view name) const {
    const auto it = m_nodes.find(std::string(name));
    return it != m_nodes.end() && it->second != nullptr ? it->second->TextureAnimationRate() : 1.0;
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
    // A screen anchor moves where the layer is drawn and nothing else: the node, which its
    // children are placed from and a script reads the origin of, stays where the scene
    // put it.
    node.SetDrawOffset(Eigen::Vector3f(binding.screen_offset.x(), binding.screen_offset.y(), 0.0f));
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
    const auto& cursor = m_cursor_plane_position;
    return cursor.x() >= origin.x() && cursor.x() <= origin.x() + size.x() &&
           cursor.y() >= origin.y() && cursor.y() <= origin.y() + size.y();
}

void SceneRuntimeContext::SetNodeCursorTarget(std::string_view name, bool hittable, bool solid,
                                              bool disable_propagation) {
    if (name.empty()) return;
    m_node_cursor_targets[std::string(name)] = NodeCursorTarget {
        .hittable = hittable, .solid = solid, .blocks = disable_propagation,
    };
    if (disable_propagation) m_any_cursor_blocker = true;
}

std::optional<SceneRuntimeContext::NodeCursorTarget>
SceneRuntimeContext::NodeCursorTargetOf(std::string_view name) const {
    const auto target = m_node_cursor_targets.find(name);
    if (target == m_node_cursor_targets.end()) return std::nullopt;
    return target->second;
}

// Whether the cursor is over the layer's own rectangle. Wallpaper Engine tests
// nothing but that quad; a layer a script handles the cursor for also answers
// to its coverage mask, so a cut-out layer is only hit where it is drawn.
bool SceneRuntimeContext::CursorHitsLayerGeometry(std::string_view name) const {
    const std::string key(name);
    const auto        node_iterator = m_nodes.find(key);
    if (node_iterator == m_nodes.end() || node_iterator->second == nullptr) return false;
    const auto         mask_iterator = m_node_hit_masks.find(key);
    const NodeHitMask* mask =
        mask_iterator == m_node_hit_masks.end() ? nullptr : &mask_iterator->second;
    const SceneCamera* camera =
        m_scene != nullptr ? CameraForHitNode(*m_scene, *node_iterator->second) : nullptr;
    const Eigen::Vector2d ndc = CursorWorldToNdc(m_cursor_viewport, m_cursor_plane_position);
    return HitTestNode(*node_iterator->second,
                       NodeSize(name),
                       NodeBoxCentre(name),
                       m_cursor_plane_position,
                       mask,
                       camera,
                       ndc);
}

std::optional<std::size_t> SceneRuntimeContext::NodeRank(std::string_view name) const {
    if (! m_node_rank_valid) {
        m_node_rank.clear();
        for (std::size_t rank = 0; rank < m_node_order.size(); ++rank) {
            m_node_rank.emplace(m_node_order[rank], rank);
        }
        m_node_rank_valid = true;
    }
    const auto found = m_node_rank.find(name);
    if (found == m_node_rank.end()) return std::nullopt;
    return found->second;
}

// Wallpaper Engine walks the layers from the front. A visible layer under the
// cursor that sets `disablepropagation` ends the walk there, so nothing behind
// it is visited, whether or not anything in front of it handles the cursor.
// The frontmost such layer is found once for the frame's cursor events; a layer
// is then out of the walk when it stands behind it.
std::optional<std::size_t> SceneRuntimeContext::FrontmostCursorBlocker() const {
    if (m_cursor_blocker_cached) return m_cursor_blocker_rank;
    m_cursor_blocker_cached = true;
    m_cursor_blocker_rank.reset();
    for (std::size_t rank = m_node_order.size(); rank-- > 0;) {
        const std::string& name   = m_node_order[rank];
        const auto         target = m_node_cursor_targets.find(std::string_view(name));
        if (target == m_node_cursor_targets.end() || ! target->second.blocks ||
            ! target->second.hittable || ! target->second.solid) {
            continue;
        }
        const auto node = m_nodes.find(name);
        if (node == m_nodes.end() || node->second == nullptr || ! node->second->EffectiveVisible()) {
            continue;
        }
        if (CursorHitsLayerGeometry(name)) {
            m_cursor_blocker_rank = rank;
            break;
        }
    }
    return m_cursor_blocker_rank;
}

bool SceneRuntimeContext::CursorBlockedByLayerInFront(std::string_view name) const {
    if (! m_any_cursor_blocker) return false;
    const auto blocker = FrontmostCursorBlocker();
    if (! blocker.has_value()) return false;
    const auto own = NodeRank(name);
    return own.has_value() && *own < *blocker;
}

SceneRuntimeContext::CursorVisit SceneRuntimeContext::VisitCursorLayer(std::string_view name) const {
    // A script of the scene itself, rather than of a layer, hears the cursor
    // wherever it is.
    if (name.empty()) return CursorVisit::Inside;
    if (! CursorInsidePresentedContent()) return CursorVisit::Outside;
    // Layers that are not solid, and objects of any kind but image, text and
    // model, are not tested for the cursor at all.
    if (const auto target = m_node_cursor_targets.find(name);
        target != m_node_cursor_targets.end() &&
        (! target->second.hittable || ! target->second.solid)) {
        return CursorVisit::Outside;
    }
    if (CursorBlockedByLayerInFront(name)) return CursorVisit::Skipped;
    return CursorHitsLayerGeometry(name) ? CursorVisit::Inside : CursorVisit::Outside;
}

bool SceneRuntimeContext::CursorHitsLayer(std::string_view name) const {
    return VisitCursorLayer(name) == CursorVisit::Inside;
}

bool SceneRuntimeContext::CursorHitsScriptLayer(const ScriptedDynamicValue& value) const {
    return CursorHitsLayer(value.LayerName());
}

bool SceneRuntimeContext::CursorHitsScriptLayer(const SceneScriptProgram& script) const {
    return CursorHitsLayer(script.LayerName());
}

SceneRuntimeContext::CursorVisit
SceneRuntimeContext::VisitScriptLayer(const ScriptedDynamicValue& value) const {
    return VisitCursorLayer(value.LayerName());
}

SceneRuntimeContext::CursorVisit
SceneRuntimeContext::VisitScriptLayer(const SceneScriptProgram& script) const {
    return VisitCursorLayer(script.LayerName());
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
    // The frontmost blocker is found once for the frame. A callback may move or
    // hide layers, so what it found is dropped whenever one has run.
    m_cursor_blocker_cached = false;
    const auto fired = [this] { m_cursor_blocker_cached = false; };
    if (cursor_in_window && ! cursor_was_in_window) {
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value != nullptr && (value->CursorHandlerMask() & hover_mask) != 0 &&
                CursorHitsScriptLayer(*value)) {
                value->DispatchCursorEnter(*m_host_context);
                fired();
                m_scripted_value_cursor_inside[value] = true;
            }
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr) continue;
            m_scene_scripts[index].cursor_inside = CursorHitsScriptLayer(*script);
            if (m_scene_scripts[index].cursor_inside) {
                script->DispatchCursorEnter(*m_host_context);
                fired();
            }
        }
    } else if (! cursor_in_window && cursor_was_in_window) {
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr || (value->CursorHandlerMask() & hover_mask) == 0) continue;
            if (m_scripted_value_cursor_inside[value]) {
                value->DispatchCursorLeave(*m_host_context);
                fired();
            }
            m_scripted_value_cursor_inside[value] = false;
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr) continue;
            if (m_scene_scripts[index].cursor_inside) {
                script->DispatchCursorLeave(*m_host_context);
                fired();
            }
            m_scene_scripts[index].cursor_inside = false;
        }
    }

    if (cursor_in_window) {
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr || (value->CursorHandlerMask() & hover_mask) == 0) continue;
            const auto visit = VisitScriptLayer(*value);
            // A layer the walk never reached hears nothing and stays as it was.
            if (visit == CursorVisit::Skipped) continue;
            const bool now_inside = visit == CursorVisit::Inside;
            bool&      was_inside = m_scripted_value_cursor_inside[value];
            if (now_inside != was_inside) {
                if (now_inside) {
                    value->DispatchCursorEnter(*m_host_context);
                    fired();
                } else {
                    value->DispatchCursorLeave(*m_host_context);
                    fired();
                }
                was_inside = now_inside;
            }
            if (now_inside) {
                value->DispatchCursorMove(*m_host_context);
                fired();
            }
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script == nullptr) continue;
            const auto visit = VisitScriptLayer(*script);
            if (visit == CursorVisit::Skipped) continue;
            const bool now_inside = visit == CursorVisit::Inside;
            if (now_inside != m_scene_scripts[index].cursor_inside) {
                if (now_inside) {
                    script->DispatchCursorEnter(*m_host_context);
                    fired();
                } else {
                    script->DispatchCursorLeave(*m_host_context);
                    fired();
                }
                m_scene_scripts[index].cursor_inside = now_inside;
            }
            if (now_inside) {
                script->DispatchCursorMove(*m_host_context);
                fired();
            }
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
                fired();
                value->DispatchCursorClick(*m_host_context);
                fired();
                held_values.push_back(value);
            }
            for (std::size_t index = 0; index < script_count; ++index) {
                auto* script = m_scene_scripts[index].script.get();
                if (script == nullptr || ! CursorHitsScriptLayer(*script)) continue;
                script->DispatchCursorDown(*m_host_context);
                fired();
                script->DispatchCursorClick(*m_host_context);
                fired();
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
                fired();
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
                fired();
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
    if (m_media_idle_pending) NoteMediaEventTold(event_json);
    ForEachEventScript([&](auto* script) { script->DispatchMediaEventJson(event_json); });
}

void SceneRuntimeContext::NoteMediaEventTold(std::string_view event_json) {
    const auto parsed = nlohmann::json::parse(event_json, nullptr, false);
    if (! parsed.is_object()) return;
    const auto type = parsed.find("type");
    if (type == parsed.end() || ! type->is_string()) return;
    const auto& name = type->get_ref<const std::string&>();
    if (name == "mediaPlaybackChanged") m_media_playback_told = true;
    if (name == "mediaPropertiesChanged") m_media_properties_told = true;
}

// A scene starts in the state of a desktop with no player: no track and
// `PLAYBACK_STOPPED`. Media widgets are authored visible and hide themselves on
// that state, so a scene that was never told it would show every one of them,
// covers and mascots included, whenever media integration is off (the app's
// default) or no player runs. The state is the same one the app sends with
// integration on and nothing playing, and it names no one's music, so it does
// not wait for the user's consent: what a player really reports still does.
// Only the first tick says it, and only what no real event said before it.
void SceneRuntimeContext::DispatchIdleMediaState() {
    if (! m_media_idle_pending) return;
    m_media_idle_pending = false;
    constexpr std::string_view kIdleProperties =
        R"({"type":"mediaPropertiesChanged","title":"","artist":"","subTitle":"",)"
        R"("albumTitle":"","albumArtist":"","genres":"","contentType":"music"})";
    constexpr std::string_view kIdlePlayback = R"({"type":"mediaPlaybackChanged","state":0})";
    // In the order a relay with no player sends them.
    if (! m_media_properties_told) {
        ForEachEventScript([&](auto* script) { script->DispatchMediaEventJson(kIdleProperties); });
    }
    if (! m_media_playback_told) {
        ForEachEventScript([&](auto* script) { script->DispatchMediaEventJson(kIdlePlayback); });
    }
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

// ---------------------------------------------------------------------------
// Layers as scripts enumerate and address them.
// ---------------------------------------------------------------------------

namespace
{
// A template a script's `createLayer` copies from is loaded as a hidden layer
// of this name. It is never part of the scene.
bool IsHiddenTemplateName(const std::string& name) { return name.starts_with("__template:"); }
} // namespace

std::size_t SceneRuntimeContext::LayerCount() const {
    return static_cast<std::size_t>(std::count_if(
        m_node_order.begin(), m_node_order.end(),
        [](const std::string& name) { return ! IsHiddenTemplateName(name); }));
}

std::string SceneRuntimeContext::LayerNameAt(std::size_t index) const {
    for (const auto& name : m_node_order) {
        if (IsHiddenTemplateName(name)) continue;
        if (index-- == 0) return name;
    }
    return {};
}

int SceneRuntimeContext::LayerIndex(std::string_view name) const {
    const std::string key = ResolveLayerName(name);
    if (! m_nodes.contains(key) || IsHiddenTemplateName(key)) return -1;
    int index = 0;
    for (const auto& entry : m_node_order) {
        if (IsHiddenTemplateName(entry)) continue;
        if (entry == key) return index;
        ++index;
    }
    return -1;
}

bool SceneRuntimeContext::SortLayer(std::string_view name, int index) {
    const std::string key   = ResolveLayerName(name);
    const auto        found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr || IsHiddenTemplateName(key)) {
        return false;
    }

    bool      changed = false;
    const int current = LayerIndex(key);
    if (current < 0) return false;
    const int target = std::clamp(index, 0, std::max(0, static_cast<int>(LayerCount()) - 1));
    if (target != current) {
        // The layer ends up at `target`: before the one that stood there when it
        // moves toward the front, after it when it moves toward the back.
        const std::string anchor = LayerNameAt(static_cast<std::size_t>(target));
        std::erase(m_node_order, key);
        auto place = std::find(m_node_order.begin(), m_node_order.end(), anchor);
        if (target > current && place != m_node_order.end()) ++place;
        m_node_order.insert(place, key);
        changed = true;
    }

    // Draw order is the order among siblings. The layer goes right after the
    // nearest sibling that now precedes it in the layer order, or, with none,
    // right before the nearest one that follows. Siblings that are not layers
    // have no place in that order and stay where they are.
    SceneNode* node   = found->second;
    SceneNode* parent = node->Parent();
    if (parent == nullptr) return changed;
    const auto mine = static_cast<std::size_t>(
        std::find(m_node_order.begin(), m_node_order.end(), key) - m_node_order.begin());
    const SceneNode* earlier = nullptr;
    const SceneNode* later   = nullptr;
    for (std::size_t position = 0; position < m_node_order.size(); ++position) {
        const auto entry = m_nodes.find(m_node_order[position]);
        if (entry == m_nodes.end() || entry->second == nullptr || entry->second == node ||
            entry->second->Parent() != parent) {
            continue;
        }
        if (position < mine) {
            earlier = entry->second;
        } else if (later == nullptr) {
            later = entry->second;
        }
    }
    auto&      siblings = parent->GetChildren();
    const auto index_without_node = [&](const SceneNode* mate) {
        int at = 0;
        for (const auto& child : siblings) {
            if (child.get() == node) continue;
            if (child.get() == mate) return at;
            ++at;
        }
        return -1;
    };
    int desired = -1;
    if (earlier != nullptr) {
        const int at = index_without_node(earlier);
        if (at >= 0) desired = at + 1;
    } else if (later != nullptr) {
        desired = index_without_node(later);
    }
    if (desired >= 0 && SortNodeInList(siblings, node, desired)) {
        m_scene_graph_mutated = true;
        changed               = true;
    }
    return changed;
}

void SceneRuntimeContext::RegisterLayerAuthoredName(std::string runtime_name,
                                                    std::string authored_name) {
    // The parser records names before it builds the layers: a script compiles
    // as its layer is built and may read its own name then.
    if (runtime_name.empty()) return;
    m_layer_authored_names.insert_or_assign(std::move(runtime_name), std::move(authored_name));
}

std::string SceneRuntimeContext::LayerAuthoredName(std::string_view runtime_name) const {
    const auto found = m_layer_authored_names.find(std::string(runtime_name));
    return found != m_layer_authored_names.end() ? found->second : std::string(runtime_name);
}

void SceneRuntimeContext::SetLayerOrder(const std::vector<std::string>& names) {
    std::vector<std::string>        order;
    std::unordered_set<std::string> placed;
    order.reserve(m_node_order.size());
    for (const auto& name : names) {
        if (m_nodes.contains(name) && placed.insert(name).second) order.push_back(name);
    }
    for (const auto& name : m_node_order) {
        if (placed.insert(name).second) order.push_back(name);
    }
    m_node_order      = std::move(order);
    m_node_rank_valid = false;
}

void SceneRuntimeContext::RegisterLayerId(int32_t id, std::string name) {
    if (id == 0 || name.empty() || ! m_nodes.contains(name)) return;
    m_layer_ids.insert_or_assign(id, std::move(name));
}

std::string SceneRuntimeContext::LayerNameForId(int32_t id) const {
    const auto found = m_layer_ids.find(id);
    return found != m_layer_ids.end() && m_nodes.contains(found->second) ? found->second
                                                                          : std::string {};
}

void SceneRuntimeContext::RequestInitialLayerConfig() { m_initial_layer_config_requested = true; }

bool SceneRuntimeContext::InitialLayerConfigRequested() const {
    return m_initial_layer_config_requested;
}

void SceneRuntimeContext::SetInitialLayerConfigProvider(InitialLayerConfigProvider provider) {
    m_initial_layer_config_provider = std::move(provider);
}

std::string SceneRuntimeContext::InitialLayerConfigJson(std::string_view name) const {
    if (! m_initial_layer_config_provider) return {};
    const std::string key = ResolveLayerName(name);
    for (const auto& [id, layer] : m_layer_ids) {
        if (layer == key) return m_initial_layer_config_provider(id);
    }
    return {};
}

// ---------------------------------------------------------------------------
// Puppet animation layers: `addEndedCallback`.
// ---------------------------------------------------------------------------

void SceneRuntimeContext::DispatchPuppetLayerEvents() {
    if (m_puppet_layers.empty()) return;
    // A puppet nobody listens to is still drained, so its record stays small.
    std::vector<std::pair<std::string, i32>> ended;
    for (auto& [name, layer] : m_puppet_layers) {
        for (const i32 index : layer.takeFinishedLayers()) ended.emplace_back(name, index);
    }
    if (m_scripted_values.empty() && m_scene_scripts.empty()) return;
    // After collecting: a listener may play the layer again or create layers.
    for (const auto& [name, index] : ended) {
        m_script_engine->NotifyAnimationLayerEnded(*m_host_context, name, index);
    }
}

// ---------------------------------------------------------------------------
// Text layers: style a script changes, and layers a script creates.
// ---------------------------------------------------------------------------

namespace
{
// The fewest digits (at least six) that read back as the very same float, so a
// script that reads the size, adds a little and writes it again loses nothing.
std::string FormatPointSize(float value) {
    char buffer[32];
    for (int digits = 6; digits <= 9; ++digits) {
        std::snprintf(buffer, sizeof(buffer), "%.*g", digits, static_cast<double>(value));
        if (std::strtof(buffer, nullptr) == value) break;
    }
    return buffer;
}

// What `horizontalalign` and `verticalalign` may be set to: Wallpaper Engine
// registers them as enumerations, so anything else is not an alignment. (Whether
// its script setter turns a bad word away, or reads it as the scene file's reader
// does -- as the registry's first entry -- is not known.)
bool IsAlignmentWord(bool horizontal, std::string_view value) {
    return horizontal ? value == "left" || value == "center" || value == "right"
                      : value == "top" || value == "center" || value == "bottom";
}
} // namespace

std::optional<std::string> SceneRuntimeContext::NodeTextStyle(std::string_view name,
                                                              std::string_view property) const {
    const auto layer = m_text_layers.find(std::string(name));
    if (layer == m_text_layers.end()) return std::nullopt;
    const auto& state = layer->second.state();
    if (property == "font") return state.font_key;
    if (property == "pointsize") return FormatPointSize(state.point_size);
    if (property == "horizontalalign") {
        return std::string(TextHorizontalAlignWord(ParseTextHorizontalAlign(state.horizontal_align)));
    }
    if (property == "verticalalign") {
        return std::string(TextVerticalAlignWord(ParseTextVerticalAlign(state.vertical_align)));
    }
    return std::nullopt;
}

bool SceneRuntimeContext::SetNodeTextStyle(std::string_view name, std::string_view property,
                                           std::string_view value) {
    const std::string key(name);
    const auto        layer = m_text_layers.find(key);
    if (layer == m_text_layers.end()) return false;
    if (property == "pointsize") {
        char*       end    = nullptr;
        const std::string text(value);
        const float parsed = std::strtof(text.c_str(), &end);
        if (end == text.c_str() || ! std::isfinite(parsed) || parsed <= 0.0f) return false;
        layer->second.SetPointSize(parsed);
        return true;
    }
    if (property == "font") {
        TextLayerState resolved = layer->second.state();
        if (m_text_font_resolver) {
            m_text_font_resolver(resolved, std::string(value));
        } else {
            // No wallpaper files to look in: one of Wallpaper Engine's font keys, or Arial.
            const auto face = ResolveSceneFont(value);
            resolved.resolved_font_kind     = "system";
            resolved.resolved_font_identity = std::string(value);
            resolved.resolved_font_path     = face.path;
            resolved.resolved_font_face     = face.postscript_name;
            resolved.resolved_font_fit      = face.fit;
            resolved.resolved_font_data     = SharedFontData {};
        }
        layer->second.SetFont(std::string(value), resolved.resolved_font_kind,
                              resolved.resolved_font_identity, resolved.resolved_font_path,
                              resolved.resolved_font_face, resolved.resolved_font_fit,
                              resolved.resolved_font_data);
        return true;
    }
    if (property == "horizontalalign" || property == "verticalalign") {
        const bool  horizontal = property == "horizontalalign";
        if (! IsAlignmentWord(horizontal, value)) return false;
        const auto& state      = layer->second.state();
        std::string h          = state.horizontal_align;
        std::string v          = state.vertical_align;
        (horizontal ? h : v)   = std::string(value);
        // The layout that follows moves the card about the layer's origin; the node stays.
        layer->second.SetAlignment(std::move(h), std::move(v));
        return true;
    }
    return false;
}

void SceneRuntimeContext::SetTextFontResolver(TextFontResolver resolver) {
    m_text_font_resolver = std::move(resolver);
}

void SceneRuntimeContext::SetTextLayerFactory(TextLayerFactory factory) {
    m_text_layer_factory = std::move(factory);
}

std::string SceneRuntimeContext::CreateTextLayer(std::string_view config_json,
                                                 std::string_view current_layer_name) {
    if (! m_text_layer_factory || m_scene == nullptr || m_scene->sceneGraph == nullptr) return {};
    auto node = m_text_layer_factory(std::string(config_json), m_next_generated_text_id++);
    if (node == nullptr || node->Name().empty()) return {};
    const std::string name = node->Name();

    SceneNode* parent = nullptr;
    if (const auto current = m_nodes.find(std::string(current_layer_name));
        current != m_nodes.end() && current->second != nullptr) {
        parent = current->second->Parent();
    }
    if (parent != nullptr) {
        parent->AppendChild(node);
    } else {
        m_scene->sceneGraph->AppendChild(node);
    }
    m_script_created_layers.insert(name);
    m_scene_graph_mutated = true;
    return name;
}

// ---------------------------------------------------------------------------
// What `createLayer` and the layer properties change about a layer.
// ---------------------------------------------------------------------------

bool SceneRuntimeContext::NameLayer(std::string_view runtime_name, std::string authored_name) {
    const std::string key(runtime_name);
    if (authored_name.empty() || ! m_nodes.contains(key)) return false;
    RegisterLayerAlias(authored_name, key);
    // A name another layer already has stays that layer's: this one is then
    // still reached by the key it was registered under.
    return ResolveLayerName(authored_name) == key;
}

bool SceneRuntimeContext::SetNodeParent(std::string_view name, std::string_view parent_name) {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || m_scene == nullptr ||
        m_scene->sceneGraph == nullptr) {
        return false;
    }
    SceneNode* node       = found->second;
    SceneNode* new_parent = m_scene->sceneGraph.get();
    if (! parent_name.empty()) {
        const auto parent = m_nodes.find(ResolveLayerName(parent_name));
        if (parent == m_nodes.end() || parent->second == nullptr) return false;
        new_parent = parent->second;
    }
    // A layer cannot hang below itself or below something that hangs below it.
    for (const SceneNode* ancestor = new_parent; ancestor != nullptr; ancestor = ancestor->Parent()) {
        if (ancestor == node) return false;
    }
    SceneNode* old_parent = node->Parent();
    if (old_parent == nullptr) return false;
    if (old_parent == new_parent) return true;

    auto&      siblings = old_parent->GetChildren();
    const auto entry    = std::find_if(siblings.begin(), siblings.end(), [node](const auto& child) {
        return child.get() == node;
    });
    if (entry == siblings.end()) return false;
    auto owned = *entry;
    siblings.erase(entry);
    new_parent->AppendChild(std::move(owned));
    m_scene_graph_mutated = true;
    return true;
}

bool SceneRuntimeContext::SetNodeSize(std::string_view name, const Eigen::Vector2f& size) {
    const std::string key(name);
    const auto        found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr || ! size.allFinite() ||
        size.x() <= 0.0f || size.y() <= 0.0f || m_text_layers.contains(key)) {
        return false;
    }
    const Eigen::Vector2f previous = NodeSize(key);
    if (previous.x() <= 0.0f || previous.y() <= 0.0f) return false;
    if (SizeNearlyEqual(previous, size, 1.0e-3f)) return true;

    // Only a plain card (one vertex array of positions and texture coordinates,
    // no indices) is resized, by stretching its corners about the layer's
    // centre. Its texture coordinates are kept, so a padded texture still maps.
    auto* mesh = found->second->Mesh();
    if (mesh == nullptr || mesh->VertexCount() == 0 || mesh->Submeshes().size() != 1 ||
        mesh->IndexCount() != 0 || mesh->Submeshes().front().VertexCount() != 1) {
        return false;
    }
    const auto& source = mesh->GetVertexArray(0);
    const auto  offsets = source.GetAttrOffsetMap();
    const auto  position = offsets.find(std::string(WE_IN_POSITION));
    if (position == offsets.end()) return false;
    std::vector<float> data(source.Data(), source.Data() + source.DataSize());
    const float        scale_x = size.x() / previous.x();
    const float        scale_y = size.y() / previous.y();
    // The offsets are in bytes; the data is floats.
    const std::size_t position_offset = position->second.offset / sizeof(float);
    for (std::size_t vertex = 0; vertex < source.VertexCount(); ++vertex) {
        float* point = data.data() + vertex * source.OneSize() + position_offset;
        point[0] *= scale_x;
        point[1] *= scale_y;
    }
    SceneVertexArray stretched(source.Attributes(), source.VertexCount());
    stretched.SetVertexs(0, data);
    stretched.SetID(source.ID());
    // This layer's geometry becomes its own: a copy made from the same template
    // shares the template's vertices, and must keep them.
    SceneMesh replacement(mesh->UpdateDriver());
    replacement.AddVertexArray(std::move(stretched));
    mesh->ChangeMeshDataFrom(replacement);
    mesh->SetDirty();
    if (! mesh->Dynamic()) m_scene_graph_mutated = true;
    RegisterNodeSize(key, size);
    return true;
}

Eigen::Vector2f SceneRuntimeContext::NodeParallaxDepth(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || m_scene == nullptr ||
        m_scene->shaderValueUpdater == nullptr) {
        return Eigen::Vector2f::Zero();
    }
    const auto depth = m_scene->shaderValueUpdater->NodeParallaxDepth(found->second);
    return Eigen::Vector2f(depth[0], depth[1]);
}

bool SceneRuntimeContext::SetNodeParallaxDepth(std::string_view name,
                                               const Eigen::Vector2f& depth) {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || m_scene == nullptr ||
        m_scene->shaderValueUpdater == nullptr || ! depth.allFinite()) {
        return false;
    }
    // A graph built while the layer stood still has it as a pass that never
    // changes; one that starts following the cursor (or stops) needs a new one.
    if (m_scene->shaderValueUpdater->SetNodeParallaxDepth(found->second, depth.x(), depth.y())) {
        m_scene_graph_mutated = true;
    }
    return true;
}

std::unique_ptr<SceneRuntimeContext> CreateSceneRuntimeContext(SceneRuntimeBootstrap bootstrap) {
    return std::make_unique<SceneRuntimeContext>(std::move(bootstrap));
}

} // namespace wallpaper
