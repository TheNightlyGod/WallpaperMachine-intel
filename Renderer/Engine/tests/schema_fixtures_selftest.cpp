// Checks of the fixture layer itself (support/schema_fixtures.hpp), so the parts that build on
// it can trust it: every file set parses through the production readers the way its comment
// says, and the byte writer produces exactly the documented layout.
#include "support/schema_fixtures.hpp"

#include "Fs/MemBinaryStream.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneMaterial.h"
#include "Scene/SpecTexs.hpp"
#include "WPMdlParser.hpp"
#include "WPTexImageParser.hpp"
#include "wpscene/WPImageObject.h"
#include "wpscene/WPParticleObject.h"

#include <gtest/gtest.h>

#include <set>
#include <utility>
#include <vector>

namespace
{

using namespace we_schema;
using wallpaper::Scene;

// ---- file system and bytes ---------------------------------------------------------------

TEST(SchemaFixtures, MemoryFsServesExactlyTheMappedPaths)
{
    wallpaper::fs::VFS vfs;
    MountAssets(vfs, { { "/dir/file.txt", "payload" }, { "/empty", "" } });

    EXPECT_TRUE(vfs.Contains("/assets/dir/file.txt"));
    EXPECT_TRUE(vfs.Contains("/assets/empty"));
    EXPECT_FALSE(vfs.Contains("/assets/dir"));
    EXPECT_FALSE(vfs.Contains("/assets/dir/other.txt"));

    EXPECT_EQ(wallpaper::fs::GetFileContent(vfs, "/assets/dir/file.txt"), "payload");
    EXPECT_EQ(wallpaper::fs::GetFileContent(vfs, "/assets/empty"), "");
    EXPECT_EQ(vfs.Open("/assets/missing"), nullptr);
    EXPECT_EQ(vfs.OpenW("/assets/dir/file.txt"), nullptr) << "the file system is read-only";
}

TEST(SchemaFixtures, AddReplacesEntriesOfTheSamePath)
{
    FileMap files { { "/a", "one" }, { "/b", "two" } };
    Add(files, { { "/b", "three" }, { "/c", "four" } });
    EXPECT_EQ(files.size(), 3u);
    EXPECT_EQ(files.at("/a"), "one");
    EXPECT_EQ(files.at("/b"), "three");
    EXPECT_EQ(files.at("/c"), "four");
}

TEST(SchemaFixtures, ByteWriterWritesTheDocumentedLayout)
{
    ByteWriter out;
    out.Stamp("MDLV", 21).U8(7).U16(0x0201).U32(0x04030201u).I32(-2).F32(1.5f).Str("ab");
    const std::string& bytes = out.Bytes();

    EXPECT_EQ(bytes.substr(0, 9), std::string("MDLV0021\0", 9));
    ASSERT_EQ(bytes.size(), 9u + 1 + 2 + 4 + 4 + 4 + 3);
    EXPECT_EQ(static_cast<unsigned char>(bytes[9]), 7u);
    EXPECT_EQ(static_cast<unsigned char>(bytes[10]), 0x01u) << "little-endian: low byte first";
    EXPECT_EQ(static_cast<unsigned char>(bytes[11]), 0x02u);
    EXPECT_EQ(static_cast<unsigned char>(bytes[12]), 0x01u);
    EXPECT_EQ(static_cast<unsigned char>(bytes[15]), 0x04u);
    EXPECT_EQ(static_cast<unsigned char>(bytes[16]), 0xFEu);
    EXPECT_EQ(static_cast<unsigned char>(bytes[19]), 0xFFu);
    float f;
    std::memcpy(&f, bytes.data() + 20, 4);
    EXPECT_EQ(f, 1.5f);
    EXPECT_EQ(bytes.substr(24), std::string("ab\0", 3));
    EXPECT_EQ(out.Size(), bytes.size());
}

TEST(SchemaFixtures, ByteWriterStampPadsTheVersionToFourDigits)
{
    EXPECT_EQ(ByteWriter().Stamp("TEXB", 3).Bytes(), std::string("TEXB0003\0", 9));
    EXPECT_EQ(ByteWriter().Stamp("MDLA", 0).Bytes(), std::string("MDLA0000\0", 9));
    EXPECT_EQ(ByteWriter().Stamp("MDLV", 1234).Bytes(), std::string("MDLV1234\0", 9));
}

TEST(SchemaFixtures, ByteWriterPatchesAnEarlierWordAndIgnoresOneOutOfRange)
{
    ByteWriter out;
    out.U32(0).U32(0xAAAAAAAAu);
    out.PatchU32(0, 0x11223344u);
    uint32_t first, second;
    std::memcpy(&first, out.Bytes().data(), 4);
    std::memcpy(&second, out.Bytes().data() + 4, 4);
    EXPECT_EQ(first, 0x11223344u);
    EXPECT_EQ(second, 0xAAAAAAAAu);

    out.PatchU32(6, 1); // would run past the end
    std::memcpy(&second, out.Bytes().data() + 4, 4);
    EXPECT_EQ(second, 0xAAAAAAAAu);
    EXPECT_EQ(out.Size(), 8u);
}

// ---- object files ------------------------------------------------------------------------

TEST(SchemaFixtures, BasicAssetsLoadAnImageObjectOfTheDocumentedSize)
{
    wallpaper::fs::VFS vfs;
    MountAssets(vfs, BasicAssets());

    wallpaper::wpscene::WPImageObject image;
    ASSERT_TRUE(image.FromJson({ { "image", "image.json" } }, vfs));
    EXPECT_EQ(image.size[0], 64.0f);
    EXPECT_EQ(image.size[1], 32.0f);
    EXPECT_EQ(image.material.shader, "genericimage");
    ASSERT_EQ(image.material.textures.size(), 1u);
    EXPECT_EQ(image.material.textures[0], "a.tex");
    EXPECT_EQ(image.material.blending, "translucent");
    EXPECT_EQ(image.material.cullmode, "nocull");
    EXPECT_EQ(image.material.depthtest, "disabled");
    EXPECT_EQ(image.material.depthwrite, "disabled");
    EXPECT_TRUE(vfs.Contains("/assets/materials/a.tex.tex"));
    EXPECT_EQ(wallpaper::fs::GetFileContent(vfs, "/assets/materials/a.tex.tex"), "") << "the texture file is empty";
}

TEST(SchemaFixtures, BasicAssetsLoadAParticleWithOneChild)
{
    wallpaper::fs::VFS vfs;
    MountAssets(vfs, BasicAssets());

    wallpaper::wpscene::WPParticleObject particle;
    ASSERT_TRUE(particle.FromJson({ { "particle", "particle.json" } }, vfs));
    ASSERT_EQ(particle.particleObj.emitters.size(), 1u);
    EXPECT_EQ(particle.particleObj.emitters[0].id, 1);
    EXPECT_EQ(particle.particleObj.maxcount, 4u);
    EXPECT_EQ(particle.particleObj.starttime, 0.0f);
    ASSERT_EQ(particle.particleObj.children.size(), 1u);
    const auto& child = particle.particleObj.children[0];
    EXPECT_EQ(child.name, "child_particle.json");
    EXPECT_EQ(child.type, "eventspawn");
    EXPECT_EQ(child.maxcount, 3);
    EXPECT_EQ(child.origin, (std::array<float, 3> { 1, 2, 3 }));
    EXPECT_EQ(child.scale, (std::array<float, 3> { 0.5f, 0.5f, 1 }));
    EXPECT_EQ(child.angles, (std::array<float, 3> { 0, 0, 45 }));
    ASSERT_EQ(child.obj.emitters.size(), 1u);
    EXPECT_EQ(child.obj.emitters[0].id, 2);
    EXPECT_EQ(child.obj.emitters[0].name, "child_emit");
    EXPECT_EQ(child.obj.maxcount, 2u);
    EXPECT_EQ(child.obj.starttime, 1.0f);
}

// ---- binary files ------------------------------------------------------------------------

TEST(SchemaFixtures, ModelFixturesParseWithTheDocumentedShape)
{
    wallpaper::fs::VFS vfs;
    FileMap            files;
    files["/two.mdl"]    = MdlTwoMeshes();
    files["/masked.mdl"] = MdlMaskedHead();
    files["/attach.mdl"] = MdlWithAttachment();
    files["/mesh.mdl"]   = MdlMeshOnly();
    MountAssets(vfs, files);

    wallpaper::WPMdl mdl;
    ASSERT_TRUE(wallpaper::WPMdlParser::Parse("two.mdl", vfs, mdl));
    EXPECT_EQ(mdl.mdlv, 21);
    ASSERT_EQ(mdl.meshes.size(), 2u);
    EXPECT_EQ(mdl.meshes[0].mat_json_file, "mat/head.json");
    EXPECT_EQ(mdl.meshes[1].mat_json_file, "mat/eyes.json");
    EXPECT_EQ(mdl.meshes[0].positions.size(), 3u);
    EXPECT_EQ(mdl.meshes[0].blend_indices.size(), 3u) << "skinned vertices";
    ASSERT_NE(mdl.puppet, nullptr);
    ASSERT_EQ(mdl.puppet->bones.size(), 1u);
    EXPECT_EQ(mdl.puppet->bones[0].name, "root");
    EXPECT_TRUE(mdl.puppet->bones[0].noParent());
    EXPECT_TRUE(mdl.puppet->anims.empty());

    ASSERT_TRUE(wallpaper::WPMdlParser::Parse("masked.mdl", vfs, mdl));
    EXPECT_EQ(mdl.mdlv, 23);
    ASSERT_EQ(mdl.meshes.size(), 2u);
    ASSERT_NE(mdl.puppet, nullptr);
    EXPECT_EQ(mdl.puppet->bones.size(), 1u);

    ASSERT_TRUE(wallpaper::WPMdlParser::Parse("attach.mdl", vfs, mdl));
    ASSERT_EQ(mdl.meshes.size(), 1u);
    ASSERT_NE(mdl.puppet, nullptr);
    ASSERT_EQ(mdl.puppet->bones.size(), 2u);
    EXPECT_EQ(mdl.puppet->bones[1].name, "head");
    EXPECT_EQ(mdl.puppet->bones[1].parent, 0u);
    ASSERT_EQ(mdl.puppet->attachments.size(), 1u);
    EXPECT_EQ(mdl.puppet->attachments[0].name, "hat_anchor");
    const auto& translation = mdl.puppet->attachments[0].local_xform.translation();
    EXPECT_FLOAT_EQ(translation.x(), 4.0f);
    EXPECT_FLOAT_EQ(translation.y(), 5.0f);
    EXPECT_FLOAT_EQ(translation.z(), 6.0f);

    ASSERT_TRUE(wallpaper::WPMdlParser::Parse("mesh.mdl", vfs, mdl));
    ASSERT_EQ(mdl.meshes.size(), 2u);
    EXPECT_EQ(mdl.meshes[0].positions.size(), 3u);
    EXPECT_TRUE(mdl.meshes[0].blend_indices.empty());
    ASSERT_EQ(mdl.meshes[0].texcoords.size(), 3u);
    EXPECT_FLOAT_EQ(mdl.meshes[0].texcoords[1][0], 0.5f);
    EXPECT_FLOAT_EQ(mdl.meshes[0].texcoords[1][1], 0.5f);
    EXPECT_EQ(mdl.puppet, nullptr) << "no skeleton at all";
}

TEST(SchemaFixtures, VideoTextureMarkerReadsAsAVideoHeader)
{
    wallpaper::fs::VFS vfs;
    MountAssets(vfs, { { "/materials/clip.tex", TexVideoMarker() } });
    wallpaper::WPTexImageParser parser(&vfs);
    const auto                  header = parser.ParseHeader("clip");
    EXPECT_TRUE(header.isVideo);
}

// ---- scene documents and the rig ---------------------------------------------------------

TEST(SchemaFixtures, QuietSceneParsesAsACanvasSceneWithNoObjects)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene());
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(scene->ortho[0], 640);
    EXPECT_EQ(scene->ortho[1], 360);
    ASSERT_NE(scene->activeCamera, nullptr);
    EXPECT_FALSE(scene->activeCamera->IsPerspective());
    EXPECT_EQ(scene->runtime, nullptr) << "the id-only overload gives no runtime";
    EXPECT_EQ(FindRootChild(*scene, "group"), nullptr) << "no object, so no layer node";
}

