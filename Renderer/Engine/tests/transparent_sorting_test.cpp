#include "graph_contract_support.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include <gtest/gtest.h>
#include <cmath>

namespace graph_contract {
namespace {
std::string SortCard(int id, std::string name, double z, std::string model = "models/card.json") {
    return "{\"id\":" + std::to_string(id) + ",\"name\":" + quote(name) +
        ",\"image\":" + quote(model) + ",\"origin\":[0,0," + std::to_string(z) +
        "],\"scale\":[1,1,1],\"angles\":[0,0,0],\"visible\":true}";
}
std::string SortingScene(std::string objects) {
    return R"({"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
        "general":{"orthogonalprojection":null,"fov":50,"nearz":0.1,"farz":10000,
        "bloom":false,"cameraparallax":false,"transparentsorting":true,"customsortorder":false},
        "objects":[)" + objects + "]}";
}

TEST(TransparentSorting, BlendedImagesFollowDepthInsteadOfFileOrder) {
    ParseFixture fixture(ordinaryAssets());
    auto scene = fixture.parse(SortingScene(SortCard(1, "near", -10) + "," + SortCard(2, "far", -20)));
    Observation order(*scene);
    EXPECT_LT(order.nodeIndex("far"), order.nodeIndex("near"));
}

TEST(TransparentSorting, UnmarkedImagesGoFirstEvenWithoutDepthTesting) {
    auto files = ordinaryAssets();
    asset(files, "/models/solid.json", R"({"width":64,"height":40,"material":"materials/solid.json"})");
    materialAsset(files, "materials/solid.json", "contract_card", "[\"contract_picture\"]", "normal");
    ParseFixture fixture(std::move(files));
    auto scene = fixture.parse(SortingScene(SortCard(1, "blended", -20) + "," +
                    SortCard(2, "solid", -10, "models/solid.json")));
    Observation order(*scene);
    EXPECT_LT(order.nodeIndex("solid"), order.nodeIndex("blended"));
}

TEST(TransparentSorting, ParentsDoNotReplaceTheLocalOriginUsedAsTheDepthKey) {
    ParseFixture fixture(ordinaryAssets());
    const ProjectProperties properties;
    SceneParseRequest request;
    request.project_properties = &properties;
    auto child = SortCard(2, "child", -10);
    child.insert(child.size() - 1, ",\"parent\":1");
    auto scene = fixture.parse(request, SortingScene(
        R"({"id":1,"name":"parent","origin":[0,0,-100],"visible":true},)" + child +
        "," + SortCard(3, "other", -20)));
    Observation order(*scene);
    EXPECT_LT(order.nodeIndex("other"), order.nodeIndex("child"));
}

TEST(TransparentSorting, EqualDepthKeepsThePreviousOrderAfterObjectsCross) {
    ParseFixture fixture(ordinaryAssets());
    const ProjectProperties properties;
    SceneParseRequest request;
    request.project_properties = &properties;
    auto scene = fixture.parse(request, SortingScene(SortCard(1, "moving", -20) + "," +
                                                      SortCard(2, "fixed", -10)));
    ASSERT_NE(scene->runtime, nullptr);
    {
        Observation order(*scene);
        EXPECT_LT(order.nodeIndex("moving"), order.nodeIndex("fixed"));
    }
    ASSERT_TRUE(scene->runtime->SetNodeTranslate("moving", {0, 0, -1}));
    {
        Observation order(*scene);
        EXPECT_LT(order.nodeIndex("fixed"), order.nodeIndex("moving"));
    }
    ASSERT_TRUE(scene->runtime->SetNodeTranslate("moving", {0, 0, -10}));
    {
        Observation order(*scene);
        EXPECT_LT(order.nodeIndex("fixed"), order.nodeIndex("moving"));
        EXPECT_EQ(scene->runtime->LayerNameAt(0), "moving");
    }
}

