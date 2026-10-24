// Scene file schema, part 6: bloom chains, scene settings bound to properties, puppet material
// slots and their parallax, the canvas camera, a paused material timeline and video textures.
//
// Everything is built in memory and parsed headlessly; nothing draws.
#include "support/schema_fixtures.hpp"

#include "Interface/IShaderValueUpdater.h"
#include "Runtime/ScalarAnimation.hpp"
#include "Scene/SceneCamera.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SceneMesh.h"
#include "Scene/SceneShader.h"
#include "Scene/SpecTexs.hpp"
#include "Video/VideoTextureSource.hpp"
#include "WPShaderValueUpdater.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <numbers>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{

using namespace we_schema;
using namespace wallpaper;

Json V2(double x, double y) { return Json::array({ x, y }); }
Json V3(double x, double y, double z) { return Json::array({ x, y, z }); }

// A canvas scene whose bloom is off unless `general` says otherwise.
Json Canvas(Json objects, Json general = Json::object())
{
    if (!general.contains("bloom")) general["bloom"] = false;
    return QuietScene(std::move(objects), general);
}

Json BloomGeneral(bool hdr, const Json& more = Json::object())
{
    Json general = { { "bloom", true }, { "hdr", hdr } };
    for (const auto& [key, value] : more.items()) general[key] = value;
    return general;
}

const SceneMaterial* PassMaterial(const ScenePostProcess& chain, std::size_t step)
{
    const ScenePostProcessPass* pass = PassStep(chain, step);
    if (pass == nullptr || pass->node == nullptr || pass->node->Mesh() == nullptr) return nullptr;
    return pass->node->Mesh()->Material();
}

float Constant(const SceneMaterial& material, std::string_view name, std::size_t lane = 0)
{
    const auto found = material.customShader.constValues.find(std::string(name));
    if (found == material.customShader.constValues.end() || found->second.size() <= lane) return std::nanf("");
    return found->second[lane];
}

WPShaderValueUpdater* UpdaterOf(Scene& scene) { return dynamic_cast<WPShaderValueUpdater*>(scene.shaderValueUpdater.get()); }

// What a `UpdateUniforms` pass hands back, by uniform name.
struct Collector {
    std::map<std::string, std::vector<float>> seen;

    UpdateUniformOp Op()
    {
        return [this](std::string_view name, const ShaderValue& value) {
            seen[std::string(name)].assign(value.data(), value.data() + value.size());
        };
    }
};

ExistsUniformOp OnlyUniform(std::string name)
{
    return [name = std::move(name)](std::string_view asked) { return asked == name; };
}

// ---- LDR bloom ------------------------------------------------------------------------------

// R-6.01 / B-6.01
TEST(BloomLdr, TheChainIsBuiltFromTheUtilityMaterialsAndTakesTheScenesSettings)
{
    ParseRig rig(BloomAssets(BloomSet::Ldr));
    auto     scene = rig.Parse(QuietScene(Json::array(), BloomGeneral(false, { { "bloomstrength", 1.5 }, { "bloomthreshold", 0.25 }, { "bloomtint", V3(0.2, 0.4, 0.6) } })));
    ASSERT_NE(scene, nullptr);

    // row 1
    ASSERT_EQ(scene->post_processes.size(), 1u);
    const ScenePostProcess* chain = scene->post_processes[0].get();
    ASSERT_NE(chain, nullptr);
    EXPECT_EQ(chain->name, "__bloom");
    ASSERT_EQ(chain->steps.size(), 5u);

    // row 2
    const char* outputs[] = { "_rt_bloom_mip1", "_rt_bloom_mip2", "_rt_bloom_blur", "_rt_bloom_combine" };
    for (std::size_t i = 0; i < 4; ++i) {
        const ScenePostProcessPass* pass = PassStep(*chain, i);
        ASSERT_NE(pass, nullptr) << "step " << i;
        EXPECT_EQ(pass->output, outputs[i]) << "step " << i;
    }
    const ScenePostProcessCopy* copy = CopyStep(*chain, 4);
    ASSERT_NE(copy, nullptr);
    EXPECT_EQ(copy->src, "_rt_bloom_combine");
    EXPECT_EQ(copy->dst, "_rt_default");

    // row 3: the scene's numbers replace the stand-in material's own constants (9, 9, [9 9 9])
    const SceneMaterial* extract = PassMaterial(*chain, 0);
    ASSERT_NE(extract, nullptr);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomStrength"), 1.5f);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomThreshold"), 0.25f);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomTint", 0), 0.2f);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomTint", 1), 0.4f);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomTint", 2), 0.6f);

    // row 4: what slot 0 of passes 1..3 samples
    const float sampled[][2] = { { 160, 90 }, { 80, 45 }, { 640, 360 } };
    for (std::size_t i = 0; i < 3; ++i) {
        const SceneMaterial* material = PassMaterial(*chain, i + 1);
        ASSERT_NE(material, nullptr);
        const std::string_view name = WE_GLTEX_RESOLUTION_NAMES[0];
        EXPECT_FLOAT_EQ(Constant(*material, name, 0), sampled[i][0]) << "pass " << i + 1;
        EXPECT_FLOAT_EQ(Constant(*material, name, 1), sampled[i][1]) << "pass " << i + 1;
        EXPECT_FLOAT_EQ(Constant(*material, name, 2), sampled[i][0]) << "pass " << i + 1;
        EXPECT_FLOAT_EQ(Constant(*material, name, 3), sampled[i][1]) << "pass " << i + 1;
    }

    // row 5
    for (const char* name : { "_rt_default", "_rt_bloom_mip1", "_rt_bloom_mip2", "_rt_bloom_combine" }) {
        const SceneRenderTarget* target = scene->FindRenderTarget(name);
        ASSERT_NE(target, nullptr) << name;
        EXPECT_EQ(target->format, TextureFormat::RGBA8) << name;
    }

    // row 6
    struct Expected {
        const char* name;
        double      scale;
        int         width, height;
    };
    const Expected targets[] = { { "_rt_default", 1.0, 640, 360 }, { "_rt_bloom_mip1", 0.25, 160, 90 }, { "_rt_bloom_mip2", 0.125, 80, 45 },
                                 { "_rt_bloom_blur", 0.125, 80, -1 }, { "_rt_bloom_combine", 1.0, 640, 360 } };
    for (const Expected& expected : targets) {
        const SceneRenderTarget* target = scene->FindRenderTarget(expected.name);
        ASSERT_NE(target, nullptr) << expected.name;
        EXPECT_TRUE(target->bind.enable) << expected.name;
        EXPECT_TRUE(target->bind.screen) << expected.name;
        EXPECT_DOUBLE_EQ(target->bind.scale, expected.scale) << expected.name;
        EXPECT_EQ(target->width, expected.width) << expected.name;
        if (expected.height > 0) EXPECT_EQ(target->height, expected.height) << expected.name;
    }

    // row 7: the combine reads the blurred target as its second texture
    const SceneMaterial* combine = PassMaterial(*chain, 3);
    ASSERT_NE(combine, nullptr);
    ASSERT_GE(combine->textures.size(), 2u);
    EXPECT_EQ(combine->textures[1], "_rt_bloom_blur");
}

