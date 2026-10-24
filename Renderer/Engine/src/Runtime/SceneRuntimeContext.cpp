// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
#include "Runtime/SceneRuntimeContext.hpp"

#include "Interface/IShaderValueUpdater.h"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/NumberText.hpp"
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

#include "Utils/Linalg.hpp"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <type_traits>
#include <iterator>
#include <ranges>
#include <limits>
#include <sstream>
#include <vector>

namespace wallpaper
{

namespace
{
// A script spells a path with either kind of separator; the registry keeps one spelling.
std::string NormalizeTemplatePath(std::string_view value) {
    if (value.empty()) return {};
    std::string text(value);
    std::replace(text.begin(), text.end(), '\\', '/');
    std::string normal = std::filesystem::path(text).lexically_normal().generic_string();
    // "." is what an empty-looking path normalises to.
    return normal == "." ? std::string {} : normal;
}

// `<folder>/workshop/<id>/<rest>` split into its parts, when it is that.
struct WorkshopPath {
    std::string folder;
    std::string id;
    std::string rest;
};
std::optional<WorkshopPath> SplitWorkshopPath(std::string_view path) {
    const auto first = path.find('/');
    if (first == std::string_view::npos || first == 0) return std::nullopt;
    constexpr std::string_view kMarker = "workshop/";
    if (path.substr(first + 1, kMarker.size()) != kMarker) return std::nullopt;
    const auto id_begin = first + 1 + kMarker.size();
    const auto id_end   = path.find('/', id_begin);
    if (id_end == std::string_view::npos || id_end == id_begin || id_end + 1 >= path.size()) {
        return std::nullopt;
    }
    const auto id = path.substr(id_begin, id_end - id_begin);
    if (! std::all_of(id.begin(), id.end(), [](char c) { return c >= '0' && c <= '9'; })) {
        return std::nullopt;
    }
    return WorkshopPath { std::string(path.substr(0, first)), std::string(id),
                          std::string(path.substr(id_end + 1)) };
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

bool SizeNearlyEqual(linalg::Vector2f lhs, linalg::Vector2f rhs, float tolerance) {
    return std::abs(lhs.x() - rhs.x()) <= tolerance && std::abs(lhs.y() - rhs.y()) <= tolerance;
}

// Puts a text card's quad at `bounds`, in the vertex order the parser builds: left-bottom,
// left-top, right-bottom, right-top, with the matching texture coordinates.
bool RewriteCardQuad(SceneMesh& mesh, const TextLayerRenderBounds& bounds) {
    if (mesh.VertexCount() < 1) return false;
    const std::array<float, 12> corners {
        bounds.left,  bounds.bottom, 0.0f, //
        bounds.left,  bounds.top,    0.0f, //
        bounds.right, bounds.bottom, 0.0f, //
        bounds.right, bounds.top,    0.0f,
    };
    const std::array<float, 8> uv { 0.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f };
    auto&                      quad = mesh.GetVertexArray(0);
    const bool wrote = quad.SetVertex(WE_IN_POSITION, corners) && quad.SetVertex(WE_IN_TEXCOORD, uv);
    if (wrote) mesh.SetDirty();
    return wrote;
}

struct DrawnExtent
{
    linalg::Vector2f size;
    linalg::Vector2f centre;
};

// The box the mesh's first vertex array covers in the layer's plane, when it has one.
std::optional<DrawnExtent> DrawnExtentOf(SceneMesh& mesh) {
    if (mesh.VertexCount() < 1) return std::nullopt;
    const auto& array = mesh.GetVertexArray(0);
    if (array.VertexCount() < 1) return std::nullopt;
    const auto attributes = array.GetAttrOffsetMap();
    const auto position   = attributes.find(std::string(WE_IN_POSITION));
    if (position == attributes.end()) return std::nullopt;
    const std::size_t lane = position->second.offset / sizeof(float);
    linalg::Vector2f  low(std::numeric_limits<float>::max(), std::numeric_limits<float>::max());
    linalg::Vector2f  high(std::numeric_limits<float>::lowest(), std::numeric_limits<float>::lowest());
    for (std::size_t i = 0; i < array.VertexCount(); ++i) {
        const float* at = array.Data() + i * array.OneSize() + lane;
        low             = linalg::Vector2f(std::min(low.x(), at[0]), std::min(low.y(), at[1]));
        high            = linalg::Vector2f(std::max(high.x(), at[0]), std::max(high.y(), at[1]));
    }
    return DrawnExtent { high - low, (low + high) * 0.5f };
}

// Where a text layer's card sits: the raster it is drawn from, the card, and the card's centre.
struct CardPlacement
{
    linalg::Vector2f raster;
    linalg::Vector2f card;
    linalg::Vector2f centre;
};

CardPlacement PlacementOf(const TextLayer& layer) {
    return CardPlacement { layer.rasterSize(), layer.size(), layer.layout().centre };
}

bool SamePlacement(const CardPlacement& a, const CardPlacement& b) {
    return SizeNearlyEqual(a.raster, b.raster, 0.001f) && SizeNearlyEqual(a.card, b.card, 0.001f) &&
           SizeNearlyEqual(a.centre, b.centre, 0.001f);
}

linalg::Vector2d CursorWorldToNdc(const CursorViewport& viewport, const linalg::Vector3f& cursor) {
    if (viewport.content_size.x() == 0.0f || viewport.content_size.y() == 0.0f) {
        return linalg::Vector2d { 0.0, 0.0 };
    }
    return linalg::Vector2d {
        2.0 * (static_cast<double>(cursor.x()) - viewport.content_origin.x()) /
                viewport.content_size.x() -
            1.0,
        2.0 * (static_cast<double>(cursor.y()) - viewport.content_origin.y()) /
                viewport.content_size.y() -
            1.0,
    };
}

// Moves `target` to position `index` of the list as it is without it (so a later slot counts
// the one after the layer it names). True only when the order changed.
template<typename ListT>
bool SortNodeInList(ListT& nodes, SceneNode* target, int index) {
    const auto current = std::find_if(nodes.begin(), nodes.end(), [target](const auto& entry) {
        return entry.get() == target;
    });
    if (current == nodes.end()) return false;
    const auto before = static_cast<int>(std::distance(nodes.begin(), current));
    auto       owned  = *current;
    nodes.erase(current);
    const int slot = std::clamp(index, 0, static_cast<int>(nodes.size()));
    nodes.insert(std::next(nodes.begin(), slot), std::move(owned));
    return slot != before;
}

// Which edges of its box a layer hangs from: the words of `alignment` are tested as parts of
// the text, `bottom` and `left` beating `top` and `right`. The sign points from the edge toward
// the layer's centre.
linalg::Vector3f AnchorDirection(std::string_view alignment) {
    float x = 0.0f;
    float y = 0.0f;
    if (alignment.find("left") != std::string_view::npos) {
        x = 1.0f;
    } else if (alignment.find("right") != std::string_view::npos) {
        x = -1.0f;
    }
    if (alignment.find("bottom") != std::string_view::npos) {
        y = 1.0f;
    } else if (alignment.find("top") != std::string_view::npos) {
        y = -1.0f;
    }
    return linalg::Vector3f(x, y, 0.0f);
}

// The final cards of an effect chain draw where the layer is drawn.
void SyncFinalCard(SceneNode& card, const SceneNode& source, const linalg::Matrix4d& drawn) {
    if (! card.HasRenderTransformOverride() || ! card.RenderTrans().isApprox(drawn, 1.0e-12)) {
        card.SetRenderTransformOverride(drawn);
    }
    card.SetTranslate(source.Translate());
    card.SetScale(source.Scale());
    card.SetRotation(source.Rotation());
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

// The layer's alpha in a material that takes it: the `g_Color4` and `g_Alpha` every
// pass of the layer is given and, on the layer's own pass, its `g_UserAlpha`. An
// effect's is the effect's own opacity (`own_user_alpha`): it starts from the
// layer's authored alpha, the effect's own `alpha` replaces that, and either is
// left alone, or the layer's alpha would be applied again by every effect that has
// an alpha.
void ApplyMaterialAlpha(SceneMaterial& material, float alpha) {
    auto& values = material.customShader.constValues;
    if (! material.own_user_alpha) values["g_UserAlpha"] = ShaderValue(alpha);
    if (const auto held = values.find("g_Alpha"); held != values.end()) held->second = ShaderValue(alpha);
    std::array<float, 4> tint { 1.0f, 1.0f, 1.0f, alpha };
    if (const auto held = values.find("g_Color4"); held != values.end() && held->second.size() >= 3) {
        tint[0] = held->second[0];
        tint[1] = held->second[1];
        tint[2] = held->second[2];
    }
    values["g_Color4"] = ShaderValue(tint);
}

// The layer's colour times its brightness where the scene renders HDR, with the
// alpha `g_Color4` already holds.
void ApplyMaterialTint(SceneMaterial& material) {
    auto& values = material.customShader.constValues;
    float alpha  = 1.0f;
    if (const auto held = values.find("g_Color4"); held != values.end() && held->second.size() >= 4) {
        alpha = held->second[3];
    }
    const float brightness = material.tint.brightness;
    values["g_Color4"]     = ShaderValue(std::array<float, 4> {
        material.tint.color[0] * brightness, material.tint.color[1] * brightness,
        material.tint.color[2] * brightness, alpha });
}

void ApplyMaterialColor(SceneMaterial& material, const linalg::Vector3f& color) {
    material.tint.color = { color.x(), color.y(), color.z() };
    material.customShader.constValues["g_Color"] =
        std::array<float, 3> { color.x(), color.y(), color.z() };
    ApplyMaterialTint(material);
}

void ApplyMaterialBrightness(SceneMaterial& material, float brightness) {
    material.tint.brightness = brightness;
    ApplyMaterialTint(material);
}

// The rotation `SceneNode::GetLocalTrans` applies to the layer's geometry:
// x first, then y, then z.
linalg::Matrix3f NodeRotationMatrix(const linalg::Vector3f& angles) {
    return (linalg::AngleAxisf(angles.z(), linalg::Vector3f::UnitZ()) *
            linalg::AngleAxisf(angles.y(), linalg::Vector3f::UnitY()) *
            linalg::AngleAxisf(angles.x(), linalg::Vector3f::UnitX()))
        .toRotationMatrix();
}

} // namespace

bool NodeHitMask::covers(float u, float v) const noexcept {
    if (width == 0 || height == 0 || ! std::isfinite(u) || ! std::isfinite(v)) return false;
    if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f) return false;
    const auto x = std::min<uint32_t>(static_cast<uint32_t>(u * static_cast<float>(width)), width - 1);
    const auto y = std::min<uint32_t>(static_cast<uint32_t>(v * static_cast<float>(height)), height - 1);
    return alpha[static_cast<std::size_t>(y) * width + x] >= kOpaqueThreshold;
}

namespace
{
// Hands the reading a table entry holds, typed by its kind, to `use`.
template<class Use>
auto VisitReading(const RuntimeScalarValue& entry, Use&& use) {
    using Result = std::invoke_result_t<Use, const bool&>;
    switch (entry.kind) {
    case RuntimeScalarValue::Kind::Bool: return use(entry.bool_value);
    case RuntimeScalarValue::Kind::Float: return use(entry.float_value);
    case RuntimeScalarValue::Kind::String: return use(entry.string_value);
    }
    return Result();
}

// A fresh live value for a table entry, starting at the entry's reading.
std::unique_ptr<DynamicValue> NewLiveValueFor(const RuntimeScalarValue& entry) {
    return VisitReading(entry, [](const auto& reading) {
        return std::make_unique<DynamicValue>(reading);
    });
}

// Assigns a table entry's reading to an existing live value.
void StoreReading(DynamicValue& target, const RuntimeScalarValue& entry) {
    VisitReading(entry, [&target](const auto& reading) { target.update(reading); });
}
} // namespace

SceneRuntimeContext::SceneRuntimeContext(SceneRuntimeBootstrap bootstrap) {
    m_script_engine = std::make_unique<ScriptEngine>();
    m_host_context  = std::make_unique<ScriptHostContext>();

    // A scene without a canvas has a zero one; the window then maps onto nothing.
    const linalg::Vector2f canvas(static_cast<float>(std::max(bootstrap.canvas_width, 0)),
                                  static_cast<float>(std::max(bootstrap.canvas_height, 0)));
    m_host_context->canvas_size        = canvas;
    m_host_context->screen_resolution  = canvas;
    m_cursor_viewport.size             = canvas;
    m_cursor_viewport.content_size     = canvas;
    // The pointer starts in the middle of the window.
    m_cursor_plane_position            = linalg::Vector3f(canvas.x() * 0.5f, canvas.y() * 0.5f, 0.0f);
    m_host_context->cursor_world_position = m_cursor_plane_position;

    m_default_properties = bootstrap.authored_project_properties.has_value()
                               ? std::move(*bootstrap.authored_project_properties)
                               : bootstrap.project_properties;
    m_project_properties = std::move(bootstrap.project_properties);
    for (const auto& [name, property] : m_project_properties) {
        auto value = NewLiveValueFor(property);
        m_property_values.emplace(name, value.get());
        m_owned_values.push_back(std::move(value));
    }

    m_text_worker = std::thread([this] { TextWorkerLoop(); });
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
    // are never started (a scene program starts as it is created, so none is
    // created from here on), and only the ones present now are ended, by index.
    m_scripts_torn_down = true;
    const auto value_count  = m_scripted_values.size();
    const auto script_count = m_scene_scripts.size();
    for (std::size_t index = 0; index < value_count; ++index) {
        if (auto* value = m_scripted_values[index]; value != nullptr) value->Destroy();
    }
    for (std::size_t index = 0; index < script_count; ++index) {
        if (auto* script = m_scene_scripts[index].script.get(); script != nullptr) script->Destroy();
    }
}

// Every clock moves by the same step: the layer timelines, the scene zoom and the clocks
// others hold, each once however many registries name it. Video clocks go with them.
void SceneRuntimeContext::AdvanceClocks(double seconds) {
    for (auto& [key, clock] : m_video_texture_playback) {
        const double step = static_cast<double>(clock.rate) * seconds;
        if (! clock.paused && step > 0.0) clock.absolute_seconds += step;
    }
    for (const auto& binding : m_scalar_animations) {
        if (binding.playback != nullptr) binding.playback->Advance(seconds);
    }
    const auto advance_unregistered = [this, seconds](ScalarAnimationPlayback* clock) {
        if (clock != nullptr && ! m_registered_clocks.contains(clock)) clock->Advance(seconds);
    };
    advance_unregistered(m_scene_zoom_animation.get());
    for (const auto& binding : m_material_alpha) advance_unregistered(binding.animation.get());
    for (const auto& shot : m_camera_shots) advance_unregistered(shot.timeline.clock.get());
}

// A layer's own flag follows its bound value; a layer with no binding is never touched.
void SceneRuntimeContext::ApplyNodeVisibilityBindings() {
    bool shown = false;
    for (auto& [name, binding] : m_node_visibility) {
        if (binding.value == nullptr || binding.node == nullptr) continue;
        if (binding.value->Generation() == binding.observed_generation) continue;
        binding.observed_generation = binding.value->Generation();
        const bool visible          = binding.value->getBool();
        if (binding.node->Visible() == visible) continue;
        binding.node->SetVisible(visible);
        shown = shown || visible;
    }
    if (shown) RequestShownLayerGraph();
}

// Scale and angles first, then the origin: an anchored layer's place is derived from all
// three once they are known. A bound key is written onto its layer every tick; one with no
// binding is never touched.
void SceneRuntimeContext::ApplyNodeTransformBindings() {
    for (auto& [name, binding] : m_node_scale) ApplyVec3Binding(Vec3Key::Scale, name, binding);
    for (auto& [name, binding] : m_node_rotation) ApplyVec3Binding(Vec3Key::Angles, name, binding);
    for (auto& [name, binding] : m_node_translate) ApplyVec3Binding(Vec3Key::Origin, name, binding);
}

// A text layer takes the text of its value when the value was assigned, and only when that
// is not the text it holds already.
void SceneRuntimeContext::ApplyTextValueBindings() {
    for (auto& binding : m_text_values) {
        if (binding.value == nullptr || binding.value->Generation() == binding.observed_generation) continue;
        binding.observed_generation = binding.value->Generation();
        const auto layer = m_text_layers.find(binding.name);
        if (layer == m_text_layers.end()) continue;
        if (binding.value->getType() == DynamicValue::String) {
            if (layer->second.text() == binding.value->getString()) continue;
            SetNodeText(binding.name, binding.value->getString());
        } else {
            SetNodeText(binding.name, binding.value->toString());
        }
    }
}

// The last card of an effect chain is drawn where its layer is.
void SceneRuntimeContext::ApplyEffectFinalBindings() {
    for (auto& [name, binding] : m_effect_card_links) {
        const auto registered = m_nodes.find(name);
        SceneNode* source = registered != m_nodes.end() && registered->second != nullptr
                                ? registered->second
                                : binding.node;
        if (source == nullptr || binding.layer == nullptr) continue;
        source->UpdateTrans();
        linalg::Matrix4d drawn = source->ModelTrans();
        drawn.block<3, 1>(0, 3) += source->DrawOffset().cast<double>();
        SyncFinalCard(binding.layer->FinalNode(), *source, drawn);
        SceneNode* resolved = binding.layer->ResolvedFinalRenderNode();
        if (resolved != nullptr && resolved != &binding.layer->FinalNode()) {
            SyncFinalCard(*resolved, *source, drawn);
        }
    }
}

void SceneRuntimeContext::RegisterPassthroughCard(std::shared_ptr<SceneNode> node,
                                                  std::shared_ptr<SceneMesh> mesh,
                                                  PassthroughCardLayout layout,
                                                  const linalg::Matrix4d& laid_out_from) {
    if (node == nullptr || mesh == nullptr || ! layout) return;
    m_passthrough_cards.push_back(
        PassthroughCard { node, std::move(mesh), std::move(layout), laid_out_from });
}

// A pass-through layer copies the screen where it is drawn: when its world transform is not the
// one its card was laid out from, the card is laid out again.
void SceneRuntimeContext::ApplyPassthroughCards() {
    std::erase_if(m_passthrough_cards, [](const PassthroughCard& card) { return card.node.expired(); });
    for (auto& card : m_passthrough_cards) {
        const auto node = card.node.lock();
        if (node == nullptr) continue;
        node->UpdateTrans();
        const linalg::Matrix4d now = node->ModelTrans();
        if ((now - card.laid_out_from).cwiseAbs().maxCoeff() <= 1.0e-6) continue;
        card.laid_out_from = now;
        card.layout(*card.mesh, now);
        ++m_passthrough_card_layouts;
        if (node->Mesh() != card.mesh.get()) continue; // a different card is drawn now
        if (card.mesh->Dynamic()) {
            card.mesh->SetDirty();
        } else {
            MarkSceneGraphMutated("passthrough-card");
        }
    }
}

void SceneRuntimeContext::ApplyMaterialConstantBindings() {
    for (auto& binding : m_material_constants) SyncMaterialConstant(binding);
}

void SceneRuntimeContext::ApplyMaterialAlphaBindings() {
    for (auto& binding : m_material_alpha) {
        if (binding.animation == nullptr) continue;
        const double frame = binding.animation->frame;
        if (frame == binding.sampled_animation_frame) continue;
        binding.sampled_animation_frame = frame;
        if (const auto material = binding.material.lock()) {
            ApplyMaterialAlpha(*material, binding.animation->Value());
        }
    }
}

void SceneRuntimeContext::StartPendingScripts() {
    if (m_scripts_torn_down) return;
    std::vector<ScriptedDynamicValue*> pending;
    for (auto* value : m_scripted_values) {
        if (value != nullptr && ! value->Initialised()) pending.push_back(value);
    }
    if (pending.empty()) return;
    // The scene's order: the layers' order, and within a layer the order the scripts were made.
    const auto rank_of = [this](const ScriptedDynamicValue* value) {
        const auto rank = NodeRank(value->LayerName());
        return rank.value_or(std::numeric_limits<std::size_t>::max());
    };
    std::stable_sort(pending.begin(), pending.end(),
                     [&](const ScriptedDynamicValue* a, const ScriptedDynamicValue* b) {
                         return rank_of(a) < rank_of(b);
                     });
    // A script's `init` may remove layers, and with them scripts that were waiting.
    const auto alive = [this](const ScriptedDynamicValue* value) {
        return std::find(m_scripted_values.begin(), m_scripted_values.end(), value) !=
               m_scripted_values.end();
    };
    for (auto* value : pending) {
        if (alive(value)) value->RunInit();
    }
    for (auto* value : pending) {
        if (alive(value)) value->RunUserNotices();
    }
}

void SceneRuntimeContext::Tick(double frame_time) {
    // A step that is negative or not a number is none.
    const double step = std::isfinite(frame_time) && frame_time > 0.0 ? frame_time : 0.0;
    m_host_context->frame_time = step;
    m_host_context->runtime_seconds += step;

    // Phase 1: inputs and clocks. Layers a script destroyed earlier go once nothing can still
    // draw them; programs hear of a new display size or language before any of them computes;
    // puppet layers that finished are collected before a listener may play one again.
    ReleaseRetiredLayers();
    const bool have_programs = ! m_scripted_values.empty() || ! m_scene_scripts.empty();
    if (m_screen_resize_pending) {
        m_screen_resize_pending = false;
        if (have_programs) {
            const auto value_count  = m_scripted_values.size();
            const auto script_count = m_scene_scripts.size();
            for (std::size_t index = 0; index < value_count; ++index) {
                if (auto* value = m_scripted_values[index]; value != nullptr) {
                    value->DispatchResizeScreen(*m_host_context);
                }
            }
            for (std::size_t index = 0; index < script_count; ++index) {
                if (auto* script = m_scene_scripts[index].script.get(); script != nullptr) {
                    script->DispatchResizeScreen(*m_host_context);
                }
            }
            m_script_engine->RunResizeScreenCallbacks(*m_host_context);
        }
    }
    if (m_general_settings_pending) {
        m_general_settings_pending = false;
        const auto value_count  = m_scripted_values.size();
        const auto script_count = m_scene_scripts.size();
        for (std::size_t index = 0; index < value_count; ++index) {
            if (auto* value = m_scripted_values[index]; value != nullptr) {
                value->DispatchGeneralSettings(*m_host_context);
            }
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            if (auto* script = m_scene_scripts[index].script.get(); script != nullptr) {
                script->DispatchGeneralSettings(*m_host_context);
            }
        }
    }
    DispatchPuppetLayerEvents();
    AdvanceClocks(step);

    // Phase 2: value scripts that have not started start (all `init`s, then all notices), then
    // every value script runs in the order the scene lists them, then the markers the clocks
    // crossed, then the bindings take this tick's results onto the layers.
    StartPendingScripts();
    {
        const auto value_count = m_scripted_values.size();
        for (std::size_t index = 0; index < value_count; ++index) {
            if (auto* value = m_scripted_values[index]; value != nullptr) value->reevaluate();
        }
    }
    DispatchPendingAnimationEvents();
    ApplyNodeVisibilityBindings();
    ApplyNodeTransformBindings();
    ApplyTextValueBindings();
    ApplyEffectFinalBindings();
    ApplyMaterialConstantBindings();
    {
        const auto script_count = m_scene_scripts.size();
        for (std::size_t index = 0; index < script_count; ++index) {
            if (index < m_scene_scripts.size()) {
                if (auto* script = m_scene_scripts[index].script.get(); script != nullptr) {
                    script->Tick(*m_host_context);
                }
            }
        }
    }
    // After every script has started and before the cameras and the draw: the scene is told
    // there is no player, so a widget that hides itself on that never shows a frame.
    DispatchIdleMediaState();

    // Phase 3: cameras and the final writes. Zoom applies after the scene scripts and before
    // the shots; shake needs the camera the shots chose; animated alpha and colour, and the
    // constants a scene script wrote after the first pass, reach this frame too.
    if (m_scene_zoom_animation != nullptr &&
        m_scene_zoom_animation->frame != m_scene_zoom_sampled_frame) {
        m_scene_zoom_sampled_frame = m_scene_zoom_animation->frame;
        ApplySceneZoomAnimation();
    }
    // A shot origin a script or property writes counts for nothing until a tick has applied it.
    for (auto& shot : m_camera_shots) shot.origin_pending = false;
    ApplyCameraShots();
    ApplyPerspectiveCameraShots(step);
    ApplyCameraShake();
    ApplyMaterialAlphaBindings();
    for (auto& binding : m_material_colors) ApplyMaterialColorAnimation(binding);
    ApplyMaterialConstantBindings();
    // Last, so the card follows every move this tick made.
    ApplyPassthroughCards();
}

ScriptEngine& SceneRuntimeContext::scriptEngine() { return *m_script_engine; }

const ScriptHostContext& SceneRuntimeContext::hostContext() const { return *m_host_context; }

const ProjectProperties& SceneRuntimeContext::defaultProjectProperties() const {
    return m_default_properties;
}

const ProjectProperties& SceneRuntimeContext::projectProperties() const {
    return m_project_properties;
}

std::vector<std::string> SceneRuntimeContext::ApplyProjectPropertyOverride(
    const ProjectProperties& override_properties) {
    return ApplyProjectProperties(MergeProjectProperties(m_default_properties, override_properties));
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
    ProjectProperties next = MergeProjectProperties(m_default_properties, override_properties);
    ProjectPropertyPreview preview;
    // A load-only property is held at what the scene read it as, for every consumer; one the
    // document asked something else for is reported, because only a reload would show it.
    for (const auto& [name, read_with] : m_load_only_properties) {
        const auto asked = next.find(name);
        const bool differs =
            read_with.has_value() != (asked != next.end()) ||
            (read_with.has_value() && ProjectPropertyValueChanged(*read_with, asked->second));
        if (differs) preview.deferred.push_back(name);
        if (read_with.has_value()) {
            next.insert_or_assign(name, *read_with);
        } else {
            next.erase(name);
        }
    }
    preview.changed = ApplyProjectProperties(std::move(next));
    return preview;
}

std::vector<std::string> SceneRuntimeContext::ApplyProjectProperties(
    ProjectProperties next_properties) {
    // What changes: a name that is new, or whose value or kind differs from the table in effect.
    std::vector<std::string> changed;
    for (const auto& [name, value] : next_properties) {
        const auto previous = m_project_properties.find(name);
        if (previous == m_project_properties.end() ||
            ProjectPropertyValueChanged(previous->second, value)) {
            changed.push_back(name);
        }
    }
    std::sort(changed.begin(), changed.end());

    // One transaction: every live value takes its entry, changed or not, and no script
    // re-evaluates itself over a half-applied table.
    struct ChangingScope
    {
        bool& flag;
        explicit ChangingScope(bool& target) : flag(target) { flag = true; }
        ~ChangingScope() { flag = false; }
    };
    std::optional<ChangingScope> changing(std::in_place, m_project_properties_changing);
    m_project_properties = std::move(next_properties);
    for (const auto& [name, value] : m_project_properties) {
        const auto live = m_property_values.find(name);
        if (live != m_property_values.end()) {
            StoreReading(*live->second, value);
            continue;
        }
        // A binding made before the name was declared has been waiting for it.
        if (const auto waiting = m_absent_property_values.find(name);
            waiting != m_absent_property_values.end()) {
            DynamicValue* adopted = waiting->second;
            m_absent_property_values.erase(waiting);
            m_property_values.emplace(name, adopted);
            StoreReading(*adopted, value);
            continue;
        }
        auto made = NewLiveValueFor(value);
        m_property_values.emplace(name, made.get());
        m_owned_values.push_back(std::move(made));
    }
    changing.reset();

    // Then the programs hear of it, as they were registered when this began.
    ProjectProperties changed_values;
    for (const auto& name : changed) changed_values.emplace(name, m_project_properties.at(name));
    const auto value_count  = m_scripted_values.size();
    const auto script_count = m_scene_scripts.size();
    for (std::size_t index = 0; index < value_count; ++index) {
        if (auto* value = m_scripted_values[index]; value != nullptr) {
            value->ApplyProjectProperties(m_project_properties, changed_values);
        }
    }
    for (std::size_t index = 0; index < script_count; ++index) {
        if (auto* script = m_scene_scripts[index].script.get(); script != nullptr) {
            script->ApplyProjectProperties(m_project_properties, changed_values);
        }
    }
    return changed;
}

std::vector<std::string> SceneRuntimeContext::ResetProjectPropertyOverride() {
    return ApplyProjectPropertyOverride({});
}

void SceneRuntimeContext::AttachScene(Scene* scene) { m_scene = scene; }

void SceneRuntimeContext::SetCursorWorldPosition(const linalg::Vector3f& value) {
    m_cursor_plane_position               = value;
    m_host_context->cursor_world_position = value;
    m_cursor_blocker_cached               = false;
}

void SceneRuntimeContext::SetCursorViewport(const CursorViewport& viewport) {
    if (! viewport.origin.allFinite() || ! viewport.size.allFinite()) return;
    if (! viewport.content_origin.allFinite() || ! viewport.content_size.allFinite()) return;
    if (viewport.size.x() == 0.0f || viewport.size.y() == 0.0f) return;
    m_cursor_viewport = viewport;
    UpdatePresentedMargins();
}

void SceneRuntimeContext::UpdatePresentedMargins() {
    // The strips of the canvas the viewport leaves uncovered; none when there is no canvas or the
    // scene fills the display.
    const auto&  canvas = m_host_context->canvas_size;
    PresentedMargins fresh;
    const bool   has_canvas = canvas.x() > 0.0f && canvas.y() > 0.0f;
    if (has_canvas && (m_scene == nullptr || ! m_scene->display_sized)) {
        const linalg::Vector2f far_corner = m_cursor_viewport.origin + m_cursor_viewport.size;
        fresh = PresentedMargins { .left   = m_cursor_viewport.origin.x(),
                                   .top    = canvas.y() - far_corner.y(),
                                   .right  = canvas.x() - far_corner.x(),
                                   .bottom = m_cursor_viewport.origin.y() };
    }
    if (std::exchange(m_presented_margins, fresh) == fresh) return;
    for (const auto& [name, alignment] : m_node_alignment) {
        if (alignment.screen_anchor != TextScreenAnchor::None) ApplyScreenAnchor(name);
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
void SceneRuntimeContext::SetScreenResolution(const linalg::Vector2f& resolution) {
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
    const auto unit = [](float value) {
        return std::isfinite(value) ? std::clamp(value, 0.0f, 1.0f) : 0.0f;
    };
    x = unit(x);
    y = unit(y);
    m_host_context->cursor_normalized_position = linalg::Vector2f(x, y);
    m_cursor_plane_position = linalg::Vector3f(
        m_cursor_viewport.origin.x() + x * m_cursor_viewport.size.x(),
        m_cursor_viewport.origin.y() + (1.0f - y) * m_cursor_viewport.size.y(), 0.0f);
    m_host_context->cursor_world_position = ScriptCursorWorldPosition();
    m_cursor_blocker_cached               = false;
    // Particles follow the cursor in canvas units whatever the camera.
    if (m_scene != nullptr) {
        m_scene->pointerScenePosition =
            std::array<float, 2> { m_cursor_plane_position.x(), m_cursor_plane_position.y() };
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
linalg::Vector3f SceneRuntimeContext::ScriptCursorWorldPosition() const {
    const SceneCamera* camera =
        m_scene != nullptr && m_scene->display_sized ? m_scene->activeCamera : nullptr;
    if (camera == nullptr || ! camera->IsPerspective()) return m_cursor_plane_position;
    const linalg::Vector2d ndc = CursorWorldToNdc(m_cursor_viewport, m_cursor_plane_position);
    const auto point = UnprojectNdcAtDepth(*camera, ndc.x(), ndc.y(), camera->FarClip());
    return point.has_value() ? linalg::Vector3f(point->cast<float>()) : m_cursor_plane_position;
}

void SceneRuntimeContext::SetCursorEnter(bool entered) { m_host_context->cursor_in_window = entered; }

void SceneRuntimeContext::SetCursorButton(int button, bool pressed) {
    if (button < 0 || button >= 32) return;
    const uint32_t bit = 1u << button;
    auto&          down = m_host_context->mouse_buttons_down;
    if (pressed && (down & bit) == 0) {
        down |= bit;
        m_host_context->mouse_buttons_pressed |= bit;
    } else if (! pressed && (down & bit) != 0) {
        down &= ~bit;
        m_host_context->mouse_buttons_released |= bit;
    }
}

void SceneRuntimeContext::SetCursorButtons(uint32_t down, uint32_t pressed, uint32_t released) {
    m_host_context->mouse_buttons_down     = down;
    m_host_context->mouse_buttons_pressed  = pressed;
    m_host_context->mouse_buttons_released = released;
}

// Edges describe one frame; the held level carries over.
void SceneRuntimeContext::BeginFrame() {
    m_host_context->mouse_buttons_pressed  = 0;
    m_host_context->mouse_buttons_released = 0;
}

void SceneRuntimeContext::StopTextWorker() {
    {
        std::lock_guard lock(m_text_worker_mutex);
        // A job in progress finishes its current step and its result is dropped; the queue
        // is never run.
        m_text_worker_stop = true;
        m_pending_text_jobs.clear();
    }
    m_text_worker_wake.notify_all();
    if (m_text_worker.joinable()) m_text_worker.join();
}

namespace
{
// A text raster side in whole texels, 1 to 4096 (anything that is not a positive number is 1).
uint32_t RasterSide(float extent) {
    if (! (extent > 1.0f)) return 1;
    if (extent >= 4096.0f) return 4096;
    return static_cast<uint32_t>(std::ceil(extent));
}
} // namespace

// The worker: lays text out and rasterises it off the render thread, one job at a time, and
// tells whoever owns the frame clock that a result is ready.
void SceneRuntimeContext::TextWorkerLoop() {
    while (auto job = AwaitTextJob()) {
        FinishedTextLayout done;
        done.name           = std::move(job->name);
        done.revision       = job->revision;
        done.cache_identity = job->state.texture_cache_key;
        done.layout         = MeasureTextLayerLayout(job->state);
        const linalg::Vector2f wanted = TextLayerRasterSizeForLayout(job->state, done.layout);
        done.raster_width  = RasterSide(wanted.x());
        done.raster_height = RasterSide(wanted.y());
        done.rgba.assign(std::size_t(done.raster_width) * done.raster_height * 4u, 0u);
        RasterizeTextLayer(job->state, done.raster_width, done.raster_height, done.rgba);
        PublishFinishedText(std::move(done));
    }
}

std::optional<RuntimePendingTextLayerJob> SceneRuntimeContext::AwaitTextJob() {
    std::unique_lock lock(m_text_worker_mutex);
    m_text_worker_wake.wait(lock,
                            [this] { return m_text_worker_stop || ! m_pending_text_jobs.empty(); });
    if (m_text_worker_stop) return std::nullopt;
    std::optional<RuntimePendingTextLayerJob> job(std::move(m_pending_text_jobs.front()));
    m_pending_text_jobs.pop_front();
    ++m_text_jobs_running;
    return job;
}

void SceneRuntimeContext::PublishFinishedText(FinishedTextLayout done) {
    std::function<void()> wake;
    {
        std::lock_guard lock(m_text_worker_mutex);
        --m_text_jobs_running;
        if (m_text_worker_stop) return;
        // Only a layer's newest result is kept, in the place its earlier result held.
        auto same_layer = std::ranges::find(m_finished_text_layouts, done.name,
                                            &FinishedTextLayout::name);
        if (same_layer == m_finished_text_layouts.end()) {
            m_finished_text_layouts.push_back(std::move(done));
        } else {
            *same_layer = std::move(done);
        }
        // Copied under the lock and called outside it, so detaching the handler cannot destroy
        // it mid-call.
        wake = m_content_wake_handler;
    }
    if (wake) wake();
}

void SceneRuntimeContext::WaitForTextLayoutForTests() const {
    for (;;) {
        {
            std::lock_guard lock(m_text_worker_mutex);
            if (m_pending_text_jobs.empty() && m_text_jobs_running == 0) return;
        }
        std::this_thread::sleep_for(std::chrono::microseconds(200));
    }
}

bool SceneRuntimeContext::TextLayoutInFlight() const {
    // A scene with no text has nothing in flight, and asks nothing of the worker's lock.
    if (m_text_layers.empty()) return false;
    {
        std::lock_guard lock(m_text_worker_mutex);
        if (! m_pending_text_jobs.empty() || m_text_jobs_running > 0 ||
            ! m_finished_text_layouts.empty()) {
            return true;
        }
    }
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
    std::lock_guard lock(m_text_worker_mutex);
    m_content_wake_handler = std::move(handler);
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
        linalg::Vector3f(card.center.x(), card.center.y(), 0.0f));
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
    MarkRenderTargetsResized("text-card-texels");
}

DynamicValue* SceneRuntimeContext::FindPropertyValue(std::string_view name) const {
    const auto found = m_property_values.find(name);
    return found == m_property_values.end() ? nullptr : found->second;
}

DynamicValue* SceneRuntimeContext::FollowProperty(std::string_view name, const DynamicValue& authored) {
    if (name.empty()) return nullptr;
    if (auto* declared = FindPropertyValue(name); declared != nullptr) return declared;
    const auto waiting = m_absent_property_values.find(name);
    if (waiting != m_absent_property_values.end()) return waiting->second;
    auto standing_in = std::make_unique<DynamicValue>(authored);
    DynamicValue* raw = standing_in.get();
    m_owned_values.push_back(std::move(standing_in));
    m_absent_property_values.emplace(std::string(name), raw);
    return raw;
}

void SceneRuntimeContext::RegisterScriptedValue(ScriptedDynamicValue* value) {
    m_scripted_values.push_back(value);
    if (value == nullptr) return;
    constexpr uint8_t kHoverEvents = static_cast<uint8_t>(ScriptCursorEvent::Enter) |
                                     static_cast<uint8_t>(ScriptCursorEvent::Leave) |
                                     static_cast<uint8_t>(ScriptCursorEvent::Move);
    if ((value->CursorHandlerMask() & kHoverEvents) != 0) {
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
    if (name.empty() || node == nullptr) return;
    const auto existing = m_nodes.find(name);
    if (existing != m_nodes.end()) {
        if (existing->second == node) return;
        // Another node under a key already in use: the layer's anchor starts again from it.
        existing->second = node;
        NodeAlignmentBinding anchor;
        anchor.origin     = node->Translate();
        anchor.scale      = node->Scale();
        anchor.base_scale = node->Scale();
        m_node_alignment.insert_or_assign(name, anchor);
        RefreshNodeTransformBindings(name);
        return;
    }
    m_nodes.emplace(name, node);
    m_node_order.push_back(name);
    m_node_rank_valid       = false;
    m_cursor_blocker_cached = false;
    // The node's place as it is registered is the anchor's origin and scale, unless an
    // alignment was given to the key first.
    const auto [anchor, inserted] = m_node_alignment.try_emplace(name);
    if (inserted) {
        anchor->second.origin     = node->Translate();
        anchor->second.scale      = node->Scale();
        anchor->second.base_scale = node->Scale();
    }
    RefreshNodeTransformBindings(name);
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

// Ends the scripts that belong to a layer that is going away, so no tick or event reaches
// them again.
void SceneRuntimeContext::ForgetLayerScripts(const std::string& name) {
    if (name.empty()) return;
    for (std::size_t index = 0; index < m_scripted_values.size(); ++index) {
        auto* value = m_scripted_values[index];
        if (value == nullptr || value->LayerName() != name) continue;
        value->Destroy();
        UnregisterScriptedValue(value);
    }
    for (std::size_t index = 0; index < m_scene_scripts.size(); ++index) {
        auto* script = m_scene_scripts[index].script.get();
        if (script == nullptr || script->LayerName() != name) continue;
        script->Destroy();
        m_scene_scripts[index].script.reset();
        for (auto& [button, held] : m_scene_script_cursor_held) std::erase(held, index);
    }
}

void SceneRuntimeContext::UnregisterNode(std::string_view view) {
    const std::string name(view);

    m_nodes.erase(name);
    std::erase(m_node_order, name);
    m_node_rank_valid       = false;
    m_cursor_blocker_cached = false;

    m_layer_authored_names.erase(name);
    std::erase_if(m_layer_ids, [&name](const auto& entry) { return entry.second == name; });
    std::erase_if(m_layer_aliases, [&name](const auto& entry) { return entry.second == name; });

    m_node_visibility.erase(name);
    m_node_color.erase(name);
    m_node_translate.erase(name);
    m_node_scale.erase(name);
    m_node_rotation.erase(name);
    m_node_alpha.erase(name);
    m_node_size.erase(name);
    m_node_hit_masks.erase(name);
    m_puppet_layers.erase(name);
    m_text_layers.erase(name);
    m_text_effect_gates.erase(name);
    m_node_alignment.erase(name);
    m_node_cursor_targets.erase(name);
    m_effect_card_links.erase(name);
    std::erase_if(m_effect_objects, [&name](const auto& entry) { return entry.second.layer == name; });
    m_node_template_paths.erase(name);
    m_sound_layers.erase(name);
    std::erase_if(m_text_values,
                  [&name](const TextValueBinding& binding) { return binding.name == name; });
    m_script_created_layers.erase(name);

    // Its video clocks, unless another layer plays the same video.
    if (const auto textures = m_node_video_textures.find(name);
        textures != m_node_video_textures.end()) {
        const auto keys = std::move(textures->second);
        m_node_video_textures.erase(textures);
        for (const auto& key : keys) {
            const bool shared = std::any_of(
                m_node_video_textures.begin(), m_node_video_textures.end(), [&key](const auto& entry) {
                    return std::find(entry.second.begin(), entry.second.end(), key) != entry.second.end();
                });
            if (! shared) m_video_texture_playback.erase(key);
        }
    }

    // What is queued for its text.
    m_revision_queued_for_layer.erase(name);
    {
        std::lock_guard lock(m_text_worker_mutex);
        std::erase_if(m_pending_text_jobs,
                      [&name](const RuntimePendingTextLayerJob& job) { return job.name == name; });
        std::erase_if(m_finished_text_layouts,
                      [&name](const FinishedTextLayout& done) { return done.name == name; });
    }
}

// Cuts the program lists back to the lengths they had, ending every script that had started.
std::size_t SceneRuntimeContext::TrimScriptsTo(std::size_t value_count, std::size_t script_count) {
    std::size_t ended = 0;
    for (std::size_t index = value_count; index < m_scripted_values.size(); ++index) {
        if (auto* value = m_scripted_values[index]; value != nullptr) {
            value->Destroy();
            UnregisterScriptedValue(value);
            ++ended;
        }
    }
    if (m_scripted_values.size() > value_count) {
        m_scripted_values.erase(m_scripted_values.begin() + static_cast<std::ptrdiff_t>(value_count),
                                m_scripted_values.end());
    }
    for (std::size_t index = script_count; index < m_scene_scripts.size(); ++index) {
        if (auto* script = m_scene_scripts[index].script.get(); script != nullptr) {
            script->Destroy();
            ++ended;
        }
    }
    if (m_scene_scripts.size() > script_count) {
        m_scene_scripts.erase(m_scene_scripts.begin() + static_cast<std::ptrdiff_t>(script_count),
                              m_scene_scripts.end());
    }
    for (auto& [button, held] : m_scene_script_cursor_held) {
        std::erase_if(held, [script_count](std::size_t index) { return index >= script_count; });
    }
    return ended;
}

std::size_t SceneRuntimeContext::RuntimeListLength(RuntimeList list) const {
    switch (list) {
    case RuntimeList::Listeners: return m_listener_ends.size();
    case RuntimeList::ScriptedValues: return m_scripted_values.size();
    case RuntimeList::SceneScripts: return m_scene_scripts.size();
    case RuntimeList::MaterialConstants: return m_material_constants.size();
    case RuntimeList::MaterialAlpha: return m_material_alpha.size();
    case RuntimeList::MaterialColors: return m_material_colors.size();
    case RuntimeList::Clocks: return m_scalar_animations.size();
    case RuntimeList::OwnedValues: return m_owned_values.size();
    case RuntimeList::Count: break;
    }
    return 0;
}

// Cuts every runtime-wide list back to the length it had: listeners are deregistered, scripts
// that had started are ended, clocks drop out of the registry, and the live values go last
// because the others may still read them.
void SceneRuntimeContext::TrimRuntimeLists(
    const std::array<std::size_t, static_cast<std::size_t>(RuntimeList::Count)>& lengths) {
    const auto want = [&lengths](RuntimeList list) { return lengths[static_cast<std::size_t>(list)]; };
    const auto truncate = [](auto& list, std::size_t length) {
        if (list.size() > length) list.erase(list.begin() + static_cast<std::ptrdiff_t>(length), list.end());
    };

    for (std::size_t at = m_listener_ends.size(); at > want(RuntimeList::Listeners); --at) {
        try {
            if (const auto& end = m_listener_ends[at - 1]; end) end();
        } catch (...) {
        }
    }
    truncate(m_listener_ends, want(RuntimeList::Listeners));

    TrimScriptsTo(want(RuntimeList::ScriptedValues), want(RuntimeList::SceneScripts));
    truncate(m_material_constants, want(RuntimeList::MaterialConstants));
    truncate(m_material_alpha, want(RuntimeList::MaterialAlpha));
    truncate(m_material_colors, want(RuntimeList::MaterialColors));

    for (std::size_t at = want(RuntimeList::Clocks); at < m_scalar_animations.size(); ++at) {
        m_registered_clocks.erase(m_scalar_animations[at].playback.get());
    }
    truncate(m_scalar_animations, want(RuntimeList::Clocks));

    const std::size_t keep_values = want(RuntimeList::OwnedValues);
    if (m_owned_values.size() > keep_values) {
        // A stand-in made for a property the failed build named is dropped with its value.
        std::unordered_set<const DynamicValue*> going;
        for (std::size_t at = keep_values; at < m_owned_values.size(); ++at) {
            going.insert(m_owned_values[at].get());
        }
        std::erase_if(m_absent_property_values,
                      [&going](const auto& entry) { return going.contains(entry.second); });
        m_owned_values.resize(keep_values);
    }
}

void SceneRuntimeContext::RollbackNodeRegistration(
    std::string_view name,
    SceneNode* node,
    std::shared_ptr<const LayerRegistrationMemo> previous) {
    if (node == nullptr) return;
    const std::string key(name);
    // A later layer under the same key keeps it.
    if (const auto registered = m_nodes.find(key);
        registered == m_nodes.end() || registered->second != node) {
        return;
    }
    UnregisterNode(key);
    if (previous == nullptr) return;

    TrimRuntimeLists(previous->lengths);

    // What stood under the key before comes back: its place, then each record it had.
    if (previous->node != nullptr) {
        m_nodes[key] = previous->node;
        const std::size_t at = std::min(previous->rank, m_node_order.size());
        m_node_order.insert(m_node_order.begin() + static_cast<std::ptrdiff_t>(at), key);
        m_node_rank_valid = false;
    }
    for (const auto& restore : previous->put_back) restore(*this);
    if (previous->color != nullptr) m_node_color.insert_or_assign(key, previous->color);
    RefreshNodeTransformBindings(key);
}

std::shared_ptr<SceneRuntimeContext::LayerRegistrationMemo>
SceneRuntimeContext::CaptureNodeRegistration(std::string_view name) const {
    static_assert(sizeof(std::size_t) + sizeof(DynamicValue*) == sizeof(std::optional<std::size_t>));
    // The generic anchor closure replaces its colour-pointer capture with a
    // table-member pointer of the same size/alignment; no new closure is stored.
    static_assert(sizeof(DynamicValue*) == sizeof(decltype(&SceneRuntimeContext::m_node_alignment)));
    static_assert(alignof(DynamicValue*) == alignof(decltype(&SceneRuntimeContext::m_node_alignment)));
    auto              memo = std::make_shared<LayerRegistrationMemo>();
    const std::string key(name);

    if (const auto held = m_nodes.find(key); held != m_nodes.end()) {
        memo->node = held->second;
        if (const auto at = std::ranges::find(m_node_order, key); at != m_node_order.end()) {
            memo->rank = static_cast<std::size_t>(at - m_node_order.begin());
        }
    }

    // Public colour binding may precede RegisterNode (and therefore any anchor).
    if (const auto color = m_node_color.find(key); color != m_node_color.end()) {
        memo->color = color->second;
    }

    // One closure per per-layer table that holds a record for the key; running it writes that
    // record back as it is now.
    const auto remember = [&](auto SceneRuntimeContext::*table) {
        const auto& records = this->*table;
        const auto  found   = records.find(key);
        if (found == records.end()) return;
        memo->put_back.push_back([key, table, record = found->second](SceneRuntimeContext& to) {
            (to.*table).insert_or_assign(key, record);
        });
    };
    remember(&SceneRuntimeContext::m_node_visibility);
    remember(&SceneRuntimeContext::m_node_translate);
    remember(&SceneRuntimeContext::m_node_scale);
    remember(&SceneRuntimeContext::m_node_rotation);
    remember(&SceneRuntimeContext::m_effect_card_links);
    remember(&SceneRuntimeContext::m_node_size);
    remember(&SceneRuntimeContext::m_node_hit_masks);
    remember(&SceneRuntimeContext::m_node_cursor_targets);
    remember(&SceneRuntimeContext::m_puppet_layers);
    remember(&SceneRuntimeContext::m_text_layers);
    remember(&SceneRuntimeContext::m_text_effect_gates);
    remember(&SceneRuntimeContext::m_node_alignment);
    remember(&SceneRuntimeContext::m_node_template_paths);
    remember(&SceneRuntimeContext::m_node_video_textures);
    remember(&SceneRuntimeContext::m_sound_layers);

    // The text bindings are a list, not a table.
    std::vector<TextValueBinding> bindings;
    std::ranges::copy_if(m_text_values, std::back_inserter(bindings),
                         [&key](const TextValueBinding& binding) { return binding.name == key; });
    if (! bindings.empty()) {
        memo->put_back.push_back([bindings = std::move(bindings)](SceneRuntimeContext& to) {
            to.m_text_values.insert(to.m_text_values.end(), bindings.begin(), bindings.end());
        });
    }

    for (std::size_t list = 0; list < memo->lengths.size(); ++list) {
        memo->lengths[list] = RuntimeListLength(static_cast<RuntimeList>(list));
    }
    return memo;
}

void SceneRuntimeContext::RegisterNodeSize(std::string name, linalg::Vector2f value) {
    if (name.empty()) return;
    const auto held = m_node_size.find(name);
    if (held != m_node_size.end() && held->second == value) return;
    m_node_size[name] = value;
    if (const auto alignment = m_node_alignment.find(name); alignment != m_node_alignment.end()) {
        alignment->second.transform_dirty = true;
    }
    RefreshNodeTransformBindings(name);
    ApplyAnchoredTransform(name);
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
                                                linalg::Vector2f            size) {
    if (node == nullptr) return;
    const std::string path = NormalizeTemplatePath(template_path);
    if (path.empty()) return;
    // The layer that goes by this node's name came from this path, which is how a script in a
    // layer of a workshop item finds the rest of the item.
    if (! node->Name().empty()) m_node_template_paths[node->Name()] = path;
    // `<folder>/workshop/<id>/<rest>` is also reachable as `<folder>/<rest>`.
    if (const auto workshop = SplitWorkshopPath(path); workshop.has_value()) {
        m_layer_templates.try_emplace(workshop->folder + "/" + workshop->rest,
                                      LayerTemplate { node, size });
    }
    m_layer_templates.insert_or_assign(path, LayerTemplate { std::move(node), size });
}

void SceneRuntimeContext::SetLayerTemplateLoader(std::function<bool(std::string_view)> loader) {
    m_layer_template_loader = std::move(loader);
    m_failed_layer_templates.clear();
    m_unsupported_layer_templates.clear();
}

void SceneRuntimeContext::ReportUnsupportedLayerTemplate(std::string_view template_path) {
    m_unsupported_layer_templates.emplace(template_path);
}

// A layer the render graph left out may be effectively visible now; one new graph shows it.
void SceneRuntimeContext::RequestShownLayerGraph() {
    if (m_scene == nullptr) return;
    for (const auto& weak : m_scene->render_excluded_nodes) {
        const auto node = weak.lock();
        if (node != nullptr && node->EffectiveVisible()) {
            MarkSceneGraphMutated("shown-layer");
            return;
        }
    }
}

void SceneRuntimeContext::RegisterNodeVisibility(std::string name, SceneNode* node,
                                                 std::unique_ptr<DynamicValue> value) {
    if (name.empty() || node == nullptr || value == nullptr) return;
    RegisterNode(name, node);
    node->SetVisible(value->getBool());
    NodeVisibilityBinding binding { .node = node, .value = value.get(),
                                    .observed_generation = value->Generation() };
    m_owned_values.push_back(std::move(value));
    m_node_visibility[std::move(name)] = binding;
}

std::string SceneRuntimeContext::RegisterEffectObject(std::string_view layer_key,
                                                      std::shared_ptr<SceneImageEffect> effect) {
    if (effect == nullptr) return {};
    std::string reference = "effect:" + std::to_string(m_next_object_reference++);
    m_effect_objects.emplace(reference, EffectObject { std::string(layer_key), std::move(effect), nullptr });
    return reference;
}

bool SceneRuntimeContext::EffectObjectVisible(std::string_view reference) const {
    const auto found = m_effect_objects.find(std::string(reference));
    return found != m_effect_objects.end() && found->second.effect != nullptr &&
           found->second.effect->visible;
}

bool SceneRuntimeContext::SetEffectObjectVisible(std::string_view reference, bool visible) {
    const auto found = m_effect_objects.find(std::string(reference));
    if (found == m_effect_objects.end() || found->second.effect == nullptr) return false;
    if (found->second.visibility != nullptr) {
        // The value's listener switches the effect and asks for the new graph.
        found->second.visibility->update(visible);
    } else {
        found->second.effect->visible = visible;
    }
    return true;
}

std::string SceneRuntimeContext::RegisterSettingAnimation(
    std::shared_ptr<ScalarAnimationPlayback> animation) {
    if (animation == nullptr) return {};
    std::string reference = "setting:" + std::to_string(m_next_object_reference++);
    m_setting_animations.emplace(reference, std::move(animation));
    return reference;
}

std::shared_ptr<ScalarAnimationPlayback> SceneRuntimeContext::RegisterSettingClock(
    ScalarAnimation animation) {
    // Filed under a key no layer has, so a lookup by layer and name never reaches it.
    return RegisterScalarAnimation("\x03clock:" + std::to_string(m_next_object_reference++),
                                   std::move(animation));
}

ScalarAnimationPlayback* SceneRuntimeContext::FindSettingAnimation(std::string_view reference) const {
    const auto found = m_setting_animations.find(std::string(reference));
    return found == m_setting_animations.end() ? nullptr : found->second.get();
}

void SceneRuntimeContext::RegisterEffectVisibility(std::shared_ptr<SceneImageEffect> effect,
                                                   std::unique_ptr<DynamicValue> value) {
    if (effect == nullptr || value == nullptr) return;
    // A script that decides this effect's visibility writes through its value from now on.
    for (auto& [reference, object] : m_effect_objects) {
        if (object.effect == effect) object.visibility = value.get();
    }
    // The value as the scene loads is what the first graph is built with, so
    // only a later switch asks for a rebuild.
    effect->visible = value->getBool();
    RegisterDynamicValueListener(std::move(value), [this, effect](const DynamicValue& current) {
        const bool visible = current.getBool();
        if (effect->visible == visible) return;
        effect->visible       = visible;
        MarkSceneGraphMutated("effect-visibility");
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
    binding.value->update(linalg::Vector3f(value[0], value[1], value[2]));
    binding.sampled_animation_frame = frame;
}

void SceneRuntimeContext::ApplyMaterialColorAnimation(MaterialColorBinding& binding) {
    if (binding.animation == nullptr || binding.animation->playback == nullptr) return;
    const double frame = binding.animation->playback->frame;
    if (frame == binding.sampled_animation_frame) return;
    const auto value = binding.animation->Value();
    const linalg::Vector3f color(value[0], value[1], value[2]);
    for (const auto& weak : binding.materials) {
        if (const auto material = weak.lock()) ApplyMaterialColor(*material, color);
    }
    binding.sampled_animation_frame = frame;
}

// Takes the live values of a vec3 binding onto the layer: scale and angles go to the node,
// the origin to the anchor, and the node's place is derived from all three.
void SceneRuntimeContext::ApplyVec3Binding(Vec3Key key, const std::string& name,
                                           NodeVec3Binding& binding) {
    ApplyNodeVec3Animation(binding);
    if (binding.value == nullptr) return;
    SceneNode* node = binding.transform_node != nullptr ? binding.transform_node : binding.node;
    if (node == nullptr) return;
    const linalg::Vector3f value = binding.value->getVec3();
    switch (key) {
    case Vec3Key::Origin:
        if (const auto alignment = m_node_alignment.find(name); alignment != m_node_alignment.end()) {
            if (! (alignment->second.origin == value)) {
                alignment->second.origin          = value;
                alignment->second.transform_dirty = true;
            }
        } else {
            node->SetTranslate(value);
        }
        break;
    case Vec3Key::Scale:
        if (const auto alignment = m_node_alignment.find(name); alignment != m_node_alignment.end()) {
            if (! (alignment->second.scale == value)) {
                alignment->second.scale           = value;
                alignment->second.transform_dirty = true;
            }
        }
        node->SetScale(value);
        break;
    case Vec3Key::Angles: node->SetRotation(value); break;
    }
    binding.observed_generation = binding.value->Generation();
    ApplyAnchoredTransform(name);
}

// The node's translation: the origin, or, for a layer hung from an edge, the anchor plus the
// offset from the anchor to the layer's centre along the layer's own turned axes. Only an
// input that changed since the last derivation makes it again.
void SceneRuntimeContext::ApplyAnchoredTransform(const std::string& name) {
    const auto found = m_nodes.find(name);
    if (found == m_nodes.end() || found->second == nullptr) return;
    const auto entry = m_node_alignment.find(name);
    if (entry == m_node_alignment.end()) return;
    SceneNode*            node      = found->second;
    NodeAlignmentBinding& alignment = entry->second;

    const linalg::Vector3f direction = AnchorDirection(alignment.alignment);
    if (direction.x() == 0.0f && direction.y() == 0.0f) {
        alignment.transform_dirty    = false;
        alignment.cached_translate   = alignment.origin;
        alignment.rotation           = node->Rotation();
        node->SetTranslate(alignment.origin);
        return;
    }
    if (alignment.transform_dirty || ! (alignment.rotation == node->Rotation())) {
        linalg::Vector2f size = linalg::Vector2f::Zero();
        if (const auto held = m_node_size.find(name); held != m_node_size.end()) size = held->second;
        // Authored: the edge is the origin, the layer's centre half its scaled size inward.
        // From a script: the node's place is the origin, and scaling moves the centre so the
        // edge stays where it was.
        const linalg::Vector3f extent =
            alignment.size_anchor ? linalg::Vector3f(alignment.scale)
                                  : linalg::Vector3f(alignment.scale - alignment.base_scale);
        const linalg::Vector3f offset(direction.x() * size.x() * extent.x() * 0.5f,
                                      direction.y() * size.y() * extent.y() * 0.5f, 0.0f);
        alignment.rotation         = node->Rotation();
        alignment.cached_translate = alignment.origin + NodeRotationMatrix(alignment.rotation) * offset;
        alignment.transform_dirty  = false;
    }
    node->SetTranslate(alignment.cached_translate);
}

void SceneRuntimeContext::ApplyScreenAnchor(const std::string& name) {
    const auto found = m_nodes.find(name);
    const auto entry = m_node_alignment.find(name);
    if (found == m_nodes.end() || found->second == nullptr || entry == m_node_alignment.end()) return;
    entry->second.screen_offset =
        TextScreenAnchorOffset(entry->second.screen_anchor, m_presented_margins);
    found->second->SetDrawOffset(
        linalg::Vector3f(entry->second.screen_offset.x(), entry->second.screen_offset.y(), 0.0f));
}

void SceneRuntimeContext::RegisterNodeTranslate(std::string name, SceneNode* node,
                                                std::unique_ptr<DynamicValue> value,
                                                std::shared_ptr<const NodeVec3Animation> animation) {
    if (name.empty() || node == nullptr || value == nullptr) return;
    RegisterNode(name, node);
    NodeVec3Binding binding;
    binding.node      = node;
    binding.value     = value.get();
    binding.animation = std::move(animation);
    m_owned_values.push_back(std::move(value));
    auto& stored = m_node_translate[name] = std::move(binding);
    RefreshNodeTransformBindings(name);
    ApplyVec3Binding(Vec3Key::Origin, name, stored);
}

void SceneRuntimeContext::RegisterNodeScale(std::string name, SceneNode* node,
                                            std::unique_ptr<DynamicValue> value,
                                            std::shared_ptr<const NodeVec3Animation> animation) {
    if (name.empty() || node == nullptr || value == nullptr) return;
    RegisterNode(name, node);
    NodeVec3Binding binding;
    binding.node      = node;
    binding.value     = value.get();
    binding.animation = std::move(animation);
    m_owned_values.push_back(std::move(value));
    auto& stored = m_node_scale[name] = std::move(binding);
    RefreshNodeTransformBindings(name);
    ApplyVec3Binding(Vec3Key::Scale, name, stored);
}

void SceneRuntimeContext::RegisterNodeRotation(std::string name, SceneNode* node,
                                               std::unique_ptr<DynamicValue> value,
                                               std::shared_ptr<const NodeVec3Animation> animation) {
    if (name.empty() || node == nullptr || value == nullptr) return;
    RegisterNode(name, node);
    NodeVec3Binding binding;
    binding.node      = node;
    binding.value     = value.get();
    binding.animation = std::move(animation);
    m_owned_values.push_back(std::move(value));
    auto& stored = m_node_rotation[name] = std::move(binding);
    RefreshNodeTransformBindings(name);
    ApplyVec3Binding(Vec3Key::Angles, name, stored);
}

void SceneRuntimeContext::RegisterTextLayer(std::string name, TextLayerState state) {
    if (name.empty()) return;
    if (state.layer_key.empty()) state.layer_key = name;
    auto layout = MeasureTextLayerLayout(state);
    RegisterTextLayer(std::move(name), std::move(state), std::move(layout));
}

void SceneRuntimeContext::RegisterTextLayer(std::string name, TextLayerState state,
                                            TextLayerLayout layout) {
    if (name.empty()) return;
    if (state.layer_key.empty()) state.layer_key = name;
    auto layer        = TextLayer(std::move(state), std::move(layout));
    // A new layer starts its revisions again: what was queued for the old one means nothing.
    m_revision_queued_for_layer.erase(name);
    RegisterNodeSize(name, layer.size());
    m_text_layers.insert_or_assign(std::move(name), std::move(layer));
}

void SceneRuntimeContext::RegisterTextValue(std::string name,
                                            std::unique_ptr<DynamicValue> value,
                                            bool apply_current_value) {
    if (name.empty() || value == nullptr) return;
    TextValueBinding binding { .name = name, .value = value.get(),
                               .observed_generation = value->Generation() };
    m_owned_values.push_back(std::move(value));
    std::erase_if(m_text_values, [&name](const TextValueBinding& entry) { return entry.name == name; });
    m_text_values.push_back(binding);
    if (apply_current_value) SetNodeText(name, binding.value->toString());
}

namespace
{
// The float lanes a live value gives a shader constant: a vector its lanes, a number, integer
// or flag one float, a text the numbers in it, nothing one 0.
ShaderValue ConstantFromValue(const DynamicValue& value) {
    switch (value.getType()) {
    case DynamicValue::Vec2:
    case DynamicValue::IVec2: return ShaderValue(std::array<float, 2> { value.getVec2().x(), value.getVec2().y() });
    case DynamicValue::Vec3:
    case DynamicValue::IVec3:
        return ShaderValue(std::array<float, 3> { value.getVec3().x(), value.getVec3().y(), value.getVec3().z() });
    case DynamicValue::Vec4:
    case DynamicValue::IVec4:
        return ShaderValue(std::array<float, 4> { value.getVec4().x(), value.getVec4().y(),
                                                  value.getVec4().z(), value.getVec4().w() });
    case DynamicValue::Float:
    case DynamicValue::Int:
    case DynamicValue::Boolean: return ShaderValue(value.getFloat());
    case DynamicValue::String: {
        std::array<float, 16> numbers {};
        const std::size_t     count = ReadNumberList(value.getString(), numbers.data(), numbers.size());
        if (count == 0) return ShaderValue(0.0f);
        return ShaderValue(numbers.data(), count);
    }
    case DynamicValue::Null: break;
    }
    return ShaderValue(0.0f);
}

bool SameConstant(const ShaderValue& left, const ShaderValue& right) {
    if (left.size() != right.size()) return false;
    for (std::size_t i = 0; i < left.size(); ++i) {
        if (left[i] != right[i]) return false;
    }
    return true;
}
} // namespace

// Writes a constant binding's current value into its material, only where it differs from
// what the material holds (and creating a constant it lacks). The converted value is cached
// against the live value's change counter, or the clock's frame, so a tick in which nothing
// moved costs a comparison per binding.
void SceneRuntimeContext::SyncMaterialConstant(MaterialConstantBinding& binding) {
    const auto material = binding.material.lock();
    if (material == nullptr) return;

    if (const auto& clip = binding.animation; clip != nullptr) {
        const double frame = clip->playback != nullptr ? clip->playback->frame : 0.0;
        const bool   stale = ! binding.cached_value_valid || frame != binding.sampled_animation_frame;
        if (stale) {
            const std::size_t   lanes = std::clamp<std::size_t>(clip->component_count, 1, 4);
            std::array<float, 4> sample {};
            for (std::size_t lane = 0; lane < lanes; ++lane) {
                const auto& curve = clip->components[lane];
                sample[lane]      = curve.Evaluate(curve.fps > 0.0 ? frame / curve.fps : 0.0);
            }
            binding.cached_value            = ShaderValue(sample.data(), lanes);
            binding.cached_value_valid      = true;
            binding.sampled_animation_frame = frame;
        }
    } else if (const DynamicValue* live = binding.value; live != nullptr) {
        const uint64_t generation = live->Generation();
        if (! binding.cached_value_valid || generation != binding.observed_generation) {
            binding.cached_value        = ConstantFromValue(*live);
            binding.cached_value_valid  = true;
            binding.observed_generation = generation;
        }
    } else {
        return;
    }

    auto& constants = material->customShader.constValues;
    if (const auto held = constants.find(binding.name); held == constants.end()) {
        constants.emplace(binding.name, binding.cached_value);
    } else if (! SameConstant(held->second, binding.cached_value)) {
        held->second = binding.cached_value;
    }
}

void SceneRuntimeContext::RegisterMaterialConstant(
    std::shared_ptr<SceneMaterial> material, std::string name,
    std::unique_ptr<DynamicValue> value,
    std::shared_ptr<const MaterialConstantAnimation> animation) {
    if (material == nullptr || name.empty() || value == nullptr) return;
    MaterialConstantBinding binding;
    binding.material  = material;
    binding.name      = std::move(name);
    binding.value     = value.get();
    binding.animation = std::move(animation);
    m_owned_values.push_back(std::move(value));
    SyncMaterialConstant(binding);
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
    const auto global = m_scene->cameras.find("global");
    if (global == m_scene->cameras.end() || global->second == nullptr) return;
    const double applied = std::isfinite(zoom) && zoom > 0.0 ? zoom : 1.0;
    constexpr double kMostUnits = 2147483647.0;
    SceneCamera&     canvas     = *global->second;
    canvas.SetWidth(std::clamp(static_cast<double>(m_scene->ortho[0]) / applied, 1.0, kMostUnits));
    canvas.SetHeight(std::clamp(static_cast<double>(m_scene->ortho[1]) / applied, 1.0, kMostUnits));
    canvas.Update();
    // The perspective camera layers that opted into it draw through keeps the canvas plane
    // where the flat view puts it.
    if (const auto perspective = m_scene->cameras.find("global_perspective");
        perspective != m_scene->cameras.end() && perspective->second != nullptr) {
        perspective->second->SetAspect(canvas.Aspect());
        FitCanvasPerspective(*perspective->second, canvas);
        perspective->second->Update();
    }
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
    linalg::Vector2f offset = linalg::Vector2f::Zero();
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
            linalg::Vector3f origin = timeline.origin_base;
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
        offset = shot.origin_pending ? linalg::Vector2f(linalg::Vector2f::Zero())
                                     : linalg::Vector2f(shot.node->Translate().head<2>());
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
        camera.SetShakeOffset(linalg::Vector3d::Zero());
        return;
    }
    const double t =
        double(m_camera_shake.speed) * m_camera_shake.speed * m_host_context->runtime_seconds;
    linalg::Vector3d offset(std::cos(t), std::sin(t * 1.333), std::sin(t));
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
    RegisterDynamicValueListener(std::move(value), [this](const DynamicValue& current) {
        if (m_scene == nullptr) return;
        const auto colour = current.getVec3();
        m_scene->clearColor = { colour.x(), colour.y(), colour.z() };
    });
}

void SceneRuntimeContext::RegisterDynamicValueListener(
    std::unique_ptr<DynamicValue> value,
    std::function<void(const DynamicValue&)> callback,
    bool replay_current) {
    if (value == nullptr || ! callback) return;
    // Drivers start with the held value. Static mutation recipients subscribe
    // without replay; later explicit assignments still notify the same listener.
    if (replay_current) callback(*value);
    DynamicValue* raw = value.get();
    m_owned_values.push_back(std::move(value));
    m_listener_ends.push_back(raw->listen(callback));
}

void SceneRuntimeContext::RegisterNodeEffectFinal(std::string name,
                                                  SceneNode* node,
                                                  SceneImageEffectLayer* layer,
                                                  TextLayerRenderFrame target_frame) {
    if (name.empty() || node == nullptr || layer == nullptr) return;
    if (const auto registered = m_nodes.find(name);
        registered == m_nodes.end() || registered->second != node) {
        RegisterNode(name, node);
    }
    // The cards follow the layer from the first tick on: until its parents are attached the
    // layer's matrix is not where it will be drawn.
    m_effect_card_links[name] =
        EffectCardLink { .node = node, .layer = layer, .target_frame = target_frame };
}

void SceneRuntimeContext::RegisterMaterialAlphaAnimation(
    std::shared_ptr<SceneMaterial> material, std::shared_ptr<ScalarAnimationPlayback> animation) {
    if (material == nullptr || animation == nullptr) return;
    MaterialAlphaBinding binding;
    binding.material  = material;
    binding.animation = std::move(animation);
    ApplyMaterialAlpha(*material, binding.animation->Value());
    binding.sampled_animation_frame = binding.animation->frame;
    m_material_alpha.push_back(std::move(binding));
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
                                            std::unique_ptr<DynamicValue> value,
                                            bool replay_current) {
    if (materials.empty() || value == nullptr) return;
    if (! layer_name.empty()) m_node_color[std::move(layer_name)] = value.get();
    RegisterDynamicValueListener(
        std::move(value), [materials = std::move(materials)](const DynamicValue& current) {
            const auto color = current.getVec3();
            for (const auto& material : materials) {
                if (material != nullptr) ApplyMaterialColor(*material, color);
            }
        }, replay_current);
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
    // A clock that cannot move is created stopped, so it asks nothing of the frame clock.
    playback->playing = !animation.start_paused && animation.fps > 0.0;
    playback->animation = std::move(animation);
    m_scalar_animations.push_back({ std::string(layer_name), playback });
    m_registered_clocks.insert(playback.get());
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
    if (m_scripts_torn_down) return;
    // The program's `init` runs inside this call, and may register more of everything.
    auto program = m_script_engine->CreateSceneScriptProgram(
        *this, std::move(script_source), std::move(layer_name), m_project_properties,
        *m_host_context);
    if (program == nullptr || ! program->Valid()) return;
    m_scene_scripts.push_back(SceneScriptBinding { .script = std::move(program) });
}

void SceneRuntimeContext::RegisterNodeVideoTexture(std::string name, std::string texture_key) {
    if (name.empty() || texture_key.empty()) return;
    auto& keys = m_node_video_textures[name];
    if (std::find(keys.begin(), keys.end(), texture_key) == keys.end()) keys.push_back(texture_key);
    m_video_texture_playback.try_emplace(std::move(texture_key));
}

void SceneRuntimeContext::RegisterSoundLayer(std::string                    name,
                                             std::shared_ptr<WPSoundStream> stream) {
    if (name.empty() || stream == nullptr) return;
    m_sound_layers[std::move(name)] = stream;
}

std::size_t SceneRuntimeContext::sceneScriptCount() const {
    std::size_t count = static_cast<std::size_t>(
        std::count_if(m_scripted_values.begin(), m_scripted_values.end(),
                      [](const ScriptedDynamicValue* value) { return value != nullptr; }));
    count += static_cast<std::size_t>(
        std::count_if(m_scene_scripts.begin(), m_scene_scripts.end(),
                      [](const SceneScriptBinding& binding) { return binding.script != nullptr; }));
    return count;
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
        return playback != nullptr && playback->playing && playback->rate != 0.0 &&
               playback->animation.fps > 0.0;
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
    const bool has_program =
        std::any_of(m_scripted_values.begin(), m_scripted_values.end(),
                    [](const ScriptedDynamicValue* value) { return value != nullptr; }) ||
        std::any_of(m_scene_scripts.begin(), m_scene_scripts.end(),
                    [](const SceneScriptBinding& binding) { return binding.script != nullptr; });
    if (has_program) reasons |= SceneDemandReason::Script;

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

    // `m_effect_card_links` holds no value at all: `SyncEffectFinalNode`
    // mirrors a node onto its effect layer's final node, so it moves when the
    // node it mirrors moves and never on its own.
    if (any_binding_advances(m_node_visibility) || any_binding_advances(m_node_translate) ||
        any_binding_advances(m_node_scale) || any_binding_advances(m_node_rotation) ||
        std::any_of(m_material_constants.begin(),
                    m_material_constants.end(),
                    [&advances_on_its_own, &advances](const MaterialConstantBinding& binding) {
                        // An animation writes the constant on a timeline of its
                        // own, which is exactly the case the value pointer
                        // cannot describe: it counts while that clock plays, and a
                        // finished one-shot timeline holds its value.
                        return (binding.animation != nullptr &&
                                advances(binding.animation->playback)) ||
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
    return m_nodes.contains(std::string(name));
}

bool SceneRuntimeContext::HasSoundLayer(std::string_view name) const {
    const auto found = m_sound_layers.find(std::string(name));
    return found != m_sound_layers.end() && ! found->second.expired();
}

bool SceneRuntimeContext::PlaySoundLayer(std::string_view name) {
    const auto found = m_sound_layers.find(std::string(name));
    const auto stream = found != m_sound_layers.end() ? found->second.lock() : nullptr;
    if (stream == nullptr) return false;
    stream->Play();
    return true;
}

bool SceneRuntimeContext::PauseSoundLayer(std::string_view name) {
    const auto found = m_sound_layers.find(std::string(name));
    const auto stream = found != m_sound_layers.end() ? found->second.lock() : nullptr;
    if (stream == nullptr) return false;
    stream->Pause();
    return true;
}

bool SceneRuntimeContext::StopSoundLayer(std::string_view name) {
    const auto found = m_sound_layers.find(std::string(name));
    const auto stream = found != m_sound_layers.end() ? found->second.lock() : nullptr;
    if (stream == nullptr) return false;
    stream->Stop();
    return true;
}

bool SceneRuntimeContext::SoundLayerPlaying(std::string_view name) const {
    const auto found = m_sound_layers.find(std::string(name));
    const auto stream = found != m_sound_layers.end() ? found->second.lock() : nullptr;
    return stream != nullptr && stream->IsPlaying();
}

bool SceneRuntimeContext::SetSoundLayerVolume(std::string_view name, float volume) {
    const auto found = m_sound_layers.find(std::string(name));
    const auto stream = found != m_sound_layers.end() ? found->second.lock() : nullptr;
    if (stream == nullptr) return false;
    stream->SetVolume(volume);
    return true;
}

float SceneRuntimeContext::SoundLayerVolume(std::string_view name) const {
    const auto found = m_sound_layers.find(std::string(name));
    const auto stream = found != m_sound_layers.end() ? found->second.lock() : nullptr;
    return stream != nullptr ? stream->Volume() : 0.0f;
}

bool SceneRuntimeContext::SetSoundLayerMuted(std::string_view name, bool muted) {
    const auto found = m_sound_layers.find(std::string(name));
    const auto stream = found != m_sound_layers.end() ? found->second.lock() : nullptr;
    if (stream == nullptr) return false;
    stream->SetMuted(muted);
    return true;
}

bool SceneRuntimeContext::SoundLayerMuted(std::string_view name) const {
    const auto found = m_sound_layers.find(std::string(name));
    const auto stream = found != m_sound_layers.end() ? found->second.lock() : nullptr;
    return stream != nullptr && stream->Muted();
}

int SceneRuntimeContext::NodeSiblingIndex(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr) return -1;
    const SceneNode* node   = found->second;
    const SceneNode* parent = node->Parent();
    if (parent == nullptr && m_scene != nullptr) parent = m_scene->sceneGraph.get();
    if (parent == nullptr) return -1;
    int index = 0;
    for (const auto& child : parent->GetChildren()) {
        if (child.get() == node) return index;
        ++index;
    }
    return -1;
}

namespace
{
// A layer a script can copy: it draws through no effect chain of its own and has no layers
// below it.
bool IsCopyableTemplate(const SceneNode& node) {
    return node.Camera().empty() && node.GetChildren().empty();
}
} // namespace

std::string SceneRuntimeContext::CreateLayerFromTemplate(std::string_view requested_template_path,
                                                         std::string_view current_layer_name,
                                                         std::string_view script_workshop_id) {
    if (m_scene == nullptr || m_scene->sceneGraph == nullptr) return {};
    const std::string path = NormalizeTemplatePath(requested_template_path);
    if (path.empty()) return {};

    const auto find_template = [this](const std::string& at) -> const LayerTemplate* {
        const auto found = m_layer_templates.find(at);
        return found != m_layer_templates.end() && found->second.node != nullptr ? &found->second
                                                                                   : nullptr;
    };
    // The loader is asked once for a path, and never again for one that failed or while it is
    // being loaded already.
    const auto try_load = [this, current_layer_name](const std::string& at) {
        if (! m_layer_template_loader || m_failed_layer_templates.contains(at) ||
            m_loading_layer_templates.contains(at)) {
            return false;
        }
        m_loading_layer_templates.insert(at);
        const bool loaded = m_layer_template_loader(at);
        m_loading_layer_templates.erase(at);
        // A path the loader found nothing at is an answer, not an error; one whose model it
        // refused for its shape is worth one line.
        if (! loaded && m_failed_layer_templates.insert(at).second &&
            m_unsupported_layer_templates.contains(at)) {
            LOG_INFO("createLayer unsupported template shape: current=\"%s\" template=\"%s\"",
                     std::string(current_layer_name).c_str(), at.c_str());
        }
        return loaded;
    };

    // Which spelling of the path the template is found under.
    std::string          found_path;
    const LayerTemplate* entry = nullptr;
    // A script in a layer that came from a workshop item finds the item's own files first.
    if (const auto caller = m_node_template_paths.find(std::string(current_layer_name));
        caller != m_node_template_paths.end()) {
        if (const auto workshop = SplitWorkshopPath(caller->second); workshop.has_value()) {
            const auto requested_folder = path.substr(0, path.find('/'));
            const auto rest             = path.substr(path.find('/') == std::string::npos ? 0 : path.find('/') + 1);
            if (! path.empty() && path.find('/') != std::string::npos && ! rest.starts_with("workshop/")) {
                const std::string local = std::string(requested_folder) + "/workshop/" + workshop->id + "/" + rest;
                if (const auto* local_entry = find_template(local); local_entry != nullptr) {
                    entry      = local_entry;
                    found_path = local;
                }
            }
        }
    }
    if (entry == nullptr) {
        entry = find_template(path);
        if (entry != nullptr) {
            found_path = path;
        } else if (try_load(path)) {
            entry = find_template(path);
            if (entry != nullptr) found_path = path;
        }
    }
    // Only when every spelling above failed does the item the script declares come into it.
    if (entry == nullptr) {
        const std::string declared = MakeWorkshopAssetPath(path, script_workshop_id);
        if (! declared.empty()) {
            entry = find_template(declared);
            if (entry == nullptr && try_load(declared)) entry = find_template(declared);
            if (entry != nullptr) found_path = declared;
        }
    }
    if (entry == nullptr) return {};

    // A layer with an effect chain or layers below it is not copied: the model itself is loaded,
    // replacing the registration, so later calls copy it directly.
    if (! IsCopyableTemplate(*entry->node)) {
        if (! try_load(found_path)) return {};
        entry = find_template(found_path);
        if (entry == nullptr || ! IsCopyableTemplate(*entry->node)) {
            m_failed_layer_templates.insert(found_path);
            return {};
        }
    }

    // The copy: the same placement and drawing flags, its own name, id, geometry and materials.
    SceneNode&           source = *entry->node;
    const linalg::Vector2f size = entry->size;
    const std::string    key    = "__generated_layer_" + std::to_string(m_next_generated_layer_key++) + ":" + found_path;
    auto                 copy   = std::make_shared<SceneNode>();
    copy->SetName(key);
    copy->ID() = m_next_generated_layer_id++;
    copy->CopyTrans(source);
    copy->SetVisible(source.Visible());
    copy->SetSkipRenderPass(source.SkipRenderPass());
    copy->SetIgnoreParentTransform(source.IgnoresParentTransform());
    copy->SetMustProduce(source.MustProduce());
    copy->SetCompositeOnly(source.CompositeOnly());
    copy->CopyChildFrame(source);
    copy->SetCamera(source.Camera());
    copy->SetDrawOffset(source.DrawOffset());
    copy->SetTextureAnimationRate(source.TextureAnimationRate());
    copy->SetTextureAnimationPaused(source.TextureAnimationPaused());

    SceneMesh*                                  source_mesh = source.Mesh();
    std::shared_ptr<SceneMesh>                  mesh;
    std::vector<std::shared_ptr<SceneMaterial>> source_materials;
    if (source_mesh != nullptr) {
        mesh = std::make_shared<SceneMesh>(source_mesh->UpdateDriver());
        mesh->ChangeMeshDataFrom(*source_mesh);
        mesh->SetPrimitive(source_mesh->Primitive());
        mesh->SetPointSize(source_mesh->PointSize());
        mesh->SetID(source_mesh->ID());
        source_materials = source_mesh->MaterialSlots();
        for (const auto& material : source_materials) {
            mesh->MaterialSlots().push_back(
                material != nullptr ? std::make_shared<SceneMaterial>(*material) : nullptr);
        }
        copy->AddMesh(mesh);
    }

    // The last child of the layer that asked, or of the scene.
    SceneNode* parent = m_scene->sceneGraph.get();
    if (const auto caller = m_nodes.find(std::string(current_layer_name));
        caller != m_nodes.end() && caller->second != nullptr && caller->second->Parent() != nullptr) {
        parent = caller->second->Parent();
    }
    parent->AppendChild(copy);

    RegisterNode(key, copy.get());
    RegisterNodeSize(key, size);
    m_script_created_layers.insert(key);
    m_node_template_paths[key] = found_path;
    if (const auto target = m_node_cursor_targets.find(std::string_view(source.Name()));
        target != m_node_cursor_targets.end()) {
        m_node_cursor_targets[key] = target->second;
    }
    if (const auto mask = m_node_hit_masks.find(source.Name()); mask != m_node_hit_masks.end()) {
        m_node_hit_masks[key] = mask->second;
    }

    // Its alpha is what its material starts from.
    float alpha = 1.0f;
    if (mesh != nullptr) {
        if (const auto* material = mesh->Material(); material != nullptr) {
            const auto held = material->customShader.constValues.find("g_UserAlpha");
            if (held != material->customShader.constValues.end() && held->second.size() >= 1) {
                alpha = held->second[0];
            }
        }
        RegisterNodeAlpha(key, mesh->MaterialSlots(), alpha);
    }

    // Every constant bound on the template's materials drives the copy's too: the same live
    // values and the same clocks, applied now so a clone of a running timeline stands where it
    // stands.
    std::vector<MaterialConstantBinding> fanned;
    for (const auto& binding : m_material_constants) {
        const auto material = binding.material.lock();
        if (material == nullptr) continue;
        for (std::size_t slot = 0; slot < source_materials.size(); ++slot) {
            if (mesh == nullptr || source_materials[slot] != material ||
                slot >= mesh->MaterialSlots().size()) {
                continue;
            }
            MaterialConstantBinding twin;
            twin.material  = mesh->MaterialSlots()[slot];
            twin.name      = binding.name;
            twin.value     = binding.value;
            twin.animation = binding.animation;
            fanned.push_back(std::move(twin));
        }
    }
    for (auto& twin : fanned) {
        SyncMaterialConstant(twin);
        m_material_constants.push_back(std::move(twin));
    }

    MarkSceneGraphMutated("clone-layer");
    return key;
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
        // The scripts and clocks of a layer that is gone are over with it.
        ForgetLayerScripts(layer_name);
        for (const auto& binding : m_scalar_animations) {
            if (binding.layer_name == layer_name) m_registered_clocks.erase(binding.playback.get());
        }
        std::erase_if(m_scalar_animations, [&layer_name](const ScalarAnimationBinding& binding) {
            return binding.layer_name == layer_name;
        });
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
    MarkSceneGraphMutated("destroy-layer");
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
            if (node->Mesh() != nullptr) {
                for (const auto& slot : node->Mesh()->MaterialSlots()) {
                    if (slot != nullptr) materials.insert(slot.get());
                }
            }
            if (m_scene != nullptr && m_scene->shaderValueUpdater != nullptr) {
                m_scene->shaderValueUpdater->ForgetNode(node);
            }
        }
    }
    std::erase_if(m_material_constants, [&materials](const MaterialConstantBinding& binding) {
        const auto material = binding.material.lock();
        return material == nullptr || materials.contains(material.get());
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

linalg::Vector3f SceneRuntimeContext::NodeColor(std::string_view name) const {
    const auto node = m_nodes.find(std::string(name));
    if (node == m_nodes.end() || node->second == nullptr || node->second->Mesh() == nullptr ||
        node->second->Mesh()->Material() == nullptr) return linalg::Vector3f::Ones();
    const auto& values = node->second->Mesh()->Material()->customShader.constValues;
    const auto color = values.find("g_Color");
    if (color == values.end() || color->second.size() < 3) return linalg::Vector3f::Ones();
    return linalg::Vector3f(color->second[0], color->second[1], color->second[2]);
}

bool SceneRuntimeContext::SetNodeColor(std::string_view name, const linalg::Vector3f& color) {
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
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr) return false;
    SceneNode* node   = found->second;
    SceneNode* parent = node->Parent();
    if (parent == nullptr && m_scene != nullptr) parent = m_scene->sceneGraph.get();
    if (parent == nullptr) return false;
    if (! SortNodeInList(parent->GetChildren(), node, index)) return false;
    MarkSceneGraphMutated("sort-node");
    return true;
}

bool SceneRuntimeContext::NodeVisible(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    return found != m_nodes.end() && found->second != nullptr && found->second->Visible();
}

std::string SceneRuntimeContext::NodeParentName(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr) return {};
    const SceneNode* parent = found->second->Parent();
    if (parent == nullptr) return {};
    for (const auto& [layer_name, layer_node] : m_nodes) {
        if (layer_node == parent) return layer_name;
    }
    return {};
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
    const std::string key(name);
    // The script's write is the bound flag's too, even where the node is missing.
    if (const auto bound = m_node_visibility.find(key);
        bound != m_node_visibility.end() && bound->second.value != nullptr) {
        bound->second.value->update(visible);
        bound->second.observed_generation = bound->second.value->Generation();
    }
    const auto found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr) return false;
    SceneNode* node = found->second;
    const bool was  = node->Visible();
    node->SetVisible(visible);
    // From here on the script decides this layer's visibility, so later graphs include it
    // even while it is hidden.
    node->SetVisibilitySettled(false);
    if (visible && ! was) RequestShownLayerGraph();
    return true;
}

bool SceneRuntimeContext::SetNodeTranslate(std::string_view name, const linalg::Vector3f& value) {
    const std::string key(name);
    // A script's write is the bound value's too, so its next run continues from it.
    if (const auto bound = m_node_translate.find(key);
        bound != m_node_translate.end() && bound->second.value != nullptr) {
        bound->second.value->update(value);
    }
    const auto found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr) return false;
    if (const auto alignment = m_node_alignment.find(key); alignment != m_node_alignment.end()) {
        alignment->second.origin          = value;
        alignment->second.transform_dirty = true;
    }
    ApplyAnchoredTransform(key);
    return true;
}

bool SceneRuntimeContext::SetNodeScale(std::string_view name, const linalg::Vector3f& value) {
    const std::string key(name);
    if (const auto bound = m_node_scale.find(key);
        bound != m_node_scale.end() && bound->second.value != nullptr) {
        bound->second.value->update(value);
    }
    const auto found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr) return false;
    if (const auto alignment = m_node_alignment.find(key); alignment != m_node_alignment.end()) {
        alignment->second.scale           = value;
        alignment->second.transform_dirty = true;
    }
    found->second->SetScale(value);
    ApplyAnchoredTransform(key);
    return true;
}

bool SceneRuntimeContext::SetNodeAlignment(std::string_view name, std::string alignment) {
    const std::string key(name);
    const auto        found = m_nodes.find(key);
    const auto        entry = m_node_alignment.find(key);
    if (found == m_nodes.end() || found->second == nullptr || entry == m_node_alignment.end() ||
        m_text_layers.contains(key)) {
        return false;
    }
    NodeAlignmentBinding& anchor = entry->second;
    const auto            before = AnchorDirection(anchor.alignment);
    if (before.x() == 0.0f && before.y() == 0.0f) {
        // A layer with no anchor: where it stands now is the origin, and scaling it from
        // here keeps the named edge in place.
        anchor.origin       = found->second->Translate();
        anchor.scale        = found->second->Scale();
        anchor.base_scale   = found->second->Scale();
        anchor.size_anchor  = false;
    }
    anchor.alignment       = std::move(alignment);
    anchor.transform_dirty = true;
    ApplyAnchoredTransform(key);
    return true;
}

bool SceneRuntimeContext::SetNodeAnchorAlignment(std::string_view name, std::string alignment,
                                                 const linalg::Vector3f& origin) {
    const std::string key(name);
    const auto        found = m_nodes.find(key);
    const auto        entry = m_node_alignment.find(key);
    if (found == m_nodes.end() || found->second == nullptr || entry == m_node_alignment.end()) {
        return false;
    }
    NodeAlignmentBinding& anchor = entry->second;
    anchor.alignment       = std::move(alignment);
    anchor.origin          = origin;
    anchor.scale           = found->second->Scale();
    anchor.base_scale      = anchor.scale;
    anchor.size_anchor     = true;
    anchor.transform_dirty = true;
    ApplyAnchoredTransform(key);
    return true;
}

bool SceneRuntimeContext::SetNodeScreenAnchor(std::string_view name, TextScreenAnchor anchor) {
    const std::string key(name);
    const auto        found = m_nodes.find(key);
    const auto        entry = m_node_alignment.find(key);
    if (found == m_nodes.end() || found->second == nullptr || entry == m_node_alignment.end()) {
        return false;
    }
    entry->second.screen_anchor = anchor;
    ApplyScreenAnchor(key);
    return true;
}

bool SceneRuntimeContext::SetNodeRotation(std::string_view name, const linalg::Vector3f& value) {
    const std::string key(name);
    if (const auto bound = m_node_rotation.find(key);
        bound != m_node_rotation.end() && bound->second.value != nullptr) {
        bound->second.value->update(value);
    }
    const auto found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr) return false;
    found->second->SetRotation(value);
    ApplyAnchoredTransform(key);
    return true;
}

namespace
{
using Turn = std::array<std::array<double, 3>, 3>;

// Rz * Ry * Rx for angles in radians: the orientation a layer's angles describe.
Turn TurnFromAngles(double x, double y, double z) {
    const double cx = std::cos(x), sx = std::sin(x);
    const double cy = std::cos(y), sy = std::sin(y);
    const double cz = std::cos(z), sz = std::sin(z);
    return { { { cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx },
               { sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx },
               { -sy, cy * sx, cy * cx } } };
}

Turn Compose(const Turn& first, const Turn& then) {
    Turn out {};
    for (std::size_t row = 0; row < 3; ++row) {
        for (std::size_t column = 0; column < 3; ++column) {
            for (std::size_t k = 0; k < 3; ++k) out[row][column] += first[row][k] * then[k][column];
        }
    }
    return out;
}

// The angles (x, y, z in radians) whose `TurnFromAngles` is `m`. At the poles of the y turn the
// x and z turns share an axis; the whole turn is then given to x.
linalg::Vector3f AnglesFromTurn(const Turn& m) {
    const double sin_y = std::clamp(-m[2][0], -1.0, 1.0);
    double       x     = 0.0;
    double       z     = 0.0;
    if (std::abs(sin_y) < 1.0 - 1e-9) {
        x = std::atan2(m[2][1], m[2][2]);
        z = std::atan2(m[1][0], m[0][0]);
    } else {
        x = std::atan2(-m[1][2], m[1][1]);
    }
    return linalg::Vector3f(static_cast<float>(x), static_cast<float>(std::asin(sin_y)),
                            static_cast<float>(z));
}
} // namespace

bool SceneRuntimeContext::RotateNodeObjectSpace(std::string_view name,
                                                const linalg::Vector3f& increment) {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || ! increment.allFinite()) return false;
    const auto& now = found->second->Rotation();
    // The increment is a turn in the layer's own frame, so it is applied before the turn the
    // layer already has is carried out on the parent's axes: now * increment.
    const Turn current = TurnFromAngles(now.x(), now.y(), now.z());
    const Turn step    = TurnFromAngles(increment.x(), increment.y(), increment.z());
    return SetNodeRotation(name, AnglesFromTurn(Compose(current, step)));
}

linalg::Vector3f SceneRuntimeContext::NodeTranslate(std::string_view name) const {
    const std::string key(name);
    const auto        found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr) return linalg::Vector3f::Zero();
    // A layer hung from an edge is where its anchor is, not where its centre is.
    if (const auto alignment = m_node_alignment.find(key); alignment != m_node_alignment.end()) {
        const auto direction = AnchorDirection(alignment->second.alignment);
        if (direction.x() != 0.0f || direction.y() != 0.0f) return alignment->second.origin;
    }
    return found->second->Translate();
}

linalg::Vector3f SceneRuntimeContext::NodeScale(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr) return linalg::Vector3f::Zero();
    return found->second->Scale();
}

linalg::Matrix4d SceneRuntimeContext::NodeTransformMatrix(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr) return linalg::Matrix4d::Identity();
    found->second->UpdateTrans();
    return found->second->ModelTrans();
}

linalg::Vector3f SceneRuntimeContext::NodeRotation(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr) return linalg::Vector3f::Zero();
    return found->second->Rotation();
}

