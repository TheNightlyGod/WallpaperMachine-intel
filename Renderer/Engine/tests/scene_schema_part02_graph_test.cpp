// Scene file schema, part 2: the scene graph a document becomes. Which statically hidden layers
// survive because another layer depends on them, where a child of a group-like parent hangs, the
// order of layers declared before their parent, and how a camera node follows its parents.
#include "support/schema_fixtures_part02.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::p2;
using namespace wallpaper;

constexpr double kPi = 3.14159265358979323846;

Json ImageLayer(int id, const std::string& name, const Json& extra = Json::object())
{
    Json layer = { { "id", id },
                   { "name", name },
                   { "image", "image.json" },
                   { "origin", Json::array({ 0, 0, 0 }) },
                   { "scale", Json::array({ 1, 1, 1 }) },
                   { "angles", Json::array({ 0, 0, 0 }) },
                   { "visible", true } };
    for (const auto& [key, value] : extra.items()) layer[key] = value;
    return layer;
}

// ---- hidden layers other layers depend on ----------------------------------------------------

// R-2.13 / B-2.13 row 1
TEST(HiddenLayerRetention, AHiddenImageIsKeptWhenAVisibleLayerDependsOnIt)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ ImageLayer(159, "source", { { "visible", false } }),
                                                        ImageLayer(160, "consumer", { { "dependencies", Json::array({ 159 }) } }) })));
    ASSERT_NE(scene, nullptr);
    SceneNode* source = FindRootChild(*scene, "source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_EQ(source->ID(), 159);
    EXPECT_NE(source->Mesh(), nullptr);
    SceneNode* consumer = FindRootChild(*scene, "consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

// R-2.14 / B-2.13 row 2
TEST(HiddenLayerRetention, TheDependencyChainIsFollowedThroughHiddenImages)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ ImageLayer(159, "source", { { "visible", false } }),
                                                        ImageLayer(200, "middle", { { "visible", false }, { "dependencies", Json::array({ 159 }) } }),
                                                        ImageLayer(201, "consumer", { { "dependencies", Json::array({ 200 }) } }) })));
    ASSERT_NE(scene, nullptr);
    SceneNode* source = FindRootChild(*scene, "source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_EQ(source->ID(), 159);
    EXPECT_NE(source->Mesh(), nullptr);
    SceneNode* middle = FindRootChild(*scene, "middle");
    ASSERT_NE(middle, nullptr);
    EXPECT_FALSE(middle->Visible());
    SceneNode* consumer = FindRootChild(*scene, "consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

// R-2.15 / B-2.13 row 3
TEST(HiddenLayerRetention, ALayerWhoseVisibilityIsDynamicCountsAsARoot)
{
    ParseRig rig(BasicAssets());
    const Json scripted = { { "value", false }, { "script", "export function update(value) { return value; }" } };
    auto       scene    = rig.Parse(QuietScene(Json::array({ ImageLayer(180, "source", { { "visible", false } }),
                                                          ImageLayer(181, "middle", { { "visible", false }, { "dependencies", Json::array({ 180 }) } }),
                                                          ImageLayer(182, "consumer", { { "visible", scripted }, { "dependencies", Json::array({ 181 }) } }) })));
    ASSERT_NE(scene, nullptr);
    SceneNode* source = FindRootChild(*scene, "source");
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    SceneNode* middle = FindRootChild(*scene, "middle");
    ASSERT_NE(middle, nullptr);
    EXPECT_FALSE(middle->Visible());
    EXPECT_NE(FindRootChild(*scene, "consumer"), nullptr);
}

// R-2.16 / B-2.13 row 4
TEST(HiddenLayerRetention, AHiddenParticleIsDroppedEvenWhenAnImageDependsOnIt)
{
    ParseRig rig(BasicAssets());
    Json     particle = { { "id", 170 },
                          { "name", "sparks" },
                          { "particle", "particle.json" },
                          { "origin", Json::array({ 0, 0, 0 }) },
                          { "scale", Json::array({ 1, 1, 1 }) },
                          { "angles", Json::array({ 0, 0, 0 }) },
                          { "visible", false } };
    auto     scene = rig.Parse(QuietScene(Json::array({ particle, ImageLayer(171, "consumer", { { "dependencies", Json::array({ 170 }) } }) })));
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(FindRootChild(*scene, "sparks"), nullptr);
    SceneNode* consumer = FindRootChild(*scene, "consumer");
    ASSERT_NE(consumer, nullptr);
    EXPECT_TRUE(consumer->Visible());
}

TEST(HiddenLayerRetention, AHiddenImageNobodyDependsOnIsDropped)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ ImageLayer(159, "loner", { { "visible", false } }), ImageLayer(160, "bystander") })));
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(FindRootChild(*scene, "loner"), nullptr);
    EXPECT_NE(FindRootChild(*scene, "bystander"), nullptr);
}

// ---- children of group-like parents ------------------------------------------------------------