TEST(TransparentSorting, FullscreenMarkedImagesComeAfterFiniteDepths) {
    auto files = ordinaryAssets();
    asset(files, "/models/full.json", R"({"width":64,"height":40,"fullscreen":true,"material":"materials/card.json"})");
    ParseFixture fixture(std::move(files));
    auto scene = fixture.parse(SortingScene(SortCard(1, "overlay", -1000, "models/full.json") +
                                             "," + SortCard(2, "ordinary", -10)));
    Observation order(*scene);
    EXPECT_LT(order.nodeIndex("ordinary"), order.nodeIndex("overlay"));
}


TEST(TransparentSorting, InternalParticleDrawsStayWithTheirLogicalLayer) {
    Scene scene;
    defaults(scene);
    scene.transparent_sorting = true;
    auto near = append(scene, "near-particle");
    near->SetTranslate({0, 0, -10});
    near->SetTransparentSort(SceneNode::TransparentSort::Depth);
    auto mirror = node("mirror-material");
    mirror->SetName("");
    mirror->SetTranslate({0, 0, -1000});
    near->AppendChild(mirror);
    auto far = append(scene, "far-card");
    far->SetTranslate({0, 0, -20});
    far->SetTransparentSort(SceneNode::TransparentSort::Depth);
    Observation order(scene);
    EXPECT_LT(order.drawIndex("far-card"), order.drawIndex("near-particle"));
    EXPECT_LT(order.drawIndex("near-particle"), order.drawIndex("mirror-material"));
}

TEST(TransparentSorting, DisablingTheModeRestoresAuthoredOrder) {
    ParseFixture fixture(ordinaryAssets());
    const ProjectProperties properties;
    SceneParseRequest request;
    request.project_properties = &properties;
    auto scene = fixture.parse(request, SortingScene(SortCard(1, "near", -10) + "," +
                                                      SortCard(2, "far", -20)));
    {
        Observation order(*scene);
        EXPECT_LT(order.nodeIndex("far"), order.nodeIndex("near"));
    }
    const float off = 0;
    ASSERT_TRUE(scene->runtime->SetSceneGeneralValue("transparentsorting", std::span(&off, 1)));
    {
        Observation order(*scene);
        EXPECT_LT(order.nodeIndex("near"), order.nodeIndex("far"));
    }
}


TEST(TransparentSorting, CompositionChildrenKeepTheirPrivateDrawOrder) {
    Scene scene;
    defaults(scene);
    scene.transparent_sorting = true;
    auto owner = append(scene, "composition");
    owner->SetTransparentSort(SceneNode::TransparentSort::Depth);
    auto effects = effectLayer(scene, owner, true);
    effects->AddEffect(oneEffect(node("composition-close")));
    auto near = node("near-child");
    near->SetTranslate({0, 0, -10});
    near->SetTransparentSort(SceneNode::TransparentSort::Depth);
    auto far = node("far-child");
    far->SetTranslate({0, 0, -20});
    far->SetTransparentSort(SceneNode::TransparentSort::Depth);
    owner->AppendChild(near);
    owner->AppendChild(far);
    Observation order(scene);
    EXPECT_LT(order.drawIndex("near-child"), order.drawIndex("far-child"));
    EXPECT_LT(order.drawIndex("far-child"), order.drawIndex("composition-close"));
    EXPECT_EQ(order.draw("near-child").output, effects->FirstTarget());
}


TEST(TransparentSorting, BothFlagsStillUseDepthSortingInAPerspectiveScene) {
    ParseFixture fixture(ordinaryAssets());
    const ProjectProperties properties;
    SceneParseRequest request;
    request.project_properties = &properties;
    auto scene = fixture.parse(request, SortingScene(SortCard(1, "near", -10) + "," +
                                                      SortCard(2, "far", -20)));
    scene->runtime->ConsumeSceneGraphMutationFlag();
    const float on = 1;
    ASSERT_TRUE(scene->runtime->SetSceneGeneralValue("customsortorder", std::span(&on, 1)));
    EXPECT_FALSE(scene->runtime->CustomSortOrder());
    EXPECT_TRUE(scene->transparent_sorting);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
    Observation order(*scene);
    EXPECT_LT(order.nodeIndex("far"), order.nodeIndex("near"));
}