linalg::Vector2f SceneRuntimeContext::NodeSize(std::string_view name) const {
    const auto found = m_node_size.find(name);
    return found != m_node_size.end() ? found->second : linalg::Vector2f(linalg::Vector2f::Zero());
}

linalg::Vector2f SceneRuntimeContext::NodeBoxCentre(std::string_view name) const {
    const auto layer = m_text_layers.find(name);
    return layer != m_text_layers.end() ? layer->second.layout().centre
                                        : linalg::Vector2f(linalg::Vector2f::Zero());
}

std::string SceneRuntimeContext::NodeText(std::string_view name) const {
    const auto layer = m_text_layers.find(std::string(name));
    return layer != m_text_layers.end() ? layer->second.text() : std::string {};
}

bool SceneRuntimeContext::NodeTextDirty(std::string_view name) const {
    const auto layer = m_text_layers.find(std::string(name));
    return layer != m_text_layers.end() && layer->second.dirty();
}

std::optional<TextLayerState> SceneRuntimeContext::NodeTextState(std::string_view name) const {
    const auto layer = m_text_layers.find(std::string(name));
    if (layer == m_text_layers.end()) return std::nullopt;
    return layer->second.state();
}

std::optional<TextLayerLayout> SceneRuntimeContext::NodeTextLayout(std::string_view name) const {
    const auto iterator = m_text_layers.find(std::string(name));
    if (iterator == m_text_layers.end()) return std::nullopt;
    return iterator->second.layout();
}

