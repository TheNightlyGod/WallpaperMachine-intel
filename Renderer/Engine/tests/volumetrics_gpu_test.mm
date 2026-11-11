#include "support/gpu_scene.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include <gtest/gtest.h>
#include <iostream>
#include <fstream>


namespace {
using namespace we_test;
using namespace wallpaper;

// Small independent materials exercise the native volume interface without a private
// shared asset dependency. The integration probe uses Wallpaper Engine's shipped shader.
void VolumeAssets(ScenePackage& p) {
    const std::string vertex =
        "uniform mat4 g_ViewProjectionMatrix;uniform mat4 g_AltViewProjectionMatrix;"
        "attribute vec3 a_Position;varying vec4 v_Clip;void main(){"
        "gl_Position=mul(mul(vec4(a_Position,1.0),g_AltViewProjectionMatrix),g_ViewProjectionMatrix);"
        "\n#if FULLSCREEN\n"
        "gl_Position=vec4(a_Position.xy,0.0,1.0);\n#endif\n"
        "v_Clip=gl_Position;}";
    const std::string fragment =
        "uniform sampler2D g_Texture1;uniform sampler2D g_Texture3;"
        "uniform mat4 g_EffectModelMatrix;uniform vec4 g_RenderVar1;"
        "uniform vec4 g_RenderVar2;uniform vec4 g_RenderVar4;varying vec4 v_Clip;"
        "void main(){vec3 c=v_Clip.xyz/v_Clip.w;vec2 uv=c.xy*vec2(.5,-.5)+.5;"
        "float end=min(texSample2D(g_Texture1,uv)[0],texSample2D(g_Texture3,uv).r);"
        "\n#if REVERSEDEPTH\nif(c.z<end)discard;\n#else\nif(end<c.z)discard;\n#endif\n"
        "vec4 a=mul(vec4(c,1.0),g_EffectModelMatrix);"
        "vec4 b=mul(vec4(c.xy,end,1.0),g_EffectModelMatrix);a/=a.w;b/=b.w;"
        "float f=max(0.0,1.0-length((a.xyz+b.xyz)*.5-g_RenderVar2.xyz)/g_RenderVar1.x);"
        "float power=length(b.xyz-a.xyz)/g_RenderVar1.x*g_RenderVar1.w*g_RenderVar2.w*.1*f;"
        "gl_FragColor=vec4(g_RenderVar4.xyz*power,1.0);}";
    p.AddShader("volume_back_test",vertex,"void main(){gl_FragColor=vec4(0.0,0.0,0.0,0.0);}");
    p.AddShader("volume_front_test",vertex,fragment);
    for (const char* name : {"volumetrics_back","volumetrics_front","volumetrics_fullscreen"}) {
        const bool back=std::string(name)=="volumetrics_back";
        p.PutJson(std::string("materials/util/")+name+".json",{{"passes",Json::array({{
            {"shader",back?"volume_back_test":"volume_front_test"},
            {"textures",Json::array({nullptr,"_rt_volumetricsBack",nullptr,"_rt_volumetricsSingle"})},
            {"depthtest","disabled"},{"depthwrite","disabled"},{"cullmode","normal"},
            {"blending",back?"normal":"additive"}}})}});
    }
    p.AddShader("volume_combine_test",
        "attribute vec3 a_Position;attribute vec2 a_TexCoord;varying vec2 uv;"
        "void main(){gl_Position=vec4(a_Position,1.0);uv=a_TexCoord;}",
        "uniform sampler2D g_Texture0;varying vec2 uv;void main(){gl_FragColor=texSample2D(g_Texture0,uv);}");
    for(const char* name:{"volumetrics_blur_h","volumetrics_blur_v","volumetrics_combine"})
        p.PutJson(std::string("materials/util/")+name+".json",{{"passes",Json::array({{
            {"shader","volume_combine_test"},{"depthtest","disabled"},{"depthwrite","disabled"},
            {"cullmode","nocull"},{"blending",std::string(name)=="volumetrics_combine"?"additive":"normal"}}})}});
}

void VolumeScene(ScenePackage& p, bool casts=true) {
    VolumeAssets(p);
    SceneGeneral general;general.canvas_width=general.canvas_height=128;
    general.extra={{"lightconfig",{{"point",1}}}};
    p.SetProject();p.SetScene(SceneJson(general,{{{"id",2},{"name","bulb"},
        {"light","lpoint"},{"origin","64 64 0"},{"radius",40},{"color","1 0 0"},
        {"intensity",4},{"density",2},{"castvolumetrics",casts},{"visible",true}}}));
}
TEST(VolumetricsGpu, APointLightAddsLightOverAnEmptySceneAndKeepsTheOutsideBlack) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();
    auto picture=s.Run(1);ASSERT_FALSE(picture.empty());
    EXPECT_GT(picture.At(64,64)[0],20);EXPECT_EQ(picture.At(4,4)[0],0);
}
TEST(VolumetricsGpu, DensityEditsReachTheNextPictureWithoutContinuousUniformDemand) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();
    const auto first=s.Run(1);ASSERT_GT(first.At(64,64)[0],20);
    EXPECT_TRUE(ExpectSamePicture(first,s.Run(2)));
    // A shared per-light depth target is intentionally not cached as an
    // independent colour pass. A static beam must not request a continuous
    // frame clock; an explicitly requested frame still executes its geometry.
    EXPECT_EQ(s.renderer().ShaderUpdateDemandReasons(),0u);
    const double zero=0;
    ASSERT_TRUE(s.runtime()->SetNodeLightMember("bulb","density",std::span(&zero,1)));
    EXPECT_EQ(s.Run(1).At(64,64)[0],0);
    const double two=2;
    ASSERT_TRUE(s.runtime()->SetNodeLightMember("bulb","density",std::span(&two,1)));
    EXPECT_TRUE(ExpectSamePicture(first,s.Run(1)));
}
TEST(VolumetricsGpu, QualityAllocatesOnlyTheNativeReductionAndBlurTargets) {
    WE_SKIP_WITHOUT_METAL();
    for(int quality=0;quality<=4;++quality) {
        ScenePackage p;VolumeScene(p);
        GpuSceneOptions options;options.width=options.height=128;
        options.scene_optimization=false;options.quality.volumetrics=quality;
        GpuScene s(p,options);ASSERT_TRUE(s.ok())<<s.error();
        const auto first=s.Run(1);ASSERT_FALSE(first.empty());
        if(quality) {
            const auto* target=s.scene().FindRenderTarget("_rt_volumetricsLightBuffer");
            ASSERT_NE(target,nullptr);EXPECT_EQ(target->width,quality<3?16:32);
            EXPECT_EQ(s.scene().HasRenderTarget("_rt_volumetricsLightBufferB"),quality<3);
            EXPECT_GT(first.At(64,64)[0],20);
        }
        std::cout<<"volume quality="<<quality<<" target_bytes="<<s.renderer().RenderTargetBytesForTests()
                 <<" encoders="<<s.LastFramePasses().render_passes<<"\n";
    }
}
TEST(VolumetricsGpu, AShadowedLightWithNoCasterUsesTheFarDepthSentinel) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p);
    auto doc=Json::parse(std::ifstream(p.root()/"scene.json"));
    doc["objects"][0]["castshadow"]=true;
    doc["general"]["lightconfig"]["pointshadow"]=1;
    p.SetScene(doc);
    const auto shader=p.root()/"shaders/volume_front_test.frag";
    auto fragment=std::string(std::istreambuf_iterator<char>(std::ifstream(shader).rdbuf()),{});
    fragment="#if SHADOW\nuniform sampler2DComparison g_Texture0; // {\"default\":\"_rt_shadowAtlas\"}\n#endif\n"+fragment;
    const auto at=fragment.find("gl_FragColor=vec4(g_RenderVar4.xyz*power,1.0);");
    ASSERT_NE(at,std::string::npos);
    fragment.insert(at,"\n#if SHADOW\npower*=texSample2DCompare(g_Texture0,vec2(0.5,0.5),0.5);\n#endif\n");
    p.Put("shaders/volume_front_test.frag",fragment);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();
    const auto picture=s.Run(1);ASSERT_FALSE(picture.empty())<<s.error();
    EXPECT_GT(picture.At(64,64)[0],20);
    EXPECT_FALSE(s.scene().HasRenderTarget("_rt_shadowAtlas"));
    EXPECT_TRUE(s.scene().HasRenderTarget("_rt_volumetricsShadowFar"));
}
TEST(VolumetricsGpu, AShadowAtlasKeepsTheVolumeUsingTheScenesForwardDepth) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p);
    auto doc=Json::parse(std::ifstream(p.root()/"scene.json"));
    doc["objects"][0]["castshadow"]=true;
    doc["general"]["lightconfig"]["pointshadow"]=1;
    p.AddShader("caster",StandardVertexShader(),"void main(){gl_FragColor=vec4(0,1,0,1);}");
    p.PutJson("materials/caster.json",{{"passes",Json::array({{{"shader","caster"},
        {"blending","normal"},{"cullmode","nocull"},{"depthtest","enabled"},{"depthwrite","enabled"}}})}});
    p.AddShader("shadowcaster",
        "uniform mat4 g_ModelMatrix;\nuniform mat4 g_ViewportViewProjectionMatrices[6];\n"
        "attribute vec3 a_Position;\nvoid main(){gl_Position=mul(mul(vec4(a_Position,1.0),"
        "g_ModelMatrix),g_ViewportViewProjectionMatrices[0]);}","void main(){}");
    p.PutJson("materials/util/shadowcaster.json",{{"passes",Json::array({{{"shader","shadowcaster"},
        {"cullmode","nocull"},{"depthtest","enabled"},{"depthwrite","enabled"}}})}});
    auto host=GroupJson(3,"host",{0,0,0});
    host["origin"]=ScriptedValue(R"JS(
const material=engine.registerAsset('materials/caster.json',true);
export function init(value){
 const model=thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array([
  -4,-4,0,4,-4,0,-4,4,0,-4,4,0,4,-4,0,4,4,0]),vertexFormat:[IModelData.POSITION],material:material}]});
 thisScene.createLayer({model:model,name:'caster',origin:new Vec3(64,64,0),castshadow:true});
 return value;
}
)JS","0 0 0");
    doc["objects"].push_back(host);p.SetScene(doc);
    GpuScene scene(p,{.width=128,.height=128});ASSERT_TRUE(scene.ok())<<scene.error();
    const auto picture=scene.Run(2);ASSERT_FALSE(picture.empty())<<scene.error();
    ASSERT_TRUE(scene.scene().HasRenderTarget("_rt_shadowAtlas"));
    EXPECT_GT(picture.At(52,64)[0],20);
    EXPECT_GT(picture.At(64,64)[1],240);
    std::string caster_key;
    for (const auto& node : scene.scene().sceneGraph->GetChildren())
        if (node->Mesh()) caster_key=node->Name();
    ASSERT_FALSE(caster_key.empty());
    for (bool casts : {false,true,false,true}) {
        ASSERT_TRUE(scene.runtime()->SetModelFlag(caster_key,"castshadow",casts));
        const auto updated=scene.Run(1);ASSERT_FALSE(updated.empty())<<scene.error();
        EXPECT_GT(updated.At(52,64)[0],20);
        EXPECT_EQ(scene.scene().shadows.active(),casts);
    }
}
TEST(VolumetricsGpu, FramedDepthReconstructsTheAuthoredWorldPointAfterZoomAndPan) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p);
    GpuScene s(p,{.width=128,.height=64});ASSERT_TRUE(s.ok())<<s.error();
    auto& scene=s.scene();
    const linalg::Vector4d world(83,42,0,1);
    const auto raw_clip=scene.activeCamera->GetViewProjectionMatrix()*world;
    for (const auto& frame : {std::array<double,4>{1,2,0,0},
                              std::array<double,4>{2,3,.3,-.2},
                              std::array<double,4>{1,2,0,0}}) {
        scene.display_framed=true;scene.display_clip=frame;++scene.display_clip_generation;
        UpdateSceneVolumetrics(scene);
        linalg::Vector4d raster_clip=raw_clip;
        raster_clip.x()=raw_clip.x()*frame[0]+raw_clip.w()*frame[2];
        raster_clip.y()=raw_clip.y()*frame[1]+raw_clip.w()*frame[3];
        auto recovered=scene.volumetric_lights.front().camera_inverse*raster_clip;
        recovered/=recovered.w();
        EXPECT_NEAR(recovered.x(),world.x(),1e-8);
        EXPECT_NEAR(recovered.y(),world.y(),1e-8);
        EXPECT_NEAR(recovered.z(),world.z(),1e-8);
    }
}
TEST(VolumetricsGpu, CameraEnteringAndLeavingTheVolumeSwitchesTheEntrySurface) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeAssets(p);
    SceneGeneral general;general.canvas_width=general.canvas_height=128;
    auto authored=SceneJson(general,{{{"id",2},{"name","bulb"},{"light","lpoint"},
        {"origin","0 0 0"},{"radius",2},{"color","1 0 0"},{"intensity",4},
        {"density",2},{"castvolumetrics",true},{"visible",true}}});
    authored["general"]["orthogonalprojection"]=nullptr;
    authored["general"]["nearz"]=0.1;authored["general"]["farz"]=100;
    authored["camera"]={{"eye","0 0 4"},{"center","0 0 0"},{"up","0 1 0"}};
    p.SetProject();p.SetScene(authored);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();
    ASSERT_TRUE(s.scene().activeCamera->IsPerspective());
    const auto outside=s.Run(1);
    ASSERT_GT(outside.At(64,64)[0],20);
    const auto rebuilds=s.RebuildCount();
    const auto start=s.runtime()->GetStaticCameraTransforms();
    auto inside=start;inside[2]=0;inside[5]=-1;
    ASSERT_TRUE(s.runtime()->SetStaticCameraTransforms(inside,3));
    EXPECT_GT(s.Run(1).At(64,64)[0],20);
    ASSERT_TRUE(s.runtime()->SetStaticCameraTransforms(start,3));
    EXPECT_TRUE(ExpectSamePicture(outside,s.Run(1)));
    EXPECT_EQ(s.RebuildCount(),rebuilds);
}
TEST(VolumetricsGpu, SpotCameraEnteringAndLeavingTheVolumeSwitchesTheEntrySurface) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeAssets(p);
    SceneGeneral general;general.canvas_width=general.canvas_height=128;
    auto authored=SceneJson(general,{{{"id",2},{"name","bulb"},{"light","lspot"},
        {"origin","0 0 2"},{"radius",6},{"angles","0 1.5707963267948966 0"},{"color","1 0 0"},{"intensity",4},
        {"density",2},{"castvolumetrics",true},{"visible",true}}});
    authored["general"]["orthogonalprojection"]=nullptr;
    authored["general"]["nearz"]=0.1;authored["general"]["farz"]=100;
    authored["camera"]={{"eye","0 0 10"},{"center","0 0 0"},{"up","0 1 0"}};
    p.SetProject();p.SetScene(authored);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();
    ASSERT_TRUE(s.scene().activeCamera->IsPerspective());
    const auto outside=s.Run(1);
    EXPECT_GT(outside.At(64,64)[0],20);
    const auto rebuilds=s.RebuildCount();
    const auto start=s.runtime()->GetStaticCameraTransforms();
    auto inside=start;inside[2]=0;inside[5]=-1;
    ASSERT_TRUE(s.runtime()->SetStaticCameraTransforms(inside,3));
    const auto inside_picture=s.Run(1);
    EXPECT_GT(inside_picture.At(64,64)[0],20);
    ASSERT_TRUE(s.runtime()->SetStaticCameraTransforms(start,3));
    EXPECT_TRUE(ExpectSamePicture(outside,s.Run(1)));
    EXPECT_EQ(s.RebuildCount(),rebuilds);
}
TEST(VolumetricsGpu, HidingTheLastDepthWriterRestoresTheBeamWithoutRebuildingTheGraph) {
    WE_SKIP_WITHOUT_METAL();
    for (bool optimize : {false,true}) {
        ScenePackage p;VolumeAssets(p);
        const auto model=p.AddImageModel("occluder","util/white",{.blending="normal",.shader="black"});
        p.AddShader("black",StandardVertexShader(),"void main(){gl_FragColor=vec4(0,0,0,1);}");
        p.PutJson("materials/occluder.json",{{"passes",Json::array({{
            {"shader","black"},{"blending","normal"},{"cullmode","nocull"},
            {"depthtest","enabled"},{"depthwrite","enabled"}}})}});
        ImageLayer card;card.id=1;card.name="occluder";card.model=model;
        card.origin={0,0,2.5};card.size={4,4};
        SceneGeneral general;general.extra={{"orthogonalprojection",nullptr},{"nearz",.1},{"farz",100}};
        auto doc=SceneJson(general,{ImageLayerJson(card),{{"id",2},{"name","bulb"},{"light","lpoint"},
            {"origin","0 0 0"},{"radius",2},{"color","1 0 0"},{"intensity",4},
            {"density",2},{"castvolumetrics",true},{"visible",true}}});
        doc["camera"]={{"eye","0 0 4"},{"center","0 0 0"},{"up","0 1 0"}};
        p.SetProject();p.SetScene(doc);
        GpuSceneOptions options;options.width=options.height=128;options.scene_optimization=optimize;
        GpuScene s(p,options);ASSERT_TRUE(s.ok())<<s.error();
        ASSERT_EQ(s.Run(1).At(64,64)[0],0);
        const auto rebuilds=s.RebuildCount();
        SceneNode* occluder=nullptr;
        for (const auto& child:s.scene().sceneGraph->GetChildren())
            if(child->Name()=="occluder")occluder=child.get();
        ASSERT_NE(occluder,nullptr);
        ASSERT_TRUE(s.runtime()->SetNodeVisible("occluder",false));
        const auto beam=s.Run(1);ASSERT_FALSE(beam.empty());EXPECT_GT(beam.At(64,64)[0],20);
        EXPECT_TRUE(ExpectSamePicture(beam,s.Run(1)));
        ASSERT_TRUE(s.runtime()->SetNodeVisible("occluder",true));EXPECT_EQ(s.Run(1).At(64,64)[0],0);
        EXPECT_EQ(s.RebuildCount(),rebuilds);
    }
}
TEST(VolumetricsGpu, CastActivationAndRemovalReleaseAllFeatureTargets) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p,false);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();
    ASSERT_TRUE(s.Step());const auto baseline=s.renderer().RenderTargetBytesForTests();
    for(int cycle=0;cycle<3;++cycle) {
        const double on=1,off=0;
        ASSERT_TRUE(s.runtime()->SetNodeLightMember("bulb","castvolumetrics",std::span(&on,1)));
        ASSERT_GT(s.Run(1).At(64,64)[0],20);
        ASSERT_TRUE(s.runtime()->SetNodeLightMember("bulb","castvolumetrics",std::span(&off,1)));
        EXPECT_EQ(s.Run(1).At(64,64)[0],0);
        EXPECT_EQ(s.renderer().RenderTargetBytesForTests(),baseline);
        for(const auto& name:s.RenderTargetNames())EXPECT_EQ(name.find("_rt_volumetrics"),std::string::npos);
    }
}
TEST(VolumetricsGpu, LightKindAndVisibilityChangesRebuildOnlyWhenTheTopologyChanges) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();
    const auto original=s.Run(1);ASSERT_GT(original.At(64,64)[0],20);
    const auto original_bytes=s.renderer().RenderTargetBytesForTests();
    const double on=1;
    const auto rebuilds=s.RebuildCount();
    ASSERT_TRUE(s.runtime()->SetNodeLightMember("bulb","castvolumetrics",std::span(&on,1)));
    EXPECT_TRUE(ExpectSamePicture(original,s.Run(1)));
    EXPECT_EQ(s.RebuildCount(),rebuilds);
    ASSERT_TRUE(s.runtime()->SetNodeLightKind("bulb","ltube"));
    EXPECT_EQ(s.Run(1).At(64,64)[0],0);
    for(const auto& name:s.RenderTargetNames())EXPECT_EQ(name.find("_rt_volumetrics"),std::string::npos);
    ASSERT_TRUE(s.runtime()->SetNodeLightKind("bulb","lpoint"));
    EXPECT_TRUE(ExpectSamePicture(original,s.Run(1)));
    EXPECT_EQ(s.renderer().RenderTargetBytesForTests(),original_bytes);
    ASSERT_TRUE(s.runtime()->SetNodeVisible("bulb",false));
    EXPECT_EQ(s.Run(1).At(64,64)[0],0);
    for(const auto& name:s.RenderTargetNames())EXPECT_EQ(name.find("_rt_volumetrics"),std::string::npos);
    ASSERT_TRUE(s.runtime()->SetNodeVisible("bulb",true));
    EXPECT_TRUE(ExpectSamePicture(original,s.Run(1)));
    EXPECT_EQ(s.renderer().RenderTargetBytesForTests(),original_bytes);
}
TEST(VolumetricsGpu, ReparentingIntoAHiddenGroupReleasesTheVolumeUntilItReturns) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p);
    auto doc=Json::parse(std::ifstream(p.root()/"scene.json"));
    doc["objects"].push_back(GroupJson(3,"holder",{0,0,0}));p.SetScene(doc);
    GpuScene scene(p,{.width=128,.height=128});ASSERT_TRUE(scene.ok())<<scene.error();
    const auto original=scene.Run(1);ASSERT_GT(original.At(64,64)[0],20);
    ASSERT_TRUE(scene.runtime()->SetNodeVisible("holder",false));
    ASSERT_TRUE(scene.runtime()->SetNodeParent("bulb","holder"));
    EXPECT_EQ(scene.Run(1).At(64,64)[0],0);
    for (const auto& name : scene.RenderTargetNames())
        EXPECT_EQ(name.find("_rt_volumetrics"),std::string::npos);
    ASSERT_TRUE(scene.runtime()->SetNodeParent("bulb",""));
    EXPECT_TRUE(ExpectSamePicture(original,scene.Run(1)));
}
TEST(VolumetricsGpu, SpotCookieShapeChangesReleaseTheirOldGeometry) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();
    ASSERT_TRUE(s.runtime()->SetNodeLightKind("bulb","lspot"));
    const auto plain=s.Run(1);ASSERT_FALSE(plain.empty());
    const auto plain_bytes=s.renderer().GeometryBufferBytesForTests();
    const auto target_bytes=s.renderer().RenderTargetBytesForTests();
    for(int cycle=0;cycle<3;++cycle) {
        const double on=1,off=0;
        ASSERT_TRUE(s.runtime()->SetNodeLightMember("bulb","usecookie",std::span(&on,1)));
        ASSERT_FALSE(s.Run(1).empty());
        EXPECT_LT(s.renderer().GeometryBufferBytesForTests(),plain_bytes);
        EXPECT_EQ(s.renderer().RenderTargetBytesForTests(),target_bytes);
        ASSERT_TRUE(s.runtime()->SetNodeLightMember("bulb","usecookie",std::span(&off,1)));
        EXPECT_TRUE(ExpectSamePicture(plain,s.Run(1)));
        EXPECT_EQ(s.renderer().GeometryBufferBytesForTests(),plain_bytes);
    }
}
TEST(VolumetricsGpu, AFailedActivationRollsBackTargetsAndNodes) {
    WE_SKIP_WITHOUT_METAL();ScenePackage p;VolumeScene(p,false);
    GpuScene s(p,{.width=128,.height=128});ASSERT_TRUE(s.ok())<<s.error();ASSERT_TRUE(s.Step());
    p.Put("materials/util/volumetrics_front.json","{}");
    const double on=1;
    ASSERT_TRUE(s.runtime()->SetNodeLightMember("bulb","castvolumetrics",std::span(&on,1)));
    EXPECT_FALSE(s.Step());
    EXPECT_TRUE(s.scene().volumetric_lights.empty());
    EXPECT_EQ(s.scene().volumetric_combine,nullptr);
    for(const auto& [name,target]:s.scene().renderTargets)
        EXPECT_EQ(name.find("_rt_volumetrics"),std::string::npos);
}
TEST(VolumetricsGpu, FourKResourceFootprint) {
    WE_SKIP_WITHOUT_METAL();
    for(int quality:{0,2,4}) {
        ScenePackage p;VolumeAssets(p);SceneGeneral general;
        general.canvas_width=3840;general.canvas_height=2160;
        general.extra={{"lightconfig",{{"point",1}}}};
        p.SetProject();p.SetScene(SceneJson(general,{{{"id",2},{"name","bulb"},
            {"light","lpoint"},{"origin","1920 1080 0"},{"radius",700},{"color","1 0 0"},
            {"intensity",4},{"density",2},{"castvolumetrics",true},{"visible",true}}}));
        GpuSceneOptions options;options.width=3840;options.height=2160;
        options.scene_optimization=false;options.quality.volumetrics=quality;
        GpuScene s(p,options);ASSERT_TRUE(s.ok())<<s.error();ASSERT_TRUE(s.Step(2))<<s.error();
        const auto* frame=s.scene().FindRenderTarget("_rt_default");ASSERT_NE(frame,nullptr);
        ASSERT_EQ(frame->width,3840);ASSERT_EQ(frame->height,2160);
        std::cout<<"volume_4k quality="<<quality<<" target_bytes="<<s.renderer().RenderTargetBytesForTests()
                 <<" geometry_bytes="<<s.renderer().GeometryBufferBytesForTests()
                 <<" encoders="<<s.LastFramePasses().render_passes
                 <<" uniform_demand="<<s.renderer().ShaderUpdateDemandReasons()<<"\n";
    }
}
TEST(VolumetricsGpu, FourKDepthResourceFootprintUsesTheExistingResolveEncoder) {
    WE_SKIP_WITHOUT_METAL();
    for (int samples : {0,4}) for (int quality : {0,2}) {
        ScenePackage p;VolumeAssets(p);
        p.AddShader("black_model", "attribute vec3 a_Position;\nuniform mat4 g_ModelViewProjectionMatrix;\n"
            "void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}",
            "void main(){gl_FragColor=vec4(0,0,0,1);}");
        p.PutJson("materials/black_model.json",{{"passes",Json::array({{{"shader","black_model"},
            {"blending","normal"},{"cullmode","nocull"},{"depthtest","enabled"},{"depthwrite","enabled"}}})}});
        auto host=GroupJson(1,"host",{0,0,0});
        host["origin"]=ScriptedValue(R"JS(
const material=engine.registerAsset('materials/black_model.json',true);
export function init(value){
 const model=thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array([
  -1920,-1080,0,1920,-1080,0,-1920,1080,0,-1920,1080,0,1920,-1080,0,1920,1080,0]),
  vertexFormat:[IModelData.POSITION],material:material}]});
 thisScene.createLayer({model:model,name:'depth-writer',origin:new Vec3(1920,1080,-1000),castshadow:false});
 return value;
}
)JS","0 0 0");
        SceneGeneral general;general.canvas_width=3840;general.canvas_height=2160;
        general.extra={{"lightconfig",{{"point",1}}}};
        p.SetProject();p.SetScene(SceneJson(general,{host,{{"id",2},{"name","bulb"},
            {"light","lpoint"},{"origin","1920 1080 0"},{"radius",700},{"color","1 0 0"},
            {"intensity",4},{"density",2},{"castvolumetrics",true},{"visible",true}}}));
        GpuSceneOptions options;options.width=3840;options.height=2160;
        options.scene_optimization=false;options.quality.volumetrics=quality;options.quality.msaa=samples;
        GpuScene scene(p,options);ASSERT_TRUE(scene.ok())<<scene.error();ASSERT_TRUE(scene.Step(2))<<scene.error();
        const auto* frame=scene.scene().FindRenderTarget("_rt_default");ASSERT_NE(frame,nullptr);
        EXPECT_TRUE(frame->withDepth);EXPECT_EQ(frame->sample_count,samples?samples:1);
        EXPECT_EQ(scene.LastFramePasses().blit_passes,0u);
        std::cout<<"volume_4k_depth msaa="<<samples<<" quality="<<quality
                 <<" target_bytes="<<scene.renderer().RenderTargetBytesForTests()
                 <<" geometry_bytes="<<scene.renderer().GeometryBufferBytesForTests()
                 <<" encoders="<<scene.LastFramePasses().render_passes<<"\n";
    }
}
TEST(VolumetricsGpu, OffAndNonCastingLightsAllocateNoVolumeTargets) {
    WE_SKIP_WITHOUT_METAL();
    for(bool casts:{false,true}) {
        ScenePackage p;VolumeScene(p,casts);GpuSceneOptions options;options.width=options.height=128;
        if(casts)options.quality.volumetrics=0;
        GpuScene s(p,options);ASSERT_TRUE(s.ok())<<s.error();
        EXPECT_TRUE(ExpectRegionAverage(s.Run(1),0,0,128,128,{0,0,0,255},0));
        for(const auto& name:s.RenderTargetNames())EXPECT_EQ(name.find("_rt_volumetrics"),std::string::npos);
    }
}
}

