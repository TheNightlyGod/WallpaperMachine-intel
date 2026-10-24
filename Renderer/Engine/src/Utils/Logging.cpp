// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#include "Utils/Logging.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <string>

namespace
{
thread_local uint64_t             t_log_scope { 0 };
// The host's sink. Swapped from any thread; each message takes one snapshot of it.
struct HostSink {
    std::atomic<WallpaperLogCallback> fn { nullptr };
    WallpaperLogCallback              snapshot() const { return fn.load(std::memory_order_acquire); }
    void                              install(WallpaperLogCallback next) {
        fn.exchange(next, std::memory_order_acq_rel);
    }
};
HostSink s_host_sink;

// The line the default sink writes, newline included.
std::string DefaultLine(int level, const char* file, int line, const std::string& text) {
    std::string out;
    if (level == LOGLEVEL_INFO) {
        out.append("INFO ");
    } else {
        out.append("ERROR ").append(file != nullptr ? file : "").append(1, ':');
        out.append(std::to_string(line)).append(1, ' ');
    }
    return out.append(text).append(1, '\n');
}

constexpr const char* kFormatFailed = "(a log message could not be formatted)";

// The message after printf-style formatting, whole whatever its length.
std::string Format(const char* fmt, va_list args) {
    if (fmt == nullptr) return kFormatFailed;
    char    stack[512];
    va_list again;
    va_copy(again, args);
    const int needed = std::vsnprintf(stack, sizeof(stack), fmt, args);
    if (needed < 0) {
        va_end(again);
        return kFormatFailed;
    }
    if (static_cast<size_t>(needed) < sizeof(stack)) {
        va_end(again);
        return std::string(stack, static_cast<size_t>(needed));
    }
    std::string text(static_cast<size_t>(needed), '\0');
    const int   written = std::vsnprintf(text.data(), text.size() + 1, fmt, again);
    va_end(again);
    if (written < 0) return kFormatFailed;
    return text;
}
} // namespace

void SetWallpaperLogCallback(WallpaperLogCallback callback) {
    s_host_sink.install(callback);
}

void SetWallpaperLogScope(uint64_t scope) { t_log_scope = scope; }

uint64_t WallpaperLogScope() { return t_log_scope; }

void WallpaperLog(int level, const char* file, int line, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    const std::string text = Format(fmt, args);
    va_end(args);

    const WallpaperLogCallback host = s_host_sink.snapshot();
    if (host != nullptr) {
        host(level, file, line, text.c_str());
        return;
    }
    // One line, one write, so lines of different threads never mix.
    const std::string out = DefaultLine(level, file, line, text);
    std::fwrite(out.data(), 1, out.size(), stderr);
    std::fflush(stderr);
}
