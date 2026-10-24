// Structural checks over a local folder of packed workshop items (WALLPAPER_MACHINE_WORKSHOP_ROOT,
// else <engine source root>/workshop). Each version stamp the corpus actually carries becomes its
// own test instance, so a stamp nobody has seen before grows the matrix on the next run. With no
// corpus no instance exists and the smoke test skips, naming the folder and the variable.
#include <gtest/gtest.h>

#include <cctype>
#include <string>
#include <vector>

#include "workshop_corpus.hpp"

namespace
{

using wmsnap::Corpus;
using wmsnap::CorpusRow;

// ---- what holds for every texture and every model ---------------------------------------------

void expectTextureSound(const CorpusRow& row) {
    SCOPED_TRACE(row.item->id + " " + row.json->value("path", std::string()));
    EXPECT_TRUE(row.json->value("ok", false));
    for (const char* key : { "width", "height", "map_width", "map_height", "count" }) {
        EXPECT_GT(row.json->value(key, 0), 0) << key;
    }
}

void expectModelSound(const CorpusRow& row) {
    SCOPED_TRACE(row.item->id + " " + row.json->value("path", std::string()));
    // A model the parser refuses (some .mdl files are plain 3-D models) still has readable stamps.
    for (const char* key : { "mdlv", "mdls", "mdla" }) {
        EXPECT_GE(row.json->value(key, -1), 0) << key;
    }
    if (row.json->value("ok", false)) {
        EXPECT_GT(row.json->value("vertex_count", 0), 0);
        // A model without bones is drawn as a static mesh, so only animations need bones.
        if (row.json->value("anims", 0) > 0) EXPECT_GT(row.json->value("bones", 0), 0);
    }
}

// ---- parameter names --------------------------------------------------------------------------

std::string numberName(const testing::TestParamInfo<int>& info) {
    return info.param < 0 ? "minus" + std::to_string(-info.param) : "v" + std::to_string(info.param);
}

std::string textName(const testing::TestParamInfo<std::string>& info) {
    std::string name;
    for (char c : info.param) name += std::isalnum(static_cast<unsigned char>(c)) ? c : '_';
    return name.empty() ? "empty" : name;
}

// One value-parameterised suite per category, instantiated from the stamps the corpus has.
#define WM_INT_SUITE(Suite, values)                                                       \
    class Suite : public testing::TestWithParam<int> {};                                  \
    GTEST_ALLOW_UNINSTANTIATED_PARAMETERIZED_TEST(Suite);                                 \
    INSTANTIATE_TEST_SUITE_P(Corpus, Suite, testing::ValuesIn(values), numberName)

std::vector<int> textureStamps(const char* field) { return Corpus::shared().textureValues(field); }
std::vector<int> puppetStamps(const char* field) { return Corpus::shared().puppetValues(field); }

class PackageVersionStamp : public testing::TestWithParam<std::string> {};
GTEST_ALLOW_UNINSTANTIATED_PARAMETERIZED_TEST(PackageVersionStamp);
INSTANTIATE_TEST_SUITE_P(Corpus, PackageVersionStamp, testing::ValuesIn(Corpus::shared().packageVersions()),
                         textName);

WM_INT_SUITE(TextureVersionStamp, textureStamps("texv"));
WM_INT_SUITE(TextureInfoStamp, textureStamps("texi"));
WM_INT_SUITE(TextureBodyStamp, textureStamps("texb"));
WM_INT_SUITE(TexturePixelFormat, textureStamps("format"));
WM_INT_SUITE(ModelVersionStamp, puppetStamps("mdlv"));
WM_INT_SUITE(ModelSkeletonStamp, puppetStamps("mdls"));
WM_INT_SUITE(ModelAnimationStamp, puppetStamps("mdla"));

void checkTextures(const char* field, int value) {
    const auto rows = Corpus::shared().texturesWith(field, value);
    ASSERT_FALSE(rows.empty());
    for (const auto& row : rows) {
        EXPECT_EQ(row.json->value(field, -2), value) << row.item->id;
        expectTextureSound(row);
    }
}

void checkModels(const char* field, int value) {
    const auto rows = Corpus::shared().puppetsWith(field, value);
    ASSERT_FALSE(rows.empty());
    for (const auto& row : rows) {
        EXPECT_EQ(row.json->value(field, -2), value) << row.item->id;
        expectModelSound(row);
    }
}

// CV-01
TEST_P(PackageVersionStamp, EveryItemWithTheVersionHasAReadableScene) {
    const auto rows = Corpus::shared().packagesWith(GetParam());
    ASSERT_FALSE(rows.empty());
    for (const auto& row : rows) {
        SCOPED_TRACE(row.item->id);
        EXPECT_EQ(row.json->value("version", std::string()), GetParam());
        EXPECT_GT(row.json->value("file_count", 0), 0);
        EXPECT_TRUE(row.json->value("has_scene_json", false));
        const auto& snap = row.item->snapshot;
        ASSERT_TRUE(snap.contains("scene"));
        const auto& scene = snap.at("scene");
        EXPECT_TRUE(scene.value("parsed", false)) << scene.value("error", std::string());
        if (scene.value("is_ortho", false)) {
            EXPECT_GT(scene.at("ortho").value("width", 0), 0);
            EXPECT_GT(scene.at("ortho").value("height", 0), 0);
        }
    }
}

// CV-02 .. CV-05
TEST_P(TextureVersionStamp, EveryTextureWithTheStampIsReadable) { checkTextures("texv", GetParam()); }
TEST_P(TextureInfoStamp, EveryTextureWithTheStampIsReadable) { checkTextures("texi", GetParam()); }
TEST_P(TextureBodyStamp, EveryTextureWithTheStampIsReadable) { checkTextures("texb", GetParam()); }
TEST_P(TexturePixelFormat, EveryTextureWithTheFormatIsReadable) { checkTextures("format", GetParam()); }

// CV-06 .. CV-08
TEST_P(ModelVersionStamp, EveryModelWithTheStampHasReadableStamps) { checkModels("mdlv", GetParam()); }
TEST_P(ModelSkeletonStamp, EveryModelWithTheStampHasReadableStamps) { checkModels("mdls", GetParam()); }
TEST_P(ModelAnimationStamp, EveryModelWithTheStampHasReadableStamps) { checkModels("mdla", GetParam()); }

// CV-09
TEST(CorpusSmoke, CorpusFolderHoldsItemsWithStamps) {
    if (const auto note = wmsnap::missingCorpusNote(wmsnap::corpusRoot())) GTEST_SKIP() << *note;
    const Corpus& corpus = Corpus::shared();
    EXPECT_FALSE(corpus.items().empty());
    EXPECT_FALSE(corpus.packageVersions().empty());
    EXPECT_FALSE(corpus.textureValues("texv").empty());
    EXPECT_FALSE(corpus.puppetValues("mdlv").empty());
}

}  // namespace