// R-6.06 / B-6.02
TEST(BloomLdr, ABloomMaterialThatCannotLoadDropsTheWholeChainAndLeavesNoTrace)
{
    const Json scene_json = QuietScene(Json::array(), BloomGeneral(false, { { "bloomstrength", 1.5 }, { "bloomthreshold", 0.25 }, { "bloomtint", V3(0.2, 0.4, 0.6) } }));

    {
        ParseRig rig(BloomAssets(BloomSet::LdrBroken));
        auto     scene = rig.Parse(scene_json);
        ASSERT_NE(scene, nullptr) << "a bloom that cannot be built does not refuse the scene";
        EXPECT_TRUE(scene->post_processes.empty());
        for (const char* name : { "_rt_bloom_mip1", "_rt_bloom_mip2", "_rt_bloom_blur", "_rt_bloom_combine" }) {
            EXPECT_EQ(scene->FindRenderTarget(name), nullptr) << name << " was registered by a chain that did not survive";
        }
    }
    {
        // The same scene with the combine material present does build: the two differ by one file.
        ParseRig rig(BloomAssets(BloomSet::Ldr));
        auto     scene = rig.Parse(scene_json);
        ASSERT_NE(scene, nullptr);
        EXPECT_EQ(scene->post_processes.size(), 1u);
    }
}

// ---- HDR bloom ------------------------------------------------------------------------------

Json HdrScene(int iterations, bool bloom = true)
{
    return QuietScene(Json::array(), { { "bloom", bloom },
                                       { "hdr", true },
                                       { "bloomhdrstrength", 3.0 },
                                       { "bloomhdrscatter", 2.0 },
                                       { "bloomhdrthreshold", 1.0 },
                                       { "bloomhdrfeather", 0.1 },
                                       { "bloomhdriterations", iterations } });
}

// R-6.03 / B-6.03
TEST(BloomHdr, TheLevelCountFollowsTheFrameAndTheIterationLimitAndWeighsEachPass)
{
    {
        ParseRig rig(BloomAssets(BloomSet::Hdr));
        auto     scene = rig.Parse(HdrScene(12));
        ASSERT_NE(scene, nullptr);
        ASSERT_EQ(scene->post_processes.size(), 1u);
        const ScenePostProcess& chain = *scene->post_processes[0];

        EXPECT_NE(scene->FindRenderTarget("_rt_hdr_bloom_7"), nullptr);
        EXPECT_EQ(scene->FindRenderTarget("_rt_hdr_bloom_8"), nullptr) << "eight levels is the cap";
        ASSERT_EQ(chain.steps.size(), 17u) << "extract + 7 down + 7 up + combine + copy";

        const SceneMaterial* extract = PassMaterial(chain, 0);
        ASSERT_NE(extract, nullptr);
        EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomStrength"), 3.0f / (std::pow(2.0f, 6.0f) + 1.0f));

        for (std::size_t i = 0; i <= 7; ++i) {
            ASSERT_NE(PassStep(chain, i), nullptr) << i;
            EXPECT_FLOAT_EQ(PassStep(chain, i)->source_texel_radius, 1.0f) << "extract and downsamples read a texel either side: step " << i;
        }
        for (std::size_t i = 8; i <= 14; ++i) {
            ASSERT_NE(PassStep(chain, i), nullptr) << i;
            EXPECT_FLOAT_EQ(PassStep(chain, i)->source_texel_radius, 0.5f) << "upsamples read half a texel: step " << i;
            const SceneMaterial* material = PassMaterial(chain, i);
            ASSERT_NE(material, nullptr) << i;
            EXPECT_FLOAT_EQ(Constant(*material, "g_BloomScatter"), 2.0f) << "step " << i;
            EXPECT_EQ(material->name, i <= 9 ? "hdr_cubic" : "hdr_up") << "the two coarsest upsamples are cubic: step " << i;
        }
        ASSERT_NE(PassStep(chain, 15), nullptr);
        EXPECT_FLOAT_EQ(PassStep(chain, 15)->source_texel_radius, 0.0f) << "the combine reads no neighbours";
        EXPECT_NE(CopyStep(chain, 16), nullptr);
    }
    {
        ParseRig rig(BloomAssets(BloomSet::Hdr));
        auto     scene = rig.Parse(HdrScene(3));
        ASSERT_NE(scene, nullptr);
        ASSERT_EQ(scene->post_processes.size(), 1u);
        const ScenePostProcess& chain = *scene->post_processes[0];
        ASSERT_EQ(chain.steps.size(), 7u) << "extract + 2 down + 2 up + combine + copy";
        for (std::size_t i : { std::size_t(3), std::size_t(4) }) {
            const SceneMaterial* material = PassMaterial(chain, i);
            ASSERT_NE(material, nullptr);
            EXPECT_EQ(material->name, "hdr_cubic") << "with three levels both upsamples are the coarsest two: step " << i;
        }
        EXPECT_NE(scene->FindRenderTarget("_rt_hdr_bloom_2"), nullptr);
        EXPECT_EQ(scene->FindRenderTarget("_rt_hdr_bloom_3"), nullptr);
    }
}

