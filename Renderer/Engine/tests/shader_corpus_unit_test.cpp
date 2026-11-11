// Always-run tests of the corpus model in shader_corpus_support.hpp: how a scene
// becomes a list of materials and a material becomes a compile job, the guards on
// roots and paths, and the gates in front of the on-request sweep.

#include "shader_corpus_support.hpp"

#include "Fs/VFS.h"
#include "shader_test_scratch.hpp"

#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include <unistd.h>

#include <algorithm>
#include <set>

using namespace wallpaper;
using namespace wallpaper::corpus;
using nlohmann::json;
using shader_test::ScratchFolder;
using shader_test::WriteFile;

namespace
{

void WriteJson(const stdfs::path& path, const json& document) { WriteFile(path, document.dump()); }

Expectation PlainExpectation() {
    Expectation expectation;
    expectation.source      = "/workshop/materials/custom.json";
    expectation.context     = "image object 'Layer' (id 7) materials/custom.json";
    expectation.identity    = "node:Layer/material-slot-0";
    expectation.shader_name = "effects/custom";
    expectation.shader_path = "shaders/effects/custom";
    return expectation;
}

json CustomMaterial() {
    return json::parse(R"({"passes":[{"shader":"effects/custom","blending":"alphatocoverage",
        "textures":["materials/albedo.tex",null,"materials/mask.tex"],"combos":{"USE_DETAIL":1,"MODE":3}}]})");
}

json LayerObject(const json& extra = json::object()) {
    json object = { { "id", 7 }, { "name", "Layer" }, { "visible", true }, { "image", "materials/layer.json" } };
    object.update(extra);
    return object;
}

// A scene folder with an image layer that has no material of its own, plus whatever the test adds.
struct SceneFolder {
    ScratchFolder scratch;
    SceneFolder() { WriteJson(scratch.sub("materials/layer.json"), { { "material", "" } }); }

    Collection Collect(const json& scene, const std::optional<stdfs::path>& common = std::nullopt) {
        fs::VFS vfs;
        return CollectExpectations(scene, Roots { scratch.path(), common }, vfs, "2799421411");
    }
    Collection CollectObjects(const json& objects, const json& general = json::object()) {
        return Collect({ { "objects", objects }, { "general", general } });
    }
};

void WriteMaterial(const stdfs::path& path, const std::string& shader, const json& combos = nullptr) {
    json pass = { { "shader", shader } };
    if (! combos.is_null()) pass["combos"] = combos;
    WriteJson(path, { { "passes", json::array({ pass }) } });
}

} // namespace

// CS-01 -------------------------------------------------------------------------------------------

TEST(ShaderCorpusJobs, JobIsBuiltFromTheMaterialDocumentAlone) {
    const Expectation wanted = PlainExpectation();
    const auto        built  = BuildJob(wanted, CustomMaterial());
    ASSERT_TRUE(built.has_value());
    const CompileJob& job = *built;

    // Where it came from and what it compiles.
    EXPECT_EQ(std::make_pair(job.source, job.context), std::make_pair(wanted.source, wanted.context));
    EXPECT_EQ(std::make_pair(job.shader_name, job.shader_path),
              std::make_pair(std::string("effects/custom"), std::string("shaders/effects/custom")));

    // The combo table holds exactly the material's integer combos plus the blending flag.
    EXPECT_EQ(job.combos, (ComboText { { "ALPHATOCOVERAGE", "1" }, { "MODE", "3" }, { "USE_DETAIL", "1" } }));

    // A null texture entry keeps its place as an empty path.
    EXPECT_EQ(job.base_textures, (std::vector<std::string> { "materials/albedo.tex", "", "materials/mask.tex" }));

    // The conservative texture records follow the paths, never a texture header.
    std::vector<bool> enabled;
    for (const auto& record : job.texture_infos) {
        enabled.push_back(record.enabled);
        EXPECT_EQ(record.present, record.enabled);
    }
    EXPECT_EQ(enabled, (std::vector<bool> { true, false, true }));
    const auto& flags = job.texture_infos.at(0).composEnabled;
    EXPECT_EQ(std::count(flags.begin(), flags.begin() + 3, true), 0);
}

