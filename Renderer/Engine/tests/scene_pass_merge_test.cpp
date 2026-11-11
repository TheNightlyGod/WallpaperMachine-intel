#include "graph_contract_support.hpp"
#include <gtest/gtest.h>

// Where a scene's objects are drawn in their own order (a layer samples another layer's
// picture) but never re-sorted while the scene runs, a layer's own effect buffers are drawn
// ahead of the draws into the scene's image around it, so those draws share one render pass;
// every read still sees the picture it saw before.
namespace graph_contract {
namespace {

/// Puts the switch back however the test ends.
struct MergeSwitch {
    bool was;
    explicit MergeSwitch(bool enabled): was(SetScenePassMergeForTests(enabled)) {}
    ~MergeSwitch() { SetScenePassMergeForTests(was); }
};

/// A layer whose picture goes through two effects: its card into the chain's first buffer,
/// `middle` from there (or from `middle_reads`) into the second, and `final` from the second
/// onto the scene.
void chainedLayer(Scene& scene, const std::shared_ptr<SceneNode>& owner, const std::string& name,
                  std::vector<std::string> middle_reads = {}) {
    const std::string a = std::string(WE_EFFECT_PPONG_PREFIX_A) + name;
    const std::string b = std::string(WE_EFFECT_PPONG_PREFIX) + name + "_b";
    target(scene, a);
    target(scene, b);
    auto layer  = std::make_shared<SceneImageEffectLayer>(owner.get(), 80, 48, a, b);
    auto camera = std::make_shared<SceneCamera>(80, 48, -1, 1);
    camera->AttatchNode(owner);
    camera->AttatchImgEffect(layer);
    scene.cameras[name + "_camera"] = camera;
    owner->SetCamera(name + "_camera");
    if (middle_reads.empty()) middle_reads = { a };
    layer->AddEffect(oneEffect(node(name + "-middle", std::move(middle_reads)), b));
    layer->AddEffect(oneEffect(node(name + "-final", { b })));
}

/// The positions in the order of the passes drawing into the scene's own image.
std::vector<std::size_t> sceneDraws(const Observation& graph) {
    std::vector<std::size_t> found;
    for (std::size_t i = 0; i < graph.steps.size(); ++i) {
        const auto* draw = graph.steps[i].draw;
        if (draw != nullptr && draw->desc().output == SpecTex_Default) found.push_back(i);
    }
    return found;
}

/// The position of `name`'s draw into the scene's own image.
std::size_t sceneDrawOf(const Observation& graph, std::string_view name) {
    for (const std::size_t i : sceneDraws(graph))
        if (graph.steps[i].draw->desc().node->Name() == name) return i;
    ADD_FAILURE() << name << " draws nothing into the scene's image";
    return graph.steps.size();
}

/// Whether nothing drawing elsewhere runs between the first and the last scene draw.
bool sceneDrawsAdjacent(const Observation& graph) {
    const auto draws = sceneDraws(graph);
    return ! draws.empty() && draws.back() - draws.front() + 1 == draws.size();
}

/// `before` is a plain card another layer samples, `chained` a layer with two effects,
/// `after` a card sampling `before`'s picture: the sample orders the scene's objects.
struct LinkedScene {
    Scene                      scene;
    std::shared_ptr<SceneNode> before, chained, after;
    LinkedScene() {
        defaults(scene);
        before     = append(scene, "before");
        before->ID() = 1;
        scene.layer_texture_sources.insert(1);
        chained = append(scene, "chained");
        chained->ID() = 2;
        chainedLayer(scene, chained, "chained");
        after = append(scene, "after", { GenLinkTex(1) });
        after->ID() = 3;
    }
};

TEST(ScenePassMerge, ALayersOwnBuffersAreDrawnAheadOfTheSceneDrawsAroundIt) {
    MergeSwitch merge(true);
    LinkedScene linked;
    Observation graph(linked.scene);
    // The three draws into the scene's image follow one another...
    EXPECT_TRUE(sceneDrawsAdjacent(graph));
    EXPECT_LT(sceneDrawOf(graph, "before"), graph.drawIndex("chained-final"));
    EXPECT_LT(graph.drawIndex("chained-final"), graph.drawIndex("after"));
    // ...the chain runs before the first of them, in its own order...
    EXPECT_LT(graph.drawIndex("chained"), graph.drawIndex("chained-middle"));
    EXPECT_LT(graph.drawIndex("chained-middle"), sceneDraws(graph).front());
    // ...and the sample still reads the picture `before` drew this frame.
    const auto composite = LayerCompositeTargetKey(1);
    EXPECT_EQ(graph.draw("after").textures[0], composite);
    std::size_t composite_draw = graph.steps.size();
    for (std::size_t i = 0; i < graph.steps.size(); ++i) {
        const auto* draw = graph.steps[i].draw;
        if (draw != nullptr && draw->desc().output == composite) composite_draw = i;
    }
    ASSERT_LT(composite_draw, graph.steps.size());
    EXPECT_LT(composite_draw, graph.drawIndex("after"));
    ASSERT_NE(linked.scene.FindRenderTarget(composite), nullptr);
    EXPECT_FALSE(linked.scene.FindRenderTarget(composite)->carriesPreviousFrame);
}

TEST(ScenePassMerge, SwitchedOffEveryObjectRunsAsOneBlockAgain) {
    MergeSwitch merge(false);
    LinkedScene linked;
    Observation graph(linked.scene);
    EXPECT_FALSE(sceneDrawsAdjacent(graph));
    // `before` finishes, then every pass of `chained`, then `after`.
    EXPECT_LT(sceneDrawOf(graph, "before"), graph.drawIndex("chained"));
    EXPECT_LT(graph.drawIndex("chained"), graph.drawIndex("chained-middle"));
    EXPECT_LT(graph.drawIndex("chained-middle"), graph.drawIndex("chained-final"));
    EXPECT_LT(graph.drawIndex("chained-final"), graph.drawIndex("after"));
}

TEST(ScenePassMerge, AReaderOfALaterLayerStillSeesItsPreviousPicture) {
    // `after` samples a layer drawn after it: it reads that layer's picture of the previous
    // frame, so it still runs before the layer's draw replaces it, merge or not.
    for (const bool enabled : { true, false }) {
        SCOPED_TRACE(enabled);
        MergeSwitch merge(enabled);
        Scene scene;
        defaults(scene);
        auto reader = append(scene, "reader", { GenLinkTex(3) });
        reader->ID() = 1;
        auto chained = append(scene, "chained");
        chained->ID() = 2;
        chainedLayer(scene, chained, "chained");
        auto source = append(scene, "source");
        source->ID() = 3;
        scene.layer_texture_sources.insert(3);
        Observation graph(scene);
        const auto composite = LayerCompositeTargetKey(3);
        EXPECT_EQ(graph.draw("reader").textures[0], composite);
        std::size_t composite_draw = graph.steps.size();
        for (std::size_t i = 0; i < graph.steps.size(); ++i) {
            const auto* draw = graph.steps[i].draw;
            if (draw != nullptr && draw->desc().output == composite) composite_draw = i;
        }
        ASSERT_LT(composite_draw, graph.steps.size());
        EXPECT_LT(graph.drawIndex("reader"), composite_draw);
        ASSERT_NE(scene.FindRenderTarget(composite), nullptr);
        EXPECT_TRUE(scene.FindRenderTarget(composite)->carriesPreviousFrame);
        // The scene's image is still drawn in the objects' order.
        EXPECT_LT(graph.drawIndex("reader"), graph.drawIndex("chained-final"));
        EXPECT_LT(graph.drawIndex("chained-final"), sceneDrawOf(graph, "source"));
    }
}

TEST(ScenePassMerge, ALayerReadingTheSceneBehindItStillSplitsTheScenesRenderPass) {
    // A layer whose effect samples the scene's image as the layers before it left it has to
    // run between their draws and its own: that read is a real dependency.
    MergeSwitch merge(true);
    LinkedScene linked;
    auto reads_scene = append(linked.scene, "reads-scene");
    reads_scene->ID() = 4;
    // The middle effect of `behind` samples the scene's image.
    chainedLayer(linked.scene, reads_scene, "behind", { std::string(SpecTex_Default) });
    Observation graph(linked.scene);
    EXPECT_FALSE(sceneDrawsAdjacent(graph));
    EXPECT_LT(graph.drawIndex("after"), graph.drawIndex("behind-middle"));
    EXPECT_LT(graph.drawIndex("behind-middle"), graph.drawIndex("behind-final"));
}

TEST(ScenePassMerge, ADepthSortedSceneKeepsEveryObjectAsOneBlock) {
    // Sorted transparency moves whole objects while the scene runs, so their passes stay
    // together whatever the switch says.
    MergeSwitch merge(true);
    LinkedScene linked;
    linked.scene.transparent_sorting = true;
    Observation graph(linked.scene);
    EXPECT_LT(graph.drawIndex("chained"), graph.drawIndex("chained-middle"));
    EXPECT_LT(graph.drawIndex("chained-middle"), graph.drawIndex("chained-final"));
    EXPECT_EQ(graph.drawIndex("chained-final") - graph.drawIndex("chained"), 2u);
}

} // namespace
} // namespace graph_contract
