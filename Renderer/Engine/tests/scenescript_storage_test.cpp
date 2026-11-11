// Script localStorage (plan Appendix A item 3, decision I3): what WE's LocalStorageSet/Get do
// (scenescript64.dll sub_181658680 / sub_181658A80, wallpaper64.exe sub_14018E3A0; notes in
// artifacts/we-parity/decompiles/A-3-localstorage.md) and how the host keeps it between runs.
//
// Headless: scenes are loaded for their runtime only (support/script_scene.hpp).

#include "scenescript_scenes.hpp"

#include "Runtime/SceneRuntimeContext.hpp"

#include <nlohmann/json.hpp>

#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>
#include <sstream>

namespace
{
using namespace we_test;
namespace disk = std::filesystem;

// A scratch storage folder, removed afterwards.
struct StorageFolder {
    disk::path path;
    StorageFolder() {
        path = disk::temp_directory_path() /
               ("we-storage-" + std::to_string(::getpid()) + "-" + std::to_string(reinterpret_cast<uintptr_t>(this)));
        disk::remove_all(path);
    }
    ~StorageFolder() {
        std::error_code ignored;
        disk::remove_all(path, ignored);
    }
    [[nodiscard]] disk::path Global() const { return path / "global.json"; }
    [[nodiscard]] disk::path Screen(const std::string& key = "display-1") const {
        return path / ("screen-" + key + ".json");
    }
};

// The JSON text stored under `key` in `file`, or "" when absent.
std::string StoredText(const disk::path& file, const std::string& key) {
    std::ifstream in(file);
    if (! in) return "";
    std::stringstream text;
    text << in.rdbuf();
    const auto doc = nlohmann::json::parse(text.str(), nullptr, false);
    if (doc.is_discarded() || ! doc.contains("entries") || ! doc["entries"].contains(key)) return "";
    return doc["entries"][key].get<std::string>();
}

// One scene whose layer "probe" gets `report` (an expression) as origin x on the first update,
// after `body` ran.
struct StorageRun {
    ScenePackage package;
    std::unique_ptr<ScriptScene> scene;
    StorageRun(const StorageFolder* folder, const std::string& body, const std::string& report,
        bool read_only = false, const Json& properties = Json::object()) {
        const auto model  = package.AddImageModel("plain");
        const auto script = Join({ "var first = true;", "export function update() {", "  if (!first) return;",
                                   "  first = false;", body,
                                   "  thisScene.getLayer('probe').origin = new Vec3(" + report + ", 0, 0);", "}" });
        Publish(package, { PlainImage(model, 1, "probe"),
                           PlainImage(model, 2, "writer", { { "alpha", ScriptedValue(script, 1.0) } }) },
                properties);
        ScriptSceneOptions options;
        if (folder != nullptr) options.storage_directory = folder->path.string();
        options.storage_read_only = read_only;
        scene = std::make_unique<ScriptScene>(package, options);
    }
    float Report() {
        scene->Tick(1);
        return scene->Origin("probe")[0];
    }
};

} // namespace

TEST(SceneScriptStorage, AValueSetInOneRunIsReadInTheNext)
{
    StorageFolder folder;
    {
        StorageRun first(&folder, "localStorage.set('k', { a: 1 });", "1");
        ASSERT_TRUE(first.scene->ok()) << first.scene->error();
        EXPECT_EQ(first.Report(), 1.0f);
        EXPECT_TRUE(first.scene->ScriptErrors().empty()) << Describe(first.scene->ScriptErrors());
    }
    StorageRun second(&folder, "", "localStorage.get('k').a === 1 ? 1 : 0");
    ASSERT_TRUE(second.scene->ok()) << second.scene->error();
    EXPECT_EQ(second.Report(), 1.0f) << "the second load reads what the first one set";
}

TEST(SceneScriptStorage, ScreenIsTheDefaultAndGlobalIsSeparate)
{
    StorageFolder folder;
    {
        StorageRun run(&folder, "localStorage.set('k', 1); localStorage.set('k', 2, localStorage.LOCATION_GLOBAL);",
                "localStorage.get('k') * 10 + localStorage.get('k', 'global')");
        EXPECT_EQ(run.Report(), 12.0f);
    }
    EXPECT_EQ(StoredText(folder.Screen(), "k"), "1");
    EXPECT_EQ(StoredText(folder.Global(), "k"), "2");
}

// WE stringifies without a replacer and parses on every get: a Vec3 comes back as {x, y, z}.
TEST(SceneScriptStorage, AVec3ComesBackAsAPlainObject)
{
    StorageRun run(nullptr, "localStorage.set('v', new Vec3(1, 2, 3)); var v = localStorage.get('v');",
            "(!(v instanceof Vec3) && v.x === 1 && v.y === 2 && v.z === 3) ? 1 : 0");
    EXPECT_EQ(run.Report(), 1.0f);
}

