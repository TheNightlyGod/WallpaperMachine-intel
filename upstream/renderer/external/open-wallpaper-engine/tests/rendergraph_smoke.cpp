#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "WPSceneParser.hpp"
#include "SpecTexs.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/PassCommon.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"

#include <algorithm>
#include <gtest/gtest.h>
#include "TestRequire.hpp"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <map>
#include <span>
#include <string>
#include <vector>
#include <array>

#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"

namespace
{
using wallpaper::Scene;
using wallpaper::SceneCamera;
using wallpaper::SceneImageEffect;
using wallpaper::SceneImageEffectLayer;
using wallpaper::SceneImageEffectNode;
using wallpaper::SceneMaterial;
using wallpaper::SceneMesh;
using wallpaper::SceneNode;
using wallpaper::SceneRenderTarget;
using wallpaper::SpecTex_Default;
using wallpaper::vulkan::CopyPass;
using wallpaper::vulkan::CustomShaderPass;

class MemoryFs final : public wallpaper::fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::string> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<wallpaper::fs::IBinaryStream> Open(std::string_view path) override {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        const auto& s = it->second;
        return std::make_shared<wallpaper::fs::MemBinaryStream>(
            std::vector<uint8_t>(s.begin(), s.end()));
    }

    std::shared_ptr<wallpaper::fs::IBinaryStreamW> OpenW(std::string_view) override {
        return nullptr;
    }

private:
    std::map<std::string, std::string> m_files;
};

class Bytes {
public:
    void Stamp(std::string_view prefix, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "%.4s%.4d", prefix.data(), version);
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(stamp), sizeof(stamp)));
    }
    void Str(std::string_view value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(value.data()), value.size()));
        U8(0);
    }
    void U8(uint8_t value) { RawValue(value); }
    void U16(uint16_t value) { RawValue(value); }
    void U32(uint32_t value) { RawValue(value); }
    void F32(float value) { RawValue(value); }
    void Raw(std::span<const uint8_t> bytes) {
        m_bytes.insert(m_bytes.end(), bytes.begin(), bytes.end());
    }
    std::string TakeString() {
        return std::string(reinterpret_cast<const char*>(m_bytes.data()), m_bytes.size());
    }

private:
    template<typename T>
    void RawValue(const T& value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(&value), sizeof(value)));
    }

    std::vector<uint8_t> m_bytes;
};

constexpr uint32_t kSkinUvFlag = 0x00800000u | 0x01000000u | 0x00000008u;

void WritePuppetVertex(Bytes& b, float x, float y, float u) {
    b.F32(x);
    b.F32(y);
    b.F32(0.0f);
    b.U32(0);
    b.U32(0);
    b.U32(0);
    b.U32(0);
    b.F32(1.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(u);
    b.F32(0.5f);
}

void WritePuppetMesh(Bytes& b, std::string_view material, uint32_t part_id) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUvFlag);
    b.U32(3u * 52u);
    WritePuppetVertex(b, 0.0f, 0.0f, 0.0f);
    WritePuppetVertex(b, 1.0f, 0.0f, 0.5f);
    WritePuppetVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(36);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(0.25f * static_cast<float>(i));
        b.F32(0.5f);
        b.U32(0);
    }
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(0);
    b.U32(3);
}

std::string BuildMaskedPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 23);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WritePuppetMesh(b, "mat/head.json", 10);
    b.U32(1);
    b.U32(7);
    b.U32(0);
    b.Str("masks/iris_mask");
    b.U32(0);
    b.U32(1);
    b.U32(0);
    b.U32(1);
    b.U32(0);
    return b.TakeString();
}

// One triangle skinned to a single root bone, with no animations.
std::string BuildBonedPuppetMdlFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WritePuppetMesh(b, "mat/head.json", 10);
    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.U32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) b.F32(row == col ? 1.0f : 0.0f);
    }
    b.Str("{}");
    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.TakeString();
}

std::string PuppetMaterialJson(std::string_view                        shader,
                               std::initializer_list<std::string_view> textures) {
    std::string texture_json;
    for (const auto texture : textures) {
        if (! texture_json.empty()) texture_json += ",";
        texture_json += "\"" + std::string(texture) + "\"";
    }
    return std::string(R"({"passes":[{"blending":"translucent","cullmode":"nocull",)"
                       R"("depthtest":"disabled","depthwrite":"disabled","shader":")") +
           std::string(shader) + R"(","textures":[)" + texture_json + R"(]}]})";
}

// `extra_fields` are further members of the image object, each followed by a comma.
std::string BasicSceneJson(std::string_view image, std::string_view extra_fields = {}) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":300,"name":"masked puppet image","image":")") +
           std::string(image) + R"(",)" + std::string(extra_fields) +
           R"("origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";
}

struct GraphPassView {
    std::string             name;
    const CustomShaderPass* custom {};
    const CopyPass*         copy {};
};

std::shared_ptr<SceneMesh> makeMesh(std::string name, std::vector<std::string> textures = {}) {
    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial material {};
    material.name     = std::move(name);
    material.textures = std::move(textures);
    mesh->AddMaterial(std::move(material));
    return mesh;
}

std::shared_ptr<SceneNode> makeNode(
    std::string name,
    std::vector<std::string> textures = {}) {
    auto node = std::make_shared<SceneNode>();
    node->SetName(name);
    node->AddMesh(makeMesh(std::move(name), std::move(textures)));
    return node;
}

std::vector<GraphPassView> graphPasses(const wallpaper::rg::RenderGraph& graph) {
    std::vector<GraphPassView> passes;
    for (const auto id : graph.topologicalOrder()) {
        auto* pass_node = graph.getPassNode(id);
        REQUIRE(pass_node != nullptr);
        auto* pass = graph.getPass(id);
        REQUIRE(pass != nullptr);
        passes.push_back(GraphPassView {
            .name   = std::string(pass_node->name()),
            .custom = dynamic_cast<const CustomShaderPass*>(pass),
            .copy   = dynamic_cast<const CopyPass*>(pass),
        });
    }
    return passes;
}

const CustomShaderPass* findCustomPass(
    const std::vector<GraphPassView>& passes,
    const std::string& name) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&name](const auto& pass) {
        return pass.custom != nullptr && pass.name == name;
    });
    REQUIRE(it != passes.end());
    return it->custom;
}

const CustomShaderPass* findCustomPassByNodeName(
    const std::vector<GraphPassView>& passes,
    const std::string& name) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&name](const auto& pass) {
        return pass.custom != nullptr && pass.custom->desc().node != nullptr &&
            pass.custom->desc().node->Name() == name;
    });
    REQUIRE(it != passes.end());
    return it->custom;
}

const GraphPassView* findCustomPassViewByNodeName(
    const std::vector<GraphPassView>& passes,
    const std::string& name) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&name](const auto& pass) {
        return pass.custom != nullptr && pass.custom->desc().node != nullptr &&
            pass.custom->desc().node->Name() == name;
    });
    REQUIRE(it != passes.end());
    return &(*it);
}

size_t findPassIndex(const std::vector<GraphPassView>& passes, const std::string& name) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&name](const auto& pass) {
        return pass.name == name;
    });
    REQUIRE(it != passes.end());
    return static_cast<size_t>(std::distance(passes.begin(), it));
}

const GraphPassView* findCopyPass(
    const std::vector<GraphPassView>& passes,
    const std::string& src,
    const std::string& dst) {
    const auto it = std::find_if(passes.begin(), passes.end(), [&src, &dst](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().src == src &&
            pass.copy->desc().dst == dst;
    });
    if (it == passes.end()) return nullptr;
    return &(*it);
}

void installDefaultTargets(Scene& scene, bool default_reuse = true) {
    scene.activeCamera = nullptr;
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width      = 1920,
        .height     = 1080,
        .allowReuse = default_reuse,
    };
    scene.cameras["effect"] = std::make_shared<SceneCamera>(1920, 1080, 0.01f, 100.0f);
}

