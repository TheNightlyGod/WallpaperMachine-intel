// Scene file schema, part 4: cards and anchors. The card a passthrough layer with an effect is
// drawn on, and the puppet attachments child layers hang from (parsed, and at the level of the
// shader-value updater that follows an animated bone).
#include "support/schema_fixtures_part03.hpp"

#include "Interface/IShaderValueUpdater.h"
#include "WPShaderValueUpdater.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace we_schema::p3;
using namespace wallpaper;

// ---- passthrough layers ------------------------------------------------------------------------

FileMap PassthroughAssets(const std::string& base_shader = "passthrough")
{
    FileMap files = BasicAssets();
    const std::string vertex   = files["/shaders/genericimage.vert"];
    const std::string fragment = files["/shaders/genericimage.frag"];
    for (const char* name : { "passthrough", "effectcopy" }) {
        files[std::string("/shaders/") + name + ".vert"] = vertex;
        files[std::string("/shaders/") + name + ".frag"] = fragment;
    }
    for (const char* path : { "/models/util/composelayer.json", "/models/util/composelayer_depthtest.json", "/layer/passthrough.json" }) {
        PutJson(files, path, { { "width", 64 }, { "height", 32 }, { "passthrough", true }, { "material", "materials/base_passthrough.json" } });
    }
    PutJson(files, "/materials/base_passthrough.json",
            { { "passes", Json::array({ { { "blending", "translucent" }, { "cullmode", "nocull" }, { "depthtest", "disabled" }, { "depthwrite", "disabled" },
                                          { "shader", base_shader }, { "textures", Json::array({ "a.tex" }) } } }) } });
    PutJson(files, "/effects/copy/effect.json",
            { { "name", "copy" },
              { "passes", Json::array({ { { "material", "materials/effect_copy.json" }, { "bind", Json::array({ { { "name", "previous" }, { "index", 0 } } }) } } }) } });
    PutJson(files, "/materials/effect_copy.json",
            { { "passes", Json::array({ { { "blending", "translucent" }, { "cullmode", "nocull" }, { "depthtest", "disabled" }, { "depthwrite", "disabled" },
                                          { "shader", "effectcopy" }, { "textures", Json::array({ nullptr }) } } }) } });
    return files;
}

Json PassthroughScene(const std::string& model, bool with_effect)
{
    Json layer = ImageObject(1, "card", { { "image", model }, { "origin", Json::array({ 180, 90, 0 }) }, { "config", { { "passthrough", true } } } });
    if (with_effect) layer["effects"] = CopyEffectEntry(3);
    return CanvasOf(Json::array({ layer }), { { "orthogonalprojection", { { "width", 640 }, { "height", 360 } } } });
}

const SceneVertexArray& CardVertices(SceneNode& node)
{
    return node.Mesh()->Submeshes().at(0).GetVertexArray(0);
}

void ExpectVertex(const SceneVertexArray& vertices, std::size_t index, std::array<float, 3> position, std::array<float, 2> uv, float tolerance = 1e-6f)
{
    SCOPED_TRACE("vertex " + std::to_string(index));
    const auto at = VertexPosition(vertices, index);
    const auto st = VertexUv(vertices, index);
    EXPECT_NEAR(at[0], position[0], tolerance);
    EXPECT_NEAR(at[1], position[1], tolerance);
    EXPECT_NEAR(at[2], position[2], tolerance);
    EXPECT_NEAR(st[0], uv[0], tolerance);
    EXPECT_NEAR(st[1], uv[1], tolerance);
}

// R-4.03 / B-4.04
class ComposeLayerModels : public ::testing::TestWithParam<const char*> {};

TEST_P(ComposeLayerModels, KeepTheLayersOwnLocalCard)
{
    ParseRig rig(PassthroughAssets());
    auto     scene = rig.Parse(PassthroughScene(GetParam(), true));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "card");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->Submeshes().size(), 1u);
    const auto& vertices = CardVertices(*node);
    ASSERT_EQ(vertices.VertexCount(), 4u);
    EXPECT_TRUE(NearArray(VertexPosition(vertices, 0), { -32, -16, 0 }, 0.0f));
    EXPECT_TRUE(NearArray(VertexPosition(vertices, 1), { -32, 16, 0 }, 0.0f));
    EXPECT_TRUE(NearArray(VertexPosition(vertices, 2), { 32, -16, 0 }, 0.0f));
    EXPECT_TRUE(NearArray(VertexPosition(vertices, 3), { 32, 16, 0 }, 0.0f));
}

