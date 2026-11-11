#include "graph_contract_support.hpp"
#include <gtest/gtest.h>
#include <map>
#include "WPShaderValueUpdater.hpp"
#include "Scene/SceneCamera.h"

namespace graph_contract {
namespace {
std::string ReflectionObjects() {
    return R"({"id":1,"name":"default","image":"models/card.json","origin":[-3,2,0],"visible":true},
      {"id":2,"name":"enabled","image":"models/card.json","origin":[0,2,0],"visible":true,"reflected":true},
      {"id":3,"name":"disabled","image":"models/card.json","origin":[3,2,0],"visible":true,"reflected":false},
      {"id":4,"name":"wrapped","image":"models/card.json","origin":[0,-2,0],"visible":true,"reflected":{"value":false}},
      {"id":5,"name":"observer","model":"models/observer.mdl","visible":true,"reflected":false})";
}
auto ReflectionAssets() {
    auto files=ordinaryAssets();
    asset(files,"/models/observer.json",R"({"width":64,"height":40,"material":"materials/observer.json"})");
    materialAsset(files,"materials/observer.json","contract_card","[\"_rt_Reflection\"]","normal");
    Bytes model;
    modelHeader(model,23);
    const std::array<uint32_t,3> indices{0,1,2};
    skinMesh(model,23,"materials/observer.json",triangle(),indices);
    model.u8(0);
    files["/models/observer.mdl"]=std::move(model.data);
    return files;
}
std::string ReflectionScene(bool hdr=false, const std::string& extra={}) {
    return std::string(R"({"camera":{"eye":"0 3 10","center":"0 0 0","up":"0 1 0"},
      "general":{"orthogonalprojection":null,"fov":50,"nearz":0.1,"farz":1000,
      "bloom":false,"cameraparallax":false,"transparentsorting":false,"clearcolor":"0.125 0.25 0.375","hdr":)")+
      (hdr?"true":"false")+"},\"objects\":["+ReflectionObjects()+extra+"]}";
}
TEST(PlanarReflection, SampledReflectionUsesRgb8AndLiteralFalseExcludesASource) {
    for(bool hdr:{false,true}) {
        ParseFixture fixture(ReflectionAssets());
        auto scene=fixture.parse(ReflectionScene(hdr));
        ASSERT_NE(scene,nullptr);
        Observation graph(*scene);
        const auto* target=scene->FindRenderTarget("_rt_Reflection");
        ASSERT_NE(target,nullptr);
        EXPECT_EQ(target->format,TextureFormat::RGBA8);
        std::vector<std::string> sources;
        for(auto id:graph.order) if(const auto* draw=dynamic_cast<const DrawPass*>(graph.graph->getPass(id))) {
            if(draw->desc().output=="_rt_Reflection") sources.push_back(draw->desc().node->Name());
        }
        EXPECT_EQ(sources,(std::vector<std::string>{"default","enabled","wrapped"}));
    }
}
TEST(PlanarReflection, DisabledQualityKeepsTheTargetAndClearsToTheSceneColour) {
    ParseFixture fixture(ReflectionAssets());
    SceneParseRequest request;request.quality.reflection=false;
    auto scene=fixture.parse(request,ReflectionScene());
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    ASSERT_NE(scene->FindRenderTarget("_rt_Reflection"),nullptr);
    EXPECT_FALSE(scene->FindRenderTarget("_rt_Reflection")->withDepth);
    std::size_t draws=0,clears=0;
    for(auto id:graph.order) {
        if(const auto* draw=dynamic_cast<const DrawPass*>(graph.graph->getPass(id)))
            draws+=draw->desc().output=="_rt_Reflection";
        if(const auto* clear=dynamic_cast<const ClearPass*>(graph.graph->getPass(id)))
            if(clear->desc().result=="_rt_Reflection") {++clears;EXPECT_FALSE(clear->desc().transparent);}
    }
    EXPECT_EQ(draws,0u);EXPECT_EQ(clears,1u);
}
TEST(PlanarReflection, AnOrdinarySceneAllocatesNoReflectionTargetOrPass) {
    ParseFixture fixture(ordinaryAssets());
    auto scene=fixture.parse(R"({"general":{"bloom":false},"objects":[{"id":1,"name":"source","image":"models/card.json","visible":true}]})");
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    EXPECT_EQ(scene->FindRenderTarget("_rt_Reflection"),nullptr);
}

TEST(PlanarReflection, ReflectionSamplingExcludesModelsButNotImageLayers) {
    auto files=ReflectionAssets();
    Bytes model;
    modelHeader(model,23);
    const std::array<uint32_t,3> indices{0,1,2};
    skinMesh(model,23,"materials/observer.json",triangle(),indices);
    model.u8(0);
    files["/models/reflective.mdl"]=std::move(model.data);
    ParseFixture fixture(std::move(files));
    auto scene=fixture.parse(ReflectionScene(false,
        R"(,{"id":6,"name":"reflective-model","model":"models/reflective.mdl","visible":true},
          {"id":7,"name":"reflective-image","image":"models/observer.json","visible":true})"));
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    std::vector<std::string> reflected;
    for(auto id:graph.order) if(const auto* draw=dynamic_cast<const DrawPass*>(graph.graph->getPass(id)))
        if(draw->desc().output=="_rt_Reflection") reflected.push_back(draw->desc().node->Name());
    EXPECT_EQ(std::count(reflected.begin(),reflected.end(),"reflective-model"),0);
    EXPECT_EQ(std::count(reflected.begin(),reflected.end(),"reflective-image"),1);
    EXPECT_FALSE(graph.order.empty());
}

TEST(PlanarReflection, AnInactiveReflectionSlotAddsNoReflectedDraws) {
    auto files=ReflectionAssets();
    asset(files,"/shaders/contract_card.frag","void main(){gl_FragColor=vec4(1.0,1.0,1.0,1.0);}");
    ParseFixture fixture(std::move(files));
    auto scene=fixture.parse(ReflectionScene());
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    for(auto id:graph.order) if(const auto* draw=dynamic_cast<const DrawPass*>(graph.graph->getPass(id)))
        EXPECT_NE(draw->desc().output,"_rt_Reflection");
    EXPECT_FALSE(scene->reflection.requested);
}
TEST(PlanarReflection, AnImageSamplerAloneDoesNotRequestTheNativeReflectionPass) {
    ParseFixture fixture(ReflectionAssets());
    auto scene=fixture.parse(R"({"general":{"bloom":false},"objects":[
        {"id":1,"name":"reader","image":"models/observer.json","visible":true}]})");
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    EXPECT_FALSE(scene->reflection.requested);
    for(auto id:graph.order) if(const auto* draw=dynamic_cast<const DrawPass*>(graph.graph->getPass(id))) {
        EXPECT_NE(draw->desc().output,"_rt_Reflection");
        EXPECT_EQ(std::count(draw->desc().textures.begin(),draw->desc().textures.end(),"_rt_Reflection"),0);
    }
}
TEST(PlanarReflection, ALoadedHiddenModelStillEnablesThePictureForAnImageReader) {
    ParseFixture fixture(ReflectionAssets());
    auto document = ReflectionScene(false,
        R"(,{"id":7,"name":"reader","image":"models/observer.json","visible":true,"reflected":false})");
    const auto observer = document.find("\"name\":\"observer\"");
    ASSERT_NE(observer,std::string::npos);
    const auto visible = document.find("\"visible\":true",observer);
    document.replace(visible,14,R"("visible":false,"origin":{"value":"0 0 0","script":"export function update(value) { return value; }"})");
    auto scene = fixture.parse(document);
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    EXPECT_TRUE(scene->reflection.requested);
    std::size_t reflected = 0;
    for (auto id : graph.order) if (const auto* draw=dynamic_cast<const DrawPass*>(graph.graph->getPass(id))) {
        EXPECT_NE(draw->desc().node->Name(),"observer");
        reflected += draw->desc().output == "_rt_Reflection";
    }
    EXPECT_GT(reflected,0u);
}

TEST(PlanarReflection, ReflectedShaderEyeAndAxesKeepTheNativeForwardVector) {
    ParseFixture fixture(ReflectionAssets());
    auto scene=fixture.parse(ReflectionScene());
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    ASSERT_NE(scene->reflection.camera,nullptr);
    const auto* normal=scene->activeCamera;
    const auto* reflected=scene->reflection.camera.get();
    EXPECT_GT(std::abs(normal->GetDirection().y()),0.1);
    // Camera geometry is mirrored; only the shader's view-forward binding keeps
    // the original view direction in WE's reflected branch.
    SceneNode* source=nullptr;
    for(const auto& node:scene->sceneGraph->GetChildren())
        if(node->Name()=="default") source=node.get();
    ASSERT_NE(source,nullptr);
    WPShaderValueUpdater updater(scene.get());
    updater.InitUniforms(source,[](std::string_view name) {
        return name=="g_ViewForward" || name=="g_ViewUp" || name=="g_EyePosition";
    });
    source->SetCamera(std::string(kReflectionCamera));
    sprite_map_t sprites;
    std::map<std::string,std::vector<float>> values;
    // Match the renderer's phase-local active-camera swap too.
    scene->activeCamera=scene->reflection.camera.get();
    updater.UpdateUniforms(source,sprites,[&](std::string_view name,const ShaderValue& value) {
        values[std::string(name)]={value.data(),value.data()+value.size()};
    });
    scene->activeCamera=const_cast<SceneCamera*>(normal);
    ASSERT_EQ(values["g_ViewForward"].size(),3u);
    EXPECT_NEAR(values["g_ViewForward"][1],normal->GetDirection().y(),1e-6);
    EXPECT_NEAR(values["g_ViewUp"][1],-normal->GetUp().y(),1e-6);
    EXPECT_NEAR(values["g_EyePosition"][1],-normal->GetPosition().y(),1e-6);
    EXPECT_NEAR(reflected->GetUp().y(),-normal->GetUp().y(),1e-6);
    EXPECT_NEAR(reflected->GetPosition().y(),-normal->GetPosition().y(),1e-6);
    EXPECT_TRUE(reflected->GetViewMatrix().allFinite());
}

TEST(PlanarReflection, AnUnusedSlotDoesNotEnableThePicture) {
    auto files=ReflectionAssets();
    materialAsset(files,"materials/observer.json","contract_card","[\"util/white\",\"_rt_Reflection\"]","normal");
    ParseFixture fixture(std::move(files));
    auto scene=fixture.parse(ReflectionScene());
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    EXPECT_FALSE(scene->reflection.requested);
}

TEST(PlanarReflection, AnUndrawnMaterialSlotDoesNotEnableThePicture) {
    auto files=ReflectionAssets();
    materialAsset(files,"materials/observer.json","contract_card","[\"util/white\"]","normal");
    ParseFixture fixture(std::move(files));
    auto scene=fixture.parse(ReflectionScene());
    ASSERT_NE(scene,nullptr);
    for(const auto& node:scene->sceneGraph->GetChildren()) if(node->Name()=="observer") {
        SceneMaterial caster;
        caster.textures.push_back("_rt_Reflection");
        node->Mesh()->AddMaterial(std::move(caster));
    }
    Observation graph(*scene);
    EXPECT_FALSE(scene->reflection.requested);
}
TEST(PlanarReflection, AHiddenModelIsRetainedWhenAnImageReadsTheReflection) {
    ParseFixture fixture(ReflectionAssets());
    auto document=ReflectionScene(false,
        R"(,{"id":7,"name":"reader","image":"models/observer.json","visible":true,"reflected":false})");
    const auto observer=document.find("\"name\":\"observer\"");
    const auto visible=document.find("\"visible\":true",observer);
    document.replace(visible,14,"\"visible\":false");
    auto scene=fixture.parse(document);
    ASSERT_NE(scene,nullptr);
    Observation graph(*scene);
    EXPECT_TRUE(scene->reflection.requested);
}

TEST(PlanarReflection, DisplayFramingPrecedesTheReflectionFramebufferFlip) {
    ParseFixture fixture(ReflectionAssets());
    auto scene=fixture.parse(ReflectionScene(true));
    ASSERT_NE(scene,nullptr);
    scene->display_framed=true;
    scene->display_clip={1.8,1.2,0.23,-0.37};
    ++scene->display_clip_generation;
    Observation graph(*scene);
    ASSERT_NE(scene->reflection.camera,nullptr);
    auto mirror=linalg::Matrix4d::Identity().eval();
    mirror(1,1)=-1;
    const auto source=scene->activeCamera->GetRasterViewProjectionMatrix(
        scene->display_clip,scene->display_clip_generation);
    const linalg::Matrix4d expected=mirror*source*mirror;
    const auto actual=scene->reflection.camera->GetRasterViewProjectionMatrix(
        scene->display_clip,scene->display_clip_generation);
    EXPECT_TRUE(actual.isApprox(expected));
}

}
}
