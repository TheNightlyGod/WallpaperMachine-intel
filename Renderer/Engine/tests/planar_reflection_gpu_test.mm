#include "support/gpu_scene.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "MetalRender/MetalRender.hpp"
#include <gtest/gtest.h>
#include <iostream>

namespace {
using namespace we_test;
struct Bounds { int left=10000, top=10000, right=-1, bottom=-1; std::size_t count=0; };
Bounds ColourBounds(const Image& picture, Rgba colour) {
    Bounds bounds;
    for (uint32_t y=0;y<picture.height;++y) for(uint32_t x=0;x<picture.width;++x) {
        if (picture.At(x,y)!=colour) continue;
        bounds.left=std::min(bounds.left,static_cast<int>(x));
        bounds.right=std::max(bounds.right,static_cast<int>(x));
        bounds.top=std::min(bounds.top,static_cast<int>(y));
        bounds.bottom=std::max(bounds.bottom,static_cast<int>(y));
        ++bounds.count;
    }
    return bounds;
}
void AddReflectionRequest(ScenePackage& package, Json& scene, bool requested=true) {
    package.AddShader("reflection_request",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy+vec2(4.0,4.0),0.0,1.0);}",
        "uniform sampler2D g_Texture0;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,vec2(0.5,0.5));}");
    package.PutJson("materials/reflection_request.json",{{"passes",Json::array({{
        {"shader","reflection_request"},{"blending","normal"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"},
        {"textures",Json::array({requested?"_rt_Reflection":"util/white"})}}})}});
    auto host=GroupJson(99,"reflection-request-host",{0,0,0});
    host["origin"]=ScriptedValue(R"JS(
const material=engine.registerAsset('materials/reflection_request.json',true);
export function init(value) {
    const model=thisScene.createModelData({shapes:[{
        vertexBuffer:new Float32Array([0,0,0,1,0,0,0,1,0]),
        vertexFormat:[IModelData.POSITION],material:material}]});
    thisScene.createLayer({model:model,name:'reflection-request',castshadow:false,reflected:false});
    return value;
}
)JS","0 0 0");
    scene["objects"].push_back(host);
}
void MakeReflectionScene(ScenePackage& package, bool reflection=true, bool hdr_canvas=false) {
    package.AddShader("reflection_source",
        "attribute vec3 a_Position;uniform mat4 g_ModelViewProjectionMatrix;void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}",
        "uniform vec4 g_Color4;void main(){gl_FragColor=g_Color4;}");
    package.AddShader("reflection_view",
        "attribute vec3 a_Position;attribute vec2 a_TexCoord;varying vec2 v_TexCoord;void main(){gl_Position=vec4(a_Position.xy/100.0,0.0,1.0);v_TexCoord=a_TexCoord;}",
        "uniform sampler2D g_Texture0;varying vec2 v_TexCoord;void main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord);}");
    ImageLayer above;above.id=1;above.name="above";above.size={2,2};above.origin={-2,2,0};above.color="1 0 0";
    above.model=package.AddImageModel("reflection_source","util/white",{.blending="normal",.shader="reflection_source"});
    ImageLayer below=above;below.id=2;below.name="below";below.origin={2,-2,0};below.color="1 1 0";
    ImageLayer observer;observer.id=3;observer.name="observer";observer.size={200,200};
    observer.model=package.AddImageModel("reflection_view",reflection?"_rt_Reflection":"util/white",{.blending="normal",.shader="reflection_view"});
    observer.extra={{"reflected",false}};
    SceneGeneral general;general.clear_color={0.125f,0.25f,0.375f};general.extra={{"orthogonalprojection",nullptr},{"fov",90},{"nearz",0.1},{"farz",1000},{"transparentsorting",false}};
    auto json=SceneJson(general,{ImageLayerJson(above),ImageLayerJson(below),ImageLayerJson(observer)});
    json["camera"]={{"eye","0 3 10"},{"center","0 0 0"},{"up","0 1 0"}};
    if(hdr_canvas) {
        json["general"]["hdr"]=true;
        json["general"]["bloom"]=true;
        json["general"]["bloomhdriterations"]=1;
        json["general"]["bloomhdrstrength"]=0;
        json["general"]["orthogonalprojection"]={{"width",16},{"height",16}};
        json["camera"]={{"eye","8 8 10"},{"center","8 8 0"},{"up","0 1 0"}};
        json["objects"][0]["origin"]="8 -8 0";
        json["objects"][1]["origin"]="12 -4 0";
        package.AddShader("reflection_hdr_output",
            "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\nvoid main(){gl_Position=vec4(a_Position,1.0);v_TexCoord=a_TexCoord;}",
            "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord);}");
        for (const char* utility : {"combine_srgb","hdr_downsample_bloom","hdr_downsample",
                                    "hdr_upsample","hdr_upsample_cubic","combine_hdr_upsample",
                                    "combine_hdr_upsample_linear"})
            package.PutJson(std::string("materials/util/")+utility+".json",{{"passes",Json::array({{
                {"shader","reflection_hdr_output"},{"blending","normal"},{"cullmode","nocull"},
                {"depthtest","disabled"},{"depthwrite","disabled"},{"textures",Json::array({nullptr,nullptr})}}})}});
    }
    AddReflectionRequest(package,json,reflection);
    package.SetProject();package.SetScene(json);
}
TEST(PlanarReflectionGpu, WorldPlaneReflectsBothSidesAndUnchangedFramesIdle) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeReflectionScene(package);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok())<<scene.error();
    auto picture=scene.Run(1);
    ASSERT_FALSE(picture.empty());
    std::cout<<"REFLECTION_COST bytes="<<scene.renderer().RenderTargetBytesForTests()
        <<" render="<<scene.LastFramePasses().render_passes<<" blit="<<scene.LastFramePasses().blit_passes<<'\n';
    const auto red=ColourBounds(picture,{255,0,0,255});
    const auto yellow=ColourBounds(picture,{255,255,0,255});
    EXPECT_GT(red.count,30u);EXPECT_LT(red.right,64);EXPECT_LT(red.bottom,64);
    EXPECT_GT(yellow.count,30u);EXPECT_GT(yellow.left,64);EXPECT_GT(yellow.top,64);
    EXPECT_GT(yellow.bottom-yellow.top,red.bottom-red.top);
    EXPECT_TRUE(ExpectRegionAverage(picture,20,20,8,8,{32,64,96,255},1));
    EXPECT_FALSE(scene.RenderTarget("_rt_Reflection").empty());
    ASSERT_TRUE(scene.Step(2));
    EXPECT_EQ(scene.LastFramePasses().total(),0u);
}
TEST(PlanarReflectionGpu, CameraAndSourceChangesRefreshTheReflectedPictureWithoutRebuilding) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeReflectionScene(package);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok())<<scene.error();
    const auto first=scene.Run(1);
    const auto rebuilds=scene.RebuildCount();
        const auto bytes=scene.renderer().RenderTargetBytesForTests();
    const auto geometry=scene.renderer().GeometryBufferBytesForTests();
    const auto programs=wallpaper::metal::MetalRender::ProgramCompilesForTests();
    auto camera=scene.runtime()->GetStaticCameraTransforms();
    camera[0]=3;camera[1]=4;camera[2]=10;
    ASSERT_TRUE(scene.runtime()->SetStaticCameraTransforms(camera,1));
    const auto moved=scene.Run(1);
    EXPECT_GT(CountDifferingPixels(first,moved),50u);
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("above",{-3,3,0}));
    const auto moved_source=scene.Run(1);
    EXPECT_GT(CountDifferingPixels(moved,moved_source),30u);
    EXPECT_EQ(scene.RebuildCount(),rebuilds);
    EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),bytes);
    EXPECT_EQ(scene.renderer().GeometryBufferBytesForTests(),geometry);
    EXPECT_EQ(wallpaper::metal::MetalRender::ProgramCompilesForTests(),programs);
    ASSERT_TRUE(scene.Step(2));
    EXPECT_EQ(scene.LastFramePasses().total(),0u);
}
TEST(PlanarReflectionGpu, DisabledQualityShowsTheSceneClearInsteadOfTheSources) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeReflectionScene(package);
    GpuSceneOptions options;options.width=128;options.height=128;options.quality.reflection=false;
    GpuScene scene(package,options);
    ASSERT_TRUE(scene.ok())<<scene.error();
    const auto picture=scene.Run(1);
    ASSERT_FALSE(picture.empty());
    EXPECT_TRUE(ExpectRegionAverage(picture,20,20,88,88,{32,64,96,255},1));
}