INSTANTIATE_TEST_SUITE_P(Models, ComposeLayerModels, ::testing::Values("models/util/composelayer.json", "models/util/composelayer_depthtest.json"));

// R-4.04 / B-4.05
TEST(PassthroughCards, AnyOtherPassthroughLayerWithAnEffectIsProjectedFromWhereItStandsOnTheCanvas)
{
    ParseRig rig(PassthroughAssets());
    auto     scene = rig.Parse(PassthroughScene("layer/passthrough.json", true));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "card");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& vertices = CardVertices(*node);
    ASSERT_EQ(vertices.VertexCount(), 4u);
    ExpectVertex(vertices, 0, { -0.5375f, -0.5888889f, 0 }, { 0.23125f, 0.79444444f });
    ExpectVertex(vertices, 1, { -0.5375f, -0.41111112f, 0 }, { 0.23125f, 0.70555556f });
    ExpectVertex(vertices, 2, { -0.3375f, -0.5888889f, 0 }, { 0.33125f, 0.79444444f });
    ExpectVertex(vertices, 3, { -0.3375f, -0.41111112f, 0 }, { 0.33125f, 0.70555556f });
    EXPECT_GT(std::abs(VertexPosition(vertices, 0)[0] - (-32.0f)), 1.0f);
    EXPECT_GT(std::abs(VertexUv(vertices, 0)[1] - 1.0f), 0.1f);
}

TEST(PassthroughCards, WithoutAClipSpaceShaderTheCornersStayLocalButTheUvIsProjected)
{
    ParseRig rig(PassthroughAssets("genericimage"));
    auto     scene = rig.Parse(PassthroughScene("layer/passthrough.json", true));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "card");
    ASSERT_NE(node, nullptr);
    const auto& vertices = CardVertices(*node);
    ASSERT_EQ(vertices.VertexCount(), 4u);
    ExpectVertex(vertices, 0, { -32, -16, 0 }, { 0.23125f, 0.79444444f });
    ExpectVertex(vertices, 3, { 32, 16, 0 }, { 0.33125f, 0.70555556f });
}

TEST(PassthroughCards, WithoutAnEffectTheLayerKeepsThePlainCard)
{
    ParseRig rig(PassthroughAssets());
    auto     scene = rig.Parse(PassthroughScene("layer/passthrough.json", false));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "card");
    ASSERT_NE(node, nullptr);
    const auto& vertices = CardVertices(*node);
    ASSERT_EQ(vertices.VertexCount(), 4u);
    ExpectVertex(vertices, 0, { -32, -16, 0 }, { 0, 1 });
    ExpectVertex(vertices, 1, { -32, 16, 0 }, { 0, 0 });
    ExpectVertex(vertices, 2, { 32, -16, 0 }, { 1, 1 });
    ExpectVertex(vertices, 3, { 32, 16, 0 }, { 1, 0 });
}

// ---- puppet attachments in a parsed scene -------------------------------------------------------

FileMap AttachmentAssets(const std::string& model = MdlWithAttachment())
{
    FileMap files = PuppetAssets();
    files["/puppet.mdl"] = model;
    Add(files, GenericImageShaders());
    files["/shaders/childimage.vert"] = files["/shaders/genericimage.vert"];
    files["/shaders/childimage.frag"] = files["/shaders/genericimage.frag"];
    PutJson(files, "/child.json", { { "material", "mat/child.json" }, { "width", 16 }, { "height", 8 } });
    PutJson(files, "/mat/child.json",
            { { "passes", Json::array({ { { "blending", "translucent" }, { "cullmode", "nocull" }, { "depthtest", "disabled" }, { "depthwrite", "disabled" },
                                          { "shader", "childimage" }, { "textures", Json::array({ "child.tex" }) } } }) } });
    files["/materials/child.tex.tex"] = "";
    return files;
}

Json AttachmentObjects(const std::string& attachment, bool reversed, const std::string& parent_image = "puppet_image.json")
{
    Json parent = ImageObject(300, "puppet parent", { { "image", parent_image }, { "origin", Json::array({ 10, 20, 0 }) } });
    Json child  = ImageObject(301, "hat child", { { "image", "child.json" }, { "parent", 300 }, { "attachment", attachment }, { "origin", Json::array({ 1, 2, 3 }) } });
    return reversed ? Json::array({ child, parent }) : Json::array({ parent, child });
}

