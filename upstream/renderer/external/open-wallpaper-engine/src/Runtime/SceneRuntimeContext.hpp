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
    Eigen::Vector2f layout_size { Eigen::Vector2f::Zero() };
    Eigen::Vector2f raster_size { Eigen::Vector2f::Zero() };
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
    void          SetCursorWorldPosition(const Eigen::Vector3f& value);
    // World rectangle the window shows, so window-normalized cursor input lands
    // where the presented wallpaper actually draws each layer.
    void          SetCursorViewport(const CursorViewport& viewport);
    /// The display's pixel resolution, which `engine.screenResolution` reports.
    /// Distinct from the cursor viewport above, which is scene world units,
    /// and from the rasterization size, which internal quality may reduce.
    void          SetScreenResolution(const Eigen::Vector2f& resolution);
    void          SetCursorInput(float x, float y);
    void          SetCursorEnter(bool entered);
    void          SetCursorButton(int button, bool pressed);
    void          SetCursorButtons(uint32_t down, uint32_t pressed, uint32_t released);
    void          BeginFrame();
    DynamicValue* FindPropertyValue(std::string_view name) const;
    void          RegisterScriptedValue(ScriptedDynamicValue* value);
    void          RegisterNode(std::string name, SceneNode* node);
    void          RegisterLayerAlias(std::string authored_name, std::string runtime_name);
    std::string   ResolveLayerName(std::string_view name) const;
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
    double        PuppetAnimationControl(std::string_view layer_name,
                                         std::string_view animation_layer,
                                         std::string_view operation, double value,
                                         bool has_value);
    void          RegisterLayerTemplate(std::string template_path, std::shared_ptr<SceneNode> node,
                                        Eigen::Vector2f size);
    // Called synchronously on a registry miss. The loader registers the requested
    // normalized template without attaching a drawable source to the scene graph.
    void          SetLayerTemplateLoader(std::function<bool(std::string_view)> loader);
    void          RegisterNodeVisibility(std::string name, SceneNode* node,
                                         std::unique_ptr<DynamicValue> value);
    void          RegisterNodeTranslate(std::string name, SceneNode* node,
                                        std::unique_ptr<DynamicValue> value,
                                        std::shared_ptr<const NodeOriginAnimation> animation = {});
    void RegisterNodeScale(std::string name, SceneNode* node, std::unique_ptr<DynamicValue> value);
    void RegisterNodeRotation(std::string name, SceneNode* node,
                              std::unique_ptr<DynamicValue> value);
    void RegisterTextLayer(std::string name, TextLayerState state);
    void RegisterTextValue(std::string name, std::unique_ptr<DynamicValue> value,
                           bool apply_current_value = true);
    void RegisterMaterialConstant(std::shared_ptr<SceneMaterial> material, std::string name,
                                  std::unique_ptr<DynamicValue> value,
                                  std::shared_ptr<const MaterialConstantAnimation> animation = {});
    void RegisterSceneClearColor(std::unique_ptr<DynamicValue> value);
    void RegisterSceneZoomAnimation(std::shared_ptr<ScalarAnimationPlayback> animation);
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
    void RegisterNodeEffectFinal(std::string name, SceneNode* node, SceneImageEffectLayer* layer,
                                 TextLayerRenderFrame target_frame = {});
    void RegisterMaterialAlphaAnimation(std::shared_ptr<SceneMaterial> material,
                                        std::shared_ptr<ScalarAnimationPlayback> animation);
    // A scripted or user-bound image `alpha` is not an animation timeline.
    // The flat shader reads `g_Alpha`, so the live value has to land there.
    void BindMaterialAlpha(std::shared_ptr<SceneMaterial> material,
                           std::unique_ptr<DynamicValue> value);
    // A user-bound image `color` tints every material the layer draws with:
    // its own and each effect pass. One value feeds them all, and the alpha in
    // `g_Color4` is left to the alpha bindings.
    void BindMaterialColor(std::vector<std::shared_ptr<SceneMaterial>> materials,
                           std::unique_ptr<DynamicValue> value);
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
    // Removes a layer `CreateLayerFromTemplate` made: it leaves the scene graph
    // and every registry at once, so whatever a script still holds for it
    // reaches nothing. The node itself is kept until the graph has been rebuilt
    // without it, as the graph compiled before still points at it. A layer the
    // scene file made, or an unknown name, is left alone and answers false.
    bool            DestroyLayer(std::string_view name);
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
    // so a frame never has two writers.
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
    bool            SetNodeRotation(std::string_view name, const Eigen::Vector3f& value);
    Eigen::Vector3f NodeTranslate(std::string_view name) const;
    Eigen::Vector3f NodeScale(std::string_view name) const;
    Eigen::Vector3f NodeRotation(std::string_view name) const;
    Eigen::Vector2f NodeSize(std::string_view name) const;
    std::string     NodeText(std::string_view name) const;
    bool            NodeTextDirty(std::string_view name) const;
    std::optional<TextLayerState> NodeTextState(std::string_view name) const;
    bool                          SetNodeText(std::string_view name, std::string text);
    bool                          ClearNodeTextDirty(std::string_view name);
    void                          PumpTextLayerCache();
    bool                          SetNodeTextureFrame(std::string_view name, double frame);
    double                        NodeTextureFrame(std::string_view name) const;
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
    };
    struct NodeVec3Binding {
        SceneNode*    node { nullptr };
        DynamicValue* value { nullptr };
        SceneNode* transform_node { nullptr };
        NodeAlignmentBinding* alignment { nullptr };
        const Eigen::Vector2f* size { nullptr };
        std::shared_ptr<const NodeOriginAnimation> animation;
        double sampled_animation_frame { std::numeric_limits<double>::quiet_NaN() };
    };
    static void ApplyNodeOriginAnimation(NodeVec3Binding& binding);
    /// Called when a layer has just become visible: if that shows one the
    /// render graph left out (`Scene::render_excluded_nodes`), the graph is
    /// marked mutated so the next frame builds one that draws it.
    void RequestGraphForShownLayers();
    struct NodeEffectFinalBinding {
        SceneNode*             node { nullptr };
        SceneImageEffectLayer* layer { nullptr };
        TextLayerRenderFrame   target_frame {};
    };
    struct MaterialAlphaBinding {
        std::weak_ptr<SceneMaterial> material;
        std::shared_ptr<ScalarAnimationPlayback> animation;
    };
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
        std::vector<TextValueBinding>           text_values;
        std::optional<NodeAlignmentBinding>     alignment;
        std::optional<std::string>              template_path;
        std::vector<std::string>                video_textures;
        std::weak_ptr<WPSoundStream>            sound_layer;
        bool                                    has_sound_layer { false };
        std::size_t                             owned_values_size { 0 };
        std::size_t                             scripted_values_size { 0 };
        std::size_t material_constants_size { 0 };
        std::size_t dynamic_value_listeners_size { 0 };
        std::size_t material_alpha_size { 0 };
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
    void ApplyNodeTransform(std::string_view name);
    void ApplyAnchoredNodeTransform(std::string_view name);
    void RefreshNodeTransformBindings(const std::string& name);
    void ApplyNodeTransform(SceneNode& node, NodeAlignmentBinding& binding, const Eigen::Vector2f& size);
    /// Frees the layers `DestroyLayer` retired once the mutation they caused
    /// has been consumed, that is once no compiled graph can still draw them.
    void ReleaseRetiredLayers();
    void ApplyMaterialConstantBinding(MaterialConstantBinding& binding);
    void ApplySceneZoomAnimation();
    void ApplyCameraShots();
    void ApplyPerspectiveCameraShots(double seconds);
    void DispatchPendingAnimationEvents();
    bool                           CursorInsidePresentedContent() const;
    bool CursorHitsLayer(std::string_view name) const;
    bool CursorHitsScriptLayer(const ScriptedDynamicValue& value) const;
    bool CursorHitsScriptLayer(const SceneScriptProgram& script) const;
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
    std::unordered_map<std::string, std::string>                   m_layer_aliases;
    std::unordered_map<std::string, NodeVisibilityBinding>         m_node_visibility;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_translate;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_scale;
    std::unordered_map<std::string, NodeVec3Binding>               m_node_rotation;
    std::unordered_map<std::string, NodeEffectFinalBinding>        m_node_effect_final;
    std::vector<MaterialAlphaBinding>                              m_material_alpha;
    struct NodeAlphaBinding {
        std::shared_ptr<SceneMaterial> material;
        float                          value { 1.0f };
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
    std::optional<std::pair<double, Eigen::Vector2f>> m_framed_camera_shot;
    std::vector<MaterialConstantBinding>                           m_material_constants;
    std::vector<TextValueBinding>                                  m_text_values;
    std::vector<DynamicValueListenerBinding>                       m_dynamic_value_listeners;
    std::unordered_map<std::string, Eigen::Vector2f>               m_node_size;
    std::unordered_map<std::string, NodeHitMask>                   m_node_hit_masks;
    std::unordered_map<std::string, WPPuppetLayer>                 m_puppet_layers;
    std::unordered_map<std::string, TextLayer>                     m_text_layers;
    std::unordered_map<std::string, uint64_t>                      m_queued_text_revisions;
    std::unordered_map<std::string, NodeAlignmentBinding>          m_node_alignment;
    std::unordered_map<std::string, std::string>                   m_node_template_paths;
    std::unordered_map<std::string, LayerTemplateBinding>          m_layer_templates;
    std::function<bool(std::string_view)>                          m_layer_template_loader;
    std::unordered_set<std::string>                               m_loading_layer_templates;
    std::unordered_set<std::string>                               m_failed_layer_templates;
    std::unordered_map<std::string, std::vector<std::string>>      m_node_video_textures;
    struct StringHash {
        using is_transparent = void;
        std::size_t operator()(std::string_view value) const noexcept {
            return std::hash<std::string_view> {}(value);
        }
    };
    std::unordered_map<std::string, VideoTexturePlaybackBinding, StringHash, std::equal_to<>>
        m_video_texture_playback;
    std::unordered_map<std::string, std::weak_ptr<WPSoundStream>>  m_sound_layers;
    std::vector<ScriptedDynamicValue*>                             m_scripted_values;
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
    bool m_scene_graph_mutated { false };
};

std::unique_ptr<SceneRuntimeContext> CreateSceneRuntimeContext(SceneRuntimeBootstrap bootstrap);

} // namespace wallpaper
