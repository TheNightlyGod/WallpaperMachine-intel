// Clean-room implementation from the WallpaperMachine spec e2-runtime-animation.md; written without access to the original source.
#include "Runtime/ScriptedDynamicValue.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scripting/ScriptEngine.hpp"

namespace wallpaper
{

ScriptedDynamicValue::ScriptedDynamicValue(
    SceneRuntimeContext& runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValueUniquePtr> script_properties, DynamicValue base_value,
    ScriptedValueSemantic semantic, int animation_layer_index, std::string effect_reference,
    std::string setting_animation_reference) :
    m_runtime(&runtime),
    m_registry(runtime.ScriptedValueRegistryToken()),
    m_current_layer_name(std::move(current_layer_name)),
    m_script_properties(std::move(script_properties)) {
    // The value starts as the setting it replaces: the same content, kind included.
    DynamicValue::update(base_value);

    std::map<std::string, DynamicValue*> parameters;
    for (auto& [name, property] : m_script_properties) {
        if (property != nullptr) parameters.emplace(name, property.get());
    }
    m_program = runtime.scriptEngine().CreatePropertyScriptProgram(
        &runtime, std::move(script_source), m_current_layer_name, std::move(parameters),
        std::move(base_value), runtime.hostContext(),
        semantic == ScriptedValueSemantic::AnglesDegrees ? PropertyScriptValueSemantic::AnglesDegrees
                                                          : PropertyScriptValueSemantic::Generic,
        animation_layer_index, std::move(effect_reference), std::move(setting_animation_reference));

    // A parameter that changes re-runs the script at once.
    for (auto& [name, property] : m_script_properties) {
        if (property == nullptr) continue;
        property->listen([this](const DynamicValue&) { reevaluate(); });
    }
}

ScriptedDynamicValue::~ScriptedDynamicValue() {
    // The runtime lists every scripted value it should tick and tear down; one
    // that is destroyed first takes itself off the list.
    if (! m_registry.expired()) m_runtime->UnregisterScriptedValue(this);
}

bool ScriptedDynamicValue::Initialised() const noexcept {
    return m_program == nullptr || ! m_program->Valid() || m_program->Initialised();
}

void ScriptedDynamicValue::RunInit() {
    if (m_program == nullptr || ! m_program->Valid() || m_program->Initialised()) return;
    // A text script that writes its own layer's text from `init` and returns nothing has
    // decided the text, as it does from `update`.
    SceneRuntimeContext::OwnTextWrite own_text_write(*m_runtime, *this);
    auto answer = m_program->RunInit(m_runtime->hostContext(), *this);
    if (answer != nullptr) {
        DynamicValue::update(*answer);
    } else if (own_text_write.Written().has_value()) {
        DynamicValue::update(*own_text_write.Written());
    }
}

void ScriptedDynamicValue::RunUserNotices() {
    if (m_program != nullptr) m_program->RunUserNotices(m_runtime->hostContext());
}

void ScriptedDynamicValue::reevaluate() {
    if (m_runtime->ProjectPropertiesChanging() || m_program == nullptr || ! m_program->Valid()) return;
    // Not started yet (a property it reads changed before the scene's first tick): it starts
    // now, in the same two steps.
    if (! m_program->Initialised()) {
        RunInit();
        RunUserNotices();
        if (! m_program->Valid()) return;
    }

    // update(value) continues from the previous result, including explicit property writes.
    SceneRuntimeContext::OwnTextWrite own_text_write(*m_runtime, *this);
    auto result = m_program->Evaluate(m_runtime->hostContext(), *this);
    if (! m_program->Capabilities().update || result == nullptr) return;
    // The text script that writes its own layer's text and returns nothing has
    // decided the text: the current value would put the string it started with
    // back over the write.
    if (own_text_write.Written().has_value() && ! m_program->UpdateReturnedValue()) {
        DynamicValue::update(*own_text_write.Written());
    } else {
        DynamicValue::update(*result);
    }
}

void ScriptedDynamicValue::ApplyProjectProperties(const ProjectProperties& project_properties,
                                                 const ProjectProperties& changed_properties) {
    if (m_program != nullptr) m_program->ApplyProjectProperties(project_properties, changed_properties);
}

uint8_t ScriptedDynamicValue::CursorHandlerMask() const noexcept {
    return m_program != nullptr && m_program->Valid() ? m_program->Capabilities().cursor_handlers : 0;
}

// Cursor events go straight to the script program, when there is one.
#define FORWARD_CURSOR_EVENT(event)                                              \
    void ScriptedDynamicValue::DispatchCursor##event(const ScriptHostContext& ctx) { \
        if (m_program != nullptr) m_program->DispatchCursor##event(ctx);         \
    }

FORWARD_CURSOR_EVENT(Click)
FORWARD_CURSOR_EVENT(Down)
FORWARD_CURSOR_EVENT(Enter)
FORWARD_CURSOR_EVENT(Leave)
FORWARD_CURSOR_EVENT(Move)
FORWARD_CURSOR_EVENT(Up)

#undef FORWARD_CURSOR_EVENT

void ScriptedDynamicValue::DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                  std::string_view event_name, double frame) {
    if (m_program != nullptr) m_program->DispatchAnimationEvent(host_context, event_name, frame);
}

void ScriptedDynamicValue::DispatchMediaThumbnailChanged(const linalg::Vector3f& primary_color,
                                                         const linalg::Vector3f& text_color) {
    if (m_program != nullptr) m_program->DispatchMediaThumbnailChanged(primary_color, text_color);
}

void ScriptedDynamicValue::DispatchMediaEventJson(std::string_view event_json) {
    if (m_program != nullptr) m_program->DispatchMediaEventJson(event_json);
}

void ScriptedDynamicValue::DispatchResizeScreen(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchResizeScreen(host_context);
}

void ScriptedDynamicValue::DispatchGeneralSettings(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchGeneralSettings(host_context);
}

void ScriptedDynamicValue::Destroy() {
    if (m_program != nullptr) m_program->Destroy();
}

} // namespace wallpaper
