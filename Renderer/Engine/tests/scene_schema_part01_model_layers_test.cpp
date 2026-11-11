// Scene file schema, part 1: what the scene parser builds from text layers and model layers
// (parent wiring, leaf model nodes, cursor targets, material state words, bones).
#include "support/schema_fixtures.hpp"
#include "mdl_fixtures.hpp"

#include "Interface/IShaderValueUpdater.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneShader.h"
#include "Scene/SpecTexs.hpp"
#include "Scene/SceneCamera.h"
#include "WPPuppet.hpp"

#include <gtest/gtest.h>

#include <array>
#include <bit>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

using Vec3 = std::array<float, 3>;

Json ModelObject(int id, const std::string& name, const Json& extra = Json::object())
{
    Json object = { { "id", id }, { "name", name }, { "model", "planet.mdl" }, { "visible", true } };
    for (const auto& [key, value] : extra.items()) object[key] = value;
    return object;
}

// The slot materials of the model layer called `name`.
std::vector<const SceneMaterial*> SlotsOf(Scene& scene, const std::string& name)
{
    std::vector<const SceneMaterial*> slots;
    SceneNode* node = FindRootChild(scene, name);
    if (node == nullptr || node->Mesh() == nullptr) return slots;
    for (const auto& slot : node->Mesh()->MaterialSlots()) slots.push_back(slot.get());
    return slots;
}

// The leaf model assets with the two slot materials replaced by the given state words.
FileMap LeafAssetsWith(const Json& head_state, const Json& eyes_state)
{
    FileMap files = LeafModelAssets();
    files["/mat/head.json"] = LeafMaterialText(head_state);
    files["/mat/eyes.json"] = LeafMaterialText(eyes_state);
    return files;
}

// ---- text layer under a plain group ------------------------------------------------------

// R-1.09 / B-1.09
TEST(ModelLayerParse, ATextLayerUnderAPlainGroupKeepsItsParent)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ { { "id", 100 }, { "name", "group" }, { "visible", true } },
                                                         { { "id", 101 }, { "parent", 100 }, { "text", "hello" }, { "font", "Arial" }, { "visible", true } } })));
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->sceneGraph, nullptr);
    EXPECT_TRUE(scene->HasRenderTarget("_alias_lightCookie"));

    SceneNode* group = FindRootChild(*scene, "group");
    ASSERT_NE(group, nullptr);
    EXPECT_EQ(group->Parent(), scene->sceneGraph.get());
    ASSERT_EQ(group->GetChildren().size(), 1u);
    const auto& text = group->GetChildren().front();
    EXPECT_EQ(text->Name(), "__we_text_101");
    EXPECT_NE(text->Mesh(), nullptr);
    EXPECT_EQ(text->Parent(), group);
    EXPECT_EQ(FindRootChild(*scene, "__we_text_101"), nullptr) << "the text node hangs off the group, not off the root";
}

// ---- leaf model layers -------------------------------------------------------------------

// R-1.10 / B-1.10
TEST(ModelLayerParse, ALeafModelLayerBecomesANodeWithItsTransformMeshAndDepthTarget)
{
    ParseRig rig(LeafModelAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ { { "id", 7 }, { "name", "planet" }, { "model", "planet.mdl" }, { "perspective", true }, { "origin", Json::array({ 3, 4, 5 }) }, { "scale", Json::array({ 1, 1, 1 }) }, { "angles", Json::array({ 0.1, 0.2, 0.3 }) }, { "visible", true } } })));
    ASSERT_NE(scene, nullptr);

    SceneNode* planet = FindRootChild(*scene, "planet");
    ASSERT_NE(planet, nullptr);
    EXPECT_EQ(planet->ID(), 7);
    EXPECT_NEAR(planet->Translate().x(), 3.0f, 1e-5f);
    EXPECT_NEAR(planet->Translate().y(), 4.0f, 1e-5f);
    EXPECT_NEAR(planet->Translate().z(), 5.0f, 1e-5f);
    EXPECT_NEAR(planet->Rotation().x(), 0.1f, 1e-5f);
    EXPECT_NEAR(planet->Rotation().y(), 0.2f, 1e-5f);
    EXPECT_NEAR(planet->Rotation().z(), 0.3f, 1e-5f);
    EXPECT_EQ(planet->Camera(), "global_perspective") << "the model asked for the perspective view on a canvas scene";

    ASSERT_NE(planet->Mesh(), nullptr);
    EXPECT_FALSE(planet->Mesh()->Submeshes().empty());
    EXPECT_FALSE(planet->Mesh()->MaterialSlots().empty());
    const SceneMaterial* material = planet->Mesh()->Material();
    ASSERT_NE(material, nullptr);
    EXPECT_TRUE(material->depth_test);
    EXPECT_TRUE(material->depth_write);
    EXPECT_EQ(material->cull_mode, CullMode::Back);

    const SceneRenderTarget* target = scene->FindRenderTarget(SpecTex_Default);
    ASSERT_NE(target, nullptr);
    EXPECT_TRUE(target->withDepth) << "a scene with a model gets a depth buffer";
}

