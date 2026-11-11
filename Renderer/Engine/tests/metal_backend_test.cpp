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
        // Wallpaper Engine blends alpha with the colour's factors
        // (sub_140099F60): As * As + Ad(1 - As).
        const auto state = ToMetalBlendState(BlendMode::Translucent);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_rgb, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_FALSE(state.alpha_to_coverage);
        // A layer's own picture into its composite keeps As + Ad(1 - As).
        const auto over = ToMetalBlendState(BlendMode::Translucent, AlphaBlendRule::SourceOver);
        EXPECT_EQ(over.source_rgb, MetalBlendFactor::SourceAlpha);
        EXPECT_EQ(over.destination_rgb, MetalBlendFactor::OneMinusSourceAlpha);
        EXPECT_EQ(over.source_alpha, MetalBlendFactor::One);
        EXPECT_EQ(over.destination_alpha, MetalBlendFactor::OneMinusSourceAlpha);
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
    for (const std::uint32_t samples : { 1u, 4u }) {
        // Kept samples are written at full strength; blending as well would dim every
        // partially covered texel a second time. One sample keeps the same state: Metal
        // thresholds coverage at half the alpha there, as Direct3D does for Wallpaper Engine
        // (`MetalSceneDraw.MetalSingleSampleAlphaToCoverageThresholdsAtHalf`).
        const auto state =
            ToMetalBlendState(BlendMode::AlphaToCoverage, AlphaBlendRule::Material, samples);
        EXPECT_FALSE(state.blending_enabled) << samples;
        EXPECT_TRUE(state.alpha_to_coverage) << samples;
    }

    for (const auto mode : { BlendMode::Disable, BlendMode::Normal, BlendMode::Translucent,
                             BlendMode::Additive, BlendMode::AlphaToCoverage }) {
        const auto state = ToMetalBlendState(mode);
        EXPECT_EQ(state.rgb_operation, MetalBlendOperation::Add);
        EXPECT_EQ(state.alpha_operation, MetalBlendOperation::Add);
    }
}

TEST(MetalBlend, AlphaMaxOnlyForBlendedModes)
{
    // The children of a layer without copybackground: BlendOpAlpha MAX with
    // ONE / ONE (sub_1401ECB20, flag 0x10 of sub_140099F60). The colour factors
    // stay the material's, and an unblended draw is left as it is.
    for (const auto mode : { BlendMode::Translucent, BlendMode::Additive }) {
        const auto plain = ToMetalBlendState(mode);
        const auto state = ToMetalBlendState(mode, AlphaBlendRule::Max);
        EXPECT_TRUE(state.blending_enabled);
        EXPECT_EQ(state.alpha_operation, MetalBlendOperation::Max);
        EXPECT_EQ(state.source_alpha, MetalBlendFactor::One);
        EXPECT_EQ(state.destination_alpha, MetalBlendFactor::One);
        EXPECT_EQ(state.rgb_operation, MetalBlendOperation::Add);
        EXPECT_EQ(state.source_rgb, plain.source_rgb);
        EXPECT_EQ(state.destination_rgb, plain.destination_rgb);
    }
    const auto normal = ToMetalBlendState(BlendMode::Normal, AlphaBlendRule::Max);
    EXPECT_EQ(normal, ToMetalBlendState(BlendMode::Normal));
    EXPECT_EQ(normal.alpha_operation, MetalBlendOperation::Add);
    EXPECT_EQ(normal.source_alpha, MetalBlendFactor::One);
    EXPECT_EQ(normal.destination_alpha, MetalBlendFactor::Zero);
    EXPECT_EQ(ToMetalBlendState(BlendMode::Disable, AlphaBlendRule::Max),
              ToMetalBlendState(BlendMode::Disable));
    EXPECT_EQ(ToMetalBlendState(BlendMode::AlphaToCoverage, AlphaBlendRule::Max, 4),
              ToMetalBlendState(BlendMode::AlphaToCoverage, AlphaBlendRule::Material, 4));
}

