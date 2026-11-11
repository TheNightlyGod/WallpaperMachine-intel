#include "support/gpu_scene.hpp"
#include "mdl_fixtures.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/RuntimeImageSource.hpp"
#include "Scene/Scene.h"
#include "MetalRender/MetalRender.hpp"

#include <gtest/gtest.h>
#include <bit>

namespace {
using namespace we_test;
using wallpaper::metal::MetalRender;
constexpr const char* kModel = "models/morph_quad.mdl";

mdltest::Bytes MorphQuad(bool image, int16_t delta, uint16_t alpha, bool animated, bool bones = true) {
    mdltest::MeshSpec mesh;
    mesh.material = "materials/morph_quad.json";
    mesh.flag = (image ? 0x10000u : mdltest::kPosition) | mdltest::kUv |
                (bones ? mdltest::kSkinIdx | mdltest::kSkinWgt : 0u);
    mesh.flagA = image ? 0x1000 : 0;
    mesh.vertices = 4;
    mesh.indices = {0,1,2,0,2,3};
    mdltest::Marks marks;
    auto bytes = mdltest::mdlFile(23, {mesh}, std::nullopt, &marks);
    const std::array<std::array<float, 3>, 4> positions {{{-80,-20,0},{-40,-20,0},{-40,20,0},{-80,20,0}}};
    const auto stride = mdltest::strideOf(mesh.flag);
    for (unsigned vertex = 0; vertex < 4; ++vertex) {
        auto at = marks.vertexStart + stride * vertex;
        const auto put_float = [&](std::size_t offset, float value) { bytes.patchU32(offset, std::bit_cast<uint32_t>(value)); };
        for (const auto& bit : wallpaper::WPMdlVertexBits()) {
            if ((mesh.flag & bit.mask) == 0) continue;
            if (bit.mask == mdltest::kPosition || bit.mask == 0x10000) {
                for (unsigned c = 0; c < 3; ++c) put_float(at + c * 4, positions[vertex][c]);
                if (bit.mask == 0x10000) put_float(at + 12, float(vertex + 1));
            } else if (bit.mask == mdltest::kSkinIdx) {
                for (unsigned c = 0; c < 4; ++c) bytes.patchU32(at + c * 4, 0);
            } else if (bit.mask == mdltest::kSkinWgt) {
                for (unsigned c = 0; c < 4; ++c) put_float(at + c * 4, c == 0 ? 1.0f : 0.0f);
            }
            at += bit.bytes;
        }
    }
    mdltest::writeSkeleton(bytes, 1, bones ? std::vector<mdltest::BoneSpec>{{"root", mdltest::kNone}}
                                         : std::vector<mdltest::BoneSpec>{});
    if (animated) {
        const auto end = mdltest::beginBlock(bytes, "MDLA", 4);
        bytes.u32(1).i32(7).u32(0).cstr("move").cstr("loop").f32(10).i32(100).u32(0).u32(0);
        bytes.u32(0).u8(0).u8(1).u32(1).f32(1).u16(1).u16(0).u32(404);
        bytes.f32(0);
        for (unsigned i = 1; i <= 100; ++i) bytes.f32(1);
        bytes.u32(0);
        mdltest::endBlock(bytes, end);
    } else bytes.stamp("MDLA", 0).u8(0);
    const auto end = mdltest::beginBlock(bytes, "MDMP", 1);
    bytes.u16(1).f32(64).u32(4).u32(0).u32(0).cstr("Move").u32(24);
    for (unsigned i = 0; i < 4; ++i) bytes.u16(static_cast<uint16_t>(delta)).u16(0).u16(0);
    if (image) { bytes.u32(8); for (unsigned i = 0; i < 4; ++i) bytes.u16(alpha); }
    mdltest::endBlock(bytes, end);
    bytes.u8(0);
    return bytes;
}

// The published image/model shader contracts, reduced to an unlit clip-space quad.
// All production parsing, texture upload, integer uniform packing and weight updates
// remain in the path; the fragment colour isolates position and alpha changes.
std::string MorphVertex(bool image) {
    return std::string(image ? "#define IMAGE_MORPH 1\n" : "#define IMAGE_MORPH 0\n") + R"GLSL(
#if IMAGE_MORPH
attribute vec4 a_PositionVec4;
#else
attribute vec3 a_Position;
#endif
varying float v_Alpha;
#if MORPHING
uniform sampler2D g_Texture5;
uniform vec4 g_Texture5Resolution;
uniform uint g_MorphOffsets[12];
uniform float g_MorphWeights[12];
#endif
void main() {
#if IMAGE_MORPH
    vec3 p = a_PositionVec4.xyz;
#else
    vec3 p = a_Position;
#endif
    v_Alpha = 1.0;
#if MORPHING
    vec2 inv = 1.0 / g_Texture5Resolution.xy;
    vec3 displacement = vec3(0.0, 0.0, 0.0);
    for (uint i=0u; i < g_MorphOffsets[0] % 12u; ++i) {
#if IMAGE_MORPH
        uint at = uint(a_PositionVec4.w) + g_MorphOffsets[i+1u];
        vec4 value = texSample2DLod(g_Texture5, (vec2(at % uint(g_Texture5Resolution.x),
            at / uint(g_Texture5Resolution.y)) + 0.5) * inv, 0.0);
        displacement += value.xyz * g_MorphWeights[i+1u];
        v_Alpha *= value.w * g_MorphWeights[i+1u] + (1.0-g_MorphWeights[i+1u]);
#else
        uint at = (uint(gl_VertexID) + g_MorphOffsets[i+1u]) * 3u;
        uint pixel = at / 4u;
        vec4 a = texSample2DLod(g_Texture5, (vec2(pixel % uint(g_Texture5Resolution.x),
            pixel / uint(g_Texture5Resolution.y)) + 0.5) * inv, 0.0);
        ++pixel;
        vec4 b = texSample2DLod(g_Texture5, (vec2(pixel % uint(g_Texture5Resolution.x),
            pixel / uint(g_Texture5Resolution.y)) + 0.5) * inv, 0.0);
        vec3 value = a.xyz;
        if (at % 4u == 1u) value = a.yzw;
        if (at % 4u == 2u) value = vec3(a.zw,b.x);
        if (at % 4u == 3u) value = vec3(a.w,b.xy);
        displacement += value * g_MorphWeights[i+1u];
#endif
    }
    p += displacement * g_MorphWeights[0];
#endif
    gl_Position = vec4(p.xy / 100.0, 0.0, 1.0);
}
)GLSL";
}

