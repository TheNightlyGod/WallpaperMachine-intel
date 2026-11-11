#include "support/gpu_scene.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "MetalRender/MetalRender.hpp"

#include <gtest/gtest.h>
#include <cmath>

namespace {
using namespace we_test;

Json CookieLight(int id, const char* name, double z, const std::string& cookie) {
    return {{"id",id},{"name",name},{"light","lspot"},{"origin",Json::array({128,128,z})},
        {"angles",Json::array({0,std::acos(-1.0)/2,0})},{"scale","1 1 1"},
        {"visible",true},{"color","1 1 1"},{"intensity",.25},{"radius",1000},
        {"exponent",1},{"innercone",5},{"outercone",45},{"usecookie",true},
        {"castshadow",false},{"cookie",cookie}};
}

void CookieReceiver(ScenePackage& package, std::vector<Json> lights, int slots,
                    bool alias_only = false) {
    package.AddShader("cookie_receiver",
        "uniform mat4 g_ModelMatrix;\nuniform mat4 g_ViewProjectionMatrix;\n"
        "attribute vec3 a_Position;\nvarying vec3 v_World;\n"
        "void main(){vec4 world=mul(vec4(a_Position,1.0),g_ModelMatrix);"
        "v_World=world.xyz;gl_Position=mul(world,g_ViewProjectionMatrix);}\n",
        alias_only ?
        "uniform sampler2D g_Texture7; // {\"default\":\"_alias_lightCookie\"}\n"
        "void main(){gl_FragColor=vec4(texSample2D(g_Texture7,vec2(.5,.5)).rgb,1.0);}\n" :
        "varying vec3 v_World;\n"
        "uniform sampler2D g_Texture7; // {\"default\":\"_alias_lightCookie\"}\n"
        "#define COOKIE_SAMPLER g_Texture7\n"
        "vec3 CalculateProjectedCoords(vec3 world,mat4 projection){"
        "vec4 clip=mul(vec4(world,1.0),projection);"
        "return vec3(clip.xy/clip.w*vec2(.5,-.5)+.5,clip.z/clip.w);}\n"
        "vec3 ComputePBRLightShadow(vec3 normal,vec3 delta,vec3 view,vec3 color,"
        "vec3 lightColor,float radius,float exponent,vec3 specular,vec3 reflectance,"
        "float roughness,float metallic,float shadow){return lightColor*shadow;}\n"
        "#require LightingV1\n"
        "void main(){gl_FragColor=vec4(PerformLighting_V1(v_World,vec3(1.0,1.0,1.0),"
        "vec3(0.0,0.0,1.0),vec3(0.0,0.0,1.0),vec3(0.0,0.0,0.0),vec3(0.0,0.0,0.0),1.0,0.0),1.0);}\n");
    package.PutJson("materials/receiver.json",{{"passes",Json::array({{
        {"shader","cookie_receiver"},{"blending","normal"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"},{"combos",{{"LIGHTING",1}}}}})}});
    package.PutJson("models/receiver.json",{{"material","materials/receiver.json"},{"width",256},{"height",256}});
    ImageLayer receiver;receiver.name="receiver";receiver.size={256,256};
    receiver.origin={128,128,0};receiver.model="models/receiver.json";
    lights.insert(lights.begin(),ImageLayerJson(receiver));
    SceneGeneral general;general.canvas_width=general.canvas_height=256;
    general.extra={{"lightconfig",{{"spot",slots},{"spotcookie",slots}}}};
    package.SetProject();package.SetScene(SceneJson(general,lights));
}

TEST(SpotCookieGpu, ProjectedCookieReplacesTheInnerConeWithoutAShadowPass) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    Image halves=Image::Solid(8,8,{0,255,0,255});
    for(int y=0;y<8;++y)for(int x=0;x<4;++x) halves.Set(x,y,{255,0,0,255});
    const auto key=package.AddTexture("halves",halves);
    auto lamp=CookieLight(2,"lamp",128,key);lamp["intensity"]=1;
    CookieReceiver(package,{lamp},1);
    GpuScene scene(package,{.width=256,.height=256});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto picture=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(picture,48,112,16,16,{255,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(picture,192,112,16,16,{0,255,0,255},1));
    EXPECT_FALSE(scene.scene().shadows.active());
    EXPECT_FALSE(scene.scene().HasRenderTarget("_rt_shadowAtlas"));
}

TEST(SpotCookieGpu, PackedBudgetAndVisibilityChooseOneSharedCookie) {
    WE_SKIP_WITHOUT_METAL();
    for(int slots : {1,2}) {
        ScenePackage package;
        auto red=package.AddTexture("red",Image::Solid(4,4,{255,0,0,255}));
        auto blue=package.AddTexture("blue",Image::Solid(4,4,{0,0,255,255}));
        CookieReceiver(package,{CookieLight(2,"red",256,red),CookieLight(3,"blue",128,blue)},slots);
        GpuScene scene(package,{.width=256,.height=256});
        ASSERT_TRUE(scene.ok()) << scene.error();
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,
            slots==1 ? Rgba{64,0,0,255} : Rgba{0,0,128,255},1));
        ASSERT_TRUE(scene.runtime()->SetNodeVisible("blue",false));
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,{64,0,0,255},1));
        ASSERT_TRUE(scene.runtime()->SetNodeVisible("blue",true));
        ASSERT_TRUE(scene.runtime()->SetNodeTranslate("red",{128,128,64}));
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,
            slots==1 ? Rgba{0,0,64,255} : Rgba{128,0,0,255},1));
    }
}

TEST(SpotCookieGpu, ADirectAliasReaderFollowsSelectionWithoutRebuildingItsGraph) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    auto red=package.AddTexture("red",Image::Solid(4,4,{255,0,0,255}));
    auto blue=package.AddTexture("blue",Image::Solid(4,4,{0,0,255,255}));
    CookieReceiver(package,{CookieLight(2,"red",256,red),CookieLight(3,"blue",128,blue)},2,true);
    GpuScene scene(package,{.width=256,.height=256});
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,{0,0,255,255},0));
    const auto rebuilds=scene.RebuildCount();
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("red",{128,128,64}));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,{255,0,0,255},0));
    EXPECT_EQ(scene.RebuildCount(),rebuilds);
    ASSERT_TRUE(scene.runtime()->SetNodeVisible("red",false));
    ASSERT_TRUE(scene.runtime()->SetNodeVisible("blue",false));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,{0,0,0,255},0));
    ASSERT_TRUE(scene.runtime()->SetNodeVisible("red",true));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,{255,0,0,255},0));
}

