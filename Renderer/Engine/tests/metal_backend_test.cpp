/// Native Metal backend: the capability gate, the blend mapping, the
/// clip-space derivation and the pipeline cache key.
///
/// Everything here is decided without a GPU on purpose -- these are the
/// decisions that must be right before a device is ever touched. The one test
/// that needs a Metal device says so and skips visibly when there is none.

#include "MetalRender/MetalBlend.hpp"
#include "MetalRender/MetalCapability.hpp"
#include "MetalRender/MetalProjection.hpp"
#include "MetalRender/MetalShaderReflection.hpp"
#include "MetalRender/SceneMetalProgram.hpp"
#include "MetalRender/ScenePassDescription.hpp"

#include "Particle/ParticleSystem.h"
#include "Presentation/WallpaperScaling.hpp"
#include "RenderGraph/PassNode.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "SpriteAnimation.hpp"
#include "SpecTexs.hpp"
#include "Utils/Linalg.hpp"
#include "RenderCommon/ScenePass.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <array>
#include <memory>
#include <string>

#ifdef __APPLE__
#include "MetalRender/MetalRender.hpp"
#endif

using namespace wallpaper;
using namespace wallpaper::metal;

namespace
{

constexpr std::string_view kReflectionJson = R"({
  "descriptor_bindings": [
    { "name": "Globals", "set": 0, "binding": 0, "descriptor": "uniform_buffer",
      "stages": ["vertex", "fragment"] },
    { "name": "g_Texture0", "set": 0, "binding": 1, "descriptor": "sampled_image",
      "stages": ["fragment"] },
    { "name": "_we_Sampler_g_Texture0", "set": 0, "binding": 2, "descriptor": "sampler",
      "stages": ["fragment"] }
  ],
  "uniform_blocks": [
    { "name": "Globals", "binding": 0, "size": 128, "members": [
      { "name": "g_ModelViewProjectionMatrix", "offset": 0, "size": 64 },
      { "name": "g_Alpha", "offset": 64, "size": 4 }
    ] }
  ],
  "vertex_inputs": [
    { "name": "a_Position", "location": 0, "format": "r32g32b32_sfloat" },
    { "name": "a_TexCoord", "location": 1, "format": "r32g32_sfloat" }
  ],
  "active_texture_slots": [0]
})";

/// Reflection for a shader driven by a puppet skeleton: four 4x4 bone
/// matrices and the blend attributes the author's vertex shader reads.
constexpr std::string_view kBonesReflectionJson = R"({
  "descriptor_bindings": [
    { "name": "Globals", "set": 0, "binding": 0, "descriptor": "uniform_buffer",
      "stages": ["vertex"] }
  ],
  "uniform_blocks": [
    { "name": "Globals", "binding": 0, "size": 256, "members": [
      { "name": "g_Bones", "offset": 0, "size": 256, "array_count": 4, "array_stride": 64 }
    ] }
  ],
  "vertex_inputs": [
    { "name": "a_Position", "location": 0, "format": "r32g32b32_sfloat" },
    { "name": "a_BlendIndices", "location": 1, "format": "r32g32b32a32_uint" },
    { "name": "a_BlendWeights", "location": 2, "format": "r32g32b32a32_sfloat" },
    { "name": "a_TexCoord", "location": 3, "format": "r32g32_sfloat" }
  ],
  "active_texture_slots": []
})";

/// Same puppet layout with a stride too small for a 4x4 float matrix.
constexpr std::string_view kBonesStride48ReflectionJson = R"({
  "descriptor_bindings": [
    { "name": "Globals", "set": 0, "binding": 0, "descriptor": "uniform_buffer",
      "stages": ["vertex"] }
  ],
  "uniform_blocks": [
    { "name": "Globals", "binding": 0, "size": 256, "members": [
      { "name": "g_Bones", "offset": 0, "size": 256, "array_count": 4, "array_stride": 48 }
    ] }
  ],
  "vertex_inputs": [
    { "name": "a_Position", "location": 0, "format": "r32g32b32_sfloat" },
    { "name": "a_BlendIndices", "location": 1, "format": "r32g32b32a32_uint" },
    { "name": "a_BlendWeights", "location": 2, "format": "r32g32b32a32_sfloat" },
    { "name": "a_TexCoord", "location": 3, "format": "r32g32_sfloat" }
  ],
  "active_texture_slots": []
})";

std::shared_ptr<SceneMetalProgram> TranslatedProgram(std::string_view reflection = kReflectionJson)
{
    auto program             = std::make_shared<SceneMetalProgram>();
    program->reflection_json = std::string(reflection);
    program->stages.push_back(SceneMetalStage {
        .kind             = SceneMetalStageKind::Vertex,
        .source           = "vertex void main_() {}",
        .entry_point      = "main_",
        .language_version = "2.0",
        .bindings         = { SceneMetalBinding { "Globals", 0, 0, SceneMetalSlotKind::Buffer, 0 } },
    });
    program->stages.push_back(SceneMetalStage {
        .kind             = SceneMetalStageKind::Fragment,
        .source           = "fragment void main_() {}",
        .entry_point      = "main_",
        .language_version = "2.0",
        .bindings =
            {
                SceneMetalBinding { "Globals", 0, 0, SceneMetalSlotKind::Buffer, 0 },
                SceneMetalBinding { "g_Texture0", 0, 1, SceneMetalSlotKind::Texture, 1 },
                SceneMetalBinding { "_we_Sampler_g_Texture0", 0, 2, SceneMetalSlotKind::Sampler,
                                    2 },
            },
    });
    return program;
}

