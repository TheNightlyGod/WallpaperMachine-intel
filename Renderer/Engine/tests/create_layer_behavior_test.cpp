// A script that copies a hidden template layer with `createLayer`: the copies join the scene
// graph, and every shader-constant binding of the template is repeated for them.
//
// The scene and runtime are built by hand: a package cannot declare a bound constant on a
// template's material.

#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/include/Scene/SceneMesh.h"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace wallpaper
{
namespace
{

constexpr double kFrame = 1.0 / 60.0;
using Vec3 = linalg::Vector3f;

// A scene with one hidden-template layer `source`, its runtime and the pieces they point at.
struct TemplateScene {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> rt;
    std::shared_ptr<SceneNode>           source;
    std::shared_ptr<SceneMaterial>       sourceMaterial;

    explicit TemplateScene(ProjectProperties properties = {})
        : rt(CreateSceneRuntimeContext(SceneRuntimeBootstrap { .canvas_width = 1920,
                                                               .canvas_height = 1080,
                                                               .project_properties = std::move(properties) }))
    {
        rt->AttachScene(&scene);
        source = std::make_shared<SceneNode>(Vec3(100, 50, 0), Vec3(1, 1, 1), Vec3(0, 0, 0), "source");
        auto mesh = std::make_shared<SceneMesh>();
        mesh->AddMaterial(SceneMaterial {});
        source->AddMesh(mesh);
        sourceMaterial = mesh->MaterialSlotPtr(0);
        scene.sceneGraph->AppendChild(source);
        rt->RegisterNode("source", source.get());
        rt->RegisterLayerTemplate("models/workshop/1234567/bar.json", source, { 20.0f, 10.0f });
    }

    // The bound constant: three components, 0.25 0.5 0.75.
    void BindTint()
    {
        rt->RegisterMaterialConstant(sourceMaterial, "g_Tint",
                                     std::make_unique<DynamicValue>(Vec3(0.25f, 0.5f, 0.75f)));
    }

    // The graph children that are not layers the fixture made itself.
    std::vector<std::shared_ptr<SceneNode>> Clones() const
    {
        std::vector<std::shared_ptr<SceneNode>> clones;
        for (const auto& child : scene.sceneGraph->GetChildren()) {
            if (child->Name() != "source" && child->Name() != "visualizer") clones.push_back(child);
        }
        return clones;
    }
};

void ExpectTint(const SceneMaterial* material)
{
    ASSERT_NE(material, nullptr);
    const auto found = material->customShader.constValues.find("g_Tint");
    ASSERT_NE(found, material->customShader.constValues.end());
    ASSERT_EQ(found->second.size(), 3u);
    EXPECT_FLOAT_EQ(found->second[0], 0.25f);
    EXPECT_FLOAT_EQ(found->second[1], 0.5f);
    EXPECT_FLOAT_EQ(found->second[2], 0.75f);
}

// ---- a scene script copies the template -------------------------------------------------------

constexpr const char* kTwoCopies = R"js(
    function update() {
        var first = thisScene.createLayer('models/bar.json');
        var second = thisScene.createLayer('models/bar.json');
        first.origin = new Vec3(10, 20, 0);
        second.origin = new Vec3(30, 40, 0);
    }
)js";

TEST(CreateLayerFromScripts, ASceneScriptsCopiesCarryEveryBoundConstant)
{
    TemplateScene f;
    f.BindTint();
    ExpectTint(f.sourceMaterial.get());
    f.rt->RegisterSceneScript(kTwoCopies, "source");
    f.rt->ConsumeSceneGraphMutationFlag();

    f.rt->Tick(kFrame);
    EXPECT_EQ(f.scene.sceneGraph->GetChildren().size(), 3u) << "the template and two copies";
    EXPECT_TRUE(f.rt->ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(f.rt->scriptErrorCount(), 0u);

    const auto clones = f.Clones();
    ASSERT_EQ(clones.size(), 2u);
    for (const auto& clone : clones) {
        ASSERT_NE(clone->Mesh(), nullptr);
        ASSERT_NE(clone->Mesh()->Material(), nullptr);
        ExpectTint(clone->Mesh()->Material());
    }
    // Each copy owns its mesh and material.
    EXPECT_NE(clones[0]->Mesh(), clones[1]->Mesh());
    EXPECT_NE(clones[0]->Mesh(), f.source->Mesh());
    EXPECT_NE(clones[0]->Mesh()->Material(), clones[1]->Mesh()->Material());
    EXPECT_NE(clones[0]->Mesh()->Material(), f.sourceMaterial.get());
    EXPECT_NE(clones[1]->Mesh()->Material(), f.sourceMaterial.get());

    // The origins the script wrote were applied to the copies.
    std::vector<std::pair<float, float>> origins;
    for (const auto& clone : clones) origins.emplace_back(clone->Translate()[0], clone->Translate()[1]);
    std::sort(origins.begin(), origins.end());
    EXPECT_NEAR(origins[0].first, 10.0f, 1e-4f);
    EXPECT_NEAR(origins[0].second, 20.0f, 1e-4f);
    EXPECT_NEAR(origins[1].first, 30.0f, 1e-4f);
    EXPECT_NEAR(origins[1].second, 40.0f, 1e-4f);
}

TEST(CreateLayerFromScripts, DirectCopiesGetDistinctNamesAndUnknownTemplatesAddNothing)
{
    TemplateScene f;
    f.BindTint();

    const std::string first = f.rt->CreateLayerFromTemplate("models/bar.json", "source");
    const std::string second = f.rt->CreateLayerFromTemplate("models/bar.json", "source");
    ASSERT_FALSE(first.empty());
    ASSERT_FALSE(second.empty());
    EXPECT_NE(first, second);
    EXPECT_TRUE(f.rt->HasNodeNamed(first));
    EXPECT_TRUE(f.rt->HasNodeNamed(second));
    EXPECT_EQ(f.scene.sceneGraph->GetChildren().size(), 3u);

    EXPECT_TRUE(f.rt->CreateLayerFromTemplate("models/nothing.json", "source").empty());
    EXPECT_TRUE(f.rt->CreateLayerFromTemplate("models/nothing.json", "").empty());
    EXPECT_EQ(f.scene.sceneGraph->GetChildren().size(), 3u);
}

// ---- a property script copies the template ----------------------------------------------------

constexpr const char* kBarFactory = R"js(
    export var scriptProperties = createScriptProperties()
        .addSlider({ name: 'count', value: 4 })
        .finish();
    export function update(value) {
        for (var i = 0; i < scriptProperties.count; i++) {
            var bar = thisScene.createLayer('models/bar.json');
            bar.angles = new Vec3(0, 0, i * 90);
        }
        return value;
    }
)js";

// Adds the `visualizer` layer whose visibility script makes the bars. The tint is bound at the
// point `bindTint` names: before the script is resolved, or after.
struct VisualizerScene : TemplateScene {
    explicit VisualizerScene(float barCount, bool bindBefore = false)
        : TemplateScene({ { "bar_count", RuntimeScalarValue::Float(barCount) },
                          { "visualizer_visible", RuntimeScalarValue::Bool(true) } })
    {
        if (bindBefore) BindTint();
        visualizer = std::make_shared<SceneNode>(Vec3(0, 0, 0), Vec3(1, 1, 1), Vec3(0, 0, 0), "visualizer");
        scene.sceneGraph->AppendChild(visualizer);
        rt->RegisterNode("visualizer", visualizer.get());
        rt->RegisterLayerTemplate("models/workshop/1234567/visualizer.json", visualizer, { 200.0f, 200.0f });

        const nlohmann::json setting = {
            { "script", kBarFactory },
            { "scriptproperties", { { "count", { { "user", "bar_count" }, { "value", 4 } } } } },
            { "user", "visualizer_visible" },
            { "value", true },
        };
        rt->RegisterNodeVisibility("visualizer", visualizer.get(),
                                   ResolveBoolSetting(*rt, setting, "visualizer"));
        childrenAfterRegistration = scene.sceneGraph->GetChildren().size();
        if (!bindBefore) BindTint();
    }

    std::shared_ptr<SceneNode> visualizer;
    std::size_t                childrenAfterRegistration { 0 };
};

TEST(CreateLayerFromScripts, APropertyScriptStartsOnTheFirstTickWithTheBindingsInPlace)
{
    VisualizerScene f(4.0f);
    EXPECT_EQ(f.childrenAfterRegistration, 2u) << "registering the script ran nothing";

    f.rt->Tick(kFrame);
    EXPECT_EQ(f.scene.sceneGraph->GetChildren().size(), 6u) << "two authored layers and four copies";
    const auto clones = f.Clones();
    ASSERT_EQ(clones.size(), 4u);
    for (const auto& clone : clones) {
        ASSERT_NE(clone->Mesh(), nullptr);
        ExpectTint(clone->Mesh()->Material());
    }
    EXPECT_EQ(f.rt->scriptErrorCount(), 0u);
}

TEST(CreateLayerFromScripts, TheNumberOfCopiesComesFromTheBoundUserProperty)
{
    VisualizerScene f(2.0f);
    f.rt->Tick(kFrame);
    EXPECT_EQ(f.scene.sceneGraph->GetChildren().size(), 4u);
    const auto clones = f.Clones();
    ASSERT_EQ(clones.size(), 2u);
    for (const auto& clone : clones) ExpectTint(clone->Mesh()->Material());
    EXPECT_EQ(f.rt->scriptErrorCount(), 0u);
}

TEST(CreateLayerFromScripts, ABindingMadeBeforeTheScriptIsResolvedReachesTheCopiesToo)
{
    VisualizerScene f(4.0f, /*bindBefore=*/true);
    EXPECT_EQ(f.childrenAfterRegistration, 2u);
    f.rt->Tick(kFrame);
    EXPECT_EQ(f.scene.sceneGraph->GetChildren().size(), 6u);
    for (const auto& clone : f.Clones()) ExpectTint(clone->Mesh()->Material());
    EXPECT_EQ(f.rt->scriptErrorCount(), 0u);
}

} // namespace
} // namespace wallpaper
