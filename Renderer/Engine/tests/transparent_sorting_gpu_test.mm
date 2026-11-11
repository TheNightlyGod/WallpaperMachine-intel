#include "support/gpu_scene.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "MetalRender/MetalRender.hpp"
#include "MetalRender/ScenePassDescription.hpp"
#include "RenderCommon/ScenePass.hpp"
#include "RenderCommon/SceneToRenderGraph.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "SpecTexs.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Scene/Scene.h"
#include <unordered_map>
#include <unordered_set>
#include <gtest/gtest.h>
#include <iostream>

namespace {
using namespace we_test;

void MakeSortingScene(ScenePackage& package) {
    package.AddShader("fixed_sort_card",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/64.0,0.0,1.0); }\n",
        "uniform vec4 g_Color4;\nvoid main(){gl_FragColor=g_Color4;}\n");
    ImageLayer red; red.id=1; red.name="red"; red.origin={0,0,-10}; red.size={64,64}; red.color="1 0 0";
    red.model=package.AddImageModel("sort_card","util/white",{.blending="translucent",.shader="fixed_sort_card"});
    ImageLayer green=red;green.id=2;green.name="green";green.origin={0,0,-20};green.color="0 1 0";
    SceneGeneral general;general.extra={{"orthogonalprojection",nullptr},{"fov",50},
        {"nearz",.1},{"farz",10000},{"transparentsorting",true}};
    auto scene=SceneJson(general,{ImageLayerJson(red),ImageLayerJson(green)});
    scene["camera"]={{"eye","0 0 0"},{"center","0 0 -1"},{"up","0 1 0"}};
    package.SetProject();package.SetScene(scene);
}

TEST(TransparentSortingGpu, MovingLayersChangePixelsWithoutRebuildingOrGrowingTheGraph) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeSortingScene(package);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),48,48,32,32,{255,0,0,255},0));
    const auto targets=scene.renderer().RenderTargetBytesForTests();
    const auto geometry=scene.renderer().GeometryBufferBytesForTests();
    const auto programs=wallpaper::metal::MetalRender::ProgramCompilesForTests();
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("red",{0,0,-30}));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),48,48,32,32,{0,255,0,255},0));
    EXPECT_EQ(scene.RebuildCount(),0);
    EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),targets);
    EXPECT_EQ(scene.renderer().GeometryBufferBytesForTests(),geometry);
    EXPECT_EQ(wallpaper::metal::MetalRender::ProgramCompilesForTests(),programs);
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("red",{0,0,-20}));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),48,48,32,32,{0,255,0,255},0));
    EXPECT_EQ(scene.RebuildCount(),0);
    ASSERT_TRUE(scene.Step(2));
    EXPECT_EQ(scene.LastFramePasses().total(),0u);
}

TEST(TransparentSortingGpu, ACameraDirectionChangeReordersPreparedDrawsAndReturnsToIdle) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeSortingScene(package);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(ExpectRegionAverage(scene.Run(1),48,48,32,32,{255,0,0,255},0));
    const auto bytes=scene.renderer().RenderTargetBytesForTests();
    const auto programs=wallpaper::metal::MetalRender::ProgramCompilesForTests();
    auto camera=scene.runtime()->GetStaticCameraTransforms();
    camera[3]=0;camera[4]=0;camera[5]=1;
    ASSERT_TRUE(scene.runtime()->SetStaticCameraTransforms(camera,2));
    EXPECT_TRUE(ExpectRegionAverage(scene.Run(1),48,48,32,32,{0,255,0,255},0));
    EXPECT_EQ(scene.RebuildCount(),0);
    EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),bytes);
    EXPECT_EQ(wallpaper::metal::MetalRender::ProgramCompilesForTests(),programs);
    ASSERT_TRUE(scene.Step(2));
    EXPECT_EQ(scene.LastFramePasses().total(),0u);
}