// A frame large enough for more halvings than the cap allows still gets eight levels.
TEST(BloomHdr, TheLevelCountIsCappedAtEightOnALargeFrame)
{
    Json scene_json = HdrScene(12);
    scene_json["general"]["orthogonalprojection"] = { { "width", 2560 }, { "height", 1440 } };
    ParseRig rig(BloomAssets(BloomSet::Hdr));
    auto     scene = rig.Parse(scene_json);
    ASSERT_NE(scene, nullptr);
    ASSERT_EQ(scene->post_processes.size(), 1u);
    EXPECT_EQ(scene->post_processes[0]->steps.size(), 17u);
    EXPECT_NE(scene->FindRenderTarget("_rt_hdr_bloom_7"), nullptr);
    EXPECT_EQ(scene->FindRenderTarget("_rt_hdr_bloom_8"), nullptr);
}

// R-6.04 / B-6.04
TEST(BloomHdr, HdrNeedsBloomToo)
{
    {
        ParseRig rig(BloomAssets(BloomSet::Hdr));
        auto     scene = rig.Parse(HdrScene(8, false));
        ASSERT_NE(scene, nullptr);
        EXPECT_FALSE(scene->hdr);
        const SceneRenderTarget* frame = scene->FindRenderTarget("_rt_default");
        ASSERT_NE(frame, nullptr);
        EXPECT_EQ(frame->format, TextureFormat::RGBA8);
        EXPECT_TRUE(scene->post_processes.empty());
    }
    {
        ParseRig rig(BloomAssets(BloomSet::Hdr));
        auto     scene = rig.Parse(HdrScene(8, true));
        ASSERT_NE(scene, nullptr);
        EXPECT_TRUE(scene->hdr);
        const SceneRenderTarget* frame = scene->FindRenderTarget("_rt_default");
        ASSERT_NE(frame, nullptr);
        EXPECT_EQ(frame->format, TextureFormat::RGBA16F);
        for (const char* name : { "_rt_hdr_bloom_0", "_rt_bloom_combine" }) {
            const SceneRenderTarget* target = scene->FindRenderTarget(name);
            ASSERT_NE(target, nullptr) << name;
            EXPECT_EQ(target->format, TextureFormat::RGBA16F) << name;
        }
    }
}

// R-6.05 / B-6.05
TEST(BloomHdr, AnHdrSceneWithoutItsHdrMaterialsIsRefusedRatherThanDrawnWithTheLdrChain)
{
    ParseRig rig(BloomAssets(BloomSet::Ldr));
    EXPECT_THROW(rig.Parse(HdrScene(8)), std::runtime_error);
}

// ---- settings bound to user properties ------------------------------------------------------

// R-6.02 / B-6.06
TEST(BoundSceneSettings, LoadOnlySettingsReadOnceAndTheRestFollowTheirPropertiesLive)
{
    ParseRig rig(BloomAssets(BloomSet::Ldr));
    auto&    props = rig.properties();
    props["glow"]         = RuntimeScalarValue::Bool(true);
    props["glowstrength"] = RuntimeScalarValue::Float(3.0f);
    props["glowtint"]     = RuntimeScalarValue::String("0.5 0.25 1");
    props["parallax"]     = RuntimeScalarValue::Bool(true);
    props["depth"]        = RuntimeScalarValue::Float(0.8f);
    props["lag"]          = RuntimeScalarValue::Float(1.5f);
    props["lens"]         = RuntimeScalarValue::Float(2.0f);

    auto bound = [](const char* property, const Json& fallback) { return Json { { "user", property }, { "value", fallback } }; };
    const Json general = { { "bloom", bound("glow", false) },
                           { "bloomstrength", bound("glowstrength", 1.0) },
                           { "bloomthreshold", 0.25 },
                           { "bloomtint", bound("glowtint", "1 1 1") },
                           { "cameraparallax", bound("parallax", false) },
                           { "cameraparallaxamount", bound("depth", 0.2) },
                           { "cameraparallaxdelay", bound("lag", 0.5) },
                           { "zoom", bound("lens", 1.0) } };
    auto scene = rig.Parse(QuietScene(Json::array(), general), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    // load
    ASSERT_EQ(scene->post_processes.size(), 1u) << "the saved choice (on) wins over the file's fallback (off)";
    WPShaderValueUpdater* updater = UpdaterOf(*scene);
    ASSERT_NE(updater, nullptr);
    EXPECT_TRUE(updater->CameraParallax().enable);
    EXPECT_FLOAT_EQ(updater->CameraParallax().amount, 0.8f);

    std::vector<std::string> load_only = scene->runtime->LoadOnlyProperties();
    std::sort(load_only.begin(), load_only.end());
    EXPECT_EQ(load_only, (std::vector<std::string> { "depth", "glow", "parallax" })) << "the live ones are not in the list";

    const SceneMaterial* extract = PassMaterial(*scene->post_processes[0], 0);
    ASSERT_NE(extract, nullptr);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomStrength"), 3.0f);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomTint", 1), 0.25f);
    EXPECT_FLOAT_EQ(updater->CameraParallax().delay, 1.5f);
    ASSERT_NE(scene->cameras.find("global"), scene->cameras.end());
    EXPECT_DOUBLE_EQ(scene->cameras.at("global")->Width(), 320.0) << "640 over a zoom of 2";

    // run
    ProjectProperties change;
    change["glowstrength"] = RuntimeScalarValue::Float(0.5f);
    change["glowtint"]     = RuntimeScalarValue::String("1 0 0");
    change["lag"]          = RuntimeScalarValue::Float(0.25f);
    change["lens"]         = RuntimeScalarValue::Float(4.0f);
    scene->runtime->ApplyProjectPropertyOverride(change);

    extract = PassMaterial(*scene->post_processes[0], 0);
    ASSERT_NE(extract, nullptr);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomStrength"), 0.5f);
    EXPECT_FLOAT_EQ(Constant(*extract, "g_BloomTint", 1), 0.0f);
    EXPECT_FLOAT_EQ(updater->CameraParallax().delay, 0.25f);
    EXPECT_DOUBLE_EQ(scene->cameras.at("global")->Width(), 160.0);

    // the load-only values did not move
    EXPECT_EQ(scene->post_processes.size(), 1u);
    EXPECT_FLOAT_EQ(updater->CameraParallax().amount, 0.8f);
}