std::shared_ptr<SceneMetalProgram> FailedProgram()
{
    auto program   = std::make_shared<SceneMetalProgram>();
    program->error = "naga msl write failed";
    return program;
}

/// A minimal but complete two-dimensional image scene: one ortho camera, one
/// node, one card mesh, one material with a translated shader and one image.
struct ImageScene
{
    Scene                         scene;
    std::shared_ptr<SceneCamera>  global;
    std::shared_ptr<SceneCamera>  global_perspective;
    std::shared_ptr<SceneNode>    node;
    std::shared_ptr<SceneMesh>    mesh;

    ImageScene()
    {
        scene.scene_id = "metal-test-scene";
        global         = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
        global_perspective = std::make_shared<SceneCamera>(16.0f / 9.0f, 0.01f, 1000.0f, 50.0f);
        scene.cameras["global"]             = global;
        scene.cameras["global_perspective"] = global_perspective;
        scene.activeCamera                  = global.get();

        scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
            .width  = 1920,
            .height = 1080,
        };
        scene.textures["materials/card.tex"] = SceneTexture { .url = "materials/card.tex" };

        SceneMaterial material;
        material.name     = "materials/card";
        material.textures = { "materials/card.tex" };
        material.blenmode = BlendMode::Translucent;
        material.customShader.shader                 = std::make_shared<SceneShader>();
        material.customShader.shader->name           = "genericimage2";
        material.customShader.shader->metal_program  = TranslatedProgram();

        mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(std::move(material));
        node = std::make_shared<SceneNode>();
        node->AddMesh(mesh);
        scene.sceneGraph->AppendChild(node);
    }

    SceneMaterial& material() { return *mesh->MaterialSlots().front(); }
};

std::string RejectionFor(ImageScene& fixture)
{
    return EvaluateMetalSupport(fixture.scene).failure_reason;
}

/// The mesh shape the particle generator writes into: one dynamic vertex
/// stream sized for `count` quads and one index stream, both empty until the
/// first emission.
std::shared_ptr<SceneMesh> ParticleMesh(std::string_view shader_name, std::size_t count = 64)
{
    auto mesh = std::make_shared<SceneMesh>(MeshUpdate::PerFrame);
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_TEXCOORDVEC4), VertexType::FLOAT4 },
        { std::string(WE_IN_COLOR), VertexType::FLOAT4 },
    };
    mesh->AddVertexArray(SceneVertexArray(attributes, count * 4));
    mesh->AddIndexArray(SceneIndexArray(count));
    // What `SetParticleMesh` marks: the sprite-particle generator owns this
    // vertex stream. Rope and text meshes never carry it.
    if (shader_name != "text") mesh->GetVertexArray(0).SetOption(WE_PRENDER_SPRITE, true);

    SceneMaterial material;
    material.name     = std::string(shader_name);
    material.textures = { "materials/card.tex" };
    material.blenmode = BlendMode::Additive;
    material.customShader.shader                = std::make_shared<SceneShader>();
    material.customShader.shader->name          = std::string(shader_name);
    material.customShader.shader->metal_program = TranslatedProgram();
    mesh->AddMaterial(std::move(material));
    return mesh;
}

/// A static skinned card: position, blend indices, blend weights, texcoord.
/// Deformation lives in the author's vertex shader, so the mesh itself is
/// not rewritten per frame.
std::shared_ptr<SceneMesh> SkinnedMesh(std::string_view reflection = kBonesReflectionJson)
{
    auto mesh = std::make_shared<SceneMesh>();
    std::vector<SceneVertexArray::SceneVertexAttribute> attributes {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_BLENDINDICES), VertexType::UINT4 },
        { std::string(WE_IN_BLENDWEIGHTS), VertexType::FLOAT4 },
        { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 },
    };
    mesh->AddVertexArray(SceneVertexArray(attributes, 4));

    SceneMaterial material;
    material.name     = "materials/card";
    material.textures = { "materials/card.tex" };
    material.blenmode = BlendMode::Translucent;
    material.customShader.shader                = std::make_shared<SceneShader>();
    material.customShader.shader->name          = "genericimage2";
    material.customShader.shader->metal_program = TranslatedProgram(reflection);
    mesh->AddMaterial(std::move(material));
    return mesh;
}

/// Attaches a particle layer to the scene the way the parser does: a node in
/// the graph carrying the dynamic mesh, plus an emitter entry in the particle
/// system, which on its own no longer decides anything.
void AttachParticleLayer(ImageScene& fixture, std::shared_ptr<SceneMesh> mesh)
{
    auto node = std::make_shared<SceneNode>();
    node->AddMesh(std::move(mesh));
    fixture.scene.sceneGraph->AppendChild(node);
    fixture.scene.paritileSys->subsystems.push_back(nullptr);
}

rg::TexNode::Desc TexDesc(const std::string& key)
{
    return rg::TexNode::Desc {
        .name = key,
        .key  = key,
        .type = IsSpecTex(key) ? rg::TexNode::TexType::Temp : rg::TexNode::TexType::Imported,
    };
}

