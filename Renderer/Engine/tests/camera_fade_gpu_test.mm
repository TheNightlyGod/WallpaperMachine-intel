#include "support/gpu_scene.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "MetalRender/MetalRender.hpp"

#include <gtest/gtest.h>

namespace {
using namespace we_test;

void MakeFadeScene(ScenePackage& package, bool enabled, const std::string& scheme,
                   bool correction = false) {
    package.InstallStandardAssets();
    package.AddShader("fade",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position,1.0);}\n",
        "uniform float g_Alpha;\nuniform vec3 color;\nvoid main(){gl_FragColor=vec4(color*0.7,g_Alpha);}\n");
    package.PutJson("materials/util/fade.json", {{"passes",Json::array({{
        {"shader","fade"},{"blending","translucent"},{"depthtest","disabled"},
        {"depthwrite","disabled"},{"cullmode","nocull"}}})}});
    if (correction) {
        package.AddShader("ccsimple",
            "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n"
            "void main(){gl_Position=vec4(a_Position,1.0);v_TexCoord=a_TexCoord;}\n",
            "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
            "void main(){vec4 c=texSample2D(g_Texture0,v_TexCoord);gl_FragColor=vec4(c.rgb*0.5,c.a);}\n");
        package.PutJson("materials/util/ccsimple.json", {{"passes",Json::array({{
            {"shader","ccsimple"},{"blending","normal"},{"depthtest","disabled"},
            {"depthwrite","disabled"},{"cullmode","nocull"},{"textures",Json::array({nullptr})}}})}});
    }
    const auto texture=package.AddTexture("red",Image::Solid(1,1,{255,0,0,255}));
    ImageLayer image;
    image.name="red";
    image.model=package.AddImageModel("red",texture,{.blending="normal"});
    image.origin={0,0,0};
    Json keys = Json::array({{{"timestamp",0},{"eye","0 0 10"},{"center","0 0 0"},{"up","0 1 0"}},
                             {{"timestamp",4},{"eye","0 0 10"},{"center","0 0 0"},{"up","0 1 0"}}});
    package.PutJson("paths.json",{{"paths",Json::array({{{"duration",4},{"transforms",keys}}})}});
    auto document=SceneJson({}, {ImageLayerJson(image)});
    document["general"]["orthogonalprojection"]=nullptr;
    document["general"]["camerafade"]=enabled;
    document["camera"]={{"eye","0 0 10"},{"center","0 0 0"},{"up","0 1 0"},{"paths",Json::array({"paths.json"})}};
    package.SetProject({{"schemecolor",ColorProperty(scheme)}});
    package.SetScene(document);
}

TEST(CameraFadeGpu, FadesAtPathEndsAndUpdatesItsTintWithoutGraphRebuilds) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    MakeFadeScene(package,true,"0 0 0");
    GpuScene scene(package,{.width=128,.height=128,.time_step=0.25});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto half=scene.Run(1);
    ASSERT_FALSE(half.empty());
    EXPECT_TRUE(ExpectRegionAverage(half,40,40,40,40,{128,0,0,255},1.0));
    const auto clear=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(clear,40,40,40,40,{255,0,0,255},1.0));
    ASSERT_TRUE(scene.SetProperty("schemecolor","0 1 0"));
    scene.TickRuntime(3.0);
    const auto end=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(end,40,40,40,40,{128,89,0,255},1.0));
    EXPECT_EQ(scene.RebuildCount(),0);
    scene.runtime()->SetCameraFadeEnabled(false);
    const auto hidden=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(hidden,40,40,40,40,{255,0,0,255},1.0));
}

TEST(CameraFadeGpu, FadeFollowsColorCorrectionAndUsesNoPrivateRenderTarget) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    MakeFadeScene(package,true,"0 1 0",true);
    GpuSceneOptions options;
    options.width=options.height=128;
    options.time_step=0.25;
    options.user_options.color_enabled=true;
    options.user_options.brightness=0.5;
    GpuScene scene(package,options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto picture=scene.Run(1);
    ASSERT_FALSE(picture.empty());
    EXPECT_TRUE(ExpectRegionAverage(picture,40,40,40,40,{64,89,0,255},1.0));
    ScenePackage disabled_package;
    MakeFadeScene(disabled_package,false,"0 1 0",true);
    GpuScene disabled(disabled_package,options);
    ASSERT_TRUE(disabled.ok()) << disabled.error();
    ASSERT_TRUE(disabled.Step());
    EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),
              disabled.renderer().RenderTargetBytesForTests());
}
} // namespace
