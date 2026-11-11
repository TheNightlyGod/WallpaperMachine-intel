#include "WPPuppet.hpp"
#include "Scene/Parse/WPPuppetMorph.hpp"
#include "WPMdlParser.hpp"
#include "Runtime/RuntimeImageSource.hpp"

#include <gtest/gtest.h>
#include <cstring>
#include <limits>

using namespace wallpaper;

namespace {
std::shared_ptr<WPPuppet> MorphPuppet(std::size_t shapes = 1, std::size_t meshes = 1) {
    auto p = std::make_shared<WPPuppet>();
    p->bones.emplace_back();
    p->morph_meshes.resize(meshes);
    for (auto& mesh : p->morph_meshes) {
        mesh.scale = 12.5f;
        mesh.vertices = 3;
        for (std::size_t i = 0; i < shapes; ++i) mesh.shapes.push_back({"shape" + std::to_string(i)});
    }
    p->prepared();
    return p;
}
WPPuppetLayer MorphLayer(const std::shared_ptr<WPPuppet>& p,
                         std::vector<WPPuppetLayer::AnimationLayer> layers = {},
                         WPPuppetLayer::CompositionKind kind = WPPuppetLayer::CompositionKind::ImagePuppet) {
    WPPuppetLayer result(p, kind);
    result.prepared(layers);
    return result;
}
WPPuppet::Animation MorphAnimation(int id, std::vector<float> values) {
    WPPuppet::Animation a {};
    a.id = id;
    a.name = "morph";
    a.fps = 10;
    a.length = static_cast<int32_t>(values.size()) - 1;
    a.mode = WPPuppet::PlayMode::Loop;
    a.morph_tracks.push_back({.flags=1, .curves={{.shape=0, .values=std::move(values)}}});
    return a;
}
uint16_t Word(const Image& image, std::size_t index) {
    uint16_t value;
    std::memcpy(&value, image.slots[0].mipmaps[0].data.get() + index * 2, 2);
    return value;
}
} // namespace

TEST(PuppetMorph, UniformsSelectFirstElevenActiveShapesThenSortBySignedWeight) {
    auto p = MorphPuppet(14);
    auto layer = MorphLayer(p);
    layer.genFrame(0);
    for (unsigned i = 0; i < 14; ++i) ASSERT_TRUE(layer.setBlendShapeWeight(i, float(i) - 7.5f));
    const auto* uniforms = layer.morphUniforms();
    ASSERT_NE(uniforms, nullptr);
    EXPECT_EQ(uniforms->offsets[0], 11);
    EXPECT_EQ(uniforms->weights[0], 12.5f);
    EXPECT_EQ(uniforms->offsets[1], 30);
    EXPECT_EQ(uniforms->weights[1], 2.5f);
    EXPECT_EQ(uniforms->offsets[11], 0);
    EXPECT_EQ(uniforms->weights[11], -7.5f);
    // A later, larger weight does not displace one of the eleven earlier active indices.
    EXPECT_EQ(*layer.blendShapeWeight(13), 5.5f);
}

TEST(PuppetMorph, EpsilonActivationAndSameTimeScriptWritesFollowTheComposerClock) {
    auto p = MorphPuppet(2);
    auto layer = MorphLayer(p), other = MorphLayer(p);
    layer.genFrame(0);
    other.genFrame(0);
    ASSERT_TRUE(layer.setBlendShapeWeight(0, std::numeric_limits<float>::epsilon() / 2));
    ASSERT_TRUE(layer.setBlendShapeWeight(1, -std::numeric_limits<float>::epsilon()));
    EXPECT_EQ(layer.morphUniforms()->offsets[0], 1);
    EXPECT_EQ(layer.morphUniforms()->offsets[1], 3);
    std::vector<WPPuppetLayer::AnimationLayer> no_layers;
    layer.prepared(no_layers); // recomposition at the same clock keeps the write
    layer.genFrame(0);
    EXPECT_EQ(layer.morphUniforms()->offsets[0], 1);
    EXPECT_EQ(other.morphUniforms()->offsets[0], 0);
    layer.genFrame(0.1);
    EXPECT_EQ(layer.morphUniforms()->offsets[0], 0);
    EXPECT_EQ(*layer.blendShapeWeight(1), 0);
}