TEST(PlanarReflectionGpu, SortedGroupsStayInTheirPhaseAsSourcesMove) {
    WE_SKIP_WITHOUT_METAL();
    for (bool optimized : {false, true}) {
        SCOPED_TRACE(optimized);
        ScenePackage package;
        package.AddShader("sorted_reflection_source",
            "attribute vec3 a_Position;void main(){gl_Position=vec4(a_Position.xy/128.0+vec2(-0.5,0.0),0.0,1.0);}",
            "uniform vec4 g_Color4;void main(){gl_FragColor=g_Color4;}");
        package.AddShader("sorted_reflection_reader",
            "attribute vec3 a_Position;void main(){gl_Position=vec4(a_Position.xy/128.0+vec2(0.5,0.0),0.0,1.0);}",
            "uniform sampler2D g_Texture0;void main(){gl_FragColor=texSample2D(g_Texture0,vec2(0.25,0.5));}");
        ImageLayer red;red.id=1;red.name="red";red.origin={0,0,-10};red.size={128,128};red.color="1 0 0";
        red.model=package.AddImageModel("sorted_source","util/white",{.blending="translucent",.shader="sorted_reflection_source"});
        // WE's global marked list participates even when reflected:false kept a
        // layer out of the ordinary reflected list.
        red.extra={{"reflected",false}};
        ImageLayer green=red;green.id=2;green.name="green";green.origin={0,0,-20};green.color="0 1 0";
        ImageLayer observer=red;observer.id=3;observer.name="observer";
        observer.model=package.AddImageModel("sorted_reader","_rt_Reflection",{.blending="normal",.shader="sorted_reflection_reader"});
        SceneGeneral general;general.extra={{"orthogonalprojection",nullptr},{"fov",50},
            {"nearz",.1},{"farz",1000},{"transparentsorting",true}};
        auto json=SceneJson(general,{ImageLayerJson(red),ImageLayerJson(green),ImageLayerJson(observer)});
        json["camera"]={{"eye","0 0 0"},{"center","0 0 -1"},{"up","0 1 0"}};
        AddReflectionRequest(package,json);
        package.SetProject();package.SetScene(json);
        GpuScene scene(package,{.width=128,.height=128,.scene_optimization=optimized});
        ASSERT_TRUE(scene.ok())<<scene.error();
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),90,55,12,12,{255,0,0,255},0));
        const auto rebuilds=scene.RebuildCount();
        const auto bytes=scene.renderer().RenderTargetBytesForTests();
        const auto geometry=scene.renderer().GeometryBufferBytesForTests();
        ASSERT_TRUE(scene.runtime()->SetNodeTranslate("red",{0,0,-30}));
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),90,55,12,12,{0,255,0,255},0));
        EXPECT_EQ(scene.RebuildCount(),rebuilds);
        EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),bytes);
        EXPECT_EQ(scene.renderer().GeometryBufferBytesForTests(),geometry);
        if (optimized) {ASSERT_TRUE(scene.Step(2));EXPECT_EQ(scene.LastFramePasses().total(),0u);}
    }
}

