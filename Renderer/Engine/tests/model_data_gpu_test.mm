#include "support/gpu_scene.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "MetalRender/MetalRender.hpp"

#include <gtest/gtest.h>

namespace {
using namespace we_test;

TEST(ModelDataGpu, SharedTypedGeometryMovesBothLayersWithoutRebuilding) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    package.InstallStandardAssets();
    package.AddShader("model_data_triangle",
        "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\n"
        "void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}\n",
        "void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}\n");
    package.PutJson("materials/model_data_triangle.json",{{"passes",Json::array({{
        {"shader","model_data_triangle"},{"blending","normal"},{"cullmode","normal"},
        {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
    const auto script=R"JS(
const material=engine.registerAsset('materials/model_data_triangle.json',true);
var model,vertices,step=0;
export function init(value) {
    vertices=new Float32Array([-20,-20,0,20,-20,0,0,20,0]);
    model=thisScene.createModelData({shapes:[{vertexBuffer:vertices,
        indexBuffer:new Uint16Array([0,1,2]),vertexFormat:[IModelData.POSITION],
        material:material,isVertexBufferDynamic:true}],
        boundingBoxMins:new Vec3(-30,-30,-1),boundingBoxMaxs:new Vec3(60,30,1)});
    thisScene.createLayer({model:model,name:'first',origin:new Vec3(40,60,0)});
    thisScene.createLayer({model:model,name:'second',origin:new Vec3(105,60,0)});
    return value;
}
export function update(value) {
    if (++step===2) {
        vertices[0]+=25;vertices[3]+=25;vertices[6]+=25;
        model.applyData({vertexBuffer:vertices});
    }
    return value;
}
)JS";
    auto host=GroupJson(1,"host",{0,0,0});
    host["origin"]=ScriptedValue(script,"0 0 0");
    ImageLayer control;
    control.id=2;control.name="control";control.model=package.AddImageModel("control");
    control.origin={8,112,0};control.size={8,8};control.color="0 1 1";
    SceneGeneral general;general.canvas_width=160;general.canvas_height=120;
    package.SetProject();package.SetScene(SceneJson(general,{host,ImageLayerJson(control)}));
    GpuScene scene(package,{.width=160,.height=120});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto before=scene.Run(1);
    ASSERT_FALSE(before.empty()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(before,6,6,4,4,{0,255,255,255},1));
    EXPECT_TRUE(ExpectRegionAverage(before,38,58,4,4,{255,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(before,103,58,4,4,{255,0,0,255},1));
    const int builds=scene.RebuildCount();
    const auto after=scene.Run(1);
    ASSERT_FALSE(after.empty()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(after,38,58,4,4,{0,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(after,63,58,4,4,{255,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(after,128,58,4,4,{255,0,0,255},1));
    EXPECT_EQ(scene.RebuildCount(),builds);
}
TEST(ModelDataGpu, InstancesShareGpuGeometryAndUploadEachGenerationOnce) {
    WE_SKIP_WITHOUT_METAL();
    uint64_t bytes[2]{},uploads[2]{};
    for (int trial=0;trial<2;++trial) {
        ScenePackage package;
        package.InstallStandardAssets();
        package.AddShader("shared_model_data",
            "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\n"
            "void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}\n",
            "void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}\n");
        package.PutJson("materials/shared_model_data.json",{{"passes",Json::array({{
            {"shader","shared_model_data"},{"blending","normal"},{"cullmode","nocull"},
            {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
        const auto script=std::string(R"JS(
const material=engine.registerAsset('materials/shared_model_data.json',true);
export function init(value) {
    var model=thisScene.createModelData({shapes:[{
        vertexBuffer:new Float32Array([-20,-20,0,20,-20,0,0,20,0]),
        indexBuffer:new Uint16Array([0,1,2]),vertexFormat:[IModelData.POSITION],
        material:material,isVertexBufferDynamic:true}]});
    for(var i=0;i<)JS")+std::to_string(trial?8:1)+R"JS(;i++)
        thisScene.createLayer({model:model,origin:new Vec3(80,60,0)});
    return value;
}
)JS";
        auto host=GroupJson(1,"host",{0,0,0});
        host["origin"]=ScriptedValue(script,"0 0 0");
        SceneGeneral general;general.canvas_width=160;general.canvas_height=120;
        ImageLayer control;
        control.id=2;control.name="control";control.model=package.AddImageModel("control");
        control.origin={8,112,0};control.size={8,8};control.color="0 1 1";
        package.SetProject();package.SetScene(SceneJson(general,{host,ImageLayerJson(control)}));
        GpuScene scene(package,{.width=160,.height=120});
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto picture=scene.Run(1);
        EXPECT_TRUE(ExpectRegionAverage(picture,78,58,4,4,{255,0,0,255},1));
        bytes[trial]=scene.renderer().GeometryBufferBytesForTests();
        uploads[trial]=scene.renderer().ModelDataUploadBytesForTests();
    }
    EXPECT_GT(bytes[0],0u);
    EXPECT_EQ(bytes[1],bytes[0]);
    EXPECT_EQ(uploads[1],uploads[0]);
}
TEST(ModelDataGpu, ASceneWithOnlyInitCreatedGeometryCanStartDrawing) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    package.AddShader("only_model_data",
        "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\n"
        "void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}\n",
        "void main(){gl_FragColor=vec4(0.0,1.0,0.0,1.0);}\n");
    package.PutJson("materials/only_model_data.json",{{"passes",Json::array({{
        {"shader","only_model_data"},{"blending","normal"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
    auto host=GroupJson(1,"host",{0,0,0});
    host["origin"]=ScriptedValue(R"JS(
const material=engine.registerAsset('materials/only_model_data.json',true);
export function init(value){
 var model=thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array([-20,-20,0,20,-20,0,0,20,0]),
     vertexFormat:[IModelData.POSITION],material:material}]});
 thisScene.createLayer({model:model,origin:new Vec3(80,60,0)});
 return value;
}
)JS","0 0 0");
    SceneGeneral general;general.canvas_width=160;general.canvas_height=120;
    package.SetProject();package.SetScene(SceneJson(general,{host}));
    GpuScene scene(package,{.width=160,.height=120});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto picture=scene.Run(1);
    ASSERT_FALSE(picture.empty()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(picture,78,58,4,4,{0,255,0,255},1));
}
TEST(ModelDataGpu, EventReplacementUpdatesSharedLayersAndCanRemoveEveryShape) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    package.AddShader("replace_model_data",
        "uniform mat4 g_ModelViewProjectionMatrix;\nattribute vec3 a_Position;\n"
        "void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}\n",
        "void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}\n");
    package.PutJson("materials/replace_model_data.json",{{"passes",Json::array({{
        {"shader","replace_model_data"},{"blending","normal"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
    auto host=GroupJson(1,"host",{0,0,0});
    host["origin"]=ScriptedValue(R"JS(
const material=engine.registerAsset('materials/replace_model_data.json',true);
var model;
export function init(value){
 model=thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array([-20,-20,0,20,-20,0,0,20,0]),
  vertexFormat:[IModelData.POSITION],material:material}]});
 thisScene.createLayer({model:model,origin:new Vec3(40,60,0)});
 thisScene.createLayer({model:model,origin:new Vec3(105,60,0)});
 return value;
}
export function applyUserProperties(p){
 if(!model)return;
 if(p.revision===1) model.replaceData({vertexBuffer:new Float32Array([
  15,-10,0,35,-10,0,35,10,0, 15,-10,0,35,10,0,15,10,0])});
 if(p.revision===2) model.replaceData({shapes:[null]});
}
)JS","0 0 0");
    SceneGeneral general;general.canvas_width=160;general.canvas_height=120;
    package.SetProject({{"revision",SliderProperty(0,0,2)}});
    package.SetScene(SceneJson(general,{host}));
    GpuScene scene(package,{.width=160,.height=120});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto before=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(before,38,58,4,4,{255,0,0,255},1));
    ASSERT_TRUE(scene.SetProperty("revision",1));
    const auto after=scene.Run(1);
    ASSERT_FALSE(after.empty()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(after,38,58,4,4,{0,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(after,63,58,4,4,{255,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(after,128,58,4,4,{255,0,0,255},1));
    ASSERT_TRUE(scene.SetProperty("revision",2));
    const auto empty=scene.Run(1);
    ASSERT_FALSE(empty.empty()) << scene.error();
    EXPECT_TRUE(ExpectRegionAverage(empty,63,58,4,4,{0,0,0,255},1));
}
TEST(ModelDataGpu, CanonicalStreamsKeepTheirLayoutWhenDeclarationsAreReversed) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    package.AddShader("model_data_streams",
        "attribute vec3 a_Position;\nattribute vec3 a_Normal;\nattribute vec4 a_Tangent4;\n"
        "attribute vec2 a_TexCoord;\nattribute vec4 a_Color;\nuniform mat4 g_ModelViewProjectionMatrix;\n"
        "varying vec3 v_Color;\nvoid main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);"
        "v_Color=vec3(a_Normal.x+a_Tangent4.y+a_Color.z,a_Normal.y+a_Tangent4.z+a_TexCoord.x,"
        "a_Normal.z+a_Tangent4.w+a_TexCoord.y+a_Color.x);}\n",
        "varying vec3 v_Color;\nvoid main(){gl_FragColor=vec4(v_Color,1.0);}\n");
    package.PutJson("materials/model_data_streams.json",{{"passes",Json::array({{
        {"shader","model_data_streams"},{"blending","normal"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
    auto host=GroupJson(1,"host",{0,0,0});
    host["origin"]=ScriptedValue(R"JS(
const material=engine.registerAsset('materials/model_data_streams.json',true);
export function init(value) {
    const vertices=[];
    for(const p of [[-20,-20,0],[20,-20,0],[0,20,0]])
        vertices.push(...p,0.1,0.15,0.1,0.4,0.2,0.25,0.2,0.35,0.15,0.25,0.4,0.3,1);
    const format=[IModelData.POSITION,IModelData.NORMAL,IModelData.TANGENT_SIGNED,IModelData.UV,IModelData.COLOR];
    for(let i=0;i<2;++i) {
        const model=thisScene.createModelData({shapes:[{vertexBuffer:new Float32Array(vertices),
            vertexFormat:i?format.slice().reverse():format,material:material}]});
        thisScene.createLayer({model:model,origin:new Vec3(40+80*i,60,0),castshadow:false});
    }
    return value;
}
)JS","0 0 0");
    SceneGeneral general;general.canvas_width=160;general.canvas_height=120;
    package.SetProject();package.SetScene(SceneJson(general,{host}));
    GpuScene scene(package,{.width=160,.height=120});
    ASSERT_TRUE(scene.ok())<<scene.error();
    const auto picture=scene.Run(1);
    ASSERT_FALSE(picture.empty());
    // Native WE witnesses use every canonical stream, including signed tangent
    // and vertex colour, and retain this packing for the reversed declaration.
    EXPECT_TRUE(ExpectRegionAverage(picture,38,58,4,4,{153,191,179,255},1));
    EXPECT_TRUE(ExpectRegionAverage(picture,118,58,4,4,{153,191,179,255},1));
}

TEST(ModelDataGpu, WideIndicesAndSeparateShapesDrawTheirSelectedVertices) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    const char* vertex="attribute vec3 a_Position;\nuniform mat4 g_ModelViewProjectionMatrix;\n"
        "void main(){gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}\n";
    for(const auto& [name,colour]:std::vector<std::pair<std::string,std::string>>{
            {"yellow","1.0,1.0,0.0"},{"red","1.0,0.0,0.0"},{"blue","0.0,0.0,1.0"}}) {
        package.AddShader("model_data_"+name,vertex,
            "void main(){gl_FragColor=vec4("+colour+",1.0);}\n");
        package.PutJson("materials/model_data_"+name+".json",{{"passes",Json::array({{
            {"shader","model_data_"+name},{"blending","normal"},{"cullmode","nocull"},
            {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
    }
    auto host=GroupJson(1,"host",{0,0,0});
    host["origin"]=ScriptedValue(R"JS(
const yellow=engine.registerAsset('materials/model_data_yellow.json',true);
const red=engine.registerAsset('materials/model_data_red.json',true);
const blue=engine.registerAsset('materials/model_data_blue.json',true);
function vertices(x){return new Float32Array([-16+x,-16,0,16+x,-16,0,x,16,0]);}
export function init(value) {
    const wide=new Float32Array(65539*3);
    wide.set(vertices(0),65536*3);
    const first=thisScene.createModelData({shapes:[{vertexBuffer:wide,
        indexBuffer:new Uint32Array([65536,65537,65538]),
        vertexFormat:[IModelData.POSITION],material:yellow}]});
    thisScene.createLayer({model:first,origin:new Vec3(40,60,0),castshadow:false});
    const second=thisScene.createModelData({shapes:[
        {vertexBuffer:vertices(-25),vertexFormat:[IModelData.POSITION],material:red},
        {vertexBuffer:vertices(25),vertexFormat:[IModelData.POSITION],material:blue}]});
    thisScene.createLayer({model:second,origin:new Vec3(120,60,0),castshadow:false});
    return value;
}
)JS","0 0 0");
    SceneGeneral general;general.canvas_width=180;general.canvas_height=120;
    package.SetProject();package.SetScene(SceneJson(general,{host}));
    GpuScene scene(package,{.width=180,.height=120});
    ASSERT_TRUE(scene.ok())<<scene.error();
    const auto picture=scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(picture,38,58,4,4,{255,255,0,255},0));
    EXPECT_TRUE(ExpectRegionAverage(picture,93,58,4,4,{255,0,0,255},0));
    EXPECT_TRUE(ExpectRegionAverage(picture,143,58,4,4,{0,0,255,255},0));
}

} // namespace
