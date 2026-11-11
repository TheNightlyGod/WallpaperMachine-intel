#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/SceneForces.hpp"
#include "WPPuppet.hpp"
#include "WPShaderValueUpdater.hpp"
#include "wpscene/WPScene.h"

#include <gtest/gtest.h>
#include <bit>
#include <cmath>

using namespace wallpaper;
namespace {
using Sim = WPPuppet::BoneSimulation;
using V3 = linalg::Vector3f;

std::shared_ptr<WPPuppet> FreeRope(bool gravity, float mass) {
    auto p = std::make_shared<WPPuppet>();
    p->bones.resize(3);
    p->bone_table = {0,0,10};
    p->bone_neighbours.resize(3);
    for (uint32_t i=0;i<3;++i) {
        auto& b=p->bones[i];
        b.name="bone"+std::to_string(i);
        b.parent=b.bind_parent=b.anim_parent=b.file_parent=i==0?WPPuppet::NO_PARENT:i-1;
        if (i>0) b.sim_type=3;
    }
    p->bones[2].local_bind.translation()=V3(10,0,0);
    p->bone_neighbours[1].push_back({2,{1,0,0}});
    auto& sim=p->bones[2].simulation;
    sim.flags=Sim::kIk|Sim::kRotation|Sim::kIkRope|Sim::kIkFreeEnd|(gravity?Sim::kGravity:0);
    sim.mass=mass;
    sim.gravity=V3(100,200,300); // rope uses scene gravity, not this spring/rigid setting
    WPPuppet::IkTarget goal;
    goal.bone=2;goal.matrix.translation()=V3(10,0,0);
    p->ik_targets.push_back(goal);
    WPPuppet::IkChainLink link;
    link.a=2;link.flags=5;link.b=std::bit_cast<uint32_t>(10.0f);link.bones={1,2};
    p->ik_chains.push_back({1,{0},{{1,{link}}}});
    p->prepared();
    return p;
}

struct Rig {
    Scene scene;
    std::unique_ptr<SceneRuntimeContext> runtime;
    std::shared_ptr<SceneNode> node=std::make_shared<SceneNode>();
    WPPuppetLayer layer;
    Rig(std::shared_ptr<WPPuppet> puppet,const wpscene::WPSceneGeneral& general,
        WPPuppetLayer::CompositionKind kind=WPPuppetLayer::CompositionKind::ImagePuppet,
        ProjectProperties properties={}) : layer(puppet,kind) {
        scene.ortho[0]=scene.ortho[1]=1000;
        SceneRuntimeBootstrap bootstrap;
        bootstrap.canvas_width=bootstrap.canvas_height=1000;
        bootstrap.project_properties=std::move(properties);
        runtime=CreateSceneRuntimeContext(std::move(bootstrap));
        runtime->AttachScene(&scene);
        runtime->RegisterSceneGeneral(general);
        runtime->RegisterSceneForceSettings(general);
        runtime->RegisterNode("puppet",node.get());
        std::vector<WPPuppetLayer::AnimationLayer> layers;
        layer.prepared(layers);
        runtime->RegisterPuppetLayer("puppet",layer);
    }
    void Step(double seconds) { scene.PassFrameTime(seconds);runtime->Tick(seconds); }
    V3 Tip() { return layer.modelBones().back().translation(); }
    linalg::Vector3d WorldTip() {
        node->UpdateTrans();
        const auto world=node->ModelTrans();
        return world.topLeftCorner<3,3>()*Tip().cast<double>()+world.topRightCorner<3,1>();
    }
};
} // namespace

TEST(SceneForces, GravityMovesRopeInWorldSpaceWithMassAndSquaredSeconds) {
    wpscene::WPSceneGeneral general;
    general.gravitydirection={0,-2,0};general.gravitystrength=1;
    Rig rig(FreeRope(true,3),general);
    rig.Step(0);rig.Step(0.1);
    // Acceleration is(0,-6,0), so dt² gives(0,-.06,0). Its length error is
    // below sub_14026E340's .001 tolerance: this isolates force units from
    // the backward/forward constraint's separate endpoint rules.
    EXPECT_NEAR(rig.Tip().x(),10,1e-5);
    EXPECT_NEAR(rig.Tip().y(),-0.06,1e-5);
    EXPECT_NEAR(rig.Tip().z(),0,1e-5);
}

TEST(SceneForces, SceneDirectionDoesNotRotateOrScaleWithThePuppetLayer) {
    wpscene::WPSceneGeneral general;
    general.gravitydirection={1,0,0};general.gravitystrength=2;
    Rig rig(FreeRope(true,3),general);
    rig.node->SetScale(V3(2,2,2));
    rig.node->SetRotation(V3(0,0,1.57079632679f));
    rig.Step(0);rig.Step(0.1);
    EXPECT_NEAR(rig.WorldTip().x(),0.06,1e-5);
    EXPECT_NEAR(rig.WorldTip().y(),20,1e-5);
}

