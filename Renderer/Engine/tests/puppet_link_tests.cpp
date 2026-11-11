#include "WPPuppet.hpp"
#include "../src/Scene/Parse/WPPuppetIk.hpp"
#include <gtest/gtest.h>
#include <bit>
#include <cmath>

using namespace wallpaper;
using linalg::Affine3f;
using linalg::Vector3f;
namespace {
using Layer = WPPuppetLayer::AnimationLayer;
void Turn(Affine3f& pose, float angle) {
    pose.linear() = linalg::AngleAxisf(angle, Vector3f::UnitZ()).toRotationMatrix();
}
void Curve(WPPuppet& puppet, std::vector<float> values) {
    WPPuppet::Animation animation;
    animation.id=1;animation.fps=1;animation.length=static_cast<int>(values.size()-1);
    animation.mode=WPPuppet::PlayMode::Single;
    animation.link_curves.push_back({.values=std::move(values)});
    puppet.anims.push_back(std::move(animation));
}
WPPuppetLayer LayerOf(const std::shared_ptr<WPPuppet>& puppet,
    WPPuppetLayer::CompositionKind kind=WPPuppetLayer::CompositionKind::ImagePuppet) {
    WPPuppetLayer layer(puppet,kind);
    Layer animation;animation.id=1;std::array<Layer,1> stack{animation};layer.prepared(stack);return layer;
}
std::shared_ptr<WPPuppet> Ordinary(uint32_t flags=0) {
    auto p=std::make_shared<WPPuppet>();p->bones.resize(3);
    for (auto& bone:p->bones) bone.parent=bone.bind_parent=bone.anim_parent=bone.file_parent=WPPuppet::NO_PARENT;
    p->bones[0].local_bind.translation()=Vector3f(12,5,0);
    Turn(p->bones[0].local_bind,.8f);
    p->bones[0].local_bind.linear() *= 2;
    p->bones[1].local_bind.translation()=Vector3f(4,1,0);
    p->bones[2].parent=p->bones[2].bind_parent=p->bones[2].anim_parent=p->bones[2].file_parent=1;
    p->bones[2].local_bind.translation()=Vector3f(0,3,0);
    p->bone_links.push_back({.bone=1,.link_a=0,.link_b=0,.flags=flags});
    Curve(*p,{0,.5f,1});p->prepared();return p;
}
void Near(const Vector3f& actual,const Vector3f& expected,float tolerance=1e-4f) {
    for(int axis=0;axis<3;++axis)EXPECT_NEAR(actual[axis],expected[axis],tolerance);
}
std::shared_ptr<WPPuppet> Ground(uint32_t flags=0x10000u,float weight=1) {
    auto p=std::make_shared<WPPuppet>();p->bones.resize(5);
    p->bone_table={0,0,0,10,10};p->bone_neighbours.resize(5);
    for(uint32_t i=0;i<5;++i) {
        auto& b=p->bones[i];b.parent=b.bind_parent=b.anim_parent=b.file_parent=i<2?WPPuppet::NO_PARENT:i-1;
        if(i>=2)b.sim_type=3;
    }
    p->bones[0].local_bind.translation()=Vector3f(12,5,0);
    p->bones[3].local_bind.translation()=Vector3f(8,6,0);
    p->bones[4].local_bind.translation()=Vector3f(8,-6,0);
    p->bone_neighbours[2].push_back({3,{.8f,.6f,0}});
    p->bone_neighbours[3].push_back({4,{.8f,-.6f,0}});
    p->bones[4].simulation.flags=WPPuppet::BoneSimulation::kIk|WPPuppet::BoneSimulation::kRotation;
    WPPuppet::IkTarget target;target.bone=4;target.matrix.translation()=Vector3f(16,0,0);p->ik_targets.push_back(target);
    WPPuppet::IkChainLink link;link.a=4;link.flags=1;link.b=std::bit_cast<uint32_t>(20.f);link.bones={2,3,4};
    p->ik_chains.push_back({2,{0},{{2,{link}}}});
    p->bone_links.push_back({.bone=4,.link_a=0,.link_b=0,.flags=flags});Curve(*p,{weight,weight});p->prepared();return p;
}
}