bool SceneRuntimeContext::SetNodeText(std::string_view name, std::string text) {
    const std::string key(name);
    const auto        layer = m_text_layers.find(key);
    if (layer == m_text_layers.end()) return false;
    // The script that decides this layer's text keeps what it writes.
    if (m_own_text_write != nullptr) {
        const auto binding = std::find_if(
            m_text_values.begin(), m_text_values.end(),
            [&key](const TextValueBinding& entry) { return entry.name == key; });
        if (binding != m_text_values.end() && binding->value == &m_own_text_write->m_owner) {
            m_own_text_write->m_written = text;
        }
    }
    // Writing what the layer already holds marks nothing and wakes nothing.
    if (layer->second.text() == text) return true;
    layer->second.SetText(std::move(text));
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
    const auto layer = m_text_layers.find(std::string(name));
    if (layer == m_text_layers.end()) return false;
    layer->second.ClearDirty();
    return true;
}

void SceneRuntimeContext::PumpTextLayerCache() {
    if (m_text_layers.empty()) return;
    // What the worker finished, for every layer, hidden or not; each is applied outside the lock.
    std::vector<FinishedTextLayout> finished;
    {
        std::lock_guard lock(m_text_worker_mutex);
        finished.swap(m_finished_text_layouts);
    }
    for (auto& result : finished) ApplyFinishedTextLayout(result);
    QueueTextJobs();
}

