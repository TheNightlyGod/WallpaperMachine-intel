// Behaviour of the wpdump snapshot: the command line, the package block, the scene document,
// each object kind, textures, models, pose sampling and determinism. Every input is built in a
// scratch folder; no corpus, GPU or environment setup is needed.
#include <fcntl.h>
#include <gtest/gtest.h>
#include <spawn.h>
#include <sys/wait.h>

#include <algorithm>
#include <fstream>
#include <set>
#include <sstream>

#include "workshop_fixtures.hpp"
#include "workshop_snapshot.hpp"

extern char** environ;

namespace
{

using namespace wmfix;

constexpr uint32_t kNoParent = 4294967295u;

double widen(float f) { return static_cast<double>(f); }

json triple(double a, double b, double c) { return json::array({ a, b, c }); }
json floats3(float a, float b, float c) { return triple(widen(a), widen(b), widen(c)); }

std::set<std::string> keysOf(const json& object) {
    std::set<std::string> keys;
    for (auto it = object.begin(); it != object.end(); ++it) keys.insert(it.key());
    return keys;
}

std::string readFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream text;
    text << in.rdbuf();
    return text.str();
}

struct Cli {
    int         code { -1 };
    std::string out, err;
};

Cli runCli(const std::vector<std::string>& args, const std::string& argv0 = "wpdump") {
    std::vector<std::string> store { argv0 };
    store.insert(store.end(), args.begin(), args.end());
    std::vector<const char*> argv;
    for (const auto& a : store) argv.push_back(a.c_str());
    std::ostringstream out, err;
    Cli                result;
    result.code = wmsnap::runWpdump(static_cast<int>(argv.size()), argv.data(), out, err);
    result.out  = out.str();
    result.err  = err.str();
    return result;
}

// The scene block of an item holding `entries`.
struct Dumped {
    json        snap;
    std::string err;
};

class WorkshopDump : public ::testing::Test {
protected:
    // The pose switch belongs to the tests that ask for it.
    ScopedEnv noPoses { wmsnap::kPoseEnv, nullptr };
    Workspace space;
    int       counter { 0 };

    std::string makeItem(const std::vector<Entry>& entries, const PackageOptions& options = {}) {
        return space.item("item" + std::to_string(counter++), entries, options);
    }
    Dumped dump(const std::string& dir) {
        Dumped d;
        d.snap = wmsnap::snapshotWorkshop(dir, d.err);
        return d;
    }
    // Dumps an item and insists it worked.
    json snapshotOf(const std::vector<Entry>& entries, const PackageOptions& options = {}) {
        const Dumped d = dump(makeItem(entries, options));
        EXPECT_EQ(d.err, "");
        return d.snap;
    }
    // The scene block of an item made of `scene` and `more`.
    json sceneOf(const json& scene, std::vector<Entry> more = {}) {
        std::vector<Entry> entries { entry("scene.json", scene) };
        append(entries, std::move(more));
        return snapshotOf(entries).at("scene");
    }
    json sceneOfText(const std::string& text) {
        return snapshotOf({ entry("scene.json", text) }).at("scene");
    }
    // The object rows of a scene built around `objects`.
    json objectsOf(json objects, std::vector<Entry> more = {}) {
        return sceneOf(sceneDoc(std::move(objects)), std::move(more)).at("objects");
    }
};

const json* byId(const json& rows, int id) {
    for (const auto& row : rows) {
        if (row.at("id") == id) return &row;
    }
    return nullptr;
}

// ============================================================================================
// DT-01 .. DT-04: the command line
// ============================================================================================

TEST_F(WorkshopDump, WrongArgumentCountPrintsUsageAndExitsTwo) {
    const std::vector<std::vector<std::string>> cases {
        {}, { "a", "b", "c" }, { "a", "b", "c", "d", "e" }
    };
    for (const auto& args : cases) {
        SCOPED_TRACE(args.size());
        const Cli r = runCli(args, "/opt/tools/wpdump");
        EXPECT_EQ(r.code, 2);
        EXPECT_EQ(r.out, "");
        EXPECT_EQ(r.err.rfind("usage: ", 0), 0u) << r.err;
        EXPECT_NE(r.err.find("/opt/tools/wpdump <workshop_dir> [output.json]"), std::string::npos) << r.err;
    }
}

TEST_F(WorkshopDump, FolderWithoutPackageReportsWhereItLooked) {
    const std::string dir      = space.folder("empty");
    const std::string expected = "scene.pkg not found at " + dir + "/scene.pkg";

    const Cli r = runCli({ dir });
    EXPECT_EQ(r.code, 1);
    EXPECT_EQ(r.out, "");
    EXPECT_EQ(r.err, "wpdump: " + expected + "\n");

    const Dumped d = dump(dir);
    EXPECT_EQ(d.err, expected);
    EXPECT_EQ(d.snap.at("error"), expected);
    EXPECT_EQ(d.snap.at("workshop_dir"), "empty");
}

TEST_F(WorkshopDump, PackageTheReaderRejectsFailsTheDump) {
    struct Bad {
        std::string text;
        bool        exactMessage;
    };
    // An empty file has no header at all; seven letters are no header either.
    for (const Bad& bad : { Bad { "", true }, Bad { "garbage", false } }) {
        SCOPED_TRACE(bad.text.size());
        const std::string dir = space.folder("bad" + std::to_string(counter++));
        space.write(dir.substr(space.root().size() + 1) + "/scene.pkg", bad.text);
        const Cli r = runCli({ dir });
        EXPECT_EQ(r.code, 1);
        EXPECT_EQ(r.out, "");
        EXPECT_EQ(r.err.rfind("wpdump: ", 0), 0u) << r.err;
        if (bad.exactMessage) EXPECT_NE(r.err.find("WPPkgFs::CreatePkgFs failed"), std::string::npos) << r.err;
    }
}

TEST_F(WorkshopDump, OutputFileHoldsTheSameTextStdoutWouldHave) {
    const std::string dir = makeItem({ entry("scene.json", sceneDoc(json::array())) });
    const std::string out = space.root() + "/dump.json";

    const Cli viaStdout = runCli({ dir });
    ASSERT_EQ(viaStdout.code, 0);
    const Cli viaFile = runCli({ dir, out });
    EXPECT_EQ(viaFile.code, 0);
    EXPECT_EQ(viaFile.out, "");

    const std::string text = readFile(out);
    EXPECT_EQ(text, viaStdout.out);
    ASSERT_GE(text.size(), 2u);
    EXPECT_EQ(text.back(), '\n');
    EXPECT_NE(text[text.size() - 2], '\n');
    EXPECT_NO_THROW((void) json::parse(text));
    EXPECT_EQ(text.substr(0, 3), "{\n ");
    EXPECT_EQ(text.rfind("{\n  \"", 0), 0u) << text.substr(0, 20);
}

