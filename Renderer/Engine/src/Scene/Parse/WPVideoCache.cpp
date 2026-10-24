#include "WPVideoCache.hpp"

#include "Fs/IBinaryStream.h"
#include "Utils/Logging.h"
#include "Utils/Sha.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

namespace wallpaper
{
namespace
{
namespace disk = std::filesystem;

// How much of the clip is held at once, while it is hashed and while it is copied.
constexpr std::size_t kPiece = std::size_t { 1 } << 20;

// A whole entry: a regular file of the clip's size.
bool IsWholeEntry(const disk::path& path, std::uintmax_t size)
{
    std::error_code failure;
    return disk::is_regular_file(path, failure) && ! failure && disk::file_size(path, failure) == size && ! failure;
}

// The clip's SHA-1, read through in pieces; empty if it cannot be read to its end.
std::string HashOf(fs::IBinaryStream& clip, std::vector<char>& piece)
{
    if (! clip.SeekSet(0)) return {};
    utils::Sha1Stream digest;
    for (isize left = clip.Size(); left > 0;) {
        const usize want = static_cast<usize>(std::min<isize>(left, static_cast<isize>(piece.size())));
        if (clip.Read(piece.data(), want) != want) return {};
        digest.Update(std::span<const char>(piece.data(), want));
        left -= static_cast<isize>(want);
    }
    return digest.Finish();
}

// Copies the clip to a new file at `staging`; false (and nothing left) if any piece fails.
bool CopyTo(fs::IBinaryStream& clip, const disk::path& staging, std::vector<char>& piece)
{
    if (! clip.SeekSet(0)) return false;
    // `x` makes the open fail rather than reuse a file that is there already.
    std::FILE* out = std::fopen(staging.c_str(), "wbx");
    if (out == nullptr) return false;
    bool ok = true;
    for (isize left = clip.Size(); left > 0 && ok;) {
        const usize want = static_cast<usize>(std::min<isize>(left, static_cast<isize>(piece.size())));
        ok               = clip.Read(piece.data(), want) == want && std::fwrite(piece.data(), 1, want, out) == want;
        left -= static_cast<isize>(want);
    }
    // The published file is read by another process (a decoder): its bytes are on their way to the
    // disk before its name appears.
    ok = ok && std::fflush(out) == 0 && ::fsync(::fileno(out)) == 0;
    ok = std::fclose(out) == 0 && ok;
    if (! ok) {
        std::error_code ignored;
        disk::remove(staging, ignored);
    }
    return ok;
}
} // namespace

std::string CacheVideoByContent(fs::IBinaryStream& clip, std::string_view extension)
{
    const isize size = clip.Size();
    if (size <= 0) return {};
    std::vector<char> piece(kPiece);

    const std::string digest = HashOf(clip, piece);
    if (digest.empty()) return {};

    std::error_code failure;
    const disk::path folder = disk::temp_directory_path(failure);
    if (failure) return {};
    const disk::path entry = folder / ("wallpaper-machine-video-" + digest + std::string(extension));
    const auto       bytes = static_cast<std::uintmax_t>(size);
    if (IsWholeEntry(entry, bytes)) return entry.string();

    // A staging name no other opener, in this process or another, shares.
    static std::atomic<std::uint64_t> serial { 0 };
    const disk::path                  staging =
        folder / ("wallpaper-machine-video-" + digest + "." + std::to_string(::getpid()) + "-" +
                  std::to_string(serial.fetch_add(1)) + "-" +
                  std::to_string(std::hash<std::thread::id> {}(std::this_thread::get_id()) % 100000) + ".part");
    if (! CopyTo(clip, staging, piece)) {
        LOG_ERROR("video cache: the clip could not be copied to \"%s\"", staging.c_str());
        return {};
    }

    // Published without replacing: a hard link fails when the name is taken, which is how an
    // entry another opener finished first is left alone.
    std::string result;
    if (::link(staging.c_str(), entry.c_str()) == 0) {
        result = entry.string();
    } else if (errno == EEXIST && IsWholeEntry(entry, bytes)) {
        result = entry.string();
    } else if (disk::exists(entry, failure)) {
        // Something unusable holds the name (a file of another size): it is replaced whole.
        if (::rename(staging.c_str(), entry.c_str()) == 0) result = entry.string();
    } else if (::rename(staging.c_str(), entry.c_str()) == 0) {
        // A folder that cannot hold links still takes a rename.
        result = entry.string();
    }
    std::error_code ignored;
    disk::remove(staging, ignored);
    if (result.empty()) LOG_ERROR("video cache: \"%s\" could not be published", entry.c_str());
    return result;
}

} // namespace wallpaper