TEST(RenderGraph, ConsecutiveAndTerminalEffectCopiesKeepTheirDependencies) {
    Scene scene;
    installDefaultTargets(scene);
    const std::string input = std::string(wallpaper::WE_EFFECT_PPONG_PREFIX_A) + "copies";
    for (const auto& key : { input, std::string("_rt_ping_b"), std::string("_rt_copy_a"),
                            std::string("_rt_copy_b"), std::string("_rt_copy_c") }) {
        scene.renderTargets[key] = { .width = 16, .height = 16, .allowReuse = true };
    }
    auto owner = makeNode("effect owner");
    owner->SetSkipRenderPass(true);
    owner->SetCamera("local");
    auto camera = std::make_shared<SceneCamera>(16, 16, -1, 1);
    auto layer = std::make_shared<SceneImageEffectLayer>(owner.get(), 16, 16, input, "_rt_ping_b");
    layer->SetFinalBlend(wallpaper::BlendMode::Translucent);
    auto effect = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back({ std::string(SpecTex_Default), makeNode("effect draw", {"_rt_copy_b"}) });
    effect->commands.push_back({ .dst = "_rt_copy_a", .src = input, .afterpos = 0 });
    effect->commands.push_back({ .dst = "_rt_copy_c", .src = std::string(SpecTex_Default), .afterpos = 1 });
    effect->commands.push_back({ .dst = "_rt_copy_b", .src = "_rt_copy_a", .afterpos = 0 });
    layer->AddEffect(effect);
    camera->AttatchImgEffect(layer);
    scene.cameras["local"] = camera;
    scene.sceneGraph->AppendChild(owner);

    const auto graph = wallpaper::sceneToRenderGraph(scene);
    ASSERT_NE(graph, nullptr);
    const auto passes = graphPasses(*graph);
    std::map<std::string, size_t> copies;
    for (size_t index = 0; index < passes.size(); ++index) {
        if (passes[index].copy != nullptr) copies[passes[index].copy->desc().dst] = index;
    }
    ASSERT_EQ(copies.size(), 3u);
    EXPECT_LT(copies.at("_rt_copy_a"), copies.at("_rt_copy_b"));
    EXPECT_LT(copies.at("_rt_copy_b"), findPassIndex(passes, "effect draw"));
    EXPECT_LT(findPassIndex(passes, "effect draw"), copies.at("_rt_copy_c"));
}

TEST(RenderGraph, renderTargetAliasesResolveForOutputAndSampledSpecTextures) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_resolved"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargetAliases["_alias_target"] = "_rt_resolved";

    auto sampled = makeNode("sampled_writer");
    scene.sceneGraph->AppendChild(sampled);

    auto sampler = makeNode("alias_sampler", { "_alias_target" });
    scene.sceneGraph->AppendChild(sampler);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        sampled.get(),
        64.0f,
        64.0f,
        "_alias_target",
        "_rt_pingpong_b"));
    sampled->SetCamera("alias_camera");
    scene.cameras["alias_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* output_pass = findCustomPass(passes, "sampled_writer");
    REQUIRE(output_pass->desc().output == "_rt_resolved");

    const auto* sampled_pass = findCustomPass(passes, "alias_sampler");
    REQUIRE(sampled_pass->desc().textures.size() == 1);
    REQUIRE(sampled_pass->desc().textures[0] == "_rt_resolved");
}

TEST(RenderGraph, runtimeTextTextureNamesStayImported) {
    Scene scene;
    installDefaultTargets(scene);
    scene.textures["runtime/text/Clock"].url = "runtime/text/Clock";

    auto text = makeNode("text", { "runtime/text/Clock" });
    scene.sceneGraph->AppendChild(text);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* text_pass = findCustomPass(passes, "text");
    REQUIRE(text_pass->desc().textures.size() == 1);
    REQUIRE(text_pass->desc().textures[0] == "runtime/text/Clock");

    const auto order = graph->topologicalOrder();
    const auto reads = graph->getLastReadTexs({ order });
    bool found_imported_text_texture = false;
    for (const auto& pass_reads : reads) {
        for (const auto* texture : pass_reads) {
            if (texture != nullptr && texture->key() == "runtime/text/Clock") {
                found_imported_text_texture =
                    texture->type() == wallpaper::rg::TexNode::TexType::Imported;
            }
        }
    }
    REQUIRE(found_imported_text_texture);
}

TEST(RenderGraph, submeshMaterialSlotsEmitDistinctCustomPasses) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_submesh_slots"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto node = std::make_shared<SceneNode>();
    node->SetName("multi_slot_mesh");

    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial body {};
    body.name = "body";
    SceneMaterial eyes {};
    eyes.name = "eyes";
    mesh->AddMaterial(std::move(body));
    mesh->AddMaterial(std::move(eyes));

    mesh->Submeshes().emplace_back();
    mesh->Submeshes().emplace_back();
    mesh->Submeshes()[0].material_slot = 0;
    mesh->Submeshes()[1].material_slot = 1;

    node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(node);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        node.get(),
        64.0f,
        64.0f,
        "_rt_submesh_slots",
        "_rt_unused"));
    node->SetCamera("submesh_slots_camera");
    scene.cameras["submesh_slots_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* body_pass = findCustomPass(passes, "body");
    const auto* eyes_pass = findCustomPass(passes, "eyes");

    REQUIRE(body_pass->desc().output == "_rt_submesh_slots");
    REQUIRE(eyes_pass->desc().output == "_rt_submesh_slots");
    REQUIRE(body_pass->desc().submesh_index == 0);
    REQUIRE(body_pass->desc().material_slot == 0);
    REQUIRE(eyes_pass->desc().submesh_index == 1);
    REQUIRE(eyes_pass->desc().material_slot == 1);
    REQUIRE(body_pass->desc().clear_on_first_use);
    REQUIRE(!body_pass->desc().preserve_target_contents);
    REQUIRE(!eyes_pass->desc().clear_on_first_use);
    REQUIRE(eyes_pass->desc().preserve_target_contents);
}

TEST(RenderGraph, submeshMaterialRoutingDoesNotRequireSlotZero) {
    Scene scene;
    installDefaultTargets(scene);

    auto node = std::make_shared<SceneNode>();
    node->SetName("slot_one_only_mesh");

    auto mesh = std::make_shared<SceneMesh>();
    mesh->MaterialSlots().push_back(nullptr);
    SceneMaterial slot_one {};
    slot_one.name = "slot_one";
    mesh->AddMaterial(std::move(slot_one));

    mesh->Submeshes().emplace_back();
    mesh->Submeshes().emplace_back();
    mesh->Submeshes()[0].material_slot = 0;
    mesh->Submeshes()[1].material_slot = 1;

    node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(node);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    REQUIRE(std::none_of(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.custom != nullptr && pass.name.empty();
    }));

    const auto* slot_one_pass = findCustomPass(passes, "slot_one");
    REQUIRE(slot_one_pass->desc().output == SpecTex_Default);
    REQUIRE(slot_one_pass->desc().submesh_index == 1);
    REQUIRE(slot_one_pass->desc().material_slot == 1);
}

TEST(RenderGraph, submeshOutputOverrideRoutesOnlyThatPass) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_puppet_mask"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_puppet_layer"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto node = std::make_shared<SceneNode>();
    node->SetName("masked_puppet");

    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial mask {};
    mask.name = "mask_pass";
    SceneMaterial clipped {};
    clipped.name = "clipped_pass";
    clipped.textures.resize(9);
    clipped.textures[8] = "_rt_puppet_mask";
    mesh->AddMaterial(std::move(mask));
    mesh->AddMaterial(std::move(clipped));
    mesh->Submeshes().emplace_back();
    mesh->Submeshes().emplace_back();
    mesh->Submeshes()[0].material_slot = 0;
    mesh->Submeshes()[0].output_override = "_rt_puppet_mask";
    mesh->Submeshes()[1].material_slot = 1;

    node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(node);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        node.get(),
        64.0f,
        64.0f,
        "_rt_puppet_layer",
        "_rt_unused"));
    node->SetCamera("mask_camera");
    scene.cameras["mask_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* mask_pass = findCustomPass(passes, "mask_pass");
    const auto* clipped_pass = findCustomPass(passes, "clipped_pass");
    REQUIRE(mask_pass->desc().output == "_rt_puppet_mask");
    REQUIRE(clipped_pass->desc().output == "_rt_puppet_layer");
    REQUIRE(clipped_pass->desc().textures.size() == 9);
    REQUIRE(clipped_pass->desc().textures[8] == "_rt_puppet_mask");
}