TEST(PuppetBoneLinks, OrdinaryBonesBlendWorldTransformsBeforeTheirChildren) {
    auto p=Ordinary();auto layer=LayerOf(p);
    layer.genFrame(0);layer.genFrame(1);
    Near(layer.modelBones()[1].translation(),Vector3f(8,3,0));
    const auto linear=layer.modelBones()[1].linear();
    EXPECT_NEAR(std::atan2(linear(1,0),linear(0,0)),.4f,1e-5f);
    EXPECT_NEAR(linear.col(0).norm(),1.5f,1e-5f);
    Near(layer.modelBones()[2].translation(),Vector3f(8,3,0)+linear*Vector3f(0,3,0));
}
TEST(PuppetBoneLinks, TheOrdinaryConsumerDoesNotUseIkTargetModes) {
    for(uint32_t flags:{1u,2u,0x10000u}) {
        SCOPED_TRACE(flags);auto p=Ordinary(flags);auto layer=LayerOf(p);layer.genFrame(0);layer.genFrame(2);
        Near(layer.modelBones()[1].translation(),Vector3f(12,5,0));
        EXPECT_NEAR(std::atan2(layer.modelBones()[1](1,0),layer.modelBones()[1](0,0)),.8f,1e-5f);
    }
}
TEST(PuppetBoneLinks, SequentialRulesKeepFileOrderAndUnnormalizedWeights) {
    auto p=Ordinary();p->bone_links.push_back({.bone=1,.link_a=1,.link_b=0,.flags=1});
    p->anims[0].link_curves.push_back({.values={.5f,.5f,.5f}});p->prepared();auto layer=LayerOf(p);layer.genFrame(0);layer.genFrame(1);
    Near(layer.modelBones()[1].translation(),Vector3f(10,4,0));
}
TEST(PuppetBoneLinks, TheModelCompositionRetainsItsFkPose) {
    auto p=Ordinary();auto layer=LayerOf(p,WPPuppetLayer::CompositionKind::Model);layer.genFrame(2);
    Near(layer.modelBones()[1].translation(),Vector3f(4,1,0));
}
TEST(PuppetGrounding, APositiveTargetDistanceIsLimitedByTheReachRemainingPastTheSource) {
    auto p=Ground();p->ik_targets[0].matrix.translation()=Vector3f(22,0,0);p->prepared();auto layer=LayerOf(p);layer.genFrame(0);
    EXPECT_LE((layer.modelBones()[4].translation()-Vector3f(19,5,0)).squaredNorm(),.1f);
}
TEST(PuppetGrounding, ATargetBehindTheGroundPlaneUsesItsOriginAndKeepsTargetRotation) {
    auto p=Ground();Turn(p->bones[0].local_bind,float(M_PI/2));p->prepared();auto layer=LayerOf(p);layer.genFrame(0);
    EXPECT_LE((layer.modelBones()[4].translation()-Vector3f(12,5,0)).squaredNorm(),.1f);
    EXPECT_NEAR(std::atan2(layer.modelBones()[4](1,0),layer.modelBones()[4](0,0)),0,1e-5f);
}
TEST(PuppetGrounding, FirstSweepReflectsTheKneeEvenWhenTheTargetBlendIsZero) {
    auto p=Ground(0x10000,0);Turn(p->bones[0].local_bind,float(M_PI/2));p->prepared();auto layer=LayerOf(p);layer.genFrame(0);
    Near(layer.modelBones()[3].translation(),Vector3f(8,-6,0),.01f);
    Near(layer.modelBones()[4].translation(),Vector3f(16,0,0),.01f);
}
TEST(PuppetGrounding, ASourceBeforeTheFirstLengthDoesNotReflectTheKnee) {
    auto p=Ground(0x10000,0);Turn(p->bones[0].local_bind,float(M_PI/2));p->bones[0].local_bind.translation()=Vector3f(0,5,0);
    p->prepared();auto layer=LayerOf(p);layer.genFrame(0);Near(layer.modelBones()[3].translation(),Vector3f(8,6,0),.01f);
}