TEST(MetalBlend, MultiplyIsDestinationColourOverInverseSourceAlpha)
{
    // Device flag 0x100 (sub_14009B100) on a translucent draw: SrcBlend DEST_COLOR,
    // DestBlend INV_SRC_ALPHA, alpha ONE / ONE (sub_140099F60).
    const auto state = ToMetalBlendState(BlendMode::Multiply);
    EXPECT_TRUE(state.blending_enabled);
    EXPECT_FALSE(state.alpha_to_coverage);
    EXPECT_EQ(state.rgb_operation, MetalBlendOperation::Add);
    EXPECT_EQ(state.alpha_operation, MetalBlendOperation::Add);
    EXPECT_EQ(state.source_rgb, MetalBlendFactor::DestinationColor);
    EXPECT_EQ(state.destination_rgb, MetalBlendFactor::OneMinusSourceAlpha);
    EXPECT_EQ(state.source_alpha, MetalBlendFactor::One);
    EXPECT_EQ(state.destination_alpha, MetalBlendFactor::One);
    // Inside a layer without copybackground the alpha takes MAX as well.
    EXPECT_EQ(ToMetalBlendState(BlendMode::Multiply, AlphaBlendRule::Max).alpha_operation,
              MetalBlendOperation::Max);
}

TEST(MetalBlend, AMaterialsCullModeAppliesWhateverItsTargetHas)
{
    // A pass starts without culling; each draw takes its material's mode, with or
    // without depth, as WE culls a mirrored `cullmode normal` card on a 2D canvas.
    EXPECT_EQ(kSceneCullMode, MetalCullMode::None);
    EXPECT_EQ(SceneMetalCullMode(CullMode::None), MetalCullMode::None);
    EXPECT_EQ(SceneMetalCullMode(CullMode::Back), MetalCullMode::Back);
    EXPECT_EQ(SceneMetalCullMode(CullMode::Front), MetalCullMode::Front);
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

TEST(MetalShaderReflection, ReadsTheDeclaredTextureShapeAndAComparisonSampler)
{
    // The translator writes `dimension` for anything but a plain 2D texture and `comparison`
    // only for a comparison sampler; absent keys read as a 2D texture and an ordinary sampler.
    constexpr std::string_view json = R"({
      "descriptor_bindings": [
        { "name": "g_Texture0", "set": 0, "binding": 1, "descriptor": "sampled_image" },
        { "name": "g_Texture2", "set": 0, "binding": 2, "descriptor": "sampled_image", "dimension": "3d" },
        { "name": "g_Texture6", "set": 0, "binding": 3, "descriptor": "sampled_image", "dimension": "depth_2d" },
        { "name": "g_Texture1", "set": 0, "binding": 4, "descriptor": "sampled_image", "dimension": "2d_ms" },
        { "name": "_we_Sampler_g_Texture6", "set": 0, "binding": 5, "descriptor": "sampler", "comparison": true },
        { "name": "_we_Sampler_g_Texture0", "set": 0, "binding": 6, "descriptor": "sampler" }
      ]
    })";
    MetalShaderReflection reflection;
    std::string           error;
    ASSERT_TRUE(ParseMetalShaderReflection(json, reflection, &error)) << error;
    ASSERT_EQ(reflection.descriptors.size(), 6u);
    using Image = MetalDescriptorBinding::Image;
    EXPECT_EQ(reflection.descriptors[0].image, Image::D2);
    EXPECT_EQ(reflection.descriptors[1].image, Image::D3);
    EXPECT_EQ(reflection.descriptors[2].image, Image::Depth2D);
    EXPECT_EQ(reflection.descriptors[3].image, Image::D2Ms);
    EXPECT_TRUE(reflection.descriptors[4].comparison);
    EXPECT_FALSE(reflection.descriptors[5].comparison);
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

TEST(MetalMultisampling, ChoosesTheBestSupportedCountWithoutIncreasingTheRequest)
{
    EXPECT_EQ(SelectSceneSampleCount(0, 15), 1u);
    EXPECT_EQ(SelectSceneSampleCount(1, 15), 1u);
    EXPECT_EQ(SelectSceneSampleCount(2, 15), 2u);
    EXPECT_EQ(SelectSceneSampleCount(4, 15), 4u);
    EXPECT_EQ(SelectSceneSampleCount(8, 15), 8u);
    EXPECT_EQ(SelectSceneSampleCount(8, 1 | 4), 4u);
    EXPECT_EQ(SelectSceneSampleCount(4, 1 | 2), 2u);
    EXPECT_EQ(SelectSceneSampleCount(4, 1 | 8), 1u);
    EXPECT_EQ(SelectSceneSampleCount(8, 1), 1u);
}

// ---- a draw that writes every texel of its target

