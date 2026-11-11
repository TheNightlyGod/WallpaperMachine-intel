#include "scenescript_scenes.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneNode.h"

#include <gtest/gtest.h>

namespace {
using namespace we_test;

TEST(ScriptSceneGeneral, AdditionalBloomAndFogMembersKeepTheirNativeTypesAndAuthoredValues) {
    ScenePackage package;
    const auto model = package.AddImageModel("probe");
    const auto source = R"JS(
export function update() {
    ['bloomhdrstrength','bloomhdrthreshold','bloomhdrscatter','bloomhdrfeather','bloomhdriterations',
     'fogdistancestart','fogdistanceend','fogdistancestartdensity','fogdistanceenddensity',
     'fogheightstart','fogheightend','fogheightstartdensity','fogheightenddensity'].forEach(function(k) {
        if (typeof thisScene[k] !== 'number') throw new Error(k+' is not a number');
    });
    ['bloomtint','fogdistancecolor','fogheightcolor'].forEach(function(k) {
        if (!(thisScene[k] instanceof Vec3)) throw new Error(k+' is not Vec3');
    });
    if (thisScene.norecompile !== undefined) throw new Error('norecompile is not a scene member');
    return new Vec3(thisScene.bloomtint.y, thisScene.bloomhdrstrength, thisScene.fogheightend);
}
)JS";
    auto document = SceneJson({}, {PlainImage(model, 1, "probe", {
        {"origin", ScriptedValue(source, "0 0 0")}})});
    document["general"]["bloomtint"] = "0.1 0.3 0.5";
    document["general"]["bloomhdrstrength"] = 4;
    document["general"]["fogheightend"] = -9;
    package.SetProject({{"bloomtint", SliderProperty(99, 0, 100)}});
    package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{0.3f,4,-9}));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptSceneGeneral, FogSettersShareBoundValuesAndUpdatePackedUniformsWithoutRebuilding) {
    ScenePackage package;
    package.AddShader("general_fog_values", StandardVertexShader(), R"(
uniform vec4 g_FogDistanceParams;
uniform vec4 g_FogHeightParams;
uniform vec3 g_FogDistanceColor;
uniform vec3 g_FogHeightColor;
void main() {
    gl_FragColor = g_FogDistanceParams + g_FogHeightParams + vec4(g_FogDistanceColor + g_FogHeightColor, 0.0);
}
)");
    const auto model = package.AddImageModel("probe", "util/white", {.shader="general_fog_values"});
    const auto source = R"JS(
export function update(value) {
    thisScene.fogdistanceend=12;
    thisScene.fogdistancestartdensity=0.2;
    thisScene.fogdistanceenddensity=0.7;
    thisScene.fogdistancecolor=new Vec3(0.1,0.2,0.3);
    thisScene.fogheightstart=4;
    thisScene.fogheightend=-6;
    thisScene.fogheightstartdensity=0.1;
    thisScene.fogheightenddensity=0.9;
    thisScene.fogheightcolor=new Vec3(0.4,0.5,0.6);
    return new Vec3(thisScene.fogdistancestart, thisScene.fogdistanceend, thisScene.fogheightend);
}
)JS";
    auto document = SceneJson({}, {PlainImage(model, 1, "probe", {
        {"origin", ScriptedValue(source, "0 0 0")}})});
    document["general"]["fogdistancestart"] = PropertyBinding("start", 1);
    package.SetProject({{"start", SliderProperty(2, 0, 10)}});
    package.SetScene(document);
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto find = [&](auto&& self, wallpaper::SceneNode* candidate) -> wallpaper::SceneNode* {
        if (candidate->Name() == "probe" && candidate->Mesh()) return candidate;
        for (const auto& child : candidate->GetChildren())
            if (const auto node = self(self, child.get())) return node;
        return nullptr;
    };
    const auto node = find(find, scene.scene().sceneGraph.get());
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto material = node->Mesh()->MaterialSlotPtr(0);
    ASSERT_NE(material, nullptr);
    scene.runtime().ConsumeSceneGraphMutationFlag();
    scene.Tick();
    auto& values = material->customShader.constValues;
    ASSERT_TRUE(values.contains("g_FogDistanceParams"));
    ASSERT_TRUE(values.contains("g_FogHeightParams"));
    EXPECT_FLOAT_EQ(values.at("g_FogDistanceParams")[0], 2);
    EXPECT_FLOAT_EQ(values.at("g_FogDistanceParams")[1], 10);
    EXPECT_FLOAT_EQ(values.at("g_FogDistanceParams")[2], 0.2f);
    EXPECT_FLOAT_EQ(values.at("g_FogDistanceParams")[3], 0.5f);
    EXPECT_FLOAT_EQ(values.at("g_FogHeightParams")[0], 4);
    EXPECT_FLOAT_EQ(values.at("g_FogHeightParams")[1], -10);
    EXPECT_FLOAT_EQ(values.at("g_FogHeightParams")[2], 0.1f);
    EXPECT_NEAR(values.at("g_FogHeightParams")[3], 0.8f, 1e-6f);
    EXPECT_FLOAT_EQ(values.at("g_FogDistanceColor")[2], 0.3f);
    EXPECT_FLOAT_EQ(values.at("g_FogHeightColor")[0], 0.4f);
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
    ASSERT_TRUE(scene.SetProperty("start", 5));
    scene.Tick();
    EXPECT_FLOAT_EQ(values.at("g_FogDistanceParams")[0], 5);
    EXPECT_FLOAT_EQ(values.at("g_FogDistanceParams")[1], 7);
    EXPECT_EQ(scene.Origin("probe"), (std::array<float, 3>{5,12,-6}));
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}
} // namespace
