#pragma once

#include "Project/ProjectProperties.hpp"
#include "Audio/include/Audio/AudioResponseService.h"
#include "Runtime/CameraPath.hpp"
#include "Runtime/ScalarAnimation.hpp"
#include "Scene/Parse/WPPuppet.hpp"
#include "Scene/include/Scene/SceneShader.h"
#include "Scene/include/Scene/SceneUpdateDemand.hpp"
#include "Text/TextLayer.hpp"
#include "Video/VideoTextureSource.hpp"

#include <Eigen/Dense>

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
class ScriptedDynamicValue;
class SceneNode;
class SceneImageEffectLayer;
struct SceneImageEffect;
struct PassthroughCard;
class Scene;
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
    Eigen::Vector2f origin { Eigen::Vector2f::Zero() };
    Eigen::Vector2f size { Eigen::Vector2f::Zero() };
    Eigen::Vector2f content_origin { Eigen::Vector2f::Zero() };
    Eigen::Vector2f content_size { Eigen::Vector2f::Zero() };
};

struct RuntimePreparedTextLayerImage {
    std::string     name;
    uint64_t        revision { 0 };
    TextLayerState  state;
    TextLayerLayout layout;
    TextLayerRenderFrame render_frame {};
    uint32_t        width { 0 };
    uint32_t        height { 0 };
    std::vector<uint8_t> rgba;
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
    struct NodeRegistrationSnapshot;

    explicit SceneRuntimeContext(SceneRuntimeBootstrap bootstrap);
    ~SceneRuntimeContext();

    void Tick(double frame_time);