TEST(SceneForces, WindActsWithoutGravityAndDoesNotMultiplyBoneMass) {
    wpscene::WPSceneGeneral general;
    general.gravitystrength=0;
    general.windenabled=true;general.winddirection={0,-2,0};general.windstrength=50;
    Rig light(FreeRope(false,1),general),heavy(FreeRope(false,1000),general);
    light.Step(0);heavy.Step(0);light.Step(0.1);heavy.Step(0.1);
    EXPECT_LT(light.Tip().y(),-0.05f);
    // Independently evaluated float32 reference at(time=.1, worldX/width*10=.1).
    EXPECT_NEAR(light.Tip().y(),-0.23985428f,1e-6);
    EXPECT_NEAR(light.Tip().x(),heavy.Tip().x(),1e-6);
    EXPECT_NEAR(light.Tip().y(),heavy.Tip().y(),1e-6);
}

TEST(SceneForces, DisabledWindAndAnUnflaggedRopeKeepTheirRestPose) {
    wpscene::WPSceneGeneral general;
    general.gravitystrength=100;general.windstrength=100;
    Rig rig(FreeRope(false,1000),general);
    rig.Step(0);
    for (int i=0;i<10;++i) rig.Step(0.1);
    EXPECT_EQ(rig.Tip(),V3(10,0,0));
}

TEST(SceneForces, ThreeDimensionalModelsDoNotAcquireAnImageRopeForceConsumer) {
    wpscene::WPSceneGeneral general;
    general.gravitystrength=100;
    general.windenabled=true;general.windstrength=100;
    Rig rig(FreeRope(true,1000),general,WPPuppetLayer::CompositionKind::Model);
    rig.Step(0);rig.Step(0.1);
    EXPECT_EQ(rig.Tip(),V3(10,0,0));
}

TEST(SceneForces, WindUsesWorldXAndCanvasWidthWhileIgnoringWorldY) {
    wpscene::WPSceneGeneral general;
    general.windenabled=true;general.winddirection={0,-2,0};general.windstrength=50;
    Rig shifted(FreeRope(false,1),general),vertical(FreeRope(false,1),general),wide(FreeRope(false,1),general);
    shifted.node->SetTranslate(V3(1000,0,0));
    vertical.node->SetTranslate(V3(0,500,0));
    wide.scene.ortho[0]=2000;
    for (auto* rig : {&shifted,&vertical,&wide}) { rig->Step(0);rig->Step(0.1); }
    EXPECT_NEAR(shifted.Tip().y(),0,1e-6) << "negative simplex pulse is clipped to zero";
    EXPECT_NEAR(vertical.Tip().y(),-0.23985428f,1e-6);
    EXPECT_NEAR(wide.Tip().y(),-0.38319752f,1e-6);
}

TEST(SceneForces, WindPulseUsesSceneTimeAndRawSignedStrength) {
    SceneForceState force;
    force.wind_enabled=true;force.canvas_width=1000;
    force.wind_direction={2,-1,0.5f};force.wind_strength=-3;
    const auto first=force.WindAt(10,0.1f),later=force.WindAt(10,0.2f);
    EXPECT_NEAR(first.x(),-1.43912566f,1e-6);
    EXPECT_NEAR(first.y(),0.71956283f,1e-6);
    EXPECT_NEAR(later.x(),-3.24791479f,1e-6);
    EXPECT_EQ(force.WindAt(70,0.3f),V3::Zero());
    force.wind_enabled=false;
    EXPECT_EQ(force.WindAt(10,0.1f),V3::Zero());
}

TEST(SceneForces, NativeForceWritesReachTheNextPoseAndEqualWritesDoNotStepItAgain) {
    wpscene::WPSceneGeneral general;general.gravitystrength=0;
    Rig rig(FreeRope(true,3),general);
    rig.Step(0);
    const float strength=2;
    const std::array<float,3> direction{0,-2,0};
    ASSERT_TRUE(rig.runtime->SetSceneGeneralValue("gravitydirection",direction));
    ASSERT_TRUE(rig.runtime->SetSceneGeneralValue("gravitystrength",std::span(&strength,1)));
    rig.Step(0.1);
    EXPECT_NEAR(rig.Tip().y(),-0.12,1e-6);
    const auto held=rig.Tip();
    (void)rig.runtime->ConsumeSceneGraphMutationFlag();
    for (int i=0;i<10;++i) {
        ASSERT_TRUE(rig.runtime->SetSceneGeneralValue("gravitydirection",direction));
        ASSERT_TRUE(rig.runtime->SetSceneGeneralValue("gravitystrength",std::span(&strength,1)));
        rig.Step(0);
    }
    EXPECT_EQ(rig.Tip(),held);
    EXPECT_FALSE(rig.runtime->ConsumeSceneGraphMutationFlag());
}