// A job for every layer that has a layout pending and is being prepared. One job per layer
// waits in the queue: a newer request overwrites it in place, keeping its turn.
void SceneRuntimeContext::QueueTextJobs() {
    bool queued = false;
    for (const auto& [name, layer] : m_text_layers) {
        const auto& state = layer.state();
        if (! layer.layoutPending() || ! state.cache_dirty || state.cache_revision == 0) continue;
        if (! TextLayerIsBeingPrepared(name)) continue;
        const auto last = m_revision_queued_for_layer.find(name);
        if (last != m_revision_queued_for_layer.end() && last->second == state.cache_revision) continue;
        m_revision_queued_for_layer[name] = state.cache_revision;
        {
            std::lock_guard lock(m_text_worker_mutex);
            const auto waiting = std::find_if(
                m_pending_text_jobs.begin(), m_pending_text_jobs.end(),
                [&name](const RuntimePendingTextLayerJob& job) { return job.name == name; });
            if (waiting != m_pending_text_jobs.end()) {
                waiting->revision = state.cache_revision;
                waiting->state    = state;
            } else {
                m_pending_text_jobs.push_back(
                    RuntimePendingTextLayerJob { name, state.cache_revision, state });
            }
        }
        queued = true;
    }
    if (queued) m_text_worker_wake.notify_one();
}

