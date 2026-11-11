#pragma once

#include "Scene/SceneShader.h"
#include <array>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <utility>
#include <vector>

namespace wallpaper {
struct WPMdl;
struct Image;
class RuntimeImageSource;

// Only the small draw/lookup description survives the MDL upload. Raw deltas stay in
// WPMdl until the immutable texture is built; animation instances never copy them.
struct PuppetMorphShapeInfo {
    std::string name;
    uint32_t bone { 0 };
    uint32_t modifier_flags { 0 };
    std::array<float, 2> range { -1.0f, 0.0f };
};
struct PuppetMorphMeshInfo {
    float scale { 0.0f };
    uint32_t vertices { 0 };
    bool modifiers { false };
    std::vector<PuppetMorphShapeInfo> shapes;
};

// The updater consumes these owning values directly. Small arrays are inline;
// modifier arrays allocate once when the instance is prepared, never per draw.
struct PuppetMorphUniforms {
    ShaderValue offsets { std::array<float, 12> {} };
    ShaderValue weights { std::array<float, 12> {} };
    ShaderValue transforms;
    ShaderValue rules;
};
struct PuppetMorphState {
    struct Mesh {
        std::vector<float> weights;
        std::vector<uint8_t> active;
        // A script override lasts through same-time recomposition, until the clock moves.
        std::vector<std::pair<uint32_t, float>> writes;
        PuppetMorphUniforms uniforms;
        bool dirty { true };
    };
    std::vector<Mesh> meshes;
};

void PreparePuppetMorphMetadata(WPMdl& mdl);
void RegisterPuppetMorphImages(WPMdl& mdl, RuntimeImageSource& images,
                               const std::string& model_name, bool image_puppet);
std::shared_ptr<Image> BuildPuppetMorphImage(const WPMdl& mdl, std::size_t mesh,
                                           bool image_puppet, const std::string& name);
} // namespace wallpaper