TEST(RenderGraph, generatedPuppetMaskSubmeshesRoutePrepassAndMainClip) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_puppet_mask"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
        .forceClear = true,
    };

    auto node = std::make_shared<SceneNode>();
    node->SetName("generated_masked_puppet");

    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial base {};
    base.name = "base_unclipped";
    SceneMaterial prepass {};
    prepass.name = "generated_mask_prepass";
    SceneMaterial clipped {};
    clipped.name = "generated_clipped_main";
    clipped.textures.resize(9);
    clipped.textures[8] = "_rt_puppet_mask";
    mesh->AddMaterial(std::move(base));
    mesh->AddMaterial(std::move(prepass));
    mesh->AddMaterial(std::move(clipped));

    mesh->Submeshes().resize(3);
    mesh->Submeshes()[0].material_slot = 0;
    mesh->Submeshes()[1].material_slot = 1;
    mesh->Submeshes()[1].output_override = "_rt_puppet_mask";
    mesh->Submeshes()[1].SetDrawRanges(std::array<SceneMesh::DrawRange, 1> {
        SceneMesh::DrawRange { .indexOffset = 0, .indexCount = 3 },
    });
    mesh->Submeshes()[2].material_slot = 2;
    mesh->Submeshes()[2].SetDrawRanges(std::array<SceneMesh::DrawRange, 1> {
        SceneMesh::DrawRange { .indexOffset = 3, .indexCount = 3 },
    });

    node->AddMesh(mesh);
    scene.sceneGraph->AppendChild(node);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* prepass_pass = findCustomPass(passes, "generated_mask_prepass");
    const auto* clipped_pass = findCustomPass(passes, "generated_clipped_main");
    REQUIRE(prepass_pass->desc().output == "_rt_puppet_mask");
    REQUIRE(prepass_pass->desc().submesh_index == 1);
    REQUIRE(prepass_pass->desc().material_slot == 1);
    REQUIRE(clipped_pass->desc().output == SpecTex_Default);
    REQUIRE(clipped_pass->desc().submesh_index == 2);
    REQUIRE(clipped_pass->desc().material_slot == 2);
    REQUIRE(clipped_pass->desc().textures.size() == 9);
    REQUIRE(clipped_pass->desc().textures[8] == "_rt_puppet_mask");
    REQUIRE(clipped_pass->desc().preserve_target_contents);
}

TEST(RenderGraph, parsedMaskedPuppetMaterialSlotsReachRenderGraph) {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/puppet_image.json",
          R"({"width":64,"height":32,"material":"mat/base.json","puppet":"puppet.mdl"})" },
        { "/puppet.mdl", BuildMaskedPuppetMdlFixture() },
        { "/mat/base.json", PuppetMaterialJson("baseimage", { "base.tex" }) },
        { "/mat/head.json", PuppetMaterialJson("puppetmain", { "head.tex" }) },
        { "/shaders/baseimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/baseimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/shaders/puppetmain.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
uniform mat4x3 g_Bones[BONECOUNT];
#endif
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/puppetmain.frag",
          R"(uniform sampler2D g_Texture0;
#if CLIPPINGTARGET
uniform sampler2D g_Texture8;
#endif
varying vec2 v_TexCoord;
void main() {
  vec4 color = texture(g_Texture0, v_TexCoord);
#if CLIPPINGTARGET
  color *= texture(g_Texture8, v_TexCoord);
#endif
  gl_FragColor = color;
}
)" },
        { "/shaders/clippingmaskimage4.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/clippingmaskimage4.frag",
          R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * texture(g_Texture1, v_TexCoord);
}
)" },
        { "/materials/base.tex.tex", "" },
        { "/materials/head.tex.tex", "" },
        { "/materials/masks/iris_mask.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    auto parsed = parser.Parse(
        "parsed-masked-puppet", BasicSceneJson("puppet_image.json"), vfs, sound_manager);
    REQUIRE(parsed != nullptr);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* base_pass = findCustomPass(passes, "puppetmain");
    const auto* prepass_pass = findCustomPass(passes, "clippingmaskimage4");
    const auto clipped_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.custom != nullptr && pass.name == "puppetmain" &&
            pass.custom->desc().material_slot == 2;
    });
    REQUIRE(clipped_it != passes.end());
    const auto* clipped_pass = clipped_it->custom;

    REQUIRE(base_pass->desc().submesh_index == 0);
    REQUIRE(base_pass->desc().material_slot == 0);
    REQUIRE(prepass_pass->desc().submesh_index == 1);
    REQUIRE(prepass_pass->desc().material_slot == 1);
    REQUIRE(prepass_pass->desc().output == "_rt_puppet_mask");
    REQUIRE(clipped_pass->desc().submesh_index == 2);
    REQUIRE(clipped_pass->desc().material_slot == 2);
    REQUIRE(clipped_pass->desc().textures.size() == 9);
    REQUIRE(clipped_pass->desc().textures[8] == "_rt_puppet_mask");
}

// A layer's colour blend mode mixes it with the screen behind it, so the screen
// may only be sampled by the pass that draws onto it. On a puppet with bones
// that is the skinned pass; a pass before it renders the texture sheet, where
// the screen comes out squeezed into the layer's bounds.
TEST(RenderGraph, puppetColorBlendModeSamplesTheScreenOnlyWhereItDrawsOnScreen) {
    const std::string blend_vert = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
#if SKINNING
attribute uvec4 a_BlendIndices;
attribute vec4 a_BlendWeights;
uniform mat4x3 g_Bones[BONECOUNT];
#endif
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    const std::string blend_frag = R"(uniform sampler2D g_Texture0;
#if BLENDMODE
uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
#endif
varying vec2 v_TexCoord;
void main() {
  vec4 color = texture(g_Texture0, v_TexCoord);
#if BLENDMODE
  color.rgb *= texture(g_Texture4, v_TexCoord).rgb;
#endif
  gl_FragColor = color;
}
)";
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/puppet_image.json",
          R"({"width":64,"height":32,"material":"mat/base.json","puppet":"puppet.mdl"})" },
        { "/puppet.mdl", BuildBonedPuppetMdlFixture() },
        { "/mat/base.json", PuppetMaterialJson("puppetblend", { "base.tex" }) },
        { "/mat/head.json", PuppetMaterialJson("puppetblend", { "base.tex" }) },
        { "/materials/util/effectpassthrough.json",
          R"({"passes":[{"shader":"genericimage3","blending":"normal","depthtest":"disabled",)"
          R"("depthwrite":"disabled","cullmode":"nocull"}]})" },
        { "/shaders/puppetblend.vert", blend_vert },
        { "/shaders/puppetblend.frag", blend_frag },
        { "/shaders/genericimage3.vert", blend_vert },
        { "/shaders/genericimage3.frag", blend_frag },
        { "/materials/base.tex.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    auto parsed = parser.Parse("parsed-blended-puppet",
                               BasicSceneJson("puppet_image.json", R"("colorBlendMode":2,)"),
                               vfs,
                               sound_manager);
    REQUIRE(parsed != nullptr);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    std::size_t screen_readers = 0;
    for (const auto& pass : passes) {
        if (pass.custom == nullptr) continue;
        const auto& textures = pass.custom->desc().textures;
        const bool  samples_screen =
            std::any_of(textures.begin(), textures.end(), [](const std::string& texture) {
                return texture.starts_with(SpecTex_Default);
            });
        if (! samples_screen) continue;
        ++screen_readers;
        REQUIRE(pass.custom->desc().output == SpecTex_Default);
    }
    REQUIRE(screen_readers == 1);
}

