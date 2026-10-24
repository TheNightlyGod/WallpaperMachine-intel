#include "graph_contract_support.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "Scene/Scene.h"
#include "WPSceneParser.hpp"
#include "SpecTexs.hpp"
#include "RenderCommon/ScenePass.hpp"
#include "RenderCommon/SceneRaster.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"

#include <algorithm>
#include <gtest/gtest.h>
#include "TestRequire.hpp"
#include <cstdint>
#include <memory>
#include <map>
#include <string>
#include <vector>
#include <array>

#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"

namespace
{
using wallpaper::Scene, wallpaper::SceneCamera, wallpaper::SceneMesh, wallpaper::SceneNode;
using wallpaper::SceneImageEffect, wallpaper::SceneImageEffectLayer, wallpaper::SceneImageEffectNode;
using wallpaper::SceneMaterial, wallpaper::SceneRenderTarget, wallpaper::SpecTex_Default;
using wallpaper::rg::CopyPass, wallpaper::rg::DrawPass;
using namespace graph_contract;

// One triangle skinned to a single root bone, with no animations.
std::vector<uint8_t> BuildBonedPuppetMdlFixture() {
    Bytes b;
    modelHeader(b, 21);
    const std::array<uint32_t, 3> indices { 0, 1, 2 };
    const std::array<Part, 1> parts {{ { 10, 0, 0, 3 } }};
    skinMesh(b, 21, "mat/head.json", triangle(), indices, parts);
    b.stamp("MDLS", 1);
    b.u32(0);
    b.u16(1);
    b.u16(0);
    b.text("root");
    b.u32(0);
    b.u32(0xFFFFFFFFu);
    b.u32(64);
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) b.f32(row == col ? 1.0f : 0.0f);
    }
    b.text("{}");
    b.stamp("MDLA", 0);
    b.u8(0);
    return std::move(b.data);
}

// `extra_fields` are further members of the image object, each followed by a comma.
std::string BasicSceneJson(std::string_view image, std::string_view extra_fields = {}) {
    return sceneJson(imageJson(300, "masked puppet image", image,
                               std::string(extra_fields) + "\"visible\":true"));
}

TEST(RenderGraph, ConsecutiveAndTerminalEffectCopiesKeepTheirDependencies) {
    Scene scene;
    defaults(scene);
    const std::string input = std::string(wallpaper::WE_EFFECT_PPONG_PREFIX_A) + "copies";
    for (const auto& key : { input, std::string("_rt_ping_b"), std::string("_rt_copy_a"),
                            std::string("_rt_copy_b"), std::string("_rt_copy_c") }) {
        scene.renderTargets[key] = { .width = 16, .height = 16, .allowReuse = true };
    }
    auto owner = node("effect owner");
    owner->SetSkipRenderPass(true);
    owner->SetCamera("local");
    auto camera = std::make_shared<SceneCamera>(16, 16, -1, 1);
    auto layer = std::make_shared<SceneImageEffectLayer>(owner.get(), 16, 16, input, "_rt_ping_b");
    layer->SetFinalBlend(wallpaper::BlendMode::Translucent);
    auto effect = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back({ std::string(SpecTex_Default), node("effect draw", {"_rt_copy_b"}) });
    effect->commands.push_back({ .dst = "_rt_copy_a", .src = input, .afterpos = 0 });
    effect->commands.push_back({ .dst = "_rt_copy_c", .src = std::string(SpecTex_Default), .afterpos = 1 });
    effect->commands.push_back({ .dst = "_rt_copy_b", .src = "_rt_copy_a", .afterpos = 0 });
    layer->AddEffect(effect);
    camera->AttatchImgEffect(layer);
    scene.cameras["local"] = camera;
    scene.sceneGraph->AppendChild(owner);

    const Observation observed(scene);
    ASSERT_NE(observed.graph, nullptr);
    const auto& passes = observed.steps;
    std::map<std::string, size_t> copies;
    for (size_t index = 0; index < passes.size(); ++index) {
        if (passes[index].copy != nullptr) copies[passes[index].copy->desc().dst] = index;
    }
    ASSERT_EQ(copies.size(), 3u);
    EXPECT_LT(copies.at("_rt_copy_a"), copies.at("_rt_copy_b"));
    EXPECT_LT(copies.at("_rt_copy_b"), observed.drawIndex("effect draw"));
    EXPECT_LT(observed.drawIndex("effect draw"), copies.at("_rt_copy_c"));
}