namespace
{

/// The effect card as the parser builds it: corners bottom-left, top-left, bottom-right,
/// top-right, two triangles sharing the top-left to bottom-right diagonal.
MetalQuad EffectCard(float half = 1.0f, float z = 0.0f)
{
    MetalQuad quad;
    quad.corners   = { { { -half, -half, z }, { -half, half, z }, { half, -half, z }, { half, half, z } } };
    quad.triangles = { { { 0, 2, 1 }, { 1, 2, 3 } } };
    return quad;
}

constexpr std::array<float, 16> kIdentity { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

} // namespace

TEST(MetalOverwrite, TheReflectionCarriesTheCoverageFactsOnlyWhenTheyAreThere)
{
    MetalShaderReflection reflection;
    std::string           error;
    ASSERT_TRUE(ParseMetalShaderReflection(
        R"({"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[],)"
        R"("vertex_position":{"input":"a_Position","matrix":"g_ModelViewProjectionMatrix"},"fragment_always_writes":true})",
        reflection, &error))
        << error;
    ASSERT_TRUE(reflection.vertex_position.has_value());
    EXPECT_EQ(reflection.vertex_position->input, "a_Position");
    EXPECT_EQ(reflection.vertex_position->matrix, "g_ModelViewProjectionMatrix");
    EXPECT_TRUE(reflection.fragment_always_writes);

    ASSERT_TRUE(ParseMetalShaderReflection(
        R"({"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[],)"
        R"("vertex_position":{"input":"a_Position"}})",
        reflection, &error))
        << error;
    ASSERT_TRUE(reflection.vertex_position.has_value());
    EXPECT_TRUE(reflection.vertex_position->matrix.empty());
    EXPECT_FALSE(reflection.fragment_always_writes);

    // A document of a compiler that knows nothing of them proves nothing.
    ASSERT_TRUE(ParseMetalShaderReflection(
        R"({"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[]})", reflection,
        &error))
        << error;
    EXPECT_FALSE(reflection.vertex_position.has_value());
    EXPECT_FALSE(reflection.fragment_always_writes);

    // Facts of the wrong shape prove nothing either, and do not fail the shader.
    ASSERT_TRUE(ParseMetalShaderReflection(
        R"({"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[],)"
        R"("vertex_position":{"input":7,"matrix":"g_ModelViewProjectionMatrix"},"fragment_always_writes":"yes"})",
        reflection, &error))
        << error;
    EXPECT_FALSE(reflection.vertex_position.has_value());
    EXPECT_FALSE(reflection.fragment_always_writes);
    ASSERT_TRUE(ParseMetalShaderReflection(
        R"({"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[],)"
        R"("vertex_position":{"matrix":"g_ModelViewProjectionMatrix"}})",
        reflection, &error))
        << error;
    EXPECT_FALSE(reflection.vertex_position.has_value());
}

TEST(MetalReflection, AMemberIsUnreadOnlyWhenTheCompilerSaysWhatIsRead)
{
    const std::string block =
        R"({"descriptor_bindings":[],"uniform_blocks":[{"name":"GlobalUniforms","size":80,"binding":1,)"
        R"("members":[{"name":"g_ModelViewProjectionMatrix","offset":0,"size":64},)"
        R"({"name":"g_EyePosition","offset":64,"size":12}]}],"vertex_inputs":[],"active_texture_slots":[])";
    MetalShaderReflection reflection;
    std::string           error;
    ASSERT_TRUE(ParseMetalShaderReflection(block + R"(,"read_uniforms":["g_ModelViewProjectionMatrix"]})",
                                           reflection, &error))
        << error;
    EXPECT_TRUE(reflection.hasMember("g_EyePosition"));
    EXPECT_FALSE(reflection.readsMember("g_EyePosition"));
    EXPECT_TRUE(reflection.readsMember("g_ModelViewProjectionMatrix"));
    // A name the block does not declare is not read, whatever the list says.
    ASSERT_TRUE(ParseMetalShaderReflection(block + R"(,"read_uniforms":["g_Time"]})", reflection, &error)) << error;
    EXPECT_FALSE(reflection.readsMember("g_Time"));

    // Without the list, and with a list that is not one of names, every declared member is read.
    for (const std::string tail : { std::string("}"), std::string(R"(,"read_uniforms":["g_ModelViewProjectionMatrix",7]})"),
                                    std::string(R"(,"read_uniforms":"g_ModelViewProjectionMatrix"})") }) {
        SCOPED_TRACE(tail);
        ASSERT_TRUE(ParseMetalShaderReflection(block + tail, reflection, &error)) << error;
        EXPECT_FALSE(reflection.read_uniforms.has_value());
        EXPECT_TRUE(reflection.readsMember("g_EyePosition"));
        EXPECT_TRUE(reflection.readsMember("g_ModelViewProjectionMatrix"));
    }
}

