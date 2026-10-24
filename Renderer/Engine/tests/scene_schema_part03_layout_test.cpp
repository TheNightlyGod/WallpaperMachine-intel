// Scene file schema, part 3: where layers end up. The order layers are hung under their parents
// in, the card that closes an effect chain, the draw offset of a node and the placement a script
// reads back from a layer.
#include "support/schema_fixtures_part03.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::p3;
using namespace wallpaper;

std::vector<std::string> NamedRootChildren(Scene& scene)
{
    std::vector<std::string> names;
    for (const auto& child : scene.sceneGraph->GetChildren()) {
        if (child != nullptr && !child->Name().empty()) names.push_back(child->Name());
    }
    return names;
}

Json Group(int id, const std::string& name, const Json& extra = Json::object())
{
    Json group = { { "id", id }, { "name", name }, { "origin", Json::array({ 0, 0, 0 }) }, { "visible", true } };
    for (const auto& [key, value] : extra.items()) group[key] = value;
    return group;
}

bool ContainsName(const std::vector<std::string>& names, const std::string& wanted)
{
    for (const auto& name : names) {
        if (name == wanted) return true;
    }
    return false;
}

// ---- attachment order ------------------------------------------------------------------------

// R-3.01 / B-3.01
TEST(LayerAttachment, AParentDeclaredAfterItsChildStillEndsUpAboveIt)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(CanvasOf(Json::array({ ImageObject(302, "early child", { { "parent", 300 }, { "origin", Json::array({ 5, 0, 0 }) } }),
                                                      ImageObject(301, "middle root", { { "origin", Json::array({ 20, 0, 0 }) } }),
                                                      Group(300, "late parent", { { "origin", Json::array({ 10, 0, 0 }) } }) })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->sceneGraph, nullptr);
    const auto names = NamedRootChildren(*scene);
    ASSERT_GE(names.size(), 2u);
    EXPECT_EQ(names[0], "middle root");
    EXPECT_EQ(names[1], "late parent");

    SceneNode* parent = FindRootChild(*scene, "late parent");
    ASSERT_NE(parent, nullptr);
    ASSERT_EQ(parent->GetChildren().size(), 1u);
    SceneNode* child = parent->GetChildren().front().get();
    ASSERT_NE(child, nullptr);
    EXPECT_EQ(child->Name(), "early child");
    EXPECT_EQ(child->Parent(), parent);
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 15.0, 1e-5);
}

// A parent that is missing, the layer itself, ambiguous or part of a cycle makes the layer a root.
class UnattachableParent : public ::testing::TestWithParam<int> {};

TEST_P(UnattachableParent, TheLayerBecomesARoot)
{
    std::vector<Json> objects;
    switch (GetParam()) {
    case 0: // names an id no layer has
        objects = { ImageObject(10, "orphan", { { "parent", 999 } }) };
        break;
    case 1: // its own id
        objects = { ImageObject(10, "orphan", { { "parent", 10 } }) };
        break;
    case 2: // an id two layers share
        objects = { ImageObject(20, "twin one"), ImageObject(20, "twin two"), ImageObject(10, "orphan", { { "parent", 20 } }) };
        break;
    default: // a cycle
        objects = { ImageObject(10, "orphan", { { "parent", 11 } }), ImageObject(11, "partner", { { "parent", 10 } }) };
        break;
    }
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(CanvasOf(Json(objects)));
    ASSERT_NE(scene, nullptr);
    EXPECT_TRUE(ContainsName(NamedRootChildren(*scene), "orphan"));
    if (GetParam() == 3) EXPECT_TRUE(ContainsName(NamedRootChildren(*scene), "partner"));
}

std::string UnattachableName(const ::testing::TestParamInfo<int>& info)
{
    static const char* const names[] = { "Missing", "Itself", "SharedId", "Cycle" };
    return std::string(names[info.param]);
}

INSTANTIATE_TEST_SUITE_P(Parents, UnattachableParent, ::testing::Values(0, 1, 2, 3), UnattachableName);

// ---- the card closing an effect chain ----------------------------------------------------------

FileMap EffectAssets()
{
    FileMap files = BasicAssets();
    Add(files, CopyEffectAssets());
    return files;
}