// A layer's colour blend mode mixes it with the screen behind it, so the screen
// may only be sampled by the pass that draws onto it. On a puppet with bones
// that is the skinned pass; a pass before it renders the texture sheet, where
// the screen comes out squeezed into the layer's bounds.
TEST(RenderGraph, puppetColorBlendModeSamplesTheScreenOnlyWhereItDrawsOnScreen) {
    AssetMap files;
    shaderAsset(files, "puppetblend", false, false, true);
    const auto& vertex_bytes = files.at("/shaders/puppetblend.vert");
    const std::string blend_vert(vertex_bytes.begin(), vertex_bytes.end());
    const auto& fragment_bytes = files.at("/shaders/puppetblend.frag");
    std::string blend_frag(fragment_bytes.begin(), fragment_bytes.end());
    blend_frag.insert(0, R"(#if BLENDMODE
uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
#endif
)");
    const auto blend_output = blend_frag.find("gl_FragColor=c;");
    REQUIRE(blend_output != std::string::npos);
    blend_frag.insert(blend_output, R"(
#if BLENDMODE
  c.rgb *= texture(g_Texture4, v_ContractUV).rgb;
#endif
)");
    asset(files, "/puppet_image.json",
          R"({"width":64,"height":32,"material":"mat/base.json","puppet":"puppet.mdl"})");
    files["/puppet.mdl"] = BuildBonedPuppetMdlFixture();
    materialAsset(files, "mat/base.json", "puppetblend", "[\"base.tex\"]");
    materialAsset(files, "mat/head.json", "puppetblend", "[\"base.tex\"]");
    materialAsset(files, "materials/util/effectpassthrough.json", "genericimage3", "[]", "normal");
    asset(files, "/shaders/puppetblend.frag", blend_frag);
    asset(files, "/shaders/genericimage3.vert", blend_vert);
    asset(files, "/shaders/genericimage3.frag", blend_frag);
    files["/materials/base.tex.tex"] = {};
    ParseFixture fixture(std::move(files));
    auto parsed = fixture.parser.Parse("parsed-blended-puppet",
        BasicSceneJson("puppet_image.json", R"("colorBlendMode":2,)"),
        fixture.vfs, fixture.sound);
    REQUIRE(parsed != nullptr);

    const Observation observed(*parsed);
    const auto& passes = observed.steps;

    std::size_t screen_readers = 0;
    for (const auto& pass : passes) {
        if (pass.draw == nullptr) continue;
        const auto& textures = pass.draw->desc().textures;
        const bool  samples_screen =
            std::any_of(textures.begin(), textures.end(), [](const std::string& texture) {
                return texture.starts_with(SpecTex_Default);
            });
        if (! samples_screen) continue;
        ++screen_readers;
        REQUIRE(pass.draw->desc().output == SpecTex_Default);
    }
    REQUIRE(screen_readers == 1);
}

