#pragma once

#include <array>
#include <cstddef>
#include <filesystem>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>

namespace wallpaper
{

/// The text behind a scene's script `localStorage`: two locations (Wallpaper Engine's
/// LOCATION_GLOBAL and LOCATION_SCREEN), each a map from key to the JSON text the script set.
///
/// Persisted, when configured with a folder, as `<folder>/global.json` and
/// `<folder>/screen-<screen key>.json` (`{"version":1,"entries":{"<key>":"<json text>"}}`).
/// Writes are coalesced: `FlushIfDue` writes a location at most every 2 s, through a temporary
/// file renamed over the old one, merging only the keys this instance changed into what is on
/// disk (two displays share the global file), under a process-wide mutex per file. Read-only
/// storage (the preview window, the lock screen) changes memory only. With no folder the store
/// lives in memory only.
class SceneScriptStorage {
public:
    /// WE refuses a set once a location's values would exceed 100,000 bytes, each value counted
    /// with its 8-byte "LSKV0001" prefix (wallpaper64.exe sub_14018E3A0).
    static constexpr std::size_t kLocationLimitBytes = 100000;
    static constexpr std::size_t kValuePrefixBytes   = 8;
    static constexpr double      kFlushIntervalSeconds = 2.0;

    /// Loads both locations from `directory` (empty path = memory only). Unsaved changes of a
    /// previous configuration are written first.
    void Configure(std::filesystem::path directory, std::string screen_key, bool read_only);

    std::optional<std::string> Get(bool global, std::string_view key) const;
    /// False when the location would exceed `kLocationLimitBytes`; nothing is stored then.
    bool Set(bool global, std::string_view key, std::string text);
    bool Delete(bool global, std::string_view key);
    void Clear(bool global);

    void FlushIfDue(double now_seconds);
    void FlushNow();
    ~SceneScriptStorage() { FlushNow(); }

    std::filesystem::path FileOf(bool global) const;

private:
    struct Location {
        std::map<std::string, std::string, std::less<>> entries;
        std::set<std::string, std::less<>>              dirty;
        bool                                            cleared { false };
        std::size_t                                     bytes { 0 };
    };
    void  Write(bool global);
    bool  Dirty(const Location& l) const { return l.cleared || ! l.dirty.empty(); }

    std::filesystem::path   m_directory;
    std::string             m_screen_key;
    bool                    m_read_only { false };
    std::array<Location, 2> m_locations; // [0] screen, [1] global
    std::optional<double>   m_dirty_since;
    std::optional<double>   m_last_write;
};

} // namespace wallpaper