// ---- puppet material slots ------------------------------------------------------------------

Json AnimatedAlpha()
{
    return { { "value", 0.6 }, { "animation", { { "c0", Json::array({ { { "frame", 0 }, { "value", 0.6 } }, { { "frame", 1 }, { "value", 0.3 } } }) }, { "options", { { "fps", 30 } } } } } };
}

Json PuppetLayer(const Json& alpha = 0.6, const Json& more = Json::object())
{
    Json layer = { { "id", 300 }, { "name", "puppet image" }, { "image", "puppet_image.json" }, { "origin", V3(0, 0, 0) },
                   { "scale", V3(1, 1, 1) }, { "angles", V3(0, 0, 0) }, { "visible", true }, { "alpha", alpha } };
    for (const auto& [key, value] : more.items()) layer[key] = value;
    return layer;
}

Json PuppetScene(const Json& alpha = 0.6) { return Canvas(Json::array({ PuppetLayer(alpha) })); }

SceneMesh* PuppetMesh(Scene& scene)
{
    SceneNode* node = FindRootChild(scene, "puppet image");
    return node == nullptr ? nullptr : node->Mesh();
}

void ExpectTwoSlotsOfTheHeadAndEyes(SceneMesh& mesh)
{
    ASSERT_EQ(mesh.Submeshes().size(), 2u);
    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
    ASSERT_EQ(mesh.MaterialSlots().size(), 2u);
    const SceneMaterial* head = mesh.MaterialForSlot(0);
    const SceneMaterial* eyes = mesh.MaterialForSlot(1);
    ASSERT_NE(head, nullptr);
    ASSERT_NE(eyes, nullptr);
    EXPECT_EQ(head->name, "headimage");
    EXPECT_EQ(eyes->name, "eyesimage");
    ASSERT_EQ(head->textures.size(), 1u);
    ASSERT_EQ(eyes->textures.size(), 1u);
    EXPECT_EQ(head->textures[0], "head.tex");
    EXPECT_EQ(eyes->textures[0], "eyes.tex");
}

// R-6.07 / B-6.07
TEST(PuppetSlots, EachMeshOfASkinnedPuppetGetsItsOwnMaterialSlot)
{
    ParseRig rig(PuppetAssets());
    auto     scene = rig.Parse(PuppetScene());
    ASSERT_NE(scene, nullptr);
    SceneMesh* mesh = PuppetMesh(*scene);
    ASSERT_NE(mesh, nullptr);
    ExpectTwoSlotsOfTheHeadAndEyes(*mesh);
}

// R-6.08 / B-6.08
TEST(PuppetSlots, APuppetWithoutASkeletonStillGetsOneSlotPerMesh)
{
    PuppetOptions options;
    options.mesh_only = true;
    ParseRig rig(PuppetAssets(options));
    auto     scene = rig.Parse(PuppetScene());
    ASSERT_NE(scene, nullptr);
    SceneMesh* mesh = PuppetMesh(*scene);
    ASSERT_NE(mesh, nullptr);
    ExpectTwoSlotsOfTheHeadAndEyes(*mesh);
}

// R-6.09 / B-6.09
TEST(PuppetSlots, AMeshWithAClippingMaskExpandsIntoSeveralSubmeshesAndSlots)
{
    PuppetOptions options;
    options.masked = true;
    ParseRig rig(PuppetAssets(options));
    auto     scene = rig.Parse(PuppetScene());
    ASSERT_NE(scene, nullptr);
    SceneMesh* mesh = PuppetMesh(*scene);
    ASSERT_NE(mesh, nullptr);

    ASSERT_EQ(mesh->Submeshes().size(), 4u);
    ASSERT_EQ(mesh->MaterialSlots().size(), 4u);
    for (std::uint32_t i = 0; i < 4; ++i) {
        EXPECT_EQ(mesh->Submeshes()[i].material_slot, i);
        ASSERT_NE(mesh->MaterialForSlot(i), nullptr) << i;
    }
    EXPECT_EQ(mesh->Submeshes()[1].output_override, "_rt_puppet_mask");
    for (std::size_t i : { std::size_t(0), std::size_t(2), std::size_t(3) }) EXPECT_TRUE(mesh->Submeshes()[i].output_override.empty()) << i;

    const char* shaders[] = { "headimage", "clippingmaskimage4", "headimage", "eyesimage" };
    for (std::uint32_t i = 0; i < 4; ++i) EXPECT_EQ(mesh->MaterialForSlot(i)->name, shaders[i]) << i;
    ASSERT_FALSE(mesh->MaterialForSlot(2)->textures.empty());
    ASSERT_FALSE(mesh->MaterialForSlot(3)->textures.empty());
    EXPECT_EQ(mesh->MaterialForSlot(2)->textures[0], "head.tex");
    EXPECT_EQ(mesh->MaterialForSlot(3)->textures[0], "eyes.tex");
}