// Wallpaper Engine draws a layer whose colour blend mode is 31 ("add") with
// additive blending straight onto the scene: no passthrough, no copy of the
// screen for it to sample. With effects the last effect pass is the one that
// adds; without, the layer's own draw.
TEST(RenderGraph, addColorBlendLayersAddOntoTheSceneWithoutSamplingIt) {
    const std::string vert = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    const std::string frag = R"(uniform sampler2D g_Texture0;
#if BLENDMODE
uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
#endif
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
#if BLENDMODE
  gl_FragColor.rgb += texture(g_Texture4, v_TexCoord).rgb;
#endif
}
)";
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/models/util/solidlayer.json", R"({"material":"materials/util/solidlayer.json"})" },
        { "/materials/util/solidlayer.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled",)"
          R"("depthwrite":"disabled","shader":"genericimage","textures":["solid.tex"]}]})" },
        { "/materials/util/effectpassthrough.json",
          R"({"passes":[{"shader":"blend_probe","cullmode":"nocull","blending":"normal",)"
          R"("depthwrite":"disabled","depthtest":"disabled"}]})" },
        { "/effects/tint/effect.json",
          R"({"name":"tint","passes":[{"material":"materials/effects/tint.json"}]})" },
        { "/materials/effects/tint.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled",)"
          R"("depthwrite":"disabled","shader":"effects/tint","textures":[null]}]})" },
        { "/shaders/genericimage.vert", vert },
        { "/shaders/genericimage.frag", frag },
        { "/shaders/blend_probe.vert", vert },
        { "/shaders/blend_probe.frag", frag },
        { "/shaders/effects/tint.vert", vert },
        { "/shaders/effects/tint.frag", frag },
        { "/materials/solid.tex.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    const std::string scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":940,"name":"plain","image":"models/util/solidlayer.json","colorBlendMode":31,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"size":[64,64],"visible":true},
        {"id":941,"name":"with effect","image":"models/util/solidlayer.json","colorBlendMode":31,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"size":[64,64],"visible":true,
         "effects":[{"file":"effects/tint/effect.json","id":942,"visible":true}]}
      ]
    })";

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    auto parsed = parser.Parse("add-color-blend", scene_json, vfs, sound_manager);
    REQUIRE(parsed != nullptr);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);
    std::size_t onto_scene = 0;
    for (const auto& pass : passes) {
        REQUIRE(pass.copy == nullptr);
        if (pass.custom == nullptr) continue;
        const auto& desc = pass.custom->desc();
        for (const auto& texture : desc.textures) REQUIRE(! texture.starts_with(SpecTex_Default));
        if (desc.output != SpecTex_Default) continue;
        ++onto_scene;
        const auto* material = desc.node->Mesh()->MaterialForSlot(desc.material_slot);
        REQUIRE(material != nullptr);
        REQUIRE(material->blenmode == wallpaper::BlendMode::Additive);
        REQUIRE(material->name != "blend_probe");
    }
    REQUIRE(onto_scene == 2);
}

TEST(RenderGraph, skippedBasePassStillEmitsEffectPasses) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_fx_a"] = SceneRenderTarget { .width = 64, .height = 64 };
    scene.renderTargets["_rt_fx_b"] = SceneRenderTarget { .width = 64, .height = 64 };

    auto base = makeNode("skipped_base");
    base->SetSkipRenderPass(true);
    scene.sceneGraph->AppendChild(base);

    auto effect_node = makeNode("effect_after_skipped_base");
    auto effect      = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back(SceneImageEffectNode {
        .output    = "_rt_fx_b",
        .sceneNode = effect_node,
    });

    auto layer = std::make_shared<SceneImageEffectLayer>(
        base.get(),
        64.0f,
        64.0f,
        "_rt_fx_a",
        "_rt_fx_b");
    layer->AddEffect(effect);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(layer);
    base->SetCamera("effect_camera");
    scene.cameras["effect_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    REQUIRE(std::none_of(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.name == "skipped_base";
    }));
    REQUIRE(findCustomPass(passes, "effect_after_skipped_base") != nullptr);
}

TEST(RenderGraph, composeBaseRunsBeforeChildrenAndEffectsAfterChildren) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_compose_a"] = SceneRenderTarget { .width = 64, .height = 64 };
    scene.renderTargets["_rt_compose_b"] = SceneRenderTarget { .width = 64, .height = 64 };

    auto compose = makeNode("compose_base");
    scene.sceneGraph->AppendChild(compose);

    auto child = makeNode("compose_child");
    compose->AppendChild(child);

    auto effect_node = makeNode("compose_effect", { "_rt_compose_a" });
    auto effect      = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back(SceneImageEffectNode {
        .output    = "_rt_compose_b",
        .sceneNode = effect_node,
    });

    auto layer = std::make_shared<SceneImageEffectLayer>(
        compose.get(),
        64.0f,
        64.0f,
        "_rt_compose_a",
        "_rt_compose_b");
    layer->AddEffect(effect);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchNode(compose);
    camera->AttatchImgEffect(layer);
    camera->SetComposeLayer(true);
    compose->SetCamera("compose_camera");
    scene.cameras["compose_camera"] = camera;
    scene.activeCamera              = camera.get();

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto base_index   = findPassIndex(passes, "compose_base");
    const auto child_index  = findPassIndex(passes, "compose_child");
    const auto effect_index = findPassIndex(passes, "compose_effect");

    REQUIRE(base_index < child_index);
    REQUIRE(child_index < effect_index);
}

TEST(RenderGraph, parsedContainerDeclarationOrderControlsRenderPassOrder) {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":200,"name":"early container","origin":[10,0,0],"visible":true},
        {"id":201,"name":"middle sibling","image":"image.json",
         "origin":[20,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":202,"parent":200,"name":"late child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("rendergraph-declaration-order", scene_json, vfs, sound_manager);
    REQUIRE(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* child_view = findCustomPassViewByNodeName(passes, "late child");
    const auto* sibling_view = findCustomPassViewByNodeName(passes, "middle sibling");
    const auto child_index =
        static_cast<size_t>(std::distance(passes.data(), child_view));
    const auto sibling_index =
        static_cast<size_t>(std::distance(passes.data(), sibling_view));
    REQUIRE(child_index < sibling_index);
}

TEST(RenderGraph, parsedForwardParentDeclarationOrderControlsRenderPassOrder) {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":302,"parent":300,"name":"early child","image":"image.json",
         "origin":[5,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":301,"name":"middle root","image":"image.json",
         "origin":[20,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true},
        {"id":300,"name":"late parent","origin":[10,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("rendergraph-forward-parent-order", scene_json, vfs, sound_manager);
    REQUIRE(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* child_view = findCustomPassViewByNodeName(passes, "early child");
    const auto* root_view  = findCustomPassViewByNodeName(passes, "middle root");
    const auto child_index =
        static_cast<size_t>(std::distance(passes.data(), child_view));
    const auto root_index =
        static_cast<size_t>(std::distance(passes.data(), root_view));
    REQUIRE(root_index < child_index);
}

TEST(RenderGraph, reusableNonDefaultTargetClearsOnlyOnFirstWriter) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_reusable"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto first = makeNode("first_reusable_writer");
    scene.sceneGraph->AppendChild(first);
    auto second = makeNode("second_reusable_writer");
    scene.sceneGraph->AppendChild(second);

    auto first_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    first_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        first.get(),
        64.0f,
        64.0f,
        "_rt_reusable",
        "_rt_unused_a"));
    first->SetCamera("first_camera");
    scene.cameras["first_camera"] = first_camera;

    auto second_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    second_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        second.get(),
        64.0f,
        64.0f,
        "_rt_reusable",
        "_rt_unused_b"));
    second->SetCamera("second_camera");
    scene.cameras["second_camera"] = second_camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* first_pass  = findCustomPass(passes, "first_reusable_writer");
    const auto* second_pass = findCustomPass(passes, "second_reusable_writer");

    REQUIRE(first_pass->desc().output == "_rt_reusable");
    REQUIRE(first_pass->desc().clear_on_first_use);
    REQUIRE(!first_pass->desc().preserve_target_contents);

    REQUIRE(second_pass->desc().output == "_rt_reusable");
    REQUIRE(!second_pass->desc().clear_on_first_use);
    REQUIRE(second_pass->desc().preserve_target_contents);
}

TEST(RenderGraph, forceClearReusableTargetClearsEveryWriter) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_force_clear"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
        .forceClear = true,
    };

    auto first = makeNode("first_force_clear_writer");
    scene.sceneGraph->AppendChild(first);
    auto second = makeNode("second_force_clear_writer");
    scene.sceneGraph->AppendChild(second);

    auto first_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    first_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        first.get(),
        64.0f,
        64.0f,
        "_rt_force_clear",
        "_rt_unused_a"));
    first->SetCamera("first_force_clear_camera");
    scene.cameras["first_force_clear_camera"] = first_camera;

    auto second_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    second_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        second.get(),
        64.0f,
        64.0f,
        "_rt_force_clear",
        "_rt_unused_b"));
    second->SetCamera("second_force_clear_camera");
    scene.cameras["second_force_clear_camera"] = second_camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* first_pass  = findCustomPass(passes, "first_force_clear_writer");
    const auto* second_pass = findCustomPass(passes, "second_force_clear_writer");

    REQUIRE(first_pass->desc().output == "_rt_force_clear");
    REQUIRE(first_pass->desc().clear_on_first_use);
    REQUIRE(!first_pass->desc().preserve_target_contents);

    REQUIRE(second_pass->desc().output == "_rt_force_clear");
    REQUIRE(second_pass->desc().clear_on_first_use);
    REQUIRE(!second_pass->desc().preserve_target_contents);
}

