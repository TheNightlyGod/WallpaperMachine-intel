#include "support/gpu_scene.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneMaterial.h"
#include "RenderCommon/ScenePass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "SpecTexs.hpp"

#include <gtest/gtest.h>

namespace {
using namespace wallpaper;
using namespace we_test;

SceneNode* FindNode(SceneNode* node, std::string_view name) {
    if (node == nullptr) return nullptr;
    if (node->Name() == name) return node;
    for (const auto& child : node->GetChildren())
        if (auto* found = FindNode(child.get(), name)) return found;
    return nullptr;
}

void DepthScene(ScenePackage& package) {
    package.InstallStandardAssets();
    const std::string vertex =
        "attribute vec3 a_Position;attribute vec2 a_TexCoord;varying vec2 uv;"
        "uniform mat4 g_ModelViewProjectionMatrix;void main(){"
        "gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);uv=a_TexCoord;}";
    package.AddShader("depth_black", vertex, "void main(){gl_FragColor=vec4(0,0,0,1);}");
    package.AddShader("depth_reader", vertex,
        "uniform sampler2D g_Texture0;varying vec2 uv;void main(){"
        "float d=texSample2D(g_Texture0,uv).r;gl_FragColor=vec4(d,d,d,1);}");
    SceneGeneral general; general.canvas_width = general.canvas_height = 64;
    std::vector<Json> objects;
    for (const auto* name : {"background", "occluder", "reader"}) {
        ImageLayer layer;
        layer.id = static_cast<int>(objects.size()) + 1;
        layer.name = name;
        layer.model = package.AddImageModel(name, "util/white", {.blending="normal",
            .shader=std::string(name)=="reader" ? "depth_reader" : "depth_black"});
        layer.origin = {32,32,0}; layer.size = {64,64};
        objects.push_back(ImageLayerJson(layer));
    }
    package.SetProject(); package.SetScene(SceneJson(general, objects));
}

rg::NodeID AddDraw(rg::RenderGraph& graph, SceneNode* node, uint32_t samples,
             bool clears, bool writes_depth, bool reads_depth) {
    const auto* pass=graph.addPass<rg::DrawPass>(node->Name(), rg::PassNode::Type::CustomShader,
        [&](rg::RenderGraphBuilder& builder, rg::DrawPass::Desc& desc) {
            desc.node = node; desc.output = reads_depth ? "_rt_volume_depth_probe" : std::string(SpecTex_Default);
            desc.clear_on_first_use = clears; desc.preserve_target_contents = !clears;
            desc.samples = reads_depth ? 1 : samples;
            desc.force_single_sample = reads_depth;
            desc.depth_override = SceneDepthState{writes_depth,writes_depth,DepthCompare::LessEqual};
            if (reads_depth) {
                desc.textures = {"_rt_volumetricsBack"};
                builder.read(builder.createTexNode({.name="_rt_volumetricsBack",.key="_rt_volumetricsBack",.type=rg::TexNode::TexType::Imported},false));
            }
            builder.write(builder.createTexNode({.name=desc.output,.key=desc.output,.type=rg::TexNode::TexType::Imported},true));
        });
    return pass->ID();
}

TEST(VolumetricDepth, HidingTheLastOccluderClearsDepthInTheExistingScenePass) {
    WE_SKIP_WITHOUT_METAL();
    for (const bool optimize : {false,true}) for (const uint32_t samples : {1u,4u}) {
        SCOPED_TRACE(::testing::Message()<<"optimize="<<optimize<<" samples="<<samples);
        ScenePackage package; DepthScene(package);
        GpuSceneOptions options; options.width=options.height=64; options.scene_optimization=optimize;
        GpuScene scene(package,options); ASSERT_TRUE(scene.ok())<<scene.error();
        auto* background=FindNode(scene.scene().sceneGraph.get(),"background");
        auto* occluder=FindNode(scene.scene().sceneGraph.get(),"occluder");
        auto* reader=FindNode(scene.scene().sceneGraph.get(),"reader");
        ASSERT_NE(background,nullptr);ASSERT_NE(occluder,nullptr);ASSERT_NE(reader,nullptr);
        auto* output=scene.scene().FindRenderTarget(SpecTex_Default);
        ASSERT_NE(output,nullptr);output->withDepth=true;output->sample_count=samples;
        scene.scene().renderTargets["_rt_volumetricsBack"] = SceneRenderTarget{
            .width=64,.height=64,.format=TextureFormat::Depth32F,.unscaled=true,
            .initial_clear={1,1,1,1}};
        scene.scene().renderTargets["_rt_volume_depth_probe"] = SceneRenderTarget{
            .width=64,.height=64,.unscaled=true};
        reader->Mesh()->Material()->textures={"_rt_volumetricsBack"};
        rg::RenderGraph graph;
        AddDraw(graph,background,samples,true,false,false);
        const auto occlusion=AddDraw(graph,occluder,samples,false,true,false);
        const auto read=AddDraw(graph,reader,samples,true,false,true);
        graph.orderBefore(occlusion,read);
        graph.addPass<rg::CopyPass>("read depth result",rg::PassNode::Type::Copy,
            [&](rg::RenderGraphBuilder& builder,rg::CopyPass::Desc& desc) {
                desc.src="_rt_volume_depth_probe";desc.dst=std::string(SpecTex_Default);
                builder.read(builder.createTexNode({.name=desc.src,.key=desc.src,.type=rg::TexNode::TexType::Imported},false));
                builder.write(builder.createTexNode({.name=desc.dst,.key=desc.dst,.type=rg::TexNode::TexType::Imported},true));
            });
        ASSERT_TRUE(scene.renderer().compileRenderGraph(scene.scene(),graph))<<scene.renderer().lastError();
        const auto first=scene.Run(1);
        ASSERT_FALSE(first.empty())<<scene.error();
        ASSERT_GT(first.At(32,32)[0],20);ASSERT_LT(first.At(32,32)[0],235);
        const auto visible_passes=scene.LastFramePasses().render_passes;
        EXPECT_TRUE(ExpectSamePicture(first,scene.Run(1)));
        if (optimize) EXPECT_EQ(scene.LastFramePasses().total(),0u);
        occluder->SetVisible(false);
        const auto hidden=scene.Run(1);
        ASSERT_FALSE(hidden.empty())<<scene.error();
        EXPECT_GE(hidden.At(32,32)[0],254);
        std::vector<float> depth;
        Image actual_depth;
        ASSERT_TRUE(scene.ReadRenderTarget("_rt_volumetricsBack",&actual_depth,&depth));
        EXPECT_FLOAT_EQ(depth.at((32u*64u+32u)*4),1.0f);
        EXPECT_LE(scene.LastFramePasses().render_passes,visible_passes);
        EXPECT_TRUE(ExpectSamePicture(hidden,scene.Run(1)));
        if (optimize) EXPECT_EQ(scene.LastFramePasses().total(),0u);
        occluder->SetVisible(true);
        EXPECT_TRUE(ExpectSamePicture(first,scene.Run(1)));
    }
}

TEST(VolumetricDepth, ASceneWithoutVolumeDepthKeepsItsSingleColorPassAndIdleReuse) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package; DepthScene(package);
    GpuScene scene(package,{.width=64,.height=64});ASSERT_TRUE(scene.ok())<<scene.error();
    const auto original_bytes=scene.renderer().RenderTargetBytesForTests();
    const auto original_targets=scene.RenderTargetNames();
    auto* background=FindNode(scene.scene().sceneGraph.get(),"background");
    ASSERT_NE(background,nullptr);
    rg::RenderGraph graph;AddDraw(graph,background,1,true,false,false);
    ASSERT_TRUE(scene.renderer().compileRenderGraph(scene.scene(),graph))<<scene.renderer().lastError();
    ASSERT_FALSE(scene.Run(1).empty());
    EXPECT_EQ(scene.LastFramePasses().render_passes,1u);
    EXPECT_EQ(scene.renderer().RenderTargetBytesForTests(),original_bytes);
    EXPECT_EQ(scene.RenderTargetNames(),original_targets);
    for (const auto& name : original_targets) EXPECT_EQ(name.find("_rt_volumetrics"),std::string::npos);
    ASSERT_FALSE(scene.Run(1).empty());EXPECT_EQ(scene.LastFramePasses().total(),0u);
}
}
