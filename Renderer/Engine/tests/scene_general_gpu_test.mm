#include "support/gpu_scene.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneMaterial.h"

#include <gtest/gtest.h>

namespace {
using namespace we_test;

void GeneralPostProcess(ScenePackage& package, const std::string& name,
                        const std::string& fragment) {
    package.AddShader(name,
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n"
        "void main(){gl_Position=vec4(a_Position,1.0);v_TexCoord=a_TexCoord;}\n",
        "varying vec2 v_TexCoord;\nuniform sampler2D g_Texture0;\n" + fragment);
    package.PutJson("materials/util/" + name + ".json", {{"passes", Json::array({{
        {"shader", name}, {"blending", "normal"}, {"depthtest", "disabled"},
        {"depthwrite", "disabled"}, {"cullmode", "nocull"},
        {"textures", Json::array({nullptr})}}})}});
}

void MakeGeneralBloomScene(ScenePackage& package) {
    package.InstallStandardAssets();
    GeneralPostProcess(package, "downsample_quarter_bloom",
        "uniform float g_BloomStrength;\nuniform float g_BloomThreshold;\nuniform vec3 g_BloomTint;\n"
        "void main(){vec4 c=texSample2D(g_Texture0,v_TexCoord);"
        "gl_FragColor=vec4(max(c.rgb-CAST3(g_BloomThreshold),vec3(0.0, 0.0, 0.0))*g_BloomStrength*g_BloomTint,1.0);}\n");
    for (const char* name : {"downsample_eighth_blur_v", "blur_h_bloom"})
        GeneralPostProcess(package, name,
            "void main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord);}\n");
    GeneralPostProcess(package, "combine_ldr",
        "uniform sampler2D g_Texture1;\nvoid main(){"
        "gl_FragColor=vec4(texSample2D(g_Texture0,v_TexCoord).rgb+texSample2D(g_Texture1,v_TexCoord).rgb,1.0);}\n");
    GeneralPostProcess(package, "ccsimple",
        "uniform vec4 g_Params;\nvoid main(){vec4 c=texSample2D(g_Texture0,v_TexCoord);"
        "gl_FragColor=vec4(c.rgb*g_Params.x,c.a);}\n");
    const auto texture = package.AddTexture("gray", Image::Solid(1, 1, {64,64,64,255}));
    ImageLayer image;
    image.model = package.AddImageModel("gray", texture, {.blending = "normal"});
    SceneGeneral general;
    general.extra = {{"bloomstrength", 1}, {"bloomthreshold", 0}};
    package.SetProject();
    package.SetScene(SceneJson(general, {ImageLayerJson(image)}));
}

bool SetGeneral(GpuScene& scene, std::string_view name, float value) {
    return scene.runtime()->SetSceneGeneralValue(name, std::span(&value, 1));
}

TEST(SceneGeneralGpu, LazyBloomChangesPixelsAndScalarWritesKeepItsGraph) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    MakeGeneralBloomScene(package);
    GpuScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {64,64,64,255}, 1));
    const auto targets = scene.RenderTargetNames().size();
    ASSERT_TRUE(SetGeneral(scene, "bloom", 1));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {128,128,128,255}, 1));
    EXPECT_EQ(scene.RebuildCount(), 1);
    ASSERT_TRUE(SetGeneral(scene, "bloomstrength", 2));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {192,192,192,255}, 1));
    EXPECT_EQ(scene.RebuildCount(), 1);
    const std::array<float, 3> tint {1,0,0};
    ASSERT_TRUE(scene.runtime()->SetSceneGeneralValue("bloomtint", tint));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {192,64,64,255}, 1));
    EXPECT_EQ(scene.RebuildCount(), 1);
    ASSERT_TRUE(SetGeneral(scene, "bloom", 1));
    ASSERT_TRUE(scene.Step(2)) << scene.error();
    EXPECT_EQ(scene.RebuildCount(), 1);
    ASSERT_TRUE(SetGeneral(scene, "bloom", 0));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {64,64,64,255}, 1));
    EXPECT_EQ(scene.RebuildCount(), 2);
    EXPECT_EQ(scene.RenderTargetNames().size(), targets);
}

TEST(SceneGeneralGpu, LazyBloomPreservesLiveColorCorrectionAndItsOrder) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    MakeGeneralBloomScene(package);
    GpuSceneOptions options;
    options.user_options.color_enabled = true;
    options.user_options.brightness = 25;
    GpuScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {16,16,16,255}, 1));
    const auto correction = scene.scene().color_correction_material;
    ASSERT_NE(correction, nullptr);
    // A live host option update must survive a later script mode change.
    correction->customShader.constValues.at("g_Params")[0] = 0.5f;
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {32,32,32,255}, 1));
    ASSERT_TRUE(SetGeneral(scene, "bloom", 1));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {64,64,64,255}, 1));
    EXPECT_EQ(scene.scene().color_correction_material, correction);
    ASSERT_EQ(scene.scene().post_processes.size(), 2u);
    EXPECT_EQ(scene.scene().post_processes[0]->name, "__bloom");
    EXPECT_EQ(scene.scene().post_processes[1]->name, "__ccsimple");
    ASSERT_TRUE(SetGeneral(scene, "bloom", 0));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1), 40, 40, 120, 60, {32,32,32,255}, 1));
    EXPECT_EQ(scene.scene().color_correction_material, correction);
}
} // namespace