TEST(PlanarReflectionGpu, EffectsUseTheirLocalCameraAndReuseTheirStorageInBothPhases) {
    WE_SKIP_WITHOUT_METAL();
    for (bool optimized : {false, true}) {
        SCOPED_TRACE(optimized);
        ScenePackage package;MakeReflectionScene(package);
        const auto tint=package.AddTintEffect("reflection_tint");
        ImageLayer source;source.id=1;source.name="source";source.origin={-2,2,0};source.size={8,8};
        source.extra={{"scale","0.25 0.25 0.25"}};
        source.model=package.AddImageModel("effect_source","util/white",{.blending="normal"});
        source.effects={EffectUse(tint,{{"tint","1 0 0"}})};
        ImageLayer observer;observer.id=2;observer.name="observer";observer.size={200,200};
        observer.model="models/reflection_view.json";observer.extra={{"reflected",false}};
        SceneGeneral general;general.clear_color={0.125f,0.25f,0.375f};
        general.extra={{"orthogonalprojection",nullptr},{"fov",90},{"nearz",.1},{"farz",1000},{"transparentsorting",false}};
        auto json=SceneJson(general,{ImageLayerJson(source),ImageLayerJson(observer)});
        json["camera"]={{"eye","0 0 10"},{"center","0 0 0"},{"up","0 1 0"}};
        AddReflectionRequest(package,json);
        package.SetScene(json);
        GpuSceneOptions options;options.width=128;options.height=128;options.scene_optimization=optimized;
        options.quality.msaa=4;
        GpuScene scene(package,options);
        ASSERT_TRUE(scene.ok())<<scene.error();
        const auto first=scene.Run(1);
        const auto red=ColourBounds(first,{255,0,0,255});
        EXPECT_GT(red.count,20u);EXPECT_LT(red.right,64);EXPECT_LT(red.bottom,64);
        const auto rebuilds=scene.RebuildCount();
        const auto bytes=scene.renderer().RenderTargetBytesForTests();
        const auto geometry=scene.renderer().GeometryBufferBytesForTests();
        ASSERT_TRUE(scene.runtime()->SetNodeTranslate("source",{2,-2,0}));
        const auto moved=scene.Run(1);
        const auto reflected=ColourBounds(moved,{255,0,0,255});
        EXPECT_GT(reflected.count,20u);EXPECT_GT(reflected.left,64);EXPECT_GT(reflected.top,64);
        EXPECT_EQ(scene.RebuildCount(),rebuilds);
        EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),bytes);
        EXPECT_EQ(scene.renderer().GeometryBufferBytesForTests(),geometry);
        if (optimized) {ASSERT_TRUE(scene.Step(2));EXPECT_EQ(scene.LastFramePasses().total(),0u);}
    }
}