// B-1.10: without `perspective` the layer stays on the scene's flat camera; both slots exist.
TEST(ModelLayerParse, AModelLayerWithoutPerspectiveStaysOnTheFlatCameraAndHasBothSlots)
{
    ParseRig rig(LeafModelAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ ModelObject(7, "planet") })));
    ASSERT_NE(scene, nullptr);
    SceneNode* planet = FindRootChild(*scene, "planet");
    ASSERT_NE(planet, nullptr);
    EXPECT_NE(planet->Camera(), "global_perspective");
    ASSERT_NE(planet->Mesh(), nullptr);
    EXPECT_EQ(planet->Mesh()->MaterialSlots().size(), 2u) << "head and eyes";
}

// ---- cursor targets ----------------------------------------------------------------------

// R-1.11 / B-1.11
TEST(ModelLayerParse, ModelLayersAreCursorTargetsUnlessTheySayOtherwise)
{
    ParseRig rig(LeafModelAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ ModelObject(1, "plain"),
                                                         ModelObject(2, "ghost", { { "solid", false } }),
                                                         ModelObject(3, "blocker", { { "disablepropagation", true } }) })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    const auto plain = scene->runtime->NodeCursorTargetOf("plain");
    ASSERT_TRUE(plain.has_value());
    EXPECT_TRUE(plain->hittable);
    EXPECT_TRUE(plain->solid);
    EXPECT_FALSE(plain->blocks);

    const auto ghost = scene->runtime->NodeCursorTargetOf("ghost");
    ASSERT_TRUE(ghost.has_value());
    EXPECT_TRUE(ghost->hittable);
    EXPECT_FALSE(ghost->solid);
    EXPECT_FALSE(ghost->blocks);

    const auto blocker = scene->runtime->NodeCursorTargetOf("blocker");
    ASSERT_TRUE(blocker.has_value());
    EXPECT_TRUE(blocker->hittable);
    EXPECT_TRUE(blocker->solid);
    EXPECT_TRUE(blocker->blocks);

    EXPECT_FALSE(scene->runtime->NodeCursorTargetOf("nobody").has_value());
}

// B-D9 (we_ss_reg_ModelLayer 0x140227470): `rootmotion` and `castshadow` are stored per model
// layer and scripts read and write them through SetModelFlag / ModelFlag. `rootmotion` defaults
// off; a model casts a shadow unless it says `castshadow: false` (C-6.md probe P-S, ps1 vs ps2).
TEST(ModelLayerParse, RootMotionAndCastShadowAreRead)
{
    ParseRig rig(LeafModelAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ ModelObject(1, "plain"),
                                                         ModelObject(2, "flagged", { { "rootmotion", true }, { "castshadow", false } }) })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;
    EXPECT_EQ(runtime.ModelFlag("plain", "rootmotion"), std::optional<bool>(false));
    EXPECT_EQ(runtime.ModelFlag("plain", "castshadow"), std::optional<bool>(true));
    EXPECT_EQ(runtime.ModelFlag("flagged", "rootmotion"), std::optional<bool>(true));
    EXPECT_EQ(runtime.ModelFlag("flagged", "castshadow"), std::optional<bool>(false));
    EXPECT_FALSE(runtime.ModelFlag("flagged", "perspective").has_value());
    EXPECT_FALSE(runtime.ModelFlag("nobody", "rootmotion").has_value());

    EXPECT_TRUE(runtime.SetModelFlag("plain", "castshadow", false));
    EXPECT_EQ(runtime.ModelFlag("plain", "castshadow"), std::optional<bool>(false));
    EXPECT_TRUE(runtime.SetModelFlag("flagged", "rootmotion", false));
    EXPECT_EQ(runtime.ModelFlag("flagged", "rootmotion"), std::optional<bool>(false));
    EXPECT_FALSE(runtime.SetModelFlag("nobody", "rootmotion", true));
    EXPECT_FALSE(runtime.SetModelFlag("plain", "solid", false));
}