TEST(TransparentSorting, AFloatOriginChangeStillOrdersLayersWhenTheirMatricesStayWithinTolerance) {
    ParseFixture fixture(ordinaryAssets());
    const ProjectProperties properties;
    SceneParseRequest request;
    request.project_properties = &properties;
    auto scene = fixture.parse(request, SortingScene(SortCard(1, "moving", -10) + "," +
                                                      SortCard(2, "fixed", -10)));
    {
        Observation order(*scene);
        EXPECT_LT(order.nodeIndex("moving"), order.nodeIndex("fixed"));
    }
    ASSERT_TRUE(scene->runtime->SetNodeTranslate("moving", {0,0,std::nextafter(-10.0f,0.0f)}));
    Observation order(*scene);
    EXPECT_LT(order.nodeIndex("fixed"), order.nodeIndex("moving"));
}

TEST(TransparentSorting, ALinkToALaterLayerDoesNotPullItsProductionAheadOfTheReader) {
    Scene scene;
    defaults(scene);
    scene.transparent_sorting = true;
    auto source = append(scene, "source");
    source->ID() = 1;
    source->SetTranslate({0, 0, -10});
    source->SetTransparentSort(SceneNode::TransparentSort::Depth);
    scene.layer_texture_sources.insert(1);
    auto reader = append(scene, "reader", {GenLinkTex(1)});
    reader->ID() = 2;
    reader->SetTranslate({0, 0, -20});
    reader->SetTransparentSort(SceneNode::TransparentSort::Depth);
    Observation order(scene);
    EXPECT_LT(order.drawIndex("reader"), order.drawIndex("source"));
    const auto carried = order.graph->getCarriedOverKeys(order.order);
    EXPECT_FALSE(carried.empty());
}


TEST(TransparentSorting, OrderedLinksUseTheRetainedCompositeAndClearItAtTheProducer) {
    for (bool source_first : {false, true}) {
        SCOPED_TRACE(source_first);
        Scene scene;
        defaults(scene);
        scene.transparent_sorting = true;
        auto source = append(scene, "source");
        source->ID() = 1;
        source->SetTranslate({0, 0, source_first ? -30.0f : -10.0f});
        source->SetTransparentSort(SceneNode::TransparentSort::Depth);
        scene.layer_texture_sources.insert(1);
        auto reader = append(scene, "reader", {GenLinkTex(1)});
        reader->ID() = 2;
        reader->SetTranslate({0, 0, -20});
        reader->SetTransparentSort(SceneNode::TransparentSort::Depth);
        Observation graph(scene);
        const auto composite = LayerCompositeTargetKey(1);
        ASSERT_EQ(graph.draw("reader").textures.size(), 1u);
        EXPECT_EQ(graph.draw("reader").textures[0], composite);
        EXPECT_EQ(graph.draw("reader").sort_owner, reader.get());
        EXPECT_EQ(graph.draw("source").sort_owner, source.get());
        const auto* target = scene.FindRenderTarget(composite);
        ASSERT_NE(target, nullptr);
        EXPECT_TRUE(target->allowReuse);
        EXPECT_EQ(target->carriesPreviousFrame, !source_first);
        EXPECT_TRUE(graph.draw("source").clear_on_first_use);
        for (const auto& step : graph.steps) EXPECT_EQ(step.copy, nullptr);
    }
}

TEST(TransparentSorting, ACompleteEffectGroupRunsBeforeTheNextObjectStarts) {
    Scene scene;
    defaults(scene);
    scene.transparent_sorting = true;
    auto source = append(scene, "source");
    source->ID() = 1;
    source->SetTranslate({0, 0, -30});
    source->SetTransparentSort(SceneNode::TransparentSort::Depth);
    const auto chain = effectLayer(scene, source);
    chain->AddEffect(oneEffect(node("effect-final")));
    auto later = append(scene, "later");
    later->SetTranslate({0, 0, -10});
    later->SetTransparentSort(SceneNode::TransparentSort::Depth);
    Observation graph(scene);
    EXPECT_LT(graph.drawIndex("source"), graph.drawIndex("effect-final"));
    EXPECT_LT(graph.drawIndex("effect-final"), graph.drawIndex("later"));
    EXPECT_EQ(graph.draw("source").sort_owner, source.get());
    EXPECT_EQ(graph.draw("effect-final").sort_owner, source.get());
    EXPECT_EQ(graph.draw("later").sort_owner, later.get());
}