/// One author draw, shaped the way `sceneToRenderGraph` shapes it: a spec-tex
/// input is marked as virtually written, which is what orders a reader before a
/// later real writer of the same key.
void AddDraw(rg::RenderGraph& graph, const std::string& output,
             const std::vector<std::string>& inputs)
{
    graph.addPass<rg::DrawPass>(
        "draw", rg::PassNode::Type::CustomShader,
        [&output, &inputs](rg::RenderGraphBuilder& builder, rg::DrawPass::Desc& desc) {
            desc.output = output;
            for (const auto& input : inputs) {
                auto* node = builder.createTexNode(TexDesc(input));
                if (IsSpecTex(input)) builder.markVirtualWrite(node);
                builder.read(node);
                desc.textures.push_back(std::string(node->key()));
            }
            builder.write(builder.createTexNode(TexDesc(output), true));
        });
}

void AddCopy(rg::RenderGraph& graph, const std::string& source, const std::string& destination)
{
    graph.addPass<rg::CopyPass>(
        "copy", rg::PassNode::Type::Copy,
        [&source, &destination](rg::RenderGraphBuilder& builder, rg::CopyPass::Desc& desc) {
            auto* in  = builder.createTexNode(TexDesc(source));
            auto* out = builder.createTexNode(TexDesc(destination), true);
            builder.read(in);
            builder.write(out);
            desc.src = std::string(in->key());
            desc.dst = std::string(out->key());
        });
}

} // namespace

// ---------------------------------------------------------------------------
// Capability gate

TEST(MetalCapability, AcceptsAMinimalTwoDimensionalImageScene)
{
    ImageScene fixture;
    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
    EXPECT_TRUE(selection.failure_reason.empty());
    EXPECT_FALSE(selection.failed());
}

TEST(MetalCapability, AnUnusedPerspectiveCameraDoesNotRejectTheScene)
{
    // Every parsed scene carries `global_perspective`. It is not a reason to
    // refuse Native Metal unless a layer actually draws through it -- and even
    // then only the rest of the gate decides.
    ImageScene fixture;
    ASSERT_NE(fixture.scene.cameras["global_perspective"], nullptr);
    ASSERT_TRUE(fixture.scene.cameras["global_perspective"]->IsPerspective());
    ASSERT_EQ(fixture.scene.activeCamera, fixture.global.get());
    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
}

TEST(MetalCapability, ASupportedLayerWithAPerspectiveCameraIsAccepted)
{
    ImageScene fixture;
    fixture.node->SetCamera("global_perspective");
    ASSERT_NE(fixture.scene.activeCamera, fixture.global_perspective.get());
    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
}

TEST(MetalCapability, AnActivePerspectiveCameraIsAcceptedForSupportedLayers)
{
    ImageScene fixture;
    fixture.scene.activeCamera = fixture.global_perspective.get();
    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
}

TEST(MetalCapability, ASpriteParticleLayerWithAPerspectiveCameraIsAccepted)
{
    ImageScene fixture;
    auto       mesh = ParticleMesh("genericparticle");
    auto       node = std::make_shared<SceneNode>();
    node->AddMesh(std::move(mesh));
    node->SetCamera("global_perspective");
    fixture.scene.sceneGraph->AppendChild(node);
    fixture.scene.paritileSys->subsystems.push_back(nullptr);
    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
}