TEST(ShaderCorpusJobs, BlendingSetsOnlyItsOwnCombo) {
    // ALPHATOCOVERAGE and ADDITIVE come from the material's own `blending`
    // (Wallpaper Engine sub_140154480).
    {
        auto material                     = CustomMaterial();
        material["passes"][0]["blending"] = "additive";
        const auto job                    = BuildJob(PlainExpectation(), material);
        ASSERT_TRUE(job.has_value());
        EXPECT_EQ(job->combos.count("ALPHATOCOVERAGE"), 0u);
        ASSERT_EQ(job->combos.count("ADDITIVE"), 1u);
        EXPECT_EQ(job->combos.at("ADDITIVE"), "1");
    }
    {
        auto material                     = CustomMaterial();
        material["passes"][0]["blending"] = "translucent";
        const auto job                    = BuildJob(PlainExpectation(), material);
        ASSERT_TRUE(job.has_value());
        EXPECT_EQ(job->combos.count("ALPHATOCOVERAGE"), 0u);
        EXPECT_EQ(job->combos.count("ADDITIVE"), 0u);
    }
    auto material = CustomMaterial();
    material["passes"][0].erase("blending");
    EXPECT_EQ(BuildJob(PlainExpectation(), material)->combos.count("ALPHATOCOVERAGE"), 0u);
    EXPECT_EQ(BuildJob(PlainExpectation(), material)->combos.count("ADDITIVE"), 0u);
}

TEST(ShaderCorpusJobs, OnlyIntegerCombosAreTaken) {
    auto material                    = CustomMaterial();
    material["passes"][0]["combos"]  = { { "MODE", "3" }, { "X", 1.5 }, { "Y", true }, { "Z", 4 } };
    const auto job                   = BuildJob(PlainExpectation(), material);
    ASSERT_TRUE(job.has_value());
    EXPECT_EQ(job->combos.count("MODE"), 0u);
    EXPECT_EQ(job->combos.count("X"), 0u);
    EXPECT_EQ(job->combos.count("Y"), 0u);
    EXPECT_EQ(job->combos.at("Z"), "4");
}

TEST(ShaderCorpusJobs, ShaderNameComesFromTheExpectationFirst) {
    auto expectation        = PlainExpectation();
    auto material           = CustomMaterial();
    material["passes"][0]["shader"] = "effects/from_material";

    EXPECT_EQ(BuildJob(expectation, material)->shader_name, "effects/custom");

    expectation.shader_name.clear();
    expectation.shader_path.clear();
    const auto job = BuildJob(expectation, material);
    ASSERT_TRUE(job.has_value());
    EXPECT_EQ(job->shader_name, "effects/from_material");
    EXPECT_EQ(job->shader_path, "shaders/effects/from_material");
}

TEST(ShaderCorpusJobs, MaterialsWithoutAUsableFirstPassMakeNoJob) {
    const auto expectation = PlainExpectation();
    EXPECT_FALSE(BuildJob(expectation, json::object()).has_value());
    EXPECT_FALSE(BuildJob(expectation, json { { "passes", json::array() } }).has_value());
    EXPECT_FALSE(BuildJob(expectation, json { { "passes", "not a list" } }).has_value());
    EXPECT_FALSE(BuildJob(expectation, json { { "passes", json::array({ 5 }) } }).has_value());

    auto nameless = expectation;
    nameless.shader_name.clear();
    EXPECT_FALSE(BuildJob(nameless, json { { "passes", json::array({ json::object() }) } }).has_value());
}

TEST(ShaderCorpusJobs, SceneCombosOverrideAndExtendTheMaterialsCombos) {
    auto expectation                = PlainExpectation();
    expectation.scene_combos["MODE"] = "9";
    expectation.scene_combos["FRESH"] = "2";
    const auto job                  = BuildJob(expectation, CustomMaterial());
    ASSERT_TRUE(job.has_value());
    EXPECT_EQ(job->combos.at("MODE"), "9");
    EXPECT_EQ(job->combos.at("FRESH"), "2");
    EXPECT_EQ(job->combos.at("USE_DETAIL"), "1");
}

TEST(ShaderCorpusJobs, AnUnreadableMaterialIsABlockerNotAJob) {
    ScratchFolder scratch;
    auto          expectation = PlainExpectation();
    expectation.source        = scratch.sub("materials/nowhere.json");

    std::vector<Blocker> blockers;
    EXPECT_FALSE(BuildJob(expectation, blockers).has_value());
    EXPECT_EQ(blockers.size(), 1u);

    WriteJson(expectation.source, CustomMaterial());
    blockers.clear();
    const auto job = BuildJob(expectation, blockers);
    ASSERT_TRUE(job.has_value());
    EXPECT_TRUE(blockers.empty());
    EXPECT_EQ(job->combos.at("MODE"), "3");
}

