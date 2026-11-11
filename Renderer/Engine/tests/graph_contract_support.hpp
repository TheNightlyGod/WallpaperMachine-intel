#pragma once

#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "WPSceneParser.hpp"
#include "SpecTexs.hpp"
#include "RenderCommon/ScenePass.hpp"
#include "RenderCommon/SceneRaster.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "TestRequire.hpp"
#include <array>
#include <bit>
#include <cstdint>
#include <limits>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace graph_contract
{
using namespace wallpaper;
using wallpaper::rg::ClearPass;
using wallpaper::rg::CopyPass;
using wallpaper::rg::DrawPass;
using wallpaper::rg::NodeID;

// Owned, host-endian-independent model primitives. No skeleton policy lives here.
class Bytes {
public:
    std::vector<uint8_t> data;
    void                 u8(uint8_t n) { data.push_back(n); }
    void                 u16(uint16_t n) {
        u8(n & 255);
        u8((n >> 8) & 255);
    }
    void u32(uint32_t n) {
        for (unsigned i = 0; i != 4; ++i) u8((n >> (8 * i)) & 255);
    }
    void i32(int32_t n) { u32(std::bit_cast<uint32_t>(n)); }
    void f32(float n) { u32(std::bit_cast<uint32_t>(n)); }
    void text(std::string_view s) {
        data.insert(data.end(), s.begin(), s.end());
        u8(0);
    }
    void stamp(std::string_view family, unsigned version) {
        REQUIRE(family.size() == 4);
        REQUIRE(version <= 9999);
        for (char c : family) {
            REQUIRE(c >= 'A' && c <= 'Z');
            u8(static_cast<uint8_t>(c));
        }
        for (unsigned divisor : { 1000u, 100u, 10u, 1u }) u8('0' + (version / divisor) % 10);
        u8(0);
    }
    void matrix(const std::array<float, 16>& column_major) {
        for (float x : column_major) f32(x);
    }
    void append(const Bytes& other) {
        data.insert(data.end(), other.data.begin(), other.data.end());
    }
    void sized(const Bytes& other) {
        REQUIRE(other.data.size() <= UINT32_MAX);
        u32(static_cast<uint32_t>(other.data.size()));
        append(other);
    }
    void patchU32(std::size_t at, uint32_t n) {
        REQUIRE(at <= data.size());
        REQUIRE(data.size() - at >= 4);
        for (unsigned i = 0; i != 4; ++i) data[at + i] = (n >> (8 * i)) & 255;
    }
};
struct SkinVertex {
    std::array<float, 3>    position;
    std::array<uint32_t, 4> bones { 0, 0, 0, 0 };
    std::array<float, 4>    weights { 1, 0, 0, 0 };
    std::array<float, 2>    uv;
};
struct Part {
    uint32_t id, unknown, start, count;
};
struct Mask {
    uint32_t              opaque0 = 17, opaque1 = 29, opaque2 = 41;
    std::string           texture;
    std::vector<uint32_t> clipped, producers;
};
inline constexpr uint32_t      skinFlags = 0x1u | 0x8u | 0x00800000u | 0x01000000u;
inline std::vector<SkinVertex> triangle() {
    return { { { -2, -1, 0 }, { 0, 0, 0, 0 }, { 1, 0, 0, 0 }, { 0, 0 } },
             { { 3, -1, 0 }, { 0, 0, 0, 0 }, { 1, 0, 0, 0 }, { 1, 0 } },
             { { 0, 2, 0 }, { 0, 0, 0, 0 }, { 1, 0, 0, 0 }, { 0.4f, 1 } } };
}
inline void modelHeader(Bytes& out, unsigned version, uint32_t meshes = 1) {
    REQUIRE(version == 21 || version == 23);
    REQUIRE(meshes > 0 && meshes <= 64);
    out.stamp("MDLV", version);
    out.u32(skinFlags);
    out.i32(1);
    out.u32(meshes);
}
// Writes one complete mesh, not an entire file: retained callers append their own MDLS/MDLA.
inline void skinMesh(Bytes& out, unsigned version, std::string_view material,
                     const std::vector<SkinVertex>& vertices, std::span<const uint32_t> indices,
                     std::span<const Part> parts = {}, std::span<const Mask> masks = {}) {
    REQUIRE(version == 21 || version == 23);
    REQUIRE(! vertices.empty());
    REQUIRE(indices.size() % 3 == 0);
    REQUIRE(version == 23 || masks.empty());
    out.text(material);
    out.u32(0);
    auto lo = vertices.front().position, hi = lo;
    for (const auto& v : vertices)
        for (std::size_t j = 0; j != 3; ++j) {
            if (v.position[j] < lo[j]) lo[j] = v.position[j];
            if (v.position[j] > hi[j]) hi[j] = v.position[j];
        }
    for (float n : lo) out.f32(n);
    for (float n : hi) out.f32(n);
    out.u32(skinFlags);
    Bytes vertexBytes;
    for (const auto& v : vertices) {
        for (float n : v.position) vertexBytes.f32(n);
        for (auto n : v.bones) vertexBytes.u32(n);
        for (float n : v.weights) vertexBytes.f32(n);
        for (float n : v.uv) vertexBytes.f32(n);
    }
    out.sized(vertexBytes);
    Bytes indexBytes;
    for (auto n : indices) {
        REQUIRE(n < vertices.size());
        if (vertices.size() <= 65535)
            indexBytes.u16(static_cast<uint16_t>(n));
        else
            indexBytes.u32(n);
    }
    out.sized(indexBytes);
    out.u8(0);
    out.u8(parts.empty() ? 0 : 1);
    if (! parts.empty()) {
        Bytes records;
        for (const auto& p : parts) {
            REQUIRE(p.start <= indices.size());
            REQUIRE(p.count <= indices.size() - p.start);
            records.u32(p.id);
            records.u32(p.unknown);
            records.u32(p.start);
            records.u32(p.count);
        }
        out.sized(records);
    }
    if (version == 23) {
        out.u32(static_cast<uint32_t>(masks.size()));
        for (const auto& m : masks) {
            out.u32(m.opaque0);
            out.u32(m.opaque1);
            out.text(m.texture);
            out.u32(m.opaque2);
            for (const auto* group : { &m.clipped, &m.producers }) {
                out.u32(static_cast<uint32_t>(group->size()));
                for (auto p : *group) {
                    REQUIRE(p < parts.size());
                    out.u32(p);
                }
            }
        }
    }
}
inline std::vector<uint8_t> maskedModel(std::string_view material, std::string maskTexture) {
    Bytes out;
    modelHeader(out, 23);
    const std::array<uint32_t, 3> indices { 0, 1, 2 };
    const std::array<Part, 1>     parts { { { 73, 0, 0, 3 } } };
    const std::array<Mask, 1> masks { { { 17, 29, 41, std::move(maskTexture), { 0 }, { 0 } } } };
    skinMesh(out, 23, material, triangle(), indices, parts, masks);
    out.u8(0);
    return std::move(out.data);
}

using AssetMap = std::unordered_map<std::string, std::vector<uint8_t>>;
class MemoryAssets final : public fs::Fs {
    AssetMap files_;

public:
    explicit MemoryAssets(AssetMap files): files_(std::move(files)) {}
    bool Contains(std::string_view path) const override {
        return files_.find(std::string(path)) != files_.end();
    }
    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        auto found = files_.find(std::string(path));
        if (found == files_.end()) return nullptr;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(found->second));
    }
    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }
};
inline void asset(AssetMap& map, std::string path, std::string_view text) {
    map[std::move(path)] = std::vector<uint8_t>(text.begin(), text.end());
}
inline std::string quote(std::string_view text) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string           out   = "\"";
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') {
            out += '\\';
            out += static_cast<char>(c);
        } else if (c < 32) {
            out += "\\u00";
            out += hex[c >> 4];
            out += hex[c & 15];
        } else
            out += static_cast<char>(c);
    }
    return out + '"';
}
inline std::string sceneJson(std::string_view objects, std::string_view generalExtra = {}) {
    std::string result =
        R"({"camera":{"center":[0,0,0],"eye":[0,0,8],"up":[0,1,0]},"general":{"orthogonalprojection":{"width":640,"height":360},"cameraparallax":false)";
    if (! generalExtra.empty()) {
        result += ',';
        result += generalExtra;
    }
    result += "},\"objects\":[";
    result += objects;
    return result + "]}";
}
// Extra fields are JSON members, allowing preserved blend/property fixtures to extend an image.
inline std::string imageJson(int id, std::string_view name, std::string_view model,
                             std::string_view extra = {}) {
    std::string out = "{\"id\":" + std::to_string(id) + ",\"name\":" + quote(name) +
                      ",\"image\":" + quote(model) +
                      R"(,"origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0])";
    if (! extra.empty()) {
        out += ',';
        out += extra;
    }
    return out + '}';
}
inline void materialAsset(AssetMap& files, std::string_view path, std::string_view shader,
                          std::string_view textures = "[\"contract_picture\"]",
                          std::string_view blend    = "translucent") {
    asset(files,
          "/" + std::string(path),
          "{\"passes\":[{\"shader\":" + quote(shader) + ",\"textures\":" + std::string(textures) +
              ",\"blending\":" + quote(blend) +
              R"(,"cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled"}]})");
}
inline void shaderAsset(AssetMap& files, std::string_view name, bool clipping = false,
                        bool mask = false, bool skinning = false) {
    std::string vertex =
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_ContractUV;\n";
    if (skinning)
        vertex += "#if SKINNING\nattribute uvec4 a_BlendIndices;\nattribute vec4 "
                  "a_BlendWeights;\nuniform mat4x3 g_Bones[BONECOUNT];\n#endif\n";
    vertex += "void main(){ vec3 p=a_Position;\n";
    if (skinning)
        vertex +=
            "#if SKINNING\np=mul(vec4(p,1.0),g_Bones[a_BlendIndices.x])*a_BlendWeights.x+"
            "mul(vec4(p,1.0),g_Bones[a_BlendIndices.y])*a_BlendWeights.y+"
            "mul(vec4(p,1.0),g_Bones[a_BlendIndices.z])*a_BlendWeights.z+"
            "mul(vec4(p,1.0),g_Bones[a_BlendIndices.w])*a_BlendWeights.w;\n#endif\n";
    vertex += "v_ContractUV=a_TexCoord; gl_Position=vec4(p,1.0); }\n";
    std::string fragment = "uniform sampler2D g_Texture0;\nvarying vec2 v_ContractUV;\n";
    if (clipping) fragment += "#if CLIPPINGTARGET\nuniform sampler2D g_Texture8;\n#endif\n";
    if (mask) fragment += "uniform sampler2D g_Texture1;\n";
    fragment += "void main(){ vec4 c=texSample2D(g_Texture0,v_ContractUV);\n";
    if (clipping)
        fragment += "#if CLIPPINGTARGET\nc*=texSample2D(g_Texture8,v_ContractUV).a;\n#endif\n";
    if (mask) fragment += "c*=texSample2D(g_Texture1,v_ContractUV).a;\n";
    fragment += "gl_FragColor=c; }\n";
    asset(files, "/shaders/" + std::string(name) + ".vert", vertex);
    asset(files, "/shaders/" + std::string(name) + ".frag", fragment);
}
inline AssetMap ordinaryAssets() {
    AssetMap files;
    asset(
        files, "/models/card.json", R"({"width":64,"height":40,"material":"materials/card.json"})");
    materialAsset(files, "materials/card.json", "contract_card");
    shaderAsset(files, "contract_card");
    files["/materials/contract_picture.tex"] = {};
    return files;
}
class ParseFixture {
public:
    fs::VFS             vfs;
    audio::SoundManager sound { audio::SoundManager::OutputBackend::Null };
    WPSceneParser       parser;
    explicit ParseFixture(AssetMap files) {
        REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryAssets>(std::move(files))));
    }
    std::shared_ptr<Scene> parse(const std::string& json) {
        auto result = parser.Parse("independent-graph-contract", json, vfs, sound);
        REQUIRE(result);
        return result;
    }
    std::shared_ptr<Scene> parse(const SceneParseRequest& request, const std::string& json) {
        auto result = parser.Parse(request, json, vfs, sound);
        REQUIRE(result);
        return result;
    }
};

