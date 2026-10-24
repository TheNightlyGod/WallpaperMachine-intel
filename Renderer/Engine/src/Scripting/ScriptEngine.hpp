#pragma once

#include "Project/ProjectProperties.hpp"
#include "Runtime/DynamicValue.hpp"

#include "Utils/Linalg.hpp"

#include <map>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>

struct JSContext;
struct JSRuntime;

namespace wallpaper
{

class SceneRuntimeContext;
// The execution context of one engine and the state around it (defined in ScriptEngine.cpp).
struct ScriptEngineContext;

struct ScriptHostContext {
    linalg::Vector2f canvas_size { 0.0f, 0.0f };
    linalg::Vector2f screen_resolution { 0.0f, 0.0f };
    linalg::Vector2f cursor_normalized_position { 0.5f, 0.5f };
    linalg::Vector3f cursor_world_position { 0.0f, 0.0f, 0.0f };
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

// The cost and bookkeeping limits of the script host (spec R98, R99). One value
// holds them all; a test replaces it with `ScriptEngine::SetLimits` and a fake
// clock so hostile scripts run in no time.
struct ScriptLimits {
    // Wall-clock budget of one host-initiated call into a script (a tick of one
    // program, an event, a notification, a timer pass) and of program creation
    // (compile, top level and, for a scene program, `init` and its notices).
    double      call_budget_ms { 50.0 };
    double      creation_budget_ms { 250.0 };
    // A program interrupted on this many consecutive calls is disabled for good.
    int         max_consecutive_interrupts { 3 };
    std::size_t memory_limit_bytes { 64u * 1024u * 1024u };
    // At 1 MiB a function with a dozen locals only nests ~900 calls deep (R99 asks for
    // 1,000); a thread with less stack than this is given what it has (see the engine).
    std::size_t stack_limit_bytes { 2u * 1024u * 1024u };
    // Recorded error texts are cut to this many characters.
    std::size_t max_error_text_chars { 1024 };
    // Per entry point: this many errors are logged in full, then one summary line
    // per `log_summary_seconds` states how many were held back.
    int         log_full_count { 5 };
    double      log_summary_seconds { 10.0 };
    // Monotonic nanoseconds that do not run during system sleep; empty means
    // `std::chrono::steady_clock`. Interrupts are measured on it.
    std::function<int64_t()> clock_nanoseconds {};
    // Seconds for the log rate limit; empty means the same clock.
    std::function<double()>  log_clock_seconds {};
};

// Where the time and the work of starting scripts went, in milliseconds and counts.
struct ScriptStartupMetrics {
    double   module_strip_ms { 0.0 };            // removing import/export syntax
    double   bootstrap_build_ms { 0.0 };         // building the shared runtime
    double   wrapper_build_ms { 0.0 };           // wrapping each script
    double   eval_ms { 0.0 };                    // running it the first time
    double   callback_registration_ms { 0.0 };   // finding its handlers
    uint64_t bootstrap_installs { 0 };           // times the runtime was set up
    uint64_t script_compiles { 0 };              // scripts compiled
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
        int animation_layer_index = -1, std::string effect_reference = {},
        std::string setting_animation_reference = {});
    ~PropertyScriptProgram();

    PropertyScriptProgram(const PropertyScriptProgram&)            = delete;
    PropertyScriptProgram& operator=(const PropertyScriptProgram&) = delete;