// CS-02 -------------------------------------------------------------------------------------------

TEST(ShaderCorpusRoots, BroadRootsAreRefused) {
    for (const char* broad : { "/", "/Users", "/Library", "/System", "/private", "/Volumes", "/Users/", "/Library/x/.." }) {
        EXPECT_TRUE(RefuseCorpusRoot(broad).has_value()) << broad;
    }
}

TEST(ShaderCorpusRoots, MissingFilesAndLinksAreRefusedButRealFoldersAreNot) {
    ScratchFolder scratch;
    const auto    real = scratch.sub("real");
    stdfs::create_directories(real);
    WriteFile(scratch.sub("plain.txt"), "x");
    stdfs::create_directory_symlink(real, scratch.sub("link"));

    EXPECT_FALSE(RefuseCorpusRoot(real).has_value());
    EXPECT_TRUE(RefuseCorpusRoot(scratch.sub("absent")).has_value());
    EXPECT_TRUE(RefuseCorpusRoot(scratch.sub("plain.txt")).has_value());
    EXPECT_TRUE(RefuseCorpusRoot(scratch.sub("link")).has_value());
}

// CS-03 -------------------------------------------------------------------------------------------

TEST(ShaderCorpusRoots, PathsThatLeaveTheRootAreRefused) {
    const stdfs::path root = "/tmp/unpack/123";
    EXPECT_EQ(ResolveInRoot(root, "materials/layer.json"), (stdfs::path("/tmp/unpack/123/materials/layer.json")));
    EXPECT_FALSE(ResolveInRoot(root, "../other/scene.json").has_value());
    EXPECT_FALSE(ResolveInRoot(root, "../../Library/Secrets/scene.json").has_value());
    EXPECT_FALSE(ResolveInRoot(root, "/Library/Secrets/scene.json").has_value());
    EXPECT_FALSE(ResolveInRoot(root, "").has_value());
    EXPECT_EQ(ResolveInRoot(root, "a/../b.json"), (stdfs::path("/tmp/unpack/123/b.json")));
    EXPECT_FALSE(ResolveInRoot(root, "a/../../b.json").has_value());
    EXPECT_FALSE(ResolveInRoot(root, "../123-sibling/x").has_value());
}

// CS-04 -------------------------------------------------------------------------------------------

namespace
{
struct WorkshopFolderScene : SceneFolder {
    WorkshopFolderScene() {
        WriteJson(scratch.sub("2799421411/effects/visible.json"),
                  { { "name", "visible-workshop-effect" },
                    { "passes", json::array({ { { "material", "2799421411/materials/effect.json" } } }) } });
        WriteMaterial(scratch.sub("2799421411/materials/effect.json"), "effects/visible_workshop_shader");
    }
    static json EffectRef(bool visible = true) {
        return { { "visible", visible }, { "file", "2799421411/effects/visible.json" } };
    }
};
} // namespace

TEST(ShaderCorpusScene, VisibleEffectUnderAWorkshopIdFolderIsCollected) {
    WorkshopFolderScene folder;
    const auto result = folder.CollectObjects(json::array({ LayerObject({ { "effects", json::array({ folder.EffectRef() }) } }) }));

    EXPECT_TRUE(result.blockers.empty());
    ASSERT_EQ(result.expectations.size(), 1u);
    const auto& found = result.expectations[0];
    EXPECT_EQ(found.source, (folder.scratch.path() / "2799421411/materials/effect.json").lexically_normal());
    EXPECT_EQ(found.shader_name, "effects/visible_workshop_shader");
    EXPECT_EQ(found.shader_path, "shaders/effects/visible_workshop_shader");
    EXPECT_EQ(found.identity, "node:Layer/effect-0/pass-0/material-slot-0");
    EXPECT_NE(found.context.find("visible-workshop-effect"), std::string::npos) << found.context;
}