    ScriptEngine&            scriptEngine();
    const ScriptHostContext& hostContext() const;
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
    void          SetCursorWorldPosition(const Eigen::Vector3f& value);
    // World rectangle the window shows, so window-normalized cursor input lands
    // where the presented wallpaper actually draws each layer.
    void          SetCursorViewport(const CursorViewport& viewport);
    /// The display's pixel resolution, which `engine.screenResolution` reports.
    /// Distinct from the cursor viewport above, which is scene world units,
    /// and from the rasterization size, which internal quality may reduce.
    void          SetScreenResolution(const Eigen::Vector2f& resolution);
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
    /// with the name it is registered under. The name may be recorded before
    /// the layer is registered; unregistering the layer forgets it.
    void          RegisterLayerAuthoredName(std::string runtime_name, std::string authored_name);
    std::string   LayerAuthoredName(std::string_view runtime_name) const;
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
                     std::shared_ptr<const NodeRegistrationSnapshot> previous);
    [[nodiscard]] std::shared_ptr<NodeRegistrationSnapshot>
                  CaptureNodeRegistration(std::string_view name) const;
    void          RegisterNodeSize(std::string name, Eigen::Vector2f value);
    void          RegisterNodeHitMask(std::string name, NodeHitMask mask);
    // The copy shares playback state with the render passes that own it.
    void          RegisterPuppetLayer(std::string name, WPPuppetLayer layer);
    WPPuppetLayer* FindPuppetLayer(std::string_view name);
    // Mirrors the SceneScript IAnimationLayer operations. Unknown layers and
    // operations return 0.
    /// Tells `addEndedCallback` listeners about the single-shot animation
    /// layers that finished playing since the last call. Run once per tick.
    void          DispatchPuppetLayerEvents();
    double        PuppetAnimationControl(std::string_view layer_name,
                                         std::string_view animation_layer,
                                         std::string_view operation, double value,
                                         bool has_value);
    /// The authored name of the animation layer a script addressed by name or
    /// by position; empty when the layer or the animation layer is unknown.
    std::string   PuppetAnimationLayerName(std::string_view layer_name,
                                           std::string_view animation_layer);
    void          RegisterLayerTemplate(std::string template_path, std::shared_ptr<SceneNode> node,
                                        Eigen::Vector2f size);
    // Called synchronously on a registry miss. The loader registers the requested
    // normalized template without attaching a drawable source to the scene graph.
    void          SetLayerTemplateLoader(std::function<bool(std::string_view)> loader);
    void          RegisterNodeVisibility(std::string name, SceneNode* node,
                                         std::unique_ptr<DynamicValue> value);
    /// An effect whose `visible` a script decides, as Wallpaper Engine's
    /// effect object does: its chain is built with it, and a switch marks the
    /// scene graph changed so the host resolves the chain again over the
    /// effects that run and rebuilds the render graph before the next frame.
    void          RegisterEffectVisibility(std::shared_ptr<SceneImageEffect> effect,
                                           std::unique_ptr<DynamicValue> value);
    /// What follows a text layer's effects as a script switches them, and what follows its card.
    /// Wallpaper Engine counts the visible effect passes of a text layer afresh whenever an
    /// effect's visibility changes: the card is padded, and drawn as a composite, only while one
    /// is visible.
    struct TextEffectGate {
        /// The layer is padded whatever its effects do: a colour blend, an LED source, an opaque
        /// background, or fog in the scene.
        bool                                           padded_regardless { false };
        /// The effects the layer's chain is built with; one that is visible counts.
        std::vector<std::shared_ptr<SceneImageEffect>> effects;
        /// The `g_Composite` constant of the card's material, 1 while the card is a composite
        /// (some effect is visible) and 0 while the glyphs go straight onto the scene. Null for
        /// a card that never composites.
        DynamicValue*                                  composite { nullptr };
        /// The `g_CardInset` constant of the material of a card with an opaque background: where
        /// the card lies in the raster, as the fraction of the raster outside it on each side. It
        /// moves with the text, so a relayout updates it. Null for a card with no background.
        DynamicValue*                                  card_inset { nullptr };
    };
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
    /// A camera layer's timeline: one clock, and the zoom and origin curves it
    /// plays. `origin_base` is the authored origin a relative timeline offsets.
    struct CameraShotTimeline {
        std::shared_ptr<ScalarAnimationPlayback>      clock;
        std::optional<ScalarAnimation>                zoom;
        std::array<std::optional<ScalarAnimation>, 3> origin;
        bool                                          origin_relative { false };
        Eigen::Vector3f                               origin_base { Eigen::Vector3f::Zero() };
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
    void RegisterDynamicValueListener(std::unique_ptr<DynamicValue> value,
                                      std::function<void(const DynamicValue&)> callback);
    /// `passthrough_card`, for a pass-through layer drawn through effects, is the
    /// card that copies the screen where the layer is drawn: laid out again,
    /// with the final card, whenever the layer is drawn somewhere else.
    void RegisterNodeEffectFinal(std::string name, SceneNode* node, SceneImageEffectLayer* layer,
                                 TextLayerRenderFrame             target_frame     = {},
                                 std::shared_ptr<PassthroughCard> passthrough_card = nullptr);
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
    void BindMaterialColor(std::string layer_name,
                           std::vector<std::shared_ptr<SceneMaterial>> materials,
                           std::unique_ptr<DynamicValue> value);
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
    /// Gives the timeline bound to one setting a handle of its own, which the
    /// setting's script reaches as `thisObject.getAnimation()` with no name
    /// (`PropertyScriptObject::property_animation`). Never 0.
    uint64_t                 RegisterPropertyAnimation(std::shared_ptr<ScalarAnimationPlayback> playback);
    ScalarAnimationPlayback* FindPropertyAnimation(uint64_t handle) const;
    void RegisterSceneScript(std::string script_source, std::string layer_name);
    void RegisterNodeVideoTexture(std::string name, std::string texture_key);
    void RegisterSoundLayer(std::string name, std::shared_ptr<WPSoundStream> stream);
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

    /// Called when work that finished off the render thread has produced
    /// something a frame would show.
    ///
    /// Installed by whoever owns the frame clock. It is invoked from the text
    /// worker's own thread, so the handler has to be safe to call from any
    /// thread and must not touch scene state -- asking for one frame is all it
    /// is for. Passing an empty function detaches it.
    void SetContentWakeHandler(std::function<void()> handler);
    bool            HasNodeNamed(std::string_view name) const;
    bool            HasSoundLayer(std::string_view name) const;
    bool            PlaySoundLayer(std::string_view name);
    bool            PauseSoundLayer(std::string_view name);
    bool            StopSoundLayer(std::string_view name);
    bool            SoundLayerPlaying(std::string_view name) const;
    bool            SetSoundLayerVolume(std::string_view name, float volume);
    float           SoundLayerVolume(std::string_view name) const;
    bool            SetSoundLayerMuted(std::string_view name, bool muted);
    bool            SoundLayerMuted(std::string_view name) const;
    int             NodeSiblingIndex(std::string_view name) const;
    // `script_workshop_id` is the `__workshopId` the calling script declares,
    // if any; it locates that item's assets once the plain path finds nothing.
    std::string     CreateLayerFromTemplate(std::string_view requested_template_path,
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
    Eigen::Vector3f NodeColor(std::string_view name) const;
    bool            SetNodeColor(std::string_view name, const Eigen::Vector3f& color);
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
    bool            SetNodeTranslate(std::string_view name, const Eigen::Vector3f& value);
    bool            SetNodeScale(std::string_view name, const Eigen::Vector3f& value);
    bool            SetNodeAlignment(std::string_view name, std::string alignment);
    // Authored anchor alignment: the origin is the anchor point, so the runtime
    // re-derives the offset whenever a dynamic origin or scale replaces it.
    bool            SetNodeAnchorAlignment(std::string_view name, std::string alignment,
                                           const Eigen::Vector3f& origin);
    // A text layer's `anchor`: pins it to an edge or corner of the area the
    // display shows (`SetCursorViewport`), on top of wherever its origin puts it.
    bool            SetNodeScreenAnchor(std::string_view name, TextScreenAnchor anchor);
    bool            SetNodeRotation(std::string_view name, const Eigen::Vector3f& value);
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
    Eigen::Vector3f NodeTranslate(std::string_view name) const;
    Eigen::Vector3f NodeScale(std::string_view name) const;
    /// Where the layer stands in the scene: its own placement with every
    /// ancestor's applied, in canvas units. A name with no node is nowhere in
    /// particular and answers the identity.
    Eigen::Matrix4d NodeTransformMatrix(std::string_view name) const;
    Eigen::Vector3f NodeRotation(std::string_view name) const;
    Eigen::Vector2f NodeSize(std::string_view name) const;
    /// Where the centre of the layer's box (`NodeSize` across) lies from its origin, in
    /// its own plane, y up: zero for a layer centred on its origin, and for a text layer
    /// the card's offset from it (`TextLayerLayout::centre`).
    Eigen::Vector2f NodeBoxCentre(std::string_view name) const;
    std::string     NodeText(std::string_view name) const;
    bool            NodeTextDirty(std::string_view name) const;
    std::optional<TextLayerState> NodeTextState(std::string_view name) const;
    /// How the layer's text lies in its card now (the card is `NodeSize`).
    std::optional<TextLayerLayout> NodeTextLayout(std::string_view name) const;
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
    /// `createLayer`'s `name`, `parent`, `size` and `parallaxDepth` for a layer
    /// a script made, and the same properties of any layer afterwards.
    bool                          NameLayer(std::string_view runtime_name, std::string authored_name);
    bool                          SetNodeParent(std::string_view name, std::string_view parent_name);
    bool                          SetNodeSize(std::string_view name, const Eigen::Vector2f& size);
    /// `parallaxDepth`: how far the cursor moves a layer. A write reaches the
    /// layer, its effect passes and the layers below it (Wallpaper Engine moves
    /// a whole tree by its outermost layer's depth, so a write on a child
    /// changes only that child's drift), and a layer that starts or stops
    /// following the cursor asks for a new render graph.
    Eigen::Vector2f               NodeParallaxDepth(std::string_view name) const;
    bool                          SetNodeParallaxDepth(std::string_view name, const Eigen::Vector2f& depth);
    bool                          ClearNodeTextDirty(std::string_view name);
    void                          PumpTextLayerCache();
    bool                          SetNodeTextureFrame(std::string_view name, double frame);
    double                        NodeTextureFrame(std::string_view name) const;
    /// `getTextureAnimation()`: the sprite sheet a layer draws. `play` lets it
    /// run on from the frame it is at, `pause` holds that frame, `stop` holds
    /// the first one; `rate` scales how fast it runs.
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
    bool                          NodeTextureAnimationPlaying(std::string_view name) const;
    bool                          SetNodeTextureAnimationRate(std::string_view name, double rate);
    double                        NodeTextureAnimationRate(std::string_view name) const;
    /// The frame the sheet is on: the one a script pinned, else the one last drawn.
    double                        NodeTextureAnimationFrame(std::string_view name) const;
    bool                          NodeHasVideoTexture(std::string_view name) const;
    bool                          NodeVideoTextureIsPlaying(std::string_view name) const;
    bool                          PlayNodeVideoTexture(std::string_view name);
    bool                          PauseNodeVideoTexture(std::string_view name);
    bool   SetNodeVideoTextureCurrentTime(std::string_view name, double seconds);
    double NodeVideoTextureCurrentTime(std::string_view name) const;
    bool   SetNodeVideoTextureRate(std::string_view name, float rate);
    float  NodeVideoTextureRate(std::string_view name) const;
    double NodeVideoTextureDuration(std::string_view name) const;
    void   SetVideoTextureDuration(std::string_view texture_key, double seconds);
    video::VideoPlaybackState
                                 ResolveVideoPlaybackState(std::string_view texture_key,
                                                           double           fallback_scene_elapsed_seconds) const;
    void                         DispatchCursorClick(int button = 0);
    void                         DispatchCursorDown(int button = 0);
    void                         DispatchCursorEnter();
    void                         DispatchCursorLeave();
    void                         DispatchCursorMove();
    void                         DispatchCursorUp(int button = 0);
    bool                         DispatchCursorFrameEvents(bool cursor_was_in_window);
    void                         DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                               const Eigen::Vector3f& text_color);
    void                         SetMediaIntegrationEnabled(bool enabled);
    bool                         MediaIntegrationEnabled() const;
    void                         DispatchMediaEventJson(std::string_view event_json);
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
    audio::AudioSpectrumSnapshot CurrentAudioSpectrumSnapshot() const;
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
    };
    struct NodeAlignmentBinding {
        std::string     alignment;
        Eigen::Vector3f origin { Eigen::Vector3f::Zero() };
        Eigen::Vector3f scale { Eigen::Vector3f::Ones() };
        bool            size_anchor { false };
        bool transform_dirty { true };
        Eigen::Vector3f cached_translate { Eigen::Vector3f::Zero() };
        /// Node rotation `cached_translate` was derived for; the anchor sits
        /// in the layer's own axes, so turning the layer moves the offset.
        Eigen::Vector3f rotation { Eigen::Vector3f::Zero() };
        /// The edge or corner of the presented area the node is pinned to, and
        /// the shift that puts it there. The shift is a translation in world space
        /// added to where the node is drawn (`SceneNode::SetDrawOffset`), so the
        /// node's own scale and rotation do not touch it and neither does anything
        /// that is parented to the node or reads its origin.
        TextScreenAnchor screen_anchor { TextScreenAnchor::None };
        Eigen::Vector2f  screen_offset { Eigen::Vector2f::Zero() };
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
        const Eigen::Vector2f* size { nullptr };
        std::shared_ptr<const NodeVec3Animation> animation;
        double sampled_animation_frame { std::numeric_limits<double>::quiet_NaN() };
    };
    static void ApplyNodeVec3Animation(NodeVec3Binding& binding);
    /// Called when a layer has just become visible: if that shows one the
    /// render graph left out (`Scene::render_excluded_nodes`), the graph is
    /// marked mutated so the next frame builds one that draws it.
    void RequestGraphForShownLayers();
    struct NodeEffectFinalBinding {
        SceneNode*             node { nullptr };
        SceneImageEffectLayer* layer { nullptr };
        TextLayerRenderFrame   target_frame {};
        std::shared_ptr<PassthroughCard> passthrough_card;
    };
    struct MaterialAlphaBinding {
        std::weak_ptr<SceneMaterial> material;
        std::shared_ptr<ScalarAnimationPlayback> animation;
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
    struct TextValueBinding {
        std::string   name;
        DynamicValue* value { nullptr };
    };
    struct DynamicValueListenerBinding {
        DynamicValue*         value { nullptr };
        std::function<void()> deregister;
    };
public:
    struct NodeRegistrationSnapshot {
        bool                                    has_node { false };
        /// Where the layer stood in `LayerNameAt` order, so a rollback puts it back there.
        std::size_t                             order_index { static_cast<std::size_t>(-1) };
        SceneNode*                              node { nullptr };
        std::optional<NodeVisibilityBinding>    visibility;
        std::optional<NodeVec3Binding>          translate;
        std::optional<NodeVec3Binding>          scale;
        std::optional<NodeVec3Binding>          rotation;
        std::optional<NodeEffectFinalBinding>   effect_final;
        std::optional<Eigen::Vector2f>          size;
        std::optional<NodeHitMask>              hit_mask;
        std::optional<WPPuppetLayer>            puppet_layer;
        std::optional<TextLayer>                text_layer;
        std::optional<TextEffectGate>           text_effect_gate;
        std::vector<TextValueBinding>           text_values;
        std::optional<NodeAlignmentBinding>     alignment;
        std::optional<NodeCursorTarget>         cursor_target;
        std::optional<std::string>              template_path;
        std::vector<std::string>                video_textures;
        std::weak_ptr<WPSoundStream>            sound_layer;
        bool                                    has_sound_layer { false };
        std::size_t                             owned_values_size { 0 };
        std::size_t                             scripted_values_size { 0 };
        std::size_t material_constants_size { 0 };
        std::size_t dynamic_value_listeners_size { 0 };
        std::size_t material_alpha_size { 0 };
        std::size_t material_colors_size { 0 };
        std::size_t scalar_animations_size { 0 };
    };

private:
    struct VideoTexturePlaybackBinding {
        double duration_seconds { 0.0 };
        double absolute_seconds { 0.0 };
        float  rate { 1.0f };
        bool   paused { false };
    };
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
    struct LayerTemplateBinding {
        std::string                canonical_path;
        std::shared_ptr<SceneNode> node;
        Eigen::Vector2f            size { Eigen::Vector2f::Zero() };
    };
    std::shared_ptr<WPSoundStream> LockSoundLayer(std::string_view name) const;
    void DispatchMediaPlaybackChanged(std::string_view name, bool playing);
    /// Tells the scripts nothing is playing, once, for whatever no real media
    /// event has said by the time the scene first runs. See `Tick`.
    void DispatchIdleMediaState();
    /// Notes which media event types a real event has already told the scripts,
    /// until the idle state has been decided.
    void NoteMediaEventTold(std::string_view event_json);
    void ApplyNodeTransform(std::string_view name);
    void ApplyAnchoredNodeTransform(std::string_view name);
    /// Re-derives the presented margins from the cursor viewport and moves every
    /// layer pinned to a screen anchor if they changed.
    void UpdatePresentedMargins();
    void RefreshNodeTransformBindings(const std::string& name);
    void ApplyNodeTransform(SceneNode& node, NodeAlignmentBinding& binding, const Eigen::Vector2f& size);
    /// Frees the layers `DestroyLayer` retired once the mutation they caused
    /// has been consumed, that is once no compiled graph can still draw them.
    void ReleaseRetiredLayers();
    void ApplyMaterialConstantBinding(MaterialConstantBinding& binding);
    void ApplySceneZoomAnimation();
    void ApplySceneZoom(double zoom);
    void ApplyCameraShots();
    void ApplyPerspectiveCameraShots(double seconds);
    void DispatchPendingAnimationEvents();
    bool                           CursorInsidePresentedContent() const;
    Eigen::Vector3f ScriptCursorWorldPosition() const;
    bool CursorHitsLayer(std::string_view name) const;
    bool CursorHitsLayerGeometry(std::string_view name) const;
    CursorVisit VisitCursorLayer(std::string_view name) const;
    bool CursorBlockedByLayerInFront(std::string_view name) const;
    std::optional<std::size_t> NodeRank(std::string_view name) const;
    std::optional<std::size_t> FrontmostCursorBlocker() const;
    bool CursorHitsScriptLayer(const ScriptedDynamicValue& value) const;
    bool CursorHitsScriptLayer(const SceneScriptProgram& script) const;
    CursorVisit VisitScriptLayer(const ScriptedDynamicValue& value) const;
    CursorVisit VisitScriptLayer(const SceneScriptProgram& script) const;
    void StartTextWorker();
    void StopTextWorker();
    /// Whether this text layer's pending layout is being worked on at all.
    ///
    /// A hidden layer is not: its relayout waits until it is shown again, which
    /// is an event. One another layer samples is, since its composite is drawn
    /// while it is hidden. Shared with `PumpTextLayerCache` so "in flight" and
    /// "the pump will do it" cannot drift apart.
    [[nodiscard]] bool TextLayerIsBeingPrepared(const std::string& name) const;
    void EnqueueTextLayerPreparation(std::string name, const TextLayer& layer);
    void CollectPreparedTextLayers();
    bool ApplyPreparedTextLayer(const RuntimePreparedTextLayerImage& prepared);
    /// Works the gate of the text layer `name` out from its effects as they stand.
    void RefreshTextEffectGate(const std::string& name);
    /// Moves the composite of a text layer another layer samples onto `card`,
    /// the card a relayout left it with, and resizes the target to it.
    void FitTextLayerComposite(SceneNode& node, const TextLayerRenderFrame& card);
    void TextWorkerLoop();
    // Makes `next_properties` the table in effect, refreshes every binding and
    // tells the scripts. Returns the sorted names whose value changed.
    std::vector<std::string> ApplyProjectProperties(ProjectProperties next_properties);

    std::unique_ptr<ScriptEngine>                                  m_script_engine;
    std::unique_ptr<ScriptHostContext>                             m_host_context;
    Scene*                                                         m_scene { nullptr };
    CursorViewport                                                 m_cursor_viewport {};
    // The cursor in the canvas plane, where the viewport maps the window pointer
    // (z = 0). Layers are hit in it and particles follow it. It is not what a
    // perspective scene's scripts read as `input.cursorWorldPosition`.
    Eigen::Vector3f                                                m_cursor_plane_position { Eigen::Vector3f::Zero() };
    ProjectProperties                                              m_default_project_properties;
    ProjectProperties                                              m_project_property_overrides;
    ProjectProperties                                              m_project_properties;
    // The properties read only while the scene loaded, each with the value it
    // was read with (empty: the table did not name it).
    std::map<std::string, std::optional<RuntimeScalarValue>>       m_load_only_properties;
    bool                                                           m_project_properties_changing { false };
    std::unordered_map<std::string, std::unique_ptr<DynamicValue>> m_property_values;
    std::vector<std::unique_ptr<DynamicValue>>                     m_owned_values;
    std::unordered_map<std::string, SceneNode*>                    m_nodes;
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
    TextLayerFactory                                               m_text_layer_factory;
    int32_t                                                        m_next_generated_text_id { 0x40000000 };
    std::unordered_map<std::string, std::string>                   m_layer_aliases;
    std::unordered_map<std::string, NodeVisibilityBinding>         m_node_visibility;
    /// The colour value an image layer takes its materials' colour from.
    std::unordered_map<std::string, DynamicValue*>                 m_node_color;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_translate;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_scale;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_rotation;
    std::unordered_map<std::string, NodeEffectFinalBinding>        m_node_effect_final;
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
    /// `RegisterPropertyAnimation`: handle - 1 is the index.
    std::vector<std::weak_ptr<ScalarAnimationPlayback>> m_property_animations;
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
    std::optional<std::pair<double, Eigen::Vector2f>> m_framed_camera_shot;
    std::vector<MaterialConstantBinding>                           m_material_constants;
    std::vector<TextValueBinding>                                  m_text_values;
    OwnTextWrite*                                                  m_own_text_write { nullptr };
    std::vector<DynamicValueListenerBinding>                       m_dynamic_value_listeners;
    std::unordered_map<std::string, Eigen::Vector2f>               m_node_size;
    std::unordered_map<std::string, NodeHitMask>                   m_node_hit_masks;
    std::unordered_map<std::string, WPPuppetLayer>                 m_puppet_layers;
    std::unordered_map<std::string, TextLayer>                     m_text_layers;
    std::unordered_map<std::string, TextEffectGate>                m_text_effect_gates;
    std::unordered_map<std::string, uint64_t>                      m_queued_text_revisions;
    std::unordered_map<std::string, NodeAlignmentBinding>          m_node_alignment;
    // Looked up by name every frame the cursor is in the window, so the maps
    // below take a `string_view` without making a string of it.
    struct StringHash {
        using is_transparent = void;
        std::size_t operator()(std::string_view value) const noexcept {
            return std::hash<std::string_view> {}(value);
        }
    };
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
    std::unordered_map<std::string, std::string>                   m_node_template_paths;
    std::unordered_map<std::string, LayerTemplateBinding>          m_layer_templates;
    std::function<bool(std::string_view)>                          m_layer_template_loader;
    std::unordered_set<std::string>                               m_loading_layer_templates;
    std::unordered_set<std::string>                               m_failed_layer_templates;
    std::unordered_map<std::string, std::vector<std::string>>      m_node_video_textures;
    std::unordered_map<std::string, VideoTexturePlaybackBinding, StringHash, std::equal_to<>>
        m_video_texture_playback;
    std::unordered_map<std::string, std::weak_ptr<WPSoundStream>>  m_sound_layers;
    std::shared_ptr<void>                                          m_scripted_value_registry { std::make_shared<char>() };
    std::vector<ScriptedDynamicValue*>                             m_scripted_values;
    /// How many of `m_scripted_values`, from the front, `Tick` has started.
    std::size_t                                                    m_scripted_values_started { 0 };
    std::unordered_map<ScriptedDynamicValue*, bool>                m_scripted_value_cursor_inside;
    // Who took each button's press, so its release reaches them wherever the
    // cursor has since gone. A button that shrinks while held -- these
    // transport buttons scale to a tenth of their size -- would otherwise be
    // too small to catch its own release and would stay held forever.
    std::unordered_map<uint32_t, std::vector<ScriptedDynamicValue*>> m_scripted_value_cursor_held;
    std::unordered_map<uint32_t, std::vector<std::size_t>>           m_scene_script_cursor_held;
    std::vector<SceneScriptBinding>                                m_scene_scripts;
    std::vector<std::string>                                       m_script_errors;
    mutable std::mutex                                             m_text_worker_mutex;
    std::condition_variable                                        m_text_worker_cv;
    std::thread                                                    m_text_worker;
    std::deque<RuntimePendingTextLayerJob>                         m_pending_text_jobs;
    std::vector<RuntimePreparedTextLayerImage>                     m_prepared_text_layers;
    bool                                                           m_stop_text_worker { false };
    /// Guarded by `m_text_worker_mutex`, alongside the queues it describes.
    std::function<void()>                                          m_content_wake_handler;
    uint64_t                                                       m_next_generated_layer_id { 1 };
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
    /// Called once, on whichever thread first marks the scene as reading
    /// audio. Guarded so installing it and marking cannot both miss.
    std::mutex            m_audio_requirement_mutex;
    std::function<void()> m_audio_requirement_listener;
    bool m_media_integration_enabled { false };
    /// The scene has not yet been told what it is like to have no player. The
    /// first tick does, for each of the two states a widget hides itself on that
    /// no real event reported first; real events after it replace it as usual.
    bool m_media_idle_pending { true };
    bool m_media_playback_told { false };
    bool m_media_properties_told { false };
    bool m_scene_graph_mutated { false };
    /// The display's size or the language changed since the scripts were told.
    bool m_screen_resize_pending { false };
    bool m_general_settings_pending { false };
};

std::unique_ptr<SceneRuntimeContext> CreateSceneRuntimeContext(SceneRuntimeBootstrap bootstrap);

} // namespace wallpaper