// R-6.10 / B-6.10
TEST(PuppetSlots, ASkeletonLessPuppetsVerticesCarryOnlyPositionAndTextureCoordinate)
{
    {
        PuppetOptions options;
        options.mesh_only = true;
        ParseRig rig(PuppetAssets(options));
        auto     scene = rig.Parse(PuppetScene());
        ASSERT_NE(scene, nullptr);
        SceneMesh* mesh = PuppetMesh(*scene);
        ASSERT_NE(mesh, nullptr);
        ASSERT_EQ(mesh->Submeshes().size(), 2u);
        EXPECT_EQ(mesh->Submeshes()[0].VertexCount(), 1u);
        const auto& attributes = mesh->Submeshes()[0].GetVertexArray(0).Attributes();
        ASSERT_EQ(attributes.size(), 2u);
        EXPECT_EQ(attributes[0].name, "a_Position");
        EXPECT_EQ(attributes[0].type, VertexType::FLOAT3);
        EXPECT_EQ(attributes[1].name, "a_TexCoord");
        EXPECT_EQ(attributes[1].type, VertexType::FLOAT2);
    }
    {
        // A skinned model adds the bone indices and weights after them.
        ParseRig rig(PuppetAssets());
        auto     scene = rig.Parse(PuppetScene());
        ASSERT_NE(scene, nullptr);
        SceneMesh* mesh = PuppetMesh(*scene);
        ASSERT_NE(mesh, nullptr);
        const auto& attributes = mesh->Submeshes()[0].GetVertexArray(0).Attributes();
        ASSERT_EQ(attributes.size(), 4u);
        EXPECT_EQ(attributes[0].name, "a_Position");
        EXPECT_EQ(attributes[0].type, VertexType::FLOAT3);
        EXPECT_EQ(attributes[1].name, "a_TexCoord");
        EXPECT_EQ(attributes[1].type, VertexType::FLOAT2);
        EXPECT_EQ(attributes[2].name, std::string(WE_IN_BLENDINDICES));
        EXPECT_EQ(attributes[2].type, VertexType::UINT4);
        EXPECT_EQ(attributes[3].name, std::string(WE_IN_BLENDWEIGHTS));
        EXPECT_EQ(attributes[3].type, VertexType::FLOAT4);
    }
}

// R-6.11 / B-6.11
TEST(PuppetSlots, SkinningIsKnownToEverySlotBeforeItsShaderIsBuiltAndAlphaReachesEachSlot)
{
    for (const Json& alpha : { AnimatedAlpha(), Json(0.6) }) {
        SCOPED_TRACE(alpha.is_object() ? "animated alpha" : "static alpha");
        ParseRig rig(PuppetAssets());
        auto     scene = rig.Parse(PuppetScene(alpha));
        ASSERT_NE(scene, nullptr);
        SceneMesh* mesh = PuppetMesh(*scene);
        ASSERT_NE(mesh, nullptr);
        ASSERT_EQ(mesh->MaterialSlots().size(), 2u) << "a skinning-less compile of the head shader would fail and collapse the slots";
        for (std::uint32_t slot = 0; slot < 2; ++slot) {
            const SceneMaterial* material = mesh->MaterialForSlot(slot);
            ASSERT_NE(material, nullptr) << slot;
            ASSERT_NE(material->customShader.shader, nullptr) << slot;
            EXPECT_TRUE(material->customShader.shader->rust_reflection_json.has_value()) << slot;
            // The puppet's skinning combos reached the slot's program: with them off the bones
            // would never be compiled in, and the pose would not move the slot.
            const auto& defines = material->defines;
            EXPECT_NE(std::find(defines.begin(), defines.end(), "SKINNING"), defines.end()) << slot;
            EXPECT_NE(std::find(defines.begin(), defines.end(), "BONECOUNT"), defines.end()) << slot;
            EXPECT_FLOAT_EQ(Constant(*material, "g_Alpha"), 0.6f) << "slot " << slot;
        }
    }
}

// R-6.12 / B-6.12
TEST(PuppetSlots, ShaderValuesAreRegisteredPerSlotSoASlotOnAScreenTargetReportsItsSize)
{
    PuppetOptions options;
    options.eyes_render_target = true;
    ParseRig rig(PuppetAssets(options));
    auto     scene = rig.Parse(PuppetScene());
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "puppet image");
    ASSERT_NE(node, nullptr);
    WPShaderValueUpdater* updater = UpdaterOf(*scene);
    ASSERT_NE(updater, nullptr);

    auto resolution_of_slot = [&](std::uint32_t slot) {
        updater->InitUniforms(node, slot, OnlyUniform("g_Texture0Resolution"));
        sprite_map_t sprites;
        Collector    collected;
        updater->UpdateUniforms(node, slot, sprites, collected.Op());
        return collected.seen;
    };

    const auto eyes = resolution_of_slot(1);
    ASSERT_NE(eyes.find("g_Texture0Resolution"), eyes.end());
    ASSERT_GE(eyes.at("g_Texture0Resolution").size(), 2u);
    EXPECT_FLOAT_EQ(eyes.at("g_Texture0Resolution")[0], 160.0f);
    EXPECT_FLOAT_EQ(eyes.at("g_Texture0Resolution")[1], 90.0f);

    const auto head = resolution_of_slot(0);
    const auto found = head.find("g_Texture0Resolution");
    const bool is_quarter_frame = found != head.end() && found->second.size() >= 2 && found->second[0] == 160.0f && found->second[1] == 90.0f;
    EXPECT_FALSE(is_quarter_frame) << "slot 0 samples a file, not the quarter-size frame";
}