TEST(TransparentSortingGpu, SortingAroundAnOmittedLayerPreservesTheUnclearedOutputWithoutRebuilding) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeSortingScene(package);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.scene().clearEnabled=false;
    for(const auto& child:scene.scene().sceneGraph->GetChildren()) {
        if(child->Name()!="green") continue;
        child->SetVisible(false);
        child->SetVisibilitySettled(true);
    }
    ASSERT_TRUE(scene.Rebuild());
    const auto rebuilds=scene.RebuildCount();
    const auto expected=scene.Run(1);
    // The material preserves destination alpha; without a scene clear that starts at zero.
    ASSERT_TRUE(ExpectRegionAverage(expected,48,48,32,32,{255,0,0,0},0));
    EXPECT_EQ(scene.renderer().FirstSceneOutputLoadForTests(),wallpaper::metal::MetalLoadAction::Load);
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("red",{0,0,-30}));
    EXPECT_EQ(scene.Run(1).rgba,expected.rgba);
    EXPECT_EQ(scene.renderer().FirstSceneOutputLoadForTests(),wallpaper::metal::MetalLoadAction::Load);
    ASSERT_TRUE(scene.runtime()->SetNodeTranslate("green",{0,0,-40}));
    EXPECT_EQ(scene.Run(1).rgba,expected.rgba);
    EXPECT_EQ(scene.renderer().FirstSceneOutputLoadForTests(),wallpaper::metal::MetalLoadAction::Load);
    EXPECT_EQ(scene.RebuildCount(),rebuilds);
}