TEST(SchemaFixtures, QuietSceneAppliesGeneralPatchAndObjects)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ { { "id", 1 }, { "name", "group" } } }),
                                      { { "orthogonalprojection", { { "width", 1280 }, { "height", 720 } } } }));
    ASSERT_NE(scene, nullptr);
    EXPECT_EQ(scene->ortho[0], 1280);
    EXPECT_EQ(scene->ortho[1], 720);
    EXPECT_NE(FindRootChild(*scene, "group"), nullptr);
    EXPECT_EQ(FindRootChild(*scene, "nothing"), nullptr);
}

TEST(SchemaFixtures, LiveParseGivesTheSceneARuntime)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(), { .live = true });
    ASSERT_NE(scene, nullptr);
    EXPECT_NE(scene->runtime, nullptr);
}

TEST(SchemaFixtures, PerspectiveSceneParsesWithAPerspectiveCamera)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(PerspectiveScene());
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    EXPECT_TRUE(scene->activeCamera->IsPerspective());
    EXPECT_DOUBLE_EQ(scene->activeCamera->Fov(), 60.0);
    const auto position = scene->activeCamera->GetPosition();
    EXPECT_NEAR(position.x(), 0.0, 1e-4);
    EXPECT_NEAR(position.y(), 10.0, 1e-4);
    EXPECT_NEAR(position.z(), 20.0, 1e-4);
}