// Applies a layout the worker finished. False when it is not the layer's any more.
bool SceneRuntimeContext::ApplyFinishedTextLayout(FinishedTextLayout& finished) {
    const auto entry = m_text_layers.find(finished.name);
    if (entry == m_text_layers.end()) return false;
    TextLayer& layer = entry->second;
    if (layer.state().texture_cache_key != finished.cache_identity) return false;

    const CardPlacement before = PlacementOf(layer);
    if (! layer.ApplyPreparedLayout(finished.revision, std::move(finished.layout))) return false;

    const std::string& name = entry->first;
    if (! SamePlacement(before, PlacementOf(layer))) {
        const auto  held = m_nodes.find(name);
        SceneNode*  node = held != m_nodes.end() ? held->second : nullptr;
        ReshapeTextCard(name, layer, node);
    }
    RegisterNodeSize(name, layer.size());
    ApplyAnchoredTransform(name);
    PublishTextRaster(layer, finished);
    if (! layer.layoutPending()) layer.ClearDirty();
    return true;
}

// Everything that follows the card of a text layer whose card just changed.
void SceneRuntimeContext::ReshapeTextCard(const std::string& name, TextLayer& layer,
                                          SceneNode* node) {
    const TextLayerRenderFrame frame    = TextLayerRenderFrameForLayout(layer.state(), layer.layout());
    const bool                 has_area = frame.size.x() > 0.0f && frame.size.y() > 0.0f;

    // A layer drawn through an effect chain has buffers of the card with the fraction cut off,
    // and that cut frame is also what the composite samples.
    EffectCardLink* chain = nullptr;
    if (const auto link = m_effect_card_links.find(name);
        has_area && link != m_effect_card_links.end() && link->second.layer != nullptr) {
        chain = &link->second;
    }
    const TextLayerRenderFrame sampled = chain != nullptr ? TextLayerEffectFrame(frame) : frame;

    if (const auto gate = m_text_effect_gates.find(name);
        gate != m_text_effect_gates.end() && gate->second.card_inset != nullptr) {
        gate->second.card_inset->update(TextCardInsetInRaster(layer.state(), layer.layout()));
    }
    if (node != nullptr) FitTextLayerComposite(*node, sampled);
    if (has_area && node != nullptr && node->Mesh() != nullptr) RefitCardMesh(*node->Mesh(), frame);
    if (chain != nullptr) ResizeEffectChain(*chain, node, sampled);
}