// The model matrix of the child of the parent layer after a parse; null when the graph is wrong.
bool ChildModel(const FileMap& files, const Json& objects, linalg::Matrix4d& model)
{
    ParseRig rig(files);
    auto     scene = rig.Parse(CanvasOf(objects));
    EXPECT_NE(scene, nullptr);
    if (scene == nullptr) return false;
    SceneNode* parent = FindRootChild(*scene, "puppet parent");
    EXPECT_NE(parent, nullptr);
    if (parent == nullptr) return false;
    SceneNode* child = FindChild(*parent, "hat child");
    EXPECT_NE(child, nullptr);
    if (child == nullptr) return false;
    EXPECT_EQ(child->Parent(), parent);
    child->UpdateTrans();
    model = child->ModelTrans();
    return true;
}

void ExpectTranslation(const linalg::Matrix4d& model, double x, double y, double z)
{
    EXPECT_NEAR(model(0, 3), x, 1e-5);
    EXPECT_NEAR(model(1, 3), y, 1e-5);
    EXPECT_NEAR(model(2, 3), z, 1e-5);
}

// R-4.05 / B-4.06
TEST(PuppetAttachmentLayers, AChildNamingAnAttachmentHangsFromThatAnchor)
{
    linalg::Matrix4d model;
    ASSERT_TRUE(ChildModel(AttachmentAssets(), AttachmentObjects("hat_anchor", false), model));
    ExpectTranslation(model, 15, 27, 9);
}

// R-4.05 / B-4.07
TEST(PuppetAttachmentLayers, TheResultDoesNotDependOnTheDeclarationOrder)
{
    linalg::Matrix4d declared, reversed;
    ASSERT_TRUE(ChildModel(AttachmentAssets(), AttachmentObjects("hat_anchor", false), declared));
    ASSERT_TRUE(ChildModel(AttachmentAssets(), AttachmentObjects("hat_anchor", true), reversed));
    EXPECT_TRUE(reversed.isApprox(declared, 1e-6));
    ExpectTranslation(reversed, 15, 27, 9);
}

TEST(PuppetAttachmentLayers, AnAnchorTheParentDoesNotHaveLeavesTheChildAtTheParentsOrigin)
{
    linalg::Matrix4d model;
    ASSERT_TRUE(ChildModel(AttachmentAssets(), AttachmentObjects("no_such_anchor", false), model));
    ExpectTranslation(model, 11, 22, 3);
}

TEST(PuppetAttachmentLayers, AnAnchorOnABoneThatIsNotThereLeavesTheChildAtTheParentsOrigin)
{
    std::string mdl = MdlWithAttachment();
    // The attachment block: stamp (9 bytes), end offset (4), count (2), then the u16 bone index.
    const auto block = mdl.find("MDAT0001");
    ASSERT_NE(block, std::string::npos);
    mdl[block + 9 + 4 + 2]     = 9;
    mdl[block + 9 + 4 + 2 + 1] = 0;
    linalg::Matrix4d model;
    ASSERT_TRUE(ChildModel(AttachmentAssets(mdl), AttachmentObjects("hat_anchor", false), model));
    ExpectTranslation(model, 11, 22, 3);
}

TEST(PuppetAttachmentLayers, ALayerThatIsNotAPuppetHasNoAnchors)
{
    linalg::Matrix4d model;
    FileMap          files = AttachmentAssets();
    Add(files, BasicAssets());
    ASSERT_TRUE(ChildModel(files, AttachmentObjects("hat_anchor", false, "image.json"), model));
    ExpectTranslation(model, 11, 22, 3);
}

// ---- puppet attachments following a bone ---------------------------------------------------------

linalg::Matrix4d Moved(double x, double y, double z)
{
    linalg::Matrix4d m = linalg::Matrix4d::Identity();
    m(0, 3) = x;
    m(1, 3) = y;
    m(2, 3) = z;
    return m;
}

linalg::Matrix4d Turned(double angle)
{
    linalg::Matrix4d m = linalg::Matrix4d::Identity();
    m(0, 0) = std::cos(angle);
    m(0, 1) = -std::sin(angle);
    m(1, 0) = std::sin(angle);
    m(1, 1) = std::cos(angle);
    return m;
}

linalg::Matrix4d Scaled(double x, double y, double z)
{
    linalg::Matrix4d m = linalg::Matrix4d::Identity();
    m(0, 0) = x;
    m(1, 1) = y;
    m(2, 2) = z;
    return m;
}

constexpr double kQuarterTurn = 1.57079632679;