TEST(SpotCookieGpu, AnOmittedOrEmptyCookieUsesTheBuiltInDefault) {
    WE_SKIP_WITHOUT_METAL();
    for (bool omitted : {false,true}) {
        ScenePackage package;
        package.AddTexture("cookie/flashlight1",Image::Solid(4,4,{0,255,0,255}));
        auto light=CookieLight(2,"lamp",128,"");
        if (omitted) light.erase("cookie");
        CookieReceiver(package,{light},1);
        GpuScene scene(package,{.width=256,.height=256});
        ASSERT_TRUE(scene.ok()) << scene.error();
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,{0,64,0,255},1));
    }
}

TEST(SpotCookieGpu, UnusedCookieLightsAddNoPackingImportsOrIdleDemand) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    const auto key=package.AddTexture("unused_cookie",Image::Solid(64,64,{255,0,0,255}));
    package.AddShader("unlit",
        "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\n"
        "void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix); }\n",
        "uniform sampler2D g_Texture7; // {\"default\":\"_alias_lightCookie\"}\n"
        "void main(){gl_FragColor=vec4(1.0,1.0,1.0,1.0); }\n");
    ImageLayer image;image.origin={128,128,0};image.size={256,256};
    image.model=package.AddImageModel("unlit","util/white",{.blending="normal",.shader="unlit"});
    SceneGeneral general;general.canvas_width=general.canvas_height=256;
    general.extra={{"lightconfig",{{"spot",1},{"spotcookie",1}}}};
    package.SetProject();package.SetScene(SceneJson(general,
        {ImageLayerJson(image),CookieLight(2,"unused",128,key)}));
    GpuScene scene(package,{.width=256,.height=256});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto before=scene.Run(1);
    const auto updates=scene.renderer().LightFeatureUpdatesForTests();
    EXPECT_EQ(scene.renderer().ImportedImageForTests(key),nullptr);
    EXPECT_EQ(scene.renderer().ShaderUpdateDemandReasons(),0u);
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("unused",{128,128,64}));
    EXPECT_TRUE(ExpectSamePicture(before,scene.Run(4)));
    EXPECT_EQ(scene.renderer().LightFeatureUpdatesForTests(),updates);
    EXPECT_EQ(scene.renderer().ImportedImageForTests(key),nullptr);
    EXPECT_EQ(scene.renderer().ShaderUpdateDemandReasons(),0u);
}

TEST(SpotCookieGpu, AProjectionOnlyConsumerFollowsLightMovementWithoutImportingTheCookie) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    const auto cookie=package.AddTexture("unread_cookie",Image::Solid(64,64,{0,255,0,255}));
    CookieReceiver(package,{CookieLight(2,"lamp",128,cookie)},1);
    package.Put("shaders/cookie_receiver.frag",
        "uniform mat4 g_LFeature_ShadowProjection[1];\n"
        "void main(){vec4 p=mul(vec4(128.0,128.0,0.0,1.0),g_LFeature_ShadowProjection[0]);"
        "gl_FragColor=vec4(p.x/p.w*.5+.5,0.0,0.0,1.0); }\n");
    GpuScene scene(package,{.width=256,.height=256});
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,{128,0,0,255},1));
    EXPECT_EQ(scene.renderer().ImportedImageForTests(cookie),nullptr);
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("lamp",{192,128,128}));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),112,112,32,32,{64,0,0,255},1));
    EXPECT_EQ(scene.renderer().ImportedImageForTests(cookie),nullptr);
}
} // namespace
