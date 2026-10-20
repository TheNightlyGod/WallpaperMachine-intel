#include "Runtime/ScriptedDynamicValue.hpp"

#include "Runtime/SceneRuntimeContext.hpp"
#include "Scripting/ScriptEngine.hpp"

namespace wallpaper
{

ScriptedDynamicValue::ScriptedDynamicValue(
    SceneRuntimeContext& runtime, std::string script_source, std::string current_layer_name,
    std::map<std::string, DynamicValueUniquePtr> script_properties, DynamicValue base_value,
    ScriptedValueSemantic semantic, PropertyScriptObject object)
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
                                                                      object);

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

void ScriptedDynamicValue::Start() {
    if (m_runtime->ProjectPropertiesChanging() || m_program == nullptr || ! m_program->Valid()) return;

    // What `init` returns is the property's value, as what `update` returns
    // is: a typing text starts empty, a helper layer hides itself. A value of
    // another kind than the property's (a flag for a position) is not one it
    // can take, and leaves it alone. A text script that returns nothing but
    // writes its own layer's text has decided the text, in `init` as in
    // `update`.
    SceneRuntimeContext::OwnTextWrite own_text_write(*m_runtime, *this);
    const auto initial = m_program->Start(m_runtime->hostContext(), *this);
    if (initial != nullptr && initial->getType() == getType()) {
        DynamicValue::update(*initial);
    } else if (own_text_write.Written().has_value()) {
        DynamicValue::update(*own_text_write.Written());
    } else {
        applyOwnWrite();
    }
}

void ScriptedDynamicValue::DeliverInitialUserProperties() {
    if (m_runtime->ProjectPropertiesChanging() || m_program == nullptr) return;
    m_program->DeliverInitialUserProperties();
    applyOwnWrite();
}

void ScriptedDynamicValue::reevaluate() {
    if (m_runtime->ProjectPropertiesChanging() || m_program == nullptr || ! m_program->Valid()) return;
    // A script the tick did not start (one a later script made, or one asked
    // for before the first tick) starts here, on its own.
    Start();
    DeliverInitialUserProperties();

    // update(value) continues from the previous result, including explicit property writes.
    SceneRuntimeContext::OwnTextWrite own_text_write(*m_runtime, *this);
    auto result = m_program->Evaluate(m_runtime->hostContext(), *this);
    if (! m_program->Capabilities().update || result == nullptr) {
        applyOwnWrite();
        return;
    }
    // The text script that writes its own layer's text and returns nothing has
    // decided the text: the current value would put the string it started with
    // back over the write.
    if (own_text_write.Written().has_value() && ! m_program->UpdateReturnedValue()) {
        DynamicValue::update(*own_text_write.Written());
    } else {
        DynamicValue::update(*result);
    }
    // So has one that writes its effect's `visible` and returns nothing; a
    // value it returns is the setting's whatever it wrote.
    if (m_program->UpdateReturnedValue()) {
        (void)m_program->TakeOwnVisibilityWrite();
    } else {
        applyOwnWrite();
    }
}

void ScriptedDynamicValue::ApplyProjectProperties(const ProjectProperties& project_properties,
                                                 const ProjectProperties& changed_properties) {
    if (m_program == nullptr) return;
    m_program->ApplyProjectProperties(project_properties, changed_properties);
    applyOwnWrite();
}

uint8_t ScriptedDynamicValue::CursorHandlerMask() const noexcept {
    return m_program != nullptr && m_program->Valid() ? m_program->Capabilities().cursor_handlers : 0;
}

void ScriptedDynamicValue::DispatchCursorClick(const ScriptHostContext& host_context) {
    if (m_program == nullptr) return;
    m_program->DispatchCursorClick(host_context);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchCursorDown(const ScriptHostContext& host_context) {
    if (m_program == nullptr) return;
    m_program->DispatchCursorDown(host_context);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchCursorEnter(const ScriptHostContext& host_context) {
    if (m_program == nullptr) return;
    m_program->DispatchCursorEnter(host_context);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchCursorLeave(const ScriptHostContext& host_context) {
    if (m_program == nullptr) return;
    m_program->DispatchCursorLeave(host_context);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchCursorMove(const ScriptHostContext& host_context) {
    if (m_program == nullptr) return;
    m_program->DispatchCursorMove(host_context);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchCursorUp(const ScriptHostContext& host_context) {
    if (m_program == nullptr) return;
    m_program->DispatchCursorUp(host_context);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchAnimationEvent(const ScriptHostContext& host_context,
                                                  std::string_view event_name, double frame) {
    if (m_program == nullptr) return;
    m_program->DispatchAnimationEvent(host_context, event_name, frame);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                                         const Eigen::Vector3f& text_color) {
    if (m_program == nullptr) return;
    m_program->DispatchMediaThumbnailChanged(primary_color, text_color);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchMediaEventJson(std::string_view event_json) {
    if (m_program == nullptr) return;
    m_program->DispatchMediaEventJson(event_json);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchResizeScreen(const ScriptHostContext& host_context) {
    if (m_program == nullptr) return;
    m_program->DispatchResizeScreen(host_context);
    applyOwnWrite();
}

void ScriptedDynamicValue::DispatchGeneralSettings(const ScriptHostContext& host_context) {
    if (m_program == nullptr) return;
    m_program->DispatchGeneralSettings(host_context);
    applyOwnWrite();
}

void ScriptedDynamicValue::applyOwnWrite() {
    if (const auto written = m_program->TakeOwnVisibilityWrite(); written.has_value()) {
        DynamicValue::update(*written);
    }
}

void ScriptedDynamicValue::Destroy() {
    if (m_program != nullptr) m_program->Destroy();
}

} // namespace wallpaper