TEST_F(WorkshopDump, UnwritableOutputPathFailsAndPrintsNothing) {
    const std::string dir = makeItem({ entry("scene.json", sceneDoc(json::array())) });
    const std::string out = space.root() + "/no-such-folder/dump.json";
    const Cli         r   = runCli({ dir, out });
    EXPECT_EQ(r.code, 1);
    EXPECT_EQ(r.out, "");
    EXPECT_EQ(r.err, "wpdump: cannot open " + out + " for writing\n");
}

// The same contract through the built executable, so the thin main is covered too.
struct Process {
    int         code { -1 };
    std::string out, err;
};

Process spawnTool(const std::vector<std::string>& args, const std::string& scratch) {
    Process           result;
    const std::string outFile = scratch + "/spawn.out", errFile = scratch + "/spawn.err";
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 1, outFile.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    posix_spawn_file_actions_addopen(&actions, 2, errFile.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    std::vector<std::string> store { WPDUMP_EXE };
    store.insert(store.end(), args.begin(), args.end());
    std::vector<char*> argv;
    for (auto& a : store) argv.push_back(a.data());
    argv.push_back(nullptr);
    pid_t pid = 0;
    if (posix_spawn(&pid, WPDUMP_EXE, &actions, nullptr, argv.data(), environ) == 0) {
        int status = 0;
        waitpid(pid, &status, 0);
        result.code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    posix_spawn_file_actions_destroy(&actions);
    result.out = readFile(outFile);
    result.err = readFile(errFile);
    return result;
}

TEST_F(WorkshopDump, BuiltToolBehavesLikeTheLibraryEntryPoint) {
    const std::string dir = makeItem({ entry("scene.json", sceneDoc(json::array())) });
    const std::string scratch = space.folder("spawn");

    const Process none = spawnTool({}, scratch);
    EXPECT_EQ(none.code, 2);
    EXPECT_EQ(none.out, "");
    EXPECT_EQ(none.err.rfind("usage: ", 0), 0u) << none.err;

    const Process ok = spawnTool({ dir }, scratch);
    EXPECT_EQ(ok.code, 0);
    EXPECT_EQ(ok.out, runCli({ dir }).out);

    const Process missing = spawnTool({ space.folder("nothing-here") }, scratch);
    EXPECT_EQ(missing.code, 1);
    EXPECT_EQ(missing.out, "");
    EXPECT_NE(missing.err.find("wpdump: scene.pkg not found at "), std::string::npos) << missing.err;
}

// ============================================================================================
// DT-05: the package block and the folder name
// ============================================================================================

TEST_F(WorkshopDump, PackageBlockReportsVersionCountAndSceneEntry) {
    const json three = snapshotOf({ entry("scene.json", sceneDoc(json::array())),
                                    entry("a.txt", std::string("x")), entry("b.txt", std::string("y")) });
    EXPECT_EQ(three.at("pkg"), (json { { "version", "PKGV0001" }, { "file_count", 3 }, { "has_scene_json", true } }));
    EXPECT_TRUE(three.contains("scene"));

    PackageOptions v17;
    v17.version = "PKGV0017";
    const json one = snapshotOf({ entry("materials/x.tex", defaultTexture()) }, v17);
    EXPECT_EQ(one.at("pkg"), (json { { "version", "PKGV0017" }, { "file_count", 1 }, { "has_scene_json", false } }));
    EXPECT_FALSE(one.contains("scene"));

    const json lookalikes = snapshotOf({ entry("Scene.json", sceneDoc(json::array())),
                                         entry("sub/scene.json", sceneDoc(json::array())) });
    EXPECT_FALSE(lookalikes.at("pkg").at("has_scene_json"));
    EXPECT_EQ(lookalikes.at("pkg").at("file_count"), 2);
    EXPECT_FALSE(lookalikes.contains("scene"));
}

TEST_F(WorkshopDump, WorkshopDirIsTheLastPathComponent) {
    const std::string dir = space.item("12345", { entry("scene.json", sceneDoc(json::array())) });
    EXPECT_EQ(dump(dir).snap.at("workshop_dir"), "12345");
    EXPECT_EQ(dump(dir + "/").snap.at("workshop_dir"), "");
}

// ============================================================================================
// DT-06: the scene document
// ============================================================================================

TEST_F(WorkshopDump, ScenePlainTextThatIsNotJsonIsAnErrorBlock) {
    const json scene = sceneOfText("{not json");
    EXPECT_EQ(keysOf(scene), (std::set<std::string> { "error", "parsed" }));
    EXPECT_FALSE(scene.at("parsed").get<bool>());
    ASSERT_TRUE(scene.at("error").is_string());
    EXPECT_FALSE(scene.at("error").get<std::string>().empty());
}

TEST_F(WorkshopDump, SceneDefaultsApplyToAnEmptyDocument) {
    const json scene = sceneOfText("{}");
    EXPECT_TRUE(scene.at("parsed").get<bool>());
    EXPECT_EQ(scene.at("object_count"), 0);
    EXPECT_EQ(scene.at("objects"), json::array());
    EXPECT_TRUE(scene.at("is_ortho").get<bool>());
    EXPECT_EQ(scene.at("ortho"), (json { { "width", 1920 }, { "height", 1080 } }));
    EXPECT_EQ(scene.at("camera"), (json { { "center", triple(0, 0, 0) }, { "eye", triple(0, 0, 1) }, { "up", triple(0, 1, 0) } }));

    const json& g = scene.at("general");
    EXPECT_EQ(g.at("ambientcolor"), triple(0, 0, 0));
    EXPECT_EQ(g.at("skylightcolor"), triple(0, 0, 0));
    EXPECT_EQ(g.at("clearcolor"), triple(0, 0, 0));
    EXPECT_FALSE(g.at("cameraparallax").get<bool>());
    for (const char* key : { "cameraparallaxamount", "cameraparallaxdelay", "cameraparallaxmouseinfluence" }) {
        EXPECT_FALSE(g.contains(key)) << key;
    }
    EXPECT_EQ(g.at("zoom"), 1.0);
    EXPECT_EQ(g.at("fov"), 50.0);
    EXPECT_EQ(g.at("nearz").get<double>(), widen(0.01f));
    EXPECT_EQ(g.at("farz"), 10000.0);
}

TEST_F(WorkshopDump, SceneSkeletonValuesComeThroughAtFloatPrecision) {
    const json scene = sceneOf(sceneDoc(json::array()));
    EXPECT_EQ(scene.at("general").at("ambientcolor"), floats3(0.2f, 0.2f, 0.2f));
    EXPECT_EQ(scene.at("general").at("skylightcolor"), floats3(0.3f, 0.3f, 0.3f));
    EXPECT_EQ(scene.at("ortho"), (json { { "width", 64 }, { "height", 32 } }));
    EXPECT_EQ(scene.at("object_count"), 0);
}

TEST_F(WorkshopDump, SceneParallaxValuesAppearOnlyWhenTheFlagIsOn) {
    json doc               = sceneDoc(json::array());
    doc["general"]["cameraparallax"]              = true;
    doc["general"]["cameraparallaxamount"]        = 0.25;
    doc["general"]["cameraparallaxdelay"]         = 0.5;
    doc["general"]["cameraparallaxmouseinfluence"] = 0.75;
    doc["general"]["zoom"]                        = 2;
    doc["general"]["fov"]                         = 60;
    doc["general"]["nearz"]                       = 1;
    doc["general"]["farz"]                        = 100;
    doc["general"]["clearcolor"]                  = json::array({ 1, 0, 0 });
    const json g = sceneOf(doc).at("general");
    EXPECT_TRUE(g.at("cameraparallax").get<bool>());
    EXPECT_EQ(g.at("cameraparallaxamount"), 0.25);
    EXPECT_EQ(g.at("cameraparallaxdelay"), 0.5);
    EXPECT_EQ(g.at("cameraparallaxmouseinfluence"), 0.75);
    EXPECT_EQ(g.at("zoom"), 2.0);
    EXPECT_EQ(g.at("fov"), 60.0);
    EXPECT_EQ(g.at("nearz"), 1.0);
    EXPECT_EQ(g.at("farz"), 100.0);
    EXPECT_EQ(g.at("clearcolor"), triple(1, 0, 0));

    // The same values with the flag off stay out of the dump.
    doc["general"]["cameraparallax"] = false;
    const json off = sceneOf(doc).at("general");
    EXPECT_FALSE(off.contains("cameraparallaxamount"));
    EXPECT_FALSE(off.contains("cameraparallaxdelay"));
    EXPECT_FALSE(off.contains("cameraparallaxmouseinfluence"));
}

TEST_F(WorkshopDump, SceneWithoutAnObjectListHasNoObjects) {
    json absent = sceneDoc(json());
    ASSERT_FALSE(absent.contains("objects"));
    json notAnArray = sceneDoc(json());
    notAnArray["objects"] = 5;
    for (const json& doc : { absent, notAnArray }) {
        const json scene = sceneOf(doc);
        EXPECT_EQ(scene.at("object_count"), 0);
        EXPECT_EQ(scene.at("objects"), json::array());
    }
}

// ============================================================================================
// DT-07: object kinds, ordering and the common fields
// ============================================================================================

TEST_F(WorkshopDump, ObjectsAreSortedByIdWithTheirKinds) {
    std::vector<Entry> assets = imageAssets();
    append(assets, particleAssets());
    const json rows = objectsOf(json::array({ json { { "id", 5 }, { "name", "grp" } }, imageObject(3),
                                               lightObject(1), particleObject(4), soundObject(2) }),
                                assets);
    ASSERT_EQ(rows.size(), 5u);
    const std::vector<std::pair<int, std::string>> expected { { 1, "light" }, { 2, "sound" }, { 3, "image" },
                                                              { 4, "particle" }, { 5, "unknown" } };
    for (size_t i = 0; i < expected.size(); ++i) {
        EXPECT_EQ(rows[i].at("id"), expected[i].first) << i;
        EXPECT_EQ(rows[i].at("kind"), expected[i].second) << i;
    }
    EXPECT_EQ(rows[4], (json { { "id", 5 }, { "kind", "unknown" }, { "name", "grp" }, { "visible", true } }));
}

TEST_F(WorkshopDump, ObjectCountMatchesTheNumberOfRows) {
    const json scene = sceneOf(sceneDoc(json::array({ lightObject(2), lightObject(1), lightObject(3) })));
    EXPECT_EQ(scene.at("object_count"), 3);
    EXPECT_EQ(scene.at("objects").size(), 3u);
}

TEST_F(WorkshopDump, AuthoredVisibilityIsReadInEveryForm) {
    const auto light = [](int id, const json& visible) {
        json o = lightObject(id);
        if (! visible.is_null()) o["visible"] = visible;
        return o;
    };
    const json rows = objectsOf(json::array({ light(1, false), light(2, json { { "value", false }, { "user", "p" } }),
                                              light(3, json { { "value", true }, { "user", "p" } }),
                                              light(4, "yes"), light(5, json()) }));
    EXPECT_EQ(byId(rows, 1)->at("visible"), false);
    EXPECT_EQ(byId(rows, 2)->at("visible"), false);
    EXPECT_EQ(byId(rows, 3)->at("visible"), true);
    EXPECT_EQ(byId(rows, 4)->at("visible"), true);
    EXPECT_EQ(byId(rows, 5)->at("visible"), true);

    // A parsed image follows the same rule in its own visible_parsed.
    json image = imageObject(7);
    image["visible"] = json { { "value", false }, { "user", "p" } };
    const json imageRows = objectsOf(json::array({ image }), imageAssets());
    EXPECT_EQ(imageRows[0].at("visible"), false);
    EXPECT_EQ(imageRows[0].at("visible_parsed"), false);
}

TEST_F(WorkshopDump, AuthoredTransformValuesAreCopiedThroughUnchanged) {
    json image  = imageObject(1);
    image["origin"] = "0 0 0";
    image["size"]   = "64 32";
    json light  = lightObject(2);
    light["origin"] = json::array({ 1, 2, 3 });
    const json rows = objectsOf(json::array({ image, light }), imageAssets());

    const json& imageRow = *byId(rows, 1);
    ASSERT_TRUE(imageRow.at("origin").is_string());
    EXPECT_EQ(imageRow.at("origin"), "0 0 0");
    EXPECT_EQ(imageRow.at("size"), "64 32");
    EXPECT_FALSE(imageRow.contains("scale"));
    EXPECT_FALSE(imageRow.contains("angles"));

    const json& lightRow = *byId(rows, 2);
    ASSERT_TRUE(lightRow.at("origin").is_array());
    for (const auto& v : lightRow.at("origin")) EXPECT_TRUE(v.is_number_integer());
    EXPECT_EQ(lightRow.at("origin"), json::array({ 1, 2, 3 }));
    EXPECT_EQ(lightRow.at("origin_parsed"), triple(1, 2, 3));
}

TEST_F(WorkshopDump, ObjectWithoutIdOrNameGetsPlaceholders) {
    const json rows = objectsOf(json::array({ json { { "light", "point" } } }));
    ASSERT_EQ(rows.size(), 1u);
    EXPECT_EQ(rows[0].at("id"), -1);
    EXPECT_EQ(rows[0].at("name"), "");
}

TEST_F(WorkshopDump, KindPrecedenceIsImageLightParticleSound) {
    std::vector<Entry> assets = imageAssets();
    append(assets, particleAssets());
    json imageAndLight = imageObject(1);
    imageAndLight["light"] = "point";
    json lightAndParticle = lightObject(2);
    lightAndParticle["particle"] = "particles/p.json";
    json particleAndSound = particleObject(3);
    particleAndSound["sound"] = json::array({ "sounds/a.mp3" });
    const json rows = objectsOf(json::array({ imageAndLight, lightAndParticle, particleAndSound }), assets);
    EXPECT_EQ(byId(rows, 1)->at("kind"), "image");
    EXPECT_EQ(byId(rows, 2)->at("kind"), "light");
    EXPECT_EQ(byId(rows, 3)->at("kind"), "particle");
}


// ============================================================================================
// DT-08: image layers and their effects
// ============================================================================================

TEST_F(WorkshopDump, ImageLayerRowCarriesTheParsedLayerAndItsMaterial) {
    json image      = imageObject(3);
    image["origin"] = "0 0 0";
    image["size"]   = "64 32";
    const json rows = objectsOf(json::array({ image }), imageAssets());
    ASSERT_EQ(rows.size(), 1u);
    const json& row = rows[0];

    EXPECT_TRUE(row.at("parsed").get<bool>());
    EXPECT_EQ(row.at("image"), "image.json");
    EXPECT_EQ(row.at("size_parsed"), json::array({ 64, 32 }));
    EXPECT_EQ(row.at("origin_parsed"), triple(0, 0, 0));
    EXPECT_EQ(row.at("scale_parsed"), triple(1, 1, 1));
    EXPECT_EQ(row.at("angles_parsed"), triple(0, 0, 0));
    EXPECT_EQ(row.at("color"), triple(1, 1, 1));
    EXPECT_EQ(row.at("alpha"), 1.0);
    EXPECT_EQ(row.at("brightness"), 1.0);
    EXPECT_EQ(row.at("colorBlendMode"), 0);
    EXPECT_EQ(row.at("fullscreen"), false);
    EXPECT_EQ(row.at("nopadding"), false);
    EXPECT_EQ(row.at("alignment_parsed"), "center");
    EXPECT_EQ(row.at("puppet"), "");
    EXPECT_EQ(row.at("effect_count"), 0);
    EXPECT_EQ(row.at("effects"), json::array());
    EXPECT_EQ(row.at("material"), (json { { "shader", "genericimage" },
                                          { "blending", "translucent" },
                                          { "cullmode", "nocull" },
                                          { "depthtest", "disabled" },
                                          { "depthwrite", "disabled" },
                                          { "use_puppet", false },
                                          { "textures", json::array({ "solid" }) },
                                          { "combos", json::object() },
                                          { "constantshadervalues", json::object() } }));
}

TEST_F(WorkshopDump, ImageLayerWithoutSizeTakesTheSizeOfItsImageFile) {
    const json rows = objectsOf(json::array({ imageObject(3) }), imageAssets());
    EXPECT_EQ(rows[0].at("size_parsed"), json::array({ 64, 32 }));
}

TEST_F(WorkshopDump, ImageEffectRowNamesTheEffectFileAndKeepsItsPassesAndBuffers) {
    json image       = imageObject(3);
    image["effects"] = json::array({ effectInstance() });
    std::vector<Entry> assets = imageAssets();
    append(assets, effectAssets());
    const json rows = objectsOf(json::array({ image }), assets);
    const json& row = rows[0];

    ASSERT_EQ(row.at("effect_count"), 1);
    ASSERT_EQ(row.at("effects").size(), 1u);
    const json& effect = row.at("effects")[0];
    EXPECT_EQ(effect.at("name"), "e");
    EXPECT_EQ(effect.at("visible"), true);
    EXPECT_EQ(effect.at("material_count"), 1);
    EXPECT_EQ(effect.at("pass_count"), 1);
    EXPECT_EQ(effect.at("fbo_count"), 1);
    EXPECT_EQ(effect.at("fbos"),
              json::array({ json { { "name", "_rt_a" }, { "format", "rgba8888" }, { "scale", 2 } } }));
    EXPECT_EQ(effect.at("materials")[0].at("blending"), "normal");

    const json& pass = effect.at("passes")[0];
    EXPECT_EQ(pass.at("bind"), json::array({ json { { "name", "previous" }, { "index", 0 } } }));
    EXPECT_EQ(pass.at("target"), "");
    EXPECT_EQ(pass.at("textures"), json::array());
    EXPECT_EQ(pass.at("constantshadervalues").at("speed"),
              (json { { "value", json::array({ 2.0 }) }, { "user", "" } }));
}

TEST_F(WorkshopDump, ImageWhoseFileIsMissingKeepsOnlyTheCommonFields) {
    json image = imageObject(3);
    image["image"] = "gone.json";
    const json rows = objectsOf(json::array({ image }));
    ASSERT_EQ(rows.size(), 1u);
    EXPECT_EQ(rows[0], (json { { "id", 3 }, { "kind", "image" }, { "name", "pic" }, { "visible", true }, { "parsed", false } }));
}

// ============================================================================================
// DT-09: lights, particles and sounds
// ============================================================================================

TEST_F(WorkshopDump, LightRowReportsAuthoredAndDefaultValues) {
    json lamp       = lightObject(1);
    lamp["origin"]  = json::array({ 1, 2, 3 });
    lamp["color"]   = "1 0.5 0.25";
    lamp["radius"]  = 100;
    lamp["intensity"] = 2;
    const json rows = objectsOf(json::array({ lamp, json { { "id", 2 }, { "light", "point" } } }));

    const json& set = *byId(rows, 1);
    EXPECT_TRUE(set.at("parsed").get<bool>());
    EXPECT_EQ(set.at("light"), "point");
    EXPECT_EQ(set.at("color"), triple(1, 0.5, 0.25));
    EXPECT_EQ(set.at("radius"), 100.0);
    EXPECT_EQ(set.at("intensity"), 2.0);
    EXPECT_EQ(set.at("origin_parsed"), triple(1, 2, 3));
    EXPECT_EQ(set.at("scale_parsed"), triple(1, 1, 1));
    EXPECT_EQ(set.at("angles_parsed"), triple(0, 0, 0));
    EXPECT_EQ(set.at("visible_parsed"), true);

    const json& bare = *byId(rows, 2);
    EXPECT_EQ(bare.at("color"), triple(1, 1, 1));
    EXPECT_EQ(bare.at("radius"), 1000.0);
    EXPECT_EQ(bare.at("intensity"), 1.0);
}

TEST_F(WorkshopDump, ParticleRowCountsItsPartsAndTruncatesStartTime) {
    const json rows = objectsOf(json::array({ particleObject(9) }), particleAssets());
    ASSERT_EQ(rows.size(), 1u);
    const json& row = rows[0];
    EXPECT_TRUE(row.at("parsed").get<bool>());
    EXPECT_EQ(row.at("particle"), "particles/p.json");
    EXPECT_EQ(row.at("origin_parsed"), triple(1, 2, 3));
    EXPECT_EQ(row.at("emitter_count"), 2);
    EXPECT_EQ(row.at("initializer_count"), 1);
    EXPECT_EQ(row.at("operator_count"), 3);
    EXPECT_EQ(row.at("renderer_count"), 1);
    EXPECT_EQ(row.at("controlpoint_count"), 1);
    EXPECT_EQ(row.at("child_count"), 0);
    EXPECT_EQ(row.at("maxcount"), 123);
    ASSERT_TRUE(row.at("starttime").is_number_integer());
    EXPECT_EQ(row.at("starttime"), 2);
    EXPECT_EQ(row.at("animationmode"), "sequence");
}

TEST_F(WorkshopDump, ParticleWhoseFileHasNoMaterialIsNotParsed) {
    std::vector<Entry> assets { entry("particles/q.json", json { { "emitter", { { { "name", "boxrandom" } } } } }) };
    json object = particleObject(9);
    object["particle"] = "particles/q.json";
    const json rows = objectsOf(json::array({ object }), assets);
    ASSERT_EQ(rows.size(), 1u);
    EXPECT_EQ(rows[0].at("parsed"), false);
    EXPECT_FALSE(rows[0].contains("emitter_count"));
    EXPECT_FALSE(rows[0].contains("particle"));
    EXPECT_EQ(rows[0].at("kind"), "particle");
}

TEST_F(WorkshopDump, SoundRowReportsPathsAndPlaybackSettings) {
    json clip          = soundObject(2);
    clip["playbackmode"] = "loop";
    clip["volume"]       = 0.5;
    json silent        = json { { "id", 3 }, { "name", "none" }, { "sound", json::array() } };
    const json rows    = objectsOf(json::array({ clip, silent }));

    const json& a = *byId(rows, 2);
    EXPECT_TRUE(a.at("parsed").get<bool>());
    EXPECT_EQ(a.at("sound_paths"), json::array({ "sounds/a.mp3" }));
    EXPECT_EQ(a.at("playbackmode"), "loop");
    EXPECT_EQ(a.at("volume"), 0.5);
    EXPECT_EQ(a.at("mintime"), 0.0);
    EXPECT_EQ(a.at("maxtime"), 10.0);
    EXPECT_EQ(a.at("visible_parsed"), true);

    const json& b = *byId(rows, 3);
    EXPECT_TRUE(b.at("parsed").get<bool>());
    EXPECT_EQ(b.at("sound_paths"), json::array());
    EXPECT_EQ(b.at("volume"), 1.0);
    EXPECT_EQ(b.at("playbackmode"), "loop");
}

// ============================================================================================
// DT-10: textures
// ============================================================================================

std::vector<Entry> textureEntries() {
    textest::Container nested(2, { textest::rawLevel(4, 1, 0x44) });
    nested.width = nested.mapWidth = 16;
    nested.height = nested.mapHeight = 4;
    Blob truncated = textBlob("TEXV0005");
    truncated.push_back(0);
    return { entry("materials/b.tex", defaultTexture()),
             entry("materials/a.tex", texture(3, 4, 4)),
             entry("Materials/c.tex", defaultTexture()),
             entry("materials/d.TEX", defaultTexture()),
             entry("textures/e.tex", defaultTexture()),
             entry("materials/sub/f.tex", textest::build(nested)),
             entry("materials/broken.tex", truncated) };
}

const json* rowFor(const json& rows, const std::string& path) {
    for (const auto& row : rows) {
        if (row.at("path") == path) return &row;
    }
    return nullptr;
}

TEST_F(WorkshopDump, OnlyMaterialTexturesAreListedInByteOrder) {
    const json textures = snapshotOf(textureEntries()).at("textures");
    std::vector<std::string> paths;
    for (const auto& row : textures) paths.push_back(row.at("path"));
    EXPECT_EQ(paths, (std::vector<std::string> { "/materials/a.tex", "/materials/b.tex", "/materials/broken.tex",
                                                 "/materials/sub/f.tex" }));
}

TEST_F(WorkshopDump, DefaultContainerRowMatchesTheHeaderFields) {
    const json textures = snapshotOf(textureEntries()).at("textures");
    const json& row     = *rowFor(textures, "/materials/b.tex");
    EXPECT_TRUE(row.at("ok").get<bool>());
    EXPECT_EQ(row.at("texv"), 5);
    EXPECT_EQ(row.at("texi"), 1);
    EXPECT_EQ(row.at("texb"), 3);
    EXPECT_EQ(row.at("width"), 8);
    EXPECT_EQ(row.at("height"), 8);
    EXPECT_EQ(row.at("map_width"), 8);
    EXPECT_EQ(row.at("map_height"), 8);
    EXPECT_EQ(row.at("count"), 1);
    EXPECT_EQ(row.at("image_type"), -1);
    EXPECT_EQ(row.at("is_sprite"), false);
    EXPECT_EQ(row.at("wrap_s"), static_cast<int>(wallpaper::TextureWrap::REPEAT));
    EXPECT_EQ(row.at("wrap_t"), static_cast<int>(wallpaper::TextureWrap::REPEAT));
    EXPECT_EQ(row.at("min_filter"), static_cast<int>(wallpaper::TextureFilter::LINEAR));
    EXPECT_EQ(row.at("mag_filter"), static_cast<int>(wallpaper::TextureFilter::LINEAR));

    // The second picture differs only in its header size.
    const json& small = *rowFor(textures, "/materials/a.tex");
    EXPECT_EQ(small.at("width"), 4);
    EXPECT_EQ(small.at("map_height"), 4);
}

TEST_F(WorkshopDump, NestedTextureAndUnreadableTextureRows) {
    const json textures = snapshotOf(textureEntries()).at("textures");
    const json& nested  = *rowFor(textures, "/materials/sub/f.tex");
    EXPECT_TRUE(nested.at("ok").get<bool>());
    EXPECT_EQ(nested.at("texv"), 5);
    EXPECT_EQ(nested.at("texb"), 2);
    EXPECT_EQ(nested.at("width"), 16);
    EXPECT_EQ(nested.at("height"), 4);
    EXPECT_EQ(nested.at("map_width"), 16);
    EXPECT_EQ(nested.at("map_height"), 4);
    EXPECT_EQ(nested.at("count"), 1);

    const json& broken = *rowFor(textures, "/materials/broken.tex");
    EXPECT_FALSE(broken.at("ok").get<bool>());
    for (const char* key : { "texv", "texi", "texb", "width", "height", "count" }) {
        EXPECT_EQ(broken.at(key), 0) << key;
    }
}

TEST_F(WorkshopDump, PictureSizeAndMapSizeAreReportedSeparately) {
    textest::Container c(3, { textest::rawLevel(2, 2, 0x11) });
    c.width     = 16;
    c.height    = 8;
    c.mapWidth  = 12;
    c.mapHeight = 6;
    const json textures = snapshotOf({ entry("materials/mapped.tex", textest::build(c)) }).at("textures");
    const json& row     = textures[0];
    EXPECT_EQ(row.at("width"), 16);
    EXPECT_EQ(row.at("height"), 8);
    EXPECT_EQ(row.at("map_width"), 12);
    EXPECT_EQ(row.at("map_height"), 6);
}

TEST_F(WorkshopDump, TextureWithAZeroSideIsNotOk) {
    textest::Container flat(3, { textest::rawLevel(2, 2, 0x11) });
    flat.width     = 0;
    flat.mapWidth  = 0;
    const json textures = snapshotOf({ entry("materials/flat.tex", textest::build(flat)) }).at("textures");
    const json& row     = textures[0];
    // The stamps are intact; the size is what makes it unusable.
    EXPECT_EQ(row.at("texv"), 5);
    EXPECT_EQ(row.at("width"), 0);
    EXPECT_FALSE(row.at("ok").get<bool>());
}

TEST_F(WorkshopDump, SamplerFlagsShowUpInTheWrapAndFilterFields) {
    const auto container = [](uint32_t flags) {
        textest::Container c(3, { textest::rawLevel(2, 2, 0x22) });
        c.flags = flags;
        return textest::build(c);
    };
    const Blob plain = container(0), clamped = container(textest::kClamp),
               point = container(textest::kPointSampling),
               both  = container(textest::kClamp | textest::kPointSampling);

    const json textures = snapshotOf({ entry("materials/plain.tex", plain), entry("materials/clamp.tex", clamped),
                                       entry("materials/point.tex", point), entry("materials/both.tex", both) })
                              .at("textures");
    const auto oracle = [](const Blob& bytes) {
        auto rig = textest::rigForTex(bytes);
        return rig->ParseHeader("sample");
    };
    const json& base = *rowFor(textures, "/materials/plain.tex");
    for (const auto& [name, bytes] : { std::pair<const char*, Blob> { "clamp", clamped },
                                       { "point", point }, { "both", both } }) {
        SCOPED_TRACE(name);
        const json& row = *rowFor(textures, std::string("/materials/") + name + ".tex");
        const auto  h   = oracle(bytes);
        EXPECT_EQ(row.at("wrap_s"), static_cast<int>(h.sample.wrapS));
        EXPECT_EQ(row.at("wrap_t"), static_cast<int>(h.sample.wrapT));
        EXPECT_EQ(row.at("min_filter"), static_cast<int>(h.sample.minFilter));
        EXPECT_EQ(row.at("mag_filter"), static_cast<int>(h.sample.magFilter));
    }
    EXPECT_NE(rowFor(textures, "/materials/clamp.tex")->at("wrap_s"), base.at("wrap_s"));
    EXPECT_NE(rowFor(textures, "/materials/point.tex")->at("min_filter"), base.at("min_filter"));
    EXPECT_NE(rowFor(textures, "/materials/both.tex")->at("wrap_t"), base.at("wrap_t"));
    EXPECT_NE(rowFor(textures, "/materials/both.tex")->at("mag_filter"), base.at("mag_filter"));
}

// ============================================================================================
// DT-11, DT-12: models and pose sampling
// ============================================================================================

std::vector<Entry> modelEntries() {
    return { entry("models/m.mdl", skinnedModel()),
             entry("models/static.mdl", staticModel()),
             entry("models/bad.mdl", junkModel()),
             entry("other/a.mdl", animatedModel()),
             entry("models/notes.MDL", junkModel()) };
}

const json* puppetAt(const json& snapshot, const std::string& path) { return rowFor(snapshot.at("puppets"), path); }

TEST_F(WorkshopDump, ModelsAreFoundInAnyFolderByLowerCaseExtension) {
    const json puppets = snapshotOf(modelEntries()).at("puppets");
    std::vector<std::string> paths;
    for (const auto& row : puppets) paths.push_back(row.at("path"));
    EXPECT_EQ(paths, (std::vector<std::string> { "/models/bad.mdl", "/models/m.mdl", "/models/static.mdl",
                                                 "/other/a.mdl" }));
}

TEST_F(WorkshopDump, SkinnedStaticAndBrokenModelRows) {
    const json snap = snapshotOf(modelEntries());

    const json& skinned = *puppetAt(snap, "/models/m.mdl");
    EXPECT_TRUE(skinned.at("ok").get<bool>());
    EXPECT_EQ(skinned.at("mdlv"), 21);
    EXPECT_EQ(skinned.at("mdls"), 1);
    EXPECT_EQ(skinned.at("mdla"), 0);
    EXPECT_EQ(skinned.at("bones"), 1);
    EXPECT_EQ(skinned.at("anims"), 0);
    EXPECT_EQ(skinned.at("mat_json_file"), "models/surface.json");
    EXPECT_EQ(skinned.at("vertex_count"), 3);
    EXPECT_EQ(skinned.at("index_count"), 1);
    ASSERT_EQ(skinned.at("bone_tree").size(), 1u);
    EXPECT_EQ(skinned.at("bone_tree")[0].at("parent"), kNoParent);
    EXPECT_EQ(skinned.at("bone_tree")[0].at("transform_col_sums"), json::array({ 1.0, 1.0, 1.0, 7.0 }));
    EXPECT_TRUE(skinned.contains("anim_tracks"));
    EXPECT_EQ(skinned.at("anim_tracks"), json::array());

    const json& fixed = *puppetAt(snap, "/models/static.mdl");
    EXPECT_TRUE(fixed.at("ok").get<bool>());
    EXPECT_EQ(fixed.at("mdls"), 0);
    EXPECT_EQ(fixed.at("bones"), 0);
    EXPECT_EQ(fixed.at("vertex_count"), 3);
    EXPECT_EQ(fixed.at("index_count"), 1);
    EXPECT_FALSE(fixed.contains("bone_tree"));
    EXPECT_FALSE(fixed.contains("anim_tracks"));

    const json& bad = *puppetAt(snap, "/models/bad.mdl");
    EXPECT_FALSE(bad.at("ok").get<bool>());
    EXPECT_EQ(bad.at("mdlv"), 13);
    EXPECT_EQ(bad.at("mdls"), 1);
    EXPECT_EQ(bad.at("mdla"), 1);
    EXPECT_EQ(bad.at("bones"), 0);
    EXPECT_EQ(bad.at("anims"), 0);
    EXPECT_EQ(bad.at("mat_json_file"), "");
    EXPECT_EQ(bad.at("vertex_count"), 0);
    EXPECT_EQ(bad.at("index_count"), 0);
    EXPECT_FALSE(bad.contains("bone_tree"));
    EXPECT_FALSE(bad.contains("anim_tracks"));
}

TEST_F(WorkshopDump, AnimatedModelRowCountsAnimationsAndTracks) {
    const json snap = snapshotOf(modelEntries());
    const json& row = *puppetAt(snap, "/other/a.mdl");
    EXPECT_TRUE(row.at("ok").get<bool>());
    EXPECT_EQ(row.at("mdls"), 3);
    EXPECT_EQ(row.at("mdla"), 6);
    EXPECT_EQ(row.at("bones"), 1);
    EXPECT_EQ(row.at("anims"), 1);
    EXPECT_EQ(row.at("mat_json_file"), "models/surface.json");
    EXPECT_EQ(row.at("vertex_count"), 3);
    EXPECT_EQ(row.at("index_count"), 1);
    EXPECT_EQ(row.at("bone_tree")[0].at("transform_col_sums"), json::array({ 1.0, 1.0, 1.0, 7.0 }));
    ASSERT_EQ(row.at("anim_tracks").size(), 1u);
    const json& anim = row.at("anim_tracks")[0];
    EXPECT_EQ(anim.at("id"), 3);
    EXPECT_EQ(anim.at("fps"), 30.0);
    EXPECT_EQ(anim.at("length"), 10);
    EXPECT_EQ(anim.at("name"), "walk");
    EXPECT_EQ(anim.at("mode"), 0);
    EXPECT_EQ(anim.at("bone_track_count"), 2);
    EXPECT_EQ(anim.at("total_bone_frames"), 2);
}

TEST_F(WorkshopDump, PoseSamplesAreOffUnlessTheVariableIsSet) {
    const json row = *puppetAt(snapshotOf(modelEntries()), "/other/a.mdl");
    for (const char* key : { "name", "bind_parent", "anim_parent", "has_file_skin_pivot", "bind", "skin", "pivot",
                             "centroid_offset" }) {
        EXPECT_FALSE(row.at("bone_tree")[0].contains(key)) << key;
    }
    EXPECT_FALSE(row.at("anim_tracks")[0].contains("poses"));
}

TEST_F(WorkshopDump, SettingThePoseVariableAddsBonesAndSampledFrames) {
    // Only its presence counts: the value 1 and the empty string behave alike.
    for (const char* value : { "1", "" }) {
        SCOPED_TRACE(value);
        ScopedEnv poses(wmsnap::kPoseEnv, value);
        const json row = *puppetAt(snapshotOf(modelEntries()), "/other/a.mdl");
        const json& bone = row.at("bone_tree")[0];
        EXPECT_EQ(bone.at("name"), "root");
        EXPECT_EQ(bone.at("bind_parent"), kNoParent);
        EXPECT_EQ(bone.at("anim_parent"), kNoParent);
        EXPECT_EQ(bone.at("has_file_skin_pivot"), false);
        json bind = json::array(), skin = json::array();
        for (int i = 0; i < 16; ++i) {
            const bool diagonal = i % 5 == 0;
            bind.push_back(i == 12 ? 1.0 : i == 13 ? 2.0 : i == 14 ? 3.0 : diagonal ? 1.0 : 0.0);
            skin.push_back(diagonal ? 1.0 : 0.0);
        }
        EXPECT_EQ(bone.at("bind"), bind);
        EXPECT_EQ(bone.at("skin"), skin);
        EXPECT_EQ(bone.at("pivot"), triple(0, 0, 0));
        EXPECT_EQ(bone.at("centroid_offset"), triple(0, 0, 0));

        const json& poses_ = row.at("anim_tracks")[0].at("poses");
        ASSERT_EQ(poses_.size(), 2u);
        for (const auto& track : poses_) {
            ASSERT_EQ(track.size(), 1u);
            EXPECT_EQ(track[0].at("position"), triple(3, 0, 0));
            EXPECT_EQ(track[0].at("angle"), triple(0, 0, 0));
            EXPECT_EQ(track[0].at("scale"), triple(1, 1, 1));
        }
    }
}

TEST_F(WorkshopDump, LongTracksAreSampledAtFirstMiddleAndLastFrame) {
    ScopedEnv poses(wmsnap::kPoseEnv, "1");
    // Frame k of animation 7 has x = 7 + 100 k.
    const json snap = snapshotOf({ entry("models/long.mdl", animatedModel(7, { Track { 5 }, Track { 2 }, Track { 1 } })) });
    const json& tracks = snap.at("puppets")[0].at("anim_tracks")[0].at("poses");
    ASSERT_EQ(tracks.size(), 3u);
    const auto xs = [](const json& frames) {
        std::vector<double> out;
        for (const auto& f : frames) out.push_back(f.at("position")[0].get<double>());
        return out;
    };
    EXPECT_EQ(xs(tracks[0]), (std::vector<double> { 7, 207, 407 }));
    EXPECT_EQ(xs(tracks[1]), (std::vector<double> { 7, 107 }));
    EXPECT_EQ(xs(tracks[2]), (std::vector<double> { 7 }));
}

// ============================================================================================
// DT-13, DT-14: loose files and determinism
// ============================================================================================

TEST_F(WorkshopDump, LooseFilesBesideThePackageAreVisibleToTheParsers) {
    json image = imageObject(1);
    const std::string dir = space.item("loose", { entry("scene.json", sceneDoc(json::array({ image }))) });
    for (const auto& file : imageAssets(4, 4)) space.write("loose/" + file.name, file.payload);

    const json snap = dump(dir).snap;
    EXPECT_EQ(snap.at("pkg").at("file_count"), 1);
    const json& row = snap.at("scene").at("objects")[0];
    EXPECT_TRUE(row.at("parsed").get<bool>());
    EXPECT_EQ(row.at("size_parsed"), json::array({ 4, 4 }));
}

std::vector<Entry> richItemWithObjectsReversed(bool reversed) {
    std::vector<Entry> entries = richItem();
    entries.push_back(entry("other/z.mdl", animatedModel()));
    entries.push_back(entry("materials/z.tex", texture(2, 16, 4)));
    if (! reversed) return entries;
    for (auto& e : entries) {
        if (e.name != "scene.json") continue;
        json doc = json::parse(std::string(e.payload.begin(), e.payload.end()));
        std::reverse(doc["objects"].begin(), doc["objects"].end());
        e.payload = jsonBlob(doc);
    }
    std::reverse(entries.begin(), entries.end());
    return entries;
}

TEST_F(WorkshopDump, DumpingTheSameFolderTwiceGivesIdenticalText) {
    const std::string dir = makeItem(richItemWithObjectsReversed(false));
    EXPECT_EQ(wmsnap::renderSnapshot(dump(dir).snap), wmsnap::renderSnapshot(dump(dir).snap));
    EXPECT_EQ(runCli({ dir }).out, runCli({ dir }).out);
}

TEST_F(WorkshopDump, EntryAndObjectOrderInTheInputDoesNotChangeTheListings) {
    const json forward = snapshotOf(richItemWithObjectsReversed(false));
    const json reverse = snapshotOf(richItemWithObjectsReversed(true));
    ASSERT_GE(forward.at("textures").size(), 3u);
    ASSERT_GE(forward.at("puppets").size(), 3u);
    EXPECT_EQ(forward.at("textures"), reverse.at("textures"));
    EXPECT_EQ(forward.at("puppets"), reverse.at("puppets"));
    EXPECT_EQ(forward.at("scene").at("objects"), reverse.at("scene").at("objects"));
    EXPECT_EQ(forward.at("pkg").at("file_count"), reverse.at("pkg").at("file_count"));
}

// ============================================================================================
// DT-15 .. DT-18
// ============================================================================================

std::set<std::string> expectedKeys(std::set<std::string> schema, const json& authored) {
    for (const char* key : { "origin", "scale", "angles", "size", "parallaxDepth", "alignment" }) {
        if (authored.contains(key)) schema.insert(key);
    }
    return schema;
}

TEST_F(WorkshopDump, EachObjectKindDumpsExactlyItsSchemaKeys) {
    const json item = snapshotOf(richItem());
    const json& rows = item.at("scene").at("objects");
    // Authored objects of the rich item, by id, for the optional raw keys.
    json authored = json::object();
    for (const auto& e : richItem()) {
        if (e.name != "scene.json") continue;
        const json doc = json::parse(std::string(e.payload.begin(), e.payload.end()));
        for (const auto& o : doc.at("objects")) {
            authored[std::to_string(o.at("id").get<int>())] = o;
        }
    }
    const auto check = [&](int id, const std::set<std::string>& schema, size_t count) {
        SCOPED_TRACE(id);
        const json* row = byId(rows, id);
        ASSERT_NE(row, nullptr);
        EXPECT_EQ(keysOf(*row), expectedKeys(schema, authored.at(std::to_string(id))));
        EXPECT_EQ(schema.size(), count);
    };
    check(3, { "alignment_parsed", "alpha", "angles_parsed", "brightness", "color", "colorBlendMode", "effect_count",
               "effects", "fullscreen", "id", "image", "kind", "material", "name", "nopadding", "origin_parsed",
               "parsed", "puppet", "scale_parsed", "size_parsed", "visible", "visible_parsed" }, 22);
    check(1, { "angles_parsed", "color", "id", "intensity", "kind", "light", "name", "origin_parsed", "parsed",
               "radius", "scale_parsed", "visible", "visible_parsed" }, 13);
    check(4, { "angles_parsed", "animationmode", "child_count", "controlpoint_count", "emitter_count", "id",
               "initializer_count", "kind", "maxcount", "name", "operator_count", "origin_parsed", "parsed",
               "particle", "renderer_count", "scale_parsed", "starttime", "visible", "visible_parsed" }, 19);
    check(2, { "id", "kind", "maxtime", "mintime", "name", "parsed", "playbackmode", "sound_paths", "visible",
               "visible_parsed", "volume" }, 11);
    check(5, { "id", "kind", "name", "visible" }, 4);

    const json& effect = byId(rows, 3)->at("effects")[0];
    EXPECT_EQ(keysOf(effect), (std::set<std::string> { "fbo_count", "fbos", "material_count", "materials", "name",
                                                         "pass_count", "passes", "visible" }));
}

TEST_F(WorkshopDump, LibraryResultEqualsWhatTheCommandLinePrints) {
    const std::string dir = makeItem(richItem());
    const Cli         cli = runCli({ dir });
    ASSERT_EQ(cli.code, 0);
    EXPECT_EQ(json::parse(cli.out), dump(dir).snap);
}

TEST_F(WorkshopDump, ErrorTextIsClearedByALaterSuccessfulCall) {
    std::string err;
    wmsnap::snapshotWorkshop(space.folder("nothing"), err);
    ASSERT_FALSE(err.empty());
    const json ok = wmsnap::snapshotWorkshop(makeItem({ entry("scene.json", sceneDoc(json::array())) }), err);
    EXPECT_EQ(err, "");
    EXPECT_FALSE(ok.contains("error"));
}

TEST_F(WorkshopDump, EntriesOutsideThePackageFileDoNotStopTheDump) {
    // The texture's offset lies beyond the end of the file.
    Entry far = entry("materials/x.tex", defaultTexture());
    far.shift = 100000;
    const Dumped lostTexture = dump(makeItem({ entry("scene.json", sceneDoc(json::array({ lightObject(1) }))), far }));
    EXPECT_EQ(lostTexture.err, "");
    EXPECT_EQ(lostTexture.snap.at("pkg").at("file_count"), 2);
    EXPECT_TRUE(lostTexture.snap.at("scene").at("parsed").get<bool>());
    EXPECT_EQ(lostTexture.snap.at("textures").size(), 1u);
    EXPECT_FALSE(lostTexture.snap.at("textures")[0].at("ok").get<bool>());

    // So does the scene document itself.
    Entry lostScene = entry("scene.json", sceneDoc(json::array()));
    lostScene.shift = 100000;
    const Dumped noScene = dump(makeItem({ lostScene }));
    EXPECT_EQ(noScene.err, "");
    EXPECT_EQ(noScene.snap.at("pkg").at("file_count"), 1);
    EXPECT_FALSE(noScene.snap.at("scene").at("parsed").get<bool>());
}

}  // namespace