TEST(MetalOverwrite, OnlyBlendingThatReplacesTheTexelLetsADrawOverwriteIt)
{
    EXPECT_TRUE(BlendReplacesDestination(ToMetalBlendState(BlendMode::Disable, AlphaBlendRule::Material, 1)));
    EXPECT_TRUE(BlendReplacesDestination(ToMetalBlendState(BlendMode::Normal, AlphaBlendRule::Material, 1)));
    EXPECT_TRUE(BlendReplacesDestination(ToMetalBlendState(BlendMode::Normal, AlphaBlendRule::Max, 1)));
    for (const auto mode : { BlendMode::Translucent, BlendMode::Additive, BlendMode::Multiply,
                             BlendMode::AlphaToCoverage }) {
        EXPECT_FALSE(BlendReplacesDestination(ToMetalBlendState(mode, AlphaBlendRule::Material, 1)))
            << static_cast<int>(mode);
    }
    auto subtract          = ToMetalBlendState(BlendMode::Normal, AlphaBlendRule::Material, 1);
    subtract.rgb_operation = MetalBlendOperation::ReverseSubtract;
    EXPECT_FALSE(BlendReplacesDestination(subtract));
}

TEST(MetalNoopDraw, OnlyBlendingThatKeepsTheTexelAtZeroAlphaLetsADrawBeLeftOut)
{
    // Source over (alpha by the colour's factors or by source-over coverage), additive, and both
    // under the maximum alpha rule: Cs * 0 + Cd * 1, and an alpha of As * As, As or max(As, Ad).
    for (const auto rule : { AlphaBlendRule::Material, AlphaBlendRule::SourceOver, AlphaBlendRule::Max }) {
        for (const auto mode : { BlendMode::Translucent, BlendMode::Additive }) {
            EXPECT_TRUE(BlendKeepsDestinationAtZeroAlpha(ToMetalBlendState(mode, rule, 1)))
                << static_cast<int>(mode) << " " << static_cast<int>(rule);
        }
        // Blending off and `normal` (One/Zero) write the fragment; multiply scales the held
        // colour by the fragment's; alpha to coverage decides coverage, not a blend.
        for (const auto mode : { BlendMode::Disable, BlendMode::Normal, BlendMode::Multiply,
                                 BlendMode::AlphaToCoverage }) {
            EXPECT_FALSE(BlendKeepsDestinationAtZeroAlpha(ToMetalBlendState(mode, rule, 1)))
                << static_cast<int>(mode) << " " << static_cast<int>(rule);
        }
    }
    const auto translucent = ToMetalBlendState(BlendMode::Translucent, AlphaBlendRule::Material, 1);
    // Factors and operations that do not give the held texel back whole.
    auto subtract          = translucent;
    subtract.rgb_operation = MetalBlendOperation::ReverseSubtract;
    EXPECT_FALSE(BlendKeepsDestinationAtZeroAlpha(subtract));
    auto source_colour       = translucent;
    source_colour.source_rgb = MetalBlendFactor::One;
    EXPECT_FALSE(BlendKeepsDestinationAtZeroAlpha(source_colour)) << "Cs * 1 is the fragment's colour";
    auto destination_colour            = translucent;
    destination_colour.destination_rgb = MetalBlendFactor::SourceColor;
    EXPECT_FALSE(BlendKeepsDestinationAtZeroAlpha(destination_colour));
    auto destination_alpha              = translucent;
    destination_alpha.destination_alpha = MetalBlendFactor::Zero;
    EXPECT_FALSE(BlendKeepsDestinationAtZeroAlpha(destination_alpha)) << "Ad * 0 drops the held alpha";
    auto minimum            = translucent;
    minimum.alpha_operation = MetalBlendOperation::Min;
    EXPECT_FALSE(BlendKeepsDestinationAtZeroAlpha(minimum)) << "min(0, Ad) is 0";
    auto coverage              = translucent;
    coverage.alpha_to_coverage = true;
    EXPECT_FALSE(BlendKeepsDestinationAtZeroAlpha(coverage));
}