// ---- perspective scene -------------------------------------------------------------------

// R-1.12 / B-1.12
TEST(ModelLayerParse, ANullOrthogonalProjectionMakesAPerspectiveScene)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(PerspectiveScene());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);

    const auto found = scene->cameras.find("global_perspective");
    ASSERT_NE(found, scene->cameras.end());
    EXPECT_EQ(scene->activeCamera, found->second.get());
    EXPECT_TRUE(scene->activeCamera->IsPerspective());
    EXPECT_EQ(scene->activeCamera->Fov(), 60.0);
    EXPECT_TRUE(scene->activeCamera->FovLocked());

    const auto position = scene->activeCamera->GetPosition();
    EXPECT_NEAR(position.x(), 0.0, 1e-4);
    EXPECT_NEAR(position.y(), 10.0, 1e-4);
    EXPECT_NEAR(position.z(), 20.0, 1e-4);

    const linalg::Vector3d expected = linalg::Vector3d(0.0, -10.0, -20.0).normalized();
    EXPECT_GT(scene->activeCamera->GetDirection().normalized().dot(expected), 0.99);

    const SceneRenderTarget* target = scene->FindRenderTarget(SpecTex_Default);
    ASSERT_NE(target, nullptr);
    EXPECT_TRUE(target->withDepth);
}

// ---- model material state ----------------------------------------------------------------

// R-1.13 / B-1.13
TEST(ModelLayerParse, ModelMaterialsDefaultToOpaqueAndDepthTestedAndExplicitStateWins)
{
    ParseRig rig(LeafAssetsWith(Json::object(),
                                { { "blending", "translucent" }, { "cullmode", "nocull" }, { "depthtest", "disabled" }, { "depthwrite", "disabled" } }));
    auto     scene = rig.Parse(PerspectiveScene(Json::array({ { { "id", 1 }, { "name", "model" }, { "model", "planet.mdl" } } })));
    ASSERT_NE(scene, nullptr);
    const auto slots = SlotsOf(*scene, "model");
    ASSERT_EQ(slots.size(), 2u);

    EXPECT_TRUE(slots[0]->depth_test);
    EXPECT_TRUE(slots[0]->depth_write);
    EXPECT_EQ(slots[0]->cull_mode, CullMode::Back);
    EXPECT_EQ(slots[0]->blenmode, BlendMode::Normal);

    EXPECT_FALSE(slots[1]->depth_test);
    EXPECT_FALSE(slots[1]->depth_write);
    EXPECT_EQ(slots[1]->cull_mode, CullMode::None);
    EXPECT_EQ(slots[1]->blenmode, BlendMode::Translucent);
}

// R-1.14 / B-1.14. Wallpaper Engine matches each word case-sensitively against its table and
// takes the table's first entry for anything else (`sub_1401587D0`, tables in `sub_1401577E0`):
// "bogus" and "Additive" both blend as normal.
TEST(ModelLayerParse, PassStateWordsOutsideTheListsReadAsTheFirstEntry)
{
    ParseRig rig(LeafAssetsWith({ { "blending", "bogus" }, { "cullmode", "inverted" }, { "depthtest", "greater" }, { "depthwrite", "always" } },
                                { { "blending", "Additive" }, { "cullmode", "nocull" }, { "depthtest", "less" }, { "depthwrite", "enabled" } }));
    auto     scene = rig.Parse(PerspectiveScene(Json::array({ { { "id", 1 }, { "name", "model" }, { "model", "planet.mdl" } } })));
    ASSERT_NE(scene, nullptr);
    const auto slots = SlotsOf(*scene, "model");
    ASSERT_EQ(slots.size(), 2u);

    EXPECT_FALSE(slots[0]->depth_test);
    EXPECT_FALSE(slots[0]->depth_write);
    EXPECT_EQ(slots[0]->cull_mode, CullMode::Back);
    EXPECT_EQ(slots[0]->blenmode, BlendMode::Normal);

    EXPECT_FALSE(slots[1]->depth_test);
    EXPECT_TRUE(slots[1]->depth_write);
    EXPECT_EQ(slots[1]->cull_mode, CullMode::None);
    EXPECT_EQ(slots[1]->blenmode, BlendMode::Normal) << "the words are matched case-sensitively";

    // Drawn, a pass that does not depth-test writes no depth either.
    const auto drawn = ResolveSceneDepthState(*slots[1], slots[1]->blenmode, true);
    EXPECT_FALSE(drawn.test);
    EXPECT_FALSE(drawn.write);
}