// Replaces the drawn card with one at the new bounds when it no longer matches.
void SceneRuntimeContext::RefitCardMesh(SceneMesh& mesh, const TextLayerRenderFrame& frame) {
    const auto drawn = DrawnExtentOf(mesh);
    if (! drawn.has_value()) return;
    const bool same_size = std::abs(drawn->size.x() - frame.size.x()) <= 1.0f &&
                           std::abs(drawn->size.y() - frame.size.y()) <= 1.0f;
    if (same_size && SizeNearlyEqual(drawn->centre, frame.center, 0.001f)) return;
    if (RewriteCardQuad(mesh, frame.bounds) && ! mesh.Dynamic()) {
        MarkSceneGraphMutated("text-card-mesh");
    }
}

void SceneRuntimeContext::ResizeEffectChain(EffectCardLink& link, SceneNode* node,
                                            const TextLayerRenderFrame& effect_frame) {
    const bool resized = std::abs(effect_frame.size.x() - link.target_frame.size.x()) > 0.5f ||
                         std::abs(effect_frame.size.y() - link.target_frame.size.y()) > 0.5f;
    if (m_scene != nullptr && resized) {
        const auto fit = [&effect_frame](SceneRenderTarget& target, double scale) {
            const auto side = [scale](float length) {
                const auto scaled = static_cast<int32_t>(std::llround(static_cast<double>(length) * scale));
                return std::max<int32_t>(4, scaled);
            };
            target.width  = target.authored_width  = side(effect_frame.size.x());
            target.height = target.authored_height = side(effect_frame.size.y());
        };
        const std::string& first = link.layer->FirstTarget();
        const std::string& second = link.layer->SecondTarget();
        // These are sibling roots: each is scaled independently by the backend,
        // without introducing a bound-target traversal-order dependency.
        for (const std::string* name : { &first, &second }) {
            if (const auto root = m_scene->renderTargets.find(*name); root != m_scene->renderTargets.end()) {
                fit(root->second, 1.0);
            }
        }
        for (auto& [target_name, target] : m_scene->renderTargets) {
            const bool follows_first = target.bind.enable && ! target.bind.screen &&
                                       target.bind.name == first;
            if (follows_first) fit(target, target.bind.scale);
        }
        MarkRenderTargetsResized("text-resized-buffers");
    }
    // The chain's camera and the final cards follow the frame whenever the card changed.
    if (m_scene != nullptr && node != nullptr) {
        const auto camera = m_scene->cameras.find(node->Camera());
        if (camera != m_scene->cameras.end() && camera->second != nullptr &&
            camera->second->GetAttachedNode() != nullptr) {
            camera->second->SetWidth(effect_frame.size.x());
            camera->second->SetHeight(effect_frame.size.y());
            camera->second->GetAttachedNode()->SetTranslate(
                linalg::Vector3f(effect_frame.center.x(), effect_frame.center.y(), 0.0f));
            camera->second->Update();
        }
    }
    RewriteCardQuad(link.layer->FinalMesh(), effect_frame.bounds);
    SceneNode* resolved = link.layer->ResolvedFinalRenderNode();
    if (resolved != nullptr && resolved->Mesh() != nullptr &&
        resolved->Mesh() != &link.layer->FinalMesh()) {
        RewriteCardQuad(*resolved->Mesh(), effect_frame.bounds);
    }
    link.target_frame = effect_frame;
}

