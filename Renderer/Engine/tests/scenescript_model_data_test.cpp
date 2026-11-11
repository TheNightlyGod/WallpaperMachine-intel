#include "scenescript_scenes.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneNode.h"

#include <gtest/gtest.h>

namespace {
using namespace we_test;
using namespace wallpaper;

void ModelMaterial(ScenePackage& package) {
    package.AddShader("model_data_probe",
        "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\n"
        "void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}\n",
        "void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}\n");
    package.PutJson("materials/model_data_probe.json", {{"passes",Json::array({{
        {"shader","model_data_probe"},{"blending","normal"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
}

SceneNode* Named(ScriptScene& scene, std::string_view name) {
    std::vector<SceneNode*> nodes {scene.scene().sceneGraph.get()};
    for (std::size_t i=0;i<nodes.size();++i) {
        if (scene.runtime().LayerAuthoredName(nodes[i]->Name())==name) return nodes[i];
        for (const auto& child:nodes[i]->GetChildren()) nodes.push_back(child.get());
    }
    return nullptr;
}

void PublishModelScript(ScenePackage& package, const std::string& script) {
    ModelMaterial(package);
    auto host=GroupJson(1,"controller",{0,0,0});
    host["origin"]=ScriptedValue(script,"0 0 0");
    Publish(package,{host});
}

TEST(ModelDataGeometry, UInt16TriangleDrawCountSurvivesACopy) {
    SceneIndexArray indices(1,SceneIndexWidth::UInt16);
    const std::array<uint16_t,3> triangle {0,1,2};
    indices.AssignHalf(0,triangle);
    indices.SetDrawIndexCount(3);
    EXPECT_EQ(indices.DrawIndexCount(),3u);
    EXPECT_EQ(indices.DrawIndexBytes(),6u);
    const auto copy=indices.Copy();
    EXPECT_EQ(copy.Width(),SceneIndexWidth::UInt16);
    EXPECT_EQ(copy.DrawIndexCount(),3u);
    EXPECT_EQ(copy.DrawIndexBytes(),6u);
}

TEST(ScriptModelData, TypedArrayViewsCreateSharedGeometryAndApplyWithoutGraphRebuild) {
    ScenePackage package;
    PublishModelScript(package,R"JS(
const material=engine.registerAsset('materials/model_data_probe.json',true);
var model,vertices,indices,step=0;
export function init(value) {
    var storage=new Float32Array([999,999,999, 0,0,0, 20,0,0, 0,20,0, 888]);
    vertices=storage.subarray(3,12);
    indices=new Uint16Array([99,0,1,2,99]).subarray(1,4);
    model=thisScene.createModelData({shapes:[{vertexBuffer:vertices,indexBuffer:indices,
        vertexFormat:[IModelData.POSITION],material:material,isVertexBufferDynamic:true}]});
    thisScene.createLayer({model:model,name:'first',origin:new Vec3(20,20,0)});
    thisScene.createLayer({model:model,name:'second',origin:new Vec3(80,20,0)});
    return value;
}
export function update(value) {
    if (++step===2) {
        vertices[0]=7; vertices[3]=27; vertices[6]=7;
        model.applyData({vertexBuffer:vertices});
    }
    return value;
}
)JS");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    ASSERT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    auto* first=Named(scene,"first");auto* second=Named(scene,"second");
    ASSERT_NE(first,nullptr);ASSERT_NE(second,nullptr);
    ASSERT_NE(first->Mesh(),nullptr);ASSERT_NE(second->Mesh(),nullptr);
    ASSERT_EQ(first->Mesh()->Submeshes().size(),1u);
    const auto& original=first->Mesh()->GetVertexArray(0);
    EXPECT_EQ(original.VertexCount(),3u);
    EXPECT_FLOAT_EQ(original.Data()[0],0);
    EXPECT_EQ(first->Mesh()->GetIndexArray(0).Width(),SceneIndexWidth::UInt16);
    EXPECT_EQ(first->Mesh()->GetIndexArray(0).DrawIndexCount(),3u);
    const auto* storage=original.Data();
    scene.runtime().ConsumeSceneGraphMutationFlag();
    scene.Tick();
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_FLOAT_EQ(first->Mesh()->GetVertexArray(0).Data()[0],7);
    EXPECT_FLOAT_EQ(second->Mesh()->GetVertexArray(0).Data()[0],7);
    EXPECT_EQ(first->Mesh()->GetVertexArray(0).Data(),storage)
        << "applyData updates the existing storage";
    EXPECT_EQ(second->Mesh()->GetVertexArray(0).Data(),storage)
        << "instances of the same ModelData share geometry";
    EXPECT_FALSE(scene.runtime().ConsumeSceneGraphMutationFlag());
}

TEST(ScriptModelData, ApplyRejectsStaticOrIncompatibleBuffersWithoutChangingGeometry) {
    ScenePackage package;
    PublishModelScript(package,R"JS(
const material=engine.registerAsset('materials/model_data_probe.json',true);
var model,rejected=0;
export function init(value) {
    model=thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array([0,0,0,20,0,0,0,20,0]),
        vertexFormat:[IModelData.POSITION],material:material}]});
    thisScene.createLayer({model:model,name:'triangle'});
    return value;
}
export function update() {
    try { model.applyData({vertexBuffer:new Float32Array([1,0,0,21,0,0,1,20,0])}); }
    catch(e) { ++rejected; }
    return new Vec3(rejected,0,0);
}
)JS");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    ASSERT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("controller"),(std::array<float,3>{1,0,0}));
    auto* node=Named(scene,"triangle");ASSERT_NE(node,nullptr);ASSERT_NE(node->Mesh(),nullptr);
    EXPECT_FLOAT_EQ(node->Mesh()->GetVertexArray(0).Data()[0],0);
}

TEST(ScriptModelData, ReplaceIsForbiddenDuringUpdateAndLeavesTheOriginalDrawable) {
    ScenePackage package;
    PublishModelScript(package,R"JS(
const material=engine.registerAsset('materials/model_data_probe.json',true);
var model;
export function init(value) {
    model=thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array([0,0,0,20,0,0,0,20,0]),
        vertexFormat:[IModelData.POSITION],material:material,isVertexBufferDynamic:true}]});
    thisScene.createLayer({model:model,name:'triangle'});
    return value;
}
export function update() {
    var rejected=false;
    try { model.replaceData({vertexBuffer:new Float32Array([9,0,0,29,0,0,9,20,0])}); }
    catch(e) { rejected=true; }
    return new Vec3(rejected?1:0,engine.isObjectValid(model)?1:0,0);
}
)JS");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    ASSERT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("controller"),(std::array<float,3>{1,0,0}))
        << "WE's ModelData token wrapper is not a valid IObject even while a layer uses it";
    auto* node=Named(scene,"triangle");ASSERT_NE(node,nullptr);ASSERT_NE(node->Mesh(),nullptr);
    EXPECT_FLOAT_EQ(node->Mesh()->GetVertexArray(0).Data()[0],0);
}
TEST(ScriptModelData, NumericDestroyWaitsForLayersAndWrapperDestroyIsIgnored) {
    ScenePackage package;
    PublishModelScript(package,R"JS(
const material=engine.registerAsset('materials/model_data_probe.json',true);
var a,b,c,d,first,second,score=0,step=0;
function values(){return new Float32Array([0,0,0,20,0,0,0,20,0]);}
function make(){return thisScene.createModelData({shapes:[{vertexBuffer:values(),
    vertexFormat:[IModelData.POSITION],material:material,isVertexBufferDynamic:true}]});}
export function init(value){
    a=make(); b=make(); c=make(); d=make();
    first=thisScene.createLayer({model:c,name:'first'});
    second=thisScene.createLayer({model:c,name:'second'});
    thisScene.destroyModelData(a);
    thisScene.destroyModelData(b.toConfigString());
    thisScene.destroyModelData(c.toConfigString());
    thisScene.destroyModelData(d.toConfigString()+0.5);
    return value;
}
export function update(){
    if(++step===1){
        a.applyData({vertexBuffer:values()});score|=1;
        try{b.applyData({vertexBuffer:values()});}catch(e){if(e instanceof SyntaxError)score|=2;}
        c.applyData({vertexBuffer:values()});score|=4;
        d.applyData({vertexBuffer:values()});score|=8;
        thisScene.destroyLayer(first);
    } else if(step===2){
        c.applyData({vertexBuffer:values()});score|=16;
        thisScene.destroyLayer(second);
    } else if(step===3){
        try{c.applyData({vertexBuffer:values()});}catch(e){if(e instanceof SyntaxError)score|=32;}
    }
    return new Vec3(score,engine.isObjectValid(c)?1:0,0);
}
)JS");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    ASSERT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    auto* node=Named(scene,"second");
    ASSERT_NE(node,nullptr);ASSERT_NE(node->Mesh(),nullptr);
    std::weak_ptr<const void> geometry=node->Mesh()->GeometryStorage();
    scene.runtime().Tick(1.0/60.0);
    scene.runtime().Tick(1.0/60.0);
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    EXPECT_EQ(scene.Origin("controller"),(std::array<float,3>{63,0,0}));
    EXPECT_FALSE(geometry.expired()) << "the outgoing graph may still read its retired layers";
    scene.runtime().ConsumeSceneGraphMutationFlag();
    scene.Tick();
    EXPECT_TRUE(geometry.expired());
}
// createLayer's configuration is read like an object in scene.json, so its
// angles are radians; the layer's `angles` member is in degrees (setter
// 0x1401DF590). WE 2.8.0.42 draws config PI/4 and setter 45 identically.
TEST(ScriptModelData, CreateLayerConfigAnglesAreSceneFileRadians) {
    ScenePackage package;
    PublishModelScript(package,R"JS(
const material=engine.registerAsset('materials/model_data_probe.json',true);
export function init(value){
 const make=function(){return thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array([0,0,0,20,0,0,0,20,0]),
  vertexFormat:[IModelData.POSITION],material:material}]});};
 const configured=thisScene.createLayer({model:make(),name:'configured',angles:new Vec3(0,Math.PI/4,0)});
 const text=thisScene.createLayer({model:make(),name:'text',angles:'0 0 1.5'});
 const assigned=thisScene.createLayer({model:make(),name:'assigned'});
 assigned.angles=new Vec3(0,45,0);
 console.log('ANGLES '+configured.angles.y.toFixed(3)+' '+text.angles.z.toFixed(3));
 return value;
}
)JS");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    ASSERT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    auto* configured=Named(scene,"configured");
    auto* text=Named(scene,"text");
    auto* assigned=Named(scene,"assigned");
    ASSERT_NE(configured,nullptr); ASSERT_NE(text,nullptr); ASSERT_NE(assigned,nullptr);
    EXPECT_NEAR(configured->Rotation().y(),0.78539816f,1e-6f);
    EXPECT_NEAR(text->Rotation().z(),1.5f,1e-6f);
    EXPECT_NEAR(assigned->Rotation().y(),configured->Rotation().y(),1e-6f);
}