namespace {
TEST(VolumetricsGpu, ADepthDisabledOverlayClearsThePriorDepthStateInTheSharedSceneEncoder) {
    WE_SKIP_WITHOUT_METAL();
    for (const bool hdr : {false, true}) {
        SCOPED_TRACE(::testing::Message() << "hdr=" << hdr);
        ScenePackage package;
        VolumeAssets(package);
        package.AddShader("depth_switch_black", StandardVertexShader(),
            "void main(){gl_FragColor=vec4(0.0,0.0,0.0,1.0);}");
        package.AddShader("depth_switch_blue", StandardVertexShader(),
            "void main(){gl_FragColor=vec4(0.0,0.0,1.0,1.0);}");
        ImageLayer occluder;
        occluder.id = 1;
        occluder.name = "depth-switch-occluder";
        occluder.origin = {0, 0, 2.5};
        occluder.size = {4, 4};
        occluder.model = package.AddImageModel("depth_switch_occluder", "util/white",
            {.blending = "normal", .shader = "depth_switch_black"});
        package.PutJson("materials/depth_switch_occluder.json", {{"passes", Json::array({{
            {"shader", "depth_switch_black"}, {"blending", "normal"}, {"cullmode", "nocull"},
            {"depthtest", "enabled"}, {"depthwrite", "enabled"}}})}});
        ImageLayer overlay;
        overlay.id = 2;
        overlay.name = "depth-switch-overlay";
        overlay.origin = {0, 0, -2};
        overlay.size = {20, 20};
        overlay.model = package.AddImageModel("depth_switch_overlay", "util/white",
            {.blending = "normal", .shader = "depth_switch_blue"});
        if (hdr) {
            package.AddShader("depth_switch_hdr",
                "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 uv;\n"
                "void main(){gl_Position=vec4(a_Position,1.0);uv=a_TexCoord;}",
                "uniform sampler2D g_Texture0;\nvarying vec2 uv;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,uv);}");
            for (const char* utility : {"combine_srgb", "hdr_downsample_bloom", "hdr_downsample",
                                       "hdr_upsample", "hdr_upsample_cubic", "combine_hdr_upsample",
                                       "combine_hdr_upsample_linear"}) {
                package.PutJson(std::string("materials/util/") + utility + ".json", {{"passes", Json::array({{
                    {"shader", "depth_switch_hdr"}, {"blending", "normal"}, {"cullmode", "nocull"},
                    {"depthtest", "disabled"}, {"depthwrite", "disabled"},
                    {"textures", Json::array({nullptr, nullptr})}}})}});
            }
        }
        SceneGeneral general;
        general.extra = {{"orthogonalprojection", nullptr}, {"nearz", 0.1}, {"farz", 100},
            {"hdr", hdr}, {"bloom", hdr}, {"bloomhdriterations", 1}, {"bloomhdrstrength", 0},
            {"transparentsorting", false}, {"lightconfig", {{"point", 1}}}};
        auto scene_json = SceneJson(general, {ImageLayerJson(occluder), ImageLayerJson(overlay), {
            {"id", 3}, {"name", "depth-switch-bulb"}, {"light", "lpoint"}, {"origin", "0 0 0"},
            {"radius", 2}, {"color", "1 0 0"}, {"intensity", 4}, {"density", 2},
            {"castvolumetrics", true}, {"visible", true}}});
        scene_json["camera"] = {{"eye", "0 0 4"}, {"center", "0 0 0"}, {"up", "0 1 0"}};
        package.SetProject();
        package.SetScene(scene_json);
        GpuSceneOptions options;
        options.width = options.height = 128;
        options.quality.msaa = 4;
        options.quality.reflection = false;
        options.quality.post_processing = static_cast<int>(PostProcessing::Ultra);
        GpuScene scene(package, options);
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto picture = scene.Run(1);
        ASSERT_FALSE(picture.empty()) << scene.error();
        EXPECT_GT(picture.At(64, 64)[2], 240);
        we_test::Image depth;
        std::vector<float> values;
        ASSERT_TRUE(scene.ReadRenderTarget("_rt_volumetricsBack", &depth, &values));
        ASSERT_FALSE(values.empty());
        // The overlay is farther away and must neither inherit the occluder's
        // test (which rejects blue) nor overwrite the occluder's depth.
        const auto centre_depth = values[(64 * depth.width + 64) * 4];
        EXPECT_GT(centre_depth, 0.9f);
        EXPECT_LT(centre_depth, 0.95f);
    }
}
} // namespace