TEST(SchemaFixtures, CanvasWithCameraObjectKeepsItsTwoObjects)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(CanvasWithCameraObject({ { "fov", 33 } }));
    ASSERT_NE(scene, nullptr);
    EXPECT_NE(FindRootChild(*scene, "shot"), nullptr);
    EXPECT_NE(FindRootChild(*scene, "canvas image"), nullptr);
    EXPECT_FALSE(scene->activeCamera->IsPerspective());
}

TEST(SchemaFixtures, CameraPathClipsDescribeOneSecondOfMovement)
{
    const Json clip = CameraPathClip(3);
    EXPECT_TRUE(clip.at("visible").get<bool>());
    EXPECT_EQ(clip.at("options").at("fps").get<int>(), 30);
    EXPECT_EQ(clip.at("options").at("length").get<int>(), 30);
    EXPECT_EQ(clip.at("options").at("mode").get<std::string>(), "single");
    EXPECT_EQ(clip.at("eye").at("c0")[0].at("value").get<double>(), 3.0);
    EXPECT_EQ(clip.at("eye").at("c0")[1].at("frame").get<int>(), 30);
    EXPECT_EQ(clip.at("eye").at("c0")[1].at("value").get<double>(), 5.0) << "two units along +x";
    EXPECT_EQ(clip.at("eye").at("c2")[0].at("value").get<double>(), 10.0);
    EXPECT_EQ(clip.at("center").at("c0")[1].at("value").get<double>(), 5.0);
    EXPECT_EQ(clip.at("up").at("c1")[0].at("value").get<double>(), 1.0);
    EXPECT_EQ(clip.at("fov")[0].at("value").get<double>(), 40.0);
    EXPECT_EQ(clip.at("fov")[1].at("value").get<double>(), 60.0);

    EXPECT_FALSE(CameraPathClip(0, false).at("visible").get<bool>());
    EXPECT_EQ(CameraPathClip(0, true, 0).at("options").at("fps").get<int>(), 0);
    EXPECT_EQ(CameraPathClip(0, true, 30, "loop").at("options").at("mode").get<std::string>(), "loop");

    const Json document = Json::parse(CameraPathsText({ clip, CameraPathClip(7) }));
    ASSERT_EQ(document.at("paths").size(), 2u);
    EXPECT_EQ(document.at("paths")[1].at("eye").at("c0")[0].at("value").get<double>(), 7.0);
}

