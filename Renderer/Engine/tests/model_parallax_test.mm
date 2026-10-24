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

// A version 13 model of one square, 40 units to a side, centred on its own origin.
std::string MakeSquareModel(const std::string& material)
{
    std::string bytes;
    const auto  u32 = [&](uint32_t value) { bytes.append(reinterpret_cast<const char*>(&value), 4); };
    const auto  f32 = [&](float value) { bytes.append(reinterpret_cast<const char*>(&value), 4); };
    const auto  u16 = [&](uint16_t value) { bytes.append(reinterpret_cast<const char*>(&value), 2); };
    bytes.append("MDLV0013", 8);
    bytes.push_back('\0');
    u32(0x8); // positions and one set of texture coordinates
    u32(0);
    u32(1);   // one mesh
    bytes.append(material);
    bytes.push_back('\0');
    u32(0);
    u32(4 * 20);
    const float corners[4][5] = { { -20, -20, 0, 0, 1 }, { 20, -20, 0, 1, 1 }, { 20, 20, 0, 1, 0 }, { -20, 20, 0, 0, 0 } };
    for (const auto& corner : corners) {
        for (const float value : corner) f32(value);
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
};

void Build(ScenePackage& package, const ModelScene& spec, Json general_extra = Json::object(), bool three_d = false)
{
    package.InstallStandardAssets();
    package.AddShader("model_red", StandardVertexShader(), kRed);
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