TEST(PuppetMorph, AnimationInterpolatesTheMeshCurvesAndAnInstanceWriteEndsAtTheNextFrame) {
    auto p = MorphPuppet();
    p->anims.push_back(MorphAnimation(7, {0, 1, 0}));
    p->prepared();
    auto layer = MorphLayer(p, {{.id=7}});
    layer.genFrame(0);
    layer.genFrame(0.1);
    EXPECT_FLOAT_EQ(*layer.blendShapeWeight(0), 1);
    ASSERT_TRUE(layer.setBlendShapeWeight(0, -2));
    layer.genFrame(0.1);
    EXPECT_FLOAT_EQ(layer.morphUniforms()->weights[1], -2);
    layer.genFrame(0.15);
    EXPECT_NEAR(*layer.blendShapeWeight(0), 0.5f, 1e-6f);
    EXPECT_NEAR(layer.morphUniforms()->weights[1], 0.5f, 1e-6f);
}

TEST(PuppetMorph, ModelMeshesHaveIndependentTracksAndPartialBlendsClampOnlyTheModelPath) {
    auto p = MorphPuppet(1, 2);
    auto animation = MorphAnimation(7, {-2, -2});
    animation.morph_tracks.push_back({.flags=1, .curves={{.shape=0, .values={0.75f,0.75f}}}});
    p->anims.push_back(std::move(animation));
    p->prepared();
    auto image = MorphLayer(p, {{.id=7, .blend=0.5}});
    auto model = MorphLayer(p, {{.id=7, .blend=0.5}}, WPPuppetLayer::CompositionKind::Model);
    image.genFrame(0); model.genFrame(0);
    EXPECT_FLOAT_EQ(*image.blendShapeWeight(0), -1);
    EXPECT_FLOAT_EQ(*model.blendShapeWeight(0), 0);
    EXPECT_NEAR(model.morphUniforms(1)->weights[1], 0.375f, 1e-7f);
    EXPECT_EQ(image.morphUniforms(1), nullptr);
}

TEST(PuppetMorph, AFullZeroCurveClearsActivityButTheGetterKeepsTheEarlierWeight) {
    auto p = MorphPuppet();
    p->anims.push_back(MorphAnimation(7, {0.75f,0.75f}));
    p->anims.push_back(MorphAnimation(8, {0,0}));
    p->prepared();
    for (const auto kind : {WPPuppetLayer::CompositionKind::ImagePuppet, WPPuppetLayer::CompositionKind::Model}) {
        auto layer = MorphLayer(p, {{.id=7}, {.id=8}}, kind);
        layer.genFrame(0);
        EXPECT_FLOAT_EQ(*layer.blendShapeWeight(0), 0.75f);
        EXPECT_EQ(layer.morphUniforms()->offsets[0], 0);
        EXPECT_FLOAT_EQ(layer.morphUniforms()->weights[1], 0);
    }
}

TEST(PuppetMorph, ModifierUsesTheInverseCurrentModelBoneAndTracksScriptBoneWrites) {
    auto p = MorphPuppet();
    p->morph_meshes[0].modifiers = true;
    p->morph_meshes[0].shapes[0].modifier_flags = 2;
    p->morph_meshes[0].shapes[0].range = {2, 4};
    auto layer = MorphLayer(p);
    layer.genFrame(0);
    ASSERT_TRUE(layer.setBlendShapeWeight(0, 1));
    auto bone = linalg::Affine3f::Identity();
    bone.translation() = linalg::Vector3f(10, 3, 0);
    ASSERT_TRUE(layer.setModelBone(0, bone));
    const auto* uniforms = layer.morphUniforms();
    ASSERT_EQ(uniforms->transforms.size(), 176u);
    EXPECT_FLOAT_EQ(uniforms->transforms[12], -10);
    EXPECT_FLOAT_EQ(uniforms->transforms[13], -3);
    EXPECT_FLOAT_EQ(uniforms->rules[0], 1);
    EXPECT_FLOAT_EQ(uniforms->rules[1], 2);
    EXPECT_FLOAT_EQ(uniforms->rules[2], 4);
}

