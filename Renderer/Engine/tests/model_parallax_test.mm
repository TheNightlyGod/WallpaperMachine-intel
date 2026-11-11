// Camera parallax moves a 3D model layer by its depth as it moves every other layer: a model
// under a group rides the group's depth and anchor, and a 3D scene moves it by its own distance
// from the camera. Checked by where the model is drawn, through the synthetic scene harness.

#include <gtest/gtest.h>

#include "render_fixtures.hpp"
#include "support/gpu_scene.hpp"
#include "support/pixels.hpp"
#include "support/scene_package.hpp"

#include "Interface/IShaderValueUpdater.h"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Runtime/SceneRuntimeContext.hpp"

#include <cmath>
#include <cstring>
#include <fstream>
#include <vector>
#include <optional>

namespace
{
using namespace we_test;
using namespace we_test::fixtures;

constexpr uint32_t kWidth  = 256;
constexpr uint32_t kHeight = 144;

const char* kRed = R"(varying vec2 v_TexCoord;
void main() {
    gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0);
}
)";

// Red, with the parallax position the shader is told in green and blue.
const char* kParallaxProbe = R"(varying vec2 v_TexCoord;
uniform vec2 g_ParallaxPosition;
void main() {
    gl_FragColor = vec4(1.0, g_ParallaxPosition.x, g_ParallaxPosition.y, 1.0);
}
)";

// A version 13 model of one square, 40 units to a side, centred on its own origin.
std::string MakeSquareModel(const std::string& material, bool horizontal = false)
{
    std::string bytes;
    const auto  u32 = [&](uint32_t value) { bytes.append(reinterpret_cast<const char*>(&value), 4); };
    const auto  f32 = [&](float value) { bytes.append(reinterpret_cast<const char*>(&value), 4); };
    const auto  u16 = [&](uint16_t value) { bytes.append(reinterpret_cast<const char*>(&value), 2); };
    bytes.append("MDLV0013", 8);
    bytes.push_back('\0');
    u32(0x9); // positions and one set of texture coordinates
    u32(0);
    u32(1);   // one mesh
    bytes.append(material);
    bytes.push_back('\0');
    u32(0);
    u32(4 * 20);
    const float corners[4][5] = { { -20, -20, 0, 0, 1 }, { 20, -20, 0, 1, 1 }, { 20, 20, 0, 1, 0 }, { -20, 20, 0, 0, 0 } };
    for (const auto& corner : corners) {
        f32(corner[0]);
        f32(horizontal ? 10.0f : corner[1]);
        f32(horizontal ? -corner[1] : corner[2]);
        f32(corner[3]);
        f32(corner[4]);
    }
    u32(12);
    for (const uint16_t index : { 0, 1, 2, 0, 2, 3 }) u16(index);
    return bytes;
}

// The horizontal centre of the lit pixels of one row, or nothing when none is lit.
std::optional<double> LitCentre(const Image& picture, uint32_t row)
{
    double weight = 0.0;
    double moment = 0.0;
    for (uint32_t x = 0; x < picture.width; ++x) {
        const double lit = picture.At(x, row)[0] / 255.0;
        weight += lit;
        moment += lit * (x + 0.5);
    }
    if (weight < 1.0) return std::nullopt;
    return moment / weight;
}

struct ModelScene {
    Json  group_depth = "0.5 0.5";
    Json  model_depth = "0 0";
    std::array<float, 3> group_origin { 128.0f, 72.0f, 0.0f };
    bool  grouped { true };
    bool  parallax { true };
    bool  perspective { false };
    float amount { 0.5f };
    float influence { 0.5f };
    const char* fragment { kRed };
};

void Build(ScenePackage& package, const ModelScene& spec, Json general_extra = Json::object(), bool three_d = false)
{
    package.InstallStandardAssets();
    package.AddShader("model_red", StandardVertexShader(), spec.fragment);
    package.PutJson("materials/square.json",
                    { { "passes", Json::array({ FlatPass("model_red", Json::array({ "util/white" }), "translucent") }) } });
    package.Put("models/square.mdl", MakeSquareModel("materials/square.json"));

    std::vector<Json> objects;
    Json              model = { { "id", 2 }, { "name", "square" }, { "model", "models/square.mdl" },
                                { "origin", spec.grouped ? "0 0 0" : "128 72 0" },
                                { "parallaxDepth", spec.model_depth } };
    if (spec.grouped) {
        Json group = GroupJson(1, "group", spec.group_origin);
        group["parallaxDepth"] = spec.group_depth;
        objects.push_back(group);
        model["parent"] = 1;
    }
    if (spec.perspective) model["perspective"] = true;
    objects.push_back(model);

    SceneGeneral general;
    general.parallax                 = spec.parallax;
    general.parallax_amount          = spec.amount;
    general.parallax_mouse_influence = spec.influence;
    general.parallax_delay           = 0.0f;
    general.extra                    = general_extra;
    Json scene = SceneJson(general, objects);
    if (three_d) scene["general"]["orthogonalprojection"] = nullptr;
    package.SetProject();
    package.SetScene(scene);
}