void MakeMorphScene(ScenePackage& package, bool image, int16_t delta = 32767,
                    uint16_t alpha = 32767, bool animated = false, bool duplicate = false,
                    bool bones = true, bool authored_morph = false) {
    package.InstallStandardAssets();
    package.AddShader("morph_probe", MorphVertex(image),
        "varying float v_Alpha;\nvoid main(){gl_FragColor=vec4(1.0,0.0,0.0,v_Alpha);}\n");
    const auto model = package.AddImageModel("morph_quad", "util/white", {.blending="translucent", .shader="morph_probe"});
    if (authored_morph) package.PutJson("materials/morph_quad.json", {{"passes",Json::array({{
        {"shader","morph_probe"},{"textures",Json::array({"util/white"})},{"blending","translucent"},
        {"cullmode","nocull"},{"depthtest","disabled"},{"depthwrite","disabled"},
        {"combos",{{"MORPHING",1}}}}})}});
    const auto mdl = MorphQuad(image,delta,alpha,animated,bones);
    package.Put(kModel, std::string_view(reinterpret_cast<const char*>(mdl.data().data()), mdl.size()));
    Json layer;
    if (image) {
        // WE stores the puppet path in the image's model JSON, not on the scene object.
        package.PutJson(model, {{"material","materials/morph_quad.json"},{"autosize",false},{"puppet",kModel}});
        ImageLayer entry;
        entry.name = "morph";
        entry.model = model;
        layer = ImageLayerJson(entry);
    } else layer = {{"id",1},{"name","morph"},{"model",kModel},{"castshadow",false},{"visible",true}};
    if (animated) layer["animationlayers"] = Json::array({{{"id",7},{"animation",7},{"blend",1},
        {"visible",true},{"rate",1},{"additive",false},{"blendin",false},{"blendout",false}}});
    std::vector<Json> objects {layer};
    if (duplicate) { layer["id"]=2; layer["name"]="duplicate"; objects.push_back(layer); }
    package.SetProject();
    package.SetScene(SceneJson({},objects));
}
std::string TextureName(bool image) { return std::string("__morph/") + (image?"image/":"model/") + kModel + "/0"; }
} // namespace

TEST(PuppetMorphGpu, AWeightMovesImageGeometryAndItsAlphaStreamReachesThePicture) {
    WE_SKIP_WITHOUT_METAL();
    for (const auto alpha : {uint16_t(32767),uint16_t(16384)}) {
        ScenePackage package;
        MakeMorphScene(package,true,32767,alpha);
        GpuScene scene(package,{.time_step=0});
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto before = scene.Run(1);
        EXPECT_TRUE(ExpectRegionAverage(before,40,65,12,12,{255,0,0,255},1));
        ASSERT_TRUE(scene.runtime()->SetPuppetBlendShapeWeight("morph",0,1));
        const auto after = scene.Run(1);
        EXPECT_TRUE(ExpectRegionAverage(after,40,65,12,12,{0,0,0,255},1));
        EXPECT_TRUE(ExpectRegionAverage(after,120,65,12,12,{uint8_t(alpha == 32767 ? 255 : 128),0,0,255},1));
        EXPECT_EQ(scene.RebuildCount(),0);
    }
}