TEST(SchemaFixtures, CameraPathClipsPlayThroughTheRuntimeAndTheSpoiledOnesAreSkipped)
{
    auto files           = BasicAssets();
    files["/paths.json"] = CameraPathsText({ CameraPathClip(0), CameraPathClip(100, false), CameraPathClip(200, true, 0), CameraPathClip(20) });
    ParseRig rig(files);
    auto     scene = rig.Parse(PerspectiveScene(Json::array({ { { "id", 1 }, { "name", "moving" }, { "camera", "default" }, { "path", "paths.json" } } })),
                           { .live = true });
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->activeCamera, nullptr);
    EXPECT_NEAR(scene->activeCamera->GetPosition().z(), 10.0, 1e-5);
    scene->runtime->Tick(0.5);
    EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 1.0, 1e-5);
    scene->runtime->Tick(0.75);
    EXPECT_NEAR(scene->activeCamera->GetPosition().x(), 20.5, 1e-5) << "the hidden and the zero-fps clips were not in the queue";
}

TEST(SchemaFixtures, ThePackageVersionOfTheRequestReachesTheGates)
{
    FileMap files = BasicAssets();
    Add(files, BloomAssets(BloomSet::Hdr));
    ParseRig   rig(files);
    const Json scene_json = QuietScene(Json::array(), { { "bloom", true }, { "hdr", true } });
    EXPECT_FALSE(rig.Parse(scene_json, { .pkg_version = 9 })->hdr) << "hdr is read from package version 10";
    EXPECT_TRUE(rig.Parse(scene_json, { .pkg_version = 10 })->hdr);
    EXPECT_TRUE(rig.Parse(scene_json)->hdr) << "an unknown version reads everything";
}