TEST(ShaderCorpusScene, HiddenEffectsAndObjectsAreSkippedUnlessVisibilityIsDynamic) {
    WorkshopFolderScene folder;
    const json effects = json::array({ folder.EffectRef() });

    auto hidden_effect = folder.CollectObjects(json::array({ LayerObject({ { "effects", json::array({ folder.EffectRef(false) }) } }) }));
    EXPECT_TRUE(hidden_effect.expectations.empty());
    EXPECT_TRUE(hidden_effect.blockers.empty());

    EXPECT_TRUE(folder.CollectObjects(json::array({ LayerObject({ { "effects", effects }, { "visible", false } }) }))
                    .expectations.empty());
    EXPECT_TRUE(folder.CollectObjects(json::array({ LayerObject({ { "effects", effects }, { "visible", { { "value", false } } } }) }))
                    .expectations.empty());
    EXPECT_EQ(folder.CollectObjects(json::array({ LayerObject({ { "effects", effects }, { "visible", { { "user", "x" } } } }) }))
                  .expectations.size(), 1u);
    EXPECT_EQ(folder.CollectObjects(json::array({ LayerObject({ { "effects", effects },
                                                                { "visible", { { "value", false }, { "script", "return false;" } } } }) }))
                  .expectations.size(), 1u);
}

TEST(ShaderCorpusScene, MissingEffectFileIsOneBlockerNamingIt) {
    WorkshopFolderScene folder;
    stdfs::remove(folder.scratch.sub("2799421411/effects/visible.json"));
    const auto result = folder.CollectObjects(json::array({ LayerObject({ { "effects", json::array({ folder.EffectRef() }) } }) }));
    EXPECT_TRUE(result.expectations.empty());
    ASSERT_EQ(result.blockers.size(), 1u);
    EXPECT_NE(result.blockers[0].message.find("2799421411/effects/visible.json"), std::string::npos)
        << result.blockers[0].message;
}

TEST(ShaderCorpusScene, EffectNumberingCountsVisibleEffectsOnly) {
    WorkshopFolderScene folder;
    const auto result = folder.CollectObjects(json::array({ LayerObject(
        { { "effects", json::array({ folder.EffectRef(), folder.EffectRef(false), folder.EffectRef() }) } }) }));
    ASSERT_EQ(result.expectations.size(), 2u);
    EXPECT_EQ(result.expectations[0].identity, "node:Layer/effect-0/pass-0/material-slot-0");
    EXPECT_EQ(result.expectations[1].identity, "node:Layer/effect-1/pass-0/material-slot-0");
}

TEST(ShaderCorpusScene, BloomAddsFourUtilityMaterialsOrFourBlockers) {
    SceneFolder folder;
    const json  general = { { "bloom", true } };
    EXPECT_EQ(folder.CollectObjects(json::array(), general).blockers.size(), 4u);
    EXPECT_TRUE(folder.CollectObjects(json::array(), general).expectations.empty());

    for (const char* stem : { "downsample_quarter_bloom", "downsample_eighth_blur_v", "blur_h_bloom", "combine_ldr" }) {
        WriteMaterial(folder.scratch.sub(std::string("materials/util/") + stem + ".json"), std::string("util/") + stem);
    }
    const auto result = folder.CollectObjects(json::array(), general);
    EXPECT_TRUE(result.blockers.empty());
    std::set<std::string> shaders;
    for (const auto& expectation : result.expectations) shaders.insert(expectation.shader_name);
    EXPECT_EQ(result.expectations.size(), 4u);
    EXPECT_EQ(shaders, (std::set<std::string> { "util/downsample_quarter_bloom", "util/downsample_eighth_blur_v",
                                                "util/blur_h_bloom", "util/combine_ldr" }));
    EXPECT_TRUE(folder.CollectObjects(json::array(), { { "bloom", false } }).expectations.empty());
}

TEST(ShaderCorpusScene, ParticleMaterialIsCollectedAndRopeRenderersForceTheRopeShader) {
    SceneFolder folder;
    WriteMaterial(folder.scratch.sub("materials/spark.json"), "genericparticle");
    const json objects = json::array({ { { "id", 9 }, { "name", "Sparks" }, { "particle", "particles/spark.json" } } });

    WriteJson(folder.scratch.sub("particles/spark.json"), { { "material", "materials/spark.json" } });
    auto plain = folder.CollectObjects(objects);
    ASSERT_EQ(plain.expectations.size(), 1u);
    EXPECT_EQ(plain.expectations[0].shader_name, "genericparticle");

    WriteJson(folder.scratch.sub("particles/spark.json"),
              { { "material", "materials/spark.json" }, { "renderer", json::array({ { { "name", "rope_trail" } } }) } });
    auto rope = folder.CollectObjects(objects);
    ASSERT_EQ(rope.expectations.size(), 1u);
    EXPECT_EQ(rope.expectations[0].shader_name, "genericropeparticle");
    EXPECT_EQ(rope.expectations[0].shader_path, "shaders/genericropeparticle");
}