TEST(MetalNoopDraw, TheFragmentColourFactsAreReadAndAMalformedChannelProvesNothing)
{
    MetalShaderReflection reflection;
    std::string           error;
    ASSERT_TRUE(ParseMetalShaderReflection(
        R"({"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[],)"
        R"("fragment_colour":[[{"uniform":"g_Color","component":0}],[{"uniform":"g_Color","component":1},)"
        R"({"constant_bits":1056964608}],null,[{"uniform":"g_Alpha","component":0}]]})",
        reflection, &error))
        << error;
    ASSERT_TRUE(reflection.fragment_colour[0].has_value());
    EXPECT_EQ((*reflection.fragment_colour[0])[0].member, "g_Color");
    ASSERT_TRUE(reflection.fragment_colour[1].has_value());
    ASSERT_EQ(reflection.fragment_colour[1]->size(), 2u);
    EXPECT_EQ((*reflection.fragment_colour[1])[1].member, "");
    EXPECT_EQ((*reflection.fragment_colour[1])[1].constant, 0.5f);
    EXPECT_FALSE(reflection.fragment_colour[2].has_value()) << "an unproven channel stays unproven";
    ASSERT_TRUE(reflection.fragment_colour[3].has_value());
    EXPECT_EQ((*reflection.fragment_colour[3])[0].member, "g_Alpha");

    // A factor of an unknown shape, a component beyond a vector, or a document without the fact.
    ASSERT_TRUE(ParseMetalShaderReflection(
        R"({"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[],)"
        R"("fragment_colour":[[{"uniform":"g_Color"}],[{"uniform":"g_Color","component":7}],[{"texture":0}],[]]})",
        reflection, &error))
        << error;
    for (const auto& channel : reflection.fragment_colour) EXPECT_FALSE(channel.has_value());
    ASSERT_TRUE(ParseMetalShaderReflection(
        R"({"descriptor_bindings":[],"uniform_blocks":[],"vertex_inputs":[],"active_texture_slots":[]})", reflection,
        &error))
        << error;
    for (const auto& channel : reflection.fragment_colour) EXPECT_FALSE(channel.has_value());
}

namespace
{

ScenePassDescription ClearStep(const std::string& target)
{
    ScenePassDescription d;
    d.kind        = MetalPassKind::Clear;
    d.name        = "clear " + target;
    d.target_key  = target;
    d.load_action = MetalLoadAction::Clear;
    return d;
}

ScenePassDescription DrawStep(const std::string& target, MetalLoadAction load, std::vector<std::string> samples = {})
{
    ScenePassDescription d;
    d.kind         = MetalPassKind::CustomShader;
    d.name         = "draw " + target;
    d.target_key   = target;
    d.load_action  = load;
    d.texture_keys = std::move(samples);
    return d;
}

std::vector<std::optional<std::vector<std::size_t>>> Plan(const std::vector<ScenePassDescription>& passes,
                                                          const std::vector<std::size_t>& order = {})
{
    return PlanUnreadClears(passes, order, [](std::size_t) { return true; }, [](std::size_t) { return true; });
}

} // namespace

TEST(MetalHiddenClears, AClearIsSeenOnlyByTheDrawsUpToTheTargetsNextClear)
{
    // A hidden layer's chain: its card clears A, the effect reads A into B (clearing B first),
    // the next effect draws back onto A, the layer goes onto the scene; the next layer clears A
    // again, and a draw after that reads A for itself.
    const std::vector<ScenePassDescription> passes {
        DrawStep("A", MetalLoadAction::Clear),                 // 0 card
        DrawStep("B", MetalLoadAction::Clear, { "A" }),        // 1 effect
        DrawStep("A", MetalLoadAction::Load, { "B" }),         // 2 effect onto A
        DrawStep("scene", MetalLoadAction::Load, { "A" }),     // 3 composite
        ClearStep("A"),                                        // 4 the next layer's clear
        DrawStep("scene", MetalLoadAction::Load, { "A" }),     // 5 reads the next layer's A
    };
    const auto plan = Plan(passes);
    ASSERT_TRUE(plan[0].has_value());
    EXPECT_EQ(*plan[0], (std::vector<std::size_t> { 1, 2, 3 })) << "the readers stop at the next clear of A";
    ASSERT_TRUE(plan[1].has_value());
    EXPECT_EQ(*plan[1], (std::vector<std::size_t> { 2 }));
    ASSERT_TRUE(plan[4].has_value());
    EXPECT_EQ(*plan[4], (std::vector<std::size_t> { 5 }));
    for (const auto index : { 2, 3, 5 }) EXPECT_FALSE(plan[index].has_value()) << index << " clears nothing";
}