// One bone bound at (100, 200) whose single animation moves it from (10, 20) to (30, 40) while it
// turns a quarter and grows to (2, 3, 1); an updater registered with a node that hangs from
// the point (4, 5) of the bone.
struct BoneRig {
    Scene                      scene;
    std::shared_ptr<WPPuppet>  puppet = std::make_shared<WPPuppet>();
    WPPuppetLayer              layer;
    std::unique_ptr<WPShaderValueUpdater> updater;
    std::shared_ptr<SceneNode> parent = std::make_shared<SceneNode>(linalg::Vector3f(5, 7, 0), linalg::Vector3f(2, 2, 1), linalg::Vector3f(0, 0, 0), "parent");
    std::shared_ptr<SceneNode> child  = std::make_shared<SceneNode>(linalg::Vector3f(1, 2, 0), linalg::Vector3f(1, 1, 1), linalg::Vector3f(0, 0, 0), "child");
    linalg::Matrix4d           attachment = linalg::Matrix4d::Identity();

    BoneRig()
    {
        puppet->bones.resize(1);
        puppet->bones[0].local_bind.matrix() = Moved(100, 200, 0).cast<float>();
        WPPuppet::Animation animation {};
        animation.id     = 1;
        animation.fps    = 1;
        animation.length = 1;
        animation.mode   = WPPuppet::PlayMode::Single;
        WPPuppet::Animation::BoneTrack track;
        WPPuppet::BoneFrame            first {};
        first.position = linalg::Vector3f(10, 20, 0);
        first.angle    = linalg::Vector3f(0, 0, 0);
        first.scale    = linalg::Vector3f(1, 1, 1);
        WPPuppet::BoneFrame second {};
        second.position = linalg::Vector3f(30, 40, 0);
        second.angle    = linalg::Vector3f(0, 0, static_cast<float>(kQuarterTurn));
        second.scale    = linalg::Vector3f(2, 3, 1);
        track.bone_index = 0;
        track.frames     = { first, second };
        animation.bone_tracks.push_back(track);
        puppet->anims.push_back(animation);
        puppet->prepared();

        layer = WPPuppetLayer(puppet);
        std::vector<WPPuppetLayer::AnimationLayer> layers(1);
        layers[0].id = 1;
        layer.prepared(layers);

        parent->AppendChild(child);
        updater = std::make_unique<WPShaderValueUpdater>(&scene);
        updater->SetCameraParallax({ .enable = false, .amount = 0.0f, .delay = 1.0f, .mouseinfluence = 0.0f });
        linalg::Affine3f bind = puppet->bones[0].world_bind;
        bind.translate(linalg::Vector3f(4, 5, 0));
        attachment = bind.matrix().cast<double>();
        updater->RegisterPuppetAttachments(layer, { { child.get(), 0, bind } });
    }

    // The pose of the bone at the layer's current frame, as the skinned draw receives it.
    linalg::Matrix4d Pose(double x, double y, double angle, double sx, double sy) const
    {
        return Moved(x, y, 0) * Turned(angle) * Scaled(sx, sy, 1) * puppet->bones[0].inv_bind.matrix().cast<double>();
    }

    void Advance(double seconds)
    {
        scene.PassFrameTime(seconds);
        updater->FrameBegin();
    }
};

// R-4.06 / B-4.08
TEST(PuppetAttachmentFollowing, ANodeFollowsTheAnimatedBonesFullAffine)
{
    BoneRig rig;
    rig.child->UpdateTrans();
    EXPECT_NEAR(rig.child->ModelTrans()(0, 3), 35.0, 1e-4);
    EXPECT_NEAR(rig.child->ModelTrans()(1, 3), 61.0, 1e-4);

    rig.Advance(1.0);
    rig.child->UpdateTrans();
    const auto after = rig.child->ModelTrans();
    EXPECT_NEAR(after(0, 3), 23.0, 1e-4);
    EXPECT_NEAR(after(1, 3), 107.0, 1e-4);
    EXPECT_NEAR(after(0, 1), -6.0, 1e-4);
    EXPECT_NEAR(after(1, 0), 4.0, 1e-4);
    EXPECT_NEAR(after(0, 0), 0.0, 1e-4);
    EXPECT_NEAR(after(1, 1), 0.0, 1e-4);

    // A second frame at the same time changes nothing.
    rig.updater->FrameBegin();
    rig.child->UpdateTrans();
    EXPECT_TRUE(rig.child->ModelTrans().isApprox(after, 1e-6));
}