TEST(SceneForces, AUserPropertyUpdatesTheExistingRopeForceConsumerWithoutRebuilding) {
    wpscene::WPSceneGeneral general;
    general.gravitydirection={0,-2,0};general.gravitystrength=0;
    general.force_settings={{"gravitystrength",{{"value",0},{"user","strength"}}}};
    Rig rig(FreeRope(true,3),general,WPPuppetLayer::CompositionKind::ImagePuppet,
            {{"strength",RuntimeScalarValue::Float(0)}});
    rig.Step(0);
    (void)rig.runtime->ConsumeSceneGraphMutationFlag();
    rig.runtime->ApplyProjectPropertyOverride({{"strength",RuntimeScalarValue::Float(2)}});
    rig.Step(0.1);
    EXPECT_NEAR(rig.Tip().y(),-0.12,1e-6);
    EXPECT_FALSE(rig.runtime->ConsumeSceneGraphMutationFlag());
}

TEST(SceneForces, AForceValueScriptWritesAfterThePoseAndFeedsTheFollowingStep) {
    wpscene::WPSceneGeneral general;
    general.gravitydirection={0,-2,0};general.gravitystrength=0;
    general.force_settings={{"gravitystrength",{{"value",0},
        {"script","export function update(value) { return engine.runtime > 0.05 ? 2 : 0; }"}}}};
    Rig rig(FreeRope(true,3),general);
    rig.Step(0);rig.Step(0.1);
    EXPECT_NEAR(rig.Tip().y(),0,1e-6);
    rig.Step(0.1);
    EXPECT_NEAR(rig.Tip().y(),-0.12,1e-6);
    EXPECT_EQ(rig.runtime->scriptErrorCount(),0u);
}

TEST(SceneForces, OrdinaryBonePhysicsKeepsItsAuthoredGravityInsteadOfSceneForces) {
    auto puppet=std::make_shared<WPPuppet>();puppet->bones.resize(1);
    auto& sim=puppet->bones[0].simulation;
    sim.flags=Sim::kSpring|Sim::kTranslation|Sim::kGravity;
    sim.mass=0.001f;sim.gravity=V3(1,0,0);
    puppet->prepared();
    wpscene::WPSceneGeneral general;
    general.gravitystrength=10000;general.windenabled=true;general.windstrength=10000;
    Rig rig(puppet,general);
    rig.Step(0);rig.Step(0.1);
    EXPECT_NEAR(rig.Tip().x(),0.01,1e-6);
    EXPECT_NEAR(rig.Tip().y(),0,1e-6);
    EXPECT_NEAR(rig.Tip().z(),0,1e-6);
}

TEST(SceneForces, ARejectedNonfiniteDriverCannotPoisonTheRopeState) {
    wpscene::WPSceneGeneral general;
    general.gravitydirection={0,-2,0};general.gravitystrength=0;
    general.force_settings={{"gravitystrength",{{"value",0},
        {"script","export function update(value) { return engine.runtime > 0.05 ? Infinity : 2; }"}}}};
    Rig rig(FreeRope(true,3),general);
    rig.Step(0);rig.Step(0.1);
    EXPECT_NEAR(rig.Tip().y(),-0.12,1e-6);
    rig.Step(0.1);
    // SeedSceneGeneralValue refuses Infinity. The next physical step must use
    // its last accepted force rather than re-reading the rejected driver value.
    EXPECT_NEAR(rig.Tip().y(),-0.36,1e-5);
    EXPECT_TRUE(rig.Tip().allFinite());
}

namespace {
std::shared_ptr<WPPuppet> TranslationSpring() {
    auto puppet=std::make_shared<WPPuppet>();
    auto& bone=puppet->bones.emplace_back();
    bone.parent=bone.bind_parent=bone.anim_parent=bone.file_parent=WPPuppet::NO_PARENT;
    bone.simulation.flags=Sim::kSpring|Sim::kTranslation|Sim::kGravity;
    bone.simulation.gravity=V3(0.2f,0.6f,0);
    bone.simulation.mass=0.1f;
    bone.simulation.trans_stiffness=4;
    bone.simulation.trans_friction=2;
    puppet->prepared();
    return puppet;
}

// Match SceneWallpaper's ownership and order: the updater sees Scene.runtime,
// FrameBegin precedes Tick, and only Tick supplies the puppet's current world.
struct AttachmentHost {
    Scene scene;
    std::shared_ptr<SceneNode> parent=std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode> child=std::make_shared<SceneNode>();
    WPPuppetLayer layer;

