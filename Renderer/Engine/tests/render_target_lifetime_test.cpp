#include "RenderGraph/RenderGraph.hpp"
#include "RenderGraph/Pass.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "RenderCommon/ScenePass.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include <gtest/gtest.h>

#include <algorithm>
#include <string>
#include <vector>

namespace wallpaper {
namespace {
struct TestPass : rg::Pass {
    struct Desc {};
    TestPass(const Desc&) {}
};

TEST(RenderTargetLifetime, ReleasesOnceAfterAllVersionsAndBlendOnlyWrites) {
    rg::RenderGraph graph;
    rg::TexNode* first = nullptr;
    rg::TexNode* second = nullptr;
    rg::TexNode::Desc target { .name = "_rt_ping", .key = "_rt_ping", .type = rg::TexNode::TexType::Temp };
    graph.addPass<TestPass>("first write", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { first = b.createTexNode(target, true); b.write(first); });
    graph.addPass<TestPass>("first read", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { b.read(first); });
    graph.addPass<TestPass>("second write", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { second = b.createTexNode(target, true); b.write(second); });
    graph.addPass<TestPass>("second read", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { b.read(second); });
    auto* last = graph.addPass<TestPass>("blend only", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { b.write(b.createTexNode(target, true)); });
    const auto order = graph.topologicalOrder();
    const auto releases = graph.getLastReadTexs(order);
    int count = 0;
    for (std::size_t i = 0; i < releases.size(); ++i) {
        for (const auto* tex : releases[i]) {
            if (tex->key() != "_rt_ping") continue;
            ++count;
            EXPECT_EQ(order[i], last->ID());
        }
    }
    EXPECT_EQ(count, 1);
}

std::shared_ptr<SceneNode> Node(std::string name, std::vector<std::string> textures = {}) {
    auto node = std::make_shared<SceneNode>();
    node->SetName(name);
    node->ID() = 1;
    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial mat;
    mat.name = name;
    mat.textures = std::move(textures);
    mesh->AddMaterial(std::move(mat));
    node->AddMesh(mesh);
    return node;
}

TEST(RenderTargetLifetime, NoBackgroundEffectGetsRealTransparentWriterBeforeSampling) {
    Scene scene;
    scene.renderTargets[std::string(SpecTex_Default)] = { .width = 64, .height = 64 };
    const std::string input = std::string(WE_EFFECT_PPONG_PREFIX_A) + "probe";
    scene.renderTargets[input] = { .width = 16, .height = 16, .allowReuse = true };
    auto owner = Node("empty compose");
    owner->SetSkipRenderPass(true);
    owner->SetCamera("local");
    auto camera = std::make_shared<SceneCamera>(16, 16, -1, 1);
    auto layer = std::make_shared<SceneImageEffectLayer>(owner.get(), 16, 16, input, "_rt_ping_b");
    layer->SetFinalBlend(BlendMode::Translucent);
    auto effect = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back({ std::string(SpecTex_Default), Node("scroll", {input}) });
    layer->AddEffect(effect);
    camera->AttatchImgEffect(layer);
    scene.cameras["local"] = camera;
    scene.sceneGraph->AppendChild(owner);
    auto graph = sceneToRenderGraph(scene);
    const auto order = graph->topologicalOrder();
    ASSERT_EQ(order.size(), 2u);
    auto* clear = dynamic_cast<rg::ClearPass*>(graph->getPass(order[0]));
    ASSERT_NE(clear, nullptr);
    EXPECT_EQ(clear->desc().result, input);
    EXPECT_TRUE(clear->desc().transparent);
    auto* draw = dynamic_cast<rg::DrawPass*>(graph->getPass(order[1]));
    ASSERT_NE(draw, nullptr);
    EXPECT_EQ(draw->desc().textures[0], input);
    EXPECT_EQ(graph->getLastReadTexs(order)[1][0]->key(), input);
}

// Motion blur blends each frame into the one before: its accumulation reads a
// history target that nothing this frame has written yet, and a copy stores the
// blend there for the next frame. Pooled, the history's image went to whatever
// target came next, so the next frame blended in that target's pixels -- a
// faint copy of some other layer jumping about. Only such a target keeps its
// own image; the effect's other targets and the scene output stay as they were.
TEST(RenderTargetLifetime, OnlyTargetsReadBeforeTheFrameWritesThemKeepTheirOwnImage) {
    Scene scene;
    scene.renderTargets[std::string(SpecTex_Default)] = { .width = 64, .height = 64 };
    const std::string input   = std::string(WE_EFFECT_PPONG_PREFIX_A) + "trail";
    const std::string output  = std::string(WE_EFFECT_PPONG_PREFIX_B) + "trail";
    const std::string history = "_rt_trail_history";
    const std::string blend   = "_rt_trail_blend";
    for (const auto& name : { input, output, history, blend }) {
        scene.renderTargets[name] = { .width = 16, .height = 16, .allowReuse = true };
    }
    auto owner = Node("trailing layer");
    owner->SetCamera("local");
    auto camera = std::make_shared<SceneCamera>(16, 16, -1, 1);
    auto layer  = std::make_shared<SceneImageEffectLayer>(owner.get(), 16, 16, input, output);
    layer->SetFinalBlend(BlendMode::Translucent);
    auto effect = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back({ blend, Node("accumulate", { input, history }) });
    effect->commands.push_back({ .dst = history, .src = blend, .afterpos = 1 });
    effect->nodes.push_back({ std::string(SpecTex_Default), Node("combine", { blend }) });
    layer->AddEffect(effect);
    camera->AttatchImgEffect(layer);
    scene.cameras["local"]  = camera;
    scene.cameras["effect"] = std::make_shared<SceneCamera>(16, 16, -1, 1);
    scene.sceneGraph->AppendChild(owner);

    const auto graph = sceneToRenderGraph(scene);
    ASSERT_NE(graph, nullptr);

    EXPECT_TRUE(scene.renderTargets.at(history).carriesPreviousFrame);
    EXPECT_FALSE(scene.renderTargets.at(history).allowReuse);
    for (const auto& name : { input, blend }) {
        SCOPED_TRACE(name);
        EXPECT_FALSE(scene.renderTargets.at(name).carriesPreviousFrame);
        EXPECT_TRUE(scene.renderTargets.at(name).allowReuse);
    }
    EXPECT_FALSE(scene.renderTargets.at(std::string(SpecTex_Default)).carriesPreviousFrame);
}

TEST(RenderTargetLifetime, CarriedOverKeysAreTheOnesReadBeforeTheirFirstWrite) {
    for (int seed = 1; seed <= 32; ++seed) {
        SCOPED_TRACE(seed);
        rg::RenderGraph graph;
        std::map<rg::NodeID, std::pair<std::string, std::string>> accesses;
        for (int i = 0; i < 40; ++i) {
            const auto read  = "_rt_" + std::to_string((i * seed + 3) % 9);
            const auto write = "_rt_" + std::to_string((i + seed) % 7);
            auto* pass = graph.addPass<TestPass>("generated", rg::PassNode::Type::CustomShader,
                [&](auto& b, auto&) {
                    b.read(b.createTexNode({.name = read, .key = read, .type = rg::TexNode::TexType::Temp}));
                    b.write(b.createTexNode({.name = write, .key = write, .type = rg::TexNode::TexType::Temp}, true));
                });
            accesses[pass->ID()] = { read, write };
        }
        const auto order = graph.topologicalOrder();
        std::set<std::string> accessed, read_first, written;
        for (const auto id : order) {
            const auto& [read, write] = accesses.at(id);
            if (accessed.insert(read).second) read_first.insert(read);
            accessed.insert(write);
            written.insert(write);
        }
        std::set<std::string> expected;
        for (const auto& key : read_first)
            if (written.contains(key)) expected.insert(key);
        const auto carried = graph.getCarriedOverKeys(order);
        EXPECT_EQ(std::set<std::string>(carried.begin(), carried.end()), expected);
        EXPECT_EQ(carried.size(), expected.size());
    }
}
// Exercise the rule with different names, dimensions, nesting and visibility;
// nothing here depends on a workshop ID, shader name or clock layer.
TEST(RenderTargetLifetime, NestedCompositesClearBeforeChildrenWithoutErasingThem) {
    for (bool copy_background : {false, true}) {
        for (bool visible : {false, true}) {
            for (int dimension : {16, 127, 512}) {
                SCOPED_TRACE(::testing::Message() << copy_background << ',' << visible << ',' << dimension);
                Scene scene;
                scene.renderTargets[std::string(SpecTex_Default)] = { .width = 800, .height = 600 };
                scene.cameras["global"] = std::make_shared<SceneCamera>(800, 600, -1, 1);
                scene.activeCamera = scene.cameras["global"].get();
                auto outer = Node("outer");
                auto inner = Node("inner");
                auto child = Node("child");
                auto sibling = Node("sibling");
                outer->ID() = 101; inner->ID() = 202; child->ID() = 303; sibling->ID() = 404;
                outer->SetVisible(visible);
                outer->AppendChild(inner); inner->AppendChild(child); inner->AppendChild(sibling);
                scene.sceneGraph->AppendChild(outer);
                for (auto owner : {outer, inner}) {
                    const auto name = owner->Name();
                    const auto input = std::string(WE_EFFECT_PPONG_PREFIX_A) + name;
                    const auto ping_b = std::string(WE_EFFECT_PPONG_PREFIX_B) + name;
                    scene.renderTargets[input] = { .width = dimension, .height = dimension + 1, .allowReuse = true };
                    scene.renderTargets[ping_b] = scene.renderTargets[input];
                    // Multisampled, so a draw after the transfer clear visibly
                    // keeps the single-sample path it had while it loaded.
                    scene.renderTargets[input].sample_count = 4;
                    // Test aliases as well as logical versions of the same key.
                    const auto alias = "_alias_" + name;
                    scene.renderTargetAliases[alias] = input;
                    auto layer = std::make_shared<SceneImageEffectLayer>(owner.get(), dimension, dimension + 1, alias, ping_b);
                    layer->SetFinalBlend(BlendMode::Translucent);
                    auto effect = std::make_shared<SceneImageEffect>();
                    effect->nodes.push_back({std::string(SpecTex_Default), Node(name + " result", {input})});
                    layer->AddEffect(effect);
                    auto camera = std::make_shared<SceneCamera>(dimension, dimension + 1, -1, 1);
                    camera->SetComposeLayer(true);
                    camera->AttatchNode(owner);
                    camera->AttatchImgEffect(layer);
                    scene.cameras[name] = camera;
                    owner->SetCamera(name);
                    owner->SetSkipRenderPass(!copy_background);
                }
                auto graph = sceneToRenderGraph(scene);
                const auto order = graph->topologicalOrder();
                std::map<std::string, std::size_t> index;
                int clears = 0;
                for (std::size_t i = 0; i < order.size(); ++i) {
                    if (auto* clear = dynamic_cast<rg::ClearPass*>(graph->getPass(order[i]))) {
                        ++clears;
                        EXPECT_TRUE(clear->desc().transparent);
                        index[clear->desc().result] = i;
                    }
                    if (auto* draw = dynamic_cast<rg::DrawPass*>(graph->getPass(order[i]))) {
                        index[draw->desc().node->Name()] = i;
                        const auto& name = draw->desc().node->Name();
                        // The first draw into a composite cleared to transparent
                        // opens with that clear (same value, so the separate one is
                        // redundant); one over a copied background loads it. Every
                        // draw after the first loads, so nothing drawn is erased.
                        if (name == "child" || name == "inner result") {
                            EXPECT_EQ(draw->desc().clear_on_first_use, ! copy_background) << name;
                            EXPECT_EQ(draw->desc().preserve_target_contents, copy_background) << name;
                        }
                        if (name == "sibling") {
                            EXPECT_FALSE(draw->desc().clear_on_first_use);
                            EXPECT_TRUE(draw->desc().preserve_target_contents);
                        }
                        if (! copy_background &&
                            (name == "child" || name == "sibling" || name == "inner result")) {
                            EXPECT_EQ(draw->desc().samples, 1u) << name;
                        }
                    }
                }
                EXPECT_EQ(clears, copy_background ? 0 : 2);
                const auto outer_start = copy_background ? "outer" : std::string(WE_EFFECT_PPONG_PREFIX_A) + "outer";
                const auto inner_start = copy_background ? "inner" : std::string(WE_EFFECT_PPONG_PREFIX_A) + "inner";
                ASSERT_TRUE(index.contains(outer_start)); ASSERT_TRUE(index.contains(inner_start));
                // Independent offscreen subtrees may execute in either order.
                // Only a write into the parent's target must follow its clear.
                EXPECT_LT(index[outer_start], index["inner result"]);
                EXPECT_LT(index[inner_start], index["child"]);
                EXPECT_LT(index["child"], index["sibling"]);
                EXPECT_LT(index["sibling"], index["inner result"]);
                EXPECT_LT(index["inner result"], index["outer result"]);
            }
        }
    }
}

TEST(RenderTargetLifetime, ReleasePlanMatchesLastAccessForGeneratedMultiVersionGraphs) {
    for (int seed = 1; seed <= 32; ++seed) {
        SCOPED_TRACE(seed);
        rg::RenderGraph graph;
        std::map<rg::NodeID, std::set<std::string>> accesses;
        for (int i = 0; i < 60; ++i) {
            const auto read = "_rt_" + std::to_string((i * seed + 3) % 7);
            const auto write = "_rt_" + std::to_string((i + seed) % 7);
            auto* pass = graph.addPass<TestPass>("generated", rg::PassNode::Type::CustomShader,
                [&](auto& b, auto&) {
                    b.read(b.createTexNode({.name = read, .key = read, .type = rg::TexNode::TexType::Temp}));
                    b.write(b.createTexNode({.name = write, .key = write, .type = rg::TexNode::TexType::Temp}, true));
                });
            accesses[pass->ID()] = {read, write};
        }
        const auto order = graph.topologicalOrder();
        ASSERT_EQ(order.size(), 60u);
        std::map<std::string, std::size_t> last_access;
        for (std::size_t i = 0; i < order.size(); ++i)
            for (const auto& key : accesses[order[i]]) last_access[key] = i;
        const auto releases = graph.getLastReadTexs(order);
        std::set<std::string> released;
        for (std::size_t i = 0; i < releases.size(); ++i) {
            for (const auto* tex : releases[i]) {
                const std::string key(tex->key());
                EXPECT_TRUE(released.insert(key).second);
                EXPECT_EQ(last_access.at(key), i);
            }
        }
        EXPECT_EQ(released.size(), last_access.size());
    }
}

TEST(RenderTargetLifetime, DrawsIntoOneTargetStayTogetherWhereTheDependenciesAllow) {
    // Three layers, each drawing a card and a step into its own buffers and then a final
    // pass onto the shared output. The finals have no reason to be apart, and a backend
    // draws consecutive passes into one image with a single render pass.
    rg::RenderGraph graph;
    const auto add = [&](const char* name, std::vector<std::string> reads, const std::string& write) {
        return graph.addPass<TestPass>(name, rg::PassNode::Type::CustomShader,
            [&](auto& b, auto&) {
                for (const auto& key : reads)
                    b.read(b.createTexNode({ .name = key, .key = key, .type = rg::TexNode::TexType::Temp }));
                b.write(b.createTexNode({ .name = write, .key = write, .type = rg::TexNode::TexType::Temp }, true));
            });
    };
    std::vector<rg::NodeID> finals, steps;
    for (int layer = 0; layer < 3; ++layer) {
        const std::string card = "card" + std::to_string(layer), step = "step" + std::to_string(layer);
        add("card", {}, card);
        steps.push_back(add("step", { card }, step)->ID());
        finals.push_back(add("final", { step }, "out")->ID());
    }
    const auto order = graph.topologicalOrder();
    ASSERT_EQ(order.size(), 9u);
    std::vector<std::size_t> at;
    for (std::size_t i = 0; i < order.size(); ++i)
        if (std::find(finals.begin(), finals.end(), order[i]) != finals.end()) at.push_back(i);
    ASSERT_EQ(at.size(), 3u);
    EXPECT_EQ(at[1], at[0] + 1);
    EXPECT_EQ(at[2], at[1] + 1);
    // The draws onto the output keep the order they were added in.
    EXPECT_EQ(order[at[0]], finals[0]);
    EXPECT_EQ(order[at[1]], finals[1]);
    EXPECT_EQ(order[at[2]], finals[2]);
    // Passes that depend on each other keep their direction.
    const auto position = [&](rg::NodeID id) {
        return std::find(order.begin(), order.end(), id) - order.begin();
    };
    for (std::size_t layer = 0; layer < 3; ++layer)
        EXPECT_LT(position(steps[layer]), position(finals[layer]));
    // Independent passes into different targets keep creation order, whatever the call.
    rg::RenderGraph plain;
    std::vector<rg::NodeID> ids;
    for (const char* key : { "a", "b", "c" })
        ids.push_back(plain.addPass<TestPass>(key, rg::PassNode::Type::CustomShader,
            [&](auto& b, auto&) {
                b.write(b.createTexNode({ .name = key, .key = key, .type = rg::TexNode::TexType::Temp }, true));
            })->ID());
    EXPECT_EQ(plain.topologicalOrder(), ids);
    EXPECT_EQ(plain.topologicalOrder(), plain.topologicalOrder());
}

rg::PassNode* AddTempPass(rg::RenderGraph& graph, const char* name, const std::vector<std::string>& reads,
                          const std::string& write) {
    return graph.addPass<TestPass>(name, rg::PassNode::Type::CustomShader, [&](auto& b, auto&) {
        for (const auto& key : reads)
            b.read(b.createTexNode({ .name = key, .key = key, .type = rg::TexNode::TexType::Temp }));
        b.write(b.createTexNode({ .name = write, .key = write, .type = rg::TexNode::TexType::Temp }, true));
    });
}

TEST(RenderTargetLifetime, ABufferIsNotFilledAheadOfUnrelatedWorkBeforeItsReader) {
    // Two draws onto the output, a pass that samples the output so far into a buffer of its
    // own, a draw that reads that buffer and draws onto the output again, then three layers
    // that each draw a card into a buffer and a final pass onto the output. The last draw and
    // the finals are one stretch onto the output, so the cards go in front of that stretch.
    // Nothing makes them run before the output was sampled, and doing so would keep their
    // buffers alive through all of it.
    rg::RenderGraph graph;
    const auto first  = AddTempPass(graph, "first", {}, "out")->ID();
    const auto second = AddTempPass(graph, "second", {}, "out")->ID();
    const auto sample = AddTempPass(graph, "sample", { "out" }, "grab")->ID();
    const auto blend  = AddTempPass(graph, "blend", { "grab" }, "out")->ID();
    std::vector<rg::NodeID> cards, finals;
    for (int layer = 0; layer < 3; ++layer) {
        const std::string card = "card" + std::to_string(layer);
        cards.push_back(AddTempPass(graph, "card", {}, card)->ID());
        finals.push_back(AddTempPass(graph, "final", { card }, "out")->ID());
    }
    const auto order = graph.topologicalOrder();
    ASSERT_EQ(order.size(), 10u);
    const auto position = [&](rg::NodeID id) {
        return std::find(order.begin(), order.end(), id) - order.begin();
    };
    EXPECT_LT(position(first), position(second));
    EXPECT_LT(position(second), position(sample));
    EXPECT_LT(position(sample), position(blend));
    for (std::size_t layer = 0; layer < 3; ++layer) {
        EXPECT_GT(position(cards[layer]), position(sample)) << "card " << layer << " was drawn too early";
        EXPECT_LT(position(cards[layer]), position(finals[layer]));
    }
    // The stretch onto the output stays one stretch, in the order the draws were added.
    EXPECT_EQ(position(finals[0]), position(blend) + 1);
    EXPECT_EQ(position(finals[1]), position(finals[0]) + 1);
    EXPECT_EQ(position(finals[2]), position(finals[1]) + 1);
}

TEST(RenderTargetLifetime, EveryPassRunsOnceAfterEverythingItDependsOnInGeneratedGraphs) {
    // Passes that read one or two of nine targets and write one of seven. A pass runs after
    // an earlier pass when that one writes something it touches or it writes something the
    // earlier one reads, so the check names every such pair, not only the nearest.
    for (int seed = 1; seed <= 32; ++seed) {
        SCOPED_TRACE(seed);
        const auto build = [&](std::vector<std::pair<std::set<std::string>, std::string>>& accesses) {
            auto graph = std::make_unique<rg::RenderGraph>();
            std::vector<rg::NodeID> ids;
            for (int i = 0; i < 60; ++i) {
                std::set<std::string> reads { "_rt_" + std::to_string((i * seed + 3) % 9) };
                if (i % 3 == 0) reads.insert("_rt_" + std::to_string((i + 2 * seed) % 9));
                const auto write = "_rt_" + std::to_string((i + seed) % 7);
                ids.push_back(AddTempPass(*graph, "generated", { reads.begin(), reads.end() }, write)->ID());
                accesses.emplace_back(reads, write);
            }
            return std::make_pair(std::move(graph), ids);
        };
        std::vector<std::pair<std::set<std::string>, std::string>> accesses;
        auto [graph, ids] = build(accesses);
        const auto order = graph->topologicalOrder();
        ASSERT_EQ(order.size(), ids.size());
        EXPECT_EQ(std::set<rg::NodeID>(order.begin(), order.end()).size(), ids.size());
        std::map<rg::NodeID, std::size_t> position;
        for (std::size_t i = 0; i < order.size(); ++i) position[order[i]] = i;
        for (std::size_t later = 0; later < ids.size(); ++later) {
            for (std::size_t earlier = 0; earlier < later; ++earlier) {
                const auto& [earlier_reads, earlier_write] = accesses[earlier];
                const auto& [later_reads, later_write]     = accesses[later];
                const bool conflict = later_reads.contains(earlier_write) || later_write == earlier_write ||
                                      earlier_reads.contains(later_write);
                if (conflict) EXPECT_LT(position[ids[earlier]], position[ids[later]]) << earlier << " before " << later;
            }
        }
        // The same graph built again gives the same order.
        std::vector<std::pair<std::set<std::string>, std::string>> again_accesses;
        auto [again, again_ids] = build(again_accesses);
        EXPECT_EQ(again->topologicalOrder(), order);
    }
}

TEST(RenderTargetLifetime, PassesOnADependencyCycleAreStillEachReturnedOnce) {
    // A pass that reads what a later pass writes closes a cycle; the order has to hold every
    // pass once, whatever it makes of the passes on the cycle.
    rg::RenderGraph graph;
    rg::TexNode*    second_output = nullptr;
    const auto      first = graph.addPass<TestPass>("first", rg::PassNode::Type::CustomShader,
                                                    [&](auto& b, auto&) {
        b.write(b.createTexNode({ .name = "a", .key = "a", .type = rg::TexNode::TexType::Temp }, true));
    });
    const auto second = graph.addPass<TestPass>("second", rg::PassNode::Type::CustomShader,
                                                [&](auto& b, auto&) {
        b.read(b.createTexNode({ .name = "a", .key = "a", .type = rg::TexNode::TexType::Temp }));
        second_output = b.createTexNode({ .name = "b", .key = "b", .type = rg::TexNode::TexType::Temp }, true);
        b.write(second_output);
    });
    const auto third = AddTempPass(graph, "third", { "b" }, "c");
    ASSERT_TRUE(graph.afterBuild(first->ID(), [&](auto& b, auto&) {
        b.read(second_output);
        return true;
    }));
    EXPECT_TRUE(graph.mustPrecede(first->ID(), second->ID()));
    EXPECT_TRUE(graph.mustPrecede(second->ID(), first->ID()));
    const auto order = graph.topologicalOrder();
    ASSERT_EQ(order.size(), 3u);
    EXPECT_EQ(std::set<rg::NodeID>(order.begin(), order.end()),
              (std::set<rg::NodeID> { first->ID(), second->ID(), third->ID() }));
    EXPECT_EQ(graph.topologicalOrder(), order);
}
} // namespace
} // namespace wallpaper