// Parses a parent group (with `group_extra`) holding an effect-drawn child at x = 6 and returns
// the x translation of the chain's final card.
double FinalCardX(const Json& group_extra, bool nested)
{
    ParseRig rig(EffectAssets());
    Json     child = ImageObject(301, "nested effect", { { "origin", Json::array({ 6, 0, 0 }) }, { "effects", CopyEffectEntry(302) } });
    Json     objects = Json::array();
    if (nested) {
        child["parent"] = 300;
        objects.push_back(Group(300, "effect parent", group_extra));
    }
    objects.push_back(child);
    auto scene = rig.Parse(CanvasOf(objects));
    EXPECT_NE(scene, nullptr);
    if (scene == nullptr) return -1;
    SceneNode* layer = nullptr;
    if (nested) {
        SceneNode* parent = FindRootChild(*scene, "effect parent");
        EXPECT_NE(parent, nullptr);
        if (parent == nullptr || parent->GetChildren().empty()) return -1;
        layer = parent->GetChildren().front().get();
    } else {
        layer = FindRootChild(*scene, "nested effect");
    }
    EXPECT_NE(layer, nullptr);
    if (layer == nullptr) return -1;
    EXPECT_EQ(layer->Name(), "nested effect");
    EXPECT_FALSE(layer->Camera().empty());
    const auto camera = scene->cameras.find(layer->Camera());
    EXPECT_NE(camera, scene->cameras.end());
    if (camera == scene->cameras.end()) return -1;
    EXPECT_TRUE(camera->second->HasImgEffect());
    if (!camera->second->HasImgEffect()) return -1;
    SceneNode& card = camera->second->GetImgEffect()->FinalNode();
    card.UpdateTrans();
    return card.RenderTrans()(0, 3);
}

// R-3.02 / B-3.02
TEST(EffectCards, TheFinalCardStandsWhereTheWorldTransformPutsItParentsIncluded)
{
    EXPECT_NEAR(FinalCardX({ { "origin", Json::array({ 40, 0, 0 }) } }, true), 46.0, 1e-5);
}

TEST(EffectCards, AParentsScaleReachesTheFinalCard)
{
    EXPECT_NEAR(FinalCardX({ { "origin", Json::array({ 40, 0, 0 }) }, { "scale", Json::array({ 2, 2, 1 }) } }, true), 52.0, 1e-5);
}

TEST(EffectCards, ARootLayersFinalCardStandsAtItsOwnOrigin)
{
    EXPECT_NEAR(FinalCardX(Json::object(), false), 6.0, 1e-5);
}

// ---- draw offset -----------------------------------------------------------------------------

struct OffsetRig {
    std::shared_ptr<SceneNode> parent = std::make_shared<SceneNode>(linalg::Vector3f(10, 20, 0), linalg::Vector3f(2, 3, 1), linalg::Vector3f(0, 0, 0.5f), "parent");
    std::shared_ptr<SceneNode> child  = std::make_shared<SceneNode>(linalg::Vector3f(5, 7, 0), linalg::Vector3f(1, 1, 1), linalg::Vector3f(0, 0, 0), "child");
    linalg::Matrix4d           parent_model;
    linalg::Matrix4d           child_model;

    OffsetRig()
    {
        parent->AppendChild(child);
        Update();
        parent_model = parent->ModelTrans();
        child_model  = child->ModelTrans();
    }
    void Update()
    {
        parent->UpdateTrans();
        child->UpdateTrans();
    }
};

// R-3.03 / B-3.03
TEST(DrawOffset, AnOffsetLeavesBothModelMatricesAlone)
{
    OffsetRig rig;
    EXPECT_TRUE(rig.parent->RenderTrans().isApprox(rig.parent_model, 0.0));
    EXPECT_TRUE(rig.parent->DrawOffset().isZero());
    rig.parent->SetDrawOffset({ -70, 4, 0 });
    rig.Update();
    EXPECT_TRUE(rig.parent->ModelTrans().isApprox(rig.parent_model, 0.0));
    EXPECT_TRUE(rig.child->ModelTrans().isApprox(rig.child_model, 0.0));
}

// B-3.04
TEST(DrawOffset, TheOffsetIsAPlainWorldTranslationOnTheRenderMatrix)
{
    OffsetRig rig;
    rig.parent->SetDrawOffset({ -70, 4, 0 });
    rig.Update();
    linalg::Matrix4d expected = rig.parent_model;
    expected(0, 3) -= 70.0;
    expected(1, 3) += 4.0;
    EXPECT_TRUE(rig.parent->RenderTrans().isApprox(expected, 1e-12));
    // Neither scaled by (2,3) nor turned by 0.5 rad.
    const linalg::Matrix4d drawn = rig.parent->RenderTrans();
    const auto             drawn_block = drawn.block<3, 3>(0, 0);
    const auto             model_block = rig.parent_model.block<3, 3>(0, 0);
    EXPECT_TRUE(drawn_block.isApprox(model_block, 0.0));

    rig.parent->SetDrawOffset({ 0, 0, 9 });
    rig.Update();
    EXPECT_NEAR(rig.parent->RenderTrans()(2, 3), rig.parent_model(2, 3) + 9.0, 1e-12);
}

