// Builders for the inputs of the texture parser tests: .tex containers with every header field
// switchable, tiny pictures made from first principles, .pkg archives and scratch folders.
#pragma once

#include <unistd.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <lz4.h>

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "WPTexImageParser.hpp"
#include "support/byte_fs.hpp"

namespace textest
{

using wallpaper::test::Bytes;
using Blob = std::vector<uint8_t>;

// ---- tiny pictures ---------------------------------------------------------------------------

inline uint32_t crc32(const uint8_t* p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) {
        c ^= p[i];
        for (int k = 0; k < 8; ++k) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
    }
    return ~c;
}

inline void bigEndian32(Blob& out, uint32_t v) {
    for (int s = 24; s >= 0; s -= 8) out.push_back(static_cast<uint8_t>(v >> s));
}

inline void pngChunk(Blob& out, const char* type, const Blob& data) {
    bigEndian32(out, static_cast<uint32_t>(data.size()));
    Blob body(type, type + 4);
    body.insert(body.end(), data.begin(), data.end());
    out.insert(out.end(), body.begin(), body.end());
    bigEndian32(out, crc32(body.data(), body.size()));
}

// A 1x1 RGBA PNG whose single pixel is (r, g, b, a).
inline Blob png1x1(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    Blob out { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    Blob header;
    bigEndian32(header, 1);
    bigEndian32(header, 1);
    for (uint8_t v : { 8, 6, 0, 0, 0 }) header.push_back(v);
    pngChunk(out, "IHDR", header);

    const Blob scanline { 0, r, g, b, a };
    uint32_t   s1 = 1, s2 = 0;
    for (uint8_t v : scanline) {
        s1 = (s1 + v) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    Blob z { 0x78, 0x01, 0x01, 0x05, 0x00, 0xFA, 0xFF };
    z.insert(z.end(), scanline.begin(), scanline.end());
    bigEndian32(z, (s2 << 16) | s1);
    pngChunk(out, "IDAT", z);
    pngChunk(out, "IEND", {});
    return out;
}

// A 1x1 24-bit BMP; it decodes to (r, g, b, 255).
inline Blob bmp1x1(uint8_t r, uint8_t g, uint8_t b) {
    Bytes f;
    f.raw({ 'B', 'M' }).u32(58).u32(0).u32(54);
    f.u32(40).i32(1).i32(1).u16(1).u16(24).u32(0).u32(4).i32(2835).i32(2835).u32(0).u32(0);
    f.u8(b).u8(g).u8(r).u8(0);
    return f.data();
}

// A 1x1 GIF whose two-colour table is c0, c1 and whose pixel is entry `pixel`.
inline Blob gif1x1(std::array<uint8_t, 3> c0, std::array<uint8_t, 3> c1, int pixel) {
    Bytes f;
    f.raw("GIF89a", 6).u16(1).u16(1).u8(0x80).u8(0).u8(0);
    for (uint8_t v : c0) f.u8(v);
    for (uint8_t v : c1) f.u8(v);
    f.u8(0x2C).u16(0).u16(0).u16(1).u16(1).u8(0);
    f.u8(2); // minimum code size
    // clear (4), the pixel, end (5): three 3-bit codes packed from the low bit up
    const uint32_t bits = 4u | (static_cast<uint32_t>(pixel) << 3) | (5u << 6);
    f.u8(2).u8(bits & 0xFF).u8(bits >> 8).u8(0);
    f.u8(0x3B);
    return f.data();
}

// Payloads that only look like something: never decoded, only recognised.
inline Blob jpegMarker() { return { 0xFF, 0xD8, 0xFF, 0xD9 }; }
inline Blob tiffMarker() { return { 0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00 }; }
inline Blob mp4Marker() {
    return { 0, 0, 0, 0x18, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm', 0, 0, 2, 0 };
}
inline Blob webmMarker() { return { 0x1A, 0x45, 0xDF, 0xA3, 0x42, 0x86, 0x81, 0x01 }; }

inline Blob lz4Block(const Blob& raw) {
    Blob out(static_cast<size_t>(LZ4_compressBound(static_cast<int>(raw.size()))));
    const int n = LZ4_compress_default(reinterpret_cast<const char*>(raw.data()),
                                       reinterpret_cast<char*>(out.data()),
                                       static_cast<int>(raw.size()), static_cast<int>(out.size()));
    out.resize(static_cast<size_t>(n));
    return out;
}

// ---- .tex containers -------------------------------------------------------------------------

struct LevelSpec {
    int                width { 1 }, height { 1 };
    Blob               bytes;
    bool               lz4 { false };
    std::optional<int> expanded; // declared expanded length; default: the stored bytes
    std::optional<int> stored;   // declared stored length; default: the bytes written
};

// Width x height RGBA pixels, every byte `mark`.
inline LevelSpec rawLevel(int w, int h, uint8_t mark) {
    LevelSpec l;
    l.width  = w;
    l.height = h;
    l.bytes.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, mark);
    return l;
}
inline LevelSpec levelOf(int w, int h, Blob bytes) {
    LevelSpec l;
    l.width  = w;
    l.height = h;
    l.bytes  = std::move(bytes);
    return l;
}
inline LevelSpec lz4Level(int w, int h, const Blob& raw) {
    LevelSpec l;
    l.width    = w;
    l.height   = h;
    l.lz4      = true;
    l.expanded = static_cast<int>(raw.size());
    l.bytes    = lz4Block(raw);
    return l;
}

struct PictureSpec {
    std::vector<LevelSpec> levels;
    std::optional<int>     declaredLevels; // replaces the level count field
};

struct SpriteRow {
    int                  picture { 0 };
    float                time { 0.1f };
    std::array<float, 6> a { 0, 0, 1, 0, 0, 1 };
};
struct SpriteTail {
    int                version { 2 };
    std::vector<SpriteRow> rows;
    std::optional<int> declaredRows;
};

constexpr uint32_t kPointSampling = 1, kClamp = 2, kSprite = 4, kVideo = 32;

struct Container {
    int      texb { 3 };
    uint32_t flags { 0 };
    int      width { 8 }, height { 8 }, mapWidth { 8 }, mapHeight { 8 };
    int      type { -1 };
    int      reserved { 0 };
    std::optional<int>      pictureCount;
    std::vector<PictureSpec> pictures;
    std::optional<SpriteTail> tail;
    Blob                    trailing;

    Container() = default;
    Container(int texbVersion, std::vector<LevelSpec> levels): texb(texbVersion) {
        pictures.push_back({ std::move(levels), std::nullopt });
    }
};

inline Blob build(const Container& c) {
    Bytes b;
    b.stamp("TEXV", 5).stamp("TEXI", 1);
    b.i32(0).u32(c.flags);
    b.i32(c.width).i32(c.height).i32(c.mapWidth).i32(c.mapHeight).i32(0);
    b.stamp("TEXB", c.texb);
    b.i32(c.pictureCount.value_or(static_cast<int>(c.pictures.size())));
    if (c.texb >= 3) b.i32(c.type);
    if (c.texb >= 4) b.i32(c.reserved);
    for (const auto& pic : c.pictures) {
        b.i32(pic.declaredLevels.value_or(static_cast<int>(pic.levels.size())));
        for (const auto& l : pic.levels) {
            b.i32(l.width).i32(l.height);
            if (c.texb >= 2) b.i32(l.lz4 ? 1 : 0).i32(l.expanded.value_or(static_cast<int>(l.bytes.size())));
            b.i32(l.stored.value_or(static_cast<int>(l.bytes.size())));
            b.raw(l.bytes);
        }
    }
    if (c.tail) {
        const auto& t = *c.tail;
        b.stamp("TEXS", t.version);
        b.i32(t.declaredRows.value_or(static_cast<int>(t.rows.size())));
        if (t.version == 3) b.i32(0).i32(0); // only version 3 carries a cell size
        for (const auto& row : t.rows) {
            b.i32(row.picture).f32(row.time);
            for (float v : row.a) {
                if (t.version == 1) b.i32(static_cast<int32_t>(v));
                else b.f32(v);
            }
        }
    }
    b.raw(c.trailing);
    return b.data();
}

// ---- file spaces and parsers -----------------------------------------------------------------

// A parser over an in-memory file space mounted at /assets.
struct Rig {
    std::unique_ptr<wallpaper::fs::VFS>           vfs;
    std::unique_ptr<wallpaper::WPTexImageParser>  parser;
    wallpaper::WPTexImageParser* operator->() { return parser.get(); }
};

inline Rig rigFor(wallpaper::test::MapFs::Files files) {
    Rig r;
    r.vfs = std::make_unique<wallpaper::fs::VFS>();
    r.vfs->Mount("/assets", std::make_unique<wallpaper::test::MapFs>(std::move(files)));
    r.parser = std::make_unique<wallpaper::WPTexImageParser>(r.vfs.get());
    return r;
}
// The container stored as the texture named "sample".
inline Rig rigForTex(const Blob& container) {
    return rigFor({ { "/materials/sample.tex", container } });
}

// A stream that remembers the biggest single read it was asked for.
class GuardStream final : public wallpaper::fs::MemBinaryStream {
public:
    GuardStream(Blob data, std::shared_ptr<size_t> biggest):
        MemBinaryStream(std::move(data)), m_biggest(std::move(biggest)) {}
    wallpaper::usize Read(void* buffer, wallpaper::usize size) override {
        *m_biggest = std::max<size_t>(*m_biggest, size);
        return MemBinaryStream::Read(buffer, size);
    }

private:
    std::shared_ptr<size_t> m_biggest;
};

class GuardFs final : public wallpaper::fs::Fs {
public:
    GuardFs(Blob data, std::shared_ptr<size_t> biggest):
        m_data(std::move(data)), m_biggest(std::move(biggest)) {}
    bool Contains(std::string_view path) const override { return path == "/materials/sample.tex"; }
    std::shared_ptr<wallpaper::fs::IBinaryStream> Open(std::string_view path) override {
        if (! Contains(path)) return nullptr;
        return std::make_shared<GuardStream>(m_data, m_biggest);
    }
    std::shared_ptr<wallpaper::fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    Blob                    m_data;
    std::shared_ptr<size_t> m_biggest;
};

struct GuardRig {
    std::unique_ptr<wallpaper::fs::VFS>          vfs;
    std::unique_ptr<wallpaper::WPTexImageParser> parser;
    std::shared_ptr<size_t>                      biggestRead = std::make_shared<size_t>(0);
};
inline GuardRig guardRigFor(const Blob& container) {
    GuardRig r;
    r.vfs = std::make_unique<wallpaper::fs::VFS>();
    r.vfs->Mount("/assets", std::make_unique<GuardFs>(container, r.biggestRead));
    r.parser = std::make_unique<wallpaper::WPTexImageParser>(r.vfs.get());
    return r;
}

// ---- host files ------------------------------------------------------------------------------

// A scratch folder under the system temp directory, named after the process, removed on exit.
class ScratchDir {
public:
    explicit ScratchDir(const std::string& tag) {
        static int counter = 0;
        m_path = std::filesystem::temp_directory_path() /
                 ("wm-" + tag + "-" + std::to_string(::getpid()) + "-" + std::to_string(counter++));
        std::filesystem::remove_all(m_path);
        std::filesystem::create_directories(m_path);
    }
    ~ScratchDir() {
        std::error_code ec;
        std::filesystem::remove_all(m_path, ec);
    }
    ScratchDir(const ScratchDir&)            = delete;
    ScratchDir& operator=(const ScratchDir&) = delete;

    const std::filesystem::path& path() const { return m_path; }
    std::string                  str(const std::string& name = "") const {
        return name.empty() ? m_path.string() : (m_path / name).string();
    }
    std::string write(const std::string& name, const Blob& data) const {
        const auto file = m_path / name;
        std::filesystem::create_directories(file.parent_path());
        std::ofstream out(file, std::ios::binary | std::ios::trunc);
        out.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
        return file.string();
    }
    std::string write(const std::string& name, const std::string& text) const {
        return write(name, Blob(text.begin(), text.end()));
    }

private:
    std::filesystem::path m_path;
};

struct PkgEntry {
    std::string name;
    std::string payload;
};

inline Blob pkgBytes(const std::vector<PkgEntry>& entries) {
    Bytes b;
    b.i32(8).raw("PKGV0001", 8).i32(static_cast<int>(entries.size()));
    int offset = 0;
    for (const auto& e : entries) {
        b.i32(static_cast<int>(e.name.size())).raw(e.name.data(), e.name.size());
        b.i32(offset).i32(static_cast<int>(e.payload.size()));
        offset += static_cast<int>(e.payload.size());
    }
    for (const auto& e : entries) b.raw(e.payload.data(), e.payload.size());
    return b.data();
}

} // namespace textest