TEST(RenderGraph, forceClearDoesNotChangeDefaultOutputPreservation) {
    Scene scene;
    installDefaultTargets(scene);
    scene.clearEnabled = false;
    scene.renderTargets[std::string(SpecTex_Default)].forceClear = true;

    auto first = makeNode("first_default_force_clear_guard");
    scene.sceneGraph->AppendChild(first);
    auto second = makeNode("second_default_force_clear_guard");
    scene.sceneGraph->AppendChild(second);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* first_pass  = findCustomPass(passes, "first_default_force_clear_guard");
    const auto* second_pass = findCustomPass(passes, "second_default_force_clear_guard");

    REQUIRE(first_pass->desc().output == SpecTex_Default);
    REQUIRE(!first_pass->desc().clear_on_first_use);
    REQUIRE(!first_pass->desc().preserve_target_contents);

    REQUIRE(second_pass->desc().output == SpecTex_Default);
    REQUIRE(!second_pass->desc().clear_on_first_use);
    REQUIRE(second_pass->desc().preserve_target_contents);
}

TEST(RenderGraph, renderTargetSampleCountPropagatesToCustomPassDesc) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_msaa_scaffold"] = SceneRenderTarget {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };

    auto writer = makeNode("msaa_scaffold_writer");
    scene.sceneGraph->AppendChild(writer);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        writer.get(),
        64.0f,
        64.0f,
        "_rt_msaa_scaffold",
        "_rt_unused"));
    writer->SetCamera("msaa_scaffold_camera");
    scene.cameras["msaa_scaffold_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* pass = findCustomPass(passes, "msaa_scaffold_writer");
    REQUIRE(pass->desc().output == "_rt_msaa_scaffold");
    REQUIRE(pass->desc().sample_count == VK_SAMPLE_COUNT_4_BIT);
}

TEST(RenderGraph, copyWrittenMsaaTargetsPreserveWithSingleSamplePasses) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_msaa_after_copy"] = SceneRenderTarget {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };

    auto writer = makeNode("msaa_after_copy_writer");
    auto post   = std::make_shared<wallpaper::ScenePostProcess>();
    post->name  = "msaa_after_copy_post";
    post->steps.push_back(wallpaper::ScenePostProcessCopy {
        .src = std::string(SpecTex_Default),
        .dst = "_rt_msaa_after_copy",
    });
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = writer,
        .output = "_rt_msaa_after_copy",
    });
    scene.post_processes.push_back(post);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* pass = findCustomPass(passes, "msaa_after_copy_writer");
    REQUIRE(pass->desc().output == "_rt_msaa_after_copy");
    REQUIRE(pass->desc().preserve_target_contents);
    REQUIRE(pass->desc().sample_count == VK_SAMPLE_COUNT_1_BIT);
}

TEST(RenderGraph, separateMsaaRenderTargetWritersPreserveWithMsaaSampleCount) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_msaa_multi_writer"] = SceneRenderTarget {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };

    auto first = makeNode("first_msaa_multi_writer");
    scene.sceneGraph->AppendChild(first);
    auto second = makeNode("second_msaa_multi_writer");
    scene.sceneGraph->AppendChild(second);

    auto first_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    first_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        first.get(),
        64.0f,
        64.0f,
        "_rt_msaa_multi_writer",
        "_rt_unused_a"));
    first->SetCamera("first_msaa_multi_writer_camera");
    scene.cameras["first_msaa_multi_writer_camera"] = first_camera;

    auto second_camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    second_camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        second.get(),
        64.0f,
        64.0f,
        "_rt_msaa_multi_writer",
        "_rt_unused_b"));
    second->SetCamera("second_msaa_multi_writer_camera");
    scene.cameras["second_msaa_multi_writer_camera"] = second_camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* first_pass  = findCustomPass(passes, "first_msaa_multi_writer");
    const auto* second_pass = findCustomPass(passes, "second_msaa_multi_writer");

    REQUIRE(first_pass->desc().output == "_rt_msaa_multi_writer");
    REQUIRE(first_pass->desc().clear_on_first_use);
    REQUIRE(!first_pass->desc().preserve_target_contents);
    REQUIRE(first_pass->desc().sample_count == VK_SAMPLE_COUNT_4_BIT);

    REQUIRE(second_pass->desc().output == "_rt_msaa_multi_writer");
    REQUIRE(!second_pass->desc().clear_on_first_use);
    REQUIRE(second_pass->desc().preserve_target_contents);
    REQUIRE(second_pass->desc().sample_count == VK_SAMPLE_COUNT_4_BIT);
}

TEST(RenderGraph, videoTextureSamplingIsPreservedInMsaaScenePass) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_msaa_video"] = SceneRenderTarget {
        .width        = 64,
        .height       = 64,
        .allowReuse   = true,
        .sample_count = 4,
    };
    scene.textures["video://clip"] = wallpaper::SceneTexture {
        .url     = "video://clip",
        .isVideo = true,
    };

    auto writer = makeNode("msaa_video_sampler", { "video://clip" });
    scene.sceneGraph->AppendChild(writer);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        writer.get(),
        64.0f,
        64.0f,
        "_rt_msaa_video",
        "_rt_unused"));
    writer->SetCamera("msaa_video_camera");
    scene.cameras["msaa_video_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* pass = findCustomPass(passes, "msaa_video_sampler");
    REQUIRE(pass->desc().output == "_rt_msaa_video");
    REQUIRE(pass->desc().textures.size() == 1);
    REQUIRE(pass->desc().textures[0] == "video://clip");
    REQUIRE(pass->desc().sample_count == VK_SAMPLE_COUNT_4_BIT);
}

TEST(RenderGraph, defaultOutputUsesSceneClearEnabledWhileNonDefaultWritesAlpha) {
    Scene scene;
    installDefaultTargets(scene);
    scene.clearEnabled = false;
    scene.renderTargets["_rt_alpha"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto default_node = makeNode("default_writer");
    scene.sceneGraph->AppendChild(default_node);

    auto offscreen_node = makeNode("alpha_writer");
    scene.sceneGraph->AppendChild(offscreen_node);
    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        offscreen_node.get(),
        64.0f,
        64.0f,
        "_rt_alpha",
        "_rt_unused"));
    offscreen_node->SetCamera("alpha_camera");
    scene.cameras["alpha_camera"] = camera;

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* default_pass = findCustomPass(passes, "default_writer");
    REQUIRE(default_pass->desc().output == SpecTex_Default);
    REQUIRE(!default_pass->desc().clear_on_first_use);
    REQUIRE(!default_pass->desc().write_alpha);

    const auto* offscreen_pass = findCustomPass(passes, "alpha_writer");
    REQUIRE(offscreen_pass->desc().output == "_rt_alpha");
    REQUIRE(offscreen_pass->desc().clear_on_first_use);
    REQUIRE(offscreen_pass->desc().write_alpha);

    Scene clear_scene;
    installDefaultTargets(clear_scene);
    clear_scene.clearEnabled = true;

    auto clear_node = makeNode("default_clear_writer");
    clear_scene.sceneGraph->AppendChild(clear_node);

    const auto clear_graph  = wallpaper::sceneToRenderGraph(clear_scene);
    const auto clear_passes = graphPasses(*clear_graph);

    const auto* clear_pass = findCustomPass(clear_passes, "default_clear_writer");
    REQUIRE(clear_pass->desc().output == SpecTex_Default);
    REQUIRE(clear_pass->desc().clear_on_first_use);
    REQUIRE(!clear_pass->desc().write_alpha);
}

