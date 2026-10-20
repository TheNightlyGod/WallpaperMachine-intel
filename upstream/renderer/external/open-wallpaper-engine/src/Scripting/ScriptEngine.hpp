#pragma once

#include "Project/ProjectProperties.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/PropertyScriptObject.hpp"

#include <Eigen/Dense>

#include <map>
#include <optional>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>

struct JSContext;
struct JSRuntime;

namespace wallpaper
{

class SceneRuntimeContext;

struct ScriptHostContext {
    Eigen::Vector2f canvas_size { 0.0f, 0.0f };
    Eigen::Vector2f screen_resolution { 0.0f, 0.0f };
    Eigen::Vector2f cursor_normalized_position { 0.5f, 0.5f };
    Eigen::Vector3f cursor_world_position { 0.0f, 0.0f, 0.0f };
    double          frame_time { 0.0 };
    double          runtime_seconds { 0.0 };
    bool            cursor_in_window { false };
    int             cursor_button { 0 };
    uint32_t        mouse_buttons_down { 0 };
    uint32_t        mouse_buttons_pressed { 0 };
    uint32_t        mouse_buttons_released { 0 };
    // Lower-case BCP-47 tag of the interface language, which a script is told in
    // `applyGeneralSettings({ language })`.
    std::string     language { "en-us" };
};

struct ScriptStartupMetrics {
    double   module_strip_ms { 0.0 };
    double   bootstrap_build_ms { 0.0 };
    double   wrapper_build_ms { 0.0 };
    double   eval_ms { 0.0 };
    double   callback_registration_ms { 0.0 };
    uint64_t bootstrap_installs { 0 };
    uint64_t script_compiles { 0 };
};

enum class PropertyScriptValueSemantic
{
    Generic,
    AnglesDegrees,
};

enum class ScriptCursorEvent : uint8_t {
    Click = 1u << 0,
    Down = 1u << 1,
    Enter = 1u << 2,
    Leave = 1u << 3,
    Move = 1u << 4,
    Up = 1u << 5,
};

struct ScriptProgramCapabilities {
    bool update { false };
    uint8_t cursor_handlers { 0 };
    bool animation_event { false };
};

class PropertyScriptProgram {
public:
    PropertyScriptProgram(
        SceneRuntimeContext* runtime, std::string script_source, std::string current_layer_name,
        std::map<std::string, DynamicValue*> script_properties, DynamicValue initial_value,
        ScriptHostContext host_context, JSRuntime* shared_runtime, JSContext* shared_context,
        std::string exports_object_name, std::string script_properties_name,
        PropertyScriptValueSemantic semantic = PropertyScriptValueSemantic::Generic,
        PropertyScriptObject object = {});
    ~PropertyScriptProgram();

    PropertyScriptProgram(const PropertyScriptProgram&)            = delete;
    PropertyScriptProgram& operator=(const PropertyScriptProgram&) = delete;

    bool                  Valid() const;
    const ScriptProgramCapabilities& Capabilities() const noexcept { return m_capabilities; }
    /// Runs `init` with the property's current value, once, and answers what it
    /// returned as the property's value from then on (null when it returned
    /// nothing). The scene starts every script this way before it tells any of
    /// them the user properties: one script's first `applyUserProperties` may
    /// call what another script's `init` set up.
    DynamicValueUniquePtr Start(const ScriptHostContext& host_context,
                                const DynamicValue&      current_value);
    /// The first `applyUserProperties`, with every property, once `init` ran.
    void                  DeliverInitialUserProperties();
    /// Starts the script and delivers the properties first if nothing has, then
    /// runs `update`.
    DynamicValueUniquePtr Evaluate(const ScriptHostContext& host_context,
                                   const DynamicValue&      current_value);
    /// Whether the last `Evaluate` got a value from `update()`. When it did not
    /// (it returned nothing, or threw), `Evaluate` hands back the current value.
    bool                  UpdateReturnedValue() const noexcept { return m_update_returned_value; }
    /// What the script last wrote to its effect's `visible`, once, when it is an
    /// effect's visibility (`PropertyScriptObject::effect_visibility`) and wrote
    /// it since this was last asked; nothing otherwise.
    std::optional<bool>   TakeOwnVisibilityWrite();
    void                  ApplyProjectProperties(const ProjectProperties& project_properties,
                                                  const ProjectProperties& changed_properties);
    void                  DispatchCursorClick(const ScriptHostContext& host_context);
    void                  DispatchCursorDown(const ScriptHostContext& host_context);
    void                  DispatchCursorEnter(const ScriptHostContext& host_context);
    void                  DispatchCursorLeave(const ScriptHostContext& host_context);
    void                  DispatchCursorMove(const ScriptHostContext& host_context);
    void                  DispatchCursorUp(const ScriptHostContext& host_context);
    void                  DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                 std::string_view event_name, double frame);
    void                  DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                        const Eigen::Vector3f& text_color);
    void                  DispatchMediaEventJson(std::string_view event_json);
    // The display's size or the interface language changed since the script
    // started. A script that has not run `init` yet has nothing to be told:
    // `init` reads the current values.
    void                  DispatchResizeScreen(const ScriptHostContext& host_context);
    void                  DispatchGeneralSettings(const ScriptHostContext& host_context);
    // Runs the script's `destroy()` once, if it started. Called when the scene
    // or the script is torn down, while what the script could still touch is
    // alive.
    void                  Destroy();

