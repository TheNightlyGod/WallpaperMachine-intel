#include "Runtime/SceneScriptStorage.hpp"

#include "Utils/Logging.h"

#include <nlohmann/json.hpp>

#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <system_error>
#include <unistd.h>

namespace wallpaper
{
namespace
{

// One mutex per file for the whole process: scenes on two displays share global.json.
std::mutex& MutexFor(const std::filesystem::path& file) {
    static std::mutex                                               guard;
    static std::map<std::string, std::unique_ptr<std::mutex>>       mutexes;
    std::lock_guard lock(guard);
    auto& slot = mutexes[file.lexically_normal().string()];
    if (! slot) slot = std::make_unique<std::mutex>();
    return *slot;
}

std::map<std::string, std::string, std::less<>> ReadEntries(const std::filesystem::path& file) {
    std::map<std::string, std::string, std::less<>> out;
    std::ifstream in(file, std::ios::binary);
    if (! in) return out;
    std::stringstream text;
    text << in.rdbuf();
    const auto json = nlohmann::json::parse(text.str(), nullptr, false);
    if (json.is_discarded() || ! json.is_object() || ! json.contains("entries") ||
        ! json["entries"].is_object()) {
        LOG_INFO("script storage %s cannot be read; it starts empty", file.c_str());
        return out;
    }
    for (const auto& [key, value] : json["entries"].items())
        if (value.is_string()) out.emplace(key, value.get<std::string>());
    return out;
}

std::size_t BytesOf(const std::map<std::string, std::string, std::less<>>& entries) {
    std::size_t total = 0;
    for (const auto& [_, text] : entries) total += SceneScriptStorage::kValuePrefixBytes + text.size();
    return total;
}

} // namespace

std::filesystem::path SceneScriptStorage::FileOf(bool global) const {
    if (m_directory.empty()) return {};
    return m_directory / (global ? std::string("global.json") : "screen-" + m_screen_key + ".json");
}

void SceneScriptStorage::Configure(std::filesystem::path directory, std::string screen_key,
                                   bool read_only) {
    FlushNow();
    m_directory  = std::move(directory);
    m_screen_key = std::move(screen_key);
    m_read_only  = read_only;
    m_dirty_since.reset();
    m_last_write.reset();
    for (int g = 0; g < 2; ++g) {
        auto& loc = m_locations[g];
        loc       = Location {};
        if (m_directory.empty()) continue;
        const auto file = FileOf(g == 1);
        std::lock_guard lock(MutexFor(file));
        loc.entries = ReadEntries(file);
        loc.bytes   = BytesOf(loc.entries);
    }
}

std::optional<std::string> SceneScriptStorage::Get(bool global, std::string_view key) const {
    const auto& entries = m_locations[global ? 1 : 0].entries;
    const auto  found   = entries.find(key);
    if (found == entries.end()) return std::nullopt;
    return found->second;
}

bool SceneScriptStorage::Set(bool global, std::string_view key, std::string text) {
    auto&       loc   = m_locations[global ? 1 : 0];
    const auto  found = loc.entries.find(key);
    const auto  old   = found == loc.entries.end() ? 0 : kValuePrefixBytes + found->second.size();
    const auto  next  = loc.bytes - old + kValuePrefixBytes + text.size();
    if (next > kLocationLimitBytes) return false;
    loc.bytes = next;
    if (found == loc.entries.end()) loc.entries.emplace(std::string(key), std::move(text));
    else found->second = std::move(text);
    loc.dirty.emplace(key);
    return true;
}

bool SceneScriptStorage::Delete(bool global, std::string_view key) {
    auto&      loc   = m_locations[global ? 1 : 0];
    const auto found = loc.entries.find(key);
    if (found == loc.entries.end()) return false;
    loc.bytes -= kValuePrefixBytes + found->second.size();
    loc.entries.erase(found);
    loc.dirty.emplace(key);
    return true;
}

void SceneScriptStorage::Clear(bool global) {
    auto& loc = m_locations[global ? 1 : 0];
    loc.entries.clear();
    loc.dirty.clear();
    loc.bytes   = 0;
    loc.cleared = true;
}

void SceneScriptStorage::FlushIfDue(double now_seconds) {
    if (! Dirty(m_locations[0]) && ! Dirty(m_locations[1])) return;
    if (m_read_only || m_directory.empty()) {
        for (auto& loc : m_locations) { loc.dirty.clear(); loc.cleared = false; }
        return;
    }
    if (! m_dirty_since) m_dirty_since = now_seconds;
    const double since = m_last_write ? std::max(*m_last_write, *m_dirty_since) : *m_dirty_since;
    if (now_seconds - since < kFlushIntervalSeconds) return;
    FlushNow();
    m_last_write = now_seconds;
}

void SceneScriptStorage::FlushNow() {
    for (int g = 0; g < 2; ++g) {
        auto& loc = m_locations[g];
        if (! Dirty(loc)) continue;
        if (! m_read_only && ! m_directory.empty()) Write(g == 1);
        loc.dirty.clear();
        loc.cleared = false;
    }
    m_dirty_since.reset();
}

void SceneScriptStorage::Write(bool global) {
    auto&      loc  = m_locations[global ? 1 : 0];
    const auto file = FileOf(global);
    std::lock_guard lock(MutexFor(file));
    // Merge: keep what another instance wrote, except for the keys this one changed.
    auto merged = loc.cleared ? loc.entries : ReadEntries(file);
    for (const auto& key : loc.dirty) {
        const auto mine = loc.entries.find(key);
        if (mine == loc.entries.end()) merged.erase(key);
        else merged.insert_or_assign(key, mine->second);
    }
    nlohmann::json entries = nlohmann::json::object();
    for (const auto& [key, text] : merged) entries[key] = text;
    const nlohmann::json doc { { "version", 1 }, { "entries", std::move(entries) } };

    std::error_code ec;
    std::filesystem::create_directories(m_directory, ec);
    auto tmp = file;
    tmp += ".tmp." + std::to_string(::getpid());
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        out << doc.dump();
        if (! out) {
            LOG_ERROR("script storage %s cannot be written", tmp.c_str());
            return;
        }
    }
    std::filesystem::rename(tmp, file, ec);
    if (ec) {
        LOG_ERROR("script storage %s cannot be replaced: %s", file.c_str(), ec.message().c_str());
        std::filesystem::remove(tmp, ec);
    }
}

} // namespace wallpaper