class ModelParallax : public ::testing::Test {
protected:
    void SetUp() override { WE_SKIP_WITHOUT_METAL(); }

    // Where the model is drawn with the pointer in the middle and at the right edge.
    static std::pair<double, double> Centres(const ModelScene& spec)
    {
        ScenePackage package;
        Build(package, spec);
        GpuScene scene(package);
        EXPECT_TRUE(scene.ok()) << scene.error();
        scene.SetPointer(0.5, 0.5);
        const Image centred = scene.Run(3);
        KeepPicture("model_parallax_centred", centred);
        scene.SetPointer(1.0, 0.5);
        const Image edge = scene.Run(3);
        KeepPicture("model_parallax_edge", edge);
        const auto a = LitCentre(centred, 72);
        const auto b = LitCentre(edge, 72);
        EXPECT_TRUE(a.has_value() && b.has_value()) << "the model is drawn";
        return { a.value_or(-1000.0), b.value_or(-1000.0) };
    }
};

} // namespace

TEST_F(ModelParallax, AModelUnderAGroupMovesByTheGroupsDepthNotItsOwnStaleZero)
{
    // Pointer at the right edge: (0.5 - 1.0) * 256 * influence 0.5 = -64 units of mouse offset,
    // times the group's depth 0.5 and the scene's amount 0.5.
    const auto [centred, edge] = Centres({});
    EXPECT_NEAR(centred, 128.0, 1.0);
    EXPECT_NEAR(edge - centred, -16.0, 1.0);
}

TEST_F(ModelParallax, ImageAndComposeCardsStayOnAModelFaceWhileItsParentTurns)
{
    // The model's face is in its XZ plane, ten units along Y. An image on that
    // face turns back by a quarter turn, inheriting the model's nonuniform scale.
    // Both must have the same silhouette as the outer group turns and the pointer moves.
    enum class Face { Model, Image, EffectImage, Compose, ComposeChildren };
    const std::array<wallpaper::linalg::Vector3f, 7> angles {{
        {0, 0, 0}, {0.4f, 0, 0}, {-0.4f, 0, 0}, {0, 0.5f, 0}, {0, -0.5f, 0},
        {0.35f, -0.45f, 0.2f}, {-0.35f, 0.45f, -0.2f}}};
    const auto draw = [&angles](Face face) {
        const bool cover = face != Face::Model;
        ScenePackage package;
        package.InstallStandardAssets();
        package.AddShader("face", StandardVertexShader(),
                          cover ? "void main() { gl_FragColor = vec4(0.0, 0.0, 0.0, 0.0); }" : kRed);
        package.PutJson("materials/face.json", {{"passes", Json::array({
            FlatPass("face", Json::array({"util/white"}), "translucent")})}});
        package.Put("models/face.mdl", MakeSquareModel("materials/face.json", true));
        Json group = GroupJson(1, "group", {118.0f, 78.0f, 0.0f});
        group["parallaxDepth"] = "-0.1 -0.1";
        Json model = {{"id", 2}, {"name", "face"}, {"model", "models/face.mdl"},
                      {"parent", 1}, {"origin", "0 0 0"}, {"angles", "1.570796327 0 0"},
                      {"scale", "1.3 0.2 1.1"}, {"parallaxDepth", "0 0"}, {"perspective", true}};
        ImageLayer card;
        card.id = 3;
        card.parent = 2;
        card.origin = {0.0f, 10.0f, 0.0f};
        card.size = {40.0f, 40.0f};
        card.color = "1 0 0";
        card.visible = cover;
        card.model = package.AddImageModel("cover", "util/white");
        card.extra = {{"angles", "-1.570796327 0 0"}, {"perspective", true}};
        if (face == Face::EffectImage)
            card.effects = {EffectUse(package.AddTintEffect("identity"), {{"tint", "1 1 1"}}, 7)};
        if (face == Face::Compose || face == Face::ComposeChildren) {
            package.AddImageModel("compose", "_rt_FullFrameBuffer");
            card.model = "models/util/composelayer.json";
            package.PutJson(card.model, {{"material", "materials/compose.json"}, {"passthrough", true}});
            card.effects = {EffectUse(AddFragmentEffect(package, "red", kRed), Json::object(), 7)};
        }
        std::vector<Json> objects {group, model};
        if (face == Face::ComposeChildren) {
            card.extra["copybackground"] = false;
            // The opaque effect fills the card whether it composes children or
            // copies a backdrop; both closing passes must follow the model's lens.
            ImageLayer child;
            child.id = 4;
            child.parent = card.id;
            child.origin = {0.0f, 0.0f, 0.0f};
            child.size = card.size;
            child.color = "1 0 0";
            child.model = package.AddImageModel("child", "util/white");
            objects.push_back(ImageLayerJson(card));
            objects.push_back(ImageLayerJson(child));
        } else {
            objects.push_back(ImageLayerJson(card));
        }
        SceneGeneral general;
        general.parallax = true;
        package.SetProject();
        package.SetScene(SceneJson(general, objects));
        GpuScene scene(package);
        EXPECT_TRUE(scene.ok()) << scene.error();
        std::vector<Image> pictures;
        if (!scene.ok() || scene.runtime() == nullptr) return pictures;
        for (std::size_t pose = 0; pose < angles.size(); ++pose) {
            EXPECT_TRUE(scene.runtime()->SetNodeRotation("group", angles[pose]));
            scene.SetPointer(pose % 2 == 0 ? 0.9 : 0.1, pose % 2 == 0 ? 0.15 : 0.85);
            pictures.push_back(scene.Run(4));
            KeepPicture("aligned_face_" + std::to_string(static_cast<int>(face)) + "_" + std::to_string(pose),
                        pictures.back());
        }
        return pictures;
    };
    const auto models = draw(Face::Model);
    ASSERT_EQ(models.size(), angles.size());
    for (Face face : {Face::Image, Face::EffectImage, Face::Compose, Face::ComposeChildren}) {
        SCOPED_TRACE(static_cast<int>(face));
        const auto covers = draw(face);
        ASSERT_EQ(covers.size(), models.size());
        for (std::size_t pose = 0; pose < models.size(); ++pose) {
            SCOPED_TRACE(pose);
            ASSERT_FALSE(models[pose].empty());
            ASSERT_FALSE(covers[pose].empty());
            EXPECT_GT(RegionAverage(models[pose], 0, 0, kWidth, kHeight)[0], 5.0)
                << "the model must draw a visible face";
            EXPECT_LE(CountDifferingPixels(covers[pose], models[pose], 8), 8u)
                << DescribeDifference(covers[pose], models[pose], 8);
        }
    }
}