inline void target(Scene& scene, std::string key, i32 width = 80, i32 height = 48,
                   bool reuse = true, bool force = false, uint32_t samples = 1) {
    SceneRenderTarget record {};
    record.width                        = width;
    record.height                       = height;
    record.allowReuse                   = reuse;
    record.forceClear                   = force;
    record.sample_count                 = samples;
    scene.renderTargets[std::move(key)] = record;
}
inline void defaults(Scene& scene) {
    target(scene, std::string(SpecTex_Default), 640, 360, false);
    scene.activeCamera = nullptr;
}
inline SceneMaterial material(std::string name, std::vector<std::string> textures = {}) {
    SceneMaterial result;
    result.name     = std::move(name);
    result.textures = std::move(textures);
    result.blenmode = BlendMode::Translucent;
    return result;
}
inline std::shared_ptr<SceneNode> node(std::string name, std::vector<std::string> textures = {}) {
    auto result = std::make_shared<SceneNode>();
    result->SetName(name);
    auto mesh = std::make_shared<SceneMesh>();
    mesh->AddMaterial(material(std::move(name), std::move(textures)));
    result->AddMesh(std::move(mesh));
    return result;
}
// A base destination is a real camera's first effect-layer input, even with no effects.
// Keep authored aliases in FirstTarget so production routing performs their resolution.
inline void baseOutput(Scene& scene, const std::shared_ptr<SceneNode>& owner, std::string output) {
    REQUIRE(owner);
    auto* destination = scene.FindRenderTarget(output);
    REQUIRE(destination);
    const auto  width = destination->width, height = destination->height;
    std::size_t serial = scene.cameras.size();
    std::string cameraName;
    do {
        cameraName = "contract_base_destination_" + std::to_string(serial++);
    } while (scene.cameras.find(cameraName) != scene.cameras.end());
    std::string spare = cameraName + "_spare";
    while (scene.FindRenderTarget(spare)) spare += '_';
    target(scene, spare, width, height);
    auto layer = std::make_shared<SceneImageEffectLayer>(
        owner.get(), static_cast<float>(width), static_cast<float>(height), output, spare);
    auto camera = std::make_shared<SceneCamera>(width, height, -1, 1);
    camera->AttatchNode(owner);
    camera->AttatchImgEffect(layer);
    scene.cameras[cameraName] = camera;
    owner->SetCamera(cameraName);
}
inline std::shared_ptr<SceneNode> append(Scene& scene, std::string name,
                                         std::vector<std::string> textures = {},
                                         std::string              output   = {}) {
    auto result = node(std::move(name), std::move(textures));
    if (! output.empty()) baseOutput(scene, result, std::move(output));
    scene.sceneGraph->AppendChild(result);
    return result;
}
inline void submesh(SceneMesh& mesh, uint32_t slot, std::string output = {},
                    std::span<const SceneMesh::DrawRange> ranges = {}) {
    SceneMesh::Submesh part {};
    part.material_slot   = slot;
    part.output_override = std::move(output);
    part.SetDrawRanges(ranges);
    mesh.Submeshes().push_back(std::move(part));
}
inline std::shared_ptr<SceneImageEffectLayer>
effectLayer(Scene& scene, const std::shared_ptr<SceneNode>& owner, bool compose = false) {
    const std::string cameraName = "contract_effect_camera";
    const std::string a          = std::string(WE_EFFECT_PPONG_PREFIX_A) + "contract";
    const std::string b          = std::string(WE_EFFECT_PPONG_PREFIX) + "contract_b";
    target(scene, a);
    target(scene, b);
    auto layer  = std::make_shared<SceneImageEffectLayer>(owner.get(), 80, 48, a, b);
    auto camera = std::make_shared<SceneCamera>(80, 48, -1, 1);
    camera->AttatchNode(owner);
    camera->AttatchImgEffect(layer);
    camera->SetComposeLayer(compose);
    scene.cameras[cameraName] = camera;
    owner->SetCamera(cameraName);
    if (compose) scene.activeCamera = camera.get();
    return layer;
}
inline std::shared_ptr<SceneImageEffect>
oneEffect(const std::shared_ptr<SceneNode>& draw,
          std::string                       output = std::string(SpecTex_Default)) {
    auto                 effect = std::make_shared<SceneImageEffect>();
    SceneImageEffectNode item {};
    item.sceneNode = draw;
    item.output    = std::move(output);
    effect->nodes.push_back(std::move(item));
    return effect;
}
struct Step {
    NodeID id;
    std::string_view
        name; // Borrowed from the graph node; valid only while Observation::graph lives.
    rg::PassNode::Type type;
    const DrawPass*    draw;
    const CopyPass*    copy;
};
class Observation {
public:
    std::unique_ptr<rg::RenderGraph> graph;
    std::vector<NodeID>              order;
    std::vector<Step>                steps;
    explicit Observation(Scene& scene): graph(sceneToRenderGraph(scene)) {
        REQUIRE(graph);
        order = graph->topologicalOrder();
        for (auto id : order) {
            auto* passNode = graph->getPassNode(id);
            auto* payload  = graph->getPass(id);
            REQUIRE(passNode);
            REQUIRE(payload);
            steps.push_back({ id,
                              passNode->name(),
                              passNode->type(),
                              dynamic_cast<const DrawPass*>(payload),
                              dynamic_cast<const CopyPass*>(payload) });
        }
    }
    std::size_t drawIndex(std::string_view materialName) const {
        for (std::size_t i = 0; i != steps.size(); ++i)
            if (steps[i].draw && steps[i].name == materialName) return i;
        REQUIRE(false);
        return 0;
    }
    std::size_t nodeIndex(std::string_view nodeName) const {
        for (std::size_t i = 0; i != steps.size(); ++i)
            if (steps[i].draw) {
                REQUIRE(steps[i].draw->desc().node);
                if (steps[i].draw->desc().node->Name() == nodeName) return i;
            }
        REQUIRE(false);
        return 0;
    }
    const DrawPass::Desc& draw(std::string_view name) const {
        return steps[drawIndex(name)].draw->desc();
    }
    const DrawPass::Desc& nodeDraw(std::string_view name) const {
        return steps[nodeIndex(name)].draw->desc();
    }
    const CopyPass* copy(std::string_view src, std::string_view dst) const {
        for (const auto& s : steps)
            if (s.copy && s.copy->desc().src == src && s.copy->desc().dst == dst) return s.copy;
        return nullptr;
    }
    std::size_t copyIndex(std::string_view src, std::string_view dst) const {
        for (std::size_t i = 0; i != steps.size(); ++i)
            if (steps[i].copy && steps[i].copy->desc().src == src &&
                steps[i].copy->desc().dst == dst)
                return i;
        REQUIRE(false);
        return 0;
    }
    bool hasDraw(std::string_view name) const {
        for (const auto& s : steps)
            if (s.draw && s.name == name) return true;
        return false;
    }
    std::vector<const DrawPass::Desc*> nodeDraws(std::string_view name) const {
        std::vector<const DrawPass::Desc*> found;
        for (const auto& s : steps)
            if (s.draw) {
                REQUIRE(s.draw->desc().node);
                if (s.draw->desc().node->Name() == name) found.push_back(&s.draw->desc());
            }
        return found;
    }
};
inline std::shared_ptr<ScenePostProcess> post(Scene& scene) {
    auto result  = std::make_shared<ScenePostProcess>();
    result->name = "contract_post";
    scene.post_processes.push_back(result);
    return result;
}
inline void requirePolicy(const DrawPass::Desc& d, bool clear, bool preserve,
                          uint32_t samples = 1) {
    REQUIRE(d.clear_on_first_use == clear);
    REQUIRE(d.preserve_target_contents == preserve);
    REQUIRE(d.samples == samples);
}
} // namespace graph_contract