TEST(ShaderCorpusScene, ParticleChildrenAreVisitedOnceEvenWhenTheyLoop) {
    SceneFolder folder;
    WriteMaterial(folder.scratch.sub("materials/spark.json"), "genericparticle");
    WriteJson(folder.scratch.sub("particles/parent.json"),
              { { "material", "materials/spark.json" }, { "children", json::array({ { { "name", "particles/child.json" } } }) } });
    WriteJson(folder.scratch.sub("particles/child.json"),
              { { "material", "materials/spark.json" }, { "children", json::array({ { { "name", "particles/parent.json" } } }) } });

    const auto result = folder.CollectObjects(json::array({ { { "id", 9 }, { "name", "Sparks" }, { "particle", "particles/parent.json" } } }));
    ASSERT_EQ(result.expectations.size(), 2u);
    EXPECT_EQ(result.expectations[0].identity, "node:Sparks/material-slot-0");
    EXPECT_EQ(result.expectations[1].identity, "node:Sparks/child-0/material-slot-0");
}

TEST(ShaderCorpusScene, ColourBlendModeAddsThePassthroughMaterial) {
    SceneFolder folder;
    WriteMaterial(folder.scratch.sub("materials/util/effectpassthrough.json"), "effectpassthrough");

    const auto blended = folder.CollectObjects(json::array({ LayerObject({ { "colorBlendMode", 5 } }) }));
    ASSERT_EQ(blended.expectations.size(), 1u);
    EXPECT_EQ(blended.expectations[0].identity, "node:Layer/effect-0/pass-0/material-slot-0");
    EXPECT_EQ(blended.expectations[0].shader_name, "effectpassthrough");

    EXPECT_TRUE(folder.CollectObjects(json::array({ LayerObject({ { "colorBlendMode", 0 } }) })).expectations.empty());
    EXPECT_TRUE(folder.CollectObjects(json::array({ LayerObject({ { "colorBlendMode", 31 } }) })).expectations.empty());
}

TEST(ShaderCorpusScene, BaseMaterialAndIdentityNaming) {
    SceneFolder folder;
    WriteMaterial(folder.scratch.sub("materials/base.json"), "flat");
    WriteJson(folder.scratch.sub("materials/shaded.json"), { { "material", "materials/base.json" } });

    // Two layers share a name, so their identities fall back to the layer id.
    json first  = LayerObject({ { "image", "materials/shaded.json" } });
    json second = LayerObject({ { "id", 8 }, { "image", "materials/shaded.json" } });
    auto shared = folder.CollectObjects(json::array({ first, second }));
    ASSERT_EQ(shared.expectations.size(), 2u);
    EXPECT_EQ(shared.expectations[0].identity, "node:__we_layer_7/material-slot-0");
    EXPECT_EQ(shared.expectations[1].identity, "node:__we_layer_8/material-slot-0");

    second["name"] = "Other";
    auto distinct  = folder.CollectObjects(json::array({ first, second }));
    ASSERT_EQ(distinct.expectations.size(), 2u);
    EXPECT_EQ(distinct.expectations[0].identity, "node:Layer/material-slot-0");
    EXPECT_EQ(distinct.expectations[1].identity, "node:Other/material-slot-0");
}

TEST(ShaderCorpusScene, PassthroughAndComposeLayersWithoutEffectsDrawNoBaseMaterial) {
    SceneFolder folder;
    WriteMaterial(folder.scratch.sub("materials/base.json"), "flat");
    WriteJson(folder.scratch.sub("materials/pass.json"), { { "material", "materials/base.json" }, { "passthrough", true } });
    WriteJson(folder.scratch.sub("models/util/composelayer.json"), { { "material", "materials/base.json" } });

    EXPECT_TRUE(folder.CollectObjects(json::array({ LayerObject({ { "image", "materials/pass.json" } }) })).expectations.empty());
    // The object's own setting overrides the image's.
    EXPECT_EQ(folder.CollectObjects(json::array({ LayerObject({ { "image", "materials/pass.json" }, { "config", { { "passthrough", false } } } }) }))
                  .expectations.size(), 1u);
    EXPECT_TRUE(folder.CollectObjects(json::array({ LayerObject({ { "image", "models/util/composelayer.json" } }) }))
                    .expectations.empty());
    EXPECT_EQ(folder.CollectObjects(json::array({ LayerObject({ { "image", "models/util/composelayer.json" }, { "copybackground", false } }) }))
                  .expectations.size(), 1u);
}