// R-6.15 / B-6.13
TEST(PuppetSlots, AMaterialThatCannotLoadAbandonsTheWholeSlotSetForTheLayersOwnMaterial)
{
    PuppetOptions options;
    options.eyes_material = false;
    ParseRig rig(PuppetAssets(options));
    auto     scene = rig.Parse(PuppetScene());
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "puppet image");
    ASSERT_NE(node, nullptr);
    SceneMesh* mesh = node->Mesh();
    ASSERT_NE(mesh, nullptr);

    ASSERT_EQ(mesh->Submeshes().size(), 2u);
    ASSERT_EQ(mesh->MaterialSlots().size(), 1u);
    ASSERT_NE(mesh->Material(), nullptr);
    EXPECT_EQ(mesh->Material()->name, "baseimage");
    EXPECT_EQ(mesh->Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh->Submeshes()[1].material_slot, 0u);
}

// ---- parallax on puppet slots ---------------------------------------------------------------

Json ParallaxGeneral()
{
    return { { "cameraparallax", true }, { "cameraparallaxamount", 2 }, { "cameraparallaxdelay", 0.25 }, { "cameraparallaxmouseinfluence", 1 } };
}

Json WithCameraAt(Json scene)
{
    scene["camera"] = { { "center", V3(10, 0, 0) }, { "eye", V3(10, 0, 1) }, { "up", V3(0, 1, 0) } };
    return scene;
}

// R-6.14 / B-6.14
TEST(PuppetParallax, TheLayersDepthReachesEverySlotNotJustTheFirst)
{
    ParseRig rig(PuppetAssets());
    auto     scene = rig.Parse(WithCameraAt(Canvas(Json::array({ PuppetLayer(0.6, { { "parallaxDepth", V2(0.5, 0.25) } }) }), ParallaxGeneral())));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "puppet image");
    ASSERT_NE(node, nullptr);
    WPShaderValueUpdater* updater = UpdaterOf(*scene);
    ASSERT_NE(updater, nullptr);

    for (std::uint32_t slot : { 1u, 0u }) {
        SCOPED_TRACE("slot " + std::to_string(slot));
        updater->InitUniforms(node, slot, OnlyUniform("g_ModelMatrix"));
        updater->MouseInput(1.0, 0.0);
        scene->frameTime = 0.25;
        updater->FrameBegin();
        sprite_map_t sprites;
        Collector    collected;
        updater->UpdateUniforms(node, slot, sprites, collected.Op());

        ASSERT_NE(collected.seen.find("g_ModelMatrix"), collected.seen.end());
        const std::vector<float>& matrix = collected.seen.at("g_ModelMatrix");
        ASSERT_EQ(matrix.size(), 16u);
        EXPECT_NE(matrix[12], static_cast<float>(node->ModelTrans()(0, 3)));
        EXPECT_NE(matrix[13], static_cast<float>(node->ModelTrans()(1, 3)));
        EXPECT_NEAR(matrix[12], -640.0f, 1e-3f);
        EXPECT_NEAR(matrix[13], -180.0f, 1e-3f);
    }
}

class ParentedPuppet : public testing::TestWithParam<bool> {};