TEST(MetalHiddenClears, AClearTheNextFrameReadsBeforeItIsClearedAgainIsAlwaysSeen)
{
    // The scene's first pass reads A as the frame before left it; A's only clear comes later.
    // Whatever that pass draws then, the clear is what it reads: never left out.
    std::vector<ScenePassDescription> passes {
        DrawStep("scene", MetalLoadAction::Clear, { "A" }), // 0 reads last frame's A
        DrawStep("A", MetalLoadAction::Clear),              // 1 hidden card
        DrawStep("scene", MetalLoadAction::Load, { "A" }),  // 2
    };
    EXPECT_FALSE(Plan(passes)[1].has_value());
    // A draw onto A before the clear reads it too; one that clears A first ends the span.
    passes[0] = DrawStep("A", MetalLoadAction::Load);
    EXPECT_FALSE(Plan(passes)[1].has_value());
    passes[0] = DrawStep("A", MetalLoadAction::Clear);
    ASSERT_TRUE(Plan(passes)[1].has_value());
    EXPECT_EQ(*Plan(passes)[1], (std::vector<std::size_t> { 2 }));
    // In another execution order the reader runs first again.
    passes[0] = DrawStep("scene", MetalLoadAction::Clear, { "A" });
    EXPECT_TRUE(Plan(passes, { 1, 2, 0 })[1].has_value());
    EXPECT_FALSE(Plan(passes, { 0, 1, 2 })[1].has_value());
}

TEST(MetalHiddenClears, ACopyOfTheTargetOrAClearThatMayNotApplyKeepsTheClear)
{
    // A copy runs whatever is visible, so a clear it reads is always seen.
    ScenePassDescription copy;
    copy.kind       = MetalPassKind::Copy;
    copy.source_key = "A";
    copy.target_key = "C";
    std::vector<ScenePassDescription> passes { DrawStep("A", MetalLoadAction::Clear), copy };
    EXPECT_FALSE(Plan(passes)[0].has_value());

    // A later clear that is switched with the order, or a draw dropped for an input nothing
    // produces, does not end the span: the readers past it count, and with none past it the
    // next frame's passes ahead of the clear do.
    auto conditional                    = ClearStep("A");
    conditional.conditional_scene_clear = true;
    passes = { DrawStep("A", MetalLoadAction::Clear), conditional, DrawStep("scene", MetalLoadAction::Load, { "A" }) };
    ASSERT_TRUE(Plan(passes)[0].has_value());
    EXPECT_EQ(*Plan(passes)[0], (std::vector<std::size_t> { 2 }));
    passes = { DrawStep("scene", MetalLoadAction::Load, { "A" }), DrawStep("A", MetalLoadAction::Clear),
               DrawStep("A", MetalLoadAction::Clear) };
    const auto unproduced = PlanUnreadClears(
        passes, {}, [](std::size_t) { return true; }, [](std::size_t j) { return j != 2; });
    EXPECT_FALSE(unproduced[1].has_value()) << "a dropped draw cleared nothing, so the next frame's reader sees it";
    EXPECT_TRUE(Plan(passes)[1].has_value());
    // A clear its caller does not consider is never planned.
    EXPECT_FALSE(PlanUnreadClears(passes, {}, [](std::size_t) { return false; },
                                  [](std::size_t) { return true; })[1]
                     .has_value());
}