TEST_F(ModelParallax, AModelRidesTheAnchorOfItsGroup)
{
    // The group stands 50 units to the right of the camera's centre, which adds
    // 50 * depth 0.5 * amount 0.5 even with the pointer in the middle.
    ModelScene spec;
    spec.group_origin = { 178.0f, 72.0f, 0.0f };
    const auto [centred, edge] = Centres(spec);
    EXPECT_NEAR(centred, 178.0 + 12.5, 1.0);
    EXPECT_NEAR(edge - centred, -16.0, 1.0);
}

TEST_F(ModelParallax, AModelWithNoGroupMovesByItsOwnDepth)
{
    ModelScene spec;
    spec.grouped     = false;
    spec.model_depth = "1 1";
    const auto [centred, edge] = Centres(spec);
    EXPECT_NEAR(centred, 128.0, 1.0);
    EXPECT_NEAR(edge - centred, -32.0, 1.0);
}

TEST_F(ModelParallax, AModelWithNoDepthStaysWhereItIs)
{
    ModelScene spec;
    spec.grouped     = false;
    spec.model_depth = "0 0";
    const auto [centred, edge] = Centres(spec);
    EXPECT_NEAR(edge, centred, 0.5);
}

TEST_F(ModelParallax, AModelDrawnThroughThePerspectiveCameraOfA2DSceneMovesToo)
{
    ModelScene spec;
    spec.grouped     = false;
    spec.model_depth = "1 1";
    spec.perspective = true;
    const auto [centred, edge] = Centres(spec);
    EXPECT_GT(centred, 0.0) << "the model is drawn";
    EXPECT_LT(edge, centred - 2.0) << "and follows the pointer";
}

TEST_F(ModelParallax, ASceneWithoutParallaxLeavesTheModelAlone)
{
    ModelScene spec;
    spec.parallax = false;
    const auto [centred, edge] = Centres(spec);
    EXPECT_NEAR(centred, 128.0, 1.0);
    EXPECT_NEAR(edge, centred, 0.5);

    ModelScene no_amount;
    no_amount.amount = 0.0f;
    const auto [still, moved] = Centres(no_amount);
    EXPECT_NEAR(moved, still, 0.5);
}