TEST(MetalCapability, EveryUnsupportedConstructHasItsOwnReason)
{
    std::vector<std::pair<std::string, std::string>> reasons;

    {
        // A sheet that is also a video would need both the uploaded-image and
        // the decoded-frame path at once.
        ImageScene fixture;
        fixture.scene.textures["sheet.tex"] = SceneTexture {
            .url = "sheet.tex", .isVideo = true, .isSprite = true
        };
        reasons.emplace_back("video sprite sheet", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.material().customShader.shader->metal_program = FailedProgram();
        reasons.emplace_back("untranslatable shader", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.material().customShader.shader->metal_program =
            TranslatedProgram(kBonesReflectionJson);
        reasons.emplace_back("puppet on card mesh", RejectionFor(fixture));
    }
    {
        ImageScene fixture;
        fixture.node->AddMesh(SkinnedMesh(kBonesStride48ReflectionJson));
        reasons.emplace_back("puppet stride 48", RejectionFor(fixture));
    }
    {
        // Never translated, because the preference was off when the scene was
        // parsed. That is not a fault in the author's shader and must not be
        // reported as one.
        ImageScene fixture;
        fixture.material().customShader.shader->metal_program = nullptr;
        reasons.emplace_back("never attempted", RejectionFor(fixture));
    }

    for (const auto& [construct, reason] : reasons) {
        EXPECT_FALSE(reason.empty()) << construct << " was accepted";
    }
    for (std::size_t i = 0; i < reasons.size(); ++i) {
        for (std::size_t j = i + 1; j < reasons.size(); ++j) {
            EXPECT_NE(reasons[i].second, reasons[j].second)
                << reasons[i].first << " and " << reasons[j].first << " share a reason";
        }
    }

    // The two that are most easily confused, spelled out.
    const auto untranslatable =
        std::find_if(reasons.begin(), reasons.end(),
                     [](const auto& entry) { return entry.first == "untranslatable shader"; });
    const auto never_attempted =
        std::find_if(reasons.begin(), reasons.end(),
                     [](const auto& entry) { return entry.first == "never attempted"; });
    ASSERT_NE(untranslatable, reasons.end());
    ASSERT_NE(never_attempted, reasons.end());
    EXPECT_NE(untranslatable->second, never_attempted->second);
}

TEST(MetalCapability, AcceptsAPlainSpriteSheetTexture)
{
    // A sheet is one uploaded image whose frame rectangle reaches the shader as
    // a uniform, so there is nothing about it the draw path cannot do.
    ImageScene fixture;
    SpriteFrame first { .imageId = 0, .frametime = 0.1f, .width = 0.5f, .height = 0.5f };
    SpriteFrame second { .imageId = 0, .frametime = 0.1f, .x = 0.5f, .width = 0.5f,
                         .height = 0.5f };
    SceneTexture sheet { .url = "materials/card.tex", .isSprite = true };
    sheet.spriteAnim.AppendFrame(first);
    sheet.spriteAnim.AppendFrame(second);
    fixture.scene.textures["materials/card.tex"] = std::move(sheet);

    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
}

TEST(MetalCapability, AcceptsAStandardTwoDimensionalSpriteParticleLayer)
{
    // The simulation belongs to the shared runtime either way, and the geometry
    // it produces is whatever layout the parser built: nothing about a particle
    // layer is a reason to refuse the scene.
    ImageScene fixture;
    AttachParticleLayer(fixture, ParticleMesh("genericparticle"));

    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
}

TEST(MetalCapability, AcceptsASkinnedMeshWithAPuppetShader)
{
    ImageScene fixture;
    fixture.node->AddMesh(SkinnedMesh(kBonesReflectionJson));

    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
    EXPECT_TRUE(selection.failure_reason.empty());
}

namespace
{

/// A layer under an effect chain, the way the parser leaves a puppet: the
/// layer's own node draws a plain card, the chain's nodes carry only a material
/// until the render graph resolves them, and the puppet's geometry waits in the
/// chain's final mesh. `skinned_node` picks which of the two effect nodes holds
/// the skinning material; only the second is the one the final mesh is resolved
/// onto.
struct PuppetEffectChain
{
    ImageScene                   fixture;
    std::shared_ptr<SceneCamera> camera;

    PuppetEffectChain(std::size_t skinned_node, bool final_mesh_has_weights)
    {
        camera = std::make_shared<SceneCamera>(1920, 1080, -1.0f, 1.0f);
        fixture.scene.cameras["layer"] = camera;
        fixture.node->SetCamera("layer");

        auto layer = std::make_shared<SceneImageEffectLayer>(
            fixture.node.get(), 1920.0f, 1080.0f, "_rt_effect_pingpong_a_0",
            "_rt_effect_pingpong_b_0");
        auto effect = std::make_shared<SceneImageEffect>();
        for (std::size_t i = 0; i < 2; ++i) {
            SceneMaterial material;
            material.name     = "materials/card";
            material.textures = { "materials/card.tex" };
            material.customShader.shader                = std::make_shared<SceneShader>();
            material.customShader.shader->name          = "genericimage2";
            material.customShader.shader->metal_program =
                TranslatedProgram(i == skinned_node ? kBonesReflectionJson : kReflectionJson);
            auto mesh = std::make_shared<SceneMesh>();
            mesh->AddMaterial(std::move(material));
            auto node = std::make_shared<SceneNode>();
            node->AddMesh(mesh);
            effect->nodes.push_back({ "_rt_effect_pingpong_b_0", node });
        }
        layer->AddEffect(effect);
        if (final_mesh_has_weights) {
            layer->FinalMesh().ChangeMeshDataFrom(*SkinnedMesh());
        }
        camera->AttatchImgEffect(layer);
    }
};

} // namespace

TEST(MetalCapability, APuppetUnderAnEffectChainIsJudgedByTheMeshTheChainResolvesOntoIt)
{
    // The gate runs before the render graph exists, so the chain's last node
    // has no streams of its own yet. Refusing it for that would refuse every
    // puppet that has an effect; what it will be drawn with is the final mesh.
    PuppetEffectChain resolved(/*skinned_node=*/1, /*final_mesh_has_weights=*/true);
    const auto        selection = EvaluateMetalSupport(resolved.fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;

    // A final mesh without bone weights leaves the skinning shader nothing to read.
    PuppetEffectChain plain_final(1, false);
    EXPECT_EQ(RejectionFor(plain_final.fixture),
              "a puppet shader is bound to a mesh without bone weights");

    // Any other node of the chain is given the plain full-target quad, so the
    // final mesh does not vouch for a skinning shader sitting there.
    PuppetEffectChain wrong_node(0, true);
    EXPECT_EQ(RejectionFor(wrong_node.fixture),
              "a puppet shader is bound to a mesh without bone weights");
}

TEST(MetalCapability, ASceneWithLightsIsAccepted)
{
    // Lighting is the author's shader reading uniforms the shared value updater
    // writes for either backend; a light on its own asks nothing else of it.
    ImageScene fixture;
    fixture.scene.lights.push_back(
        std::make_unique<SceneLight>(linalg::Vector3f { 1.0f, 1.0f, 1.0f }, 100.0f, 1.0f));
    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;
}

TEST(MetalCapability, AnImageEffectChainIsNoLongerRejectedBeforeTheGraphExists)
{
    // An effect chain is ordinary multi-pass work now. Whether its particular
    // shape can be executed is a question about the lowered graph, and refusing
    // the whole class here would answer it for scenes that are perfectly
    // drawable.
    ImageScene fixture;
    fixture.global->AttatchImgEffect(std::make_shared<SceneImageEffectLayer>(
        fixture.node.get(), 1920.0f, 1080.0f, "_rt_effect_pingpong_a_0",
        "_rt_effect_pingpong_b_0"));
    const auto selection = EvaluateMetalSupport(fixture.scene);
    EXPECT_FALSE(selection.failed()) << selection.failure_reason;

    ImageScene post;
    post.scene.post_processes.push_back(std::make_shared<ScenePostProcess>());
    const auto post_selection = EvaluateMetalSupport(post.scene);
    EXPECT_FALSE(post_selection.failed())
        << post_selection.failure_reason;
}

TEST(MetalGraph, SequentialEffectPassesAreAccepted)
{
    ImageScene       fixture;
    rg::RenderGraph  graph;
    AddDraw(graph, "_rt_effect_pingpong_a_0", { "materials/card.tex" });
    AddDraw(graph, "_rt_effect_pingpong_b_0", { "_rt_effect_pingpong_a_0" });
    AddDraw(graph, std::string(SpecTex_Default), { "_rt_effect_pingpong_b_0" });

    EXPECT_EQ(MetalGraphRejection(fixture.scene, graph), "");
}

TEST(MetalGraph, ALinkTextureProducedEarlierInTheSameFrameIsNotFeedback)
{
    // One layer's output, copied into a link texture and sampled by another
    // layer later in the very same frame. Every pixel it reads was produced by
    // this frame's work, so there is nothing historical about it.
    ImageScene      fixture;
    rg::RenderGraph graph;
    AddDraw(graph, "_rt_imageLayerComposite_1", { "materials/card.tex" });
    AddCopy(graph, "_rt_imageLayerComposite_1", "_rt_link_1");
    AddDraw(graph, std::string(SpecTex_Default), { "_rt_link_1" });

    EXPECT_EQ(MetalGraphRejection(fixture.scene, graph), "");
}

TEST(MetalGraph, ReadingATargetThatIsOnlyWrittenLaterIsAcceptedAsHistory)
{
    // The mip-mapped frame buffer: sampled by a layer, then filled from the
    // frame's own output afterwards. What the layer samples is the previous
    // frame's picture, which this backend keeps in the target's own image.
    ImageScene      fixture;
    rg::RenderGraph graph;
    AddDraw(graph, std::string(SpecTex_Default),
            { "materials/card.tex", std::string(WE_MIP_MAPPED_FRAME_BUFFER) });
    AddCopy(graph, std::string(SpecTex_Default), std::string(WE_MIP_MAPPED_FRAME_BUFFER));

    EXPECT_EQ(MetalGraphRejection(fixture.scene, graph), "");
}

TEST(MetalCapability, RecognisedPassKindsAreClassifiedAndAnythingElseFallsBack)
{
    EXPECT_EQ(ClassifyMetalPassKind(static_cast<int>(rg::PassNode::Type::CustomShader)),
              MetalPassKind::CustomShader);
    EXPECT_EQ(ClassifyMetalPassKind(static_cast<int>(rg::PassNode::Type::Copy)),
              MetalPassKind::Copy);
    EXPECT_EQ(ClassifyMetalPassKind(static_cast<int>(rg::PassNode::Type::Clear)),
              MetalPassKind::Clear);
    EXPECT_EQ(ClassifyMetalPassKind(static_cast<int>(rg::PassNode::Type::Virtual)),
              MetalPassKind::Virtual);

    // A pass kind added after this build. It has to fall back, not be skipped
    // and not be drawn as something it resembles.
    const int unknown_kind = static_cast<int>(rg::PassNode::Type::Virtual) + 1;
    EXPECT_EQ(ClassifyMetalPassKind(unknown_kind), MetalPassKind::Unsupported);
    EXPECT_EQ(ClassifyMetalPassKind(-1), MetalPassKind::Unsupported);
}

// ---------------------------------------------------------------------------
// Blend mapping

TEST(MetalBlend, EachModeProducesTheAuthoredFactors)
{
    {
        const auto state = ToMetalBlendState(BlendMode::Disable);
        EXPECT_FALSE(state.blending_enabled);
        EXPECT_FALSE(state.alpha_to_coverage);
    }
    {
        // An opaque replace. Not Porter-Duff source-over, despite the name:
        // source-over here would composite every "normal" layer wrongly.
        const auto state = ToMetalBlendState(BlendMode::Normal);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.source_rgb, MetalBlendFactor::One);
        EXPECT_EQ(state.destination_rgb, MetalBlendFactor::Zero);
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::One);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::Zero);
        EXPECT_NE(state.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_NE(state.destination_rgb, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_FALSE(state.alpha_to_coverage);
    }
    {
        const auto state = ToMetalBlendState(BlendMode::Translucent);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_rgb, MetalBlendFactor::OneMinusSourceAlpha);
        // Coverage is As + Ad(1 - As), so the source alpha factor is ONE.
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::One);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_FALSE(state.alpha_to_coverage);
    }
    {
        const auto state = ToMetalBlendState(BlendMode::Additive);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_rgb, MetalBlendFactor::One);
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::One);
        EXPECT_FALSE(state.alpha_to_coverage);
    }
    {
        // Kept samples are written at full strength; blending as well would
        // dim every partially covered texel a second time.
        const auto state = ToMetalBlendState(BlendMode::AlphaToCoverage, 4);
        EXPECT_FALSE(state.blending_enabled);
        EXPECT_TRUE(state.alpha_to_coverage);
        EXPECT_EQ(ToMetalBlendState(BlendMode::AlphaToCoverage, 1),
                  ToMetalBlendState(BlendMode::Translucent));
    }

    for (const auto mode : { BlendMode::Disable, BlendMode::Normal, BlendMode::Translucent,
                             BlendMode::Additive, BlendMode::AlphaToCoverage }) {
        const auto state = ToMetalBlendState(mode);
        EXPECT_EQ(state.rgb_operation, MetalBlendOperation::Add);
        EXPECT_EQ(state.alpha_operation, MetalBlendOperation::Add);
    }
}