TEST(MetalDepthSharing, AFlatDrawBetweenTwoDepthTestedDrawsJoinsTheirDepthAttachment)
{
    // A model, a flat layer and text over it, another model, all on the scene; a flat layer
    // before the first model and one after the last; a flat draw elsewhere.
    const auto tested = [](std::string target) {
        auto d       = DrawStep(std::move(target), MetalLoadAction::Load);
        d.depth_test = true;
        return d;
    };
    std::vector<ScenePassDescription> passes {
        DrawStep("scene", MetalLoadAction::Clear), // 0 before the first model
        tested("scene"),                           // 1 model
        DrawStep("scene", MetalLoadAction::Load),  // 2 flat layer
        DrawStep("other", MetalLoadAction::Load),  // 3 another target
        DrawStep("scene", MetalLoadAction::Load),  // 4 text
        tested("scene"),                           // 5 model
        DrawStep("scene", MetalLoadAction::Load),  // 6 after the last model
    };
    // A post-processing draw is single-sample like every other draw of a target without MSAA.
    passes[4].force_single_sample = true;
    ShareDepthAttachments(passes);
    for (std::size_t i = 0; i < passes.size(); ++i) {
        SCOPED_TRACE(i);
        EXPECT_EQ(passes[i].shares_depth_attachment, i == 2 || i == 4);
    }

    // A flat draw that passes on another target cut off from both models joins neither of them,
    // so it takes no attachment: it would only load and store the depth.
    std::vector<ScenePassDescription> isolated {
        tested("scene"), DrawStep("effect", MetalLoadAction::Load), DrawStep("scene", MetalLoadAction::Load),
        DrawStep("effect", MetalLoadAction::Load), tested("scene"),
    };
    ShareDepthAttachments(isolated);
    for (const auto& pass : isolated) EXPECT_FALSE(pass.shares_depth_attachment);
    // Joined to one of them on either side, it does.
    isolated[3].target_key = "scene";
    ShareDepthAttachments(isolated);
    EXPECT_TRUE(isolated[2].shares_depth_attachment);
    EXPECT_TRUE(isolated[3].shares_depth_attachment);

    // A scene sorted by depth reorders its objects as it runs, so build order says nothing about
    // which draws end up between the models: none is marked.
    auto sorted = passes;
    for (auto& pass : sorted) pass.shares_depth_attachment = false;
    ShareDepthAttachments(sorted, true);
    for (const auto& pass : sorted) EXPECT_FALSE(pass.shares_depth_attachment);

    // A target with a multisampled draw keeps its draws as they were, and so does a target
    // whose draws do not depth-test, a depth-only draw (a shadow caster) and the volumetric
    // scene's draws, which carry the scene's depth already.
    auto multisampled = passes;
    for (auto& pass : multisampled) pass.shares_depth_attachment = false;
    multisampled[1].samples = 4;
    ShareDepthAttachments(multisampled);
    for (const auto& pass : multisampled) EXPECT_FALSE(pass.shares_depth_attachment);

    std::vector<ScenePassDescription> others {
        tested("shadow"), DrawStep("shadow", MetalLoadAction::Load), tested("shadow"),
        DrawStep("scene", MetalLoadAction::Load),
    };
    others[0].depth_only = others[2].depth_only = true;
    others[1].depth_only                        = true;
    ShareDepthAttachments(others);
    for (const auto& pass : others) EXPECT_FALSE(pass.shares_depth_attachment);

    std::vector<ScenePassDescription> volumetric { tested("scene"), DrawStep("scene", MetalLoadAction::Load),
                                                   tested("scene") };
    volumetric[1].scene_depth_attachment = true;
    ShareDepthAttachments(volumetric);
    EXPECT_FALSE(volumetric[1].shares_depth_attachment);
}

TEST(MetalHiddenClears, ACopyIsForTheDrawsAfterItThatSampleItsResultAlone)
{
    ScenePassDescription copy;
    copy.kind       = MetalPassKind::Copy;
    copy.source_key = "scene";
    copy.target_key = "C";
    // A lens copies the scene so far and samples the copy while drawing into the scene.
    std::vector<ScenePassDescription> passes {
        DrawStep("scene", MetalLoadAction::Clear), copy, DrawStep("scene", MetalLoadAction::Load, { "C" }),
        DrawStep("scene", MetalLoadAction::Load, { "C" }),
    };
    const auto all = [](std::size_t) { return true; };
    ASSERT_TRUE(PlanUnreadCopies(passes, {}, all)[1].has_value());
    EXPECT_EQ(*PlanUnreadCopies(passes, {}, all)[1], (std::vector<std::size_t> { 2, 3 }));
    EXPECT_FALSE(PlanUnreadCopies(passes, {}, [](std::size_t) { return false; })[1].has_value());
    // A reader ahead of it sees the frame before's copy.
    EXPECT_FALSE(PlanUnreadCopies(passes, { 2, 0, 1, 3 }, all)[1].has_value());
    // Another pass that writes the copy's name, or a copy of the copy, sees or changes it otherwise.
    auto other = passes;
    other.push_back(DrawStep("C", MetalLoadAction::Load));
    EXPECT_FALSE(PlanUnreadCopies(other, {}, all)[1].has_value());
    other = passes;
    auto onward       = copy;
    onward.source_key = "C";
    onward.target_key = "D";
    other.push_back(onward);
    EXPECT_FALSE(PlanUnreadCopies(other, {}, all)[1].has_value());
    // A copy nobody samples is the copy plan's to remove, which keeps it while scene
    // optimisation is off.
    passes.resize(2);
    EXPECT_FALSE(PlanUnreadCopies(passes, {}, all)[1].has_value());
}