TEST(PlanarReflectionGpu, OnlySamplingScenesPayForTheBoundedTargetAndDrawingPhase) {
    WE_SKIP_WITHOUT_METAL();
    for(bool depth:{false,true}) for (const auto size : {std::array<uint32_t,2>{128,128},std::array<uint32_t,2>{1280,720},std::array<uint32_t,2>{3840,2160}}) {
        const auto make=[&](ScenePackage& package,bool reflected) {
            MakeReflectionScene(package,reflected);
            if(depth) package.PutJson("materials/reflection_source.json",{{"passes",Json::array({{
                {"shader","reflection_source"},{"blending","normal"},{"cullmode","nocull"},
                {"depthtest","enabled"},{"depthwrite","enabled"},{"textures",Json::array({"util/white"})}}})}});
        };
        ScenePackage plain_package;make(plain_package,false);
        GpuScene plain(plain_package,{.width=size[0],.height=size[1]});
        ASSERT_TRUE(plain.ok())<<plain.error();
        ASSERT_TRUE(plain.Step());
        const auto base_bytes=plain.renderer().RenderTargetBytesForTests();
        const auto base_geometry=plain.renderer().GeometryBufferBytesForTests();
        const auto base_passes=plain.LastFramePasses();
        EXPECT_TRUE(plain.RenderTarget("_rt_Reflection").empty());
        ScenePackage package;make(package,true);
        GpuScene reflected(package,{.width=size[0],.height=size[1]});
        ASSERT_TRUE(reflected.ok())<<reflected.error();
        ASSERT_TRUE(reflected.Step());
        const auto bytes=reflected.renderer().RenderTargetBytesForTests();
        const auto geometry=reflected.renderer().GeometryBufferBytesForTests();
        const auto passes=reflected.LastFramePasses();
        std::cout<<"REFLECTION_INCREMENT width="<<size[0]<<" height="<<size[1]
            <<" depth="<<depth<<" bytes="<<(bytes-base_bytes)<<" geometry="<<(geometry-base_geometry)
            <<" renders="<<(passes.render_passes-base_passes.render_passes)
            <<" blits="<<(passes.blit_passes-base_passes.blit_passes)<<'\n';
        GpuSceneOptions off_options;off_options.width=size[0];off_options.height=size[1];
        off_options.quality.reflection=false;
        GpuScene disabled(package,off_options);
        ASSERT_TRUE(disabled.ok())<<disabled.error();
        ASSERT_TRUE(disabled.Step());
        const auto off_bytes=disabled.renderer().RenderTargetBytesForTests();
        std::cout<<"REFLECTION_DISABLED width="<<size[0]<<" height="<<size[1]
            <<" depth="<<depth<<" bytes="<<(off_bytes-base_bytes)
            <<" renders="<<(disabled.LastFramePasses().render_passes-base_passes.render_passes)
            <<" on_extra_bytes="<<(bytes-off_bytes)<<'\n';
        ASSERT_FALSE(disabled.RenderTarget("_rt_Reflection").empty());
        EXPECT_TRUE(ExpectRegionAverage(disabled.RenderTarget("_rt_Reflection"),
            0,0,size[0],size[1],{32,64,96,255},1));
        EXPECT_GT(bytes,base_bytes);
        EXPECT_LE(bytes-base_bytes,static_cast<uint64_t>(size[0])*size[1]*16+65536);
        EXPECT_EQ(geometry,base_geometry);
        EXPECT_EQ(passes.render_passes,base_passes.render_passes+1);
        EXPECT_EQ(passes.blit_passes,base_passes.blit_passes);
        ASSERT_TRUE(reflected.Step(2));EXPECT_EQ(reflected.LastFramePasses().total(),0u);
    }
}