    bool                  Valid() const;
    const ScriptProgramCapabilities& Capabilities() const noexcept { return m_capabilities; }
    DynamicValueUniquePtr Evaluate(const ScriptHostContext& host_context,
                                   const DynamicValue&      current_value);
    /// Whether the program has run its `init`. A program starts in two steps, so that every
    /// script of a scene is initialised before any is told the user properties: `RunInit`, then
    /// `RunUserNotices`. `Evaluate` does whatever of the two has not happened yet.
    bool                  Initialised() const noexcept;
    /// Runs `init(value)` once. What it returns is answered as `Evaluate` answers the result of
    /// `update` (null when it returned nothing, threw, or gave an object for a flag).
    DynamicValueUniquePtr RunInit(const ScriptHostContext& host_context,
                                  const DynamicValue&      current_value);
    /// Tells the script the language and the user properties, once, after `RunInit`.
    void                  RunUserNotices(const ScriptHostContext& host_context);
    /// Whether the last `Evaluate` got a value from `update()`. When it did not
    /// (it returned nothing, or threw), `Evaluate` hands back the current value.
    bool                  UpdateReturnedValue() const noexcept { return m_update_returned_value; }
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
    void                  DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                                        const linalg::Vector3f& text_color);
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
    struct State;
    ScriptProgramCapabilities             m_capabilities;
    bool                                 m_update_returned_value = false;
    bool                                 m_destroyed    = false;
    // The animation layer this script is attached to (`animationlayers[i]`), or -1
    // when it is attached to the layer itself. `thisObject` is that animation layer.
    int                                  m_animation_layer_index = -1;
    std::unique_ptr<State>               m_state;
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
    const std::string& LayerName() const;
    void               Tick(const ScriptHostContext& host_context);
    void               DispatchCursorClick(const ScriptHostContext& host_context);
    void               DispatchCursorDown(const ScriptHostContext& host_context);
    void               DispatchCursorEnter(const ScriptHostContext& host_context);
    void               DispatchCursorLeave(const ScriptHostContext& host_context);
    void               DispatchCursorMove(const ScriptHostContext& host_context);
    void               DispatchCursorUp(const ScriptHostContext& host_context);
    void               DispatchAnimationEvent(const ScriptHostContext& host_context,
                                              std::string_view event_name, double frame);
    void               DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                                     const linalg::Vector3f& text_color);
    void               DispatchMediaEventJson(std::string_view event_json);
    void               ApplyProjectProperties(const ProjectProperties& project_properties,
                                               const ProjectProperties& changed_properties);
    void               DispatchResizeScreen(const ScriptHostContext& host_context);
    void               DispatchGeneralSettings(const ScriptHostContext& host_context);
    void               Destroy();

private:
    struct State;
    void ApplyUserProperties(const ProjectProperties& property_changes);
    ScriptProgramCapabilities m_capabilities;
    bool                 m_destroyed    = false;
    std::string          m_layer_name;
    std::unique_ptr<State> m_state;
};

class ScriptEngine {
public:
    ScriptEngine();
    ~ScriptEngine();

    ScriptEngine(const ScriptEngine&)            = delete;
    ScriptEngine& operator=(const ScriptEngine&) = delete;

    /// Replaces this engine's limits (R98, R99). Budgets, interrupt policy, log
    /// rate limit and the memory and stack caps apply from the next call on.
    void                        SetLimits(const ScriptLimits& limits);
    ScriptLimits                Limits() const;

    static void                 ResetStartupMetrics();          // zeroes the counters
    static ScriptStartupMetrics GetStartupMetrics();            // a copy of them

    /// One-shot evaluation of a property script against `current_value`.
    DynamicValueUniquePtr Evaluate(const std::string& script_source,
                                   const std::map<std::string, DynamicValue*>& properties,
                                   const DynamicValue& current_value,
                                   const ScriptHostContext& host_context);

    /// A long-lived program for one property: it keeps its state between ticks.
    std::unique_ptr<PropertyScriptProgram> CreatePropertyScriptProgram(
        SceneRuntimeContext*                 runtime,
        std::string                          script_source,
        std::string                          current_layer_name,
        std::map<std::string, DynamicValue*> script_properties,
        DynamicValue                         initial_value,
        ScriptHostContext                    host_context,
        PropertyScriptValueSemantic          semantic = PropertyScriptValueSemantic::Generic,
        int                                  animation_layer_index = -1,
        std::string                          effect_reference = {},
        std::string                          setting_animation_reference = {});

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
    std::shared_ptr<ScriptEngineContext> m_context;
};

} // namespace wallpaper