namespace {

void CombinedLightingAssets(ScenePackage& package, Json& scene) {
    package.AddShader("combined_reflection_request",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy+vec2(4.0,4.0),0.0,1.0);}",
        "uniform sampler2D g_Texture0;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,vec2(0.5,0.5));}");
    package.PutJson("materials/combined_reflection_request.json", {{"passes", Json::array({{
        {"shader", "combined_reflection_request"}, {"blending", "normal"},
        {"cullmode", "nocull"}, {"depthtest", "disabled"}, {"depthwrite", "disabled"},
        {"textures", Json::array({"_rt_Reflection"})}}})}});
    auto host = GroupJson(99, "combined-reflection-request-host", {0, 0, 0});
    host["origin"] = ScriptedValue(R"JS(
const material=engine.registerAsset('materials/combined_reflection_request.json',true);
export function init(value) {
    const model=thisScene.createModelData({shapes:[{
        vertexBuffer:new Float32Array([0,0,0,1,0,0,0,1,0]),
        vertexFormat:[IModelData.POSITION],material:material}]});
    thisScene.createLayer({model:model,name:'combined-reflection-request',castshadow:false,reflected:false});
    return value;
}
)JS", "0 0 0");
    scene["objects"].push_back(host);

    package.AddShader("combined_hdr_output",
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 uv;\n"
        "void main(){gl_Position=vec4(a_Position,1.0);uv=a_TexCoord;}",
        "uniform sampler2D g_Texture0;\nvarying vec2 uv;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,uv);}");
    for (const char* utility : {"combine_srgb", "hdr_downsample_bloom", "hdr_downsample",
                               "hdr_upsample", "hdr_upsample_cubic", "combine_hdr_upsample",
                               "combine_hdr_upsample_linear"}) {
        package.PutJson(std::string("materials/util/") + utility + ".json", {{"passes", Json::array({{
            {"shader", "combined_hdr_output"}, {"blending", "normal"}, {"cullmode", "nocull"},
            {"depthtest", "disabled"}, {"depthwrite", "disabled"},
            {"textures", Json::array({nullptr, nullptr})}}})}});
    }
}

