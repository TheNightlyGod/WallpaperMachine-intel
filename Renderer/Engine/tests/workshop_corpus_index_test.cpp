// The corpus index on a small corpus built in a scratch folder: where the root comes from, which
// folders are indexed, what is harvested and sliced, and what happens when there is no corpus.
#include <gtest/gtest.h>

#include <filesystem>
#include <sstream>

#include "workshop_corpus.hpp"
#include "workshop_fixtures.hpp"

namespace
{

using namespace wmfix;

std::vector<Entry> itemWith(std::vector<Entry> extra) {
    std::vector<Entry> entries { entry("scene.json", sceneDoc(json::array())) };
    append(entries, std::move(extra));
    return entries;
}

// Item A: a texb 3 texture and a skinned version 21 model. Item B: a texb 2 texture, a texture the
// parser cannot read, and a model that does not parse.
std::vector<Entry> itemA() {
    return itemWith({ entry("materials/t.tex", texture(3, 8, 8)), entry("models/m.mdl", skinnedModel()) });
}
std::vector<Entry> itemB() {
    return itemWith({ entry("materials/t.tex", texture(2, 16, 4)),
                      entry("materials/unreadable.tex", textBlob("not a texture")),
                      entry("models/m.mdl", junkModel()) });
}

class CorpusIndexTest : public ::testing::Test {
protected:
    Workspace space;
    std::string root() { return space.folder("corpus"); }
    void add(const std::string& id, const std::vector<Entry>& entries, const PackageOptions& options = {}) {
        space.item("corpus/" + id, entries, options);
    }
    wmsnap::Corpus build(const std::string& at, std::string* log = nullptr) {
        std::ostringstream text;
        wmsnap::Corpus     corpus = wmsnap::Corpus::build(at, text);
        if (log != nullptr) *log = text.str();
        return corpus;
    }
};

std::vector<std::string> idsOf(const wmsnap::Corpus& corpus) {
    std::vector<std::string> ids;
    for (const auto& item : corpus.items()) ids.push_back(item->id);
    return ids;
}

// CX-01
TEST_F(CorpusIndexTest, RootComesFromTheEnvironmentWhenSetAndNotEmpty) {
    {
        ScopedEnv env(wmsnap::kCorpusEnv, "/some/corpus");
        EXPECT_EQ(wmsnap::corpusRoot(), "/some/corpus");
    }
    {
        ScopedEnv env(wmsnap::kCorpusEnv, "");
        EXPECT_EQ(wmsnap::corpusRoot(), WM_DEFAULT_CORPUS_ROOT);
    }
    {
        ScopedEnv env(wmsnap::kCorpusEnv, nullptr);
        EXPECT_EQ(wmsnap::corpusRoot(), WM_DEFAULT_CORPUS_ROOT);
    }
}

// CX-02
TEST_F(CorpusIndexTest, OnlyFoldersWithAPackageAreIndexedInSortedOrder) {
    add("b-second", itemA());
    add("a-first", itemB());
    space.folder("corpus/no-package");
    space.write("corpus/stray-file.txt", std::string("not an item"));

    std::string          log;
    const wmsnap::Corpus corpus = build(root(), &log);
    EXPECT_EQ(idsOf(corpus), (std::vector<std::string> { "a-first", "b-second" }));
    EXPECT_EQ(corpus.items()[0]->snapshot.at("workshop_dir"), "a-first");
    // The other entries are not even tried, so they leave no skip note either.
    EXPECT_EQ(log.find("no-package"), std::string::npos) << log;
    EXPECT_EQ(log.find("stray-file"), std::string::npos) << log;
}

// CX-03
TEST_F(CorpusIndexTest, SkippedIdAndRejectedPackagesAreLeftOut) {
    const std::string skipped = *wmsnap::skippedItemIds().begin();
    add(skipped, itemA());
    add("good", itemA());
    space.folder("corpus/rejected");
    space.write("corpus/rejected/scene.pkg", std::string("garbage"));

    std::string          log;
    const wmsnap::Corpus corpus = build(root(), &log);
    EXPECT_EQ(idsOf(corpus), (std::vector<std::string> { "good" }));
    EXPECT_NE(log.find("corpus: skip rejected: "), std::string::npos) << log;
    EXPECT_EQ(log.find(skipped), std::string::npos) << log;
}

// CX-04
TEST_F(CorpusIndexTest, StampSetsAreHarvestedFromReadableTexturesAndEveryModel) {
    add("a", itemA());
    add("b", itemB());
    std::string          log;
    const wmsnap::Corpus corpus = build(root(), &log);

    EXPECT_EQ(corpus.packageVersions(), (std::vector<std::string> { "PKGV0001" }));
    EXPECT_EQ(corpus.textureValues("texb"), (std::vector<int> { 2, 3 }));
    // The unreadable texture reads as texv 0 and must not add a stamp of its own.
    EXPECT_EQ(corpus.textureValues("texv"), (std::vector<int> { 5 }));
    EXPECT_EQ(corpus.textureValues("texi"), (std::vector<int> { 1 }));
    EXPECT_EQ(corpus.puppetValues("mdlv"), (std::vector<int> { 13, 21 }));
    EXPECT_EQ(corpus.puppetValues("mdls"), (std::vector<int> { 1 }));
    EXPECT_EQ(corpus.puppetValues("mdla"), (std::vector<int> { 0, 1 }));
    EXPECT_NE(log.find("corpus: indexed 2 workshops; pkgv=1 texv=1 texi=1 texb=2 fmt=1 mdlv=2 mdls=1 mdla=2"),
              std::string::npos)
        << log;
}

// CX-05
TEST_F(CorpusIndexTest, SlicesHoldExactlyTheRowsWithTheValue) {
    PackageOptions newer;
    newer.version = "PKGV0017";
    add("a", itemA());
    add("b", itemB());
    add("c", itemWith({}), newer);
    const wmsnap::Corpus corpus = build(root());

    const auto three = corpus.texturesWith("texb", 3);
    ASSERT_EQ(three.size(), 1u);
    EXPECT_EQ(three[0].item->id, "a");
    EXPECT_EQ(three[0].json->at("path"), "/materials/t.tex");
    EXPECT_TRUE(corpus.texturesWith("texb", 4).empty());
    // The unreadable texture is in no slice at all, not even under 0.
    EXPECT_TRUE(corpus.texturesWith("texv", 0).empty());
    EXPECT_EQ(corpus.texturesWith("texv", 5).size(), 2u);

    const auto broken = corpus.puppetsWith("mdlv", 13);
    ASSERT_EQ(broken.size(), 1u);
    EXPECT_EQ(broken[0].item->id, "b");
    EXPECT_FALSE(broken[0].json->at("ok").get<bool>());
    EXPECT_EQ(corpus.puppetsWith("mdlv", 21).size(), 1u);
    EXPECT_TRUE(corpus.puppetsWith("mdlv", 99).empty());

    EXPECT_EQ(corpus.packagesWith("PKGV0001").size(), 2u);
    const auto newest = corpus.packagesWith("PKGV0017");
    ASSERT_EQ(newest.size(), 1u);
    EXPECT_EQ(newest[0].item->id, "c");
    EXPECT_EQ(newest[0].json->at("version"), "PKGV0017");
    EXPECT_TRUE(corpus.packagesWith("PKGV0099").empty());
}

// CX-06
TEST_F(CorpusIndexTest, MissingRootGivesAnEmptyIndexAndANote) {
    const std::string gone = space.root() + "/not-there";
    std::string       log;
    const wmsnap::Corpus corpus = build(gone, &log);
    EXPECT_TRUE(corpus.items().empty());
    EXPECT_TRUE(corpus.packageVersions().empty());
    EXPECT_TRUE(corpus.textureValues("texv").empty());
    EXPECT_TRUE(corpus.puppetValues("mdlv").empty());
    EXPECT_NE(log.find("corpus: workshop dir " + gone + " missing"), std::string::npos) << log;

    const std::string file = space.write("plain.txt", std::string("x"));
    EXPECT_TRUE(build(file).items().empty());
}

// CX-07: the check that decides whether the corpus tests run or skip.
TEST_F(CorpusIndexTest, SkipNoteNamesTheFolderAndTheVariableOnlyWhenTheFolderIsMissing) {
    const std::string gone = space.root() + "/no-corpus-here";
    const auto        note = wmsnap::missingCorpusNote(gone);
    ASSERT_TRUE(note.has_value());
    EXPECT_NE(note->find(gone), std::string::npos) << *note;
    EXPECT_NE(note->find(wmsnap::kCorpusEnv), std::string::npos) << *note;

    EXPECT_FALSE(wmsnap::missingCorpusNote(root()).has_value());
    EXPECT_TRUE(wmsnap::missingCorpusNote(space.write("file.txt", std::string("x"))).has_value());
}

}  // namespace