TEST(SchemaFixtures, PuppetAssetsBuildALayerWithTwoMaterialSlots)
{
    ParseRig rig(PuppetAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ { { "id", 1 }, { "name", "puppet" }, { "image", "puppet_image.json" } } })));
    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "puppet");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
}

TEST(SchemaFixtures, EveryPuppetVariantBuildsALayer)
{
    const Json scene_json = QuietScene(Json::array({ { { "id", 1 }, { "name", "puppet" }, { "image", "puppet_image.json" } } }));
    struct Variant {
        const char*   name;
        PuppetOptions options;
    };
    const Variant variants[] = {
        { "plain", {} },
        { "render target eyes", { .eyes_render_target = true } },
        { "masked", { .masked = true } },
        { "mesh only", { .mesh_only = true } },
    };
    for (const Variant& variant : variants) {
        SCOPED_TRACE(variant.name);
        ParseRig rig(PuppetAssets(variant.options));
        auto     scene = rig.Parse(scene_json);
        ASSERT_NE(scene, nullptr);
        auto* node = FindRootChild(*scene, "puppet");
        ASSERT_NE(node, nullptr);
        ASSERT_NE(node->Mesh(), nullptr);
        EXPECT_GE(node->Mesh()->MaterialSlots().size(), 2u);
    }
}