// The raster becomes the layer's texture, when there is a scene to hold it.
void SceneRuntimeContext::PublishTextRaster(const TextLayer& layer, const FinishedTextLayout& done) {
    if (m_scene == nullptr || layer.state().layer_key.empty()) return;
    if (done.raster_width == 0 || done.raster_height == 0 || done.rgba.empty()) return;
    auto* images = dynamic_cast<RuntimeImageSource*>(m_scene->imageParser.get());
    if (images == nullptr) return;
    images->SetRgbaImage(TextTextureName(layer.state().layer_key), done.raster_width,
                         done.raster_height, done.rgba.data(), done.rgba.size());
}

bool SceneRuntimeContext::SetNodeTextureFrame(std::string_view name, double frame) {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr || ! std::isfinite(frame)) return false;
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
    if (it == m_nodes.end() || it->second == nullptr) return false;
    return ! it->second->TextureAnimationPaused() && ! it->second->TextureFrame().has_value();
}

bool SceneRuntimeContext::SetNodeTextureAnimationRate(std::string_view name, double rate) {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr || ! std::isfinite(rate)) return false;
    it->second->SetTextureAnimationRate(rate);
    return true;
}

double SceneRuntimeContext::NodeTextureAnimationRate(std::string_view name) const {
    const auto it = m_nodes.find(std::string(name));
    if (it == m_nodes.end() || it->second == nullptr) return 1.0;
    return it->second->TextureAnimationRate();
}

bool SceneRuntimeContext::NodeHasVideoTexture(std::string_view name) const {
    const auto keys = m_node_video_textures.find(name);
    return keys != m_node_video_textures.end() && ! keys->second.empty();
}

bool SceneRuntimeContext::PlayNodeVideoTexture(std::string_view name) {
    const auto keys = m_node_video_textures.find(name);
    if (keys == m_node_video_textures.end() || keys->second.empty()) return false;
    for (const auto& key : keys->second) {
        if (const auto clock = m_video_texture_playback.find(key); clock != m_video_texture_playback.end()) {
            clock->second.paused = false;
        }
    }
    return true;
}

bool SceneRuntimeContext::NodeVideoTextureIsPlaying(std::string_view name) const {
    const auto keys = m_node_video_textures.find(name);
    if (keys == m_node_video_textures.end() || keys->second.empty()) return false;
    const auto clock = m_video_texture_playback.find(keys->second.front());
    return clock != m_video_texture_playback.end() && ! clock->second.paused;
}

bool SceneRuntimeContext::PauseNodeVideoTexture(std::string_view name) {
    const auto keys = m_node_video_textures.find(name);
    if (keys == m_node_video_textures.end() || keys->second.empty()) return false;
    for (const auto& key : keys->second) {
        if (const auto clock = m_video_texture_playback.find(key); clock != m_video_texture_playback.end()) {
            clock->second.paused = true;
        }
    }
    return true;
}

bool SceneRuntimeContext::SetNodeVideoTextureCurrentTime(std::string_view name, double seconds) {
    const auto keys = m_node_video_textures.find(name);
    if (keys == m_node_video_textures.end() || keys->second.empty()) return false;
    const double target = std::isfinite(seconds) ? std::max(0.0, seconds) : 0.0;
    for (const auto& key : keys->second) {
        const auto clock = m_video_texture_playback.find(key);
        if (clock == m_video_texture_playback.end()) continue;
        const double duration = clock->second.duration_seconds;
        clock->second.absolute_seconds = duration > 0.0 ? std::fmod(target, duration) : target;
    }
    return true;
}

double SceneRuntimeContext::NodeVideoTextureCurrentTime(std::string_view name) const {
    const auto keys = m_node_video_textures.find(name);
    if (keys == m_node_video_textures.end() || keys->second.empty()) return 0.0;
    const auto clock = m_video_texture_playback.find(keys->second.front());
    if (clock == m_video_texture_playback.end()) return 0.0;
    const double absolute = std::max(0.0, clock->second.absolute_seconds);
    const double duration = clock->second.duration_seconds;
    return duration > 0.0 ? std::fmod(absolute, duration) : absolute;
}

bool SceneRuntimeContext::SetNodeVideoTextureRate(std::string_view name, float rate) {
    const auto keys = m_node_video_textures.find(name);
    if (keys == m_node_video_textures.end() || keys->second.empty()) return false;
    const float applied = std::isfinite(rate) ? std::max(0.0f, rate) : 0.0f;
    for (const auto& key : keys->second) {
        if (const auto clock = m_video_texture_playback.find(key); clock != m_video_texture_playback.end()) {
            clock->second.rate = applied;
        }
    }
    return true;
}

float SceneRuntimeContext::NodeVideoTextureRate(std::string_view name) const {
    const auto keys = m_node_video_textures.find(name);
    if (keys == m_node_video_textures.end() || keys->second.empty()) return 1.0f;
    const auto clock = m_video_texture_playback.find(keys->second.front());
    return clock == m_video_texture_playback.end() ? 1.0f : clock->second.rate;
}

double SceneRuntimeContext::NodeVideoTextureDuration(std::string_view name) const {
    const auto keys = m_node_video_textures.find(name);
    if (keys == m_node_video_textures.end() || keys->second.empty()) return 0.0;
    const auto clock = m_video_texture_playback.find(keys->second.front());
    return clock == m_video_texture_playback.end() ? 0.0 : clock->second.duration_seconds;
}

void SceneRuntimeContext::SetVideoTextureDuration(std::string_view texture_key, double seconds) {
    if (texture_key.empty() || ! std::isfinite(seconds) || seconds <= 0.0) return;
    auto found = m_video_texture_playback.find(texture_key);
    if (found == m_video_texture_playback.end()) {
        found = m_video_texture_playback.try_emplace(std::string(texture_key)).first;
    }
    found->second.duration_seconds = seconds;
    found->second.absolute_seconds = std::fmod(std::max(0.0, found->second.absolute_seconds), seconds);
}