// Probe T10 (artifacts/we-parity/probes/texshader2): an image layer whose material names no
// `blending` writes its fragment as it is, as `normal` does; the enum field starts at its first
// entry. A missing key is not translucent.
TEST(ModelLayerParse, AnImageMaterialWithoutABlendingWordBlendsAsNormal)
{
    FileMap assets = BasicAssets();
    PutJson(assets, "/mat.json",
            { { "passes", Json::array({ { { "shader", "genericimage" }, { "cullmode", "nocull" },
                                          { "depthtest", "disabled" }, { "depthwrite", "disabled" },
                                          { "textures", Json::array({ "a.tex" }) } } }) } });
    ParseRig rig(assets);
    auto     scene = rig.Parse(QuietScene(Json::array({ { { "id", 1 }, { "name", "img" }, { "image", "image.json" } } })));
    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "img");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_NE(node->Mesh()->Material(), nullptr);
    EXPECT_EQ(node->Mesh()->Material()->blenmode, BlendMode::Normal);
}

// B-1.14: the depth rule on materials that do test.
TEST(ModelLayerParse, DepthStateFollowsTheTargetsDepthAttachment)
{
    ParseRig rig(LeafModelAssets());
    auto     scene = rig.Parse(PerspectiveScene(Json::array({ { { "id", 1 }, { "name", "model" }, { "model", "planet.mdl" } } })));
    ASSERT_NE(scene, nullptr);
    const auto slots = SlotsOf(*scene, "model");
    ASSERT_EQ(slots.size(), 2u);
    ASSERT_TRUE(slots[0]->depth_test);
    ASSERT_TRUE(slots[0]->depth_write);

    const auto with_depth = ResolveSceneDepthState(*slots[0], slots[0]->blenmode, true);
    EXPECT_TRUE(with_depth.test);
    EXPECT_TRUE(with_depth.write);
    const auto without_depth = ResolveSceneDepthState(*slots[0], slots[0]->blenmode, false);
    EXPECT_FALSE(without_depth.test);
    EXPECT_FALSE(without_depth.write);

    ASSERT_TRUE(slots[1]->depth_test);
    ASSERT_FALSE(slots[1]->depth_write);
    EXPECT_TRUE(ResolveSceneDepthState(*slots[1], slots[1]->blenmode, true).test);
    EXPECT_FALSE(ResolveSceneDepthState(*slots[1], slots[1]->blenmode, true).write);

    // Wallpaper Engine's device (`sub_140099F60`) gives a draw that blends no depth write
    // whatever its material says; it still tests. `normal` and `alphatocoverage` write.
    for (const auto blend : { BlendMode::Translucent, BlendMode::Additive }) {
        const auto drawn = ResolveSceneDepthState(*slots[0], blend, true);
        EXPECT_TRUE(drawn.test);
        EXPECT_FALSE(drawn.write);
    }
    for (const auto blend : { BlendMode::Normal, BlendMode::AlphaToCoverage, BlendMode::Disable }) {
        EXPECT_TRUE(ResolveSceneDepthState(*slots[0], blend, true).write);
    }
}

// ---- bones -------------------------------------------------------------------------------