TEST(ShaderCorpusScene, ComposeLayerWithChildrenAndNoEffectsRendersThroughPassthrough) {
    SceneFolder folder;
    WriteMaterial(folder.scratch.sub("materials/util/effectpassthrough.json"), "effectpassthrough");
    WriteJson(folder.scratch.sub("models/util/composelayer.json"), { { "material", "" } });

    const json compose = LayerObject({ { "image", "models/util/composelayer.json" }, { "copybackground", false } });
    const json child   = { { "id", 8 }, { "name", "Child" }, { "parent", 7 }, { "image", "materials/layer.json" } };
    const auto result  = folder.CollectObjects(json::array({ compose, child }));
    ASSERT_EQ(result.expectations.size(), 1u);
    EXPECT_EQ(result.expectations[0].shader_name, "effectpassthrough");

    const json lonely = LayerObject({ { "image", "models/util/composelayer.json" }, { "copybackground", false } });
    EXPECT_TRUE(folder.CollectObjects(json::array({ lonely })).expectations.empty());
}

TEST(ShaderCorpusScene, UnparsablePuppetModelBlocksTheLayer) {
    SceneFolder folder;
    WriteMaterial(folder.scratch.sub("materials/base.json"), "flat");
    WriteJson(folder.scratch.sub("materials/puppet.json"), { { "material", "materials/base.json" }, { "puppet", "models/ghost.mdl" } });

    const auto result = folder.CollectObjects(json::array({ LayerObject({ { "image", "materials/puppet.json" } }) }));
    EXPECT_TRUE(result.expectations.empty());
    EXPECT_EQ(result.blockers.size(), 1u);

    WriteJson(folder.scratch.sub("materials/escape.json"), { { "material", "materials/base.json" }, { "puppet", "../outside.mdl" } });
    const auto escaping = folder.CollectObjects(json::array({ LayerObject({ { "image", "materials/escape.json" } }) }));
    EXPECT_TRUE(escaping.expectations.empty());
    EXPECT_EQ(escaping.blockers.size(), 1u);
}

TEST(ShaderCorpusScene, SceneFolderShadowsTheCommonAssets) {
    SceneFolder  folder;
    ScratchFolder common_assets_holder;
    const auto   common = common_assets_holder.sub("common");
    WriteMaterial(common / "materials/shared.json", "common_shader");
    WriteMaterial(common / "materials/both.json", "common_both");
    WriteMaterial(folder.scratch.sub("materials/both.json"), "scene_both");
    WriteJson(folder.scratch.sub("materials/uses.json"), { { "material", "materials/shared.json" } });
    WriteJson(folder.scratch.sub("materials/uses_both.json"), { { "material", "materials/both.json" } });

    const auto from_common =
        folder.Collect({ { "objects", json::array({ LayerObject({ { "image", "materials/uses.json" } }) }) } }, common);
    ASSERT_EQ(from_common.expectations.size(), 1u);
    EXPECT_EQ(from_common.expectations[0].shader_name, "common_shader");

    const auto shadowed =
        folder.Collect({ { "objects", json::array({ LayerObject({ { "image", "materials/uses_both.json" } }) }) } }, common);
    ASSERT_EQ(shadowed.expectations.size(), 1u);
    EXPECT_EQ(shadowed.expectations[0].shader_name, "scene_both");

    // Without the common assets the shared material is a blocker, not a failure.
    const auto missing = folder.Collect({ { "objects", json::array({ LayerObject({ { "image", "materials/uses.json" } }) }) } });
    EXPECT_TRUE(missing.expectations.empty());
    EXPECT_EQ(missing.blockers.size(), 1u);
}

// CS-05 -------------------------------------------------------------------------------------------

namespace
{
struct BarsScene : SceneFolder {
    BarsScene() {
        WriteJson(scratch.sub("effects/bars.json"),
                  { { "name", "bars" },
                    { "passes",
                      json::array({ { { "material", "materials/first.json" } },
                                    { { "command", "copy" }, { "target", "_rt_copy" }, { "source", "previous" } },
                                    { { "material", "materials/second.json" }, { "combos", { { "FROM_FILE", 1 }, { "BOTH", 1 } } } } }) } });
        WriteMaterial(scratch.sub("materials/first.json"), "effects/first", { { "SHAPE", 0 }, { "KEPT", 1 } });
        WriteMaterial(scratch.sub("materials/second.json"), "effects/second");
    }