TEST(PuppetBoneLinks, OrdinaryOnlyPlansKeepPerBoneSolverArraysEmpty) {
    auto puppet=Ordinary();
    ASSERT_NE(puppet->ik_plan,nullptr);
    EXPECT_TRUE(puppet->ik_plan->chains.empty());
    EXPECT_TRUE(puppet->ik_plan->at_bone.empty());
    EXPECT_TRUE(puppet->ik_plan->driven.empty());
    EXPECT_TRUE(puppet->ik_plan->lengths.empty());
    EXPECT_TRUE(puppet->ik_plan->reference.empty());
    EXPECT_TRUE(puppet->ik_plan->targets.empty());
    EXPECT_EQ(puppet->ik_plan->bone_links.size(),1u);
    EXPECT_EQ(puppet->ik_plan->link_curve_indices.size(),1u);
    EXPECT_EQ(sizeof(PuppetIkPlan::TargetLink),16u);
    puppet->bone_links.clear();puppet->prepared();
    EXPECT_EQ(puppet->ik_plan,nullptr);
}

TEST(PuppetBoneLinks, AForwardSourceReadsThisInstancesPreviousPose) {
    auto p=Ordinary();
    p->bones[2].parent=p->bones[2].bind_parent=p->bones[2].anim_parent=p->bones[2].file_parent=WPPuppet::NO_PARENT;
    p->bone_links[0].link_b=2;p->anims[0].link_curves[0].values={1,1,1};
    p->anims[0].bone_tracks.resize(3);
    auto& track=p->anims[0].bone_tracks[2];track.bone_index=2;
    for(float x:{20.f,40.f,60.f}) {
        WPPuppet::BoneFrame frame;frame.position=Vector3f(x,0,0);frame.scale=Vector3f::Ones();
        track.frames.push_back(frame);
    }
    p->prepared();auto first=LayerOf(p),second=LayerOf(p);first.genFrame(0);second.genFrame(0);
    first.genFrame(1);Near(first.modelBones()[1].translation(),Vector3f(20,0,0));
    second.genFrame(2);Near(second.modelBones()[1].translation(),Vector3f(20,0,0));
    first.genFrame(2);Near(first.modelBones()[1].translation(),Vector3f(40,0,0));
}

TEST(PuppetGrounding, AScaledThreeDimensionalNormalKeepsTheGroundingDistance) {
    for(float scale:{1.f,3.f}) {
        auto p=Ground();auto& source=p->bones[0].local_bind;
        source.linear()=linalg::AngleAxisf(-float(M_PI/2),Vector3f::UnitY()).toRotationMatrix();
        source.linear()*=scale;source.translation()=Vector3f(12,5,3);
        p->ik_targets[0].matrix.translation()=Vector3f(16,0,10);p->prepared();auto layer=LayerOf(p);layer.genFrame(0);
        const Vector3f goal(12,5,3+20-std::sqrt(178.f));
        EXPECT_LE((layer.modelBones()[4].translation()-goal).squaredNorm(),.1f);
    }
}

TEST(PuppetGrounding, ATargetExactlyOnThePlaneUsesTheSourcesOrientation) {
    auto p=Ground();auto& source=p->bones[0].local_bind;
    source(0,0)=0;source(1,0)=1;source(0,1)=-1;source(1,1)=0;
    p->ik_targets[0].matrix.translation()=Vector3f(16,5,0);p->prepared();auto layer=LayerOf(p);layer.genFrame(0);
    EXPECT_LE((layer.modelBones()[4].translation()-Vector3f(12,5,0)).squaredNorm(),.1f);
    EXPECT_NEAR(std::atan2(layer.modelBones()[4](1,0),layer.modelBones()[4](0,0)),float(M_PI/2),1e-5f);
}

TEST(PuppetBoneLinks, AnUnusableDeclaredChainKeepsNoPerBoneSolverStorage) {
    auto p=Ordinary();p->ik_chains.push_back({.bone=2});p->prepared();
    ASSERT_NE(p->ik_plan,nullptr);EXPECT_TRUE(p->ik_plan->chains.empty());
    EXPECT_EQ(p->ik_plan->at_bone.capacity(),0u);
    EXPECT_EQ(p->ik_plan->driven.capacity(),0u);
    EXPECT_EQ(p->ik_plan->lengths.capacity(),0u);
    EXPECT_EQ(p->ik_plan->reference.capacity(),0u);
    EXPECT_EQ(p->ik_plan->targets.capacity(),0u);
    auto layer=LayerOf(p);layer.genFrame(0);layer.genFrame(2);
    Near(layer.modelBones()[1].translation(),Vector3f(12,5,0));
}