TEST(PlanarReflectionGpu, RgbReflectionRemainsOpaqueWhenAMaterialWritesAlpha) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeReflectionScene(package);
    package.AddShader("reflection_source",
        "attribute vec3 a_Position;\nuniform mat4 g_ModelViewProjectionMatrix;\nvoid main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}",
        "uniform vec4 g_Color4;\nvoid main(){gl_FragColor=vec4(g_Color4.rgb,0.25);}");
    package.PutJson("materials/reflection_source.json",{{"passes",Json::array({{
        {"shader","reflection_source"},{"blending","normal"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"},{"alphawriting","enabled"},
        {"textures",Json::array({"util/white"})}}})}});
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok())<<scene.error();
    ASSERT_TRUE(scene.Step());
    const auto target=scene.RenderTarget("_rt_Reflection");
    ASSERT_FALSE(target.empty());
    EXPECT_GT(ColourBounds(target,{255,0,0,255}).count,30u);
    for(std::size_t i=3;i<target.rgba.size();i+=4) ASSERT_EQ(target.rgba[i],255);
}

TEST(PlanarReflectionGpu, AReflectedLayerLinkObservesAnExcludedSourcesPreviousScenePicture) {
    WE_SKIP_WITHOUT_METAL();
    for(bool optimized:{false,true}) {
        SCOPED_TRACE(optimized);
        ScenePackage package;
        const std::string left="attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/128.0+vec2(-0.5,0.0),0.0,1.0);}";
        const std::string sample="uniform sampler2D g_Texture0;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,vec2(0.25,0.5));}";
        package.AddShader("history_source",left,
            "uniform vec4 g_Color4;\nvoid main(){gl_FragColor=g_Color4;}");
        package.AddShader("history_reader",left,sample);
        package.AddShader("history_observer",
            "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/128.0+vec2(0.5,0.0),0.0,1.0);}",sample);
        ImageLayer source;source.id=1;source.name="source";source.origin={0,0,0};source.size={128,128};source.color="1 0 0";
        source.extra={{"reflected",false}};
        source.model=package.AddImageModel("history_source","util/white",{.blending="normal",.shader="history_source"});
        ImageLayer reader=source;reader.id=2;reader.name="reader";reader.extra={{"reflected",true},{"dependencies",Json::array({1})}};
        reader.model=package.AddImageModel("history_reader","_rt_imageLayerComposite_1_a",{.blending="normal",.shader="history_reader"});
        ImageLayer observer=source;observer.id=3;observer.name="observer";
        observer.model=package.AddImageModel("history_observer","_rt_Reflection",{.blending="normal",.shader="history_observer"});
        SceneGeneral general;general.extra={{"orthogonalprojection",nullptr},{"fov",50},{"nearz",.1},{"farz",1000},{"transparentsorting",false}};
        auto json=SceneJson(general,{ImageLayerJson(source),ImageLayerJson(reader),ImageLayerJson(observer)});
        json["camera"]={{"eye","0 0 10"},{"center","0 0 0"},{"up","0 1 0"}};
        AddReflectionRequest(package,json);
        package.SetProject();package.SetScene(json);
        GpuScene scene(package,{.width=128,.height=128,.scene_optimization=optimized});
        ASSERT_TRUE(scene.ok())<<scene.error();
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),90,55,12,12,{0,0,0,255},0));
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),90,55,12,12,{255,0,0,255},0));
        const auto rebuilds=scene.RebuildCount();
        const auto bytes=scene.renderer().RenderTargetBytesForTests();
        ASSERT_TRUE(scene.runtime()->SetNodeColor("source",{0,1,0}));
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),90,55,12,12,{255,0,0,255},0));
        EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),90,55,12,12,{0,255,0,255},0));
        EXPECT_EQ(scene.RebuildCount(),rebuilds);
        EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),bytes);
        if(optimized) {ASSERT_TRUE(scene.Step(2));EXPECT_EQ(scene.LastFramePasses().total(),0u);}
    }
}
TEST(PlanarReflectionGpu, HdrDisplayReflectionUsesTheZoomedAndPannedViewport) {
    WE_SKIP_WITHOUT_METAL();
    using namespace wallpaper;
    struct RestoreResolution {
        SceneResolution value {CurrentSceneResolution()};
        ~RestoreResolution() { SetSceneResolution(value); }
    } restore;
    SetSceneResolution(SceneResolution::Display);
    ScenePackage package;MakeReflectionScene(package,true,true);
    GpuSceneOptions options;options.width=320;options.height=180;
    options.quality.post_processing=static_cast<int>(wallpaper::PostProcessing::Ultra);
    GpuScene scene(package,options);
    ASSERT_TRUE(scene.ok())<<scene.error();
    for(const auto framing: {std::array<double,3>{1,0.5,0.5},
                              std::array<double,3>{1.5,0.3,0.7},
                              std::array<double,3>{1.2,0.7,0.2}}) {
        scene.renderer().SetWallpaperScalingFactor(framing[0]);
        scene.renderer().SetWallpaperFraming({framing[1],framing[2]});
        ASSERT_TRUE(scene.Step(2));
        ASSERT_TRUE(scene.scene().display_framed);
        auto reflected=scene.RenderTarget("_rt_Reflection");
        ASSERT_EQ(reflected.width,320u);ASSERT_EQ(reflected.height,180u);
        const auto& source=*scene.scene().activeCamera;
        linalg::Vector4d clip=source.GetRasterViewProjectionMatrix(
            scene.scene().display_clip,scene.scene().display_clip_generation)*
            linalg::Vector4d(8,8,0,1);
        // The target's vertical convention is opposite the ordinary framebuffer.
        const int x=static_cast<int>((clip.x()/clip.w()+1)*reflected.width*0.5);
        const int y=static_cast<int>((clip.y()/clip.w()+1)*reflected.height*0.5);
        ASSERT_GE(x,0);ASSERT_LT(x,static_cast<int>(reflected.width));
        ASSERT_GE(y,0);ASSERT_LT(y,static_cast<int>(reflected.height));
        EXPECT_TRUE(ExpectPixel(reflected,x,y,{255,0,0,255},0));
    }
}