// R-4.06 / B-4.09, B-4.10
TEST(PuppetAttachmentFollowing, TheAttachmentUsesTheSamePoseAsTheSkinnedDrawAndKeepsLocalEdits)
{
    BoneRig rig;
    rig.Advance(1.0);
    rig.child->UpdateTrans();

    // A local edit of the node is kept under the attachment: (3,2) instead of (1,2) moves the
    // node two units along the bone's x axis, which the parent's scale doubles.
    rig.child->SetTranslate({ 3, 2, 0 });
    rig.updater->FrameBegin();
    rig.child->UpdateTrans();
    EXPECT_NEAR(rig.child->ModelTrans()(0, 3), 23.0, 1e-4);
    EXPECT_NEAR(rig.child->ModelTrans()(1, 3), 115.0, 1e-4);

    // The parent is drawn skinned with the same layer.
    SceneCamera camera(640, 360, 0.01f, 100.0f);
    rig.scene.activeCamera = &camera;
    auto mesh              = std::make_shared<SceneMesh>();
    mesh->AddMaterial(SceneMaterial {});
    rig.parent->AddMesh(mesh);
    WPShaderValueData data;
    data.puppet_layer = rig.layer;
    rig.updater->SetNodeData(rig.parent.get(), data);
    rig.updater->InitUniforms(rig.parent.get(), [](std::string_view name) { return name == "g_Bones"; });

    int                bone_writes = 0;
    std::vector<float> last_bones;
    sprite_map_t       sprites;
    const auto         draw = [&] {
        rig.updater->UpdateUniforms(rig.parent.get(), sprites, [&](std::string_view name, const ShaderValue& value) {
            if (name != "g_Bones") return;
            ++bone_writes;
            last_bones.assign(value.data(), value.data() + value.size());
        });
    };
    draw();
    EXPECT_EQ(bone_writes, 1);
    EXPECT_EQ(last_bones.size(), 16u);

    // Half way through the animation.
    ASSERT_TRUE(rig.layer.setFrame(0, 0.5));
    rig.updater->FrameBegin();
    draw();
    EXPECT_EQ(bone_writes, 2);
    const linalg::Matrix4d pose = rig.Pose(20, 30, 0.785398163395, 1.5, 2);
    ASSERT_EQ(last_bones.size(), 16u);
    linalg::Matrix4f uniform;
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) uniform(row, column) = last_bones[static_cast<std::size_t>(column * 4 + row)];
    }
    EXPECT_TRUE(uniform.isApprox(pose.cast<float>(), 1e-5f));

    rig.child->UpdateTrans();
    linalg::Matrix4d expected = rig.parent->ModelTrans() * (pose * rig.attachment) * Moved(3, 2, 0);
    EXPECT_TRUE(rig.child->ModelTrans().isApprox(expected, 1e-5));

    // Bones are written on every draw, also when the pose has not changed, and a later local
    // edit is still kept.
    rig.child->SetTranslate({ 4, 6, 0 });
    rig.updater->FrameBegin();
    draw();
    EXPECT_EQ(bone_writes, 3);
    linalg::Matrix4f again;
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) again(row, column) = last_bones[static_cast<std::size_t>(column * 4 + row)];
    }
    EXPECT_TRUE(again.isApprox(uniform, 1e-6f));
    rig.child->UpdateTrans();
    expected = rig.parent->ModelTrans() * (pose * rig.attachment) * Moved(4, 6, 0);
    EXPECT_TRUE(rig.child->ModelTrans().isApprox(expected, 1e-5));

    // Playing on, time passing moves the skinned draw and the attachment together.
    ASSERT_TRUE(rig.layer.play(0));
    rig.Advance(0.25);
    draw();
    EXPECT_EQ(bone_writes, 4);
    linalg::Matrix4f later;
    for (int column = 0; column < 4; ++column) {
        for (int row = 0; row < 4; ++row) later(row, column) = last_bones[static_cast<std::size_t>(column * 4 + row)];
    }
    const linalg::Matrix4d moved_pose = rig.Pose(25, 35, 0.75 * kQuarterTurn, 1.75, 2.5);
    EXPECT_TRUE(later.isApprox(moved_pose.cast<float>(), 1e-5f));
    rig.child->UpdateTrans();
    expected = rig.parent->ModelTrans() * (moved_pose * rig.attachment) * Moved(4, 6, 0);
    EXPECT_TRUE(rig.child->ModelTrans().isApprox(expected, 1e-5));

    rig.scene.activeCamera = nullptr;
}

} // namespace