void MakeReferencedEffectScene(ScenePackage& package, bool source_is_near, bool alternating = false,
                               bool animate = true, bool transparent = true, bool reader_first = false) {
    package.AddShader("animated_sort_card",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/64.0,0.0,1.0); }\n",
        "uniform vec4 g_Color4;\nuniform float g_Time;\nvoid main(){gl_FragColor=g_Color4+vec4(step(1000.0,g_Time)*0.1,0.0,0.0,0.0); }\n");
    package.AddShader("sorted_effect",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy*0.5,0.0,1.0); }\n",
        "uniform sampler2D g_Texture0;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,vec2(0.5,0.5)); }\n");
    package.AddShader("sorted_reader",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/64.0,0.0,1.0); }\n",
        "uniform sampler2D g_Texture0;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,vec2(0.5,0.5)); }\n");
    package.PutJson("materials/sorted_effect.json",{{"passes",Json::array({{
        {"shader","sorted_effect"},{"blending","normal"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"},{"textures",Json::array({nullptr})}}})}});
    package.PutJson("effects/sorted/effect.json",{{"name","sorted effect"},
        {"passes",Json::array({{{"material","materials/sorted_effect.json"}}})}});
    ImageLayer source;source.id=1;source.name="source";source.size={64,64};
    source.origin={0,0,source_is_near ? -5.0f : -30.0f};source.color="1 0 0";
    source.model=package.AddImageModel("effect_source","util/white",
        {.blending="translucent",.shader="animated_sort_card"});
    source.effects={EffectUse("effects/sorted/effect.json")};
    if (alternating && animate) source.color=ScriptedValue(
        "let n=0;export function update(value){n++;return new Vec3(n%2,1-n%2,0);}","1 0 0");
    ImageLayer reader;reader.id=2;reader.name="reader";reader.size={64,64};reader.origin={0,0,-20};
    reader.model=package.AddImageModel("effect_reader","_rt_imageLayerComposite_1_a",
        {.blending="translucent",.shader="sorted_reader"});
    reader.extra={{"dependencies",Json::array({1})}};
    ImageLayer other=source;other.id=3;other.name="other";other.origin={0,0,-10};other.color="0 1 0";
    SceneGeneral general;general.extra={{"orthogonalprojection",nullptr},{"fov",50},
        {"nearz",.1},{"farz",10000},{"transparentsorting",transparent}};
    std::vector<Json> objects {ImageLayerJson(source),ImageLayerJson(reader),ImageLayerJson(other)};
    if(reader_first) std::swap(objects[0],objects[1]);
    if (alternating) {
        ImageLayer monitor=reader;monitor.id=4;monitor.name="monitor";monitor.origin={0,0,-15};
        monitor.model=package.AddImageModel("reader_monitor","_rt_imageLayerComposite_2_a",
            {.blending="translucent",.shader="sorted_reader"});
        monitor.extra={{"dependencies",Json::array({2})}};
        objects.push_back(ImageLayerJson(monitor));
    }
    auto scene=SceneJson(general,objects);
    scene["camera"]={{"eye","0 0 0"},{"center","0 0 -1"},{"up","0 1 0"}};
    package.SetProject();package.SetScene(scene);
}

TEST(TransparentSortingGpu, ReferencedEffectInputsSurviveAChangeOfLayerOrder) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage near_package;MakeReferencedEffectScene(near_package,true);
    GpuScene near(near_package,{.width=128,.height=128});
    ASSERT_TRUE(near.ok()) << near.error();
    const auto expected=near.Run(1);
    ASSERT_TRUE(ExpectRegionAverage(expected,52,52,24,24,{255,0,0,255},0));
    const auto near_bytes=near.renderer().RenderTargetBytesForTests();
    ScenePackage moving_package;MakeReferencedEffectScene(moving_package,false);
    GpuScene moving(moving_package,{.width=128,.height=128});
    ASSERT_TRUE(moving.ok()) << moving.error();
    ASSERT_TRUE(ExpectRegionAverage(moving.Run(1),52,52,24,24,{0,255,0,255},0));
    const auto before_bytes=moving.renderer().RenderTargetBytesForTests();
    std::cout << "SORT_RESOURCE_WITNESS before=" << before_bytes << " near=" << near_bytes << '\n';
    ASSERT_TRUE(moving.runtime()->SetNodeTranslate("source",{0,0,-5}));
    EXPECT_TRUE(ExpectSamePicture(expected,moving.Run(1)));
    EXPECT_EQ(moving.RebuildCount(),0);
    EXPECT_LE(moving.renderer().RenderTargetBytesForTests(),std::max(before_bytes,near_bytes));
}

TEST(TransparentSortingGpu, LayerLinksReadThePreviousOrCurrentPictureAtTheirPlaceInTheOrder) {
    WE_SKIP_WITHOUT_METAL();
    for (bool optimized : {false, true}) {
        SCOPED_TRACE(optimized);
        ScenePackage package;MakeReferencedEffectScene(package,true,true);
        GpuScene scene(package,{.width=128,.height=128,.scene_optimization=optimized});
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto targets=scene.renderer().RenderTargetBytesForTests();
        const auto geometry=scene.renderer().GeometryBufferBytesForTests();
        const auto programs=wallpaper::metal::MetalRender::ProgramCompilesForTests();
        const auto pixel=[&](int id) {
            const auto image=scene.RenderTarget(wallpaper::LayerCompositeTargetKey(id));
            EXPECT_FALSE(image.empty());
            return image.At(image.width/2,image.height/2);
        };
        ASSERT_TRUE(scene.Step());
        auto previous=pixel(1);
        for(int frame=0;frame<4;++frame) {
            ASSERT_TRUE(scene.Step());
            const auto current=pixel(1);
            EXPECT_NE(current,previous);
            EXPECT_EQ(pixel(2),previous);
            previous=current;
        }
        ASSERT_TRUE(scene.runtime()->SetNodeTranslate("source",{0,0,-30}));
        for(int frame=0;frame<4;++frame) {
            ASSERT_TRUE(scene.Step());
            EXPECT_EQ(pixel(2),pixel(1));
        }
        ASSERT_TRUE(scene.runtime()->SetNodeTranslate("source",{0,0,-5}));
        previous=pixel(1);
        ASSERT_TRUE(scene.Step());
        EXPECT_EQ(pixel(2),previous);
        EXPECT_EQ(scene.RebuildCount(),0);
        EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),targets);
        EXPECT_EQ(scene.renderer().GeometryBufferBytesForTests(),geometry);
        EXPECT_EQ(wallpaper::metal::MetalRender::ProgramCompilesForTests(),programs);
    }
}

TEST(TransparentSortingGpu, CompositeLinksKeepAuthoredTimingWithDepthSortingDisabled) {
    WE_SKIP_WITHOUT_METAL();
    for(bool optimized:{false,true}) {
        ScenePackage package;MakeReferencedEffectScene(package,true,true,true,false,true);
        GpuScene scene(package,{.width=128,.height=128,.scene_optimization=optimized});
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto pixel=[&](int id) {
            const auto picture=scene.RenderTarget(wallpaper::LayerCompositeTargetKey(id));
            EXPECT_FALSE(picture.empty());
            return picture.At(picture.width/2,picture.height/2);
        };
        ASSERT_TRUE(scene.Step());
        auto previous=pixel(1);
        for(int frame=0;frame<5;++frame) {
            if(frame==2) ASSERT_TRUE(scene.runtime()->SetNodeTranslate("source",{0,0,-30}));
            ASSERT_TRUE(scene.Step());
            const auto current=pixel(1);
            EXPECT_NE(current,previous);
            EXPECT_EQ(pixel(2),previous);
            previous=current;
        }
        EXPECT_EQ(scene.RebuildCount(),0);
    }
}

TEST(TransparentSortingGpu, AHistoryReaderCatchesUpOneFrameAfterItsSourceChangesThenIdles) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeReferencedEffectScene(package,true,true,false);
    package.AddShader("animated_sort_card",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/64.0,0.0,1.0); }\n",
        "uniform vec4 g_Color4;\nvoid main(){gl_FragColor=g_Color4;}\n");
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(scene.Step(3));
    const auto red=scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2));
    ASSERT_TRUE(ExpectRegionAverage(red,20,20,24,24,{255,0,0,255},0));
    ASSERT_TRUE(scene.runtime()->SetNodeColor("source",{0,1,0}));
    ASSERT_TRUE(scene.Step());
    EXPECT_TRUE(ExpectSamePicture(red,scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2))));
    ASSERT_TRUE(scene.Step());
    EXPECT_TRUE(ExpectRegionAverage(scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2)),
                                  20,20,24,24,{0,255,0,255},0));
    ASSERT_TRUE(scene.Step(3));
    EXPECT_EQ(scene.LastFramePasses().total(),0u);
    EXPECT_EQ(scene.renderer().ShaderUpdateDemandReasons() &
        static_cast<uint32_t>(wallpaper::render::DynamicReason::Feedback),0u);
    EXPECT_EQ(scene.RebuildCount(),0);
}