// R-6.13 / B-6.15
TEST_P(ParentedPuppet, AGroupsOutermostDepthAndOriginDecideTheShiftWhateverTheDeclarationOrder)
{
    const bool reversed = GetParam();
    Json objects = Json::array({
        PuppetLayer(0.6, { { "parent", 20 }, { "origin", V3(13, 17, 0) } }),
        { { "id", 20 }, { "name", "inner group" }, { "parent", 10 }, { "parallaxDepth", V2(9, 9) }, { "origin", V3(30, 40, 0) }, { "visible", true } },
        { { "id", 10 }, { "name", "root group" }, { "parallaxDepth", V2(0.75, -0.25) }, { "origin", V3(100, 80, 0) }, { "visible", true } },
    });
    if (reversed) std::reverse(objects.begin(), objects.end());

    ParseRig rig(PuppetAssets());
    auto     scene = rig.Parse(WithCameraAt(Canvas(objects, ParallaxGeneral())));
    ASSERT_NE(scene, nullptr);
    SceneNode* root_group = FindRootChild(*scene, "root group");
    ASSERT_NE(root_group, nullptr);
    SceneNode* inner_group = FindChild(*root_group, "inner group");
    ASSERT_NE(inner_group, nullptr);
    SceneNode* node = FindChild(*inner_group, "puppet image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);

    WPShaderValueUpdater* updater = UpdaterOf(*scene);
    ASSERT_NE(updater, nullptr);
    for (std::uint32_t slot = 0; slot < 2; ++slot) updater->InitUniforms(node, slot, OnlyUniform("g_ModelMatrix"));

    for (const double x : { 0.5, 1.0, 0.0, 0.5 }) {
        SCOPED_TRACE("cursor x " + std::to_string(x));
        updater->MouseInput(x, 1.0 - x);
        scene->frameTime = 0.25;
        updater->FrameBegin();
        node->UpdateTrans();
        EXPECT_NEAR(node->ModelTrans()(0, 3), 143.0, 1e-5);
        EXPECT_NEAR(node->ModelTrans()(1, 3), 137.0, 1e-5);

        for (std::uint32_t slot = 0; slot < 2; ++slot) {
            SCOPED_TRACE("slot " + std::to_string(slot));
            sprite_map_t sprites;
            Collector    collected;
            updater->UpdateUniforms(node, slot, sprites, collected.Op());
            ASSERT_NE(collected.seen.find("g_ModelMatrix"), collected.seen.end());
            const std::vector<float>& matrix = collected.seen.at("g_ModelMatrix");
            ASSERT_EQ(matrix.size(), 16u);
            EXPECT_NEAR(matrix[12], 143.0 + ((0.5 - x) * 640.0 + (100.0 - 320.0)) * 2.0 * 0.75, 1e-3);
            EXPECT_NEAR(matrix[13], 137.0 + ((0.5 - x) * 360.0 + (80.0 - 180.0)) * 2.0 * -0.25, 1e-3);
        }
    }
}

INSTANTIATE_TEST_SUITE_P(Order, ParentedPuppet, testing::Bool(),
                         [](const testing::TestParamInfo<bool>& info) { return info.param ? "ReversedObjects" : "DeclaredObjects"; });

// ---- the canvas camera ---------------------------------------------------------------------

// R-6.16 / B-6.16
TEST(CanvasCamera, ATimelineOnTheSceneZoomFramesTheCanvasWithoutResizingTheTargets)
{
    const Json zoom = { { "value", 3 },
                        { "animation", { { "options", { { "fps", 30 }, { "length", 450 }, { "mode", "single" }, { "name", "intro" } } },
                                         { "c0", Json::array({ { { "frame", 0 }, { "value", 3 } }, { { "frame", 300 }, { "value", 3 } }, { { "frame", 450 }, { "value", 1 } } }) } } } };
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(Canvas(Json::array(), { { "zoom", zoom }, { "orthogonalprojection", { { "width", 960 }, { "height", 540 } } } }), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    const auto global = scene->cameras.at("global");
    const auto persp  = scene->cameras.at("global_perspective");
    ASSERT_NE(global, nullptr);
    ASSERT_NE(persp, nullptr);
    auto linked = std::make_shared<SceneCamera>(*global);
    scene->cameras["linked"] = linked;
    scene->linkedCameras["global"].push_back("linked");

    const double initial_fov = persp->Fov();
    const double initial_z   = persp->GetPosition().z();
    const SceneRenderTarget* frame = scene->FindRenderTarget("_rt_default");
    ASSERT_NE(frame, nullptr);
    const SceneRenderTarget frame_before = *frame;

    // 1
    EXPECT_DOUBLE_EQ(global->Width(), 320.0);
    EXPECT_DOUBLE_EQ(global->Height(), 180.0);
    // 2
    scene->runtime->Tick(10.0);
    EXPECT_DOUBLE_EQ(global->Width(), 320.0) << "still on the first plateau";
    // 3
    scene->runtime->Tick(2.5);
    EXPECT_DOUBLE_EQ(global->Width(), 480.0);
    EXPECT_DOUBLE_EQ(global->Height(), 270.0);
    // 4
    scene->runtime->Tick(2.5);
    EXPECT_DOUBLE_EQ(global->Width(), 960.0);
    EXPECT_DOUBLE_EQ(global->Height(), 540.0);
    // 5
    EXPECT_DOUBLE_EQ(linked->Width(), global->Width());
    EXPECT_DOUBLE_EQ(linked->Height(), global->Height());
    // 6, 7, 8
    EXPECT_DOUBLE_EQ(persp->Fov(), initial_fov) << "the lens does not change, the eye moves";
    EXPECT_GT(persp->GetPosition().z(), initial_z);
    EXPECT_NEAR(persp->GetPosition().z(), 270.0 / std::tan(persp->Fov() * std::numbers::pi / 360.0), 1e-3);
    EXPECT_DOUBLE_EQ(persp->Aspect(), global->Aspect());
    // 9: the canvas corners land on the frame's corners through every one of the cameras
    for (const auto& camera : { global, persp, linked }) {
        const linalg::Matrix4d projection = camera->GetViewProjectionMatrix();
        for (const auto& corner : { std::pair { 0.0, 0.0 }, std::pair { 960.0, 540.0 } }) {
            const linalg::Vector4d clip = projection * linalg::Vector4d(corner.first, corner.second, 0.0, 1.0);
            EXPECT_NEAR(std::abs(clip.x() / clip.w()), 1.0, 1e-6);
            EXPECT_NEAR(std::abs(clip.y() / clip.w()), 1.0, 1e-6);
        }
    }
    // 10
    scene->runtime->Tick(20.0);
    EXPECT_DOUBLE_EQ(global->Width(), 960.0) << "the animation holds at its end";
    // 11
    EXPECT_EQ(scene->ortho[0], 960);
    EXPECT_EQ(scene->ortho[1], 540);
    // 12
    const SceneRenderTarget& frame_after = scene->renderTargets.at("_rt_default");
    EXPECT_EQ(frame_after.width, frame_before.width);
    EXPECT_EQ(frame_after.height, frame_before.height);
    EXPECT_EQ(frame_before.width, 320);
    EXPECT_EQ(frame_before.height, 180);
}

// R-6.17 / B-6.17
TEST(CanvasCamera, AShaderEyeSitsAtTheViewCentreTwoThousandUnitsOutWhateverTheLens)
{
    ParseRig rig(LeafModelAssets());
    auto     scene = rig.Parse(Canvas(Json::array({ { { "id", 7 }, { "name", "planet" }, { "model", "planet.mdl" }, { "perspective", true },
                                                      { "origin", V3(0, 0, 0) }, { "scale", V3(1, 1, 1) }, { "angles", V3(0, 0, 0) }, { "visible", true } } }),
                                      { { "perspectiveoverridefov", 40 } }));
    ASSERT_NE(scene, nullptr);
    SceneNode* node = FindRootChild(*scene, "planet");
    ASSERT_NE(node, nullptr);
    EXPECT_EQ(node->Camera(), "global_perspective");

    const auto persp = scene->cameras.at("global_perspective");
    ASSERT_NE(persp, nullptr);
    EXPECT_NEAR(persp->GetPosition().z(), 180.0 / std::tan(20.0 * std::numbers::pi / 180.0), 1e-2);

    WPShaderValueUpdater* updater = UpdaterOf(*scene);
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(node, 0, OnlyUniform("g_EyePosition"));
    auto eye = [&] {
        sprite_map_t sprites;
        Collector    collected;
        updater->UpdateUniforms(node, sprites, collected.Op());
        return collected.seen["g_EyePosition"];
    };

    std::vector<float> before = eye();
    ASSERT_EQ(before.size(), 3u);
    EXPECT_NEAR(before[0], 320.0f, 1e-3f);
    EXPECT_NEAR(before[1], 180.0f, 1e-3f);
    EXPECT_NEAR(before[2], 2000.0f, 1e-3f);

    const double reference_z = persp->GetPosition().z();
    scene->FrameCanvas(3.0, linalg::Vector2f(40.0f, -20.0f));
    EXPECT_GT(std::abs(persp->GetPosition().z() - reference_z), 100.0) << "the camera came closer";
    std::vector<float> after = eye();
    ASSERT_EQ(after.size(), 3u);
    EXPECT_NEAR(after[0], 360.0f, 1e-3f);
    EXPECT_NEAR(after[1], 160.0f, 1e-3f);
    EXPECT_NEAR(after[2], 2000.0f, 1e-3f);
}

// ---- video material -------------------------------------------------------------------------

// The files of an image layer whose material has two video textures.
FileMap VideoAssets(const std::string& fragment, const Json& pass_extra = Json::object())
{
    FileMap files = GenericImageShaders();
    files["/shaders/multivideo.vert"] = files["/shaders/genericimage.vert"];
    files["/shaders/multivideo.frag"] = fragment;
    PutJson(files, "/image.json", { { "material", "mat/multi_video.json" }, { "width", 64 }, { "height", 32 } });
    Json pass = { { "blending", "translucent" }, { "cullmode", "nocull" }, { "depthtest", "disabled" }, { "depthwrite", "disabled" },
                  { "shader", "multivideo" }, { "textures", Json::array({ "diffuse.tex", "mask.tex" }) } };
    for (const auto& [key, value] : pass_extra.items()) pass[key] = value;
    PutJson(files, "/mat/multi_video.json", { { "passes", Json::array({ pass }) } });
    files["/materials/diffuse.tex.tex"] = TexVideoMarker();
    files["/materials/mask.tex.tex"]    = TexVideoMarker();
    return files;
}

Json VideoScene()
{
    return Canvas(Json::array({ { { "id", 310 }, { "name", "video image" }, { "image", "image.json" }, { "origin", V3(0, 0, 0) },
                                  { "scale", V3(1, 1, 1) }, { "angles", V3(0, 0, 0) }, { "visible", true } } }));
}

constexpr const char* kTwoVideoFragment = R"(varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * texSample2D(g_Texture1, v_TexCoord);
}
)";