// A layer hidden by a visibility only a reload changes is left out of the
// graph. While it was in, it could be the scene output's first writer: with
// clearing off that writer neither cleared nor drew, so the first layer drawn
// loaded what the frame began with, and leaving the hidden one out must not
// make that layer discard it. With clearing on the first layer drawn clears,
// as the hidden one's clear did before it.
TEST(RenderGraph, aHiddenFirstWriterLeftOutKeepsTheSceneOutputsLoadAndClear) {
    for (const bool clear : { false, true }) {
        for (const bool hidden_first : { true, false }) {
            SCOPED_TRACE(std::string(clear ? "clearing" : "not clearing") +
                         (hidden_first ? ", hidden first" : ", hidden after"));
            Scene scene;
            installDefaultTargets(scene);
            scene.clearEnabled = clear;
            auto hidden = makeNode("left_out_writer");
            hidden->SetVisible(false);
            hidden->SetVisibilitySettled(true);
            auto drawn = makeNode("first_drawn_writer");
            if (hidden_first) scene.sceneGraph->AppendChild(hidden);
            scene.sceneGraph->AppendChild(drawn);
            if (! hidden_first) scene.sceneGraph->AppendChild(hidden);

            const auto graph  = wallpaper::sceneToRenderGraph(scene);
            const auto passes = graphPasses(*graph);
            REQUIRE(std::none_of(passes.begin(), passes.end(), [](const auto& pass) {
                return pass.name == "left_out_writer";
            }));
            const auto* first = findCustomPass(passes, "first_drawn_writer");
            REQUIRE(first->desc().output == SpecTex_Default);
            EXPECT_EQ(first->desc().clear_on_first_use, clear);
            EXPECT_EQ(first->desc().preserve_target_contents, ! clear && hidden_first);
        }
    }
}

TEST(RenderGraph, postProcessesAppendPassesAndCopiesAfterSceneGraph) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_post_pass"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_post_copy"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto scene_node = makeNode("main_scene_writer");
    scene.sceneGraph->AppendChild(scene_node);

    auto post_node = makeNode("post_process_writer", { SpecTex_Default.data() });
    auto post      = std::make_shared<wallpaper::ScenePostProcess>();
    post->name     = "test_post_process";
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = post_node,
        .output = "_rt_post_pass",
    });
    post->steps.push_back(wallpaper::ScenePostProcessCopy {
        .src = "_rt_post_pass",
        .dst = "_rt_post_copy",
    });
    scene.post_processes.push_back(post);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto scene_index = findPassIndex(passes, "main_scene_writer");
    const auto post_index  = findPassIndex(passes, "post_process_writer");
    const auto copy_it     = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().src == "_rt_post_pass"
            && pass.copy->desc().dst == "_rt_post_copy";
    });
    REQUIRE(copy_it != passes.end());
    const auto copy_index = static_cast<size_t>(std::distance(passes.begin(), copy_it));

    REQUIRE(scene_index < post_index);
    REQUIRE(post_index < copy_index);

    const auto* post_pass = findCustomPass(passes, "post_process_writer");
    REQUIRE(post_pass->desc().output == "_rt_post_pass");
    REQUIRE(copy_it->copy->desc().src == "_rt_post_pass");
    REQUIRE(copy_it->copy->desc().dst == "_rt_post_copy");
}

TEST(RenderGraph, nullPostProcessPassNodesAreSkipped) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_after_null_pass"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_after_null_copy"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto post_node = makeNode("post_after_null_pass");
    auto post      = std::make_shared<wallpaper::ScenePostProcess>();
    post->name     = "null_pass_guard";
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = nullptr,
        .output = "_rt_ignored_null_pass",
    });
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = post_node,
        .output = "_rt_after_null_pass",
    });
    post->steps.push_back(wallpaper::ScenePostProcessCopy {
        .src = "_rt_after_null_pass",
        .dst = "_rt_after_null_copy",
    });
    scene.post_processes.push_back(post);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* post_pass = findCustomPass(passes, "post_after_null_pass");
    REQUIRE(post_pass->desc().output == "_rt_after_null_pass");
    REQUIRE(std::any_of(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().src == "_rt_after_null_pass"
            && pass.copy->desc().dst == "_rt_after_null_copy";
    }));
}

TEST(RenderGraph, postProcessCopyStepsResolveRenderTargetAliases) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_alias_resolved_src"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_alias_resolved_dst"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargetAliases["_alias_post_src"] = "_rt_alias_resolved_src";
    scene.renderTargetAliases["_alias_post_dst"] = "_rt_alias_resolved_dst";

    auto post_node = makeNode("alias_post_writer");
    auto post      = std::make_shared<wallpaper::ScenePostProcess>();
    post->name     = "alias_post_process";
    post->steps.push_back(wallpaper::ScenePostProcessPass {
        .node   = post_node,
        .output = "_alias_post_src",
    });
    post->steps.push_back(wallpaper::ScenePostProcessCopy {
        .src = "_alias_post_src",
        .dst = "_alias_post_dst",
    });
    scene.post_processes.push_back(post);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* post_pass = findCustomPass(passes, "alias_post_writer");
    REQUIRE(post_pass->desc().output == "_rt_alias_resolved_src");

    const auto copy_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().src == "_rt_alias_resolved_src"
            && pass.copy->desc().dst == "_rt_alias_resolved_dst";
    });
    REQUIRE(copy_it != passes.end());

    const auto post_index = findPassIndex(passes, "alias_post_writer");
    const auto copy_index = static_cast<size_t>(std::distance(passes.begin(), copy_it));
    REQUIRE(post_index < copy_index);
}

TEST(RenderGraph, linkedImageCompositeTexturesResolveToSourceLayerOutput) {
    Scene scene;
    installDefaultTargets(scene);

    auto source = makeNode("source_layer");
    source->ID() = 159;
    scene.sceneGraph->AppendChild(source);

    auto consumer = makeNode("consumer_layer", { wallpaper::GenLinkTex(159) });
    consumer->ID() = 160;
    scene.sceneGraph->AppendChild(consumer);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPass(passes, "consumer_layer");
    REQUIRE(consumer_pass->desc().textures.size() == 1);
    REQUIRE(consumer_pass->desc().textures[0] == wallpaper::GenLinkTex(159));

    const auto copy_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().dst == wallpaper::GenLinkTex(159);
    });
    REQUIRE(copy_it != passes.end());
}

TEST(RenderGraph, parsedInvisibleDependencySourceResolvesLinkedRenderTexture) {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/linked.json",
          R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/linked_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":159,"name":"dependency source","image":"image.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false},
        {"id":160,"name":"consumer","image":"linked.json","dependencies":[159],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("linked-invisible-dependency", scene_json, vfs, sound_manager);
    REQUIRE(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPassByNodeName(passes, "consumer");
    REQUIRE(consumer_pass->desc().textures.size() == 1);
    REQUIRE(consumer_pass->desc().textures[0] == wallpaper::GenLinkTex(159));

    const auto copy_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().dst == wallpaper::GenLinkTex(159);
    });
    REQUIRE(copy_it != passes.end());
}