TEST(PlanarReflectionGpu, TheReflectedDrawKeepsTheOrdinaryViewForwardUniform) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeReflectionScene(package);
    package.AddShader("reflection_source",
        "attribute vec3 a_Position;\nuniform mat4 g_ModelViewProjectionMatrix;\nvoid main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}",
        "uniform vec3 g_ViewForward;\nvoid main(){gl_FragColor=vec4(g_ViewForward*0.5+0.5,1.0);}");
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok())<<scene.error();
    ASSERT_TRUE(scene.Step());
    auto direction=scene.scene().activeCamera->GetDirection();
    Rgba expected {static_cast<uint8_t>(std::lround((direction.x()*0.5+0.5)*255)),
                   static_cast<uint8_t>(std::lround((direction.y()*0.5+0.5)*255)),
                   static_cast<uint8_t>(std::lround((direction.z()*0.5+0.5)*255)),255};
    const auto picture=scene.RenderTarget("_rt_Reflection");
    std::size_t matches=0;
    for(uint32_t y=0;y<picture.height;++y) for(uint32_t x=0;x<picture.width;++x) {
        const auto pixel=picture.At(x,y);
        matches += std::abs(int(pixel[0])-int(expected[0]))<=1 &&
                   std::abs(int(pixel[1])-int(expected[1]))<=1 &&
                   std::abs(int(pixel[2])-int(expected[2]))<=1;
    }
    EXPECT_GT(matches,60u);
}