    struct Jobs {
        Collection             collected;
        std::vector<CompileJob> jobs;
    };
    Jobs Build(const json& effect_reference) {
        Jobs result;
        result.collected = CollectObjects(json::array({ LayerObject({ { "effects", json::array({ effect_reference }) } }) }));
        for (const auto& expectation : result.collected.expectations) {
            if (auto job = BuildJob(expectation, result.collected.blockers)) result.jobs.push_back(std::move(*job));
        }
        return result;
    }
    static json Reference(const json& passes = nullptr) {
        json reference = { { "visible", true }, { "file", "effects/bars.json" } };
        if (! passes.is_null()) reference["passes"] = passes;
        return reference;
    }
};

json SceneChoices() {
    return json::array({ { { "combos", { { "SHAPE", 7 }, { "NOT_AN_INTEGER", "x" } } } }, { { "combos", { { "BOTH", 2 } } } } });
}
} // namespace

TEST(ShaderCorpusScene, EffectIsCompiledUnderTheCombosTheSceneSetsOnItsPasses) {
    BarsScene folder;
    const auto built = folder.Build(BarsScene::Reference(SceneChoices()));

    EXPECT_TRUE(built.collected.blockers.empty());
    ASSERT_EQ(built.collected.expectations.size(), 2u);
    ASSERT_EQ(built.jobs.size(), 2u);
    EXPECT_EQ(built.jobs[0].combos.at("SHAPE"), "7");
    EXPECT_EQ(built.jobs[0].combos.at("KEPT"), "1");
    EXPECT_EQ(built.jobs[0].combos.count("NOT_AN_INTEGER"), 0u);
    EXPECT_EQ(built.jobs[1].combos.at("FROM_FILE"), "1");
    EXPECT_EQ(built.jobs[1].combos.at("BOTH"), "2");

    // Identities count material passes only: the second one is pass-1 although it is the third raw pass.
    EXPECT_EQ(built.collected.expectations[0].identity, "node:Layer/effect-0/pass-0/material-slot-0");
    EXPECT_EQ(built.collected.expectations[1].identity, "node:Layer/effect-0/pass-1/material-slot-0");
    EXPECT_NE(built.collected.expectations[1].context.find("source-pass-2"), std::string::npos);
}

TEST(ShaderCorpusScene, SceneEntriesFollowMaterialPassesNotCommandPasses) {
    BarsScene folder;
    // Swapping the two scene entries swaps which pass receives which value.
    const auto swapped = folder.Build(BarsScene::Reference(json::array({ { { "combos", { { "BOTH", 2 } } } }, { { "combos", { { "SHAPE", 7 } } } } })));
    ASSERT_EQ(swapped.jobs.size(), 2u);
    EXPECT_EQ(swapped.jobs[0].combos.at("BOTH"), "2");
    EXPECT_EQ(swapped.jobs[0].combos.at("SHAPE"), "0");
    EXPECT_EQ(swapped.jobs[1].combos.at("BOTH"), "1");
    EXPECT_EQ(swapped.jobs[1].combos.at("SHAPE"), "7");
}

TEST(ShaderCorpusScene, MissingOrShortSceneEntriesLeaveTheEffectFilesCombos) {
    BarsScene folder;
    const auto none = folder.Build(BarsScene::Reference());
    ASSERT_EQ(none.jobs.size(), 2u);
    EXPECT_EQ(none.jobs[0].combos.at("SHAPE"), "0");
    EXPECT_EQ(none.jobs[1].combos.at("BOTH"), "1");
    EXPECT_EQ(none.jobs[1].combos.at("FROM_FILE"), "1");

    const auto shorter = folder.Build(BarsScene::Reference(json::array({ { { "combos", { { "SHAPE", 7 } } } } })));
    ASSERT_EQ(shorter.jobs.size(), 2u);
    EXPECT_EQ(shorter.jobs[0].combos.at("SHAPE"), "7");
    EXPECT_EQ(shorter.jobs[1].combos.at("BOTH"), "1");
}

// CS-06 gates -------------------------------------------------------------------------------------