TEST_F(ModelParallax, MouseParallaxOffKeepsLayersStill)
{
    // The user's per-wallpaper switch (Wallpaper Engine's injected `cameraparallax`, which
    // sub_140115280 turns into scene flag 0x200) holds cursor parallax in the middle in a
    // scene that has it on: the model stays put and shaders read the centre.
    ModelScene spec;
    spec.grouped     = false;
    spec.model_depth = "1 1";
    spec.fragment    = kParallaxProbe;
    ScenePackage package;
    Build(package, spec);
    GpuSceneOptions options;
    options.user_options.mouse_parallax = false;
    GpuScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.SetPointer(0.5, 0.5);
    const Image centred = scene.Run(3);
    scene.SetPointer(0.9, 0.1);
    const Image moved = scene.Run(3);
    const auto a = LitCentre(centred, 72);
    const auto b = LitCentre(moved, 72);
    ASSERT_TRUE(a.has_value() && b.has_value()) << "the model is drawn";
    EXPECT_NEAR(*b, *a, 0.5);
    const auto at = static_cast<uint32_t>(std::lround(*b));
    EXPECT_NEAR(moved.At(at, 72)[1], 128, 1) << "g_ParallaxPosition.x reads the centre";
    EXPECT_NEAR(moved.At(at, 72)[2], 128, 1) << "g_ParallaxPosition.y reads the centre";

    // Turned on again while the scene runs, the cursor moves the model once more.
    scene.scene().shaderValueUpdater->SetUserMouseParallax(true);
    ASSERT_TRUE(scene.Rebuild()) << scene.error();
    scene.SetPointer(1.0, 0.5);
    const auto edge = LitCentre(scene.Run(3), 72);
    ASSERT_TRUE(edge.has_value());
    EXPECT_NEAR(*edge - *a, -32.0, 1.0);
}

TEST_F(ModelParallax, TheModelsPassReportsThatItFollowsTheCursor)
{
    ScenePackage package;
    Build(package, {});
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();

    wallpaper::SceneNode* model = nullptr;
    std::vector<wallpaper::SceneNode*> pending { scene.scene().sceneGraph.get() };
    while (!pending.empty() && model == nullptr) {
        wallpaper::SceneNode* node = pending.back();
        pending.pop_back();
        if (node == nullptr) continue;
        if (node->ID() == 2 && node->Mesh() != nullptr) model = node;
        for (const auto& child : node->GetChildren()) pending.push_back(child.get());
    }
    ASSERT_NE(model, nullptr);
    const uint32_t bits = scene.scene().shaderValueUpdater->FrameVaryingUniforms(model, 0, std::string());
    EXPECT_NE(bits & wallpaper::frame_varying_uniform::kParallax, 0u);
}

TEST_F(ModelParallax, AModelInAScenePassWithStaticReuseRedrawsWhenThePointerMoves)
{
    // The first picture draws everything; with reuse on, a frame that follows a pointer move
    // still opens the model's pass.
    ScenePackage package;
    Build(package, {});
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.SetPointer(0.5, 0.5);
    ASSERT_TRUE(scene.Step(6)) << scene.error();
    scene.SetPointer(1.0, 0.5);
    ASSERT_TRUE(scene.Step(2)) << scene.error();
    EXPECT_GT(scene.LastFramePasses().total(), 0u);
}

TEST_F(ModelParallax, InAThreeDimensionalSceneAModelMovesByItsDistanceFromTheCamera)
{
    // The camera looks at the origin from 100 units away. The model stands at the origin on
    // the camera's axis, so only the pointer moves it: (0.5 - 1.0) * extent * influence * depth
    // * amount, towards the left at the right edge, and the lens shows that move.
    ScenePackage package;
    ModelScene   spec;
    spec.grouped     = false;
    spec.model_depth = "1 1";
    spec.amount      = 0.1f;
    spec.influence   = 0.1f;
    Build(package, spec, { { "fov", 50.0 }, { "nearz", 1.0 }, { "farz", 1000.0 } }, true);
    Json scene_json = Json::parse(std::string("{}"));
    {
        std::ifstream in(package.root() / "scene.json");
        scene_json = Json::parse(in);
    }
    scene_json["camera"] = { { "center", "0 0 0" }, { "eye", "0 0 100" }, { "up", "0 1 0" } };
    scene_json["objects"][0]["origin"] = "0 0 0";
    package.SetScene(scene_json);

    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.SetPointer(0.5, 0.5);
    const Image centred = scene.Run(3);
    scene.SetPointer(1.0, 0.5);
    const Image edge = scene.Run(3);
    KeepPicture("model_parallax_3d_centred", centred);
    KeepPicture("model_parallax_3d_edge", edge);
    const auto a = LitCentre(centred, 72);
    const auto b = LitCentre(edge, 72);
    ASSERT_TRUE(a.has_value() && b.has_value());
    EXPECT_NEAR(*a, kWidth / 2.0, 1.5) << "centred, the model stays on the camera axis";
    EXPECT_LT(*b, *a - 2.0) << "the pointer at the right edge moves it left";
}