TEST(MetalOverwrite, TheEffectCardCoversEveryTexelCentreHoweverItIsFolded)
{
    for (const auto [width, height] : { std::pair { 1u, 1u }, { 7u, 5u }, { 3840u, 2160u }, { 16384u, 16384u } }) {
        SCOPED_TRACE(::testing::Message() << width << "x" << height);
        EXPECT_TRUE(QuadCoversViewport(EffectCard(), kIdentity, width, height));
        // Metal's clip-space fold mirrors y; the card covers the same square.
        auto folded = kIdentity;
        folded[5]   = -1.0f;
        EXPECT_TRUE(QuadCoversViewport(EffectCard(), folded, width, height));
        // The same card drawn as a strip, and as a larger card the viewport clips.
        auto strip      = EffectCard();
        strip.triangles = { { { 0, 1, 2 }, { 1, 2, 3 } } };
        EXPECT_TRUE(QuadCoversViewport(strip, kIdentity, width, height));
        EXPECT_TRUE(QuadCoversViewport(EffectCard(4.0f), kIdentity, width, height));
    }
    // A layer's card through an orthographic matrix that maps it onto the whole canvas.
    std::array<float, 16> ortho {};
    ortho[0]  = 2.0f / 384.0f;
    ortho[5]  = 2.0f / 256.0f;
    ortho[10] = -2.0f / 10000.0f;
    ortho[14] = 0.5f;
    ortho[15] = 1.0f;
    EXPECT_TRUE(QuadCoversViewport(EffectCard(192.0f), ortho, 384, 256)) << "x and y scale differently";
    auto wide = EffectCard(192.0f);
    for (auto& corner : wide.corners) corner[1] *= 256.0f / 384.0f;
    EXPECT_TRUE(QuadCoversViewport(wide, ortho, 384, 256));
}

TEST(MetalOverwrite, ACardThatMayMissATexelCentreIsNotACover)
{
    constexpr uint32_t width = 1000, height = 600;
    // Shrunk, moved, or pulled in by less than a texel: the outermost centres are at
    // 1 - 1/1000, so a card ending at 1 - 0.6/1000 still covers them, but the proof keeps a
    // quarter-texel margin and gives up.
    EXPECT_FALSE(QuadCoversViewport(EffectCard(0.5f), kIdentity, width, height));
    EXPECT_FALSE(QuadCoversViewport(EffectCard(1.0f - 0.6f / width), kIdentity, width, height));
    auto moved = kIdentity;
    moved[12]  = 0.01f;
    EXPECT_FALSE(QuadCoversViewport(EffectCard(), moved, width, height));
    // Clipped by depth: in front of the near plane, past the far one, or on it but not exactly.
    EXPECT_FALSE(QuadCoversViewport(EffectCard(1.0f, -0.5f), kIdentity, width, height));
    EXPECT_FALSE(QuadCoversViewport(EffectCard(1.0f, 2.0f), kIdentity, width, height));
    auto skewed = kIdentity;
    skewed[2]   = 1e-7f;     // z picks up x: rounding could put a corner behind the near plane
    EXPECT_FALSE(QuadCoversViewport(EffectCard(), skewed, width, height));
    EXPECT_TRUE(QuadCoversViewport(EffectCard(1.0f, 0.5f), kIdentity, width, height));
    // Behind the eye, or a matrix that is not finite.
    auto behind = kIdentity;
    behind[15]  = -1.0f;
    EXPECT_FALSE(QuadCoversViewport(EffectCard(), behind, width, height));
    auto broken = kIdentity;
    broken[0]   = std::nanf("");
    EXPECT_FALSE(QuadCoversViewport(EffectCard(), broken, width, height));
    // Triangles that do not tile the quad: both on one side of their shared edge, the same
    // triangle twice, or a degenerate one. The other diagonal tiles it as well as the first.
    auto diagonal      = EffectCard();
    diagonal.triangles = { { { 0, 1, 3 }, { 0, 3, 2 } } };
    EXPECT_TRUE(QuadCoversViewport(diagonal, kIdentity, width, height));
    auto one_side      = EffectCard();
    one_side.triangles = { { { 0, 2, 3 }, { 0, 2, 1 } } };
    EXPECT_FALSE(QuadCoversViewport(one_side, kIdentity, width, height)) << "both stand on the bottom edge";
    auto twice      = EffectCard();
    twice.triangles = { { { 0, 2, 1 }, { 0, 2, 1 } } };
    EXPECT_FALSE(QuadCoversViewport(twice, kIdentity, width, height));
    auto flat        = EffectCard();
    flat.corners[3]  = flat.corners[2];
    EXPECT_FALSE(QuadCoversViewport(flat, kIdentity, width, height));
    EXPECT_FALSE(QuadCoversViewport(EffectCard(), kIdentity, 0, height));
}