TEST(ScriptModelData, PropertyCallbackReplacesFormatsAndShapesAndKeepsLayerState) {
    ScenePackage package;
    ModelMaterial(package);
    auto host=GroupJson(1,"controller",{0,0,0});
    host["origin"]=ScriptedValue(R"JS(
const material=engine.registerAsset('materials/model_data_probe.json',true);
var model;
export function init(value){
 model=thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array([0,0,0,20,0,0,0,20,0]),
  vertexFormat:[IModelData.POSITION],material:material}]});
 thisScene.createLayer({model:model,name:'triangle',color:new Vec3(0.2,0.3,0.4),alpha:0.6});
 return value;
}
export function applyUserProperties(p){
 if(!model)return;
 if(p.revision===1) model.replaceData({shapes:[
  {vertexBuffer:new Float32Array([40,0,0,1,0,0,1, 60,0,0,0,1,0,1, 40,20,0,0,0,1,1]),
   vertexFormat:[IModelData.POSITION,IModelData.COLOR],indexBuffer:new Uint32Array([0,1,2])},
  {vertexBuffer:new Float32Array([100,0,0,120,0,0,100,20,0]),vertexFormat:[IModelData.POSITION],material:material}]});
 if(p.revision===2) model.replaceData({shapes:[null]});
}
)JS","0 0 0");
    package.SetProject({{"revision",SliderProperty(0,0,2)}});
    package.SetScene(SceneJson({}, {host}));
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    ASSERT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    auto* node=Named(scene,"triangle");ASSERT_NE(node,nullptr);
    ASSERT_TRUE(scene.SetProperty("revision",1));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    ASSERT_EQ(node->Mesh()->Submeshes().size(),2u);
    EXPECT_EQ(node->Mesh()->GetVertexArray(0).OneSize(),7u);
    EXPECT_EQ(node->Mesh()->GetIndexArray(0).Width(),SceneIndexWidth::UInt32);
    EXPECT_FLOAT_EQ(node->Mesh()->GetVertexArray(0).Data()[0],40);
    EXPECT_TRUE(scene.runtime().NodeColor(node->Name()).isApprox(linalg::Vector3f(0.2f,0.3f,0.4f)));
    EXPECT_FLOAT_EQ(scene.runtime().NodeAlpha(node->Name()).value(),0.6f);
    EXPECT_TRUE(scene.runtime().ConsumeSceneGraphMutationFlag());
    ASSERT_TRUE(scene.SetProperty("revision",2));
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    ASSERT_EQ(node->Mesh()->Submeshes().size(),1u);
    EXPECT_FLOAT_EQ(node->Mesh()->GetVertexArray(0).Data()[0],100);
}
} // namespace