// R-1.15 / B-1.15
TEST(ModelLayerParse, BonesReachEveryMaterialAndTheBindPoseIsTheIdentity)
{
    ParseRig rig(PuppetAssets());
    auto     scene = rig.Parse(PerspectiveScene(Json::array({ { { "id", 1 }, { "name", "model" }, { "model", "puppet.mdl" },
                                                                { "animationlayers", Json::array({ { { "animation", 99 }, { "id", 7 }, { "name", "motion" }, { "blend", 1 }, { "rate", 2 } } }) } } })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    ASSERT_NE(scene->shaderValueUpdater, nullptr);

    SceneNode* node = FindRootChild(*scene, "model");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);

    WPPuppetLayer* layer = scene->runtime->FindPuppetLayer("model");
    ASSERT_NE(layer, nullptr);
    EXPECT_EQ(layer->findLayer("motion"), 0);
    EXPECT_DOUBLE_EQ(layer->rate(0), 2.0);

    for (uint32_t slot = 0; slot < 2; ++slot) {
        SCOPED_TRACE(slot);
        scene->shaderValueUpdater->InitUniforms(node, slot, [](std::string_view name) { return name == "g_Bones"; });
        sprite_map_t sprites;
        int          calls = 0;
        scene->shaderValueUpdater->UpdateUniforms(node, slot, sprites, [&](std::string_view name, const ShaderValue& value) {
            if (name != "g_Bones") return;
            ++calls;
            ASSERT_EQ(value.size(), 16u);
            for (std::size_t i = 0; i < 16; ++i) EXPECT_EQ(value[i], i % 5 == 0 ? 1.0f : 0.0f) << "element " << i;
        });
        EXPECT_EQ(calls, 1) << "g_Bones is written once per material, and the identity stands even though no clip has animation 99";
    }
}

TEST(ModelLayerParse, ImagePuppetsSolveIkButThreeDimensionalModelsKeepForwardKinematics)
{
    // The same MDLS chain is routed through both scene object kinds. WE's image composer
    // (0x1401FDF90) solves it; the model composer (0x14021C480) does not. The v1 model probe
    // and the target-shifted known-good image puppet distinguish the two paths visibly.
    mdltest::MeshSpec mesh;
    mesh.material = "mat/head.json";
    mesh.flag = mdltest::kSkinned;
    auto file = mdltest::mdlFile(23, { mesh });
    std::vector<mdltest::BoneSpec> bones {
        { "anchor", mdltest::kNone }, { "root", 0 },
        { "joint", 1, { 8, 6, 0 } }, { "tip", 2, { 8, -6, 0 } }
    };
    bones[3].simulation = R"({"ik":true,"ikd":2})";
    mdltest::SkeletonTail tail;
    tail.targets = { { "goal", 3, 0, { 12, 5, 0 } } };
    tail.table = { 0, 0, 10, 10 };
    tail.groups = { {}, { { 2, { 0.8f, 0.6f, 0 } } }, { { 3, { 0.8f, -0.6f, 0 } } }, {} };
    tail.chains = { { 1, { 0 }, { { 1, { { 3, 1, std::bit_cast<uint32_t>(20.0f), 0, { 1, 2, 3 } } } } } } };
    mdltest::writeSkeleton(file, 4, bones, tail, { 1, 3, 3, 3 });
    file.stamp("MDLA", 0).u8(0);
    auto assets = PuppetAssets();
    assets["/puppet.mdl"].assign(reinterpret_cast<const char*>(file.data().data()), file.size());
    ParseRig rig(std::move(assets));
    auto scene = rig.Parse(QuietScene(Json::array({
        { { "id", 1 }, { "name", "model" }, { "model", "puppet.mdl" } },
        { { "id", 2 }, { "name", "image" }, { "image", "puppet_image.json" } }
    })), { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* model = scene->runtime->FindPuppetLayer("model");
    auto* image = scene->runtime->FindPuppetLayer("image");
    ASSERT_NE(model, nullptr);
    ASSERT_NE(image, nullptr);
    model->genFrame(0);
    image->genFrame(0);
    ASSERT_EQ(model->modelBones().size(), 4u);
    ASSERT_EQ(image->modelBones().size(), 4u);
    EXPECT_NEAR(model->modelBones()[3].translation().x(), 16, 1e-4);
    EXPECT_NEAR(model->modelBones()[3].translation().y(), 0, 1e-4);
    EXPECT_LE((image->modelBones()[3].translation() - linalg::Vector3f(12, 5, 0)).squaredNorm(), 0.1f);
}

} // namespace
