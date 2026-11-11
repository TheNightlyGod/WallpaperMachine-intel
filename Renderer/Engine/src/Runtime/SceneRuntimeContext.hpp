#pragma once

#include "Project/ProjectProperties.hpp"
#include "Audio/include/Audio/AudioResponseService.h"
#include "Runtime/CameraPath.hpp"
#include "Runtime/GlobalCameraPath.hpp"
#include "Runtime/ScalarAnimation.hpp"
#include "Scene/Parse/WPPuppet.hpp"
#include "Scene/include/Scene/SceneShader.h"
#include "Scene/include/Scene/SceneUpdateDemand.hpp"
#include "Runtime/SceneScriptStorage.hpp"
#include "Text/TextLayer.hpp"
#include "Video/VideoTextureSource.hpp"

#include "Utils/Linalg.hpp"

#include <array>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace wallpaper
{

class DynamicValue;
class ScriptEngine;
class SceneScriptProgram;
struct SceneMaterial;
struct SceneGeneralState;
struct SceneForceState;
struct SceneModelDataState;
struct ModelDataUpdate;
struct ModelDataLayerOptions;
struct ModelDataMaterial;
struct ModelDataResource;
namespace wpscene { class WPSceneGeneral; }
struct Image;
class ScriptedDynamicValue;
class SceneNode;
class SceneLight;
class SceneMesh;
class SceneImageEffectLayer;
struct SceneImageEffect;
class Scene;
class SceneCamera;
class WPSoundStream;
struct ScriptHostContext;

struct SceneRuntimeBootstrap {
    int               canvas_width { 0 };
    int               canvas_height { 0 };
    // The values the scene loads with.
    ProjectProperties project_properties {};
    // What the project declares, apart from any saved choice already folded into
    // `project_properties`. Unset means the loaded table is also the authored one.
    std::optional<ProjectProperties> authored_project_properties {};
};

// What showing a property document on a running scene did.
struct ProjectPropertyPreview {
    // Sorted names whose value in effect changed.
    std::vector<std::string> changed;
    // Sorted names of load-only properties (see `NoteLoadOnlyProperty`) the
    // document asked to change but that were held at the value the scene loaded
    // with, because a fresh load is the only thing that applies them.
    std::vector<std::string> deferred;
};

// How window-normalized cursor input maps onto scene coordinates:
// world = origin + (x, 1 - y) * size. `content` is the part of that rectangle
// the wallpaper draws; input outside it is over letterbox bars, not the scene.
struct CursorViewport {
    linalg::Vector2f origin { linalg::Vector2f::Zero() };
    linalg::Vector2f size { linalg::Vector2f::Zero() };
    linalg::Vector2f content_origin { linalg::Vector2f::Zero() };
    linalg::Vector2f content_size { linalg::Vector2f::Zero() };
};

struct RuntimePendingTextLayerJob {
    std::string    name;
    uint64_t       revision { 0 };
    TextLayerState state;
};

// Downsampled coverage of an image layer's base texture. Cursor hit tests
// consult it so transparent texels do not count as the layer; without one the
// layer's authored rectangle is the hit area.
struct NodeHitMask {
    uint32_t             width { 0 };
    uint32_t             height { 0 };
    std::vector<uint8_t> alpha;

    static constexpr uint8_t kOpaqueThreshold = 16;

    [[nodiscard]] bool covers(float u, float v) const noexcept;
};

class SceneRuntimeContext {
public:
    struct LayerRegistrationMemo;

    explicit SceneRuntimeContext(SceneRuntimeBootstrap bootstrap);
    ~SceneRuntimeContext();

    void Tick(double frame_time);

    ScriptEngine&            scriptEngine();
    const ScriptHostContext& hostContext() const;
    /// The text behind the scripts' `localStorage` (configured by the scene before scripts start).
    SceneScriptStorage&      ScriptStorage();
    // What the project declares: the table a document is applied over, and the
    // one a reset returns to. It is not the table the scene loaded with when a
    // saved choice was loaded over it.
    const ProjectProperties& defaultProjectProperties() const;
    // The values currently in effect.
    const ProjectProperties& projectProperties() const;
    // Property bindings are refreshed as one transaction before script callbacks
    // see the change, so callback-only programs never initialize on a partial set.
    bool          ProjectPropertiesChanging() const { return m_project_properties_changing; }
    // `override_properties` is the whole document: the declared defaults with
    // exactly these values over them. A property the document leaves out is at
    // its declared default again, whatever the scene loaded with. Returns the
    // sorted names whose value in effect changed.
    std::vector<std::string> ApplyProjectPropertyOverride(const ProjectProperties& override_properties);
    // The declared defaults, as applying an empty document.
    std::vector<std::string> ResetProjectPropertyOverride();
    // Records that something read property `name` once, while the scene loaded,
    // and never again: a scenetexture picked into a material slot, or an effect
    // a toggle builds or leaves out. Only a fresh load applies a new value to
    // such a consumer, so a preview keeps the property at the value it was read
    // with (`name` absent from the table is held absent). Parse-time only.
    void NoteLoadOnlyProperty(std::string_view name);
    // The sorted names noted above.
    std::vector<std::string> LoadOnlyProperties() const;
    // `ApplyProjectPropertyOverride` for a document shown without reloading the
    // scene: the same whole document, except that every load-only property stays
    // at the value it was read with, for every consumer of that name, live ones
    // included, so no property is ever half applied. A load-only property the
    // document asked for something else is reported in `deferred`.
    ProjectPropertyPreview PreviewProjectPropertyOverride(const ProjectProperties& override_properties);
    void          AttachScene(Scene* scene);
    /// Puts the cursor at a scene position, canvas units for hit tests and
    /// scripts alike, whatever the camera: the probes' way to click a layer.
    void          SetCursorWorldPosition(const linalg::Vector3f& value);
    // World rectangle the window shows, so window-normalized cursor input lands
    // where the presented wallpaper actually draws each layer.
    void          SetCursorViewport(const CursorViewport& viewport);
    /// The display's pixel resolution, which `engine.screenResolution` reports.
    /// Distinct from the cursor viewport above, which is scene world units,
    /// and from the rasterization size, which internal quality may reduce.
    void          SetScreenResolution(const linalg::Vector2f& resolution);
    /// The interface language scripts are told about in `applyGeneralSettings`,
    /// as a lower-case BCP-47 tag (`en-us`, `zh-cn`). A tag in any case, or with
    /// `_` for `-`, is normalized; nothing more is: mapping an operating-system
    /// locale (`zh_Hans_CN`) to the tags Wallpaper Engine's scripts switch on
    /// (`zh-cn`) is the caller's job. Nothing calls this yet, so scripts are
    /// told `en-us`. Scripts that are running hear of a change on the next tick.
    void          SetLanguage(std::string_view language);
    const std::string& Language() const;
    void          SetCursorInput(float x, float y);
    void          SetCursorEnter(bool entered);
    void          SetCursorButton(int button, bool pressed);
    void          SetCursorButtons(uint32_t down, uint32_t pressed, uint32_t released);
    void          BeginFrame();
    DynamicValue* FindPropertyValue(std::string_view name) const;
    /// The live value a setting bound to property `name` follows. A name the table does not
    /// declare gets a value that holds `authored` until a property document supplies the
    /// name, so a binding made before the name appeared follows it once it does (a name
    /// `FindPropertyValue` still answers nothing for until then).
    DynamicValue* FollowProperty(std::string_view name, const DynamicValue& authored);
    void          RegisterScriptedValue(ScriptedDynamicValue* value);
    /// A scripted value that goes away (a setting resolved only to read its first
    /// value, a rolled-back layer) leaves the registry, so nothing reaches it
    /// afterwards. `ScriptedValueRegistryToken` expires with the runtime, which
    /// is how a value that outlives it knows there is no registry to leave.
    void          UnregisterScriptedValue(ScriptedDynamicValue* value);
    std::weak_ptr<void> ScriptedValueRegistryToken() const { return m_scripted_value_registry; }
    void          RegisterNode(std::string name, SceneNode* node);
    void          RegisterLayerAlias(std::string authored_name, std::string runtime_name);
    std::string   ResolveLayerName(std::string_view name) const;
    /// The layers as `thisScene.getLayerCount()`, `getLayer(index)`,
    /// `enumerateLayers()`, `getLayerIndex()` and `sortLayer()` count them: every
    /// layer registered by name, in the order the scene file declares them, then
    /// the ones scripts made. A hidden template a script's `createLayer` copies
    /// from is not a layer of the scene. One order serves all five:
    /// `SortLayer` changes it, and the draw order follows it.
    ///
    /// Only layers the parser instantiated are counted: an object the scene file
    /// marks statically invisible (and no script or property can show) is never
    /// built, so it has no index, no id and no place in this list.
    std::size_t   LayerCount() const;
    std::string   LayerNameAt(std::size_t index) const;
    /// The position of a layer (by runtime name or authored name) in that order,
    /// or -1 for a name that is not a layer.
    int           LayerIndex(std::string_view name) const;
    /// Moves a layer to position `index` of that order (clamped to the ends) and
    /// puts it among its siblings in the scene graph where the order now says,
    /// which is the order it is drawn in. False when nothing changed.
    bool          SortLayer(std::string_view name, int index);
    /// The name the scene file gives the layer registered as `runtime_name`,
    /// which is what a script's `layer.name` reads. A layer whose authored name is
    /// shared or empty is registered under a generated key; this is its own
    /// name (possibly empty). A layer with no authored name on record answers
    /// with the name it is registered under.
    void          RegisterLayerAuthoredName(std::string runtime_name, std::string authored_name);
    std::string   LayerAuthoredName(std::string_view runtime_name) const;
    /// Records the name the scene file gives a layer, and the name lookup that finds it, before
    /// the layer itself is registered. The parser declares every layer so that a script that
    /// compiles early (and looks later layers up while it does) already sees the names.
    void          DeclareLayerName(std::string runtime_name, std::string authored_name);
    /// Puts the registered layers in the scene file's declaration order. Names
    /// not listed keep the order they were registered in, after the listed ones.
    void          SetLayerOrder(const std::vector<std::string>& names);
    /// The scene.json `id` of a layer, which `getLayerByID` looks it up by.
    void          RegisterLayerId(int32_t id, std::string name);
    std::string   LayerNameForId(int32_t id) const;
    /// A script reads `thisScene.getInitialLayerConfig(layer)` to copy what the
    /// scene file says about a layer. The scene's object list is only kept when
    /// a script asks for it (`InitialLayerConfigRequested`), since it holds
    /// every script the scene carries.
    void          RequestInitialLayerConfig();
    bool          InitialLayerConfigRequested() const;
    /// Answers for a layer's scene.json `id` with that object as JSON text.
    using InitialLayerConfigProvider = std::function<std::string(int32_t id)>;
    void          SetInitialLayerConfigProvider(InitialLayerConfigProvider provider);
    /// The layer's own object from the scene file, as JSON text; empty when the
    /// layer is unknown, was made by a script, or the object list was not kept.
    std::string   InitialLayerConfigJson(std::string_view name) const;
    void          UnregisterNode(std::string_view name);
    void          RollbackNodeRegistration(
                     std::string_view name,
                     SceneNode* node,
                     std::shared_ptr<const LayerRegistrationMemo> previous);
    [[nodiscard]] std::shared_ptr<LayerRegistrationMemo>
                  CaptureNodeRegistration(std::string_view name) const;
    void          RegisterNodeSize(std::string name, linalg::Vector2f value);
    void          RegisterNodeHitMask(std::string name, NodeHitMask mask);
    // The copy shares playback state with the render passes that own it.
    void          RegisterPuppetLayer(std::string name, WPPuppetLayer layer);
    WPPuppetLayer* FindPuppetLayer(std::string_view name);
    void RefreshPuppetAttachments(const WPPuppetLayer& layer);
    // An image layer's script members `brightness`, `colorBlendMode`, `perspective`,
    // `copybackground`, `nointerpolation`, `clampuvs`, `ledsource` and `castshadow`
    // (we_ss_reg_ImageLayer 0x1401EE520, decompiles/A-7a.md). Wallpaper Engine's setters
    // only write the field; a write shows where its renderer reads the field per draw:
    // `brightness` (the tint of `brightness_materials`, the layer's tinted materials in an
    // HDR scene) and `copybackground` (the alpha rule of the layer's children). The others
    // are read when the layer is built, so a write is kept and read back but changes
    // nothing drawn; `castshadow` is kept for the shadow caster pass. Numbers come and go
    // as doubles (flags 0 or 1). Unknown layers or members answer nothing / false.
    struct ImageLayerFlags {
        double  brightness { 1.0 };
        int32_t colorBlendMode { 0 };
        bool    perspective { false };
        bool    copybackground { true };
        bool    nointerpolation { false };
        bool    clampuvs { true };
        bool    ledsource { false };
        bool    castshadow { false };
    };
    void RegisterImageLayerFlags(std::string name, SceneNode* node, ImageLayerFlags flags,
                                 std::vector<std::shared_ptr<SceneMaterial>> brightness_materials);
    std::optional<double> NodeLayerFlag(std::string_view name, std::string_view flag) const;
    bool                  SetNodeLayerFlag(std::string_view name, std::string_view flag, double value);
    // A light layer's script members (we_ss_reg_LightLayer 0x14025DA80, decompiles/A-7g.md):
    // `color`, `intensity`, `radius`, `exponent`, `innercone`, `outercone` (degrees) and
    // `controlpoint` reach the light the renderer packs every frame; `density`,
    // `volumetricsexponent`, `cascadedistance0-2`, `lightsourcesize`, `castshadow`,
    // `usecookie` and `castvolumetrics` are kept on the light for the shadow and volumetric
    // passes; `light` changes the kind. A member reads as one or three numbers (flags 0 or 1).
    // Unknown layers or members answer nothing / false.
    void RegisterLightLayer(std::string name, SceneLight* light, std::string kind);
    std::optional<std::vector<double>> NodeLightMember(std::string_view name, std::string_view member) const;
    bool SetNodeLightMember(std::string_view name, std::string_view member, std::span<const double> values);
    std::optional<std::string> NodeLightKind(std::string_view name) const;
    bool                       SetNodeLightKind(std::string_view name, std::string kind);
    // A layer's `sortorder` (int @292, we_ss_reg_SceneObjectBase 0x1401E0530, decompiles/A-7d.md):
    // 0 unless the file says otherwise. Wallpaper Engine's setter only stores it; its draw sorts
    // the objects by it every frame when the scene has `customsortorder` (sub_14018AAC0), so a
    // write there rebuilds the graph. Unknown layers answer nothing / false.
    void                   RegisterNodeSortOrder(std::string name, int32_t order);
    std::optional<int32_t> NodeSortOrder(std::string_view name) const;
    bool                   SetNodeSortOrder(std::string_view name, int32_t order);
    void                   SetCustomSortOrder(bool custom) { m_custom_sort_order = custom; }
    bool                   CustomSortOrder() const { return m_custom_sort_order; }
    // A 3D model layer's script flags `rootmotion` and `castshadow` (we_ss_reg_ModelLayer
    // 0x140227470). The shadow caster pass reads `castshadow`; `rootmotion` reaches the
    // model's puppet layer. Unknown layers or flag names answer nothing / false.
    void                RegisterModelFlags(std::string name, bool rootmotion, bool castshadow);
    bool                SetModelFlag(std::string_view name, std::string_view flag, bool value);
    std::optional<bool> ModelFlag(std::string_view name, std::string_view flag) const;
    // Mirrors the SceneScript IAnimationLayer operations. Unknown layers and
    // operations return 0.
    /// Tells `addEndedCallback` listeners about the single-shot animation
    /// layers that finished playing since the last call. Run once per tick.
    void          DispatchPuppetLayerEvents();
    /// Evaluates puppet poses at the scene time before the scripts run, as Wallpaper Engine
    /// runs every animation before any script on a frame; the draw then reads the same
    /// pose. A `rootmotion` model's extracted motion moves its node here (sub_140225900:
    /// origin += world 3x3 * step, yaw about the layer's y axis).
    void          EvaluatePuppetPoses();
    double        PuppetAnimationControl(std::string_view layer_name,
                                         std::string_view animation_layer,
                                         std::string_view operation, double value,
                                         bool has_value, bool by_serial = false);
    // createAnimationLayer / playSingleAnimation (0x14020EA30 / 0x14020EF40): a new animation
    // layer on the puppet of `layer_name`, from an animation name, or from a config object's
    // JSON text when `config_object`; `config_text` is the second argument's JSON text (empty
    // for none). `single_shot` layers go after their first cycle. The new layer's serial; -1
    // when no layer was made.
    int32_t       CreatePuppetAnimationLayer(std::string_view layer_name, bool config_object,
                                             std::string_view animation, std::string_view config_text,
                                             bool single_shot);
    /// The authored name of the animation layer a script addressed by name or
    /// by position; empty when the layer or the animation layer is unknown.
    std::string   PuppetAnimationLayerName(std::string_view layer_name,
                                           std::string_view animation_layer, bool by_serial = false);
    /// The puppet bone API the script bone methods use (B-D8, I13). World is the layer's
    /// world matrix times the bone's model-space matrix (+832 = world * +712); Local is the
    /// bone's parent-relative matrix (+784). Column-major like `NodeTransformMatrix`. A world
    /// write moves that bone alone (0x14020F350); a local write moves the bone and every bone
    /// below it (0x14020F840). Unknown layers or bones answer 0 / -1 / nothing / false.
    enum class PuppetBoneSpace { World, Local };
    int32_t PuppetBoneCount(std::string_view layer);
    int32_t PuppetBoneIndex(std::string_view layer, std::string_view bone);
    int32_t PuppetBoneParentIndex(std::string_view layer, int32_t bone);
    std::optional<linalg::Matrix4d> PuppetBoneTransform(std::string_view layer, int32_t bone,
                                                        PuppetBoneSpace space);
    bool SetPuppetBoneTransform(std::string_view layer, int32_t bone, PuppetBoneSpace space,
                                const linalg::Matrix4d& matrix);
    int32_t PuppetBlendShapeIndex(std::string_view layer, std::string_view name);
    std::optional<float> PuppetBlendShapeWeight(std::string_view layer, int32_t shape);
    bool SetPuppetBlendShapeWeight(std::string_view layer, int32_t shape, float weight);
    /// Bone physics (Appendix B item 2) is not simulated yet: no bone takes an impulse or a
    /// reset, so both answer false.
    bool ApplyPuppetBoneImpulse(std::string_view layer, int32_t bone, const linalg::Vector3d& linear,
                                const linalg::Vector3d& angular_degrees);
    bool ResetPuppetBoneSimulation(std::string_view layer, int32_t bone);
    void          RegisterLayerTemplate(std::string template_path, std::shared_ptr<SceneNode> node,
                                        linalg::Vector2f size);
    // Called synchronously on a registry miss. The loader registers the requested
    // normalized template without attaching a drawable source to the scene graph.
    void          SetLayerTemplateLoader(std::function<bool(std::string_view)> loader);
    /// Called by the loader when the model at `template_path` exists but is of a shape that
    /// cannot be copied (a passthrough or compose model), so the refusal that follows is
    /// logged as that and not as a missing template.
    void          ReportUnsupportedLayerTemplate(std::string_view template_path);
    void          RegisterNodeVisibility(std::string name, SceneNode* node,
                                         std::unique_ptr<DynamicValue> value);
    /// An effect whose `visible` a script decides, as Wallpaper Engine's
    /// effect object does: its chain is built with it, and a switch marks the
    /// scene graph changed so the host resolves the chain again over the
    /// effects that run and rebuilds the render graph before the next frame.
    void          RegisterEffectVisibility(std::shared_ptr<SceneImageEffect> effect,
                                           std::unique_ptr<DynamicValue> value);
    struct EffectMaterialPass {
        std::shared_ptr<SceneNode>                   node;
        std::shared_ptr<SceneMaterial>               material;
        std::unordered_map<std::string, std::string> aliases;
        std::string                                 material_name;
        std::unordered_set<std::string>              rad2deg;
    };
    /// Makes `effect`, an effect of layer `layer_key`, the `thisObject` of the script that decides
    /// its visibility (or an entry of `thisLayer.getEffect(...)`) and returns the reference
    /// scripts reach it by. Called before the script exists, so the effect is there when the
    /// script's top level runs; `RegisterEffectVisibility` then ties the script's value to it.
    std::string   RegisterEffectObject(std::string_view layer_key,
                                       std::shared_ptr<SceneImageEffect> effect,
                                       std::string_view effect_name = {},
                                       std::vector<EffectMaterialPass> passes = {},
                                       bool listed_on_layer = false);
    std::string   EffectObjectName(std::string_view reference) const;
    bool          HasEffectObject(std::string_view reference) const;
    /// What a script reads from, and writes to, `thisObject.visible` of an effect object. A write
    /// goes through the effect's visibility value when it has one, so the script's next run and
    /// the effect agree, and the scene graph is rebuilt; an unknown reference reads false.
    bool          EffectObjectVisible(std::string_view reference) const;
    bool          SetEffectObjectVisible(std::string_view reference, bool visible);
    std::size_t   LayerEffectCount(std::string_view layer_key) const;
    std::string   LayerEffectReference(std::string_view layer_key, std::size_t index) const;
    std::string   LayerEffectReferenceByName(std::string_view layer_key,
                                             std::string_view effect_name) const;
    std::size_t   EffectMaterialCount(std::string_view reference) const;
    int32_t       EffectMaterialIndexByName(std::string_view reference, std::string_view name) const;
    /// The constant `name` (a material name or a uniform) of an effect pass's material as it
    /// holds it now: what the scene or a script set, else the shader's default; empty when the
    /// pass has no such constant.
    std::vector<float> EffectMaterialConstant(std::string_view reference, std::size_t pass_index,
                                              std::string_view name) const;
    bool          SetEffectMaterialProperty(std::string_view reference, std::string_view name,
                                            std::span<const float> values, bool scalar);
    bool          SetEffectMaterialConstant(std::string_view reference, std::size_t pass_index,
                                            std::string_view name,
                                            std::span<const float> values);
    /// `executeMaterialFunction(name)` on the effect object `effect_reference` (I11): queues the
    /// clears of the effect's function `name` on the scene, which the renderer runs at the start
    /// of its next frame before any pass. False, and nothing queued, when the effect is unknown or
    /// has no such function (Wallpaper Engine `sub_1401EE3A0` then does nothing).
    bool          RunEffectFunction(std::string_view effect_reference, std::string_view name);
    /// A clock that belongs to one setting a script sits on (`thisObject.getAnimation()` with no
    /// name answers it), and the reference scripts reach it by.
    std::string   RegisterSettingAnimation(std::shared_ptr<ScalarAnimationPlayback> animation);
    /// The clock of a keyed setting that a script drives: it runs with the others, but belongs to
    /// the setting and no layer's name lookup finds it.
    std::shared_ptr<ScalarAnimationPlayback> RegisterSettingClock(ScalarAnimation animation);
    ScalarAnimationPlayback* FindSettingAnimation(std::string_view reference) const;
    /// What follows a text layer's effects as a script switches them, and what follows its card.
    /// Wallpaper Engine counts the visible effect passes of a text layer afresh whenever an
    /// effect's visibility changes: the card is padded, and drawn as a composite, only while one
    /// is visible. Otherwise the glyphs go straight onto the scene (Appendix G T.7.2).
    struct TextMaterialKey {
        bool distance_field { false }, outline { false }, blur { false }, shadow { false };
        bool depth { false }, background { false };
        bool operator==(const TextMaterialKey&) const = default;
    };
    struct TextMaterialSet {
        std::shared_ptr<SceneMaterial> glyphs, color, background;
    };
    using TextMaterialFactory = std::function<std::optional<TextMaterialSet>(
        const std::string&, const TextMaterialKey&, const TextStyleUniforms&)>;
    void SetTextMaterialFactory(TextMaterialFactory factory);
    using TextBackgroundAlphaBinding = std::function<void(const std::shared_ptr<SceneMaterial>&, bool)>;
    void SetTextBackgroundAlphaBinding(std::string_view name, TextBackgroundAlphaBinding binding);
    struct TextEffectGate {
        /// The layer is padded whatever its effects do: a colour blend, an LED source, an opaque
        /// background, or fog in the scene.
        bool                                           padded_regardless { false };
        /// The layer is a composite whatever its effects do: a colour blend, an LED source, or
        /// fog in the scene (whose fog pass the composite goes through).
        bool                                           composites_regardless { false };
        /// A particle emitter reads the published glyphs even while this layer is hidden.
        /// This keeps CPU layout current without creating a render-graph producer.
        bool                                           particle_image_source { false };
        bool                                           padding_without_background { false };
        bool                                           depth_available { false };
        TextMaterialKey                                material_key;
        std::optional<TextMaterialKey>                 pending_material_key;
        std::optional<TextMaterialSet>                 pending_materials;
        TextBackgroundAlphaBinding                     background_alpha_binding;
        /// The effects the layer's chain is built with; one that is visible counts.
        std::vector<std::shared_ptr<SceneImageEffect>> effects;
        /// The layer's chain, its node, and the cameras the node draws through as a composite
        /// (into the chain's buffer) and straight onto the scene. Null for a layer without one.
        SceneImageEffectLayer*                         chain { nullptr };
        SceneNode*                                     node { nullptr };
        std::string                                    chain_camera;
        std::string                                    own_camera;
        /// The material slot 0 of the layer's mesh takes: the seed of the composite, and the
        /// background quad of the direct draw (null without `opaquebackground`).
        std::shared_ptr<SceneMaterial>                 seed;
        std::shared_ptr<SceneMaterial>                 background;
        /// The glyph materials, drawn additively straight onto the scene for colour blend 31.
        std::vector<std::shared_ptr<SceneMaterial>>    glyphs;
        bool                                           additive { false };
    };
    /// Puts a text layer into its composite or its direct draw: the node's camera and
    /// transform, slot 0's material, the glyphs' blend and the chain's bypass.
    static void   ApplyTextDrawMode(const TextEffectGate& gate, bool composite);
    /// Registers the gate of the text layer `name` and applies it: the layer's padding and
    /// composite follow its effects from here on.
    void          RegisterTextEffectGate(std::string name, TextEffectGate gate);
    // A node's origin, scale or angles. `animation` is the authored timeline
    // that plays the value when no script or property writes it.
    void          RegisterNodeTranslate(std::string name, SceneNode* node,
                                        std::unique_ptr<DynamicValue> value,
                                        std::shared_ptr<const NodeVec3Animation> animation = {});
    void RegisterNodeScale(std::string name, SceneNode* node, std::unique_ptr<DynamicValue> value,
                           std::shared_ptr<const NodeVec3Animation> animation = {});
    void RegisterNodeRotation(std::string name, SceneNode* node,
                              std::unique_ptr<DynamicValue> value,
                              std::shared_ptr<const NodeVec3Animation> animation = {});
    void RegisterTextLayer(std::string name, TextLayerState state);
    /// `layout` is `MeasureTextLayerLayout(state)`, which the caller has measured
    /// already: the layer does not measure the text a second time.
    void RegisterTextLayer(std::string name, TextLayerState state, TextLayerLayout layout);
    void RegisterTextValue(std::string name, std::unique_ptr<DynamicValue> value,
                           bool apply_current_value = true);
    void RegisterMaterialConstant(std::shared_ptr<SceneMaterial> material, std::string name,
                                  std::unique_ptr<DynamicValue> value,
                                  std::shared_ptr<const MaterialConstantAnimation> animation = {});
    void RegisterSceneClearColor(std::unique_ptr<DynamicValue> value);
    void RegisterSceneGeneral(const wpscene::WPSceneGeneral& general);
    void RegisterSceneForceSettings(const wpscene::WPSceneGeneral& general);
    void SeedSceneGeneralValue(std::string_view name, std::span<const float> value);
    void AliasSceneGeneralDriver(std::string_view name, DynamicValue* value);
    std::optional<ShaderValue> SceneGeneralValue(std::string_view name) const;
    bool SetSceneGeneralValue(std::string_view name, std::span<const float> value);
    void CopySceneGeneralSettings(wpscene::WPSceneGeneral& general) const;
    void SetSceneGeneralFactory(std::function<bool(uint32_t)> factory);
    /// Rechecks the existing post-process shape after physical target sizing.
    /// Returns true only when the caller must replace its render graph.
    bool RefreshSceneGeneralPostProcesses();
    void SetSceneGeneralBloomWriter(std::function<void(std::string_view, const ShaderValue&)> writer);
    /// A uniform every material of the scene shares (`g_LightAmbientColor`, the fog colours
    /// and parameters) whose `general` settings a script or a user property drives: `compute`
    /// turns the inputs into the uniform, recomputed on a tick in which one of them changed
    /// and written into every material `AddSceneUniformMaterial` handed over that declares it.
    /// A scene whose settings are all literal registers none, and its uniforms stay the
    /// constants the materials were loaded with.
    using SceneUniformCompute = std::function<ShaderValue(std::span<DynamicValue* const>)>;
    void RegisterSceneUniform(std::string uniform, std::vector<std::unique_ptr<DynamicValue>> inputs,
                              SceneUniformCompute compute);
    bool HasSceneUniforms() const noexcept;
    /// Hands a material to every scene uniform it declares, and writes the current value.
    void AddSceneUniformMaterial(const std::shared_ptr<SceneMaterial>& material);
    /// Removes a retired material without leaving weak records until an input changes.
    void ForgetSceneUniformMaterial(const std::shared_ptr<SceneMaterial>& material);
    /// The scene camera's shake (`general.camerashake*`), each setting static
    /// or bound to a property or script. Applied to the active camera every
    /// tick as Wallpaper Engine applies it.
    void RegisterCameraShake(std::unique_ptr<DynamicValue> enabled,
                             std::unique_ptr<DynamicValue> amplitude,
                             std::unique_ptr<DynamicValue> speed,
                             std::unique_ptr<DynamicValue> roughness);
    void RegisterSceneZoomAnimation(std::shared_ptr<ScalarAnimationPlayback> animation);
    /// A scene zoom bound to a user property or a script: applied now and
    /// whenever the value changes.
    void RegisterSceneZoom(std::unique_ptr<DynamicValue> zoom);
    // SceneScript's static camera snapshot: eye, center, up, zoom. WE loads the authored
    // position after startup init callbacks; an init-written zoom survives that load.
    using StaticCameraTransforms = std::array<double, 10>;
    void RegisterStaticCameraTransforms(StaticCameraTransforms value);
    StaticCameraTransforms GetStaticCameraTransforms() const { return m_static_camera; }
    bool SetStaticCameraTransforms(const StaticCameraTransforms& value, uint32_t fields);
    /// A camera layer's timeline: one clock, and the zoom and origin curves it
    /// plays. `origin_base` is the authored origin a relative timeline offsets.
    struct CameraShotTimeline {
        std::shared_ptr<ScalarAnimationPlayback>      clock;
        std::optional<ScalarAnimation>                zoom;
        std::array<std::optional<ScalarAnimation>, 3> origin;
        bool                                          origin_relative { false };
        linalg::Vector3f                               origin_base { linalg::Vector3f::Zero() };
    };
    /// A camera layer of a scene projected by its canvas. Shots are kept in
    /// authored order and the last visible one frames the view -- its zoom
    /// about the view's centre, its origin as that centre's offset from the
    /// canvas centre -- re-decided every tick; with none visible the whole
    /// canvas is shown. `zoom` is the static, user-bound or scripted zoom a
    /// zoom curve in `timeline` replaces. `origin_bound` says a script or a user
    /// property writes the origin: until a tick has applied it the layer holds
    /// the editor's last value, which need not be where the shot is, so the
    /// canvas centre stands in for it.
    void RegisterCameraShot(SceneNode* node, std::unique_ptr<DynamicValue> zoom,
                            CameraShotTimeline timeline, bool origin_bound);
    void RegisterPerspectiveCameraShot(std::shared_ptr<SceneNode> node, SceneCamera* camera,
                                       double fov, CameraPathPlayback path);
    void RegisterGlobalCameraPaths(SceneCamera* camera, std::shared_ptr<SceneNode> node,
                                   GlobalCameraPlayback paths);
    bool IsCameraLayer(std::string_view name) const;
    bool HasCameraPaths() const { return m_has_camera_paths; }
    bool CameraFadeEnabled() const { return m_camera_fade_enabled; }
    bool HasCameraFadeNode() const { return !m_camera_fade_node.expired(); }
    void SetCameraFadeEnabled(bool enabled);
    void RegisterCameraFadeNode(const std::shared_ptr<SceneNode>& node);
    // `replay_current` false registers only future assignments (including an
    // assignment of the held value), without making a static value a driver.
    void RegisterDynamicValueListener(std::unique_ptr<DynamicValue> value,
                                      std::function<void(const DynamicValue&)> callback,
                                      bool replay_current = true);
    void RegisterNodeEffectFinal(std::string name, SceneNode* node, SceneImageEffectLayer* layer,
                                 TextLayerRenderFrame target_frame = {});
    /// Changes the style values of text layer `name` that only the font shader takes (sizes,
    /// opacity, offset, colours; `TextLayer::SetStyleUniformValues`) and writes the layer's
    /// `g_RenderVar0..3` into its glyph materials at once: no layout, no rebuild (T.8).
    void EditTextStyleUniforms(std::string_view name, const std::function<void(TextStyle&)>& edit);
    void SetTextBackgroundColor(std::string_view name, const linalg::Vector3f& color);
    void SetTextBackgroundBrightness(std::string_view name, float brightness);
    /// Lays a pass-through layer's card out again from where `matrix` puts the layer
    /// (its world transform, y up, canvas units), into `mesh`.
    using PassthroughCardLayout = std::function<void(SceneMesh& mesh, const linalg::Matrix4d& matrix)>;
    /// A pass-through layer's card copies the part of the screen the layer is drawn over. The
    /// loader laid it out from `laid_out_from`; from then on every tick lays it out again
    /// when the layer's world transform differs from the one it was last laid out from, and
    /// not otherwise. A mesh that was not made to be rewritten is rewritten in place and
    /// the render graph asked to be built again.
    void RegisterPassthroughCard(std::shared_ptr<SceneNode> node, std::shared_ptr<SceneMesh> mesh,
                                 PassthroughCardLayout layout, const linalg::Matrix4d& laid_out_from);
    /// A display-framing change rewrites screen UVs at this event boundary. Fixed
    /// cards request the existing graph rebuild; moving cards use their existing upload.
    void RefreshPassthroughCardFraming();
    /// How many times a registered card was laid out again after the scene loaded.
    uint64_t PassthroughCardLayoutCount() const { return m_passthrough_card_layouts; }
    void RegisterMaterialAlphaAnimation(std::shared_ptr<SceneMaterial> material,
                                        std::shared_ptr<ScalarAnimationPlayback> animation);
    // A scripted or user-bound image `alpha` is not an animation timeline.
    // The flat shader reads `g_Alpha`, so the live value has to land there.
    void BindMaterialAlpha(std::shared_ptr<SceneMaterial> material,
                           std::unique_ptr<DynamicValue> value);
    // A user-bound or scripted image `color` tints every material the layer
    // draws with: its own and each effect pass. One value feeds them all, and
    // the alpha in `g_Color4` is left to the alpha bindings. What a script
    // writes to `thisLayer.color` becomes that value (see `SetNodeColor`).
    // Static multi-material recipients use replay_current=false: explicit writes
    // still reach the existing recipient set, but registration changes no tint.
    // Both forms reuse the same live value, listener and m_node_color entry.
    void BindMaterialColor(std::string layer_name,
                           std::vector<std::shared_ptr<SceneMaterial>> materials,
                           std::unique_ptr<DynamicValue> value,
                           bool replay_current = true);
    // A user-bound or scripted image `brightness` multiplies the colour of every
    // material the layer tints with, and only in an HDR scene: with no material
    // given the value is kept for its script alone.
    void BindMaterialBrightness(std::vector<std::shared_ptr<SceneMaterial>> materials,
                                std::unique_ptr<DynamicValue> value);
    // An image `color` keyed on a timeline tints the same materials, keeping
    // their alpha, from the clock's frame.
    void RegisterMaterialColorAnimation(std::vector<std::shared_ptr<SceneMaterial>> materials,
                                        std::shared_ptr<const NodeVec3Animation> animation);
    std::shared_ptr<ScalarAnimationPlayback> RegisterScalarAnimation(std::string_view layer_name,
                                                                   ScalarAnimation animation);
    ScalarAnimationPlayback* FindScalarAnimation(std::string_view layer_name,
                                                 std::string_view animation_name) const;
    // `scene.getAnimation(name)` is not scoped to a layer: the authored name is
    // matched across every registered timeline.
    ScalarAnimationPlayback* FindAnimationByName(std::string_view animation_name) const;
    void RegisterSceneScript(std::string script_source, std::string layer_name);
    void RegisterNodeVideoTexture(std::string name, std::string texture_key);
    void RegisterSoundLayer(std::string name, std::shared_ptr<WPSoundStream> stream);
    /// A sound layer's script members (we_ss_reg_SoundLayer 0x1401F7090, decompiles/A-7j.md):
    /// `mintime`, `maxtime` and `playbackmode` reach the stream; `attenuation`, `mindistance`,
    /// `muteineditor`, `startsilent` and `spatialization` are kept (flags 0 or 1). Unknown
    /// layers or members answer nothing / false.
    std::optional<double>      SoundLayerMember(std::string_view name, std::string_view member) const;
    bool                       SetSoundLayerMember(std::string_view name, std::string_view member, double value);
    std::optional<std::string> SoundLayerPlaybackMode(std::string_view name) const;
    bool                       SetSoundLayerPlaybackMode(std::string_view name, std::string mode);
    std::size_t     sceneScriptCount() const;

    /// Which of this runtime's facilities advance with time, as
    /// `SceneDemandReason` bits.
    ///
    /// Derived from what `Tick` actually steps, registry by registry, not from
    /// searching script or shader text. A registry that exists but is empty
    /// contributes nothing; a registry this function does not know about is a
    /// compile-time omission, which is why the caller starts from "unknown"
    /// rather than from "still" and this only ever clears bits it can account
    /// for.
    [[nodiscard]] uint32_t DescribeTimeAdvancingWork() const;

    /// Whether any text layer is between "its layout changed" and "the new
    /// image has been applied".
    ///
    /// Covers both halves: a job this thread has queued but the worker has not
    /// finished, and a result the worker has finished but no frame has applied.
    [[nodiscard]] bool TextLayoutInFlight() const;
    /// Blocks until the text worker has no job queued or running, so that the next
    /// `PumpTextLayerCache` applies every layout a tick asked for. A test that compares two
    /// runs of one scene needs the layouts to land on the same frames in both.
    void WaitForTextLayoutForTests() const;

    /// Called when work that finished off the render thread has produced
    /// something a frame would show.
    ///
    /// Installed by whoever owns the frame clock. It is invoked from the text
    /// worker's own thread, so the handler has to be safe to call from any
    /// thread and must not touch scene state -- asking for one frame is all it
    /// is for. Passing an empty function detaches it.
    void SetContentWakeHandler(std::function<void()> handler);
    /// Does a node, or a sound layer, answer to this name?
    bool HasNodeNamed(std::string_view node_name) const;
    bool HasSoundLayer(std::string_view layer_name) const;

    /// Particle controls and the instance override record belong to the loaded
    /// system. A retained script wrapper reaches nothing after its layer is removed.
    bool HasParticleLayer(std::string_view layer_name) const;
    bool ParticlePlayback(std::string_view layer_name, std::string_view operation, int32_t count = 0);
    std::optional<std::vector<double>> ParticleInstanceValue(std::string_view layer_name,
                                                            std::string_view member) const;
    bool SetParticleInstanceValue(std::string_view layer_name, std::string_view member,
                                   std::span<const double> values);

    /// Sound layers by name. Each returns false when no such layer exists.
    bool  PlaySoundLayer(std::string_view layer_name);
    bool  PauseSoundLayer(std::string_view layer_name);
    bool  StopSoundLayer(std::string_view layer_name);
    bool  SoundLayerPlaying(std::string_view layer_name) const;
    bool  SetSoundLayerVolume(std::string_view layer_name, float volume);
    float SoundLayerVolume(std::string_view layer_name) const;
    bool  SetSoundLayerMuted(std::string_view layer_name, bool muted);
    bool  SoundLayerMuted(std::string_view layer_name) const;

    /// Position of the named node among its siblings.
    int NodeSiblingIndex(std::string_view name) const;

    using ModelDataMaterialLoader = std::function<std::shared_ptr<ModelDataMaterial>(
        std::string_view, uint32_t, std::string&)>;
    using ModelDataLayerSetup = std::function<void(const std::shared_ptr<SceneNode>&,
        const std::vector<std::shared_ptr<ModelDataMaterial>>&, const ModelDataLayerOptions&)>;
    void ConfigureModelData(ModelDataMaterialLoader loader, ModelDataLayerSetup setup);
    uint32_t CreateModelData(const ModelDataUpdate& configuration, std::string& error);
    bool UpdateModelData(uint32_t token, const ModelDataUpdate& update, bool replace, std::string& error);
    void DestroyModelData(uint32_t token);
    std::string CreateModelDataLayer(uint32_t token, const ModelDataLayerOptions& options,
                                     std::string_view creator);

    /// Instantiates a layer from a template file and returns its runtime name. The calling
    /// script's own `__workshopId`, when it declares one, goes in `script_workshop_id`: it
    /// finds that item's assets when the plain path leads nowhere.
    std::string CreateLayerFromTemplate(std::string_view requested_template_path,
                                        std::string_view current_layer_name,
                                        std::string_view script_workshop_id = {});
    // Removes a layer `CreateLayerFromTemplate` (or `CreateTextLayer`) made: it
    // leaves the scene graph and every registry at once, so whatever a script
    // still holds for it reaches nothing. So does every layer registered below it
    // (a script can make one with `createLayer({ parent })`), and `destroyed`, if
    // given, receives the runtime names of all of them. The nodes themselves are
    // kept until the graph has been rebuilt without them, as the graph compiled
    // before still points at them. A layer the scene file made, or an unknown
    // name, is left alone and answers false.
    bool            DestroyLayer(std::string_view name, std::vector<std::string>* destroyed = nullptr);
    linalg::Vector3f NodeColor(std::string_view name) const;
    bool            SetNodeColor(std::string_view name, const linalg::Vector3f& color);
    bool            SortNode(std::string_view name, int index);
    bool            NodeVisible(std::string_view name) const;
    // A layer's parent as scripts address layers: by name. Empty when the layer
    // is unknown or sits at the scene root, which `getParent()` reports as null
    // rather than inventing a stand-in layer for the graph's unnamed root.
    std::string     NodeParentName(std::string_view name) const;
    // Layer opacity a script writes. The authored `alpha` reaches the same
    // `g_Alpha` the flat shader reads; when the author already bound alpha to a
    // script or a user property that binding owns it and this one is not made,
    // so a frame never has two writers. A write reaches every material given:
    // the layer's own and the `g_Color4` and `g_Alpha` of each effect pass, the
    // set an authored alpha, a property or a timeline reaches, and not an
    // effect's own `g_UserAlpha` (`SceneMaterial::own_user_alpha`). A second
    // registration of a name replaces the first.
    void            RegisterNodeAlpha(std::string name,
                                      std::vector<std::shared_ptr<SceneMaterial>> materials,
                                      float value);
    void            RegisterNodeAlpha(std::string name, std::shared_ptr<SceneMaterial> material,
                                      float value);
    // Absent when the layer owns no material the runtime can tint, which the
    // script layer reports as its own remembered value instead of a false 1.
    std::optional<float> NodeAlpha(std::string_view name) const;
    bool            SetNodeAlpha(std::string_view name, float value);
    bool            SetNodeVisible(std::string_view name, bool visible);
    bool            SetNodeTranslate(std::string_view name, const linalg::Vector3f& value);
    bool            SetNodeScale(std::string_view name, const linalg::Vector3f& value);
    bool            SetNodeAlignment(std::string_view name, std::string alignment);
    // Authored anchor alignment: the origin is the anchor point, so the runtime
    // re-derives the offset whenever a dynamic origin or scale replaces it.
    bool            SetNodeAnchorAlignment(std::string_view name, std::string alignment,
                                           const linalg::Vector3f& origin);
    // A text layer's `anchor`: pins it to an edge or corner of the area the
    // display shows (`SetCursorViewport`), on top of wherever its origin puts it.
    bool            SetNodeScreenAnchor(std::string_view name, TextScreenAnchor anchor);
    bool            SetNodeRotation(std::string_view name, const linalg::Vector3f& value);
    /// `layer.rotateObjectSpace(Vec3)`: turns the layer by `increment` (Euler angles in radians,
    /// composed as the layer's own angles are: z, then y, then x) about its own axes, on top of
    /// the orientation it has now. A layer that is not registered is left alone.
    bool            RotateNodeObjectSpace(std::string_view name, const linalg::Vector3f& increment);
    // How the cursor treats a layer: only image, text and model layers that are
    // `solid` are hit-tested, and a visible one under the cursor with
    // `disablepropagation` hides every layer behind it from the cursor. A layer
    // never registered here is tested like a solid image.
    void            SetNodeCursorTarget(std::string_view name, bool hittable, bool solid,
                                        bool disable_propagation);
    struct NodeCursorTarget {
        bool hittable { true };
        bool solid { true };
        bool blocks { false };
    };
    std::optional<NodeCursorTarget> NodeCursorTargetOf(std::string_view name) const;
    linalg::Vector3f NodeTranslate(std::string_view name) const;
    linalg::Vector3f NodeSortingOrigin(const SceneNode& node) const;
    linalg::Vector3f NodeScale(std::string_view name) const;
    /// Where the layer stands in the scene: its own placement with every
    /// ancestor's applied, in canvas units. A name with no node is nowhere in
    /// particular and answers the identity.
    linalg::Matrix4d NodeTransformMatrix(std::string_view name) const;
    linalg::Vector3f NodeRotation(std::string_view name) const;
    linalg::Vector2f NodeSize(std::string_view name) const;
    /// Where the centre of the layer's box (`NodeSize` across) lies from its origin, in
    /// its own plane, y up: zero for a layer centred on its origin, and for a text layer
    /// the card's offset from it (`TextLayerLayout::centre`).
    linalg::Vector2f NodeBoxCentre(std::string_view name) const;
    std::string     NodeText(std::string_view name) const;
    bool            NodeTextDirty(std::string_view name) const;
    std::optional<TextLayerState> NodeTextState(std::string_view name) const;
    /// How the layer's text lies in its card now (the card is `NodeSize`).
    std::optional<TextLayerLayout> NodeTextLayout(std::string_view name) const;
    /// Source dimensions and local bounds for an explicit text particle donor; no layout or copy.
    std::optional<TextLayerRenderFrame> TextEmissionFrame(std::string_view name) const;
    /// Makes only the requested quarter image, on demand; never publishes a second layer bitmap.
    std::shared_ptr<Image> BuildTextEmissionImage(std::string_view name, uint32_t width, uint32_t height);
    bool                          SetNodeText(std::string_view name, std::string text);
    /// Watches one run of a scripted value's script for the text it writes to the
    /// layer the value is the text property of. The script that decides a layer's
    /// text keeps what it writes there when its `update()` returns nothing, so the
    /// scripted value asks `Written()` after the run. A write by any other script
    /// to that layer, or by this one to another layer, is not recorded.
    class OwnTextWrite {
    public:
        OwnTextWrite(SceneRuntimeContext& runtime, const DynamicValue& owner) noexcept;
        ~OwnTextWrite();
        OwnTextWrite(const OwnTextWrite&)            = delete;
        OwnTextWrite& operator=(const OwnTextWrite&) = delete;

        const std::optional<std::string>& Written() const noexcept { return m_written; }

    private:
        friend class SceneRuntimeContext;
        SceneRuntimeContext&       m_runtime;
        const DynamicValue&        m_owner;
        OwnTextWrite*              m_outer { nullptr };
        std::optional<std::string> m_written;
    };
    /// The text layer's style as scripts read and write it: `font`, `pointsize`,
    /// `horizontalalign`, `verticalalign`. A write that changes anything makes
    /// the layer lay out and draw again. `nullopt` / false for a layer that is
    /// not text.
    std::optional<std::string>    NodeTextStyle(std::string_view name, std::string_view property) const;
    bool                          SetNodeTextStyle(std::string_view name, std::string_view property,
                                                   std::string_view value);
    /// How a font named by a script (`systemfont_arial`, `fonts/x.ttf`) becomes
    /// the font fields of a text layer. Installed by the parser, which can read
    /// the wallpaper's files.
    using TextFontResolver = std::function<void(TextLayerState&, const std::string& font_key)>;
    void                          SetTextFontResolver(TextFontResolver resolver);
    /// Builds a text layer from the configuration a script passes `createLayer`
    /// (scene.json keys as JSON text) and returns the new node, registered and
    /// named but not yet attached to the scene graph. `object_id` is unique to it.
    using TextLayerFactory = std::function<std::shared_ptr<SceneNode>(const std::string& config_json,
                                                                      int32_t object_id)>;
    void                          SetTextLayerFactory(TextLayerFactory factory);
    /// `createLayer({text: ...})`: the layer's name, or empty when it could not
    /// be made. It joins the scene beside `current_layer_name`.
    std::string                   CreateTextLayer(std::string_view config_json,
                                                  std::string_view current_layer_name);
    /// `layer.name = …` and `createLayer`'s `name` (Wallpaper Engine's setter 0x1401A4D00
    /// writes the object's name, and name lookup scans the layers in order): the layer
    /// is found by its new name -- unless a layer before it has that name too -- and no
    /// longer by its old one.
    bool                          RenameLayer(std::string_view runtime_name, std::string new_name);
    /// A layer a script names (`getLayer`, `destroyLayer`, a `parent` option): its key, or
    /// empty when no layer has that name now.
    std::string                   ResolveScriptLayerName(std::string_view name) const;
    /// `createLayer`'s `parent`, `size` and `parallaxDepth` for a layer a script made,
    /// and the same properties of any layer afterwards.
    bool SetNodeParent(std::string_view name, std::string_view parent_name,
                       int32_t attachment = -1, bool adjust_transforms = false);
    int32_t NodeAttachmentIndex(std::string_view name, std::string_view attachment);
    linalg::Matrix4d NodeAttachmentMatrix(std::string_view name, int32_t attachment);
    std::optional<linalg::Matrix3d> AttachmentToTexture(std::string_view receiver,
        std::string_view target, int32_t attachment);
    bool                          SetNodeSize(std::string_view name, const linalg::Vector2f& size);
    /// `parallaxDepth`: how far the cursor moves a layer. A write reaches the
    /// layer, its effect passes and the layers below it (Wallpaper Engine moves
    /// a whole tree by its outermost layer's depth, so a write on a child
    /// changes only that child's drift), and a layer that starts or stops
    /// following the cursor asks for a new render graph.
    linalg::Vector2f               NodeParallaxDepth(std::string_view name) const;
    bool                          SetNodeParallaxDepth(std::string_view name, const linalg::Vector2f& depth);
    bool                          ClearNodeTextDirty(std::string_view name);
    void                          PumpTextLayerCache();
    bool                          SetNodeTextureFrame(std::string_view name, double frame);
    double                        NodeTextureFrame(std::string_view name) const;
    /// `getTextureAnimation()`: the sprite sheet a layer draws, Wallpaper
    /// Engine's TextureAnimation (0x1402131A0). `pause`, `stop`, `setFrame` and
    /// a `rate` other than one detach the layer from the sheet's clock onto a
    /// frame of its own; `play` runs that frame on at `rate`; `join` returns
    /// the layer to the clock.
    struct TextureAnimationInfo {
        std::string name;
        std::size_t frame_count { 0 };
        double      duration { 0.0 };
        double      fps { 0.0 };
    };
    std::optional<TextureAnimationInfo> NodeTextureAnimation(std::string_view name) const;
    bool                          PlayNodeTextureAnimation(std::string_view name);
    bool                          PauseNodeTextureAnimation(std::string_view name);
    bool                          StopNodeTextureAnimation(std::string_view name);
    bool                          JoinNodeTextureAnimation(std::string_view name);
    bool                          NodeTextureAnimationPlaying(std::string_view name) const;
    bool                          SetNodeTextureAnimationRate(std::string_view name, double rate);
    double                        NodeTextureAnimationRate(std::string_view name) const;
    /// The frame the sheet is on: one a script asked for and nothing drew yet, else the one last drawn.
    double                        NodeTextureAnimationFrame(std::string_view name) const;
    /// A node's video texture, looked up by the node's name.
    bool NodeHasVideoTexture(std::string_view node_name) const;
    // Transport.
    bool PlayNodeVideoTexture(std::string_view node_name);
    bool PauseNodeVideoTexture(std::string_view node_name);
    bool NodeVideoTextureIsPlaying(std::string_view node_name) const;
    /// `loop` of a layer's video texture (we_ss_reg_VideoTexture 0x140214050, decompiles/A-7i.md).
    bool SetNodeVideoTextureLoop(std::string_view node_name, bool loop);
    bool NodeVideoTextureLoop(std::string_view node_name) const;
    /// Tells `addEndedCallback` listeners (0x1401FA730) about the layers whose video stopped
    /// at its end since the last call. Run once per tick.
    void DispatchVideoEndedEvents();
    // Position and speed, in seconds and as a multiple of normal.
    bool   SetNodeVideoTextureCurrentTime(std::string_view node_name, double seconds);
    double NodeVideoTextureCurrentTime(std::string_view node_name) const;
    bool   SetNodeVideoTextureRate(std::string_view node_name, float rate);
    float  NodeVideoTextureRate(std::string_view node_name) const;
    double NodeVideoTextureDuration(std::string_view node_name) const;

    /// The texture itself, by key: its length once known, and the playback state a frame
    /// should show (falling back to the scene clock when nothing drives it).
    void SetVideoTextureDuration(std::string_view texture_key, double seconds);
    video::VideoPlaybackState
    ResolveVideoPlaybackState(std::string_view texture_key,
                              double fallback_scene_elapsed_seconds) const;

    /// Cursor events for the scripts that listen. The button-carrying ones default to the
    /// primary button.
    void DispatchCursorClick(int which_button = 0);
    void DispatchCursorDown(int which_button = 0);
    void DispatchCursorUp(int which_button = 0);
    // Pointer entered, left or moved over a layer.
    void DispatchCursorEnter();
    void DispatchCursorLeave();
    void DispatchCursorMove();
    /// One frame's worth of them; true when a listener took part.
    bool DispatchCursorFrameEvents(bool cursor_was_in_window);
    /// Pixel coordinates from the layer's top-left, before its world transform.
    /// Outside points remain outside for leave/release events.
    struct CursorEventData {
        linalg::Vector3f local_position { linalg::Vector3f::Zero() };
        std::optional<std::string> hit_box;
    };
    CursorEventData CursorEventForLayer(std::string_view name, bool primary_button_event) const;

    /// Media integration: the artwork colours, the consent switch and the raw event feed.
    void DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                       const linalg::Vector3f& text_color);
    void SetMediaIntegrationEnabled(bool enabled);
    bool MediaIntegrationEnabled() const;
    void DispatchMediaEventJson(std::string_view event_json);
    /// Records a wallpaper's request to run the action its user bound to a
    /// `usershortcut` property.
    ///
    /// The scene names the property; what the request means is the property's
    /// own value, which is the user's choice and the only thing that may be
    /// acted on. Nothing is interpreted here -- the host drains these and
    /// decides -- so a scene cannot reach past its own declared properties.
    void RequestUserShortcut(std::string_view property_name, std::string_view property_value);
    /// Takes the requests made since the last call, oldest first.
    std::vector<std::pair<std::string, std::string>> TakeUserShortcutRequests();
    /// Records that this scene reads system audio. Monotonic per runtime: the
    /// first call runs the audio-requirement listener, later calls are one
    /// atomic load.
    void                         MarkSceneRequiresAudioResponse();
    bool                         SceneRequiresAudioResponse() const;
    /// Installs (or clears, with an empty function) the listener run on the
    /// false -> true transition of `SceneRequiresAudioResponse`. It may run on
    /// any thread that marks the scene, so it must only hand the event on.
    /// A caller must read `SceneRequiresAudioResponse` after installing: a
    /// mark that raced the install is then seen by at least one of the two.
    void SetAudioRequirementListener(std::function<void()> listener);
    void                         SetAudioResponseEnabled(bool enabled);
    bool                         AudioResponseEnabled() const;
    bool                         AudioResponseActive() const;
    bool                         ConsumeSceneGraphMutationFlag();
    /// A light's shadow/cookie partition or type changed. Called only on an actual change.
    void                         InvalidateShadowTopology();
    void                         InvalidateVolumetricTopology();
    void                         InvalidateVolumetricVisibility(const SceneNode* node);
    /// Whether a change gave render targets another size and asked for nothing else: the
    /// buffers an effect chain draws into follow a text card's size in texels. The graph is
    /// as it was, so the renderer resizes its targets under it
    /// (`MetalRender::ResizeRenderTargets`) instead of building the graph again, which drops
    /// every uploaded image and every vertex buffer. A host that built the graph again for
    /// `ConsumeSceneGraphMutationFlag` in the same frame has the new sizes already; it
    /// consumes this flag first or after and does not resize a second time.
    bool                         ConsumeRenderTargetResizeFlag();
    /// How many times each kind of change asked for a new render graph, for a test or a
    /// probe that wants to know what made a scene rebuild.
    const std::map<std::string, int>& SceneGraphMutationReasonsForTests() const {
        return m_scene_graph_mutation_reasons;
    }
    /// The same for the changes that only resized render targets.
    const std::map<std::string, int>& RenderTargetResizeReasonsForTests() const {
        return m_render_target_resize_reasons;
    }
    /// The audio spectrum this frame reads: shader uniforms, particle operators and scripts
    /// alike, as Wallpaper Engine gives a frame one spectrum. The first read after
    /// `BeginAudioFrame` takes the newest analysis (silence while audio response is not
    /// active) and every later read until the next `BeginAudioFrame` returns that same one,
    /// even when the analysis publishes a newer spectrum in between. Before the first frame (a
    /// scene being loaded) every read takes the newest. The reference stays valid until the
    /// next such read; on the render thread, like everything that reads it.
    const audio::AudioSpectrumSnapshot& CurrentAudioSpectrumSnapshot() const;
    /// Starts a frame for `CurrentAudioSpectrumSnapshot`: called once a frame, before anything
    /// in that frame reads the spectrum. Takes nothing itself, so a frame that reads no audio
    /// costs nothing.
    void BeginAudioFrame();
    /// Whether every read of `CurrentAudioSpectrumSnapshot` returns one spectrum until the next
    /// `BeginAudioFrame`: true from the first `BeginAudioFrame` on. Before it, two reads can
    /// return two analyses, so what one read saw says nothing about another.
    bool AudioSpectrumHeldPerFrame() const { return m_audio_frames_begun; }
    /// Runs `destroy()` in every script that started, once, while everything
    /// the scripts could reach still exists. `Scene` calls it first thing in its
    /// destructor, before any of its members die: the runtime is declared above
    /// the file system and the render-exclusion list it reads, which would be
    /// gone by the time `~SceneRuntimeContext` ran. Safe to call again.
    void                         TearDownScripts();
    void                         RecordScriptError(std::string message);
    std::size_t                  scriptErrorCount() const;
    const std::vector<std::string>& scriptErrors() const;
    void                            ClearScriptErrors();

private:
    struct NodeVisibilityBinding {
        SceneNode*    node { nullptr };
        DynamicValue* value { nullptr };
        /// The value's change counter when the layer last took its flag.
        uint64_t      observed_generation { 0 };
    };
    struct NodeAlignmentBinding {
        std::string     alignment;
        linalg::Vector3f origin { linalg::Vector3f::Zero() };
        linalg::Vector3f scale { linalg::Vector3f::Ones() };
        /// The scale the layer had when a script gave it an alignment: the offset of such an
        /// anchor grows with the scale from there.
        linalg::Vector3f base_scale { linalg::Vector3f::Ones() };
        bool            size_anchor { false };
        bool transform_dirty { true };
        linalg::Vector3f cached_translate { linalg::Vector3f::Zero() };
        /// Node rotation `cached_translate` was derived for; the anchor sits
        /// in the layer's own axes, so turning the layer moves the offset.
        linalg::Vector3f rotation { linalg::Vector3f::Zero() };
        /// The edge or corner of the presented area the node is pinned to, and
        /// the shift that puts it there. The shift is a translation in world space
        /// added to where the node is drawn (`SceneNode::SetDrawOffset`), so the
        /// node's own scale and rotation do not touch it and neither does anything
        /// that is parented to the node or reads its origin.
        TextScreenAnchor screen_anchor { TextScreenAnchor::None };
        linalg::Vector2f  screen_offset { linalg::Vector2f::Zero() };
    };
    /// What the cursor walk makes of a layer: under the cursor, not under it, or
    /// never reached because a layer in front of it stopped the walk.
    enum class CursorVisit
    {
        Outside,
        Inside,
        Skipped,
    };
    struct NodeVec3Binding {
        SceneNode*    node { nullptr };
        DynamicValue* value { nullptr };
        SceneNode* transform_node { nullptr };
        NodeAlignmentBinding* alignment { nullptr };
        const linalg::Vector2f* size { nullptr };
        std::shared_ptr<const NodeVec3Animation> animation;
        double sampled_animation_frame { std::numeric_limits<double>::quiet_NaN() };
        /// The value's change counter when the layer last took it.
        uint64_t observed_generation { std::numeric_limits<uint64_t>::max() };
    };
    static void ApplyNodeVec3Animation(NodeVec3Binding& binding);
    struct MaterialAlphaBinding {
        std::weak_ptr<SceneMaterial> material;
        std::shared_ptr<ScalarAnimationPlayback> animation;
        double sampled_animation_frame { std::numeric_limits<double>::quiet_NaN() };
    };
    struct MaterialColorBinding {
        std::vector<std::weak_ptr<SceneMaterial>> materials;
        std::shared_ptr<const NodeVec3Animation>  animation;
        double sampled_animation_frame { std::numeric_limits<double>::quiet_NaN() };
    };
    static void ApplyMaterialColorAnimation(MaterialColorBinding& binding);
    struct MaterialConstantBinding {
        std::weak_ptr<SceneMaterial> material;
        std::string                  name;
        DynamicValue*                value { nullptr };
        std::shared_ptr<const MaterialConstantAnimation> animation;
        uint64_t observed_generation { 0 };
        double sampled_animation_frame { std::numeric_limits<double>::quiet_NaN() };
        bool cached_value_valid { false };
        ShaderValue cached_value;
    };
    struct SceneUniformBinding {
        std::string                                uniform;
        std::vector<DynamicValue*>                 inputs;
        std::vector<uint64_t>                      seen;
        SceneUniformCompute                        compute;
        std::set<std::weak_ptr<SceneMaterial>, std::owner_less<>> materials;
        ShaderValue                                value;
    };
    static void WriteSceneUniform(SceneMaterial& material, const SceneUniformBinding& binding);
    void ApplySceneUniformBindings();
    void AddSceneGeneralUniformMaterial(const std::shared_ptr<SceneMaterial>& material);
    void WriteSceneGeneralUniform(const std::string& name, const ShaderValue& value);
    void CommitSceneGeneralChanges();
    void InstallModelDataLayer(std::string_view name, const std::shared_ptr<ModelDataResource>& resource);
    void ForgetModelDataLayer(std::string_view name);
    std::optional<linalg::Vector3f> ModelDataLayerColor(std::string_view name) const;
    bool SetModelDataLayerColor(std::string_view name, const linalg::Vector3f& color);
    std::optional<linalg::Vector2f> ModelDataLayerBoxCentre(std::string_view name) const;
    static void ApplyModelDataMaterialTint(SceneMaterial&, const linalg::Vector3f&, float alpha);
    struct TextValueBinding {
        std::string   name;
        DynamicValue* value { nullptr };
        /// The value's change counter when the layer last took its text.
        uint64_t      observed_generation { 0 };
    };
    /// A layer whose picture goes through an effect chain: the chain's last card follows the
    /// layer wherever the layer is.
    struct EffectCardLink {
        SceneNode*             node { nullptr };
        SceneImageEffectLayer* layer { nullptr };
        TextLayerRenderFrame   target_frame {};
    };
    struct PassthroughCard {
        std::weak_ptr<SceneNode> node;
        std::shared_ptr<SceneMesh> mesh;
        PassthroughCardLayout    layout;
        linalg::Matrix4d         laid_out_from;
    };
    /// A layer a script can copy (`createLayer`), as registered by the loader.
    struct LayerTemplate {
        std::shared_ptr<SceneNode> node;
        linalg::Vector2f           size { linalg::Vector2f::Zero() };
    };
    /// What the text worker finished for one layer.
    struct FinishedTextLayout {
        std::string     name;
        std::string     cache_identity;
        uint64_t        revision { 0 };
        TextLayerLayout layout;
        /// The glyph quads and atlases of the layout (`BuildTextGlyphs`).
        TextGlyphBuild  build;
    };
public:
    /// The runtime-wide lists a layer build can append to, in the order a rollback cuts them
    /// (what reads another list goes first, the live values last).
    enum class RuntimeList : std::size_t {
        Listeners,
        ScriptedValues,
        SceneScripts,
        MaterialConstants,
        MaterialAlpha,
        MaterialColors,
        Clocks,
        OwnedValues,
        Count,
    };
    /// What `CaptureNodeRegistration` remembers about one layer key so a layer whose build
    /// failed can be taken back out: where the key stood, one closure per per-layer record that
    /// existed (each puts its record back), and how long each runtime-wide list was. Opaque to
    /// the loader.
    struct LayerRegistrationMemo {
        SceneNode*                 node { nullptr };
        // SIZE_MAX cannot be an index in the layer-order vector. Replacing the
        // optional rank leaves room for the pre-node colour pointer at no cost.
        std::size_t                rank { std::numeric_limits<std::size_t>::max() };
        DynamicValue*              color { nullptr };
        std::vector<std::function<void(SceneRuntimeContext&)>> put_back;
        std::array<std::size_t, static_cast<std::size_t>(RuntimeList::Count)> lengths {};
    };

private:
    struct VideoTexturePlaybackBinding {
        double duration_seconds { 0.0 };
        double absolute_seconds { 0.0 };
        float  rate { 1.0f };
        bool   paused { false };
        // `loop` (0x1401FA700 pushes it to the decoder): a clip that does not loop stops on
        // its last frame and is `ended` once, until it is played or moved again.
        bool loop { true };
        bool ended { false };
    };
    std::vector<std::string> m_ended_video_textures;
    struct SceneScriptBinding {
        std::unique_ptr<SceneScriptProgram> script;
        bool                                cursor_inside { false };
    };
    template<typename Callback>
    void ForEachEventScript(Callback&& callback) {
        const auto value_count = m_scripted_values.size();
        const auto script_count = m_scene_scripts.size();
        for (std::size_t index = 0; index < value_count; ++index) {
            auto* value = m_scripted_values[index];
            if (value != nullptr) callback(value);
        }
        for (std::size_t index = 0; index < script_count; ++index) {
            auto* script = m_scene_scripts[index].script.get();
            if (script != nullptr) callback(script);
        }
    }
    /// Re-derives the presented margins from the cursor viewport and moves every
    /// layer pinned to a screen anchor if they changed.
    void UpdatePresentedMargins();
    void RefreshNodeTransformBindings(const std::string& name);
    /// Frees the layers `DestroyLayer` retired once the mutation they caused
    /// has been consumed, that is once no compiled graph can still draw them.
    void ReleaseRetiredLayers();
    void ApplySceneZoomAnimation();
    void ApplySceneZoom(double zoom);
    void ApplyCameraShots();
    void ApplyPerspectiveCameraShots(double seconds);
    void DispatchPendingAnimationEvents();
    bool                           CursorInsidePresentedContent() const;
    linalg::Vector3f ScriptCursorWorldPosition() const;
    struct CursorLayerPoint {
        linalg::Vector2d offset;
        linalg::Vector2f size;
        SceneNode* node;
        const SceneCamera* camera;
    };
    std::optional<CursorLayerPoint> CursorPointInLayer(std::string_view name) const;
    bool CursorHitsLayer(std::string_view name) const;
    bool CursorHitsLayerGeometry(std::string_view name) const;
    CursorVisit VisitCursorLayer(std::string_view name) const;
    bool CursorBlockedByLayerInFront(std::string_view name) const;
    std::optional<std::size_t> NodeRank(std::string_view name) const;
    std::optional<std::size_t> FrontmostCursorBlocker() const;
    CursorVisit VisitScriptLayer(const ScriptedDynamicValue& value) const;
    CursorVisit VisitScriptLayer(const SceneScriptProgram& script) const;
    void StopTextWorker();
    /// Whether this text layer's pending layout is being worked on at all.
    ///
    /// An unreferenced hidden layer waits until it is shown. A layer sampled by
    /// another layer or a particle emitter still prepares its glyphs; the particle
    /// source needs no GPU composite. Shared with `PumpTextLayerCache` so "in flight"
    /// and "the pump will do it" cannot drift apart.
    [[nodiscard]] bool TextLayerIsBeingPrepared(const std::string& name) const;
    /// Works the gate of the text layer `name` out from its effects as they stand.
    void RefreshTextEffectGate(const std::string& name);
    bool PrepareTextMaterials(const std::string& name, const TextMaterialKey& key,
                              const TextStyleUniforms& uniforms);
    void CommitTextMaterials(const std::string& name, bool published_distance_field);
    void WriteTextBackgroundUniforms(const std::string& name);
    /// Moves the composite of a text layer another layer samples onto `card`,
    /// the card a relayout left it with, and resizes the target to it.
    void FitTextLayerComposite(SceneNode& node, const TextLayerRenderFrame& card);
    // Makes `next_properties` the table in effect, refreshes every binding and
    // tells the scripts. Returns the sorted names whose value changed.
    std::vector<std::string> ApplyProjectProperties(ProjectProperties next_properties);

    // Looked up by name every frame the cursor is in the window, so the maps
    // below take a `string_view` without making a string of it.
    struct StringHash {
        using is_transparent = void;
        std::size_t operator()(std::string_view value) const noexcept {
            return std::hash<std::string_view> {}(value);
        }
    };
    std::unique_ptr<ScriptEngine>                                  m_script_engine;
    std::unique_ptr<ScriptHostContext>                             m_host_context;
    Scene*                                                         m_scene { nullptr };
    StaticCameraTransforms m_static_camera { 2, 2, 2, 0, 0, 0, 0, 1, 0, 1 };
    StaticCameraTransforms m_initial_static_camera { 0, 0, 0, 0, 0, -1, 0, 1, 0, 1 };
    bool m_static_camera_started { false };
    void StartStaticCamera();
    bool m_has_camera_paths { false };
    GlobalCameraPlayback m_global_camera_paths;
    SceneCamera* m_global_path_camera { nullptr };
    std::shared_ptr<SceneNode> m_global_path_node;
    struct GlobalCameraBasePose;
    std::shared_ptr<GlobalCameraBasePose> m_global_camera_base;
    void RestoreGlobalCameraBase();
    bool m_canvas_shot_selected { false }, m_perspective_shot_selected { false };
    void ApplyGlobalCameraPaths(double seconds);
    bool m_camera_fade_enabled { true };
    double m_camera_fade_alpha { 0.0 };
    std::weak_ptr<SceneNode> m_camera_fade_node;
    void SetCameraFadeAlpha(double alpha);
    void ApplyCameraFadeBinding();
    CursorViewport                                                 m_cursor_viewport {};
    // The cursor in the canvas plane, where the viewport maps the window pointer
    // (z = 0). Layers are hit in it and particles follow it. It is not what a
    // perspective scene's scripts read as `input.cursorWorldPosition`.
    linalg::Vector3f                                                m_cursor_plane_position { linalg::Vector3f::Zero() };
    ProjectProperties                                              m_project_properties;
    // The properties read only while the scene loaded, each with the value it
    // was read with (empty: the table did not name it).
    std::map<std::string, std::optional<RuntimeScalarValue>>       m_load_only_properties;
    bool                                                           m_project_properties_changing { false };
    std::vector<std::unique_ptr<DynamicValue>>                     m_owned_values;
    std::unordered_map<std::string, SceneNode*, StringHash, std::equal_to<>> m_nodes;
    /// Registration order of `m_nodes`, which `SetLayerOrder` reorders to the
    /// scene file's and `SortLayer` changes.
    std::vector<std::string>                                       m_node_order;
    /// Runtime key -> the name the scene file gave it, for layers registered
    /// under a generated key (a shared or empty authored name).
    std::unordered_map<std::string, std::string>                   m_layer_authored_names;
    std::unordered_map<int32_t, std::string>                       m_layer_ids;
    bool                                                           m_initial_layer_config_requested { false };
    InitialLayerConfigProvider                                     m_initial_layer_config_provider;
    TextFontResolver                                               m_text_font_resolver;
    TextMaterialFactory                                            m_text_material_factory;
    std::unique_ptr<SceneGeneralState>                              m_scene_general;
    std::shared_ptr<SceneForceState> m_scene_forces;
    void BindPuppetSceneForces(WPPuppetLayer&);
    void RefreshSceneForces();
    std::unique_ptr<SceneModelDataState>                            m_model_data;
    TextLayerFactory                                               m_text_layer_factory;
    int32_t                                                        m_next_generated_text_id { 0x40000000 };
    std::unordered_map<std::string, std::string>                   m_layer_aliases;
    std::unordered_map<std::string, NodeVisibilityBinding>         m_node_visibility;
    /// The colour value an image layer takes its materials' colour from.
    std::unordered_map<std::string, DynamicValue*>                 m_node_color;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_translate;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_scale;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_rotation;
    std::vector<MaterialAlphaBinding>                              m_material_alpha;
    std::vector<MaterialColorBinding>                              m_material_colors;
    struct CameraShake {
        bool  registered { false };
        bool  enabled { false };
        float amplitude { 0.0f };
        float speed { 0.0f };
        float roughness { 1.0f };
    };
    CameraShake                                                    m_camera_shake;
    void                                                           ApplyCameraShake();
    struct NodeAlphaBinding {
        std::vector<std::shared_ptr<SceneMaterial>> materials;
        float                                       value { 1.0f };
    };
    std::unordered_map<std::string, NodeAlphaBinding>              m_node_alpha;
    struct ScalarAnimationBinding {
        std::string layer_name;
        std::shared_ptr<ScalarAnimationPlayback> playback;
    };
    std::vector<ScalarAnimationBinding> m_scalar_animations;
    std::shared_ptr<ScalarAnimationPlayback> m_scene_zoom_animation;
    struct CameraShotBinding {
        SceneNode*         node { nullptr };
        DynamicValue*      zoom { nullptr };
        CameraShotTimeline timeline;
        /// The origin is bound and no tick has applied it yet.
        bool               origin_pending { false };
    };
    std::vector<CameraShotBinding> m_camera_shots;
    struct PerspectiveCameraShot {
        std::shared_ptr<SceneNode> node;
        double fov;
        CameraPathPlayback path;
        std::size_t order;
    };
    struct PerspectiveCameraGroup {
        SceneCamera* camera;
        std::shared_ptr<SceneNode> fallback_node;
        double fallback_fov;
        std::vector<PerspectiveCameraShot> shots;
    };
    std::vector<PerspectiveCameraGroup> m_perspective_camera_groups;
    SceneCamera* m_fallback_active_camera { nullptr };
    std::size_t m_perspective_shot_count { 0 };
    /// What the view was last framed with, so an unchanged shot costs nothing.
    std::optional<std::pair<double, linalg::Vector2f>> m_framed_camera_shot;
    std::vector<MaterialConstantBinding>                           m_material_constants;
    std::vector<SceneUniformBinding>                               m_scene_uniforms;
    std::vector<TextValueBinding>                                  m_text_values;
    OwnTextWrite*                                                  m_own_text_write { nullptr };
    std::unordered_map<std::string, linalg::Vector2f, StringHash, std::equal_to<>> m_node_size;
    std::unordered_map<std::string, NodeHitMask, StringHash, std::equal_to<>> m_node_hit_masks;
    std::unordered_map<std::string, WPPuppetLayer>                 m_puppet_layers;
    struct ModelFlags {
        bool rootmotion { false };
        bool castshadow { false };
    };
    std::unordered_map<std::string, ModelFlags, StringHash, std::equal_to<>> m_model_flags;
    std::unordered_map<std::string, int32_t, StringHash, std::equal_to<>> m_node_sort_order;
    struct LightLayerBinding {
        SceneLight* light { nullptr };
        std::string kind;
    };
    std::unordered_map<std::string, LightLayerBinding, StringHash, std::equal_to<>> m_light_layers;
    // Layers whose name a script changed away from the key they are registered under.
    std::unordered_set<std::string> m_renamed_layers;
    void                            RefreshNameAlias(const std::string& name);
    bool                                                                  m_custom_sort_order { false };
    struct ImageLayerFlagBinding {
        ImageLayerFlags                             flags;
        SceneNode*                                  node { nullptr };
        std::vector<std::shared_ptr<SceneMaterial>> brightness_materials;
    };
    std::unordered_map<std::string, ImageLayerFlagBinding, StringHash, std::equal_to<>> m_image_layer_flags;
    std::unordered_map<std::string, TextLayer, StringHash, std::equal_to<>> m_text_layers;
    std::unordered_map<std::string, TextEffectGate>                m_text_effect_gates;
    std::unordered_map<std::string, NodeAlignmentBinding>          m_node_alignment;
    std::unordered_map<std::string, NodeCursorTarget, StringHash, std::equal_to<>>
        m_node_cursor_targets;
    // Set once any layer is registered as one that stops the cursor walk; the
    // blocker search is skipped until then.
    bool                                                           m_any_cursor_blocker { false };
    // Where each layer stands in `m_node_order` (higher is in front), rebuilt the
    // first time it is asked for after the order changed.
    mutable std::unordered_map<std::string, std::size_t, StringHash, std::equal_to<>>
        m_node_rank;
    mutable bool                                                   m_node_rank_valid { false };
    // The frontmost visible blocker under the cursor, found once for the cursor
    // events of a frame and found again after a callback that may have moved
    // layers: its rank in `m_node_order`, or none.
    mutable bool                                                   m_cursor_blocker_cached { false };
    mutable std::optional<std::size_t>                             m_cursor_blocker_rank;
    PresentedMargins                                               m_presented_margins {};
    std::function<bool(std::string_view)>                          m_layer_template_loader;
    std::unordered_set<std::string>                               m_loading_layer_templates;
    std::unordered_set<std::string>                               m_failed_layer_templates;
    std::unordered_set<std::string>                               m_unsupported_layer_templates;
    std::unordered_map<std::string, VideoTexturePlaybackBinding, StringHash, std::equal_to<>>
        m_video_texture_playback;
    std::unordered_map<std::string, std::weak_ptr<WPSoundStream>>  m_sound_layers;
    std::shared_ptr<void>                                          m_scripted_value_registry { std::make_shared<char>() };
    std::vector<ScriptedDynamicValue*>                             m_scripted_values;
    // `m_scripted_values` in the scene's order, which is the order their `update`s run in each
    // tick: by the rank of their layer, ties in the order the scripts were made. Rebuilt when a
    // value is registered or the layer order changes; a removed value leaves an empty slot.
    std::vector<ScriptedDynamicValue*>                             m_scripted_tick_order;
    bool                                                           m_scripted_tick_order_dirty { true };
    // The host samples input before Tick. A cold scene retains one dispatch marker
    // until that tick has run init/notices, using the already-sampled host context.
    bool                                                         m_cursor_events_ready { false };
    std::optional<bool>                                          m_deferred_cursor_was_in_window;
    std::unordered_map<ScriptedDynamicValue*, bool>                m_scripted_value_cursor_inside;
    // Who took each button's press, so its release reaches them wherever the
    // cursor has since gone. A button that shrinks while held -- these
    // transport buttons scale to a tenth of their size -- would otherwise be
    // too small to catch its own release and would stay held forever.
    std::unordered_map<uint32_t, std::vector<ScriptedDynamicValue*>> m_scripted_value_cursor_held;
    std::unordered_map<uint32_t, std::vector<std::size_t>>           m_scene_script_cursor_held;
    std::vector<SceneScriptBinding>                                m_scene_scripts;
    mutable std::mutex                                             m_text_worker_mutex;
    /// Jobs the worker has taken off the queue and not yet published. Guarded by the mutex.
    int                                                            m_text_jobs_running { 0 };
    std::deque<RuntimePendingTextLayerJob>                         m_pending_text_jobs;
    /// Guarded by `m_text_worker_mutex`, alongside the queues it describes.
    std::function<void()>                                          m_content_wake_handler;
    /// Names of the layers scripts created and have not destroyed.
    std::unordered_set<std::string>                                m_script_created_layers;
    /// Destroyed layers no longer in the scene graph, kept alive until
    /// `ReleaseRetiredLayers` sees the graph rebuilt without them.
    std::vector<std::shared_ptr<SceneNode>>                        m_retired_layers;
    /// Textures of text layers that were destroyed, dropped from the scene once
    /// the graph that drew them is gone, so layers made and destroyed over and
    /// over do not accumulate rasters.
    std::vector<std::string>                                       m_retired_text_textures;
    /// Bounded: a wallpaper that requests on every cursor event while nothing
    /// drains must not grow this without limit, and the oldest request is the
    /// one a user has already stopped waiting for.
    std::vector<std::pair<std::string, std::string>>               m_user_shortcut_requests;
    /// Written from the parse thread (materials, particles), the render thread
    /// (shader uniforms) and the script thread (`registerAudioBuffers`), and
    /// read on all of them, so both flags are atomic. The requirement only ever
    /// goes false -> true for one runtime: a replaced scene gets a new runtime.
    std::atomic<bool> m_scene_requires_audio_response { false };
    std::atomic<bool> m_audio_response_enabled { false };
    /// The spectrum of the frame in progress (`CurrentAudioSpectrumSnapshot`), whether it has
    /// been taken yet, and whether frames have begun at all.
    mutable audio::AudioSpectrumSnapshot m_frame_audio_spectrum {};
    mutable bool                         m_frame_audio_spectrum_taken { false };
    bool                                 m_audio_frames_begun { false };
    /// Called once, on whichever thread first marks the scene as reading
    /// audio. Guarded so installing it and marking cannot both miss.
    std::mutex            m_audio_requirement_mutex;
    std::function<void()> m_audio_requirement_listener;
    void MarkSceneGraphMutated(const char* reason);
    void MarkRenderTargetsResized(const char* reason);
    bool m_scene_graph_mutated { false };
    std::map<std::string, int> m_scene_graph_mutation_reasons;
    bool m_render_targets_resized { false };
    std::map<std::string, int> m_render_target_resize_reasons;
    SceneScriptStorage m_script_storage;
    /// The display's size or the language changed since the scripts were told.
    /// `TearDownScripts` has run: no program starts from then on.
    bool m_scripts_torn_down { false };
    bool m_screen_resize_pending { false };
    bool m_general_settings_pending { false };

    // ---- State added with the clean-room rewrite ----------------------------------------
    /// What the project declares: the table a document is applied over.
    ProjectProperties m_default_properties;
    /// The live value of each property, owned by `m_owned_values`.
    std::unordered_map<std::string, DynamicValue*, StringHash, std::equal_to<>> m_property_values;
    /// Values standing in for properties no table has declared yet, adopted by the first
    /// document that supplies the name.
    std::unordered_map<std::string, DynamicValue*, StringHash, std::equal_to<>> m_absent_property_values;
    std::vector<std::string> m_script_errors;
    /// Ends the subscription a registered listener made, in registration order.
    std::vector<std::function<void()>> m_listener_ends;
    std::unordered_map<std::string, EffectCardLink> m_effect_card_links;
    std::vector<PassthroughCard> m_passthrough_cards;
    uint64_t                     m_passthrough_card_layouts { 0 };
    struct EffectObject {
        std::string                       layer;
        std::string                       name;
        std::shared_ptr<SceneImageEffect> effect;
        DynamicValue*                     visibility { nullptr };
        std::vector<EffectMaterialPass>   passes;
    };
    /// The effects whose visibility or materials a script reaches, by their reference.
    std::unordered_map<std::string, EffectObject> m_effect_objects;
    /// Layer key -> the references of the layer's authored effects, in declaration order.
    std::unordered_map<std::string, std::vector<std::string>, StringHash, std::equal_to<>>
        m_layer_effects;
    std::unordered_map<std::string, std::shared_ptr<ScalarAnimationPlayback>> m_setting_animations;
    uint64_t m_next_object_reference { 1 };
    std::unordered_map<std::string, LayerTemplate> m_layer_templates;
    /// Layer key -> the template path the layer was made from (or the path a template node
    /// was registered under, which is how a script in a workshop layer finds its siblings).
    std::unordered_map<std::string, std::string> m_node_template_paths;
    uint64_t m_next_generated_layer_key { 1 };
    int32_t  m_next_generated_layer_id { 0x50000000 };
    /// The texture keys of each layer's video textures, in the order they were registered.
    std::unordered_map<std::string, std::vector<std::string>, StringHash, std::equal_to<>>
        m_node_video_textures;
    /// Every clock registered by `RegisterScalarAnimation`, so a clock that is also held by
    /// another registry is stepped once.
    std::unordered_set<const ScalarAnimationPlayback*> m_registered_clocks;
    double m_scene_zoom_sampled_frame { std::numeric_limits<double>::quiet_NaN() };
    std::atomic<bool> m_media_integration_enabled { false };

    // The text worker: one thread, one queue (`m_pending_text_jobs`, guarded by
    // `m_text_worker_mutex` like everything below it) and the newest result of every layer.
    std::thread                                  m_text_worker;
    std::condition_variable                      m_text_worker_wake;
    bool                                         m_text_worker_stop { false };
    std::vector<FinishedTextLayout>              m_finished_text_layouts;
    /// The revision of the job last queued for a layer.
    std::unordered_map<std::string, uint64_t>    m_revision_queued_for_layer;
    enum class Vec3Key
    {
        Origin,
        Scale,
        Angles,
    };
    void ApplyVec3Binding(Vec3Key key, const std::string& name, NodeVec3Binding& binding);
    void SyncMaterialConstant(MaterialConstantBinding& binding);
    void TextWorkerLoop();
    /// Blocks until the worker has a job to take (counting it as running) or is told to stop.
    std::optional<RuntimePendingTextLayerJob> AwaitTextJob();
    /// Files a finished job and tells the content wake handler; drops it once stopping.
    void PublishFinishedText(FinishedTextLayout done);
    bool ApplyFinishedTextLayout(FinishedTextLayout& finished);
    /// Re-fits everything that depends on a text layer's card after its card changed.
    void ReshapeTextCard(const std::string& name, TextLayer& layer, SceneNode* node);
    void RefitCardMesh(SceneMesh& mesh, const TextLayerRenderFrame& frame);
    void ResizeEffectChain(EffectCardLink& link, SceneNode* node,
                           const TextLayerRenderFrame& effect_frame);
    /// Writes the glyphs of a finished layout into the layer's mesh, publishes its atlases and
    /// hands their sizes and the style's uniforms to the glyph materials.
    void PublishTextGlyphs(const TextLayer& layer, const FinishedTextLayout& done, SceneNode* node);
    /// The style's render variables of `layer` into the glyph materials of `mesh`.
    static void WriteTextStyleUniforms(const TextLayer& layer, SceneMesh& mesh);
    std::size_t RuntimeListLength(RuntimeList list) const;
    void TrimRuntimeLists(const std::array<std::size_t, static_cast<std::size_t>(RuntimeList::Count)>& lengths);
    void QueueTextJobs();
    void RequestShownLayerGraph();
    void AdvanceClocks(double seconds);
    /// Starts the value scripts that have not started, as a scene starts them: every script's
    /// `init` in the scene's order, then every script told the user properties for the first
    /// time. Only then does any script's `update` run.
    void StartPendingScripts();
    /// Where a value script stands in the scene's order: its layer's rank, or after every layer
    /// for a script that belongs to none.
    std::size_t ScriptRank(const ScriptedDynamicValue* value) const;
    void RebuildScriptTickOrder();
    void ApplyNodeVisibilityBindings();
    void ApplyNodeTransformBindings();
    void ApplyTextValueBindings();
    void ApplyEffectFinalBindings();
    void ApplyPassthroughCards(bool force = false);
    void ApplyMaterialConstantBindings();
    void ApplyMaterialAlphaBindings();
    void ApplyAnchoredTransform(const std::string& name);
    void ApplyScreenAnchor(const std::string& name);
    void ForgetLayerScripts(const std::string& name);
    std::size_t TrimScriptsTo(std::size_t value_count, std::size_t script_count);
};

std::unique_ptr<SceneRuntimeContext> CreateSceneRuntimeContext(SceneRuntimeBootstrap bootstrap);

} // namespace wallpaper
