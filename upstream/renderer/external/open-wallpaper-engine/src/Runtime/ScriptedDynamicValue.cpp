#include "Runtime/ScriptedDynamicValue.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scripting/ScriptEngine.hpp"

namespace wallpaper
{

ScriptedDynamicValue::ScriptedDynamicValue(
    SceneRuntimeContext& runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValueUniquePtr> script_properties, DynamicValue base_value,
    ScriptedValueSemantic semantic, int animation_layer_index)
    : m_runtime(&runtime),
      m_registry(runtime.ScriptedValueRegistryToken()),
      m_current_layer_name(std::move(current_layer_name)),
      m_script_properties(std::move(script_properties)),
      m_semantic(semantic) {
    DynamicValue::update(base_value);

    std::map<std::string, DynamicValue*> raw_properties;
    for (auto& [name, property] : m_script_properties) {
        if (property == nullptr) continue;
        raw_properties.emplace(name, property.get());
    }

    const auto program_semantic = m_semantic == ScriptedValueSemantic::AnglesDegrees
                                      ? PropertyScriptValueSemantic::AnglesDegrees
                                      : PropertyScriptValueSemantic::Generic;
    m_program                   = m_runtime->scriptEngine().CreatePropertyScriptProgram(m_runtime,
                                                                      std::move(script_source),
                                                                      m_current_layer_name,
                                                                      std::move(raw_properties),
                                                                      std::move(base_value),
                                                                      m_runtime->hostContext(),
                                                                      program_semantic,
                                                                      animation_layer_index);

    for (auto& [name, property] : m_script_properties) {
        (void)name;
        if (property == nullptr) continue;
        property->listen([this](const DynamicValue&) {
            reevaluate();
        });
    }
}

ScriptedDynamicValue::~ScriptedDynamicValue() {
    // The runtime lists every scripted value it should tick and tear down; one
    // that is destroyed first takes itself off the list.
    if (! m_registry.expired()) m_runtime->UnregisterScriptedValue(this);
}

void ScriptedDynamicValue::reevaluate() {
    if (m_runtime->ProjectPropertiesChanging() || m_program == nullptr || ! m_program->Valid()) return;

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

void ScriptedDynamicValue::DispatchCursorClick(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorClick(host_context);
}

void ScriptedDynamicValue::DispatchCursorDown(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorDown(host_context);
}

void ScriptedDynamicValue::DispatchCursorEnter(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorEnter(host_context);
}

void ScriptedDynamicValue::DispatchCursorLeave(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorLeave(host_context);
}

void ScriptedDynamicValue::DispatchCursorMove(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorMove(host_context);
}

void ScriptedDynamicValue::DispatchCursorUp(const ScriptHostContext& host_context) {
    if (m_program != nullptr) m_program->DispatchCursorUp(host_context);
}

void ScriptedDynamicValue::DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                  std::string_view event_name, double frame) {
    if (m_program != nullptr) m_program->DispatchAnimationEvent(host_context, event_name, frame);
}

void ScriptedDynamicValue::DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                         const Eigen::Vector3f& text_color) {
    if (m_program != nullptr) {
        m_program->DispatchMediaThumbnailChanged(primary_color, text_color);
    }
}

void ScriptedDynamicValue::DispatchMediaEventJson(std::string_view event_json) {
    if (m_program != nullptr) {
        m_program->DispatchMediaEventJson(event_json);
    }
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
