// Shared by the corpus A/B tests: finding the local video corpus and asking
// ffprobe about a file. Everything here is optional; a test that cannot find
// what it needs skips and says why.
#pragma once

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper::media::testing
{

namespace fs = std::filesystem;

/// WALLPAPER_MACHINE_VIDEO_ROOT, else the app's local wallpaper library; nullopt when neither is a directory.
inline std::optional<fs::path> CorpusRoot()
{
    fs::path root;
    if (const char* chosen = std::getenv("WALLPAPER_MACHINE_VIDEO_ROOT")) {
        root = chosen;
    } else if (const char* home = std::getenv("HOME")) {
        root = fs::path(home) / "Library/Application Support/WallpaperMachine/Library";
    }
    std::error_code ignored;
    if (root.empty() || ! fs::is_directory(root, ignored)) return std::nullopt;
    return root;
}

inline std::string LowerExtension(const fs::path& path)
{
    std::string extension = path.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return extension;
}

/// Regular files under `root` (at most three folders deep) whose extension is in `extensions`, sorted, at most `limit`.
inline std::vector<fs::path> CorpusFiles(const fs::path& root, const std::vector<std::string>& extensions, std::size_t limit = 60)
{
    std::vector<fs::path> files;
    std::error_code       ignored;
    for (fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ignored), end;
         it != end && files.size() < limit; it.increment(ignored)) {
        if (ignored) break;
        if (it.depth() > 3) {
            it.disable_recursion_pending();
            continue;
        }
        if (it->is_regular_file(ignored) &&
            std::find(extensions.begin(), extensions.end(), LowerExtension(it->path())) != extensions.end()) {
            files.push_back(it->path());
        }
    }
    std::sort(files.begin(), files.end());
    return files;
}

inline std::string FindFfprobe()
{
    if (const char* chosen = std::getenv("WALLPAPER_MACHINE_FFPROBE")) return fs::exists(chosen) ? chosen : "";
    for (const char* candidate : { "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe" }) {
        if (fs::exists(candidate)) return candidate;
    }
    return "";
}

inline std::string ShellQuote(const std::string& text)
{
    std::string quoted = "'";
    for (char c : text) quoted += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return quoted + "'";
}

/// key=value lines of `ffprobe -show_entries <entries>` for the first video stream
/// (`-count_packets` adds nb_read_packets). Keys of the format section have a "format." prefix.
inline std::map<std::string, std::string> Ffprobe(const std::string& ffprobe, const fs::path& file)
{
    std::map<std::string, std::string> values;
    const std::string command = ShellQuote(ffprobe) +
        " -v error -select_streams v:0 -count_packets"
        " -show_entries stream=width,height,nb_read_packets,duration:format=duration"
        " -of default=nw=1 " + ShellQuote(file.string()) + " 2>/dev/null";
    FILE* pipe = ::popen(command.c_str(), "r");
    if (pipe == nullptr) return values;
    char        line[256];
    int         streamDurations = 0;
    while (std::fgets(line, sizeof(line), pipe) != nullptr) {
        std::string text(line);
        while (! text.empty() && (text.back() == '\n' || text.back() == '\r')) text.pop_back();
        const auto equals = text.find('=');
        if (equals == std::string::npos) continue;
        std::string key = text.substr(0, equals);
        // Both the stream and the format print "duration": the stream's comes first.
        if (key == "duration" && streamDurations++ == 1) key = "format.duration";
        values[key] = text.substr(equals + 1);
    }
    ::pclose(pipe);
    return values;
}

} // namespace wallpaper::media::testing