TEST(MetalBlend, SceneDrawsAreRasterizedWithoutCulling)
{
    // Wallpaper Engine rasterizes scene draws without culling, and any
    // clip-space fold reverses triangle winding. Culling here would silently
    // eat half a scene.
    EXPECT_EQ(kSceneCullMode, MetalCullMode::None);
}

// ---------------------------------------------------------------------------
// Pipeline cache keys

TEST(MetalPipelineKey, DistinguishesBlendModesAndTargetFormats)
{
    MetalPipelineKey base {
        .program_id       = 0x1234,
        .vertex_layout_id = 0x5678,
        .blend            = ToMetalBlendState(BlendMode::Translucent),
        .color_format     = MetalPixelFormat::RGBA8Unorm,
        .sample_count     = 1,
        .write_alpha      = true,
    };

    auto additive  = base;
    additive.blend = ToMetalBlendState(BlendMode::Additive);
    auto normal    = base;
    normal.blend   = ToMetalBlendState(BlendMode::Normal);
    auto bgra         = base;
    bgra.color_format = MetalPixelFormat::BGRA8Unorm;
    auto srgb         = base;
    srgb.color_format = MetalPixelFormat::RGBA8Unorm_sRGB;
    auto opaque        = base;
    opaque.write_alpha = false;
    auto depth              = base;
    depth.depth_format      = MetalPixelFormat::Depth32Float;
    depth.depth_test        = true;
    depth.depth_compare     = MetalDepthCompare::LessEqual;
    auto depth_write        = depth;
    depth_write.depth_write = true;

    const MetalPipelineKeyHash hash;
    for (const auto& other : { additive, normal, bgra, srgb, opaque, depth, depth_write }) {
        EXPECT_FALSE(base == other);
        EXPECT_NE(hash(base), hash(other));
    }

    auto same = base;
    EXPECT_TRUE(base == same);
    EXPECT_EQ(hash(base), hash(same));
}