private:
    void UpdateHostContext(const ScriptHostContext& host_context);
    void UpdateScriptProperties();

    std::map<std::string, DynamicValue*> m_script_properties;
    void*                                m_impl_runtime = nullptr;
    void*                                m_impl_context = nullptr;
    SceneRuntimeContext*                 m_runtime      = nullptr;
    std::string                          m_current_layer_name;
    std::string                          m_exports_object_name;
    std::string                          m_script_properties_name;
    PropertyScriptValueSemantic          m_semantic { PropertyScriptValueSemantic::Generic };
    ScriptProgramCapabilities             m_capabilities;
    bool                                 m_owns_context = false;
    bool                                 m_valid        = false;
    bool                                 m_init_called  = false;
    bool                                 m_user_properties_delivered = false;
    bool                                 m_update_returned_value = false;
    bool                                 m_destroyed    = false;
    // What `thisObject` is beyond the layer: the animation layer the script is
    // attached to (`animationlayers[i]`), the effect whose visibility it decides,
    // the timeline bound to its setting.
    PropertyScriptObject                 m_object;
    // Where an effect's `thisObject` keeps the `visible` the script wrote, until
    // `TakeOwnVisibilityWrite` takes it. Empty for any other script.
    std::string                          m_own_state_name;
};

class SceneScriptProgram {
public:
    SceneScriptProgram(SceneRuntimeContext& runtime, std::string script_source,
                       std::string current_layer_name, ProjectProperties project_properties,
                       ScriptHostContext host_context, JSRuntime* shared_runtime,
                       JSContext* shared_context, std::string exports_object_name);
    ~SceneScriptProgram();

    SceneScriptProgram(const SceneScriptProgram&)            = delete;
    SceneScriptProgram& operator=(const SceneScriptProgram&) = delete;

    bool               Valid() const;
    const ScriptProgramCapabilities& Capabilities() const noexcept { return m_capabilities; }
    const std::string& LayerName() const { return m_current_layer_name; }
    void               Tick(const ScriptHostContext& host_context);
    void               DispatchCursorClick(const ScriptHostContext& host_context);
    void               DispatchCursorDown(const ScriptHostContext& host_context);
    void               DispatchCursorEnter(const ScriptHostContext& host_context);
    void               DispatchCursorLeave(const ScriptHostContext& host_context);
    void               DispatchCursorMove(const ScriptHostContext& host_context);
    void               DispatchCursorUp(const ScriptHostContext& host_context);
    void               DispatchAnimationEvent(const ScriptHostContext& host_context,
                                              std::string_view event_name, double frame);
    void               DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                     const Eigen::Vector3f& text_color);
    void               DispatchMediaEventJson(std::string_view event_json);
    void               ApplyProjectProperties(const ProjectProperties& project_properties,
                                               const ProjectProperties& changed_properties);
    void               DispatchResizeScreen(const ScriptHostContext& host_context);
    void               DispatchGeneralSettings(const ScriptHostContext& host_context);
    void               Destroy();

private:
    void ApplyUserProperties(const ProjectProperties& property_changes);
    void UpdateHostContext(const ScriptHostContext& host_context);

    SceneRuntimeContext* m_runtime = nullptr;
    std::string          m_script_source;
    std::string          m_current_layer_name;
    ProjectProperties    m_project_properties;
    std::string          m_exports_object_name;
    void*                m_impl_runtime = nullptr;
    void*                m_impl_context = nullptr;
    ScriptProgramCapabilities m_capabilities;
    bool                 m_owns_context = false;
    bool                 m_valid        = false;
    bool                 m_destroyed    = false;
};

class ScriptEngine {
public:
    ScriptEngine();
    ~ScriptEngine();

    ScriptEngine(const ScriptEngine&)            = delete;
    ScriptEngine& operator=(const ScriptEngine&) = delete;

    static void                 ResetStartupMetrics();
    static ScriptStartupMetrics GetStartupMetrics();

    DynamicValueUniquePtr                  Evaluate(const std::string&                          script_source,
                                                    const std::map<std::string, DynamicValue*>& script_properties,
                                                    const DynamicValue&                         current_value,
                                                    const ScriptHostContext&                    host_context);
    std::unique_ptr<PropertyScriptProgram> CreatePropertyScriptProgram(
        SceneRuntimeContext* runtime, std::string script_source, std::string current_layer_name,
        std::map<std::string, DynamicValue*> script_properties, DynamicValue initial_value,
        ScriptHostContext           host_context,
        PropertyScriptValueSemantic semantic = PropertyScriptValueSemantic::Generic,
        PropertyScriptObject        object = {});
    std::unique_ptr<SceneScriptProgram>
    CreateSceneScriptProgram(SceneRuntimeContext& runtime, std::string script_source,
                             std::string current_layer_name, ProjectProperties project_properties,
                             ScriptHostContext host_context);
    // The global `engine.on`/`scene.on` list lives on the shared context, so it
    // is run once per event rather than once per program that owns a handler.
    // Nothing else may have refreshed `engine` this tick, so it is updated here.
    void RunAnimationEventCallbacks(const ScriptHostContext& host_context,
                                    std::string_view event_name, double frame);
    // Listeners registered with `engine.on('resizeScreen', ...)`, once per resize.
    void RunResizeScreenCallbacks(const ScriptHostContext& host_context);
    // `addEndedCallback` listeners of one animation layer of a puppet layer.
    void NotifyAnimationLayerEnded(const ScriptHostContext& host_context,
                                   std::string_view layer_name, int animation_layer_index);

private:
    JSRuntime* m_runtime         = nullptr;
    JSContext* m_context         = nullptr;
    uint64_t   m_next_program_id = 0;
};

} // namespace wallpaper
