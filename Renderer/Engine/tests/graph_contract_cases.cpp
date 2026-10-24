#include "graph_contract_support.hpp"
#include <gtest/gtest.h>
#include <cmath>

namespace graph_contract
{
namespace
{
constexpr const char* auxiliary  = "_rt_contract_auxiliary";
constexpr const char* maskTarget = "_rt_puppet_mask";

TEST(RenderGraph, renderTargetAliasesResolveForOutputAndSampledSpecTextures) {
    Scene s;
    defaults(s);
    target(s, auxiliary);
    s.renderTargetAliases["_rt_contract_alias"] = auxiliary;
    append(s, "alias_writer", {}, "_rt_contract_alias");
    append(s, "alias_reader", { "_rt_contract_alias" });
    Observation g(s);
    REQUIRE(g.draw("alias_writer").output == auxiliary);
    const auto& reader = g.draw("alias_reader");
    REQUIRE(reader.textures.size() == 1);
    REQUIRE(reader.textures[0] == auxiliary);
}
TEST(RenderGraph, runtimeTextTextureNamesStayImported) {
    Scene s;
    defaults(s);
    const std::string text = "runtime/text/independent_contract_label";
    SceneTexture      runtimeText {};
    runtimeText.url  = text;
    s.textures[text] = std::move(runtimeText);
    append(s, "runtime_text", { text });
    Observation g(s);
    const auto& d = g.draw("runtime_text");
    REQUIRE(d.textures.size() == 1);
    REQUIRE(d.textures[0] == text);
    auto accesses = g.graph->getLastReadTexs(g.order);
    REQUIRE(accesses.size() == g.order.size());
    std::size_t matches = 0;
    for (const auto& list : accesses)
        for (auto* t : list) {
            REQUIRE(t);
            if (t->key() == text) {
                ++matches;
                REQUIRE(t->type() == rg::TexNode::TexType::Imported);
            }
        }
    REQUIRE(matches == 1);
}
TEST(RenderGraph, submeshMaterialSlotsEmitDistinctCustomPasses) {
    Scene s;
    defaults(s);
    target(s, auxiliary);
    auto n = append(s, "slot_zero", {}, auxiliary);
    n->Mesh()->AddMaterial(material("slot_one"));
    submesh(*n->Mesh(), 0);
    submesh(*n->Mesh(), 1);
    Observation g(s);
    const auto& a = g.draw("slot_zero");
    const auto& b = g.draw("slot_one");
    REQUIRE(g.nodeDraws("slot_zero").size() == 2);
    REQUIRE(g.steps[g.drawIndex("slot_zero")].type == rg::PassNode::Type::CustomShader);
    REQUIRE(g.steps[g.drawIndex("slot_one")].type == rg::PassNode::Type::CustomShader);
    REQUIRE(a.submesh_index == 0);
    REQUIRE(a.material_slot == 0);
    REQUIRE(b.submesh_index == 1);
    REQUIRE(b.material_slot == 1);
    REQUIRE(a.output == auxiliary);
    REQUIRE(b.output == auxiliary);
    requirePolicy(a, true, false);
    requirePolicy(b, false, true);
}
TEST(RenderGraph, submeshMaterialRoutingDoesNotRequireSlotZero) {
    Scene s;
    defaults(s);
    auto n = append(s, "discarded");
    n->Mesh()->MaterialSlots()[0].reset();
    n->Mesh()->AddMaterial(material("valid_slot_one"));
    submesh(*n->Mesh(), 0);
    submesh(*n->Mesh(), 1);
    Observation g(s);
    auto        draws = g.nodeDraws("discarded");
    REQUIRE(draws.size() == 1);
    REQUIRE(draws[0]->submesh_index == 1);
    REQUIRE(draws[0]->material_slot == 1);
    REQUIRE(draws[0]->output == SpecTex_Default);
    REQUIRE(! g.hasDraw(""));
}
TEST(RenderGraph, submeshOutputOverrideRoutesOnlyThatPass) {
    Scene s;
    defaults(s);
    target(s, auxiliary);
    target(s, maskTarget);
    auto                     n = append(s, "mask_subset", {}, auxiliary);
    std::vector<std::string> slots(9);
    slots[8] = maskTarget;
    n->Mesh()->AddMaterial(material("main_subset", slots));
    submesh(*n->Mesh(), 0, maskTarget);
    submesh(*n->Mesh(), 1);
    Observation g(s);
    REQUIRE(g.draw("mask_subset").output == maskTarget);
    const auto& main = g.draw("main_subset");
    REQUIRE(main.output == auxiliary);
    REQUIRE(main.textures.size() == 9);
    REQUIRE(main.textures[8] == maskTarget);
}
TEST(RenderGraph, generatedPuppetMaskSubmeshesRoutePrepassAndMainClip) {
    Scene s;
    defaults(s);
    target(s, maskTarget, 32, 24, true, true);
    auto n = append(s, "base_piece", { "picture" });
    n->Mesh()->AddMaterial(material("mask_piece", { "picture", "mask_picture" }));
    std::vector<std::string> slots(9);
    slots[0] = "picture";
    slots[8] = maskTarget;
    n->Mesh()->AddMaterial(material("clip_piece", slots));
    const std::array<SceneMesh::DrawRange, 1> range { { { 0, 3 } } };
    submesh(*n->Mesh(), 0, {}, range);
    submesh(*n->Mesh(), 1, maskTarget, range);
    submesh(*n->Mesh(), 2, {}, range);
    REQUIRE(! n->Mesh()->Submeshes()[1].DrawRanges().empty());
    REQUIRE(! n->Mesh()->Submeshes()[2].DrawRanges().empty());
    Observation g(s);
    const auto& mask = g.draw("mask_piece");
    const auto& clip = g.draw("clip_piece");
    REQUIRE(mask.submesh_index == 1);
    REQUIRE(mask.material_slot == 1);
    REQUIRE(mask.output == maskTarget);
    requirePolicy(mask, true, false);
    REQUIRE(clip.submesh_index == 2);
    REQUIRE(clip.material_slot == 2);
    REQUIRE(clip.output == SpecTex_Default);
    REQUIRE(clip.textures.size() == 9);
    REQUIRE(clip.textures[8] == maskTarget);
    REQUIRE(clip.preserve_target_contents);
}
TEST(RenderGraph, parsedMaskedPuppetMaterialSlotsReachRenderGraph) {
    auto files = ordinaryAssets();
    asset(
        files,
        "/models/masked.json",
        R"({"width":64,"height":40,"material":"materials/masked.json","puppet":"models/masked.mdl"})");
    materialAsset(files, "materials/masked.json", "contract_masked");
    shaderAsset(files, "contract_masked", true, false, true);
    shaderAsset(files, "clippingmaskimage4", false, true);
    files["/models/masked.mdl"] = maskedModel("materials/masked.json", "contract_mask_picture");
    files["/materials/contract_mask_picture.tex"] = {};
    ParseFixture parser(std::move(files));
    auto         s = parser.parse(sceneJson(imageJson(47, "parsed_masked", "models/masked.json")));
    Observation  g(*s);
    auto         draws = g.nodeDraws("parsed_masked");
    REQUIRE(draws.size() == 3);
    const DrawPass::Desc *base = nullptr, *mask = nullptr, *clip = nullptr;
    for (auto* d : draws) {
        if (d->submesh_index == 0) base = d;
        if (d->submesh_index == 1) mask = d;
        if (d->submesh_index == 2) clip = d;
    }
    REQUIRE(base);
    REQUIRE(mask);
    REQUIRE(clip);
    REQUIRE(base->material_slot == 0);
    REQUIRE(mask->material_slot == 1);
    REQUIRE(clip->material_slot == 2);
    REQUIRE(mask->output == maskTarget);
    REQUIRE(clip->textures.size() == 9);
    REQUIRE(clip->textures[8] == mask->output);
}
TEST(RenderGraph, skippedBasePassStillEmitsEffectPasses) {
    Scene s;
    defaults(s);
    auto owner = append(s, "skipped_base");
    owner->SetSkipRenderPass(true);
    auto layer = effectLayer(s, owner);
    layer->AddEffect(oneEffect(node("surviving_effect")));
    layer->ResolveEffect(s.default_effect_mesh, "contract_effect_camera");
    Observation g(s);
    REQUIRE(! g.hasDraw("skipped_base"));
    REQUIRE(g.hasDraw("surviving_effect"));
}
TEST(RenderGraph, composeBaseRunsBeforeChildrenAndEffectsAfterChildren) {
    Scene s;
    defaults(s);
    auto owner = append(s, "compose_base");
    owner->AppendChild(node("compose_child"));
    auto layer = effectLayer(s, owner, true);
    layer->AddEffect(oneEffect(node("compose_effect")));
    layer->ResolveEffect(s.default_effect_mesh, "contract_effect_camera");
    Observation g(s);
    REQUIRE(g.drawIndex("compose_base") < g.drawIndex("compose_child"));
    REQUIRE(g.drawIndex("compose_child") < g.drawIndex("compose_effect"));
}
TEST(RenderGraph, parsedContainerDeclarationOrderControlsRenderPassOrder) {
    ParseFixture parser(ordinaryAssets());
    auto         s = parser.parse(sceneJson(
        R"({"id":91,"name":"container"},)" + imageJson(92, "root_sibling", "models/card.json") +
        ',' + imageJson(93, "nested_image", "models/card.json", "\"parent\":91")));
    Observation  g(*s);
    REQUIRE(g.nodeIndex("nested_image") < g.nodeIndex("root_sibling"));
}
TEST(RenderGraph, parsedForwardParentDeclarationOrderControlsRenderPassOrder) {
    ParseFixture parser(ordinaryAssets());
    auto         s = parser.parse(sceneJson(
        imageJson(101, "forward_child", "models/card.json", "\"parent\":103") + ',' +
        imageJson(102, "root_image", "models/card.json") + R"(,{"id":103,"name":"late_parent"})"));
    Observation  g(*s);
    REQUIRE(g.nodeIndex("root_image") < g.nodeIndex("forward_child"));
}
TEST(RenderGraph, reusableNonDefaultTargetClearsOnlyOnFirstWriter) {
    Scene s;
    defaults(s);
    target(s, auxiliary);
    append(s, "first", {}, auxiliary);
    append(s, "second", {}, auxiliary);
    Observation g(s);
    requirePolicy(g.draw("first"), true, false);
    requirePolicy(g.draw("second"), false, true);
}
TEST(RenderGraph, forceClearReusableTargetClearsEveryWriter) {
    Scene s;
    defaults(s);
    target(s, auxiliary, 80, 48, true, true);
    append(s, "first", {}, auxiliary);
    append(s, "second", {}, auxiliary);
    Observation g(s);
    requirePolicy(g.draw("first"), true, false);
    requirePolicy(g.draw("second"), true, false);
}
TEST(RenderGraph, forceClearDoesNotChangeDefaultOutputPreservation) {
    Scene s;
    defaults(s);
    s.clearEnabled                                           = false;
    s.renderTargets[std::string(SpecTex_Default)].forceClear = true;
    append(s, "first");
    append(s, "second");
    Observation g(s);
    requirePolicy(g.draw("first"), false, false);
    requirePolicy(g.draw("second"), false, true);
}
TEST(RenderGraph, renderTargetSampleCountPropagatesToCustomPassDesc) {
    Scene s;
    defaults(s);
    target(s, auxiliary, 80, 48, true, false, 4);
    append(s, "multisampled", {}, auxiliary);
    Observation g(s);
    const auto& d = g.draw("multisampled");
    REQUIRE(d.output == auxiliary);
    REQUIRE(d.samples == 4);
}
TEST(RenderGraph, copyWrittenMsaaTargetsPreserveWithSingleSamplePasses) {
    Scene s;
    defaults(s);
    target(s, auxiliary, 80, 48, true, false, 4);
    append(s, "scene_writer");
    auto chain = post(s);
    chain->steps.emplace_back(ScenePostProcessCopy { std::string(SpecTex_Default), auxiliary });
    chain->steps.emplace_back(ScenePostProcessPass { node("after_copy"), auxiliary, 0 });
    Observation g(s);
    REQUIRE(g.copyIndex(SpecTex_Default, auxiliary) < g.drawIndex("after_copy"));
    requirePolicy(g.draw("after_copy"), false, true, 1);
}
TEST(RenderGraph, separateMsaaRenderTargetWritersPreserveWithMsaaSampleCount) {
    Scene s;
    defaults(s);
    target(s, auxiliary, 80, 48, true, false, 4);
    append(s, "first", {}, auxiliary);
    append(s, "second", {}, auxiliary);
    Observation g(s);
    requirePolicy(g.draw("first"), true, false, 4);
    requirePolicy(g.draw("second"), false, true, 4);
}
TEST(RenderGraph, videoTextureSamplingIsPreservedInMsaaScenePass) {
    Scene s;
    defaults(s);
    s.renderTargets[std::string(SpecTex_Default)].sample_count = 4;
    SceneTexture video {};
    video.url               = "contract_unopened_video";
    video.isVideo           = true;
    s.textures["video_key"] = video;
    append(s, "video_draw", { "video_key" });
    Observation g(s);
    const auto& d = g.draw("video_draw");
    REQUIRE(d.textures.size() == 1);
    REQUIRE(d.textures[0] == "video_key");
    REQUIRE(d.samples == 4);
}
TEST(RenderGraph, defaultOutputUsesSceneClearEnabledWhileNonDefaultWritesAlpha) {
    Scene s;
    defaults(s);
    s.clearEnabled = false;
    target(s, auxiliary);
    append(s, "scene_draw");
    append(s, "other_draw", {}, auxiliary);
    Observation g(s);
    REQUIRE(! g.draw("scene_draw").clear_on_first_use);
    REQUIRE(! g.draw("scene_draw").write_alpha);
    REQUIRE(g.draw("other_draw").clear_on_first_use);
    REQUIRE(g.draw("other_draw").write_alpha);
    Scene clear;
    defaults(clear);
    clear.clearEnabled = true;
    append(clear, "clear_scene");
    Observation h(clear);
    REQUIRE(h.draw("clear_scene").clear_on_first_use);
    REQUIRE(! h.draw("clear_scene").write_alpha);
}
TEST(RenderGraph, postProcessesAppendPassesAndCopiesAfterSceneGraph) {
    Scene s;
    defaults(s);
    target(s, auxiliary);
    target(s, "_rt_contract_post_copy");
    append(s, "ordinary");
    auto chain = post(s);
    chain->steps.emplace_back(ScenePostProcessPass { node("post_draw"), auxiliary, 0 });
    chain->steps.emplace_back(ScenePostProcessCopy { auxiliary, "_rt_contract_post_copy" });
    Observation g(s);
    REQUIRE(g.draw("post_draw").output == auxiliary);
    REQUIRE(g.drawIndex("ordinary") < g.drawIndex("post_draw"));
    REQUIRE(g.drawIndex("post_draw") < g.copyIndex(auxiliary, "_rt_contract_post_copy"));
}
TEST(RenderGraph, nullPostProcessPassNodesAreSkipped) {
    Scene s;
    defaults(s);
    target(s, auxiliary);
    target(s, "_rt_contract_null_post_copy");
    append(s, "ordinary");
    auto chain = post(s);
    chain->steps.emplace_back(ScenePostProcessPass { nullptr, auxiliary, 0 });
    chain->steps.emplace_back(ScenePostProcessPass { node("valid_post"), auxiliary, 0 });
    chain->steps.emplace_back(ScenePostProcessCopy { auxiliary, "_rt_contract_null_post_copy" });
    Observation g(s);
    REQUIRE(g.draw("valid_post").output == auxiliary);
    REQUIRE(g.drawIndex("valid_post") < g.copyIndex(auxiliary, "_rt_contract_null_post_copy"));
    for (const auto& step : g.steps)
        if (step.draw) REQUIRE(step.draw->desc().node);
}
TEST(RenderGraph, postProcessCopyStepsResolveRenderTargetAliases) {
    Scene s;
    defaults(s);
    target(s, auxiliary);
    target(s, "_rt_contract_destination");
    s.renderTargetAliases["_rt_contract_source_alias"] = auxiliary;
    s.renderTargetAliases["_rt_contract_dest_alias"]   = "_rt_contract_destination";
    auto chain                                         = post(s);
    chain->steps.emplace_back(
        ScenePostProcessPass { node("aliased_post"), "_rt_contract_source_alias", 0 });
    chain->steps.emplace_back(
        ScenePostProcessCopy { "_rt_contract_source_alias", "_rt_contract_dest_alias" });
    Observation g(s);
    REQUIRE(g.draw("aliased_post").output == auxiliary);
    REQUIRE(g.drawIndex("aliased_post") < g.copyIndex(auxiliary, "_rt_contract_destination"));
}
TEST(RenderGraph, linkedImageCompositeTexturesResolveToSourceLayerOutput) {
    Scene s;
    defaults(s);
    auto producer   = append(s, "ordinary_producer");
    producer->ID()  = 211;
    const auto link = GenLinkTex(211);
    append(s, "ordinary_consumer", { link });
    Observation g(s);
    const auto& consumer = g.draw("ordinary_consumer");
    REQUIRE(consumer.textures.size() == 1);
    REQUIRE(consumer.textures[0] == link);
    bool found = false;
    for (const auto& step : g.steps)
        if (step.copy && step.copy->desc().dst == link) found = true;
    REQUIRE(found);
}
TEST(RenderGraph, parsedInvisibleDependencySourceResolvesLinkedRenderTexture) {
    auto files = ordinaryAssets();
    materialAsset(files,
                  "materials/consumer.json",
                  "contract_consumer",
                  "[" + quote(LayerCompositeTargetKey(221)) + "]");
    shaderAsset(files, "contract_consumer");
    asset(files,
          "/models/consumer.json",
          R"({"width":80,"height":48,"material":"materials/consumer.json"})");
    ParseFixture parser(std::move(files));
    auto         s = parser.parse(sceneJson(
        imageJson(221, "hidden_source", "models/card.json", "\"visible\":false") + ',' +
        imageJson(222, "visible_consumer", "models/consumer.json", "\"dependencies\":[221]")));
    Observation  g(*s);
    const auto   link = GenLinkTex(221);
    const auto&  d    = g.nodeDraw("visible_consumer");
    REQUIRE(d.textures.size() == 1);
    REQUIRE(d.textures[0] == link);
    bool copied = false;
    for (const auto& step : g.steps)
        if (step.copy && step.copy->desc().dst == link) copied = true;
    REQUIRE(copied);
}

// These assets describe real parser inputs; empty .tex entrances are graph-only, not decoded
// pictures.
AssetMap accumulationAssets() {
    auto files = ordinaryAssets();
    asset(files, "/models/flat.json", R"({"material":"materials/card.json"})");
    materialAsset(files,
                  "materials/consumer.json",
                  "contract_consumer",
                  "[" + quote(LayerCompositeTargetKey(231)) + "]");
    shaderAsset(files, "contract_consumer");
    asset(files,
          "/models/consumer.json",
          R"({"width":80,"height":48,"material":"materials/consumer.json"})");
    materialAsset(files, "materials/accumulate.json", "contract_accumulate", "[null,null]");
    shaderAsset(files, "contract_accumulate");
    // Both bound inputs participate in the accumulation shader.
    asset(files,
          "/shaders/contract_accumulate.frag",
          "uniform sampler2D g_Texture0;\nuniform sampler2D g_Texture1;\nvarying vec2 "
          "v_ContractUV;\nvoid "
          "main(){gl_FragColor=0.6*texture2D(g_Texture0,v_ContractUV)+0.4*texture2D(g_Texture1,v_"
          "ContractUV);}\n");
    materialAsset(files, "materials/combine.json", "contract_combine", "[null]");
    shaderAsset(files, "contract_combine");
    asset(
        files,
        "/effects/accumulate.json",
        R"({"name":"contract accumulation","fbos":[{"name":"_rt_FullCompoBuffer_contract_a","scale":1},{"name":"_rt_FullCompoBuffer_contract_b","scale":1},{"name":"contract_tiny","scale":512}],"passes":[{"material":"materials/accumulate.json","target":"_rt_FullCompoBuffer_contract_b","bind":[{"name":"previous","index":0},{"name":"_rt_FullCompoBuffer_contract_a","index":1}]},{"command":"copy","source":"_rt_FullCompoBuffer_contract_b","target":"_rt_FullCompoBuffer_contract_a"},{"material":"materials/combine.json","bind":[{"name":"_rt_FullCompoBuffer_contract_b","index":0}]}]})");
    return files;
}
TEST(RenderGraph, parsedZeroHeightDependencyEffectUsesNonZeroRenderTargets) {
    ParseFixture parser(accumulationAssets());
    // Assemble this exceptional image explicitly, without duplicate scale fields.
    const std::string source =
        R"({"id":231,"name":"flat_source","image":"models/flat.json","origin":[0,0,0],"angles":[0,0,0],"size":[64,0],"scale":[0,0,0],"visible":false,"effects":[{"file":"effects/accumulate.json","id":239,"visible":true}]})";
    auto        s = parser.parse(sceneJson(
        source + ',' +
        imageJson(232, "flat_consumer", "models/consumer.json", "\"dependencies\":[231]")));
    Observation g(*s);
    const auto  link     = GenLinkTex(231);
    const auto& consumer = g.nodeDraw("flat_consumer");
    REQUIRE(consumer.textures.size() == 1);
    REQUIRE(consumer.textures[0] == link);
    bool copied = false;
    for (const auto& step : g.steps)
        if (step.copy && step.copy->desc().dst == link) copied = true;
    REQUIRE(copied);
    std::size_t full = 0, ping = 0, tiny = 0;
    for (const auto& [key, t] : s->renderTargets) {
        const bool isFull = key.find(WE_FULL_COMPO_BUFFER_PREFIX) != std::string::npos;
        const bool isPing = key.find(WE_EFFECT_PPONG_PREFIX) != std::string::npos;
        const bool isTiny = key.find("contract_tiny") != std::string::npos;
        if (! (isFull || isPing || isTiny)) continue;
        REQUIRE(t.width >= 4);
        REQUIRE(t.height >= 4);
        REQUIRE(static_cast<int64_t>(t.width) * t.height > 4);
        if (! isTiny) {
            REQUIRE(t.width == 64);
            REQUIRE(t.height == 360);
        }
        full += isFull;
        ping += isPing;
        tiny += isTiny;
    }
    REQUIRE(full >= 2);
    REQUIRE(ping >= 1);
    REQUIRE(tiny == 1);
}
TEST(RenderGraph, linkedEffectSourceFallsBackToBaseTargetWhenEffectsFailToLoad) {
    auto files = ordinaryAssets();
    materialAsset(files,
                  "materials/consumer.json",
                  "contract_consumer",
                  "[" + quote(LayerCompositeTargetKey(241)) + "]");
    shaderAsset(files, "contract_consumer");
    asset(files,
          "/models/consumer.json",
          R"({"width":80,"height":48,"material":"materials/consumer.json"})");
    asset(
        files,
        "/effects/missing.json",
        R"({"name":"unavailable material","passes":[{"material":"materials/deliberately_absent.json"}]})");
    ParseFixture                            parser(std::move(files));
    auto                                    s      = parser.parse(sceneJson(
        imageJson(
            241,
            "fallback_source",
            "models/card.json",
            R"("visible":false,"effects":[{"file":"effects/missing.json","id":249,"visible":true}])") +
        ',' +
        imageJson(242, "fallback_consumer", "models/consumer.json", "\"dependencies\":[241]")));
    auto                                    source = s->sceneGraph;
    std::shared_ptr<SceneNode>              owner;
    std::vector<std::shared_ptr<SceneNode>> pending { source };
    while (! pending.empty()) {
        auto n = pending.back();
        pending.pop_back();
        REQUIRE(n);
        if (n->Name() == "fallback_source") owner = n;
        for (auto& child : n->GetChildren())
            if (child) pending.push_back(child);
    }
    REQUIRE(owner);
    auto camera = s->cameras.find(owner->Camera());
    REQUIRE(camera != s->cameras.end());
    REQUIRE(camera->second);
    REQUIRE(camera->second->HasImgEffect());
    auto layer = camera->second->GetImgEffect();
    REQUIRE(layer);
    for (std::size_t i = 0; i < layer->EffectCount(); ++i) {
        auto effect = layer->GetEffect(i);
        REQUIRE(effect);
        REQUIRE(! effect->included || effect->nodes.empty());
    }
    const std::string first = layer->FirstTarget();
    Observation       g(*s);
    const auto        link = GenLinkTex(241);
    REQUIRE(g.nodeDraw("fallback_source").output == first);
    REQUIRE(g.copy(first, link));
    REQUIRE(g.nodeDraw("fallback_consumer").textures.size() == 1);
    REQUIRE(g.nodeDraw("fallback_consumer").textures[0] == link);
    REQUIRE(g.nodeIndex("fallback_source") < g.copyIndex(first, link));
    REQUIRE(g.copyIndex(first, link) < g.nodeIndex("fallback_consumer"));
}
TEST(RenderGraph, linkedEffectSourceDoesNotUseIntermediateTargetAsFallback) {
    Scene s;
    defaults(s);
    target(s, auxiliary);
    auto producer  = append(s, "intermediate_owner");
    producer->ID() = 251;
    producer->SetVisible(false);
    producer->SetMustProduce(true);
    s.layer_texture_sources.insert(251);
    auto              layer  = effectLayer(s, producer);
    const std::string first  = layer->FirstTarget();
    auto              effect = oneEffect(node("intermediate_only"), auxiliary);
    layer->AddEffect(effect);
    // Keep this authored intermediate destination; no resolver-generated final picture is supplied.
    const auto link = GenLinkTex(251);
    append(s, "negative_consumer", { link });
    Observation g(s);
    REQUIRE(g.draw("intermediate_only").output == auxiliary);
    const auto& consumer = g.draw("negative_consumer");
    REQUIRE(consumer.textures.size() == 1);
    REQUIRE(consumer.textures[0].empty());
    REQUIRE(! g.copy(first, link));
    REQUIRE(! g.copy(auxiliary, link));
    for (const auto& step : g.steps)
        if (step.copy) REQUIRE(step.copy->desc().dst != link);
}
TEST(RenderGraph, parsedFullscreenScaledFbosStayValidAfterScreenBindSizing) {
    auto files = ordinaryAssets();
    asset(files,
          "/models/fullscreen.json",
          R"({"fullscreen":true,"material":"materials/card.json"})");
    materialAsset(files, "materials/tiny.json", "contract_tiny_shader", "[null]");
    shaderAsset(files, "contract_tiny_shader");
    asset(
        files,
        "/effects/tiny.json",
        R"({"name":"tiny framebuffer","fbos":[{"name":"contract_fullscreen_tiny","scale":512}],"passes":[{"material":"materials/tiny.json","target":"contract_fullscreen_tiny","bind":[{"name":"previous","index":0}]},{"material":"materials/tiny.json","bind":[{"name":"contract_fullscreen_tiny","index":0}]}]})");
    ParseFixture parser(std::move(files));
    auto         s = parser.parse(
        sceneJson(imageJson(261,
                            "fullscreen",
                            "models/fullscreen.json",
                            R"("effects":[{"file":"effects/tiny.json","id":269,"visible":true}])"),
                  "\"zoom\":4"));
    auto* output = s->FindRenderTarget(SpecTex_Default);
    REQUIRE(output);
    REQUIRE(output->width == 160);
    REQUIRE(output->height == 90);
    std::string tinyKey;
    for (const auto& [key, t] : s->renderTargets)
        if (key.find("contract_fullscreen_tiny") != std::string::npos) {
            REQUIRE(tinyKey.empty());
            tinyKey = key;
            REQUIRE(t.bind.enable);
            REQUIRE(t.bind.screen);
            REQUIRE(std::abs(t.bind.scale - 1.0 / 512.0) < 1e-9);
        }
    REQUIRE(! tinyKey.empty());
    auto extents = render::ResolveScreenBoundRenderTargetSizes(*s, Extent2D { 999, 999 });
    REQUIRE(extents.raster.width >= 4);
    REQUIRE(extents.raster.height >= 4);
    auto* tiny = s->FindRenderTarget(tinyKey);
    REQUIRE(tiny);
    REQUIRE(tiny->width >= 4);
    REQUIRE(tiny->height >= 4);
    REQUIRE(static_cast<int64_t>(tiny->width) * tiny->height > 4);
}
TEST(RenderGraph, screenBoundSizingHonorsTinyAuthoredDefaultExtent) {
    Scene s;
    defaults(s);
    s.ortho[0]    = 640;
    s.ortho[1]    = 360;
    auto& output  = s.renderTargets[std::string(SpecTex_Default)];
    output.width  = 1;
    output.height = 90;
    REQUIRE(output.authored_width == 0);
    REQUIRE(output.authored_height == 0);
    target(s, auxiliary, 1, 90);
    auto& bound       = s.renderTargets[auxiliary];
    bound.bind.enable = true;
    bound.bind.screen = true;
    bound.bind.scale  = 1;
    for (int repeat = 0; repeat != 2; ++repeat) {
        auto extents = render::ResolveScreenBoundRenderTargetSizes(s, Extent2D { 999, 999 });
        REQUIRE(extents.source.width == 1);
        REQUIRE(extents.source.height == 90);
        REQUIRE(extents.raster.width == 4);
        REQUIRE(extents.raster.height == 90);
        REQUIRE(bound.width == 4);
        REQUIRE(bound.height == 90);
        REQUIRE(output.authored_width == 1);
        REQUIRE(output.authored_height == 90);
        REQUIRE(output.width == 4);
        REQUIRE(output.height == 90);
    }
}
} // namespace
} // namespace graph_contract