constexpr const char* kOpacityFragment = R"(varying vec2 v_TexCoord;
uniform float u_Opacity; // {"material":"Opacity","default":1}
void main() {
    gl_FragColor = vec4(u_Opacity);
}
)";

// R-6.18 / B-6.18
TEST(MaterialTimeline, APausedTimelineHoldsItsFirstKeyUntilItIsPlayed)
{
    const Json opacity = { { "value", 1.5 },
                           { "animation", { { "options", { { "fps", 30 }, { "length", 9 }, { "mode", "single" }, { "startpaused", true }, { "name", "transition" } } },
                                            { "c0", Json::array({ { { "frame", 0 }, { "value", 0 } }, { { "frame", 5 }, { "value", 1.5 } }, { { "frame", 9 }, { "value", 0 } } }) } } } };
    ParseRig rig(VideoAssets(kOpacityFragment, { { "constantshadervalues", { { "Opacity", opacity } } } }));
    auto     scene = rig.Parse(VideoScene(), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneNode* node = FindRootChild(*scene, "video image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    SceneMaterial* material = node->Mesh()->Material();
    ASSERT_NE(material, nullptr);
    ShaderValues& values = material->customShader.constValues;
    ASSERT_NE(values.find("u_Opacity"), values.end());

    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f) << "the first key, not the authored 1.5";
    // Long enough to climb to the middle key if the clock were running; the last key is 0 again,
    // so the longer tick below could not tell a paused clock from a finished one.
    scene->runtime->Tick(5.0 / 30.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f) << "paused: time passing moves nothing";
    scene->runtime->Tick(2.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f) << "still paused";

    ScalarAnimationPlayback* clock = scene->runtime->FindScalarAnimation("video image", "transition");
    ASSERT_NE(clock, nullptr);
    clock->Play();
    scene->runtime->Tick(5.0 / 30.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 1.5f);
    scene->runtime->Tick(4.0 / 30.0);
    EXPECT_FLOAT_EQ(values.at("u_Opacity")[0], 0.0f) << "frame 9: the live map the first read came from kept updating";
}

// R-6.19 / B-6.19
TEST(VideoTextures, EveryVideoTextureOfAnImageMaterialAnswersToTheLayersControls)
{
    ParseRig rig(VideoAssets(kTwoVideoFragment));
    auto     scene = rig.Parse(VideoScene(), ParseOptions { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    SceneRuntimeContext& rt = *scene->runtime;

    EXPECT_TRUE(rt.PauseNodeVideoTexture("video image"));
    EXPECT_TRUE(rt.SetNodeVideoTextureCurrentTime("video image", 7.5));
    EXPECT_TRUE(rt.SetNodeVideoTextureRate("video image", 0.25f));

    for (const char* texture : { "diffuse.tex", "mask.tex" }) {
        const video::VideoPlaybackState state = rt.ResolveVideoPlaybackState(texture, 99.0);
        EXPECT_TRUE(state.paused) << texture;
        EXPECT_FLOAT_EQ(state.rate, 0.25f) << texture;
        EXPECT_DOUBLE_EQ(state.scene_elapsed_seconds, 7.5) << texture << ": not the fallback";
    }

    const video::VideoPlaybackState other = rt.ResolveVideoPlaybackState("other.tex", 99.0);
    EXPECT_FALSE(other.paused);
    EXPECT_FLOAT_EQ(other.rate, 1.0f);
    EXPECT_DOUBLE_EQ(other.scene_elapsed_seconds, 99.0);

    EXPECT_FALSE(rt.PauseNodeVideoTexture("no such layer"));
    EXPECT_FALSE(rt.SetNodeVideoTextureCurrentTime("no such layer", 1.0));
    EXPECT_FALSE(rt.SetNodeVideoTextureRate("no such layer", 2.0f));
}

} // namespace