video::VideoPlaybackState
SceneRuntimeContext::ResolveVideoPlaybackState(std::string_view texture_key,
                                               double fallback_scene_elapsed_seconds) const {
    video::VideoPlaybackState state;
    const auto                clock = m_video_texture_playback.find(texture_key);
    if (clock == m_video_texture_playback.end()) {
        state.scene_elapsed_seconds = fallback_scene_elapsed_seconds;
        return state;
    }
    state.paused                = clock->second.paused;
    state.rate                  = clock->second.rate;
    state.scene_elapsed_seconds = std::max(0.0, clock->second.absolute_seconds);
    return state;
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
    const auto found = m_nodes.find(name);
    if (found == m_nodes.end() || found->second == nullptr) return false;
    SceneNode& node = *found->second;

    // The box the layer answers to: its size across, about its box centre. A size of nothing on
    // both axes counts as 100 by 100, and a negative one is never hit.
    linalg::Vector2f size = NodeSize(name);
    if (size.x() <= 0.0f && size.y() <= 0.0f) size = linalg::Vector2f(100.0f, 100.0f);
    if (size.x() < 0.0f || size.y() < 0.0f) return false;
    const linalg::Vector2f centre = NodeBoxCentre(name);

    // The camera the layer is drawn through: its own, else the scene's active one.
    const SceneCamera* camera = nullptr;
    if (m_scene != nullptr) {
        if (! node.Camera().empty()) {
            const auto own = m_scene->cameras.find(node.Camera());
            if (own != m_scene->cameras.end()) camera = own->second.get();
        } else {
            camera = m_scene->activeCamera;
        }
    }

    // Where the cursor is in the layer's own plane.
    double plane_x = 0.0;
    double plane_y = 0.0;
    node.UpdateTrans();
    if (camera != nullptr && camera->IsPerspective()) {
        const linalg::Vector2d ndc = CursorWorldToNdc(m_cursor_viewport, m_cursor_plane_position);
        const auto hit = IntersectNdcWithNodePlane(*camera, node, ndc.x(), ndc.y());
        if (! hit.has_value()) return false;
        plane_x = hit->x();
        plane_y = hit->y();
    } else {
        linalg::Matrix4d drawn = node.ModelTrans();
        drawn.block<3, 1>(0, 3) += node.DrawOffset().cast<double>();
        if (! drawn.allFinite() || ! (std::abs(drawn.determinant()) >= 1.0e-12)) return false;
        const linalg::Vector4d local =
            drawn.inverse() * linalg::Vector4d(m_cursor_plane_position.x(), m_cursor_plane_position.y(), 0.0, 1.0);
        if (! local.allFinite()) return false;
        plane_x = local.x();
        plane_y = local.y();
    }

    const double across = plane_x - centre.x();
    const double down   = plane_y - centre.y();
    const double half_x = static_cast<double>(size.x()) * 0.5;
    const double half_y = static_cast<double>(size.y()) * 0.5;
    if (std::abs(across) > half_x || std::abs(down) > half_y) return false;

    // A layer a script handles the cursor for also answers to its coverage mask: the card's
    // left-top is texture 0, 0.
    const auto mask = m_node_hit_masks.find(name);
    if (mask == m_node_hit_masks.end() || ! (half_x > 0.0) || ! (half_y > 0.0)) return true;
    const double u = (across + half_x) / static_cast<double>(size.x());
    const double v = (half_y - down) / static_cast<double>(size.y());
    return mask->second.covers(static_cast<float>(u), static_cast<float>(v));
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

// One frame of cursor events for the programs that listen (a scene program carries no mask of
// the handlers it defines, since it may register them as it runs, so each is asked): enter, leave and move by whether
// the pointer is over their layer, then the press and release edges this frame brought.
bool SceneRuntimeContext::DispatchCursorFrameEvents(bool cursor_was_in_window) {
    const bool in_window = m_host_context->cursor_in_window;
    constexpr uint8_t kPress = static_cast<uint8_t>(ScriptCursorEvent::Down) |
                               static_cast<uint8_t>(ScriptCursorEvent::Click);
    constexpr uint8_t kRelease = static_cast<uint8_t>(ScriptCursorEvent::Up);
    // The walk's programs are the ones there are as it begins; what a callback adds joins at the
    // next frame, and one it removes leaves an empty slot.
    const auto value_count  = m_scripted_values.size();
    const auto script_count = m_scene_scripts.size();
    m_cursor_blocker_cached = false;
    const auto callback_ran = [this] { m_cursor_blocker_cached = false; };

    if (! in_window) {
        if (cursor_was_in_window) {
            for (std::size_t index = 0; index < value_count; ++index) {
                auto* value = m_scripted_values[index];
                if (value == nullptr) continue;
                const auto inside = m_scripted_value_cursor_inside.find(value);
                if (inside == m_scripted_value_cursor_inside.end() || ! inside->second) continue;
                inside->second = false;
                value->DispatchCursorLeave(*m_host_context);
                callback_ran();
            }
            for (std::size_t index = 0; index < script_count; ++index) {
                if (index >= m_scene_scripts.size() || m_scene_scripts[index].script == nullptr ||
                    ! m_scene_scripts[index].cursor_inside) {
                    continue;
                }
                m_scene_scripts[index].cursor_inside = false;
                m_scene_scripts[index].script->DispatchCursorLeave(*m_host_context);
                callback_ran();
            }
        }
    } else {
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr) continue;
            auto inside = m_scripted_value_cursor_inside.find(value);
            if (inside == m_scripted_value_cursor_inside.end()) continue;
            const CursorVisit visit = VisitScriptLayer(*value);
            if (visit == CursorVisit::Skipped) continue;
            const bool now = visit == CursorVisit::Inside;
            if (now != inside->second) {
                inside->second = now;
                if (now) {
                    value->DispatchCursorEnter(*m_host_context);
                } else {
                    value->DispatchCursorLeave(*m_host_context);
                }
                callback_ran();
            }
            // Over the layer, the pointer moves every frame, moved or not.
            if (now && m_scripted_values.size() > index && m_scripted_values[index] == value) {
                value->DispatchCursorMove(*m_host_context);
                callback_ran();
            }
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            if (index >= m_scene_scripts.size() || m_scene_scripts[index].script == nullptr) continue;
            auto* script = m_scene_scripts[index].script.get();
            const CursorVisit visit = VisitScriptLayer(*script);
            if (visit == CursorVisit::Skipped) continue;
            const bool now = visit == CursorVisit::Inside;
            if (now != m_scene_scripts[index].cursor_inside) {
                m_scene_scripts[index].cursor_inside = now;
                if (now) {
                    script->DispatchCursorEnter(*m_host_context);
                } else {
                    script->DispatchCursorLeave(*m_host_context);
                }
                callback_ran();
            }
            if (now && index < m_scene_scripts.size() && m_scene_scripts[index].script.get() == script) {
                script->DispatchCursorMove(*m_host_context);
                callback_ran();
            }
        }
    }

    // Presses go to the programs under the pointer, which then hold the button; the release
    // goes to the holders wherever the pointer has gone since.
    const uint32_t pressed  = m_host_context->mouse_buttons_pressed;
    const uint32_t released = m_host_context->mouse_buttons_released;
    for (uint32_t button = 0; button < 32; ++button) {
        const uint32_t bit = 1u << button;
        if ((pressed & bit) != 0 && in_window) {
            m_scripted_value_cursor_held[button].clear();
            m_scene_script_cursor_held[button].clear();
            m_host_context->cursor_button = static_cast<int>(button);
            m_cursor_blocker_cached = false;
            for (std::size_t index = 0; index < value_count; ++index) {
                auto* value = m_scripted_values[index];
                if (value == nullptr || (value->CursorHandlerMask() & kPress) == 0) continue;
                if (VisitScriptLayer(*value) != CursorVisit::Inside) continue;
                m_scripted_value_cursor_held[button].push_back(value);
                value->DispatchCursorDown(*m_host_context);
                if (m_scripted_values.size() > index && m_scripted_values[index] == value) {
                    value->DispatchCursorClick(*m_host_context);
                }
                callback_ran();
            }
            for (std::size_t index = 0; index < script_count; ++index) {
                if (index >= m_scene_scripts.size() || m_scene_scripts[index].script == nullptr) continue;
                auto* script = m_scene_scripts[index].script.get();
                if (VisitScriptLayer(*script) != CursorVisit::Inside) continue;
                m_scene_script_cursor_held[button].push_back(index);
                script->DispatchCursorDown(*m_host_context);
                if (index < m_scene_scripts.size() && m_scene_scripts[index].script.get() == script) {
                    script->DispatchCursorClick(*m_host_context);
                }
                callback_ran();
            }
        }
        if ((released & bit) == 0) continue;
        m_host_context->cursor_button = static_cast<int>(button);
        const auto held_values  = std::exchange(m_scripted_value_cursor_held[button], {});
        const auto held_scripts = std::exchange(m_scene_script_cursor_held[button], {});
        m_cursor_blocker_cached = false;
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value == nullptr || (value->CursorHandlerMask() & kRelease) == 0) continue;
            const bool holder = std::find(held_values.begin(), held_values.end(), value) != held_values.end();
            const bool scene_wide = value->LayerName().empty();
            if (holder || scene_wide ||
                (in_window && VisitScriptLayer(*value) == CursorVisit::Inside)) {
                value->DispatchCursorUp(*m_host_context);
                callback_ran();
            }
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            if (index >= m_scene_scripts.size() || m_scene_scripts[index].script == nullptr) continue;
            auto* script = m_scene_scripts[index].script.get();
            const bool holder = std::find(held_scripts.begin(), held_scripts.end(), index) != held_scripts.end();
            const bool scene_wide = script->LayerName().empty();
            if (holder || scene_wide ||
                (in_window && VisitScriptLayer(*script) == CursorVisit::Inside)) {
                script->DispatchCursorUp(*m_host_context);
                callback_ran();
            }
        }
    }
    return in_window;
}

void SceneRuntimeContext::DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                                        const linalg::Vector3f& text_color) {
    ForEachEventScript([&](auto* script) { script->DispatchMediaThumbnailChanged(primary_color, text_color); });
}

void SceneRuntimeContext::SetMediaIntegrationEnabled(bool enabled) {
    m_media_integration_enabled.store(enabled, std::memory_order_release);
}

bool SceneRuntimeContext::MediaIntegrationEnabled() const {
    return m_media_integration_enabled.load(std::memory_order_acquire);
}

void SceneRuntimeContext::DispatchMediaEventJson(std::string_view event_json) {
    if (! MediaIntegrationEnabled() || event_json.empty()) return;
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

void SceneRuntimeContext::MarkSceneGraphMutated(const char* reason) {
    m_scene_graph_mutated = true;
    ++m_scene_graph_mutation_reasons[reason];
}

void SceneRuntimeContext::MarkRenderTargetsResized(const char* reason) {
    m_render_targets_resized = true;
    ++m_render_target_resize_reasons[reason];
}

bool SceneRuntimeContext::ConsumeRenderTargetResizeFlag() {
    const bool resized       = m_render_targets_resized;
    m_render_targets_resized = false;
    return resized;
}

bool SceneRuntimeContext::ConsumeSceneGraphMutationFlag() {
    const bool mutated    = m_scene_graph_mutated;
    m_scene_graph_mutated = false;
    return mutated;
}

audio::AudioSpectrumSnapshot SceneRuntimeContext::CurrentAudioSpectrumSnapshot() const {
    if (! AudioResponseActive()) return {};
    return audio::CurrentAudioSpectrumSnapshot();
}

void SceneRuntimeContext::RecordScriptError(std::string message) {
    if (message.empty()) return;
    m_script_errors.push_back(std::move(message));
}

std::size_t SceneRuntimeContext::scriptErrorCount() const { return m_script_errors.size(); }

const std::vector<std::string>& SceneRuntimeContext::scriptErrors() const { return m_script_errors; }

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
        m_node_rank_valid       = false;
        m_cursor_blocker_cached = false;
        changed                 = true;
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
        MarkSceneGraphMutated("sort-layer-relative");
        changed               = true;
    }
    return changed;
}

void SceneRuntimeContext::RegisterLayerAuthoredName(std::string runtime_name,
                                                    std::string authored_name) {
    if (runtime_name.empty() || ! m_nodes.contains(runtime_name)) return;
    m_layer_authored_names.insert_or_assign(std::move(runtime_name), std::move(authored_name));
}

void SceneRuntimeContext::DeclareLayerName(std::string runtime_name, std::string authored_name) {
    if (runtime_name.empty() || runtime_name == authored_name) return;
    if (! authored_name.empty()) RegisterLayerAlias(authored_name, runtime_name);
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
    const auto found = m_text_layers.find(std::string(name));
    if (found == m_text_layers.end()) return false;
    TextLayer& layer = found->second;
    if (property == "pointsize") {
        const std::string text(value);
        char*             end = nullptr;
        const float       size = std::strtof(text.c_str(), &end);
        if (end == text.c_str() || ! std::isfinite(size) || size <= 0.0f) return false;
        layer.SetPointSize(size);
        return true;
    }
    if (property == "horizontalalign" || property == "verticalalign") {
        const bool horizontal = property == "horizontalalign";
        if (! IsAlignmentWord(horizontal, value)) return false;
        const auto& state = layer.state();
        layer.SetAlignment(horizontal ? std::string(value) : state.horizontal_align,
                           horizontal ? state.vertical_align : std::string(value));
        return true;
    }
    if (property == "font") {
        TextLayerState state = layer.state();
        const std::string font_key(value);
        if (m_text_font_resolver) {
            m_text_font_resolver(state, font_key);
        } else {
            state.font_key = font_key;
        }
        layer.SetFont(font_key, state.resolved_font_kind, state.resolved_font_identity,
                      state.resolved_font_path, state.resolved_font_face, state.resolved_font_fit,
                      state.resolved_font_data);
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
    MarkSceneGraphMutated("create-layer");
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
    MarkSceneGraphMutated("reparent");
    return true;
}

bool SceneRuntimeContext::SetNodeSize(std::string_view name, const linalg::Vector2f& size) {
    const std::string key(name);
    const auto        found = m_nodes.find(key);
    if (found == m_nodes.end() || found->second == nullptr || m_text_layers.contains(key)) {
        return false;
    }
    if (! size.allFinite() || size.x() <= 0.0f || size.y() <= 0.0f) return false;
    const auto held = m_node_size.find(key);
    if (held == m_node_size.end() || held->second.x() <= 0.0f || held->second.y() <= 0.0f) {
        return false;
    }
    const linalg::Vector2f old_size = held->second;
    if (SizeNearlyEqual(old_size, size, 0.001f)) return true;

    // Only a plain card can be stretched: one vertex array of positions and texture
    // coordinates and no indices.
    SceneNode* node = found->second;
    SceneMesh* mesh = node->Mesh();
    if (mesh == nullptr || mesh->VertexCount() != 1 || mesh->IndexCount() != 0) return false;
    const auto& source   = mesh->GetVertexArray(0);
    const auto  offsets  = source.GetAttrOffsetMap();
    const auto  position = offsets.find(std::string(WE_IN_POSITION));
    if (position == offsets.end() || offsets.size() != 2 || source.VertexCount() == 0) return false;
    const std::size_t first = position->second.offset / sizeof(float);

    // The layer's geometry becomes its own: a copy made from the same template keeps the
    // template's. Corners stretch about the centre of the card, texture coordinates stay.
    float centre_x = 0.0f, centre_y = 0.0f;
    {
        float min_x = std::numeric_limits<float>::max(), max_x = std::numeric_limits<float>::lowest();
        float min_y = min_x, max_y = max_x;
        for (std::size_t i = 0; i < source.VertexCount(); ++i) {
            const float* point = source.Data() + i * source.OneSize() + first;
            min_x = std::min(min_x, point[0]);
            max_x = std::max(max_x, point[0]);
            min_y = std::min(min_y, point[1]);
            max_y = std::max(max_y, point[1]);
        }
        centre_x = (min_x + max_x) * 0.5f;
        centre_y = (min_y + max_y) * 0.5f;
    }
    const float ratio_x = size.x() / old_size.x();
    const float ratio_y = size.y() / old_size.y();

    auto stretched = std::make_shared<SceneMesh>(mesh->UpdateDriver());
    stretched->SetPrimitive(mesh->Primitive());
    stretched->SetPointSize(mesh->PointSize());
    SceneVertexArray vertices(source.Attributes(), source.VertexCount());
    std::vector<float> data(source.Data(), source.Data() + source.DataSize());
    for (std::size_t i = 0; i < source.VertexCount(); ++i) {
        float* point = data.data() + i * source.OneSize() + first;
        point[0] = centre_x + (point[0] - centre_x) * ratio_x;
        point[1] = centre_y + (point[1] - centre_y) * ratio_y;
    }
    vertices.SetVertexs(0, data);
    stretched->AddVertexArray(std::move(vertices));
    stretched->MaterialSlots() = mesh->MaterialSlots();
    const bool dynamic = stretched->Dynamic();
    node->AddMesh(stretched);
    if (dynamic) {
        stretched->SetDirty();
    } else {
        MarkSceneGraphMutated("stretch-mesh");
    }
    RegisterNodeSize(key, size);
    return true;
}

linalg::Vector2f SceneRuntimeContext::NodeParallaxDepth(std::string_view name) const {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || m_scene == nullptr ||
        m_scene->shaderValueUpdater == nullptr) {
        return linalg::Vector2f::Zero();
    }
    const auto depth = m_scene->shaderValueUpdater->NodeParallaxDepth(found->second);
    return linalg::Vector2f(depth[0], depth[1]);
}

bool SceneRuntimeContext::SetNodeParallaxDepth(std::string_view name,
                                               const linalg::Vector2f& depth) {
    const auto found = m_nodes.find(std::string(name));
    if (found == m_nodes.end() || found->second == nullptr || m_scene == nullptr ||
        m_scene->shaderValueUpdater == nullptr || ! depth.allFinite()) {
        return false;
    }
    // A graph built while the layer stood still has it as a pass that never
    // changes; one that starts following the cursor (or stops) needs a new one.
    if (m_scene->shaderValueUpdater->SetNodeParallaxDepth(found->second, depth.x(), depth.y())) {
        MarkSceneGraphMutated("parallax-depth");
    }
    return true;
}

std::unique_ptr<SceneRuntimeContext> CreateSceneRuntimeContext(SceneRuntimeBootstrap bootstrap) {
    return std::make_unique<SceneRuntimeContext>(std::move(bootstrap));
}

} // namespace wallpaper