// ---------------------------------------------------------------------------
// Clip space

TEST(MetalProjection, LandsAuthorGeometryOnTheSameWindowPixelAsTheFlippedViewportConvention)
{
    // The reference presentation viewport: a letterboxed region written with a
    // negative height, the convention that agrees with the coordinate system
    // the authored shaders use.
    const auto layout = ComputeWallpaperScalingLayout(WallpaperScalingMode::FIT, 1920, 1080, 1000,
                                                      1000, 1.0, 1.0);
    const FlippedViewportBox flipped_viewport {
        .x      = static_cast<double>(layout.viewport_px.x),
        .y      = static_cast<double>(layout.viewport_px.y + layout.viewport_px.height),
        .width  = static_cast<double>(layout.viewport_px.width),
        .height = -static_cast<double>(layout.viewport_px.height),
    };
    ASSERT_LT(flipped_viewport.height, 0.0) << "the reference viewport must be the flipped one";
    const auto metal_viewport = ToMetalViewport(flipped_viewport);
    EXPECT_GT(metal_viewport.height, 0.0) << "Metal has no negative-height viewport";

    // The scene's own camera, built the way the parser builds it.
    SceneCamera camera(1920, 1080, -1.0, 1.0);
    const linalg::Matrix4d reference_vp = camera.GetViewProjectionMatrix();
    const linalg::Matrix4d metal_vp         = MetalViewProjection(reference_vp);

    // The author's canvas corners plus its centre and an off-centre point, so a
    // sign error cannot cancel against symmetry.
    const std::array<linalg::Vector4d, 5> author_points {
        linalg::Vector4d { -960.0, -540.0, 0.0, 1.0 }, linalg::Vector4d { -960.0, 540.0, 0.0, 1.0 },
        linalg::Vector4d { 960.0, -540.0, 0.0, 1.0 },  linalg::Vector4d { 960.0, 540.0, 0.0, 1.0 },
        linalg::Vector4d { -300.0, 210.0, 0.0, 1.0 },
    };

    for (const auto& point : author_points) {
        const linalg::Vector4d reference_clip = reference_vp * point;
        const linalg::Vector4d metal_clip         = metal_vp * point;

        const auto want = ClipToWindowFlipped(reference_clip, flipped_viewport);
        const auto got  = ClipToWindowMetal(metal_clip, metal_viewport);
        EXPECT_NEAR(want.x(), got.x(), 1e-9);
        EXPECT_NEAR(want.y(), got.y(), 1e-9);

        // Both APIs clip depth to [0, 1] and `Ortho` already maps into it, so
        // no depth remap is folded either. Asserted, not assumed.
        EXPECT_TRUE(MetalDepthInClipRange(metal_clip.z(), metal_clip.w()));
    }

    // A y-flip inserted anywhere in the fold is exactly the regression this
    // guards: with it, the top and bottom canvas edges swap window rows.
    linalg::Matrix4d flipped_fold = linalg::Matrix4d::Identity();
    flipped_fold(1, 1)           = -1.0;
    const linalg::Matrix4d wrong_vp = flipped_fold * metal_vp;
    const linalg::Vector4d top      = author_points[1];
    const auto correct = ClipToWindowMetal(metal_vp * top, metal_viewport);
    const auto wrong   = ClipToWindowMetal(wrong_vp * top, metal_viewport);
    EXPECT_GT(std::abs(correct.y() - wrong.y()), 1.0)
        << "a spurious clip-space flip has to move the image";
}