TEST(TransparentSorting, ASelfLinkKeepsItsSnapshotAfterTheAtomicSourceGroup) {
    Scene scene;
    defaults(scene);
    scene.transparent_sorting = true;
    auto source = append(scene, "self", {GenLinkTex(1)});
    source->ID() = 1;
    source->SetTranslate({0, 0, -30});
    source->SetTransparentSort(SceneNode::TransparentSort::Depth);
    scene.layer_texture_sources.insert(1);
    auto later = append(scene, "later");
    later->SetTranslate({0, 0, -10});
    later->SetTransparentSort(SceneNode::TransparentSort::Depth);
    Observation graph(scene);
    EXPECT_EQ(graph.draw("self").textures[0], GenLinkTex(1));
    std::size_t snapshot = graph.steps.size();
    for (std::size_t i = 0; i < graph.steps.size(); ++i) {
        if (const auto* copy = graph.steps[i].copy; copy && copy->desc().dst == GenLinkTex(1)) {
            snapshot = i;
            EXPECT_EQ(copy->desc().sort_owner, source.get());
        }
    }
    ASSERT_LT(snapshot, graph.steps.size());
    EXPECT_LT(graph.drawIndex("self"), snapshot);
    EXPECT_LT(snapshot, graph.drawIndex("later"));
}


TEST(TransparentSorting, CompositionChildrenKeepForwardLinksAtTheirPrivatePositions) {
    Scene scene;
    defaults(scene);
    scene.transparent_sorting = true;
    auto composition = append(scene, "composition");
    composition->SetTransparentSort(SceneNode::TransparentSort::Depth);
    auto effects = effectLayer(scene, composition, true);
    effects->AddEffect(oneEffect(node("close")));
    auto reader = node("child-reader", {GenLinkTex(2)});
    reader->ID() = 1;
    auto source = node("child-source");
    source->ID() = 2;
    scene.layer_texture_sources.insert(2);
    composition->AppendChild(reader);
    composition->AppendChild(source);
    Observation graph(scene);
    EXPECT_LT(graph.drawIndex("child-reader"), graph.drawIndex("child-source"));
    EXPECT_LT(graph.drawIndex("child-source"), graph.drawIndex("close"));
    EXPECT_EQ(graph.draw("child-reader").sort_owner, composition.get());
    EXPECT_EQ(graph.draw("child-source").sort_owner, composition.get());
    EXPECT_EQ(graph.draw("child-reader").textures[0], LayerCompositeTargetKey(2));
    ASSERT_NE(scene.FindRenderTarget(LayerCompositeTargetKey(2)), nullptr);
    EXPECT_TRUE(scene.FindRenderTarget(LayerCompositeTargetKey(2))->carriesPreviousFrame);
}


TEST(TransparentSorting, AuthoredCompositeReadersKeepTheirPositionWhenDepthSortingIsOff) {
    for (bool source_first : {false, true}) {
        SCOPED_TRACE(source_first);
        Scene scene;
        defaults(scene);
        scene.transparent_sorting = false;
        auto source=node("source");source->ID()=1;
        auto reader=node("reader",{GenLinkTex(1)});reader->ID()=2;
        if (source_first) {
            scene.sceneGraph->AppendChild(source);
            scene.sceneGraph->AppendChild(reader);
        } else {
            scene.sceneGraph->AppendChild(reader);
            scene.sceneGraph->AppendChild(source);
        }
        scene.layer_texture_sources.insert(1);
        Observation graph(scene);
        EXPECT_EQ(graph.drawIndex("source") < graph.drawIndex("reader"), source_first);
        EXPECT_EQ(graph.draw("reader").textures[0], LayerCompositeTargetKey(1));
        const auto* retained=scene.FindRenderTarget(LayerCompositeTargetKey(1));
        ASSERT_NE(retained,nullptr);
        EXPECT_EQ(retained->carriesPreviousFrame,!source_first);
    }
}

}
}
