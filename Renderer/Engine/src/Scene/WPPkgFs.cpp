// Clean-room implementation from the WallpaperMachine spec p6-textures-packages.md; written without access to the original source.
#include "WPPkgFs.hpp"
#include "Utils/Logging.h"
#include "Fs/LimitedBinaryStream.h"
#include "Fs/CBinaryStream.h"

using namespace wallpaper;
using namespace wallpaper::fs;

namespace
{
// Smallest table row: name length, offset and length with an empty name.
constexpr std::int64_t kMinRow = 12;

std::string FoldAscii(std::string_view text) {
    std::string out(text);
    for (char& c : out)
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    return out;
}

// Reads the fixed-width numbers of the header, checking each against what is left.
class Cursor {
public:
    explicit Cursor(IBinaryStream& in) : m_in(in), m_size(in.Size()) {}
    std::int64_t Left() const { return m_size - m_in.Tell(); }
    std::int64_t Tell() const { return m_in.Tell(); }
    bool         Int32(std::int32_t& out) {
        if (Left() < 4) return false;
        out = m_in.ReadInt32();
        return true;
    }
    bool Bytes(std::string& out, std::int64_t n) {
        if (n < 0 || n > Left()) return false;
        out.resize(static_cast<std::size_t>(n));
        return n == 0 || m_in.Read(out.data(), out.size()) == out.size();
    }

private:
    IBinaryStream& m_in;
    std::int64_t   m_size;
};
} // namespace

std::unique_ptr<WPPkgFs> WPPkgFs::CreatePkgFs(std::string_view pkgpath) {
    const auto file = CreateCBinaryStream(pkgpath);
    if (! file) return nullptr;
    const auto reject = [&](const char* why) -> std::unique_ptr<WPPkgFs> {
        LOG_ERROR("package \"%.*s\" rejected: %s", (int)pkgpath.size(), pkgpath.data(), why);
        return nullptr;
    };

    Cursor       in(*file);
    std::int32_t versionLength = 0;
    std::string  version;
    if (! in.Int32(versionLength) || versionLength < 1 || versionLength > 64)
        return reject("bad version text length");
    if (! in.Bytes(version, versionLength)) return reject("truncated version text");
    LOG_INFO("package \"%.*s\": %s", (int)pkgpath.size(), pkgpath.data(), version.c_str());

    std::int32_t count = 0;
    if (! in.Int32(count)) return reject("truncated header");
    // Nothing is sized from the count before the table could actually hold it.
    if (count < 0 || static_cast<std::int64_t>(count) * kMinRow > in.Left())
        return reject("entry count does not fit the file");

    struct Row {
        std::string  name;
        std::int32_t offset { 0 };
        std::int32_t length { 0 };
    };
    std::vector<Row> rows;
    rows.reserve(static_cast<std::size_t>(count));
    for (std::int32_t i = 0; i < count; ++i) {
        Row          row;
        std::int32_t nameLength = 0;
        if (! in.Int32(nameLength) || nameLength < 0 || ! in.Bytes(row.name, nameLength) ||
            ! in.Int32(row.offset) || ! in.Int32(row.length))
            return reject("the entry table is cut short");
        rows.push_back(std::move(row));
    }

    const std::int64_t dataStart = in.Tell();
    const std::int64_t fileSize  = file->Size();

    std::unique_ptr<WPPkgFs> pkg(new WPPkgFs());
    pkg->m_path = std::string(pkgpath);
    for (const Row& row : rows) {
        const std::int64_t begin = dataStart + static_cast<std::int64_t>(row.offset);
        if (row.name.empty() || row.offset < 0 || row.length < 0 ||
            begin + static_cast<std::int64_t>(row.length) > fileSize) {
            LOG_ERROR("package entry \"%s\" lies outside the file, skipped", row.name.c_str());
            continue;
        }
        const std::size_t index = pkg->m_entries.size();
        pkg->m_entries.push_back(Entry { begin, row.length });
        // The first entry of a name wins, for exact and folded lookups alike.
        pkg->m_exact.emplace(row.name, index);
        pkg->m_folded.emplace(FoldAscii(row.name), index);
    }
    return pkg;
}

long WPPkgFs::Find(std::string_view path) const {
    if (path.size() < 2 || path.front() != '/') return -1;
    const std::string name(path.substr(1));
    if (const auto it = m_exact.find(name); it != m_exact.end()) return static_cast<long>(it->second);
    if (const auto it = m_folded.find(FoldAscii(name)); it != m_folded.end())
        return static_cast<long>(it->second);
    return -1;
}

bool WPPkgFs::Contains(std::string_view path) const { return Find(path) >= 0; }

std::shared_ptr<IBinaryStream> WPPkgFs::Open(std::string_view path) {
    const long found = Find(path);
    if (found < 0) return nullptr;
    const Entry& entry = m_entries[static_cast<std::size_t>(found)];
    // A handle of its own per entry: opens are independent and thread-safe.
    auto source = CreateCBinaryStream(m_path);
    if (! source) return nullptr;
    return std::make_shared<LimitedBinaryStream>(std::move(source), entry.begin, entry.size);
}

std::shared_ptr<IBinaryStreamW> WPPkgFs::OpenW(std::string_view) { return nullptr; }