TEST(MetalProjection, NegativeHeightViewportsCoverTheSameWindowRows)
{
    const FlippedViewportBox negative { .x = 12.0, .y = 40.0 + 200.0, .width = 320.0,
                                       .height = -200.0 };
    const auto              metal = ToMetalViewport(negative);
    EXPECT_DOUBLE_EQ(metal.origin_x, 12.0);
    EXPECT_DOUBLE_EQ(metal.origin_y, 40.0);
    EXPECT_DOUBLE_EQ(metal.width, 320.0);
    EXPECT_DOUBLE_EQ(metal.height, 200.0);
}

TEST(MetalProjection, PerspectiveUsesFovAspectNearFarAndAHomogeneousDivide)
{
    // Same placement the parser uses for `global_perspective`: one metre in
    // front of the authored canvas, far plane well beyond it.
    SceneCamera camera(16.0f / 9.0f, 0.1f, 10000.0f, 50.0f);
    auto        node = std::make_shared<SceneNode>(
        linalg::Vector3f { 0.0f, 0.0f, 1000.0f }, linalg::Vector3f { 1.0f, 1.0f, 1.0f },
        linalg::Vector3f::Zero());
    camera.AttatchNode(node);

    const linalg::Matrix4d vp = camera.GetViewProjectionMatrix();
    const linalg::Vector4d centre = vp * linalg::Vector4d { 0.0, 0.0, 0.0, 1.0 };
    ASSERT_NE(centre.w(), 0.0);
    EXPECT_GT(std::abs(centre.w() - 1.0), 1e-6) << "a perspective projection must not be affine";
    EXPECT_NEAR(centre.x() / centre.w(), 0.0, 1e-9);
    EXPECT_NEAR(centre.y() / centre.w(), 0.0, 1e-9);
    EXPECT_TRUE(MetalDepthInClipRange(centre.z(), centre.w()));

    const linalg::Vector4d off = vp * linalg::Vector4d { 100.0, 0.0, 0.0, 1.0 };
    const double          ndc_x = off.x() / off.w();

    SceneCamera tighter(16.0f / 9.0f, 0.1f, 10000.0f, 20.0f);
    tighter.AttatchNode(node);
    const linalg::Vector4d tight =
        tighter.GetViewProjectionMatrix() * linalg::Vector4d { 100.0, 0.0, 0.0, 1.0 };
    EXPECT_GT(std::abs(tight.x() / tight.w()), std::abs(ndc_x))
        << "a narrower FOV must enlarge the same world offset";

    // 0.05 in front of the camera, nearer than the 0.1 near plane.
    const linalg::Vector4d close = vp * linalg::Vector4d { 0.0, 0.0, 999.95, 1.0 };
    EXPECT_FALSE(MetalDepthInClipRange(close.z(), close.w()))
        << "a point in front of the near plane must fail the clip range";

    const linalg::Matrix4d metal_vp = MetalViewProjection(vp);
    EXPECT_TRUE(metal_vp.isApprox(vp, 1e-12))
        << "the Metal clip-space fold is the identity; a flip or scale here is a second correction";
}

TEST(MetalProjection, UnprojectingNdcHitsTheLayerPlane)
{
    SceneCamera camera(16.0f / 9.0f, 0.1f, 10000.0f, 50.0f);
    auto        cam_node = std::make_shared<SceneNode>(
        linalg::Vector3f { 0.0f, 0.0f, 1000.0f }, linalg::Vector3f { 1.0f, 1.0f, 1.0f },
        linalg::Vector3f::Zero());
    camera.AttatchNode(cam_node);

    SceneNode layer(linalg::Vector3f::Zero(), linalg::Vector3f { 1.0f, 1.0f, 1.0f },
                    linalg::Vector3f::Zero());
    const auto centre = IntersectNdcWithNodePlane(camera, layer, 0.0, 0.0);
    ASSERT_TRUE(centre.has_value());
    EXPECT_NEAR(centre->x(), 0.0, 1e-6);
    EXPECT_NEAR(centre->y(), 0.0, 1e-6);
    EXPECT_NEAR(centre->z(), 0.0, 1e-6);

    const linalg::Vector4d world { 40.0, -15.0, 0.0, 1.0 };
    const linalg::Vector4d clip = camera.GetViewProjectionMatrix() * world;
    ASSERT_NE(clip.w(), 0.0);
    const auto hit =
        IntersectNdcWithNodePlane(camera, layer, clip.x() / clip.w(), clip.y() / clip.w());
    ASSERT_TRUE(hit.has_value());
    EXPECT_NEAR(hit->x(), 40.0, 1e-4);
    EXPECT_NEAR(hit->y(), -15.0, 1e-4);
    EXPECT_NEAR(hit->z(), 0.0, 1e-4);

    SceneNode rotated(linalg::Vector3f { 0.0f, 0.0f, 0.0f }, linalg::Vector3f { 1.0f, 1.0f, 1.0f },
                      linalg::Vector3f { 0.4f, 0.0f, 0.0f });
    const auto rotated_hit = IntersectNdcWithNodePlane(camera, rotated, 0.0, 0.0);
    ASSERT_TRUE(rotated_hit.has_value());
    EXPECT_NEAR(rotated_hit->z(), 0.0, 1e-6);
}