TEST(TransparentSortingGpu, SelfLinksKeepTheirSnapshotAcrossAnOwnerCrossing) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    package.AddShader("self_sort",
        "attribute vec3 a_Position;void main(){gl_Position=vec4(a_Position.xy/64.0,0.0,1.0);}",
        "uniform sampler2D g_Texture0;void main(){gl_FragColor=vec4(texSample2D(g_Texture0,vec2(0.5, 0.5)).r+0.125,0.0,0.0,1.0);}");
    ImageLayer source;source.id=1;source.name="self";source.size={64,64};source.origin={0,0,-30};
    source.model=package.AddImageModel("self_sort","_rt_imageLayerComposite_1_a",
        {.blending="translucent",.shader="self_sort"});
    source.extra={{"dependencies",Json::array({1})}};
    ImageLayer other;other.id=2;other.name="other";other.origin={0,0,-20};other.size={64,64};
    other.color="0 1 0";other.model=package.AddImageModel("self_other","util/white",{.blending="translucent"});
    SceneGeneral general;general.extra={{"orthogonalprojection",nullptr},{"fov",50},
        {"nearz",.1},{"farz",10000},{"transparentsorting",true}};
    auto json=SceneJson(general,{ImageLayerJson(source),ImageLayerJson(other)});
    json["camera"]={{"eye","0 0 0"},{"center","0 0 -1"},{"up","0 1 0"}};
    package.SetProject();package.SetScene(json);
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto bytes=scene.renderer().RenderTargetBytesForTests();
    int previous=0;
    for(int frame=0;frame<5;++frame) {
        if(frame==2) ASSERT_TRUE(scene.runtime()->SetNodeTranslate("self",{0,0,-10}));
        ASSERT_TRUE(scene.Step());
        const auto picture=scene.RenderTarget(wallpaper::LayerCompositeTargetKey(1));
        ASSERT_FALSE(picture.empty());
        const int current=picture.At(picture.width/2,picture.height/2)[0];
        EXPECT_NEAR(current-previous,32,1);
        previous=current;
    }
    EXPECT_NE(scene.renderer().ShaderUpdateDemandReasons() &
        static_cast<uint32_t>(wallpaper::render::DynamicReason::Feedback),0u);
    EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),bytes);
    EXPECT_EQ(scene.RebuildCount(),0);
}