TEST(VolumetricsGpu, ReflectionKeepsMainDepthAndVolumeLightThroughHdrFramingAndVisibilityChanges) {
    WE_SKIP_WITHOUT_METAL();
    struct RestoreResolution {
        SceneResolution value {CurrentSceneResolution()};
        ~RestoreResolution() { SetSceneResolution(value); }
    } restore;
    SetSceneResolution(SceneResolution::Display);

    ScenePackage package;
    VolumeAssets(package);
    package.AddShader("combined_occluder", StandardVertexShader(),
        "void main(){gl_FragColor=vec4(0.0,0.25,0.75,1.0);}");
    ImageLayer occluder;
    occluder.id = 1;
    occluder.name = "combined-occluder";
    occluder.origin = {8, 8.6, 2.5};
    occluder.size = {2, 1};
    occluder.model = package.AddImageModel("combined_occluder", "util/white",
        {.blending = "normal", .shader = "combined_occluder"});
    package.PutJson("materials/combined_occluder.json", {{"passes", Json::array({{
        {"shader", "combined_occluder"}, {"blending", "normal"}, {"cullmode", "nocull"},
        {"depthtest", "enabled"}, {"depthwrite", "enabled"}}})}});
    SceneGeneral general;
    general.canvas_width = general.canvas_height = 16;
    general.extra = {{"orthogonalprojection", {{"width", 16}, {"height", 16}}}, {"nearz", 0.1}, {"farz", 100},
        {"hdr", true}, {"bloom", true}, {"bloomhdriterations", 1}, {"bloomhdrstrength", 0},
        {"transparentsorting", false}, {"lightconfig", {{"point", 1}}}};
    auto document = SceneJson(general, {ImageLayerJson(occluder), {
        {"id", 2}, {"name", "combined-bulb"}, {"light", "lpoint"}, {"origin", "8 8 0"},
        {"radius", 2}, {"color", "1 0 0"}, {"intensity", 4}, {"density", 2},
        {"castvolumetrics", true}, {"visible", true}}});
    document["camera"] = {{"eye", "0 1 4"}, {"center", "0 0 0"}, {"up", "0 1 0"}};
    ImageLayer reflected_source = occluder;
    reflected_source.id = 3;
    reflected_source.name = "combined-reflected-source";
    reflected_source.origin = {8, -8.6, 3};
    document["objects"].push_back(ImageLayerJson(reflected_source));
    CombinedLightingAssets(package, document);
    package.SetProject();
    package.SetScene(document);

    struct Snapshot { we_test::Image beam; we_test::Image depth; std::vector<float> depth_values; };
    std::vector<Snapshot> baseline;
    // Scene quality is applied by reloading in the host. The third load verifies
    // that returning to the disabled quality recovers the same pictures.
    for (const bool reflection : {false, true, false}) {
        SCOPED_TRACE(::testing::Message() << "reflection=" << reflection);
        GpuSceneOptions options;
        options.width = 320;
        options.height = 180;
        options.quality.msaa = 4;
        options.quality.volumetrics = 4;
        options.quality.reflection = reflection;
        options.quality.post_processing = static_cast<int>(PostProcessing::Ultra);
        GpuScene scene(package, options);
        ASSERT_TRUE(scene.ok()) << scene.error();
        scene.renderer().SetWallpaperScalingMode(WallpaperScalingMode::FILL);
        std::vector<Snapshot> current;
        for (int state = 0; state < 4; ++state) {
            SCOPED_TRACE(::testing::Message() << "state=" << state);
            const bool reframed = state == 1 || state == 2;
            scene.renderer().SetWallpaperScalingFactor(reframed ? 1.35 : 1.0);
            scene.renderer().SetWallpaperFraming({reframed ? 0.35 : 0.5, reframed ? 0.65 : 0.5});
            ASSERT_TRUE(scene.runtime()->SetNodeVisible("combined-occluder", state != 2));
            ASSERT_TRUE(scene.Step(2)) << scene.error();
            ASSERT_TRUE(scene.scene().display_framed);
            Snapshot sample;
            sample.beam = scene.RenderTarget("_rt_volumetricsLightBuffer");
            ASSERT_FALSE(sample.beam.empty());
            ASSERT_TRUE(scene.ReadRenderTarget("_rt_volumetricsBack", &sample.depth, &sample.depth_values));
            ASSERT_FALSE(sample.depth_values.empty());
            const auto lowest_depth = *std::min_element(sample.depth_values.begin(), sample.depth_values.end());
            if (state == 2) EXPECT_FLOAT_EQ(lowest_depth, 1.0f);
            else EXPECT_LT(lowest_depth, 0.999f);
            if (state == 0 && reflection) {
                const auto reflected = scene.RenderTarget("_rt_Reflection");
                ASSERT_FALSE(reflected.empty());
                std::size_t coloured = 0;
                for (std::size_t i = 0; i < reflected.rgba.size(); i += 4)
                    coloured += reflected.rgba[i + 2] > 16;
                EXPECT_GT(coloured, 0u) << "The reflection control must draw a source.";
            }
            current.push_back(std::move(sample));
        }
        ASSERT_EQ(current.size(), 4u);
        EXPECT_GT(CountDifferingPixels(current[0].depth, current[1].depth), 0u);
        EXPECT_GT(CountDifferingPixels(current[1].beam, current[2].beam), 0u);
        EXPECT_TRUE(ExpectSamePicture(current[0].beam, current[3].beam));
        EXPECT_TRUE(ExpectSamePicture(current[0].depth, current[3].depth));
        if (baseline.empty()) baseline = current;
        else for (std::size_t state = 0; state < baseline.size(); ++state) {
            SCOPED_TRACE(::testing::Message() << "comparison state=" << state);
            EXPECT_TRUE(ExpectSamePicture(current[state].beam, baseline[state].beam, 1));
            ASSERT_EQ(current[state].depth_values.size(), baseline[state].depth_values.size());
            float difference = 0;
            for (std::size_t i = 0; i < current[state].depth_values.size(); ++i)
                difference = std::max(difference, std::abs(current[state].depth_values[i] - baseline[state].depth_values[i]));
            EXPECT_LE(difference, 1e-6f);
        }
    }
}
} // namespace