TEST(PuppetMorph, ImageAndModelDeltasUseDistinctSnormLayoutsAndImmutableRegistration) {
    WPMdl mdl;
    mdl.meshes.resize(1);
    mdl.meshes[0].flag = 0x10000;
    mdl.meshes[0].flag_a = 0x1400;
    mdl.meshes[0].positions.resize(2);
    mdl.morph_sections.resize(1);
    auto& section = mdl.morph_sections[0];
    section.vertex_count = 2;
    section.mesh_parameter = 4;
    auto& shape = section.sections.emplace_back();
    shape.vertices = {{{0x8000,1,2}}, {{3,4,5}}};
    shape.data_400 = {{{6,7,8}}, {{9,10,11}}};
    shape.data_1000 = {32767,16384};
    auto image = BuildPuppetMorphImage(mdl, 0, true, "image");
    auto model = BuildPuppetMorphImage(mdl, 0, false, "model");
    ASSERT_NE(image, nullptr); ASSERT_NE(model, nullptr);
    EXPECT_EQ(image->header.format, TextureFormat::RGBA16S);
    EXPECT_EQ(image->header.formatCode, 19);
    EXPECT_EQ(Word(*image,3), 32767);
    EXPECT_EQ(Word(*image,4), 0x8000);
    EXPECT_EQ(Word(*image,7), 32767);
    EXPECT_EQ(Word(*image,11), 16384);
    EXPECT_EQ(Word(*model,0), 0x8000);
    EXPECT_EQ(Word(*model,3), 6);
    EXPECT_EQ(Word(*model,6), 3);
    RuntimeImageSource source(nullptr);
    const auto generation = source.NamesGeneration();
    ASSERT_TRUE(source.SetStaticImage("image", image));
    EXPECT_EQ(source.Parse("image"), image);
    EXPECT_FALSE(source.IsRuntimeImage("image"));
    EXPECT_EQ(source.Version("image"), 0u);
    EXPECT_EQ(source.NamesGeneration(), generation);
    EXPECT_FALSE(source.SetStaticImage("image", model));
    EXPECT_EQ(source.Parse("image"), image);
}

TEST(PuppetMorph, AnOrdinaryPuppetHasNoMorphStateOrTexture) {
    auto p = MorphPuppet(0);
    auto layer = MorphLayer(p);
    layer.genFrame(0);
    EXPECT_EQ(layer.morphUniforms(), nullptr);
    EXPECT_FALSE(layer.blendShapeWeight(0).has_value());
    WPMdl mdl;
    mdl.meshes.resize(1);
    EXPECT_EQ(BuildPuppetMorphImage(mdl,0,false,"ordinary"), nullptr);
}

TEST(PuppetMorph, BoneFreeModelsKeepNoMorphInstance) {
    auto p = MorphPuppet();
    p->bones.clear();
    p->anims.push_back(MorphAnimation(7,{1,1}));
    p->prepared();
    auto layer = MorphLayer(p,{{.id=7}},WPPuppetLayer::CompositionKind::Model);
    layer.genFrame(0);
    EXPECT_EQ(layer.morphUniforms(),nullptr);
    EXPECT_FALSE(layer.setBlendShapeWeight(0,1));
    EXPECT_FALSE(layer.blendShapeWeight(0).has_value());
}