TEST(PlanarReflectionGpu, SamplingTheBoundReflectionTargetReadsZeroInEveryChannel) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    package.AddShader("self_source",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/128.0+vec2(-0.5,0.0),0.0,1.0);}",
        "void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}");
    package.AddShader("self_reader",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/128.0+vec2(0.5,0.0),0.0,1.0);}",
        "uniform sampler2D g_Texture0;\nvoid main(){vec4 c=texSample2D(g_Texture0,vec2(0.25,0.5));gl_FragColor=vec4(c.r,0.5,c.a,1.0);}");
    ImageLayer source;source.id=1;source.name="source";source.size={128,128};
    source.model=package.AddImageModel("self_source","util/white",{.blending="normal",.shader="self_source"});
    ImageLayer reader;reader.id=2;reader.name="reader";reader.size={128,128};
    reader.model=package.AddImageModel("self_reader","_rt_Reflection",{.blending="normal",.shader="self_reader"});
    SceneGeneral general;general.extra={{"orthogonalprojection",nullptr},{"transparentsorting",false}};
    auto document=SceneJson(general,{ImageLayerJson(source),ImageLayerJson(reader)});
    AddReflectionRequest(package,document);package.SetProject();package.SetScene(document);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok())<<scene.error();
    ASSERT_TRUE(scene.Step(2));
    auto reflected=scene.RenderTarget("_rt_Reflection");
    EXPECT_TRUE(ExpectRegionAverage(reflected,20,55,12,12,{255,0,0,255},0));
    EXPECT_TRUE(ExpectRegionAverage(reflected,90,55,12,12,{0,128,0,255},0));
    EXPECT_TRUE(ExpectRegionAverage(scene.Picture(),90,55,12,12,{255,128,255,255},0));
    EXPECT_EQ(scene.LastFramePasses().total(),0u);
}