TEST(ShaderCorpusGate, MissingFolderMeansSkipAndNamesTheVariable) {
    ScratchFolder scratch;
    const auto    decision = DecideSweepGate(scratch.sub("not-there"));
    EXPECT_EQ(decision.gate, SweepGate::Skip);
    EXPECT_NE(decision.message.find("WALLPAPER_MACHINE_UNPACK_ROOT"), std::string::npos);
    EXPECT_NE(decision.message.find("not-there"), std::string::npos);
}

TEST(ShaderCorpusGate, FolderWithoutScenesMeansSkip) {
    ScratchFolder scratch;
    stdfs::create_directories(scratch.sub("empty-package"));
    EXPECT_EQ(DecideSweepGate(scratch.path()).gate, SweepGate::Skip);
}

TEST(ShaderCorpusGate, BroadRootsAndLinksFailInsteadOfSkipping) {
    EXPECT_EQ(DecideSweepGate("/Users").gate, SweepGate::Fail);
    EXPECT_EQ(DecideSweepGate("/").gate, SweepGate::Fail);

    ScratchFolder scratch;
    stdfs::create_directories(scratch.sub("real/1"));
    WriteFile(scratch.sub("real/1/scene.json"), "{}");
    stdfs::create_directory_symlink(scratch.sub("real"), scratch.sub("link"));
    EXPECT_EQ(DecideSweepGate(scratch.sub("link")).gate, SweepGate::Fail);
    EXPECT_EQ(DecideSweepGate(scratch.sub("real")).gate, SweepGate::Run);
}

TEST(ShaderCorpusGate, OnlyRealSceneFoldersAreEnumeratedInPathOrder) {
    ScratchFolder scratch;
    WriteFile(scratch.sub("20/scene.json"), "{}");
    WriteFile(scratch.sub("10/scene.json"), "{}");
    stdfs::create_directories(scratch.sub("30"));                    // no scene.json
    WriteFile(scratch.sub("stray.json"), "{}");                      // not a folder
    stdfs::create_directory_symlink(scratch.sub("10"), scratch.sub("40")); // a link

    const auto decision = DecideSweepGate(scratch.path());
    ASSERT_EQ(decision.gate, SweepGate::Run);
    ASSERT_EQ(decision.scenes.size(), 2u);
    EXPECT_EQ(decision.scenes[0].filename(), "10");
    EXPECT_EQ(decision.scenes[1].filename(), "20");
}

TEST(ShaderCorpusGate, TooManySceneFoldersFailTheGate) {
    ScratchFolder scratch;
    for (std::size_t i = 0; i < kSceneFolderLimit + 1; ++i) {
        WriteFile(scratch.sub(std::to_string(i) + "/scene.json"), "{}");
    }
    EXPECT_EQ(DecideSweepGate(scratch.path()).gate, SweepGate::Fail);
}

TEST(ShaderCorpusGate, ConfigurationComesFromTheEnvironmentWithDefaults) {
    const auto none = [](const char*) -> const char* { return nullptr; };
    const auto bare = ResolveSweepConfig(none, "/built/in/unpack");
    EXPECT_EQ(bare.unpack_root, stdfs::path("/built/in/unpack"));
    EXPECT_FALSE(bare.assets_root.has_value());

    const auto home = [](const char* name) -> const char* { return std::string(name) == "HOME" ? "/home/someone" : nullptr; };
    const auto with_home = ResolveSweepConfig(home, "/built/in/unpack");
    ASSERT_TRUE(with_home.assets_root.has_value());
    EXPECT_EQ(*with_home.assets_root,
              stdfs::path("/home/someone/Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets"));

    const auto given = [](const char* name) -> const char* {
        const std::string key = name;
        if (key == "WALLPAPER_MACHINE_UNPACK_ROOT") return "/given/unpack";
        if (key == "WALLPAPER_MACHINE_ASSETS_ROOT") return "/given/assets";
        if (key == "HOME") return "/home/someone";
        return nullptr;
    };
    const auto explicit_roots = ResolveSweepConfig(given, "/built/in/unpack");
    EXPECT_EQ(explicit_roots.unpack_root, stdfs::path("/given/unpack"));
    EXPECT_EQ(explicit_roots.assets_root, std::optional<stdfs::path>("/given/assets"));

    const auto blank = [](const char* name) -> const char* { return std::string(name) == "WALLPAPER_MACHINE_UNPACK_ROOT" ? "" : nullptr; };
    EXPECT_EQ(ResolveSweepConfig(blank, "/built/in/unpack").unpack_root, stdfs::path("/built/in/unpack"));
}
