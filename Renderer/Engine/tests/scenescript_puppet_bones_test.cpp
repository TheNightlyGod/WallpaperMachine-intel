// The SceneScript puppet bone methods (Appendix A item 12, B-D8): what a script reads from and
// writes to a puppet's bones through the layer object, driven straight through the runtime.
// Headless: no scene package, no device, no window.

#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "WPPuppet.hpp"
#include "mdl_fixtures.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <cmath>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper
{
namespace
{

// root (bind (3, 4, 0)), arm (child of root, bind (10, 0, 0)), hand (child of arm, bind (5, 0, 0)),
// and a second bone named "arm" (child of root) the name lookup must not reach. Animation 7 moves
// the root along x by one unit a frame at 10 fps and holds the other bones at their binds.
std::shared_ptr<WPPuppet> MakeArm() {
    auto puppet = std::make_shared<WPPuppet>();
    const std::vector<std::pair<std::string, uint32_t>> bones {
        { "root", WPPuppet::NO_PARENT }, { "arm", 0 }, { "hand", 1 }, { "arm", 0 } };
    const linalg::Vector3f binds[] = { { 3, 4, 0 }, { 10, 0, 0 }, { 5, 0, 0 }, { 0, 7, 0 } };
    for (size_t i = 0; i < bones.size(); ++i) {
        auto& bone       = puppet->bones.emplace_back();
        bone.name        = bones[i].first;
        bone.parent = bone.bind_parent = bone.anim_parent = bone.file_parent = bones[i].second;
        bone.local_bind  = linalg::Affine3f::Identity();
        bone.local_bind.translation() = binds[i];
    }
    WPPuppet::Animation animation;
    animation.id     = 7;
    animation.fps    = 10.0;
    animation.length = 5;
    animation.mode   = WPPuppet::PlayMode::Loop;
    for (size_t b = 0; b < bones.size(); ++b) {
        WPPuppet::Animation::BoneTrack track;
        track.bone_index = static_cast<uint32_t>(b);
        for (int frame = 0; frame <= animation.length; ++frame) {
            linalg::Vector3f at = binds[b];
            if (b == 0) at.x() += static_cast<float>(frame);
            track.frames.push_back(WPPuppet::BoneFrame { .position = at,
                                                         .angle    = linalg::Vector3f::Zero(),
                                                         .scale    = linalg::Vector3f::Ones() });
        }
        animation.bone_tracks.push_back(std::move(track));
    }
    puppet->anims.push_back(std::move(animation));
    puppet->prepared();
    return puppet;
}

struct Rig {
    Scene                                scene;
    std::unique_ptr<SceneRuntimeContext> runtime;
    std::shared_ptr<SceneNode>           character = std::make_shared<SceneNode>();
    std::shared_ptr<SceneNode>           probe     = std::make_shared<SceneNode>();
    WPPuppetLayer                        layer;

    explicit Rig(bool with_puppet = true) {
        runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
        runtime->AttachScene(&scene);
        character->SetTranslate(linalg::Vector3f(100.0f, 50.0f, 0.0f));
        runtime->RegisterNode("character", character.get());
        runtime->RegisterNode("probe", probe.get());
        if (with_puppet) {
            std::vector<WPPuppetLayer::AnimationLayer> authored(1);
            authored[0].id = 7;
            layer          = WPPuppetLayer(MakeArm());
            layer.prepared(authored);
            runtime->RegisterPuppetLayer("character", layer);
        }
    }
    // An `update` on the character layer's visibility setting; it answers through the probe.
    void Script(const std::string& update) {
        runtime->RegisterNodeVisibility(
            "character", character.get(),
            ResolveBoolSetting(*runtime,
                               { { "value", true },
                                 { "script", "export function update(value) {\n" + update + "\nreturn value;\n}\n" } },
                               "character"));
    }
    linalg::Vector3f Probe() const { return runtime->NodeTranslate("probe"); }
};

} // namespace

namespace {
std::shared_ptr<WPPuppet> MakeMorphPuppet() {
    mdltest::MeshSpec mesh;
    mesh.flagA = 0x1000;
    auto bytes = mdltest::mdlFile(23, {mesh});
    mdltest::writeSkeleton(bytes, 1, {{"root", mdltest::kNone}});
    bytes.stamp("MDLA", 0).u8(0);
    const auto end = mdltest::beginBlock(bytes, "MDMP", 1);
    bytes.u16(3).f32(10).u32(1);
    for (const char* name : {"Smile", "smile", "Frown"}) {
        bytes.u32(0).u32(0).cstr(name).u32(6).u16(32767).u16(0).u16(0);
        bytes.u32(2).u16(32767);
    }
    mdltest::endBlock(bytes, end);
    auto parsed = mdltest::parse(bytes);
    EXPECT_TRUE(parsed.ok);
    return parsed.mdl.puppet;
}

void RegisterMorphPuppet(Rig& rig) {
    auto puppet = MakeMorphPuppet();
    ASSERT_NE(puppet, nullptr);
    puppet->prepared();
    rig.layer = WPPuppetLayer(std::move(puppet));
    std::vector<WPPuppetLayer::AnimationLayer> no_layers;
    rig.layer.prepared(no_layers);
    rig.runtime->RegisterPuppetLayer("character", rig.layer);
}
} // namespace

TEST(PuppetBones, BlendShapeNamesIgnoreAsciiCaseAndResolveTheFirstMatch) {
    Rig rig(false);
    RegisterMorphPuppet(rig);
    rig.Script(R"JS(
thisScene.getLayer('probe').origin = new Vec3(thisLayer.getBlendShapeIndex('sMiLe'),
    thisLayer.getBlendShapeIndex('FROWN'), thisLayer.getBlendShapeIndex(''));
)JS");
    rig.runtime->Tick(0);
    EXPECT_EQ(rig.Probe(), linalg::Vector3f(0, 2, -1));
    EXPECT_EQ(rig.runtime->scriptErrorCount(), 0u);
}

TEST(PuppetBones, BlendShapeWeightsKeepSignedValuesAndIndexNameWritesAgree) {
    Rig rig(false);
    RegisterMorphPuppet(rig);
    rig.Script(R"JS(
thisLayer.setBlendShapeWeight('SMILE', -1.25);
thisLayer.setBlendShapeWeight(2, 1.5);
thisScene.getLayer('probe').origin = new Vec3(thisLayer.getBlendShapeWeight(0),
    thisLayer.getBlendShapeWeight('frown'), thisLayer.getBlendShapeWeight(1));
)JS");
    rig.runtime->Tick(0);
    EXPECT_EQ(rig.Probe(), linalg::Vector3f(-1.25f, 1.5f, 0));
    EXPECT_EQ(rig.runtime->scriptErrorCount(), 0u);
}

TEST(PuppetBones, BlendShapeUnknownWeightsUseTheNativeNumericZeroResult) {
    for (bool has_shapes : {false,true}) {
        SCOPED_TRACE(has_shapes);
        Rig rig(false);
        if (has_shapes) RegisterMorphPuppet(rig);
        rig.Script(R"JS(
thisScene.getLayer('probe').origin = new Vec3(
    thisLayer.getBlendShapeWeight(-1) === 0 && thisLayer.getBlendShapeWeight('') === 0 ? 1 : 0,
    thisLayer.getBlendShapeWeight('missing') === 0 && thisLayer.getBlendShapeWeight(99) === 0 ? 1 : 0,
    typeof thisLayer.getBlendShapeWeight('missing') === 'number' ? 1 : 0);
)JS");
        rig.runtime->Tick(0);
        EXPECT_EQ(rig.Probe(), linalg::Vector3f(1,1,1));
        EXPECT_EQ(rig.runtime->scriptErrorCount(), 0u);
    }
}

// getBoneTransform 0x14020F1D0: the bone's world matrix (the layer's world times its model-space
// matrix), read after this frame's animation.
TEST(PuppetBones, ScriptsReadTheBonesWorldMatrixOfTheFrameTheyRunIn) {
    Rig rig;
    rig.Script(R"JS(
var m = thisLayer.getBoneTransform(0);
thisScene.getLayer('probe').origin = new Vec3(m.m[12], m.m[13], thisLayer.getBoneCount());
)JS");
    rig.runtime->Tick(0.0);
    EXPECT_NEAR(rig.Probe().x(), 103.0f, 1e-4f);
    EXPECT_NEAR(rig.Probe().y(), 54.0f, 1e-4f);
    EXPECT_EQ(rig.Probe().z(), 4.0f);
    rig.scene.PassFrameTime(0.2);
    rig.runtime->Tick(0.2);
    EXPECT_NEAR(rig.Probe().x(), 105.0f, 1e-4f) << "frame 2 of the clip, not the last frame's pose";
    EXPECT_EQ(rig.runtime->scriptErrorCount(), 0u);
}

// setBoneTransform 0x14020F350 by name: the first bone of that name takes the matrix, which the
// draw at the same time keeps; getBoneIndex and getBoneParentIndex follow the skeleton.
TEST(PuppetBones, SetBoneTransformByNameReachesTheFirstBoneOfThatName) {
    Rig rig;
    rig.Script(R"JS(
thisLayer.setBoneTransform('arm', Mat4.fromTranslation(new Vec3(150, 70, 0)));
thisScene.getLayer('probe').origin = new Vec3(thisLayer.getBoneIndex('arm'), thisLayer.getBoneParentIndex('hand'),
                                              thisLayer.getBoneParentIndex(0));
)JS");
    rig.runtime->Tick(0.0);
    EXPECT_EQ(rig.Probe(), linalg::Vector3f(1.0f, 1.0f, -1.0f));
    const auto world = rig.runtime->PuppetBoneTransform("character", 1, SceneRuntimeContext::PuppetBoneSpace::World);
    ASSERT_TRUE(world.has_value());
    EXPECT_NEAR((*world)(0, 3), 150.0, 1e-4);
    EXPECT_NEAR((*world)(1, 3), 70.0, 1e-4);
    const auto other = rig.runtime->PuppetBoneTransform("character", 3, SceneRuntimeContext::PuppetBoneSpace::World);
    ASSERT_TRUE(other.has_value());
    EXPECT_NEAR((*other)(1, 3), 50.0 + 4.0 + 7.0, 1e-4);
    // The palette the draw reads maps the arm's bind origin (13, 4) to the written place, in
    // model space (inverse of the layer's world).
    const auto palette = rig.layer.genFrame(0.0);
    const auto moved   = palette[1] * linalg::Vector3f(13.0f, 4.0f, 0.0f);
    EXPECT_NEAR(moved.x(), 50.0f, 1e-4f);
    EXPECT_NEAR(moved.y(), 20.0f, 1e-4f);
    EXPECT_EQ(rig.runtime->scriptErrorCount(), 0u);
}

// Local origin and angles (0x1402100D0..0x140210250, 0x14020FA10 / 0x14020FCE0): parent-relative,
// angles in radians; a local write carries the bones below.
TEST(PuppetBones, LocalOriginAndAnglesRoundTripInRadiansAndCarryTheBonesBelow) {
    Rig rig;
    rig.Script(R"JS(
thisLayer.setLocalBoneOrigin('hand', new Vec3(8, 0, 0));
thisLayer.setLocalBoneAngles(1, new Vec3(0, 0, Math.PI / 2));
var a = thisLayer.getLocalBoneAngles(1), o = thisLayer.getLocalBoneOrigin(2);
thisScene.getLayer('probe').origin = new Vec3(a.z, o.x, thisLayer.getLocalBoneOrigin(1).x);
)JS");
    rig.runtime->Tick(0.0);
    EXPECT_NEAR(rig.Probe().x(), 1.5707963f, 1e-5f);
    EXPECT_NEAR(rig.Probe().y(), 8.0f, 1e-5f);
    EXPECT_NEAR(rig.Probe().z(), 10.0f, 1e-5f) << "setting the angles keeps the origin";
    // The hand hangs 8 along the arm's turned x: model (3 + 10, 4 + 8), world + (100, 50).
    const auto hand = rig.runtime->PuppetBoneTransform("character", 2, SceneRuntimeContext::PuppetBoneSpace::World);
    ASSERT_TRUE(hand.has_value());
    EXPECT_NEAR((*hand)(0, 3), 113.0, 1e-4);
    EXPECT_NEAR((*hand)(1, 3), 62.0, 1e-4);
    EXPECT_EQ(rig.runtime->scriptErrorCount(), 0u);
}

// A layer with no puppet answers 0, -1 and null and takes writes without throwing; bone physics
// and blend shapes have nothing to act on yet.
TEST(PuppetBones, ALayerWithoutBonesAnswersNothingAndDoesNotThrow) {
    Rig rig(false);
    rig.Script(R"JS(
thisLayer.setBoneTransform(0, new Mat4());
thisLayer.setLocalBoneAngles(0, new Vec3(1, 2, 3));
thisLayer.applyBonePhysicsImpulse(0, new Vec3(1, 0, 0));
thisLayer.resetBonePhysicsSimulation();
thisLayer.setBlendShapeWeight(0, 1);
var none = thisLayer.getBoneTransform(0) === null && thisLayer.getLocalBoneOrigin(0) === null &&
           thisLayer.getLocalBoneAngles(0) === null && thisLayer.getBlendShapeWeight(0) === 0;
thisScene.getLayer('probe').origin = new Vec3(thisLayer.getBoneCount(), thisLayer.getBoneIndex('root'),
                                              none ? thisLayer.getBlendShapeIndex('smile') : 5);
)JS");
    rig.runtime->Tick(0.0);
    EXPECT_EQ(rig.Probe(), linalg::Vector3f(0.0f, -1.0f, -1.0f));
    EXPECT_EQ(rig.runtime->scriptErrorCount(), 0u);
}

} // namespace wallpaper