TEST(PlanarReflectionGpu, WorldAndClipShadersKeepTheOrdinaryFrontFaceConvention) {
    WE_SKIP_WITHOUT_METAL();
    for(bool world:{false,true}) for(bool reversed:{false,true}) {
        SCOPED_TRACE(world);
        SCOPED_TRACE(reversed);
        ScenePackage package;MakeReflectionScene(package);
        const std::string position=reversed
            ? "vec4(-a_Position.x,a_Position.y,a_Position.z,1.0)" : "vec4(a_Position,1.0)";
        const std::string vertex="attribute vec3 a_Position;\nuniform mat4 g_ModelViewProjectionMatrix;\nvoid main(){vec4 p="+position+";gl_Position="+
            (world?"mul(p,g_ModelViewProjectionMatrix)":"vec4(p.xy*0.4,0.0,1.0)")+";}";
        package.AddShader("reflection_source",vertex,
            "uniform vec4 g_Color4;\nvoid main(){gl_FragColor=g_Color4;}");
        package.PutJson("materials/reflection_source.json",{{"passes",Json::array({{
            {"shader","reflection_source"},{"blending","normal"},{"cullmode","normal"},
            {"depthtest","disabled"},{"depthwrite","disabled"},{"textures",Json::array({"util/white"})}}})}});
        GpuScene scene(package,{.width=128,.height=128});
        ASSERT_TRUE(scene.ok())<<scene.error();ASSERT_TRUE(scene.Step());
        const auto yellow=ColourBounds(scene.RenderTarget("_rt_Reflection"),{255,255,0,255});
        if(reversed) EXPECT_EQ(yellow.count,0u);else EXPECT_GT(yellow.count,30u);
    }
}

TEST(PlanarReflectionGpu, TheSharedClearKeepsOcclusionAndClearsDepthAfterVisibilityChanges) {
    WE_SKIP_WITHOUT_METAL();
    for(bool optimized:{false,true}) {
        SCOPED_TRACE(optimized);
        ScenePackage package;
        package.AddShader("reflection_depth",
            "attribute vec3 a_Position;\nuniform vec4 g_Color4;\nvoid main(){gl_Position=vec4(a_Position.xy/128.0,0.8-0.6*g_Color4.r,1.0);}",
            "uniform vec4 g_Color4;\nvoid main(){gl_FragColor=g_Color4;}");
        package.PutJson("materials/reflection_depth.json",{{"passes",Json::array({{
            {"shader","reflection_depth"},{"blending","normal"},{"cullmode","nocull"},
            {"depthtest","enabled"},{"depthwrite","enabled"},{"textures",Json::array()}}})}});
        package.PutJson("models/reflection_depth.json",{{"material","materials/reflection_depth.json"},{"width",128},{"height",128}});
        ImageLayer near;near.id=1;near.name="near";near.size={128,128};near.color="1 0 0";near.model="models/reflection_depth.json";
        ImageLayer far=near;far.id=2;far.name="far";far.color="0 1 0";
        SceneGeneral general;general.extra={{"orthogonalprojection",nullptr},{"transparentsorting",false}};
        auto document=SceneJson(general,{ImageLayerJson(near),ImageLayerJson(far)});
        AddReflectionRequest(package,document);package.SetProject();package.SetScene(document);
        GpuScene scene(package,{.width=128,.height=128,.scene_optimization=optimized});
        ASSERT_TRUE(scene.ok())<<scene.error();ASSERT_TRUE(scene.Step());
        EXPECT_TRUE(ExpectRegionAverage(scene.RenderTarget("_rt_Reflection"),55,55,12,12,{255,0,0,255},0));
        const auto rebuilds=scene.RebuildCount();
        ASSERT_TRUE(scene.runtime()->SetNodeVisible("near",false));ASSERT_TRUE(scene.Step());
        EXPECT_TRUE(ExpectRegionAverage(scene.RenderTarget("_rt_Reflection"),55,55,12,12,{0,255,0,255},0));
        ASSERT_TRUE(scene.runtime()->SetNodeVisible("near",true));ASSERT_TRUE(scene.Step());
        EXPECT_TRUE(ExpectRegionAverage(scene.RenderTarget("_rt_Reflection"),55,55,12,12,{255,0,0,255},0));
        EXPECT_EQ(scene.RebuildCount(),rebuilds);
        if(optimized) {ASSERT_TRUE(scene.Step(2));EXPECT_EQ(scene.LastFramePasses().total(),0u);}
    }
}

}