// R-2.17 / B-2.14
TEST(LayerParents, AGroupLikeTextParentKeepsItsImageChildsOffset)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ Json { { "id", 200 }, { "name", "caption" }, { "text", "hello" }, { "origin", Json::array({ 25, 0, 0 }) }, { "visible", true } },
                                                        ImageLayer(201, "badge", { { "parent", 200 }, { "origin", Json::array({ 5, 0, 0 }) } }) })));
    ASSERT_NE(scene, nullptr);
    SceneNode* parent = FindRootChild(*scene, "caption");
    ASSERT_NE(parent, nullptr);
    ASSERT_EQ(parent->GetChildren().size(), 1u);
    SceneNode* child = parent->GetChildren().front().get();
    ASSERT_NE(child, nullptr);
    EXPECT_EQ(child->Name(), "badge");
    EXPECT_EQ(child->Parent(), parent);
    child->UpdateTrans();
    EXPECT_NEAR(child->ModelTrans()(0, 3), 30.0, 1e-5);
}

// R-2.21 / B-2.18
TEST(LayerOrder, DeclarationOrderSurvivesAChildThatIsAttachedLate)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ Json { { "id", 200 }, { "name", "container" }, { "origin", Json::array({ 10, 0, 0 }) }, { "visible", true } },
                                                        ImageLayer(201, "image", { { "origin", Json::array({ 20, 0, 0 }) } }),
                                                        ImageLayer(202, "late child", { { "parent", 200 }, { "origin", Json::array({ 5, 0, 0 }) } }) })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->sceneGraph, nullptr);
    std::vector<std::string> named;
    for (const auto& child : scene->sceneGraph->GetChildren()) {
        if (child != nullptr && !child->Name().empty()) named.push_back(child->Name());
    }
    ASSERT_GE(named.size(), 2u);
    EXPECT_EQ(named[0], "container");
    EXPECT_EQ(named[1], "image");
    for (const auto& name : named) EXPECT_NE(name, "late child") << "a child of a container must not also hang from the root";

    SceneNode* container = FindRootChild(*scene, "container");
    ASSERT_NE(container, nullptr);
    ASSERT_EQ(container->GetChildren().size(), 1u);
    SceneNode* late = container->GetChildren().front().get();
    ASSERT_NE(late, nullptr);
    EXPECT_EQ(late->Name(), "late child");
    EXPECT_EQ(late->Parent(), container);
    late->UpdateTrans();
    EXPECT_NEAR(late->ModelTrans()(0, 3), 15.0, 1e-5);
}

// ---- camera nodes ----------------------------------------------------------------------------

std::shared_ptr<SceneNode> MakeNode(float x, float y, float z)
{
    auto node = std::make_shared<SceneNode>();
    node->SetTranslate({ x, y, z });
    return node;
}

// R-2.18 / B-2.15
TEST(CameraNodes, ACameraFollowsItsParentsModelTransform)
{
    auto parent = MakeNode(10, 20, 30);
    parent->SetRotation({ 0, 0, static_cast<float>(kPi / 2) });
    auto child = MakeNode(2, 3, 4);
    parent->AppendChild(child);

    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(child);
    camera.Update();

    const auto position = camera.GetPosition();
    EXPECT_NEAR(position.x(), 7.0, 1e-5);
    EXPECT_NEAR(position.y(), 22.0, 1e-5);
    EXPECT_NEAR(position.z(), 34.0, 1e-5);
    const auto direction = camera.GetDirection();
    EXPECT_NEAR(direction.x(), 0.0, 1e-5);
    EXPECT_NEAR(direction.y(), 0.0, 1e-5);
    EXPECT_NEAR(direction.z(), -1.0, 1e-5);
    child->UpdateTrans();
    EXPECT_TRUE(camera.GetViewMatrix().isApprox(child->ModelTrans().inverse(), 1e-5));
}

// R-2.19 / B-2.16
TEST(CameraNodes, TheViewTracksLaterChangesOfTheParent)
{
    auto parent = std::make_shared<SceneNode>();
    auto child  = std::make_shared<SceneNode>();
    parent->AppendChild(child);
    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(child);
    EXPECT_NEAR(camera.GetViewMatrix()(0, 3), 0.0, 1e-5);
    parent->SetTranslate({ 12, 0, 0 });
    EXPECT_NEAR(camera.GetViewMatrix()(0, 3), -12.0, 1e-5);
}

// R-2.20 / B-2.17
TEST(CameraNodes, TheViewIsTheInverseOfTheScaledModelTransform)
{
    auto node = MakeNode(4, 6, 8);
    node->SetScale({ 2, 3, 4 });
    SceneCamera camera(640, 360, 0.01f, 100.0f);
    camera.AttatchNode(node);
    node->UpdateTrans();
    const auto view = camera.GetViewMatrix();
    EXPECT_TRUE(view.isApprox(node->ModelTrans().inverse(), 1e-5));
    EXPECT_NEAR(view(0, 0), 0.5, 1e-5);
    EXPECT_NEAR(view(1, 1), 1.0 / 3.0, 1e-5);
    EXPECT_NEAR(view(2, 2), 0.25, 1e-5);
    EXPECT_NEAR(view(3, 3), 1.0, 1e-5);
    EXPECT_NEAR(view(0, 3), -2.0, 1e-5);
    EXPECT_NEAR(view(1, 3), -2.0, 1e-5);
    EXPECT_NEAR(view(2, 3), -2.0, 1e-5);
}

} // namespace