TEST(TransparentSortingGpu, ADelayedPointerInputRequestsOnlyItsCatchUpFrame) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeReferencedEffectScene(package,true,true,false);
    package.AddShader("animated_sort_card",
        "attribute vec3 a_Position;void main(){gl_Position=vec4(a_Position.xy/64.0,0.0,1.0);}",
        "uniform vec2 g_PointerPosition;void main(){float x=step(0.5,g_PointerPosition.x);gl_FragColor=vec4(1.0-x,x,0.0,1.0);}");
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.SetPointer(0.1,0.5);ASSERT_TRUE(scene.Step(3));
    const auto red=scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2));
    ASSERT_TRUE(ExpectRegionAverage(red,20,20,24,24,{255,0,0,255},0));
    scene.SetPointer(0.9,0.5);ASSERT_TRUE(scene.Step());
    EXPECT_TRUE(ExpectSamePicture(red,scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2))));
    EXPECT_NE(scene.renderer().ShaderUpdateDemandReasons() &
        static_cast<uint32_t>(wallpaper::render::DynamicReason::Feedback),0u);
    ASSERT_TRUE(scene.Step(2));
    EXPECT_TRUE(ExpectRegionAverage(scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2)),
        20,20,24,24,{0,255,0,255},0));
    EXPECT_EQ(scene.renderer().ShaderUpdateDemandReasons() &
        static_cast<uint32_t>(wallpaper::render::DynamicReason::Feedback),0u);
    EXPECT_EQ(scene.RebuildCount(),0);
}

TEST(TransparentSortingGpu, AnEffectSnapshotCyclePropagatesOneChangeToItsDelayedReader) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;MakeReferencedEffectScene(package,true,true,false);
    package.AddShader("animated_sort_card",
        "attribute vec3 a_Position;void main(){gl_Position=vec4(a_Position.xy/64.0,0.0,1.0);}",
        "uniform vec4 g_Color4;void main(){gl_FragColor=g_Color4;}");
    package.PutJson("effects/sorted/effect.json",{{"name","current-frame snapshot"},
        {"fbos",Json::array({{{"name","cyclebuf"},{"format","rgba8"},{"unique",true}}})},
        {"passes",Json::array({
            {{"material","materials/sorted_effect.json"},{"target","cyclebuf"}},
            {{"material","materials/sorted_effect.json"},{"target","cyclebuf"},
             {"bind",Json::array({{{"index",0},{"name","cyclebuf"}}})}},
            {{"material","materials/sorted_effect.json"},
             {"bind",Json::array({{{"index",0},{"name","cyclebuf"}}})}}})}});
    GpuScene scene(package,{.width=128,.height=128});
    ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_TRUE(scene.Step(3));
    const auto red=scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2));
    ASSERT_TRUE(ExpectRegionAverage(red,20,20,24,24,{255,0,0,255},0));
    ASSERT_TRUE(scene.runtime()->SetNodeColor("source",{0,1,0}));
    ASSERT_TRUE(scene.Step());
    EXPECT_TRUE(ExpectSamePicture(red,scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2))));
    EXPECT_NE(scene.renderer().ShaderUpdateDemandReasons() &
        static_cast<uint32_t>(wallpaper::render::DynamicReason::Feedback),0u);
    ASSERT_TRUE(scene.Step(2));
    EXPECT_TRUE(ExpectRegionAverage(scene.RenderTarget(wallpaper::LayerCompositeTargetKey(2)),
        20,20,24,24,{0,255,0,255},0));
    EXPECT_EQ(scene.renderer().ShaderUpdateDemandReasons() &
        static_cast<uint32_t>(wallpaper::render::DynamicReason::Feedback),0u);
    EXPECT_EQ(scene.RebuildCount(),0);
}

}
