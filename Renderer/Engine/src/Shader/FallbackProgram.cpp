#include "Shader/FallbackProgram.hpp"

#include "Shader/RustShaderBridge.hpp"
#include "Utils/Logging.h"

#include <mutex>
#include <string>

namespace wallpaper::shader
{

namespace
{

SceneMetalSlotKind ToSceneMetalSlotKind(RustShaderMetalSlotKind kind) {
    switch (kind) {
    case RustShaderMetalSlotKind::Texture: return SceneMetalSlotKind::Texture;
    case RustShaderMetalSlotKind::Sampler: return SceneMetalSlotKind::Sampler;
    case RustShaderMetalSlotKind::Buffer: break;
    }
    return SceneMetalSlotKind::Buffer;
}

} // namespace

SceneMetalStage ToSceneMetalStage(const RustShaderMetalStage& stage) {
    SceneMetalStage out;
    out.kind = stage.kind == ShaderType::FRAGMENT ? SceneMetalStageKind::Fragment
                                                   : SceneMetalStageKind::Vertex;
    out.source           = stage.source;
    out.entry_point      = stage.entry_point;
    out.language_version = stage.language_version;
    out.bindings.reserve(stage.bindings.size());
    for (const auto& binding : stage.bindings) {
        out.bindings.push_back(SceneMetalBinding {
            .name      = binding.name,
            .set       = binding.set,
            .binding   = binding.binding,
            .slot_kind = ToSceneMetalSlotKind(binding.slot_kind),
            .slot      = binding.slot,
        });
    }
    return out;
}

std::shared_ptr<const SceneMetalProgram> FallbackMetalProgram() {
    static std::once_flag                            once;
    static std::shared_ptr<const SceneMetalProgram> program;
    std::call_once(once, [] {
        RustShaderRequest request;
        request.shader_name = "dx11fallback";
        request.stages      = { { ShaderType::VERTEX, std::string(kFallbackVertexSource) },
                                { ShaderType::FRAGMENT, std::string(kFallbackFragmentSource) } };
        RustShaderOutput output;
        if (! CompileRustShaderProgram(request, output) || output.reflection_json.empty()) {
            LOG_ERROR("the fallback shader could not be translated: %s", LastRustShaderError().c_str());
            return;
        }
        auto made             = std::make_shared<SceneMetalProgram>();
        made->reflection_json = std::move(output.reflection_json);
        for (const auto& stage : output.metal_stages) made->stages.push_back(ToSceneMetalStage(stage));
        program = std::move(made);
    });
    return program;
}

} // namespace wallpaper::shader