    AttachmentHost(std::shared_ptr<WPPuppet> puppet,bool attach,bool runtime=true)
        : layer(std::move(puppet)) {
        scene.ortho[0]=scene.ortho[1]=1000;
        scene.shaderValueUpdater=std::make_unique<WPShaderValueUpdater>(&scene);
        scene.sceneGraph->AppendChild(parent);
        parent->SetTranslate(V3(100,50,0));
        parent->SetScale(V3(2,2,2));
        parent->SetRotation(V3(0,0,0.4f));
        std::vector<WPPuppetLayer::AnimationLayer> layers;
        layer.prepared(layers);
        if (runtime) {
            scene.runtime=CreateSceneRuntimeContext(SceneRuntimeBootstrap{});
            scene.runtime->AttachScene(&scene);
            wpscene::WPSceneGeneral general;
            general.gravitydirection={0,-2,0};general.gravitystrength=1;
            scene.runtime->RegisterSceneGeneral(general);
            scene.runtime->RegisterNode("parent",parent.get());
            scene.runtime->RegisterPuppetLayer("parent",layer);
        }
        if (attach) {
            parent->AppendChild(child);
            static_cast<WPShaderValueUpdater&>(*scene.shaderValueUpdater).RegisterPuppetAttachments(
                layer,{{child.get(),uint32_t(layer.boneCount()-1),linalg::Affine3f::Identity()}});
        }
    }
    void Step(double seconds) {
        scene.PassFrameTime(seconds);
        scene.shaderValueUpdater->FrameBegin();
        if (scene.runtime) scene.runtime->Tick(seconds);
    }
    void Move() {
        parent->SetTranslate(V3(125,47,0));
        parent->SetRotation(V3(0,0,0.8f));
    }
};

void ExpectMatchingPose(const AttachmentHost& plain,const AttachmentHost& attached) {
    const auto expected=plain.layer.modelBones(),actual=attached.layer.modelBones();
    ASSERT_FALSE(expected.empty());ASSERT_EQ(expected.size(),actual.size());
    for (std::size_t i=0;i<expected.size();++i) {
        EXPECT_TRUE(actual[i].matrix().isApprox(expected[i].matrix(),1e-5f)) << "bone " << i;
    }
    const auto palette=attached.layer.lastFrame();
    ASSERT_FALSE(palette.empty());
    EXPECT_TRUE(attached.child->GetLocalTrans().isApprox(palette.back().matrix().cast<double>(),1e-5));
}
} // namespace

TEST(SceneForces, AVisualAttachmentDoesNotAdvanceItsRopeBeforeTheRuntimeWorldTransform) {
    AttachmentHost plain(FreeRope(true,3),false),attached(FreeRope(true,3),true);
    ASSERT_TRUE(plain.layer.simulates());
    plain.Step(0);attached.Step(0);
    ExpectMatchingPose(plain,attached);
    plain.Step(0.1);attached.Step(0.1);
    ExpectMatchingPose(plain,attached);
    plain.Move();attached.Move();
    plain.Step(0.1);attached.Step(0.1);
    ExpectMatchingPose(plain,attached);
}

TEST(SceneForces, AVisualAttachmentDoesNotAdvanceItsSpringBeforeTheRuntimeWorldTransform) {
    AttachmentHost plain(TranslationSpring(),false),attached(TranslationSpring(),true);
    ASSERT_TRUE(plain.layer.simulates());
    plain.Step(0);attached.Step(0);
    ExpectMatchingPose(plain,attached);
    plain.Step(0.1);attached.Step(0.1);
    EXPECT_GT(plain.layer.modelBones().back().translation().norm(),0.01f);
    ExpectMatchingPose(plain,attached);
    plain.Move();attached.Move();
    plain.Step(0.1);attached.Step(0.1);
    ExpectMatchingPose(plain,attached);
}

TEST(SceneForces, AnAttachmentWithoutARuntimeSynchronizesItsParentsWorldBeforeStepping) {
    AttachmentHost plain(TranslationSpring(),false,false),attached(TranslationSpring(),true,false);
    const auto step=[&](double seconds) {
        plain.scene.PassFrameTime(seconds);
        plain.parent->UpdateTrans();
        plain.layer.setLayerWorld(plain.parent->ModelTrans());
        plain.layer.genFrame(plain.scene.elapsingTime);
        attached.Step(seconds);
        ExpectMatchingPose(plain,attached);
    };
    step(0);step(0.1);
    plain.Move();attached.Move();
    step(0.1);
}