TEST(SceneScriptStorage, SetSerialisesAtTheCall)
{
    StorageRun run(nullptr, "var o = { a: 1 }; localStorage.set('o', o); o.a = 2; var a = localStorage.get('o');",
            "(a.a === 1 && a !== localStorage.get('o')) ? 1 : 0");
    EXPECT_EQ(run.Report(), 1.0f);
}

TEST(SceneScriptStorage, NonStringKeyThrowsWEsMessage)
{
    StorageRun run(nullptr, "var m = ''; try { localStorage.set(1, 2); } catch (e) { m = e.message; }",
            "m === 'LocalStorageSet key not a string.' ? 1 : 0");
    EXPECT_EQ(run.Report(), 1.0f);
}

// 100,000 bytes per location, each value counted with WE's 8-byte prefix: a string of n
// characters is n + 2 bytes of JSON.
TEST(SceneScriptStorage, OverOneHundredThousandBytesThrows)
{
    StorageRun run(nullptr,
            Join({ "var fits = 'x'.repeat(99990), m = '';",
                   "localStorage.set('a', fits);",
                   "try { localStorage.set('b', 'y'); } catch (e) { m = e.message; }",
                   "var big = 0; try { localStorage.set('a', fits + 'x'); } catch (e) { big = 1; }" }),
            "(m === 'LocalStorageSet failed, possibly out of memory.' && big === 1 && "
            "localStorage.get('a').length === 99990 && localStorage.get('b') === undefined) ? 1 : 0");
    EXPECT_EQ(run.Report(), 1.0f);
}

TEST(SceneScriptStorage, NoWriteBeforeTwoSeconds)
{
    StorageFolder folder;
    ScenePackage  package;
    const auto    model  = package.AddImageModel("plain");
    const auto    script = "var n = 0; export function update() { localStorage.set('n', ++n); }";
    Publish(package, { PlainImage(model, 1, "writer", { { "alpha", ScriptedValue(script, 1.0) } }) });
    ScriptSceneOptions options;
    options.storage_directory = folder.path.string();
    options.time_step         = 1.0 / 60.0;
    ScriptScene scene(package, options);
    ASSERT_TRUE(scene.ok()) << scene.error();
    scene.Tick(30);
    EXPECT_FALSE(disk::exists(folder.Screen())) << "half a second of sets writes nothing";
    scene.Tick(80);
    EXPECT_FALSE(disk::exists(folder.Screen())) << "nor do 110 frames (1.8 s)";
    scene.Tick(20);
    EXPECT_TRUE(disk::exists(folder.Screen())) << "two seconds after the first set the file is written";
    const auto written = std::stoi(StoredText(folder.Screen(), "n"));
    EXPECT_GE(written, 120);
    scene.Tick(10);
    EXPECT_EQ(std::stoi(StoredText(folder.Screen(), "n")), written) << "the next write waits two seconds again";
}

TEST(SceneScriptStorage, ReadOnlyNeverWrites)
{
    StorageFolder folder;
    {
        StorageRun run(&folder, "localStorage.set('k', 3);", "localStorage.get('k')", /*read_only*/ true);
        EXPECT_EQ(run.Report(), 3.0f) << "the value is kept in memory";
    }
    EXPECT_FALSE(disk::exists(folder.path)) << "nothing is written";
}

// Plan decision I3: unlike WE's settings "Reset", a user-property change or reset keeps storage.
TEST(SceneScriptStorage, PropertyResetDoesNotClearStorage)
{
    StorageFolder folder;
    StorageRun run(&folder, "localStorage.set('k', 5);", "1", false, { { "flag", BoolProperty(true) } });
    ASSERT_TRUE(run.scene->ok()) << run.scene->error();
    run.scene->Tick(1);
    ASSERT_TRUE(run.scene->SetProperty("flag", false));
    run.scene->Tick(1);
    ASSERT_TRUE(run.scene->SetProperty("flag", true));
    run.scene->Tick(1);
    const auto value = run.scene->runtime().ScriptStorage().Get(false, "k");
    ASSERT_TRUE(value.has_value());
    EXPECT_EQ(*value, "5");
}

TEST(SceneScriptStorage, DeleteAnswersWhetherTheKeyExistedAndClearEmptiesBoth)
{
    StorageRun run(nullptr,
            Join({ "localStorage.set('a', 1); localStorage.set('a', 1, 'global');",
                   "var d1 = localStorage.delete('a'), d2 = localStorage.delete('a');",
                   "localStorage.set('b', 1); localStorage.clear();" }),
            "(d1 === true && d2 === false && localStorage.get('b') === undefined && "
            "localStorage.get('a', 'global') === undefined) ? 1 : 0");
    EXPECT_EQ(run.Report(), 1.0f);
}