TEST(MetalProjection, TheLayerPlaneIsWhereTheLayerIsDrawn)
{
    SceneCamera camera(16.0f / 9.0f, 0.1f, 10000.0f, 50.0f);
    auto        cam_node = std::make_shared<SceneNode>(
        linalg::Vector3f { 0.0f, 0.0f, 1000.0f }, linalg::Vector3f { 1.0f, 1.0f, 1.0f },
        linalg::Vector3f::Zero());
    camera.AttatchNode(cam_node);

    // A layer a screen anchor draws 25 right and 10 down of where its node is: the point
    // under the cursor is that far from the layer's own origin.
    SceneNode layer(linalg::Vector3f::Zero(), linalg::Vector3f { 2.0f, 2.0f, 1.0f },
                    linalg::Vector3f::Zero());
    layer.SetDrawOffset(linalg::Vector3f { 25.0f, -10.0f, 0.0f });
    const linalg::Vector4d world { 40.0, -15.0, 0.0, 1.0 };
    const linalg::Vector4d clip = camera.GetViewProjectionMatrix() * world;
    ASSERT_NE(clip.w(), 0.0);
    const auto hit =
        IntersectNdcWithNodePlane(camera, layer, clip.x() / clip.w(), clip.y() / clip.w());
    ASSERT_TRUE(hit.has_value());
    // (40 - 25, -15 + 10) in the world, in the layer's own plane at scale 2.
    EXPECT_NEAR(hit->x(), 7.5, 1e-4);
    EXPECT_NEAR(hit->y(), -2.5, 1e-4);
}

TEST(MetalProjection, CameraAxesFollowTheAttachedNode)
{
    SceneCamera camera(16.0f / 9.0f, 0.1f, 1000.0f, 50.0f);
    auto        node = std::make_shared<SceneNode>(
        linalg::Vector3f { 10.0f, 20.0f, 30.0f }, linalg::Vector3f { 1.0f, 1.0f, 1.0f },
        linalg::Vector3f { 0.0f, static_cast<float>(linalg::Pi / 2.0), 0.0f });
    camera.AttatchNode(node);
    const auto axes = camera.GetAxes();
    EXPECT_NEAR(axes.right.x(), 0.0, 1e-5);
    EXPECT_NEAR(std::abs(axes.right.z()), 1.0, 1e-5);
    EXPECT_NEAR(axes.up.y(), 1.0, 1e-5);
}

// ---------------------------------------------------------------------------
// Reflection

TEST(MetalShaderReflection, ReadsTheUniformLayoutAndVertexInputs)
{
    MetalShaderReflection reflection;
    std::string           error;
    ASSERT_TRUE(ParseMetalShaderReflection(kReflectionJson, reflection, &error)) << error;

    ASSERT_NE(reflection.uniformBlock(), nullptr);
    EXPECT_EQ(reflection.uniformBlock()->size, 128u);
    ASSERT_TRUE(reflection.hasMember("g_ModelViewProjectionMatrix"));
    EXPECT_EQ(reflection.member("g_ModelViewProjectionMatrix")->offset, 0u);
    EXPECT_EQ(reflection.member("g_Alpha")->offset, 64u);
    EXPECT_FALSE(reflection.hasMember("g_Bones"));
    ASSERT_EQ(reflection.inputs.size(), 2u);
    EXPECT_EQ(reflection.inputs[0].name, "a_Position");
    EXPECT_EQ(reflection.inputs[0].format, "r32g32b32_sfloat");
    EXPECT_EQ(reflection.descriptors.size(), 3u);
}

TEST(MetalShaderReflection, RefusesAResourceOutsideDescriptorSetZero)
{
    constexpr std::string_view bad = R"({
      "descriptor_bindings": [
        { "name": "Globals", "set": 1, "binding": 0, "descriptor": "uniform_buffer" }
      ]
    })";
    MetalShaderReflection reflection;
    std::string           error;
    EXPECT_FALSE(ParseMetalShaderReflection(bad, reflection, &error));
    EXPECT_FALSE(error.empty());
}

// ---------------------------------------------------------------------------
// Device-dependent

#ifdef __APPLE__
TEST(MetalDevice, TranslatedShaderConventionsAreWhatTheBackendBindsAgainst)
{
    if (! MetalDeviceAvailable()) {
        GTEST_SKIP() << "no Metal device on this machine; the device-backed checks did not run";
    }

    // The two conventions the backend depends on and cannot re-derive: the
    // entry point is renamed, and a resource's Metal slot is the GLSL
    // binding index within its own argument-table namespace.
    const auto program = TranslatedProgram();
    for (const auto& stage : program->stages) {
        EXPECT_EQ(stage.entry_point, "main_");
        EXPECT_NE(stage.entry_point, "main");
        for (const auto& binding : stage.bindings) {
            EXPECT_EQ(binding.set, 0u);
            EXPECT_EQ(binding.slot, binding.binding);
        }
    }
}
#endif