TEST(RenderGraph, parsedZeroHeightDependencyEffectUsesNonZeroRenderTargets) {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/models/util/solidlayer.json",
          R"({"material":"materials/util/solidlayer.json"})" },
        { "/materials/util/solidlayer.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid.tex"]}]})" },
        { "/effects/audio_buffer_accumulation/effect.json",
          R"({"name":"Audio Buffer Accumulation","fbos":[{"name":"_rt_FullCompoBuffer1","scale":1},{"name":"_rt_FullCompoBuffer2","scale":1},{"name":"_rt_TinyScaledBuffer","scale":512}],"passes":[{"material":"materials/effects/accumulate.json","target":"_rt_FullCompoBuffer2","bind":[{"name":"previous","index":0},{"name":"_rt_FullCompoBuffer1","index":1}]},{"command":"copy","source":"_rt_FullCompoBuffer2","target":"_rt_FullCompoBuffer1"},{"material":"materials/effects/combine.json","bind":[{"name":"_rt_FullCompoBuffer2","index":0}]}]})" },
        { "/materials/effects/accumulate.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null,null]}]})" },
        { "/materials/effects/combine.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/linked.json",
          R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/linked_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_915"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/solid.tex.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":915,"name":"zero height dependency source","image":"models/util/solidlayer.json",
         "origin":[0,0,0],"scale":[0,0,0],"size":[64,0],"visible":false,
         "effects":[{"file":"effects/audio_buffer_accumulation/effect.json","id":917,"visible":true}]},
        {"id":916,"name":"consumer","image":"linked.json","dependencies":[915],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("zero-height-dependency-effect", scene_json, vfs, sound_manager);
    REQUIRE(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPassByNodeName(passes, "consumer");
    REQUIRE(consumer_pass->desc().textures.size() == 1);
    REQUIRE(consumer_pass->desc().textures[0] == wallpaper::GenLinkTex(915));

    const auto copy_it = std::find_if(passes.begin(), passes.end(), [](const auto& pass) {
        return pass.copy != nullptr && pass.copy->desc().dst == wallpaper::GenLinkTex(915);
    });
    REQUIRE(copy_it != passes.end());

    const std::string full_compo_prefix =
        std::string(wallpaper::WE_FULL_COMPO_BUFFER_PREFIX);
    const std::string effect_pingpong_prefix =
        std::string(wallpaper::WE_EFFECT_PPONG_PREFIX);
    for (const auto& [name, target] : parsed->renderTargets) {
        const bool relevant =
            name.rfind(full_compo_prefix, 0) == 0 || name.rfind(effect_pingpong_prefix, 0) == 0 ||
            name.find("_rt_TinyScaledBuffer") != std::string::npos;
        if (!relevant) continue;
        REQUIRE(target.width * target.height > 4);
        REQUIRE(target.width >= 4);
        REQUIRE(target.height >= 4);
        if (name.find("_rt_TinyScaledBuffer") == std::string::npos) {
            REQUIRE(target.width == 64);
            REQUIRE(target.height == 360);
        }
    }
}

// The materials of every effect the parser built for the scene's layers.
std::vector<std::string> parsedEffectMaterials(wallpaper::Scene& scene) {
    std::vector<std::string> names;
    for (auto& [camera_name, camera] : scene.cameras) {
        (void)camera_name;
        if (! camera->HasImgEffect()) continue;
        auto& layer = *camera->GetImgEffect();
        for (std::size_t i = 0; i < layer.EffectCount(); ++i) {
            for (const auto& node : layer.GetEffect(i)->nodes) {
                if (node.sceneNode == nullptr || node.sceneNode->Mesh() == nullptr) continue;
                if (const auto* material = node.sceneNode->Mesh()->Material())
                    names.push_back(material->name);
            }
        }
    }
    std::sort(names.begin(), names.end());
    return names;
}

TEST(RenderGraph, parsedEffectVisibilityFollowsTheBoundUserProperty) {
    // An effect's `visible` bound to a user property stores the editor's value
    // only as a default; the property's current value decides, as for a layer.
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/models/util/solidlayer.json",
          R"({"material":"materials/util/solidlayer.json"})" },
        { "/materials/util/solidlayer.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid.tex"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/solid.tex.tex", "" },
    };
    // A material is named after its shader, so each effect gets its own.
    for (const std::string name : { "toggled", "chosen", "unchosen", "unbound" }) {
        files["/effects/" + name + "/effect.json"] =
            R"({"name":")" + name + R"(","passes":[{"material":"materials/effects/)" + name +
            R"(.json"}]})";
        files["/materials/effects/" + name + ".json"] =
            R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"effects/)" +
            name + R"(","textures":[null]}]})";
        files["/shaders/effects/" + name + ".vert"] = files.at("/shaders/genericimage.vert");
        files["/shaders/effects/" + name + ".frag"] = files.at("/shaders/genericimage.frag");
    }
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    const std::string scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":930,"name":"customizable","image":"models/util/solidlayer.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"size":[64,64],"visible":true,
         "effects":[
           {"file":"effects/toggled/effect.json","id":931,
            "visible":{"user":"toggle","value":false}},
           {"file":"effects/chosen/effect.json","id":932,
            "visible":{"user":{"name":"mode","condition":"2"},"value":false}},
           {"file":"effects/unchosen/effect.json","id":933,
            "visible":{"user":{"name":"mode","condition":"1"},"value":true}},
           {"file":"effects/unbound/effect.json","id":934,
            "visible":{"user":"missing","value":true}}
         ]}
      ]
    })";

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;

    // Without properties the scene file's values are all there is.
    auto authored = parser.Parse("effect-visibility-authored", scene_json, vfs, sound_manager);
    REQUIRE(authored != nullptr);
    REQUIRE((parsedEffectMaterials(*authored) ==
             std::vector<std::string> { "effects/unbound", "effects/unchosen" }));

    const wallpaper::ProjectProperties properties {
        { "toggle", wallpaper::RuntimeScalarValue::Bool(true) },
        { "mode", wallpaper::RuntimeScalarValue::String("2") },
    };
    auto chosen = parser.Parse(
        wallpaper::SceneParseRequest {
            .scene_id = "effect-visibility-chosen", .project_properties = &properties },
        scene_json, vfs, sound_manager);
    REQUIRE(chosen != nullptr);
    REQUIRE((parsedEffectMaterials(*chosen) ==
             std::vector<std::string> { "effects/chosen", "effects/toggled", "effects/unbound" }));
}

TEST(RenderGraph, linkedEffectSourceFallsBackToBaseTargetWhenEffectsFailToLoad) {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/source.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["a.tex"]}]})" },
        { "/effects/failing/effect.json",
          R"({"name":"failing effect","passes":[{"material":"materials/missing.json"}]})" },
        { "/linked.json",
          R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/linked_mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_915"]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/a.tex.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":915,"name":"dependency source with failed effect","image":"source.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":false,
         "effects":[{"file":"effects/failing/effect.json","id":917,"visible":true}]},
        {"id":916,"name":"consumer","image":"linked.json","dependencies":[915],
         "origin":[8,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}
      ]
    })";

    auto parsed = parser.Parse("failed-effect-linked-source", scene_json, vfs, sound_manager);
    REQUIRE(parsed != nullptr);
    installDefaultTargets(*parsed);

    const auto graph  = wallpaper::sceneToRenderGraph(*parsed);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPassByNodeName(passes, "consumer");
    REQUIRE(consumer_pass->desc().textures.size() == 1);
    REQUIRE(consumer_pass->desc().textures[0] == wallpaper::GenLinkTex(915));

    const auto* source_view = findCustomPassViewByNodeName(passes, "dependency source with failed effect");
    const auto* source_pass = source_view->custom;
    REQUIRE(source_pass->desc().output.rfind(wallpaper::WE_EFFECT_PPONG_PREFIX_A, 0) == 0);
    const auto* link_copy = findCopyPass(passes, source_pass->desc().output, wallpaper::GenLinkTex(915));
    REQUIRE(link_copy != nullptr);

    const auto source_index =
        static_cast<size_t>(std::distance(passes.data(), source_view));
    const auto copy_index =
        static_cast<size_t>(std::distance(passes.data(), link_copy));
    const auto* consumer_view = findCustomPassViewByNodeName(passes, "consumer");
    const auto consumer_index =
        static_cast<size_t>(std::distance(passes.data(), consumer_view));
    REQUIRE(source_index < copy_index);
    REQUIRE(copy_index < consumer_index);
}

