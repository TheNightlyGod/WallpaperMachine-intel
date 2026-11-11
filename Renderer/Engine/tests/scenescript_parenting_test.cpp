#include "scenescript_scenes.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "WPShaderValueUpdater.hpp"

#include <gtest/gtest.h>

namespace {
using namespace we_test;
namespace linalg = wallpaper::linalg;

void MakeParentScene(ScenePackage& package, const std::string& script,
                     const Json& child_extra = Json::object()) {
    const auto model = package.AddImageModel("plain");
    auto child = PlainImage(model, 20, "child", {
        {"origin","10 20 3"},{"scale","1 0.5 2"},
        {"visible",ScriptedValue("var once=false;export function update(v){"
            "if(!once){once=true;"+script+"}return v;}",true)}});
    for (const auto& [key,value] : child_extra.items()) child[key]=value;
    Publish(package, {
        PlainImage(model, 100, "parent", {{"origin","100 50 0"},{"scale","2 2 2"},
            {"angles","0 0 1.5707963267948966"}}), child});
}

TEST(ScriptParenting, NameObjectAndSceneIndexSelectTheSameParent) {
    for (const std::string target : {"'parent'", "thisScene.getLayer('parent')", "0"}) {
        ScenePackage package;
        MakeParentScene(package,"thisLayer.setParent("+target+");");
        ScriptScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        scene.Tick();
        EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
        const auto world=scene.runtime().NodeTransformMatrix("child");
        EXPECT_NEAR(world(0,3),60,1e-4);
        EXPECT_NEAR(world(1,3),70,1e-4);
        EXPECT_NEAR(world(2,3),6,1e-4);
        EXPECT_EQ(scene.Origin("child"),(std::array<float,3>{10,20,3}));
    }
}

TEST(ScriptParenting, BothKeepWorldOverloadsPreserveTheWorldTransform) {
    for (const char* arguments : {"'parent',true", "'parent',undefined,true"}) {
        ScenePackage package;
        MakeParentScene(package,std::string("thisLayer.setParent(")+arguments+");");
        ScriptScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto before=scene.runtime().NodeTransformMatrix("child");
        scene.Tick();
        EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
        EXPECT_TRUE(scene.runtime().NodeTransformMatrix("child").isApprox(before,1e-5));
        const auto origin=scene.Origin("child");
        EXPECT_NEAR(origin[0],-15,1e-4);
        EXPECT_NEAR(origin[1],45,1e-4);
        EXPECT_NEAR(origin[2],1.5,1e-4);
    }
}

TEST(ScriptParenting, DetachingKeepsWorldAndReturnsANullParent) {
    for (const char* target : {"undefined","null"}) {
        ScenePackage package;
        MakeParentScene(package,std::string("thisLayer.setParent(")+target+",true);"
            "if(thisLayer.getParent()!==null)throw new Error('still parented');",{{"parent",100}});
        ScriptScene scene(package);
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto before=scene.runtime().NodeTransformMatrix("child");
        scene.Tick();
        EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
        EXPECT_TRUE(scene.runtime().NodeTransformMatrix("child").isApprox(before,1e-5));
    }
}

TEST(ScriptParenting, AncestorCyclesAreRejectedAndSelfParentingDetachesBeforeThrowing) {
    ScenePackage package;
    MakeParentScene(package,R"JS(
var parent=thisScene.getLayer('parent');
thisLayer.setParent(parent);
var caught=0;
try { parent.setParent(thisLayer); } catch(e) { ++caught; }
if(caught!==1 || thisLayer.getParent()!==parent || parent.getParent()!==null)
    throw new Error('cycle changed the hierarchy');
try { thisLayer.setParent(thisLayer); } catch(e) { ++caught; }
if(caught!==2 || thisLayer.getParent()!==null || parent.getParent()!==null)
    throw new Error('self parenting did not detach');
)JS");
    ScriptScene scene(package);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick();
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
    const auto world=scene.runtime().NodeTransformMatrix("child");
    EXPECT_NEAR(world(0,3),10,1e-4);
    EXPECT_NEAR(world(1,3),20,1e-4);
}

TEST(ScriptParenting, AParentIndexMustBeAnInteger) {
    ScenePackage package;
    MakeParentScene(package,"thisLayer.setParent('parent');thisLayer.setParent(0.9);"
        "if(thisLayer.getParent()!==null)throw new Error('fractional index was truncated');");
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();scene.Tick();
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

namespace {
void MakeCompositionHierarchy(ScenePackage& package, int destination_depth,
                              int subtree_depth, bool ordinary_root=false,
                              bool parallel_children=false, bool copy_background=false) {
    const auto plain=package.AddImageModel("composition_leaf");
    package.PutJson("materials/util/effectpassthrough.json",{{"passes",Json::array({{
        {"shader","harness_image"},{"textures",Json::array({nullptr})},
        {"blending","translucent"},{"cullmode","nocull"},
        {"depthtest","disabled"},{"depthwrite","disabled"}}})}});
    package.PutJson("models/util/composelayer.json",{{"material","materials/composition_leaf.json"},
        {"passthrough",true},{"width",16},{"height",16}});
    std::vector<Json> objects {GroupJson(1,"old",{0,0,0})};
    const auto layer=[&](int id, const std::string& name, int parent, bool composition) {
        return PlainImage(composition ? "models/util/composelayer.json" : plain,id,name,
            {{"parent",parent},{"copybackground",copy_background},{"size","16 16"},{"origin","3 5 0"}});
    };
    int parent=0;
    for(int depth=0;depth<destination_depth;++depth) {
        const int id=10+depth;
        objects.push_back(layer(id,depth+1==destination_depth ? "destination" : "ancestor"+std::to_string(depth),parent,true));
        parent=id;
    }
    objects.push_back(layer(20,"destination_child",parent,false));
    objects.push_back(layer(30,"moving",1,subtree_depth>0 && !ordinary_root));
    parent=30;
    const int children=subtree_depth-(ordinary_root ? 0 : 1);
    for(int depth=0;depth<children;++depth) {
        const int id=40+depth;
        objects.push_back(layer(id,"nested"+std::to_string(depth),parallel_children ? 30 : parent,true));
        objects.push_back(layer(60+depth,"nested_leaf"+std::to_string(depth),id,false));
        parent=id;
    }
    if(subtree_depth>0 && children<=0) objects.push_back(layer(70,"moving_child",30,false));
    Publish(package,objects);
}
}

TEST(ScriptParenting, CompositionDepthUsesTheDeepestMovedBranchAndAllowsThreeBoundaries) {
    for(int destination_depth:{1,2}) {
        SCOPED_TRACE(destination_depth);
        ScenePackage package;MakeCompositionHierarchy(package,destination_depth,2);
        ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
        EXPECT_EQ(scene.runtime().SetNodeParent("moving","destination"),destination_depth==1);
        EXPECT_EQ(scene.runtime().NodeParentName("moving"),destination_depth==1 ? "destination" : "");
        EXPECT_EQ(scene.Origin("moving"),(std::array<float,3>{3,5,0}));
    }
}

TEST(ScriptParenting, ParallelCompositionChildrenDoNotAddTheirDepthsTogether) {
    ScenePackage package;MakeCompositionHierarchy(package,2,2,true,true);
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_TRUE(scene.runtime().SetNodeParent("moving","destination"));
    EXPECT_EQ(scene.runtime().NodeParentName("moving"),"destination");
}

TEST(ScriptParenting, RawPassthroughModelsCountWithoutAPrivateCompositionCamera) {
    for(int depth:{2,3}) {
        SCOPED_TRACE(depth);
        ScenePackage package;MakeCompositionHierarchy(package,depth,1,false,false,true);
        ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
        EXPECT_EQ(scene.runtime().SetNodeParent("moving","destination"),depth==2);
        EXPECT_EQ(scene.runtime().NodeParentName("moving"),depth==2 ? "destination" : "");
    }
}

TEST(ScriptParenting, OrdinaryImageEffectCamerasDoNotConsumeTheParentingBudget) {
    ScenePackage package;const auto model=package.AddImageModel("ordinary_effect_parent");
    const auto effect=package.AddTintEffect("ordinary_parent_copy");
    std::vector<Json> objects;
    for(int i=0;i<4;++i) objects.push_back(PlainImage(model,i+1,"effect"+std::to_string(i),
        {{"parent",i},{"size","16 16"}}, {EffectUse(effect,Json::object(),100+i)}));
    objects.push_back(PlainImage(model,20,"moving"));
    Publish(package,objects);
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
    ASSERT_EQ(scene.runtime().LayerEffectCount("effect3"),1u);
    EXPECT_TRUE(scene.runtime().SetNodeParent("moving","effect3"));
    EXPECT_EQ(scene.runtime().NodeParentName("moving"),"effect3");
}

TEST(ScriptParenting, ARegistrationRollbackPreservesTheModelsParentingBoundary) {
    ScenePackage package;MakeCompositionHierarchy(package,3,1,false,false,true);
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
    auto& runtime=scene.runtime();
    const auto prior=runtime.CaptureNodeRegistration("destination");
    auto replacement=std::make_shared<wallpaper::SceneNode>();
    replacement->SetName("destination");
    runtime.RegisterNode("destination",replacement.get());
    runtime.RegisterImageLayerFlags("destination",replacement.get(),{},{});
    runtime.RollbackNodeRegistration("destination",replacement.get(),prior);
    EXPECT_FALSE(runtime.SetNodeParent("moving","destination"));
    EXPECT_TRUE(runtime.NodeParentName("moving").empty());
}

TEST(ScriptParenting, SortingChangesKeepTheParentingLimitAndOrdinaryNodesUnmarked) {
    ScenePackage package;MakeCompositionHierarchy(package,3,1,false,false,true);
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
    const auto find=[](const auto& self,wallpaper::SceneNode* node,std::string_view name) -> wallpaper::SceneNode* {
        if(node->Name()==name)return node;
        for(const auto& child:node->GetChildren())if(auto* found=self(self,child.get(),name))return found;
        return nullptr;
    };
    auto* moving=find(find,scene.scene().sceneGraph.get(),"moving");
    ASSERT_NE(moving,nullptr);
    using Kind=wallpaper::SceneNode::TransparentSort;
    for(const auto kind:{Kind::Unmarked,Kind::Depth,Kind::Last,Kind::Unmarked}) {
        SCOPED_TRACE(static_cast<int>(kind));
        moving->SetTransparentSort(kind);
        moving->SetTransparentSortTracking(kind==Kind::Depth);
        moving->MarkTransparentOriginChanged();
        moving->ConsumeTransparentOrderDirty();
        EXPECT_EQ(moving->TransparentSortKind(),kind);
        EXPECT_FALSE(scene.runtime().SetNodeParent("moving","destination"));
        EXPECT_TRUE(scene.runtime().NodeParentName("moving").empty());
    }
}

TEST(ScriptParenting, ACompositionLimitFailureDetachesWithoutAdjustingLocalComponents) {
    ScenePackage package;MakeCompositionHierarchy(package,3,1);
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
    EXPECT_FALSE(scene.runtime().SetNodeParent("moving","destination",-1,true));
    EXPECT_TRUE(scene.runtime().NodeParentName("moving").empty());
    EXPECT_EQ(scene.Origin("moving"),(std::array<float,3>{3,5,0}));
    EXPECT_EQ(scene.Scale("moving"),(std::array<float,3>{1,1,1}));
    // The existing cycle guard must still reject before unlinking.
    EXPECT_FALSE(scene.runtime().SetNodeParent("moving","moving_child"));
    EXPECT_EQ(scene.runtime().NodeParentName("moving_child"),"moving");
}

TEST(ScriptParenting, AdjustedTransformsFollowTheReferenceComponentRulesUnderMirroredScale) {
    for (const bool anchored : {false,true}) {
        ScenePackage package;const auto model=package.AddImageModel("plain");
        auto child=PlainImage(model,2,"child",{{"origin",anchored ? "660 500 0" : "520 500 0"},
            {"scale","0.1 0.1 1"},{"angles","0 0 0.2"},
            {"visible",ScriptedValue("var once=false;export function update(v){if(!once){once=true;thisLayer.setParent('parent',true);}return v;}",true)}});
        if (anchored) child["alignment"]="left";
        Publish(package,{PlainImage(model,1,"parent",{{"origin","100 50 0"},
            {"scale","-2 3 4"},{"angles","0 0 0.5235987756"}}),child});
        ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();scene.Tick();
        EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
        const auto origin=scene.Origin("child");
        EXPECT_NEAR(origin[0],anchored ? -354.98712158f : -294.36535645f,1e-4f);
        EXPECT_NEAR(origin[1],anchored ? 36.57048035f : 59.90381622f,1e-4f);
        EXPECT_NEAR(scene.AnglesDegrees("child")[2],-18.54084587f,1e-4f);
        const auto scale=scene.runtime().NodeScale("child");
        EXPECT_NEAR(scale.x(),0.04711136967f,1e-6f);
        EXPECT_NEAR(scale.y(),0.03431093693f,1e-6f);
        EXPECT_NEAR(scale.z(),0.25f,1e-6f);
    }
}
} // namespace

namespace {
using namespace wallpaper;
struct AttachmentRig {
    Scene scene;
    std::unique_ptr<SceneRuntimeContext> runtime=CreateSceneRuntimeContext(SceneRuntimeBootstrap{});
    std::shared_ptr<SceneNode> parent=std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode> child=std::make_shared<SceneNode>();
    WPPuppetLayer puppet;
    AttachmentRig() {
        scene.shaderValueUpdater=std::make_unique<WPShaderValueUpdater>(&scene);
        runtime->AttachScene(&scene);
        parent->SetTranslate(linalg::Vector3f(100,50,0));
        child->SetTranslate(linalg::Vector3f(1,2,0));
        scene.sceneGraph->AppendChild(parent);scene.sceneGraph->AppendChild(child);
        runtime->RegisterNode("parent",parent.get());runtime->RegisterNode("child",child.get());
        auto data=std::make_shared<WPPuppet>();
        auto& bone=data->bones.emplace_back();
        bone.name="root";
        bone.parent=bone.bind_parent=bone.anim_parent=bone.file_parent=WPPuppet::NO_PARENT;
        bone.local_bind=linalg::Affine3f::Identity();bone.local_bind.translation()=linalg::Vector3f(3,4,0);
        auto& attachment=data->attachments.emplace_back();attachment.name="mount";
        attachment.local_xform=linalg::Affine3f::Identity();attachment.local_xform.translation()=linalg::Vector3f(5,0,0);
        auto& unnamed=data->attachments.emplace_back();unnamed.name="";
        unnamed.local_xform=linalg::Affine3f::Identity();
        data->prepared();puppet=WPPuppetLayer(data);
        std::vector<WPPuppetLayer::AnimationLayer> layers;puppet.prepared(layers);
        runtime->RegisterPuppetLayer("parent",puppet);
    }
    void Script(const std::string& body) {
        runtime->RegisterNodeVisibility("child",child.get(),ResolveBoolSetting(*runtime,
            {{"value",true},{"script","var once=false;export function update(v){if(!once){once=true;"+body+"}return v;}"}},"child"));
    }
};
}

TEST(ScriptAttachments, QueriesUseTheCurrentBonePoseAndUnknownAnchorsUseLayerSpace) {
    AttachmentRig rig;
    rig.Script(R"JS(
var p=thisScene.getLayer('parent');
var i=p.getAttachmentIndex('mount');
var a=p.getAttachmentOrigin(i),b=p.getAttachmentOrigin('missing');
var m=p.getAttachmentMatrix('mount');
if(i!==0 || p.getAttachmentIndex('missing')!==-1 || a.x!==108 || a.y!==54 ||
   b.x!==100 || b.y!==50 || m.m[12]!==108)throw new Error('wrong attachment frame');
p.setLocalBoneOrigin(0,new Vec3(10,20,0));
var moved=p.getAttachmentOrigin('mount');
if(moved.x!==115 || moved.y!==70)throw new Error('stale bone pose');
p.angles=new Vec3(0,0,90);
if(Math.abs(p.getAttachmentAngles('mount').z-90)>0.001)throw new Error('angle units');
)JS");
    rig.runtime->Tick(0.01);
    EXPECT_TRUE(rig.runtime->scriptErrors().empty());
}

TEST(ScriptAttachments, ReparentingCanSwitchAndClearAnAttachmentWithoutAStaleUpdater) {
    AttachmentRig rig;
    rig.Script("thisLayer.setParent(thisScene.getLayer('parent'),'mount');");
    rig.runtime->Tick(0.01);rig.scene.shaderValueUpdater->FrameBegin();
    EXPECT_TRUE(rig.runtime->scriptErrors().empty());
    auto world=rig.runtime->NodeTransformMatrix("child");
    EXPECT_NEAR(world(0,3),109,1e-5);EXPECT_NEAR(world(1,3),56,1e-5);
    ASSERT_TRUE(rig.runtime->SetNodeParent("child",""));
    rig.scene.shaderValueUpdater->FrameBegin();
    world=rig.runtime->NodeTransformMatrix("child");
    EXPECT_NEAR(world(0,3),1,1e-5);EXPECT_NEAR(world(1,3),2,1e-5);
}

TEST(ScriptAttachments, BoneWritesMoveAttachedChildrenBeforeTheNextDraw) {
    AttachmentRig rig;
    rig.Script("thisLayer.setParent(thisScene.getLayer('parent'),'mount');");
    rig.runtime->Tick(0.01);
    auto bone=linalg::Matrix4d::Identity();bone(0,3)=10;bone(1,3)=20;
    ASSERT_TRUE(rig.runtime->SetPuppetBoneTransform("parent",0,
        SceneRuntimeContext::PuppetBoneSpace::Local,bone));
    const auto world=rig.runtime->NodeTransformMatrix("child");
    EXPECT_NEAR(world(0,3),116,1e-5);EXPECT_NEAR(world(1,3),72,1e-5);
}

TEST(ScriptAttachments, AdjustedAttachmentSnapsToItsOriginAndRepeatedWritesKeepTheTreeStable) {
    AttachmentRig rig;
    rig.Script("thisLayer.setParent(thisScene.getLayer('parent'),'mount',true);");
    rig.runtime->Tick(0.01);
    EXPECT_TRUE(rig.runtime->scriptErrors().empty());
    const auto before=rig.runtime->NodeTransformMatrix("child");
    EXPECT_NEAR(before(0,3),108,1e-5);EXPECT_NEAR(before(1,3),54,1e-5);
    EXPECT_EQ(rig.runtime->NodeTranslate("child"),linalg::Vector3f::Zero());
    rig.runtime->ConsumeSceneGraphMutationFlag();
    ASSERT_TRUE(rig.runtime->SetNodeParent("child","parent",0,true));
    EXPECT_FALSE(rig.runtime->ConsumeSceneGraphMutationFlag());
    EXPECT_TRUE(rig.runtime->NodeTransformMatrix("child").isApprox(before,1e-5));
}

TEST(ScriptAttachments, EmptyNamesAreSearchableAndNamesKeepTheirCase) {
    AttachmentRig rig;
    rig.Script("var p=thisScene.getLayer('parent');"
        "if(p.getAttachmentIndex('')!==1 || p.getAttachmentIndex('MOUNT')!==-1)"
        "throw new Error('attachment name comparison');");
    rig.runtime->Tick(0.01);
    EXPECT_TRUE(rig.runtime->scriptErrors().empty());
}

TEST(ScriptAttachments, TextureProjectionReturnsAUnitMat3AndIncludesTheHalfTexelOrigin) {
    ScenePackage package;
    const auto model=package.AddImageModel("plain");
    Publish(package,{PlainImage(model,1,"target",{{"origin","131 77 0"},{"angles","0 0 1.5707963267948966"}}),
        PlainImage(model,2,"receiver",{{"origin","128 72 0"},{"size","64 32"},
            {"visible",ScriptedValue(R"JS(
export function update(v){
var m=thisLayer.transformAttachmentToTexture(thisScene.getLayer('target'),'missing');
if(!(m instanceof Mat3))throw new Error('not Mat3');
if(Math.abs(m.m[6]-0.5390625)>0.00001 || Math.abs(m.m[7]-0.359375)>0.00001)
    throw new Error('UV origin');
if(Math.abs(m.m[0])>0.00001 || Math.abs(m.m[1]+1)>0.00001 ||
   Math.abs(m.m[3]+1)>0.00001 || Math.abs(m.m[4])>0.00001)
    throw new Error('normalized texture axes');
return v;
}
)JS",true)}})});
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();scene.Tick();
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptAttachments, TextureProjectionProjectsTheTargetOntoTheReceiverPlane) {
    ScenePackage package;
    const auto model=package.AddImageModel("plain");
    auto document=SceneJson({}, {PlainImage(model,1,"target",{{"origin","2 0 5"}}),
        PlainImage(model,2,"receiver",{{"origin","0 0 0"},{"size","20 10"},
            {"visible",ScriptedValue(R"JS(
export function update(v){
var m=thisLayer.transformAttachmentToTexture('target',-1);
if(Math.abs(m.m[6]-0.675)>0.00001 || Math.abs(m.m[7]-0.55)>0.00001)
    throw new Error('perspective intersection');
return v;
}
)JS",true)}})});
    document["general"]["orthogonalprojection"]=nullptr;
    document["camera"]={{"eye","0 0 10"},{"center","0 0 0"},{"up","0 1 0"}};
    package.SetProject();package.SetScene(document);
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();scene.Tick();
    EXPECT_TRUE(scene.ScriptErrors().empty()) << Describe(scene.ScriptErrors());
}

TEST(ScriptAttachments, ACollapsedReceiverReturnsTheNativeHalfTexelOriginAndZeroAxes) {
    for(const char* scale:{"0 1 1","1 0 1","1 1 0","0 0 0"}) {
        SCOPED_TRACE(scale);
        ScenePackage package;const auto model=package.AddImageModel("collapsed_projection");
        Publish(package,{PlainImage(model,1,"target",{{"origin","1 2 0"}}),
            PlainImage(model,2,"receiver",{{"origin","0 0 0"},{"size","64 32"},{"scale",scale}})});
        ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
        const auto result=scene.runtime().AttachmentToTexture("receiver","target",-1);
        EXPECT_TRUE(result.has_value());if(!result)continue;
        EXPECT_TRUE(result->allFinite());
        EXPECT_TRUE((result->block<2,2>(0,0).isZero()));
        EXPECT_DOUBLE_EQ((*result)(0,2),0.4921875);
        EXPECT_DOUBLE_EQ((*result)(1,2),0.515625);
        EXPECT_DOUBLE_EQ((*result)(2,2),1.0);
    }
}

TEST(ScriptAttachments, AnEdgeOnReceiverUsesTheRayIntersectionTolerance) {
    for(const char* angles:{"0 1.5707963267948966 0","1.5707963267948966 0 0"}) {
        SCOPED_TRACE(angles);
        ScenePackage package;const auto model=package.AddImageModel("edge_projection");
        Publish(package,{PlainImage(model,1,"target",{{"origin","1 2 0"}}),
            PlainImage(model,2,"receiver",{{"origin","0 0 0"},{"size","64 32"},{"angles",angles}})});
        ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
        const auto result=scene.runtime().AttachmentToTexture("receiver","target",-1);
        ASSERT_TRUE(result.has_value());
        EXPECT_TRUE((result->block<2,2>(0,0).isZero()));
        EXPECT_DOUBLE_EQ((*result)(0,2),0.4921875);
        EXPECT_DOUBLE_EQ((*result)(1,2),0.515625);
    }
}

TEST(ScriptAttachments, ATargetOnTheCameraPlaneStillReturnsACollapsedTextureMatrix) {
    ScenePackage package;const auto model=package.AddImageModel("camera_plane_projection");
    auto document=SceneJson({}, {PlainImage(model,1,"target",{{"origin","0 0 10"}}),
        PlainImage(model,2,"receiver",{{"origin","0 0 0"},{"size","64 32"}})});
    document["general"]["orthogonalprojection"]=nullptr;
    document["camera"]={{"eye","0 0 10"},{"center","0 0 0"},{"up","0 1 0"}};
    package.SetProject();package.SetScene(document);
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
    const auto result=scene.runtime().AttachmentToTexture("receiver","target",-1);
    ASSERT_TRUE(result.has_value());
    EXPECT_TRUE((result->block<2,2>(0,0).isZero()));
    EXPECT_DOUBLE_EQ((*result)(0,2),0.4921875);
    EXPECT_DOUBLE_EQ((*result)(1,2),0.515625);
}

namespace {
SceneNode* FindParallaxNode(SceneNode* node, std::string_view name) {
    if (node->Name() == name) return node;
    for (const auto& child : node->GetChildren())
        if (auto* found = FindParallaxNode(child.get(), name)) return found;
    return nullptr;
}

void MakeProjectionParallaxScene(ScenePackage& package, bool parented) {
    const auto model = package.AddImageModel("parallax-card");
    auto child = PlainImage(model,2,"child",{{"origin",parented ? "16 22 0" : "656 562 0"},
        {"parallaxDepth","1 1"}});
    if (parented) child["parent"] = 1;
    auto group = GroupJson(1,"root",{640,540,0});
    group["parallaxDepth"] = "0.25 0.5";
    auto document = SceneJson({}, {group,child,
        PlainImage(model,3,"receiver",{{"origin","960 540 0"},{"size","640 360"},
            {"parallaxDepth","0.1 0.2"}})});
    document["general"]["orthogonalprojection"] = {{"width",1920},{"height",1080}};
    document["general"]["cameraparallax"] = true;
    document["general"]["cameraparallaxamount"] = .7;
    document["general"]["cameraparallaxmouseinfluence"] = 1;
    document["general"]["cameraparallaxdelay"] = 0;
    package.SetProject();package.SetScene(document);
}

linalg::Matrix4d DrawParallaxModel(ScriptScene& scene, SceneNode* node, uint32_t slot = 0) {
    auto& updater = *scene.scene().shaderValueUpdater;
    updater.InitUniforms(node,slot,[](std::string_view name){return name=="g_ModelMatrix";});
    updater.FrameBegin();
    sprite_map_t sprites;
    linalg::Matrix4d model = linalg::Matrix4d::Zero();
    updater.UpdateUniforms(node,slot,sprites,[&](std::string_view name,const ShaderValue& value){
        if (name != "g_ModelMatrix" || value.size() != 16) return;
        for (std::size_t index=0;index<16;++index) model.data()[index]=value[index];
    });
    return model;
}
} // namespace

TEST(ScriptAttachments, ParallaxUsesRootDepthWithoutChangingTheChildsRawValue) {
    for (const bool authored_parent : {false,true}) {
        SCOPED_TRACE(authored_parent);
        ScenePackage package;MakeProjectionParallaxScene(package,authored_parent);
        ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
        if (!authored_parent) ASSERT_TRUE(scene.runtime().SetNodeParent("child","root",-1,true));
        auto* child=FindParallaxNode(scene.scene().sceneGraph.get(),"child");
        ASSERT_NE(child,nullptr);
        EXPECT_EQ(scene.ParallaxDepth("child"),(std::array<float,2>{1,1}));
        EXPECT_EQ(scene.ParallaxDepth("root"),(std::array<float,2>{.25f,.5f}));
        auto model=DrawParallaxModel(scene,child);
        EXPECT_NEAR(model(0,3),600,1e-4) << "root anchor640, root depth.25: shift-56";
        EXPECT_NEAR(model(1,3),562,1e-4);
        ASSERT_TRUE(scene.runtime().SetNodeParallaxDepth("root",{.5f,.5f}));
        EXPECT_EQ(scene.ParallaxDepth("child"),(std::array<float,2>{1,1}));
        model=DrawParallaxModel(scene,child);
        EXPECT_NEAR(model(0,3),544,1e-4) << "changing the root updates effective depth only";
        ASSERT_TRUE(scene.runtime().SetNodeParent("child","",-1,true));
        model=DrawParallaxModel(scene,child);
        EXPECT_NEAR(model(0,3),443.2,1e-4) << "detaching exposes the child's own depth1";
    }
}

TEST(ScriptAttachments, TextureProjectionReadsTheLastSceneDrawOffset) {
    ScenePackage package;MakeProjectionParallaxScene(package,true);
    ScriptScene scene(package);ASSERT_TRUE(scene.ok()) << scene.error();
    auto* child=FindParallaxNode(scene.scene().sceneGraph.get(),"child");
    ASSERT_NE(child,nullptr);
    const auto expect_u=[&](double expected) {
        const auto projected=scene.runtime().AttachmentToTexture("receiver","child",-1);
        ASSERT_TRUE(projected.has_value());
        EXPECT_NEAR((*projected)(0,2),expected,1e-6);
        EXPECT_NEAR((*projected)(1,2),.440277777777778,1e-6);
    };
    expect_u(.02421875); // no object has drawn yet: native cached offset starts at0
    (void)DrawParallaxModel(scene,child);
    expect_u(-.06328125);
    ASSERT_TRUE(scene.runtime().SetNodeTranslate("root",{800,540,0}));
    expect_u(.18671875); // new world transform with the old -56 draw offset
    ASSERT_TRUE(scene.runtime().SetNodeVisible("child",false));
    (void)DrawParallaxModel(scene,child); // even a queried hidden pass cannot publish a new offset
    expect_u(.18671875);
    ASSERT_TRUE(scene.runtime().SetNodeVisible("child",true));
    (void)DrawParallaxModel(scene,child);
    expect_u(.23046875); // the next visible draw publishes -28
    ASSERT_TRUE(scene.runtime().SetNodeParallaxDepth("root",{0,0}));
    expect_u(.23046875);
    (void)DrawParallaxModel(scene,child);
    expect_u(.27421875); // a visible zero-depth draw clears the old offset

    ASSERT_TRUE(scene.runtime().SetNodeParallaxDepth("root",{.25f,.5f}));
    auto* mesh=child->Mesh();
    ASSERT_NE(mesh,nullptr);
    mesh->AddMaterial(SceneMaterial(*mesh->MaterialForSlot(0)));
    child->SetShadowCasterSlots({1});
    auto* updater=dynamic_cast<WPShaderValueUpdater*>(scene.scene().shaderValueUpdater.get());
    ASSERT_NE(updater,nullptr);
    WPShaderValueData caster;caster.parallaxDepth={.25f,.5f};
    updater->SetNodeData(child,1,caster);
    (void)DrawParallaxModel(scene,child,1);
    expect_u(.27421875); // a shadow draw must not replace the last scene-view offset
    const std::string camera=child->Camera();
    child->SetCamera("effect");
    (void)DrawParallaxModel(scene,child);
    child->SetCamera(camera);
    expect_u(.27421875); // layer-local effect work is not a scene-view draw
    updater->SceneDrawWithoutUniforms(child,0,"");
    expect_u(.23046875); // a visible colour program with no uniform block still publishes its draw
}