TEST(SchemaFixtures, PuppetOptionsChangeTheFileSetAsDocumented)
{
    EXPECT_EQ(PuppetAssets().count("/mat/eyes.json"), 1u);
    EXPECT_EQ(PuppetAssets({ .eyes_material = false }).count("/mat/eyes.json"), 0u);
    EXPECT_NE(PuppetAssets({ .eyes_render_target = true }).at("/mat/eyes.json").find("_rt_4FrameBuffer"), std::string::npos);
    EXPECT_EQ(PuppetAssets().count("/mat/head_mask.json"), 0u);
    const auto masked = PuppetAssets({ .masked = true });
    EXPECT_EQ(masked.count("/mat/head_mask.json"), 1u);
    EXPECT_EQ(masked.count("/shaders/clippingmaskimage4.frag"), 1u);
    EXPECT_EQ(masked.at("/puppet.mdl"), MdlMaskedHead());
    EXPECT_EQ(PuppetAssets({ .mesh_only = true }).at("/puppet.mdl"), MdlMeshOnly());
    EXPECT_EQ(PuppetAssets().at("/puppet.mdl"), MdlTwoMeshes());
}

TEST(SchemaFixtures, LeafModelAssetsGiveTwoDistinguishableSlots)
{
    ParseRig rig(LeafModelAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ { { "id", 7 }, { "name", "planet" }, { "model", "planet.mdl" } } })));
    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "planet");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    ASSERT_EQ(node->Mesh()->MaterialSlots().size(), 2u);
    const auto& head = *node->Mesh()->MaterialSlots()[0];
    const auto& eyes = *node->Mesh()->MaterialSlots()[1];
    EXPECT_EQ(head.cull_mode, wallpaper::CullMode::Back);
    EXPECT_EQ(eyes.cull_mode, wallpaper::CullMode::None);
    EXPECT_TRUE(head.depth_write);
    EXPECT_FALSE(eyes.depth_write);
}

TEST(SchemaFixtures, LdrBloomStandInsCarryDistinctConstantsForTheSceneToOverwrite)
{
    const FileMap files   = BloomAssets(BloomSet::Ldr);
    const Json    extract = Json::parse(files.at("/materials/util/downsample_quarter_bloom.json"));
    const Json&   values  = extract.at("passes")[0].at("constantshadervalues");
    EXPECT_EQ(values.at("bloomstrength").get<int>(), 9);
    EXPECT_EQ(values.at("bloomthreshold").get<int>(), 9);
    EXPECT_EQ(values.at("bloomtint").get<std::string>(), "9 9 9");
    for (const char* name : { "downsample_eighth_blur_v", "blur_h_bloom", "combine_ldr" }) {
        EXPECT_EQ(files.count(std::string("/materials/util/") + name + ".json"), 1u) << name;
    }
    EXPECT_EQ(BloomAssets(BloomSet::LdrBroken).count("/materials/util/combine_ldr.json"), 0u);
    EXPECT_EQ(BloomAssets(BloomSet::LdrBroken).count("/materials/util/blur_h_bloom.json"), 1u);

    const FileMap hdr = BloomAssets(BloomSet::Hdr);
    for (const auto& [material, shader] : std::vector<std::pair<std::string, std::string>> { { "hdr_downsample_bloom", "hdr_extract" }, { "hdr_downsample", "hdr_down" }, { "hdr_upsample", "hdr_up" }, { "hdr_upsample_cubic", "hdr_cubic" }, { "combine_hdr_upsample_linear", "hdr_combine" } }) {
        const Json document = Json::parse(hdr.at("/materials/util/" + material + ".json"));
        EXPECT_EQ(document.at("passes")[0].at("shader").get<std::string>(), shader);
        EXPECT_EQ(hdr.count("/shaders/" + shader + ".frag"), 1u);
        EXPECT_NE(hdr.at("/shaders/" + shader + ".frag").find("g_BloomScatter"), std::string::npos);
    }
}

