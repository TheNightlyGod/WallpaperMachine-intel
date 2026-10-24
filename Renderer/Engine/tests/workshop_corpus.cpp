#include "workshop_corpus.hpp"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <ostream>

#include "workshop_snapshot.hpp"

namespace wmsnap
{
namespace
{

namespace fsys = std::filesystem;

constexpr const char* kTextureFields[] = { "texv", "texi", "texb", "format" };
constexpr const char* kPuppetFields[]  = { "mdlv", "mdls", "mdla" };

// A missing field counts as -1.
int intField(const nlohmann::json& row, const char* key) {
    const auto found = row.find(key);
    return found != row.end() && found->is_number_integer() ? found->get<int>() : -1;
}

template<class Map>
std::vector<int> keysOf(const Map& slices, const std::string& field) {
    std::vector<int> out;
    const auto       found = slices.find(field);
    if (found == slices.end()) return out;
    for (const auto& entry : found->second) out.push_back(entry.first);
    return out;
}

template<class Map>
std::vector<CorpusRow> rowsOf(const Map& slices, const std::string& field, int value) {
    const auto byField = slices.find(field);
    if (byField == slices.end()) return {};
    const auto byValue = byField->second.find(value);
    return byValue == byField->second.end() ? std::vector<CorpusRow> {} : byValue->second;
}

size_t distinct(const std::map<std::string, std::map<int, std::vector<CorpusRow>>>& slices,
                const char* field) {
    const auto found = slices.find(field);
    return found == slices.end() ? 0 : found->second.size();
}

} // namespace

std::string corpusRoot() {
    const char* value = std::getenv(kCorpusEnv);
    if (value != nullptr && *value != '\0') return value;
    return WM_DEFAULT_CORPUS_ROOT;
}

const std::set<std::string>& skippedItemIds() {
    static const std::set<std::string> ids { "2435537849" };
    return ids;
}

std::optional<std::string> missingCorpusNote(const std::string& root) {
    std::error_code ignored;
    if (fsys::is_directory(root, ignored)) return std::nullopt;
    return "no workshop corpus at \"" + root + "\"; set " + kCorpusEnv +
           " to a folder of packed workshop items to run these checks";
}

Corpus Corpus::build(const std::string& root, std::ostream& log) {
    Corpus corpus;
    std::error_code ignored;
    if (! fsys::is_directory(root, ignored)) {
        log << "corpus: workshop dir " << root << " missing\n";
        return corpus;
    }

    std::vector<fsys::path> folders;
    for (fsys::directory_iterator it(root, ignored), end; ! ignored && it != end; it.increment(ignored)) {
        std::error_code probe;
        if (it->is_directory(probe) && fsys::exists(it->path() / "scene.pkg", probe)) {
            folders.push_back(it->path());
        }
    }
    std::sort(folders.begin(), folders.end());

    for (const auto& folder : folders) {
        const std::string id = folder.filename().string();
        if (skippedItemIds().count(id) != 0) continue;
        auto item = std::make_unique<CorpusItem>();
        item->id  = id;
        item->dir = folder.string();
        std::string err;
        item->snapshot = snapshotWorkshop(item->dir, err);
        if (! err.empty()) {
            log << "corpus: skip " << id << ": " << err << "\n";
            continue;
        }
        corpus.m_items.push_back(std::move(item));
    }

    // The rows point into the stored snapshots, which do not change from here on.
    for (const auto& item : corpus.m_items) {
        const auto& snap = item->snapshot;
        if (const auto pkg = snap.find("pkg"); pkg != snap.end()) {
            corpus.m_packages[pkg->value("version", std::string())].push_back({ item.get(), &*pkg });
        }
        if (const auto list = snap.find("textures"); list != snap.end()) {
            for (const auto& row : *list) {
                if (! row.value("ok", false)) continue;
                for (const char* field : kTextureFields) {
                    corpus.m_textures[field][intField(row, field)].push_back({ item.get(), &row });
                }
            }
        }
        if (const auto list = snap.find("puppets"); list != snap.end()) {
            for (const auto& row : *list) {
                for (const char* field : kPuppetFields) {
                    corpus.m_puppets[field][intField(row, field)].push_back({ item.get(), &row });
                }
            }
        }
    }

    log << "corpus: indexed " << corpus.m_items.size() << " workshops; pkgv=" << corpus.m_packages.size()
        << " texv=" << distinct(corpus.m_textures, "texv") << " texi=" << distinct(corpus.m_textures, "texi")
        << " texb=" << distinct(corpus.m_textures, "texb") << " fmt=" << distinct(corpus.m_textures, "format")
        << " mdlv=" << distinct(corpus.m_puppets, "mdlv") << " mdls=" << distinct(corpus.m_puppets, "mdls")
        << " mdla=" << distinct(corpus.m_puppets, "mdla") << "\n";
    return corpus;
}

const Corpus& Corpus::shared() {
    static const Corpus corpus = build(corpusRoot(), std::cerr);
    return corpus;
}

std::vector<std::string> Corpus::packageVersions() const {
    std::vector<std::string> out;
    for (const auto& entry : m_packages) out.push_back(entry.first);
    return out;
}

std::vector<CorpusRow> Corpus::packagesWith(const std::string& version) const {
    const auto found = m_packages.find(version);
    return found == m_packages.end() ? std::vector<CorpusRow> {} : found->second;
}

std::vector<int> Corpus::textureValues(const std::string& field) const { return keysOf(m_textures, field); }
std::vector<CorpusRow> Corpus::texturesWith(const std::string& field, int value) const {
    return rowsOf(m_textures, field, value);
}
std::vector<int> Corpus::puppetValues(const std::string& field) const { return keysOf(m_puppets, field); }
std::vector<CorpusRow> Corpus::puppetsWith(const std::string& field, int value) const {
    return rowsOf(m_puppets, field, value);
}

} // namespace wmsnap