// Wallpaper Engine draws a layer whose colour blend mode is 31 ("add") with
// additive blending straight onto the scene: no passthrough, no copy of the
// screen for it to sample. With effects the last effect pass is the one that
// adds; without, the layer's own draw.
TEST(RenderGraph, addColorBlendLayersAddOntoTheSceneWithoutSamplingIt) {
    AssetMap files;
    shaderAsset(files, "genericimage");
    const auto& vertex_bytes = files.at("/shaders/genericimage.vert");
    const std::string vert(vertex_bytes.begin(), vertex_bytes.end());
    const auto& fragment_bytes = files.at("/shaders/genericimage.frag");
    std::string frag(fragment_bytes.begin(), fragment_bytes.end());
    frag.insert(0, R"(#if BLENDMODE
uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
#endif
)");
    const auto blend_output = frag.find("gl_FragColor=c;");
    REQUIRE(blend_output != std::string::npos);
    frag.insert(blend_output, R"(
#if BLENDMODE
  c.rgb += texture(g_Texture4, v_ContractUV).rgb;
#endif
)");
    asset(files, "/models/util/solidlayer.json", R"({"material":"materials/util/solidlayer.json"})");
    materialAsset(files, "materials/util/solidlayer.json", "genericimage", "[\"solid.tex\"]");
    materialAsset(files, "materials/util/effectpassthrough.json", "blend_probe", "[]", "normal");
    asset(files, "/effects/tint/effect.json",
          R"({"name":"tint","passes":[{"material":"materials/effects/tint.json"}]})");
    materialAsset(files, "materials/effects/tint.json", "effects/tint", "[null]");
    asset(files, "/shaders/genericimage.frag", frag);
    asset(files, "/shaders/blend_probe.vert", vert);
    asset(files, "/shaders/blend_probe.frag", frag);
    asset(files, "/shaders/effects/tint.vert", vert);
    asset(files, "/shaders/effects/tint.frag", frag);
    files["/materials/solid.tex.tex"] = {};
    ParseFixture fixture(std::move(files));

    const std::string scene_json = sceneJson(R"(
        {"id":940,"name":"plain","image":"models/util/solidlayer.json","colorBlendMode":31,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"size":[64,64],"visible":true},
        {"id":941,"name":"with effect","image":"models/util/solidlayer.json","colorBlendMode":31,
         "origin":[0,0,0],"scale":[1,1,1],"angles":[0,0,0],"size":[64,64],"visible":true,
         "effects":[{"file":"effects/tint/effect.json","id":942,"visible":true}]}
    )");

    auto parsed = fixture.parser.Parse("add-color-blend", scene_json, fixture.vfs, fixture.sound);
    REQUIRE(parsed != nullptr);

    const Observation observed(*parsed);
    const auto& passes = observed.steps;
    std::size_t onto_scene = 0;
    for (const auto& pass : passes) {
        REQUIRE(pass.copy == nullptr);
        if (pass.draw == nullptr) continue;
        const auto& desc = pass.draw->desc();
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
            defaults(scene);
            scene.clearEnabled = clear;
            auto hidden = node("left_out_writer");
            hidden->SetVisible(false);
            hidden->SetVisibilitySettled(true);
            auto drawn = node("first_drawn_writer");
            if (hidden_first) scene.sceneGraph->AppendChild(hidden);
            scene.sceneGraph->AppendChild(drawn);
            if (! hidden_first) scene.sceneGraph->AppendChild(hidden);

            const Observation observed(scene);
            const auto& passes = observed.steps;
            REQUIRE(std::none_of(passes.begin(), passes.end(), [](const auto& pass) {
                return pass.name == "left_out_writer";
            }));
            const auto& first = observed.draw("first_drawn_writer");
            REQUIRE(first.output == SpecTex_Default);
            EXPECT_EQ(first.clear_on_first_use, clear);
            EXPECT_EQ(first.preserve_target_contents, ! clear && hidden_first);
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
    AssetMap files;
    asset(files, "/models/util/solidlayer.json", R"({"material":"materials/util/solidlayer.json"})");
    materialAsset(files, "materials/util/solidlayer.json", "genericimage", "[\"solid.tex\"]");
    shaderAsset(files, "genericimage");
    files["/materials/solid.tex.tex"] = {};
    // A material is named after its shader, so each effect gets its own.
    for (const std::string name : { "toggled", "chosen", "unchosen", "unbound" }) {
        asset(files, "/effects/" + name + "/effect.json",
            R"({"name":")" + name + R"(","passes":[{"material":"materials/effects/)" + name +
            R"(.json"}]})");
        materialAsset(files, "materials/effects/" + name + ".json", "effects/" + name, "[null]");
        files["/shaders/effects/" + name + ".vert"] = files.at("/shaders/genericimage.vert");
        files["/shaders/effects/" + name + ".frag"] = files.at("/shaders/genericimage.frag");
    }
    ParseFixture fixture(std::move(files));

    const std::string scene_json = sceneJson(R"(
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
    )");


    // Without properties the scene file's values are all there is.
    auto authored = fixture.parser.Parse("effect-visibility-authored", scene_json, fixture.vfs, fixture.sound);
    REQUIRE(authored != nullptr);
    REQUIRE((parsedEffectMaterials(*authored) ==
             std::vector<std::string> { "effects/unbound", "effects/unchosen" }));

    const wallpaper::ProjectProperties properties {
        { "toggle", wallpaper::RuntimeScalarValue::Bool(true) },
        { "mode", wallpaper::RuntimeScalarValue::String("2") },
    };
    auto chosen = fixture.parser.Parse(
        wallpaper::SceneParseRequest {
            .scene_id = "effect-visibility-chosen", .project_properties = &properties },
        scene_json, fixture.vfs, fixture.sound);
    REQUIRE(chosen != nullptr);
    REQUIRE((parsedEffectMaterials(*chosen) ==
             std::vector<std::string> { "effects/chosen", "effects/toggled", "effects/unbound" }));
}

} // namespace