TEST(SchemaFixtures, LdrBloomAssetsBuildTheChainAndTheBrokenSetDoesNot)
{
    const Json bloom_scene = QuietScene(Json::array(), { { "bloom", true }, { "bloomstrength", 1.5 }, { "bloomthreshold", 0.25 }, { "bloomtint", Json::array({ 0.2, 0.4, 0.6 }) } });
    {
        ParseRig rig(BloomAssets(BloomSet::Ldr));
        auto     scene = rig.Parse(bloom_scene);
        ASSERT_NE(scene, nullptr);
        ASSERT_EQ(scene->post_processes.size(), 1u);
        const auto& chain = *scene->post_processes[0];
        ASSERT_NE(PassStep(chain, 0), nullptr);
        ASSERT_NE(CopyStep(chain, 4), nullptr);
        const auto& values = PassStep(chain, 0)->node->Mesh()->Material()->customShader.constValues;
        ASSERT_TRUE(values.count("g_BloomStrength"));
        EXPECT_FLOAT_EQ(values.at("g_BloomStrength")[0], 1.5f) << "the scene's value replaces the stand-in's 9";
        EXPECT_FLOAT_EQ(values.at("g_BloomThreshold")[0], 0.25f);
        EXPECT_FLOAT_EQ(values.at("g_BloomTint")[2], 0.6f);
    }
    {
        ParseRig rig(BloomAssets(BloomSet::LdrBroken));
        auto     scene = rig.Parse(bloom_scene);
        ASSERT_NE(scene, nullptr);
        EXPECT_TRUE(scene->post_processes.empty()) << "a chain without its combine material is not installed";
    }
}

TEST(SchemaFixtures, HdrBloomAssetsBuildTheHdrChain)
{
    ParseRig rig(BloomAssets(BloomSet::Hdr));
    auto     scene = rig.Parse(QuietScene(Json::array(), { { "bloom", true }, { "hdr", true } }));
    ASSERT_NE(scene, nullptr);
    ASSERT_EQ(scene->post_processes.size(), 1u);
    EXPECT_GE(scene->post_processes[0]->steps.size(), 3u);
    ASSERT_NE(PassStep(*scene->post_processes[0], 0), nullptr);
    EXPECT_EQ(PassStep(*scene->post_processes[0], 0)->node->Name(), "__bloom_hdr_extract");
}

TEST(SchemaFixtures, TreeHelpersReadVertices)
{
    ParseRig rig(BasicAssets());
    auto     scene = rig.Parse(QuietScene(Json::array({ { { "id", 1 }, { "name", "layer" }, { "image", "image.json" }, { "origin", Json::array({ 100, 50, 0 }) }, { "size", Json::array({ 64, 32 }) } } })));
    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "layer");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& vertices = node->Mesh()->GetVertexArray(0);
    ASSERT_GE(vertices.VertexCount(), 4u);

    // The card is a 64x32 rectangle: its corners have texture coordinates 0 or 1 on each axis, and
    // a vertex further along an axis has the larger coordinate on it.
    std::set<std::pair<float, float>> corners;
    for (std::size_t i = 0; i < 4; ++i) {
        const auto position = VertexPosition(vertices, i);
        const auto uv       = VertexUv(vertices, i);
        EXPECT_TRUE(uv[0] == 0.0f || uv[0] == 1.0f) << i;
        EXPECT_TRUE(uv[1] == 0.0f || uv[1] == 1.0f) << i;
        EXPECT_TRUE(std::abs(std::abs(position[0]) - 32.0f) < 1e-3f) << "half the width, got " << position[0];
        EXPECT_TRUE(std::abs(std::abs(position[1]) - 16.0f) < 1e-3f) << "half the height, got " << position[1];
        corners.insert({ uv[0], uv[1] });
    }
    EXPECT_EQ(corners.size(), 4u) << "the four vertices carry the four corners";

    EXPECT_TRUE(NearArray({ 1.0f, 2.0f, 3.0f }, { 1.0f, 2.0f, 3.0f }, 0.0f));
    EXPECT_FALSE(NearArray({ 1.0f, 2.0f, 3.5f }, { 1.0f, 2.0f, 3.0f }, 0.1f));
    EXPECT_TRUE(NearArray({ 1.0f, 2.0f, 3.05f }, { 1.0f, 2.0f, 3.0f }, 0.1f));
}

} // namespace
