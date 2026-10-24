// An index over a local folder of packed workshop items: every item is dumped once with
// workshop_snapshot and the version stamps it carries are collected, so the corpus tests can
// create one test instance per stamp value actually seen.
#pragma once

#include <iosfwd>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace wmsnap
{

// Names the corpus folder: set and non-empty wins over the compile-time default.
inline constexpr const char* kCorpusEnv = "WALLPAPER_MACHINE_WORKSHOP_ROOT";

#ifndef WM_DEFAULT_CORPUS_ROOT
#define WM_DEFAULT_CORPUS_ROOT "workshop"
#endif

// The folder to index. The environment is read on every call.
std::string corpusRoot();

// Item folders that are never opened. A local item once stalled a parser; the id is a fact
// about one machine's corpus, not a rendering rule.
const std::set<std::string>& skippedItemIds();

// Why a corpus check has nothing to run on `root`; empty when the folder exists.
std::optional<std::string> missingCorpusNote(const std::string& root);

struct CorpusItem {
    std::string    id;       // the folder name
    std::string    dir;
    nlohmann::json snapshot; // the whole dump
};

// One entry of a slice: the item and the JSON object (pkg block, texture row or puppet row).
struct CorpusRow {
    const CorpusItem*     item { nullptr };
    const nlohmann::json* json { nullptr };
};

class Corpus {
public:
    // Dumps the direct subfolders of `root` that hold a scene.pkg, in sorted order.
    // Progress and skips are written to `log`.
    static Corpus build(const std::string& root, std::ostream& log);
    // The corpus of corpusRoot(), built on first use.
    static const Corpus& shared();

    const std::vector<std::unique_ptr<CorpusItem>>& items() const { return m_items; }

    std::vector<std::string> packageVersions() const;
    std::vector<CorpusRow>   packagesWith(const std::string& version) const;

    // Texture fields: texv, texi, texb, format. Only textures that parsed count.
    std::vector<int>       textureValues(const std::string& field) const;
    std::vector<CorpusRow> texturesWith(const std::string& field, int value) const;

    // Puppet fields: mdlv, mdls, mdla. Every model counts, parsed or not.
    std::vector<int>       puppetValues(const std::string& field) const;
    std::vector<CorpusRow> puppetsWith(const std::string& field, int value) const;

private:
    using IntSlices = std::map<std::string, std::map<int, std::vector<CorpusRow>>>;

    std::vector<std::unique_ptr<CorpusItem>>            m_items;
    std::map<std::string, std::vector<CorpusRow>>       m_packages;
    IntSlices                                           m_textures;
    IntSlices                                           m_puppets;
};

} // namespace wmsnap
