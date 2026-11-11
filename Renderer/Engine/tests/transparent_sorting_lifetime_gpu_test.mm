#include "support/gpu_scene.hpp"
#include "MetalRender/MetalRender.hpp"
#include "RenderCommon/StaticSubgraphCache.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "SpecTexs.hpp"

#include <array>
#include <string>
#include <vector>
#include <gtest/gtest.h>

namespace {
using namespace we_test;

void MakeSharedFboSortingWitness(ScenePackage& package, bool interleaved, bool reads_scene) {
    package.AddShader("alias_cost_input",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/32.0,0.0,1.0);}\n",
        "uniform vec4 g_Color4;\nuniform float g_Time;\n"+
        std::string(reads_scene?"uniform sampler2D g_Texture1;\n":"")+
        "void main(){gl_FragColor=g_Color4+vec4(step(1000.0,g_Time)*0.1,0.0,0.0,0.0)"+
        (reads_scene?"+vec4(texSample2D(g_Texture1,vec2(0.0,0.0)).rgb*0.01,0.0)":"")+";}\n");
    package.AddShader("alias_cost_half_write",
        "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n"
        "void main(){gl_Position=vec4(a_Position,1.0);v_TexCoord=a_TexCoord;}\n",
        "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
        "void main(){vec4 c=texSample2D(g_Texture0,vec2(0.5,0.5));"
        "if((c.g<0.5&&v_TexCoord.x>0.5)||(c.g>0.5&&v_TexCoord.x<0.5))discard;"
        "gl_FragColor=c;}\n");
    const auto material = [&](const std::string& name, const std::string& shader) {
        package.PutJson("materials/"+name+".json",{{"passes",Json::array({{
            {"shader",shader},{"blending","normal"},{"cullmode","nocull"},
            {"depthtest","disabled"},{"depthwrite","disabled"},
            {"textures",Json::array({nullptr})}}})}});
    };
    material("alias_cost_half_write","alias_cost_half_write");

    const std::array<std::string,4> colors {"1 0 0","0 1 0","0 0 1","1 1 0"};
    const std::array<std::string,4> offsets {"-0.5,-0.5","0.5,-0.5","-0.5,0.5","0.5,0.5"};
    const std::array<float,4> separate_depths {-40,-30,-20,-10};
    const std::array<float,4> interleaved_depths {-40,-20,-30,-10};
    std::vector<Json> objects;
    for (std::size_t i=0;i<colors.size();++i) {
        const auto suffix=std::to_string(i+1);
        const auto close="alias_cost_close_"+suffix;
        package.AddShader(close,
            "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\nvarying vec2 v_TexCoord;\n"
            "void main(){gl_Position=vec4(a_Position.xy/80.0+vec2("+offsets[i]+"),0.0,1.0);"
            "v_TexCoord=a_TexCoord;}\n",
            "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
            "void main(){gl_FragColor=texSample2D(g_Texture0,v_TexCoord);}\n");
        material(close,close);
        const std::string shared=i<2 ? "alias_cost_a" : "alias_cost_b";
        const auto effect="effects/alias_cost_"+suffix+".json";
        package.PutJson(effect,{{"name","shared FBO lifetime witness"},
            {"fbos",Json::array({{{"name",shared},{"format","rgba8"},{"unique",false}}})},
            {"passes",Json::array({
                {{"material","materials/alias_cost_half_write.json"},{"target",shared}},
                {{"material","materials/"+close+".json"},
                 {"bind",Json::array({{{"index",0},{"name",shared}}})}}})}});
        ImageLayer layer;
        layer.id=static_cast<int>(i+1);layer.name="alias-cost-"+suffix;layer.size={64,64};
        layer.origin={0,0,(interleaved?interleaved_depths:separate_depths)[i]};
        layer.color=colors[i];
        layer.model=package.AddImageModel("alias_cost_input_"+suffix,"util/white",
            {.blending="translucent",.shader="alias_cost_input"});
        if(reads_scene) package.PutJson("materials/alias_cost_input_"+suffix+".json",
            {{"passes",Json::array({{{"shader","alias_cost_input"},
                {"textures",Json::array({"util/white","_rt_FullFrameBuffer"})},
                {"blending","translucent"},{"cullmode","nocull"},
                {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
        layer.effects={EffectUse(effect)};
        objects.push_back(ImageLayerJson(layer));
    }
    SceneGeneral general;
    general.extra={{"orthogonalprojection",nullptr},{"fov",50},{"nearz",.1},
        {"farz",10000},{"transparentsorting",true}};
    auto scene=SceneJson(general,objects);
    scene["camera"]={{"eye","0 0 0"},{"center","0 0 -1"},{"up","0 1 0"}};
    package.SetProject();package.SetScene(scene);
}

std::size_t CountWitnessColor(const Image& picture, const Rgba& expected) {
    std::size_t count=0;
    for (std::size_t i=0;i+3<picture.rgba.size();i+=4) {
        bool same=true;
        for(std::size_t c=0;c<4;++c) same=same&&picture.rgba[i+c]==expected[c];
        count+=same;
    }
    return count;
}


TEST(TransparentSortingLifetimeGpu, SharedNamedFbosSurviveDepthInterleavingWithoutGrowingAfterCompile) {
    WE_SKIP_WITHOUT_METAL();
    for (bool optimized : {false, true}) {
        SCOPED_TRACE(optimized);
        ScenePackage package;
        MakeSharedFboSortingWitness(package, false, true);
        GpuScene scene(package, {.width=128, .height=128, .scene_optimization=optimized});
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto separate = scene.Run(1);
        ASSERT_FALSE(separate.empty()) << scene.error();
        for (const Rgba color : {Rgba{255,0,0,255}, Rgba{0,255,0,255},
                                 Rgba{0,0,255,255}, Rgba{255,255,0,255}})
            ASSERT_GT(CountWitnessColor(separate, color), 100u);
        const auto bytes = scene.renderer().RenderTargetBytesForTests();
        const auto geometry = scene.renderer().GeometryBufferBytesForTests();
        const auto programs = wallpaper::metal::MetalRender::ProgramCompilesForTests();
        for (bool interleaved : {true, false, true}) {
            ASSERT_TRUE(scene.runtime()->SetNodeTranslate("alias-cost-2", {0,0,interleaved ? -20.0f : -30.0f}));
            ASSERT_TRUE(scene.runtime()->SetNodeTranslate("alias-cost-3", {0,0,interleaved ? -30.0f : -20.0f}));
            const auto moved = scene.Run(2);
            ASSERT_FALSE(moved.empty()) << scene.error();
            EXPECT_TRUE(ExpectSamePicture(separate, moved));
            EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(), bytes);
            EXPECT_EQ(scene.renderer().GeometryBufferBytesForTests(), geometry);
            EXPECT_EQ(wallpaper::metal::MetalRender::ProgramCompilesForTests(), programs);
            EXPECT_EQ(scene.RebuildCount(), 0);
        }
    }
}

void MakeMovingScreenReader(ScenePackage& package) {
    package.AddShader("moving_screen_source",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/32.0*vec2(0.5,1.0)+vec2(0.5,0.0),0.0,1.0);}\n",
        "uniform vec4 g_Color4;\nvoid main(){gl_FragColor=g_Color4;}\n");
    package.AddShader("moving_screen_reader",
        "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/32.0*vec2(0.5,1.0)-vec2(0.5,0.0),0.0,1.0);}\n",
        "uniform sampler2D g_Texture0;\nvoid main(){gl_FragColor=texSample2D(g_Texture0,vec2(0.75,0.5));}\n");
    ImageLayer source;
    source.id=1;source.name="source";source.size={64,64};source.origin={0,0,-30};source.color="1 0 0";
    source.model=package.AddImageModel("moving_screen_source","util/white",
        {.blending="translucent",.shader="moving_screen_source"});
    ImageLayer reader=source;
    reader.id=2;reader.name="reader";reader.origin={0,0,-10};
    reader.model=package.AddImageModel("moving_screen_reader","_rt_FullFrameBuffer",
        {.blending="translucent",.shader="moving_screen_reader"});
    SceneGeneral general;
    general.clear_color={0,1,0};
    general.extra={{"orthogonalprojection",nullptr},{"fov",50},{"nearz",.1},
        {"farz",10000},{"transparentsorting",true}};
    auto scene=SceneJson(general,{ImageLayerJson(source),ImageLayerJson(reader)});
    scene["camera"]={{"eye","0 0 0"},{"center","0 0 -1"},{"up","0 1 0"}};
    package.SetProject();package.SetScene(scene);
}

TEST(TransparentSortingLifetimeGpu, MovingAScreenReaderFirstClearsBeforeItsSnapshotIncludingMultisamples) {
    WE_SKIP_WITHOUT_METAL();
    for (uint32_t samples : {1u, 4u}) {
        if (wallpaper::metal::MetalRender::SelectSampleCountForDevice(samples) != samples) continue;
        for (bool optimized : {false, true}) {
            SCOPED_TRACE(::testing::Message() << "samples=" << samples << " optimized=" << optimized);
            ScenePackage package;MakeMovingScreenReader(package);
            GpuScene scene(package,{.width=128,.height=128,.scene_optimization=optimized});
            ASSERT_TRUE(scene.ok()) << scene.error();
            if (samples > 1) {
                scene.scene().renderTargets[std::string(wallpaper::SpecTex_Default)].sample_count=samples;
                ASSERT_TRUE(scene.Rebuild()) << scene.error();
            }
            const int rebuilds=scene.RebuildCount();
            const auto before=scene.Run(1);
            ASSERT_TRUE(ExpectRegionAverage(before,16,32,32,64,{255,0,0,255},0));
            ASSERT_TRUE(ExpectRegionAverage(before,80,32,32,64,{255,0,0,255},0));
            const auto bytes=scene.renderer().RenderTargetBytesForTests();
            const auto geometry=scene.renderer().GeometryBufferBytesForTests();
            const auto programs=wallpaper::metal::MetalRender::ProgramCompilesForTests();
            ASSERT_TRUE(scene.runtime()->SetNodeTranslate("reader",{0,0,-40}));
            for (int frame=0; frame<3; ++frame) {
                const auto after=scene.Run(1);
                EXPECT_TRUE(ExpectRegionAverage(after,16,32,32,64,{0,255,0,255},0));
                EXPECT_TRUE(ExpectRegionAverage(after,80,32,32,64,{255,0,0,255},0));
                EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),bytes);
                EXPECT_EQ(scene.renderer().GeometryBufferBytesForTests(),geometry);
                EXPECT_EQ(wallpaper::metal::MetalRender::ProgramCompilesForTests(),programs);
                EXPECT_EQ(scene.RebuildCount(),rebuilds);
            }
            // Both reconfiguration paths must use the order currently executing.
            wallpaper::render::SetSceneOptimizationEnabled(!optimized);
            auto toggled=scene.Run(1);
            EXPECT_TRUE(ExpectRegionAverage(toggled,16,32,32,64,{0,255,0,255},0));
            EXPECT_TRUE(ExpectRegionAverage(toggled,80,32,32,64,{255,0,0,255},0));
            wallpaper::render::SetSceneOptimizationEnabled(optimized);
            ASSERT_TRUE(scene.Step());
            scene.scene().render_scale=0.5;
            ASSERT_TRUE(scene.renderer().ResizeRenderTargets(scene.scene())) << scene.renderer().lastError();
            const auto resized=scene.Run(1);
            EXPECT_TRUE(ExpectRegionAverage(resized,16,32,32,64,{0,255,0,255},0));
            EXPECT_TRUE(ExpectRegionAverage(resized,80,32,32,64,{255,0,0,255},0));
            EXPECT_EQ(wallpaper::metal::MetalRender::ProgramCompilesForTests(),programs);
            EXPECT_EQ(scene.renderer().GeometryBufferBytesForTests(),geometry);
            EXPECT_EQ(scene.RebuildCount(),rebuilds);
        }
    }
}

TEST(TransparentSortingLifetimeGpu, ASelfLinkRetainsItsSeparatePreviousPictureWhileItsOwnerMoves) {
    WE_SKIP_WITHOUT_METAL();
    for (bool optimized : {false, true}) {
        SCOPED_TRACE(optimized);
        ScenePackage package;
        package.AddShader("sorting_self_history",
            "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/32.0*vec2(0.5,1.0)-vec2(0.5,0.0),0.0,1.0);}\n",
            "uniform sampler2D g_Texture0;\nvoid main(){vec3 old=texSample2D(g_Texture0,vec2(0.25,0.5)).rgb;gl_FragColor=vec4((old+vec3(1.0,0.0,0.0))*0.5,1.0);}\n");
        package.AddShader("sorting_self_neighbor",
            "attribute vec3 a_Position;\nvoid main(){gl_Position=vec4(a_Position.xy/32.0*vec2(0.5,1.0)+vec2(0.5,0.0),0.0,1.0);}\n",
            "void main(){gl_FragColor=vec4(0.0,1.0,0.0,1.0);}\n");
        ImageLayer source;
        source.id=1;source.name="self-source";source.size={64,64};source.origin={0,0,-30};
        source.model=package.AddImageModel("sorting_self_history","_rt_imageLayerComposite_1_a",
            {.blending="translucent",.shader="sorting_self_history"});
        source.extra={{"dependencies",Json::array({1})}};
        ImageLayer neighbor=source;
        neighbor.id=2;neighbor.name="neighbor";neighbor.origin={0,0,-20};neighbor.extra=Json::object();
        neighbor.model=package.AddImageModel("sorting_self_neighbor","util/white",
            {.blending="translucent",.shader="sorting_self_neighbor"});
        SceneGeneral general;
        general.extra={{"orthogonalprojection",nullptr},{"fov",50},{"nearz",.1},
            {"farz",10000},{"transparentsorting",true}};
        auto definition=SceneJson(general,{ImageLayerJson(source),ImageLayerJson(neighbor)});
        definition["camera"]={{"eye","0 0 0"},{"center","0 0 -1"},{"up","0 1 0"}};
        package.SetProject();package.SetScene(definition);
        GpuScene scene(package,{.width=128,.height=128,.scene_optimization=optimized});
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto bytes=scene.renderer().RenderTargetBytesForTests();
        const auto programs=wallpaper::metal::MetalRender::ProgramCompilesForTests();
        int expected=0;
        for (int frame=0;frame<6;++frame) {
            if (frame==3) ASSERT_TRUE(scene.runtime()->SetNodeTranslate("self-source",{0,0,-10}));
            ASSERT_TRUE(scene.Step()) << scene.error();
            expected=(expected+256)/2;
            const auto retained=scene.RenderTarget(wallpaper::LayerCompositeTargetKey(1));
            ASSERT_FALSE(retained.empty());
            const auto pixel=retained.At(retained.width/4,retained.height/2);
            EXPECT_NEAR(pixel[0],expected,1);
            EXPECT_EQ(pixel[1],0);
            EXPECT_EQ(pixel[2],0);
            EXPECT_EQ(scene.RebuildCount(),0);
            EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),bytes);
            EXPECT_EQ(wallpaper::metal::MetalRender::ProgramCompilesForTests(),programs);
        }
    }
}

}