TEST(RenderGraph, linkedEffectSourceDoesNotUseIntermediateTargetAsFallback) {
    Scene scene;
    installDefaultTargets(scene);
    scene.renderTargets["_rt_source_base"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };
    scene.renderTargets["_rt_intermediate_effect"] = SceneRenderTarget {
        .width      = 64,
        .height     = 64,
        .allowReuse = true,
    };

    auto source = makeNode("source_base");
    source->ID() = 915;
    scene.sceneGraph->AppendChild(source);

    auto effect_node = makeNode("source_intermediate_effect", { "_rt_source_base" });
    auto effect      = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back(SceneImageEffectNode {
        .output    = "_rt_intermediate_effect",
        .sceneNode = effect_node,
    });

    auto layer = std::make_shared<SceneImageEffectLayer>(
        source.get(),
        64.0f,
        64.0f,
        "_rt_source_base",
        "_rt_unused_pingpong");
    layer->AddEffect(effect);

    auto camera = std::make_shared<SceneCamera>(64, 64, 0.01f, 100.0f);
    camera->AttatchImgEffect(layer);
    source->SetCamera("source_effect_camera");
    scene.cameras["source_effect_camera"] = camera;

    auto consumer = makeNode("consumer_of_base", { wallpaper::GenLinkTex(915) });
    consumer->ID() = 916;
    scene.sceneGraph->AppendChild(consumer);

    const auto graph  = wallpaper::sceneToRenderGraph(scene);
    const auto passes = graphPasses(*graph);

    const auto* consumer_pass = findCustomPass(passes, "consumer_of_base");
    REQUIRE(consumer_pass->desc().textures.size() == 1);
    REQUIRE(consumer_pass->desc().textures[0].empty());
    REQUIRE(findCopyPass(passes, "_rt_source_base", wallpaper::GenLinkTex(915)) == nullptr);
    REQUIRE(findCopyPass(passes, "_rt_intermediate_effect", wallpaper::GenLinkTex(915)) == nullptr);
}

TEST(RenderGraph, parsedFullscreenScaledFbosStayValidAfterScreenBindSizing) {
    wallpaper::fs::VFS vfs;
    auto files = std::map<std::string, std::string> {
        { "/fullscreen.json",
          R"({"fullscreen":true,"material":"materials/fullscreen.json"})" },
        { "/materials/fullscreen.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid.tex"]}]})" },
        { "/effects/fullscreen_scaled/effect.json",
          R"({"name":"Fullscreen Scaled FBO","fbos":[{"name":"_rt_TinyFullscreenBuffer","scale":512}],"passes":[{"material":"materials/effects/copy.json","target":"_rt_TinyFullscreenBuffer","bind":[{"name":"previous","index":0}]}]})" },
        { "/materials/effects/copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]})" },
        { "/shaders/genericimage.vert",
          R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
        { "/shaders/genericimage.frag",
          R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)" },
        { "/materials/solid.tex.tex", "" },
    };
    REQUIRE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));

    wallpaper::audio::SoundManager sound_manager(wallpaper::audio::SoundManager::OutputBackend::Null);
    wallpaper::WPSceneParser       parser;
    const std::string              scene_json = R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "zoom":4,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": [
        {"id":930,"name":"fullscreen tiny fbo","image":"fullscreen.json",
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true,
         "effects":[{"file":"effects/fullscreen_scaled/effect.json","id":931,"visible":true}]}
      ]
    })";

    auto parsed = parser.Parse("fullscreen-scaled-fbo", scene_json, vfs, sound_manager);
    REQUIRE(parsed != nullptr);
    const auto tiny_it = std::find_if(
        parsed->renderTargets.begin(),
        parsed->renderTargets.end(),
        [](const auto& item) {
            return item.first.find("_rt_TinyFullscreenBuffer") != std::string::npos;
        });
    REQUIRE(tiny_it != parsed->renderTargets.end());

    const auto& target = tiny_it->second;
    REQUIRE(target.bind.enable);
    REQUIRE(target.bind.screen);
    const auto& default_target = parsed->renderTargets.at(std::string(SpecTex_Default));
    REQUIRE(default_target.width == 160);
    REQUIRE(default_target.height == 90);
    REQUIRE(std::abs(target.bind.scale - (1.0 / 512.0)) < 0.000001);

    auto runtime_target = target;
    Scene runtime_scene;
    runtime_scene.renderTargets[std::string(SpecTex_Default)] = default_target;
    runtime_scene.renderTargets["fullscreen_runtime_target"] = runtime_target;
    wallpaper::vulkan::ResolveScreenBoundRenderTargetSizes(
        runtime_scene,
        VkExtent2D {
            .width  = 999,
            .height = 999,
        });
    runtime_target = runtime_scene.renderTargets.at("fullscreen_runtime_target");
    REQUIRE(runtime_target.width >= 4);
    REQUIRE(runtime_target.height >= 4);
    REQUIRE(runtime_target.width * runtime_target.height > 4);
}

TEST(RenderGraph, screenBoundSizingHonorsTinyAuthoredDefaultExtent) {
    Scene scene;
    scene.ortho[0] = 640;
    scene.ortho[1] = 360;
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width  = 1,
        .height = 90,
        .bind   = { .enable = true, .screen = true },
    };
    scene.renderTargets["screen_bound_tiny"] = SceneRenderTarget {
        .width = 2,
        .height = 2,
        .bind = {
            .enable = true,
            .screen = true,
            .scale = 1.0,
        },
    };

    const auto source_extent = wallpaper::vulkan::ResolveScreenBoundRenderTargetSizes(
        scene,
        VkExtent2D {
            .width  = 999,
            .height = 999,
        });

    REQUIRE(source_extent.source.width == 1);
    REQUIRE(source_extent.source.height == 90);
    const auto& target = scene.renderTargets.at("screen_bound_tiny");
    REQUIRE(target.width == 4);
    REQUIRE(target.height == 90);

    const auto second_source_extent = wallpaper::vulkan::ResolveScreenBoundRenderTargetSizes(
        scene,
        VkExtent2D {
            .width  = 999,
            .height = 999,
        });
    REQUIRE(second_source_extent.source.width == 1);
    REQUIRE(second_source_extent.source.height == 90);
    const auto& second_target = scene.renderTargets.at("screen_bound_tiny");
    REQUIRE(second_target.width == 4);
    REQUIRE(second_target.height == 90);
    const auto& default_target = scene.renderTargets.at(std::string(SpecTex_Default));
    REQUIRE(source_extent.raster.width == 4);
    REQUIRE(default_target.authored_width == 1);
    REQUIRE(default_target.width == 4);
    REQUIRE(default_target.height == 90);
}

TEST(RenderGraph, textureDescriptorReadinessRejectsMissingImages) {
    wallpaper::vulkan::CustomShaderPass::Desc desc {};
    desc.textures = { "_rt_imageLayerComposite_159_a" };
    desc.vk_textures.resize(1);
    desc.vk_texture_bindings.push_back({
        .image_binding = 1,
        .image_descriptor_type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .sampler_binding = -1,
    });

    wallpaper::vulkan::CustomShaderPass pass(desc);
    pass.desc().vk_textures = desc.vk_textures;
    pass.desc().vk_texture_bindings = desc.vk_texture_bindings;
    REQUIRE(! pass.textureDescriptorsReady());
}

TEST(RenderGraph, textureDescriptorReadinessRejectsMissingSeparateSampler) {
    wallpaper::vulkan::CustomShaderPass::Desc desc {};
    desc.textures = { "image.png" };
    desc.vk_textures.resize(1);
    wallpaper::vulkan::ImageParameters image {};
    image.handle  = reinterpret_cast<VkImage>(1);
    image.view    = reinterpret_cast<VkImageView>(1);
    image.sampler = VK_NULL_HANDLE;
    image.layout  = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    desc.vk_textures[0].slots.push_back(image);
    desc.vk_texture_bindings.push_back({
        .image_binding = 1,
        .image_descriptor_type = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        .sampler_binding = 2,
    });

    wallpaper::vulkan::CustomShaderPass pass(desc);
    pass.desc().vk_textures = desc.vk_textures;
    pass.desc().vk_texture_bindings = desc.vk_texture_bindings;
    REQUIRE(! pass.textureDescriptorsReady());
}
} // namespace