// R-3.03 / B-3.05
TEST(DrawOffset, AnOverrideBeatsTheOffsetAndClearingOrZeroingRestores)
{
    OffsetRig rig;
    rig.parent->SetDrawOffset({ -70, 4, 0 });
    rig.Update();
    linalg::Matrix4d moved = rig.parent_model;
    moved(0, 3) -= 70.0;
    moved(1, 3) += 4.0;

    rig.parent->SetRenderTransformOverride(linalg::Matrix4d::Identity());
    EXPECT_TRUE(rig.parent->HasRenderTransformOverride());
    EXPECT_TRUE(rig.parent->RenderTrans().isApprox(linalg::Matrix4d::Identity(), 0.0));
    rig.parent->ClearRenderTransformOverride();
    EXPECT_FALSE(rig.parent->HasRenderTransformOverride());
    EXPECT_TRUE(rig.parent->RenderTrans().isApprox(moved, 1e-12));
    rig.parent->SetDrawOffset({ 0, 0, 0 });
    EXPECT_TRUE(rig.parent->RenderTrans().isApprox(rig.parent_model, 0.0));
}

// ---- placement as scripts read it --------------------------------------------------------------

constexpr const char* kReadMatrix = "const m = thisScene.getLayer('%s').getTransformMatrix().m; return new Vec3(m[12], m[13], 0);";

std::string ReadsMatrixOf(const std::string& layer)
{
    std::string body = kReadMatrix;
    body.replace(body.find("%s"), 2, layer);
    return body;
}

void ExpectVec(const linalg::Vector3f& actual, float x, float y, float z, const char* what)
{
    EXPECT_TRUE(actual.isApprox(linalg::Vector3f(x, y, z))) << what << ": got (" << actual.x() << ", " << actual.y() << ", " << actual.z() << ")";
}

