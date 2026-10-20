#pragma once

#include "Runtime/DynamicValue.hpp"
#include "Runtime/PropertyScriptObject.hpp"
#include "Project/ProjectProperties.hpp"

#include <map>
#include <memory>
#include <string>
#include <string_view>

namespace wallpaper
{

class SceneRuntimeContext;
class PropertyScriptProgram;
struct ScriptHostContext;

enum class ScriptedValueSemantic
{
    Generic,
    AnglesDegrees,
};

class ScriptedDynamicValue final : public DynamicValue {
public:
    ScriptedDynamicValue(SceneRuntimeContext& runtime, std::string script_source,
                         std::string                                  current_layer_name,
                         std::map<std::string, DynamicValueUniquePtr> script_properties,
                         DynamicValue                                 base_value,
                         ScriptedValueSemantic semantic = ScriptedValueSemantic::Generic,
                         PropertyScriptObject object = {});
    ~ScriptedDynamicValue() override;

    const std::string& LayerName() const { return m_current_layer_name; }
    uint8_t CursorHandlerMask() const noexcept;

    /// Runs the script's `init` if it has not run. The runtime starts every
    /// script it holds, then delivers their first user properties, before the
    /// first `reevaluate` of any of them.
    void Start();
    void DeliverInitialUserProperties();
    void reevaluate();
    void ApplyProjectProperties(const ProjectProperties& project_properties,
                                const ProjectProperties& changed_properties);
    void DispatchCursorClick(const ScriptHostContext& host_context);
    void DispatchCursorDown(const ScriptHostContext& host_context);
    void DispatchCursorEnter(const ScriptHostContext& host_context);
    void DispatchCursorLeave(const ScriptHostContext& host_context);
    void DispatchCursorMove(const ScriptHostContext& host_context);
    void DispatchCursorUp(const ScriptHostContext& host_context);
    void DispatchAnimationEvent(const ScriptHostContext& host_context,
                                std::string_view event_name, double frame);
    void DispatchMediaThumbnailChanged(const Eigen::Vector3f& primary_color,
                                       const Eigen::Vector3f& text_color);
    void DispatchMediaEventJson(std::string_view event_json);
    void DispatchResizeScreen(const ScriptHostContext& host_context);
    void DispatchGeneralSettings(const ScriptHostContext& host_context);
    /// Runs the script's `destroy()` if it started. Called while the runtime the
    /// script reaches is alive; the destructor does not, since by then it is not.
    void Destroy();

private:
    /// Takes what the script wrote to its effect's `visible` as this value
    /// (`PropertyScriptObject::effect_visibility`), after anything that ran it.
    void applyOwnWrite();

    SceneRuntimeContext*                         m_runtime = nullptr;
    std::weak_ptr<void>                          m_registry;
    std::string                                  m_current_layer_name;
    std::map<std::string, DynamicValueUniquePtr> m_script_properties;
    std::unique_ptr<PropertyScriptProgram>       m_program;
    ScriptedValueSemantic                        m_semantic { ScriptedValueSemantic::Generic };
};

} // namespace wallpaper