TEST(PuppetMorphGpu, ModelAnimationChangesPixelsWithoutUploadingTheStaticDeltasAgain) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    MakeMorphScene(package,false,32767,32767,true);
    GpuScene scene(package,{.time_step=0.025});
    ASSERT_TRUE(scene.ok()) << scene.error();
    const auto before = scene.Run(1);
    EXPECT_TRUE(ExpectRegionAverage(before,40,65,12,12,{255,0,0,255},1));
    const auto uploads = MetalRender::ImageUploadsForTests();
    const auto after = scene.Run(8);
    EXPECT_TRUE(ExpectRegionAverage(after,40,65,12,12,{0,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(after,120,65,12,12,{255,0,0,255},1));
    ASSERT_TRUE(scene.Step(60));
    EXPECT_EQ(MetalRender::ImageUploadsForTests(),uploads);
    auto* images = dynamic_cast<wallpaper::RuntimeImageSource*>(scene.scene().imageParser.get());
    ASSERT_NE(images,nullptr);
    EXPECT_FALSE(images->IsRuntimeImage(TextureName(false)));
    EXPECT_EQ(images->Version(TextureName(false)),0u);
    EXPECT_EQ(scene.RebuildCount(),0);
}

TEST(PuppetMorphGpu, BoneFreeModelsDoNotApplyMorphAnimationEvenWhenMaterialOptsIn) {
    WE_SKIP_WITHOUT_METAL();
    // The same MDLV23/MDLS/MDLA4/MDMP data and visible controls were captured in WE:
    // a model with no bones retains its base vertices, including authored MORPHING=1.
    for (bool explicit_combo : {false,true}) {
        SCOPED_TRACE(explicit_combo);
        ScenePackage package;
        MakeMorphScene(package,false,32767,32767,true,false,false,explicit_combo);
        GpuScene scene(package,{.time_step=0.025});
        ASSERT_TRUE(scene.ok()) << scene.error();
        const auto before = scene.Run(1);
        EXPECT_TRUE(ExpectRegionAverage(before,40,65,12,12,{255,0,0,255},1));
        const auto after = scene.Run(8);
        EXPECT_TRUE(ExpectRegionAverage(after,40,65,12,12,{255,0,0,255},1));
        EXPECT_TRUE(ExpectRegionAverage(after,120,65,12,12,{0,0,0,255},1));
    }
}

TEST(PuppetMorphGpu, TwoLayersAndTwoDisplaysShareOneImmutableMorphTexture) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage package;
    MakeMorphScene(package,true,32767,32767,false,true);
    GpuScene first(package,{.time_step=0});
    ASSERT_TRUE(first.ok()) << first.error();
    ASSERT_TRUE(first.Step());
    const auto uploads = MetalRender::ImageUploadsForTests();
    const auto bytes = MetalRender::SharedImageBytesForTests();
    GpuScene second(package,{.time_step=0});
    ASSERT_TRUE(second.ok()) << second.error();
    ASSERT_TRUE(second.Step());
    const auto name = TextureName(true);
    const void* one = first.renderer().ImportedImageForTests(name);
    ASSERT_NE(one,nullptr);
    EXPECT_EQ(one,second.renderer().ImportedImageForTests(name));
    EXPECT_EQ(MetalRender::ImageUploadsForTests(),uploads);
    EXPECT_EQ(MetalRender::SharedImageBytesForTests(),bytes);
    ASSERT_TRUE(first.runtime()->SetPuppetBlendShapeWeight("morph",0,1));
    ASSERT_TRUE(first.runtime()->SetPuppetBlendShapeWeight("duplicate",0,1));
    EXPECT_TRUE(ExpectRegionAverage(first.Run(1),120,65,12,12,{255,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(second.Run(1),40,65,12,12,{255,0,0,255},1));
}

TEST(PuppetMorphGpu, ANewSceneWithChangedBytesAtTheSameModelPathGetsFreshDeltas) {
    WE_SKIP_WITHOUT_METAL();
    ScenePackage original;
    MakeMorphScene(original,true,32767);
    GpuScene first(original,{.time_step=0});
    ASSERT_TRUE(first.ok()) << first.error();
    ASSERT_TRUE(first.Step());
    ScenePackage changed;
    MakeMorphScene(changed,true,16384);
    GpuScene second(changed,{.time_step=0});
    ASSERT_TRUE(second.ok()) << second.error();
    ASSERT_TRUE(second.Step());
    EXPECT_NE(first.renderer().ImportedImageForTests(TextureName(true)),
              second.renderer().ImportedImageForTests(TextureName(true)));
    ASSERT_TRUE(first.runtime()->SetPuppetBlendShapeWeight("morph",0,1));
    ASSERT_TRUE(second.runtime()->SetPuppetBlendShapeWeight("morph",0,1));
    EXPECT_TRUE(ExpectRegionAverage(first.Run(1),140,65,10,10,{255,0,0,255},1));
    EXPECT_TRUE(ExpectRegionAverage(second.Run(1),140,65,10,10,{0,0,0,255},1));
}