// R-3.04 / B-3.06
TEST(ScriptPlacement, ALayersTransformMatrixIsItsWorldMatrixNotTheOneItRendersFrom)
{
    ParseRig rig(EffectAssets());
    auto     scene = rig.Parse(CanvasOf(Json::array({ Group(1, "group", { { "origin", Json::array({ 100, 200, 0 }) }, { "scale", Json::array({ 2, 2, 1 }) } }),
                                                      ImageObject(2, "plain", { { "parent", 1 }, { "origin", Json::array({ 10, 20, 0 }) } }),
                                                      ImageObject(3, "drawn", { { "parent", 1 }, { "origin", Json::array({ 30, 0, 0 }) }, { "effects", CopyEffectEntry(4) } }),
                                                      ReaderObject(10, "reads plain", ReadsMatrixOf("plain")),
                                                      ReaderObject(11, "reads drawn", ReadsMatrixOf("drawn")),
                                                      ReaderObject(12, "reads group", ReadsMatrixOf("group")) })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneNode* group = FindRootChild(*scene, "group");
    ASSERT_NE(group, nullptr);
    ASSERT_GE(group->GetChildren().size(), 2u);
    // Premise: the layer with an effect renders from a matrix of its own, not from its model matrix.
    SceneNode* drawn = FindChild(*group, "drawn");
    ASSERT_NE(drawn, nullptr);
    EXPECT_TRUE(drawn->HasRenderTransformOverride());

    scene->runtime->Tick(0.01);
    ExpectVec(scene->runtime->NodeTranslate("reads plain"), 120, 240, 0, "plain");
    ExpectVec(scene->runtime->NodeTranslate("reads drawn"), 160, 200, 0, "drawn");
    ExpectVec(scene->runtime->NodeTranslate("reads group"), 100, 200, 0, "group");
    EXPECT_TRUE(scene->runtime->scriptErrors().empty());
}

TEST(ScriptPlacement, EveryLevelOfNestingContributesItsScale)
{
    ParseRig rig(EffectAssets());
    auto     scene = rig.Parse(CanvasOf(Json::array({ Group(1, "outer", { { "origin", Json::array({ 100, 200, 0 }) }, { "scale", Json::array({ 2, 2, 1 }) } }),
                                                      Group(2, "inner", { { "parent", 1 }, { "origin", Json::array({ 5, 5, 0 }) }, { "scale", Json::array({ 2, 2, 1 }) } }),
                                                      ImageObject(3, "leaf", { { "parent", 2 }, { "origin", Json::array({ 10, 20, 0 }) } }),
                                                      ReaderObject(10, "reads leaf", ReadsMatrixOf("leaf")) })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    scene->runtime->Tick(0.01);
    // outer: 100 + 2 * (5 + 2 * 10), 200 + 2 * (5 + 2 * 20)
    ExpectVec(scene->runtime->NodeTranslate("reads leaf"), 150, 290, 0, "leaf");
    EXPECT_TRUE(scene->runtime->scriptErrors().empty());
}

// R-3.05 / B-3.07
TEST(ScriptPlacement, AnEdgeAnchoredLayersMatrixIsItsQuadCentreAndItsOriginTheAnchor)
{
    ParseRig rig(EffectAssets());
    const Json anchored = { { "alignment", "left" }, { "origin", Json::array({ 100, 70, 0 }) }, { "scale", Json::array({ 2, 1, 1 }) } };
    auto       scene    = rig.Parse(CanvasOf(Json::array({ ImageObject(1, "anchored", anchored),
                                                      ImageObject(2, "moved", anchored),
                                                      ReaderObject(10, "reads matrix", ReadsMatrixOf("anchored")),
                                                      ReaderObject(11, "reads origin", "const o = thisScene.getLayer('anchored').origin; return new Vec3(o.x, o.y, 0);"),
                                                      ReaderObject(12, "moves anchor",
                                                                   "const layer = thisScene.getLayer('moved'); layer.origin = new Vec3(300, 70, 0); "
                                                                   "const m = layer.getTransformMatrix().m; return new Vec3(m[12], m[13], 0);") })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    // Half the layer's authored width (the image is 64 wide, the layer twice that).
    const float half = scene->runtime->NodeSize("anchored").x() * 2.0f / 2.0f;
    ASSERT_GT(half, 0.0f);
    EXPECT_FLOAT_EQ(half, 64.0f);

    scene->runtime->Tick(0.01);
    ExpectVec(scene->runtime->NodeTranslate("reads origin"), 100, 70, 0, "the anchor");
    ExpectVec(scene->runtime->NodeTranslate("reads matrix"), 100 + half, 70, 0, "the quad centre");
    ExpectVec(scene->runtime->NodeTranslate("moves anchor"), 300 + half, 70, 0, "a moved anchor");
    EXPECT_TRUE(scene->runtime->scriptErrors().empty());
}

struct AnchorRow {
    const char* alignment;
    float       centre_x;
    float       centre_y;
};

class AnchorAlignments : public ::testing::TestWithParam<AnchorRow> {};

TEST_P(AnchorAlignments, TheCentreMovesAwayFromTheAnchorByHalfTheLayer)
{
    const AnchorRow row = GetParam();
    ParseRig        rig(EffectAssets());
    const Json      layer = { { "alignment", row.alignment }, { "origin", Json::array({ 100, 70, 0 }) }, { "scale", Json::array({ 2, 1, 1 }) } };
    auto            scene = rig.Parse(CanvasOf(Json::array({ ImageObject(1, "anchored", layer), ReaderObject(10, "reads matrix", ReadsMatrixOf("anchored")) })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    scene->runtime->Tick(0.01);
    ExpectVec(scene->runtime->NodeTranslate("reads matrix"), row.centre_x, row.centre_y, 0, row.alignment);
}

// The image is 64x32; the layer's scale is (2, 1), so it is 128 wide and 32 tall.
std::string AnchorName(const ::testing::TestParamInfo<AnchorRow>& info)
{
    std::string name = info.param.alignment;
    for (char& c : name) {
        if (c == ' ') c = '_';
    }
    return name;
}

const AnchorRow kAnchorRows[] = { { "left", 164, 70 }, { "right", 36, 70 }, { "bottom", 100, 86 }, { "top", 100, 54 }, { "top left", 164, 54 }, { "center", 100, 70 } };

INSTANTIATE_TEST_SUITE_P(Alignments, AnchorAlignments, ::testing::ValuesIn(kAnchorRows), AnchorName);

} // namespace
