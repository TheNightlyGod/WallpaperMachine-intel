#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <limits>
#include <span>
#include <string>
#include <string_view>
#include <tuple>
#include <vector>

#include <unistd.h>

#include <gtest/gtest.h>
#include <lz4.h>

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "SceneSourceResolver.hpp"
#include "WPPkgFs.hpp"
#include "WPTexImageParser.hpp"
#include "Utils/Algorism.h"
#include "Scene/Parse/ImageOrientation.hpp"
#include "Runtime/RuntimeImageSource.hpp"

TEST(ImageOrientation, AllEightDisplayTransformsPreserveRGBA) {
    const std::vector<std::vector<int>> expected = {
        {1,2,3,4,5,6}, {3,2,1,6,5,4}, {6,5,4,3,2,1}, {4,5,6,1,2,3},
        {1,4,2,5,3,6}, {4,1,5,2,6,3}, {6,3,5,2,4,1}, {3,6,2,5,1,4}};
    for (int orientation = 1; orientation <= 8; ++orientation) {
        std::vector<uint8_t> pixels;
        for (int i = 1; i <= 6; ++i) pixels.insert(pixels.end(), {uint8_t(i), 17, 29, 131});
        int w = 3, h = 2;
        wallpaper::OrientRGBA(pixels.data(), w, h, orientation);
        EXPECT_EQ(w, orientation >= 5 ? 2 : 3);
        EXPECT_EQ(h, orientation >= 5 ? 3 : 2);
        for (int i = 0; i < 6; ++i) {
            EXPECT_EQ(pixels[i*4], expected[orientation-1][i]);
            EXPECT_EQ(pixels[i*4+1], 17);
            EXPECT_EQ(pixels[i*4+2], 29);
            EXPECT_EQ(pixels[i*4+3], 131);
        }
    }
}

TEST(ImageOrientation, ExifByteOrdersAndTruncation) {
    for (bool le : {false, true}) for (int orientation = 1; orientation <= 8; ++orientation) {
        std::vector<uint8_t> b = {0xff,0xd8,0xff,0xe1,0,34,'E','x','i','f',0,0};
        auto u16 = [&](unsigned v) {
            b.push_back(le ? v & 255 : v >> 8); b.push_back(le ? v >> 8 : v & 255);
        };
        auto u32 = [&](unsigned v) { if (le) {u16(v & 65535); u16(v >> 16);}
                                    else {u16(v >> 16); u16(v & 65535);} };
        b.push_back(le ? 'I' : 'M'); b.push_back(le ? 'I' : 'M');
        u16(42); u32(8); u16(1); u16(0x112); u16(3); u32(1); u16(orientation); u16(0); u32(0);
        EXPECT_EQ(wallpaper::JpegOrientation(b), orientation);
        for (size_t n = 0; n < b.size(); ++n)
            EXPECT_EQ(wallpaper::JpegOrientation(std::span(b).first(n)), 1);
        b[16] = b[17] = b[18] = b[19] = 255; // Invalid IFD offset.
        EXPECT_EQ(wallpaper::JpegOrientation(b), 1);
    }
}

namespace
{
using namespace wallpaper;

class MemoryFs final : public fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::vector<uint8_t>> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(it->second));
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::map<std::string, std::vector<uint8_t>> m_files;
};

class GuardedReadStream final : public fs::IBinaryStream {
public:
    GuardedReadStream(
        std::vector<uint8_t> data,
        usize max_read_size,
        std::shared_ptr<bool> oversized_read_seen)
        : m_data(std::move(data)),
          m_maxReadSize(max_read_size),
          m_oversizedReadSeen(std::move(oversized_read_seen))
    {}

    usize Read(void* buffer, usize sizeInByte) override {
        if (sizeInByte > m_maxReadSize) *m_oversizedReadSeen = true;
        const auto available = static_cast<usize>(std::max<idx>(0, Size() - m_pos));
        const auto to_read = std::min(sizeInByte, available);
        std::copy(m_data.begin() + m_pos, m_data.begin() + m_pos + static_cast<idx>(to_read),
                  static_cast<uint8_t*>(buffer));
        m_pos += static_cast<idx>(to_read);
        return to_read;
    }

    char* Gets(char* buffer, usize sizeStr) override {
        Read(buffer, sizeStr);
        return buffer;
    }

    idx Tell() const override { return m_pos; }

    bool SeekSet(idx offset) override {
        if (!InArea(offset)) return false;
        m_pos = offset;
        return true;
    }

    bool SeekCur(idx offset) override { return SeekSet(m_pos + offset); }
    bool SeekEnd(idx offset) override { return SeekSet(Size() + offset); }
    isize Size() const override { return static_cast<isize>(m_data.size()); }

protected:
    usize Write_impl(const void*, usize) override { return 0; }

private:
    bool InArea(idx pos) const { return pos >= 0 && pos <= Size(); }

    std::vector<uint8_t> m_data;
    idx m_pos { 0 };
    usize m_maxReadSize { 0 };
    std::shared_ptr<bool> m_oversizedReadSeen;
};

class GuardedMemoryFs final : public fs::Fs {
public:
    GuardedMemoryFs(
        std::vector<uint8_t> tex,
        usize max_read_size,
        std::shared_ptr<bool> oversized_read_seen)
        : m_tex(std::move(tex)),
          m_maxReadSize(max_read_size),
          m_oversizedReadSeen(std::move(oversized_read_seen))
    {}

    bool Contains(std::string_view path) const override {
        return path == "/materials/sample.tex";
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        if (!Contains(path)) return nullptr;
        return std::make_shared<GuardedReadStream>(
            std::vector<uint8_t>(m_tex),
            m_maxReadSize,
            m_oversizedReadSeen);
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::vector<uint8_t> m_tex;
    usize m_maxReadSize { 0 };
    std::shared_ptr<bool> m_oversizedReadSeen;
};

class Bytes {
public:
    void Stamp(char kind, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "TEX%c%04d", kind, version);
        Append(stamp, sizeof(stamp));
    }

    void I32(int32_t value) { Append(&value, sizeof(value)); }
    void U32(uint32_t value) { Append(&value, sizeof(value)); }
    void F32(float value) { Append(&value, sizeof(value)); }

    void Raw(std::span<const uint8_t> bytes) {
        m_bytes.insert(m_bytes.end(), bytes.begin(), bytes.end());
    }

    std::vector<uint8_t> Take() { return std::move(m_bytes); }

private:
    void Append(const void* data, std::size_t size) {
        const auto* p = static_cast<const uint8_t*>(data);
        m_bytes.insert(m_bytes.end(), p, p + size);
    }

    std::vector<uint8_t> m_bytes;
};

constexpr uint32_t kSpriteFlag = 1u << 2;
constexpr uint32_t kVideoFlag = 1u << 5;

std::vector<uint8_t> Png1x1() {
    return {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
        0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
        0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
}

std::vector<uint8_t> Bmp1x1() {
    return {
        0x42, 0x4d, 0x3a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00,
        0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00,
        0x00, 0x00, 0x13, 0x0b, 0x00, 0x00, 0x13, 0x0b, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
    };
}

std::vector<uint8_t> Gif1x1() {
    return {
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b,
    };
}

std::vector<uint8_t> JpegMarkerPayload() {
    return { 0xff, 0xd8, 0xff, 0xd9 };
}

std::vector<uint8_t> TiffMarkerPayload() {
    return { 'I', 'I', 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00 };
}

std::vector<uint8_t> Mp4MarkerPayload() {
    return {
        0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p',
        'i', 's', 'o', 'm', 0x00, 0x00, 0x02, 0x00,
    };
}

std::vector<uint8_t> WebmMarkerPayload() {
    return { 0x1a, 0x45, 0xdf, 0xa3, 0x42, 0x86, 0x81, 0x01 };
}

std::vector<uint8_t> BuildTex(
    int texb,
    int32_t image_type,
    int32_t reserved,
    std::span<const uint8_t> payload,
    uint32_t flags = 0,
    int32_t mip_count = 1)
{
    Bytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(0);
    b.U32(flags);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', texb);
    b.I32(1);
    if (texb >= 3) b.I32(image_type);
    if (texb >= 4) b.I32(reserved);
    b.I32(mip_count);
    if (mip_count > 0) {
        b.I32(1);
        b.I32(1);
        if (texb > 1) {
            b.I32(0);
            b.I32(0);
        }
        b.I32(static_cast<int32_t>(payload.size()));
        b.Raw(payload);
    }
    return b.Take();
}

std::vector<uint8_t> BuildTexWithDeclaredPayloadSize(int32_t src_size) {
    Bytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(0);
    b.U32(0);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', 3);
    b.I32(1);
    b.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.I32(0);
    b.I32(src_size);
    return b.Take();
}

std::vector<uint8_t> BuildCompressedUnknownTex(
    std::span<const uint8_t> decompressed_payload,
    uint32_t                 flags = 0)
{
    std::vector<uint8_t> compressed(static_cast<std::size_t>(
        LZ4_compressBound(static_cast<int>(decompressed_payload.size()))));
    const int compressed_size = LZ4_compress_default(
        reinterpret_cast<const char*>(decompressed_payload.data()),
        reinterpret_cast<char*>(compressed.data()),
        static_cast<int>(decompressed_payload.size()),
        static_cast<int>(compressed.size()));
    if (compressed_size <= 0) return {};
    compressed.resize(static_cast<std::size_t>(compressed_size));

    Bytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(0);
    b.U32(flags);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', 3);
    b.I32(1);
    b.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(static_cast<int32_t>(decompressed_payload.size()));
    b.I32(compressed_size);
    b.Raw(compressed);
    return b.Take();
}

std::vector<uint8_t> BuildSpriteWithInvalidFrames(bool empty_mips) {
    const std::vector<uint8_t> raw { 0xff, 0x00, 0x00, 0xff };
    Bytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(0);
    b.U32(kSpriteFlag);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', 2);
    b.I32(1);
    b.I32(empty_mips ? 0 : 1);
    if (!empty_mips) {
        b.I32(1);
        b.I32(1);
        b.I32(0);
        b.I32(0);
        b.I32(static_cast<int32_t>(raw.size()));
        b.Raw(raw);
    }
    b.Stamp('S', 2);
    b.I32(3);
    for (const int32_t image_id : { -1, 2, 0 }) {
        b.I32(image_id);
        b.F32(0.1f);
        b.F32(0.0f);
        b.F32(0.0f);
        b.F32(1.0f);
        b.F32(0.0f);
        b.F32(0.0f);
        b.F32(1.0f);
    }
    return b.Take();
}

WPTexImageParser MakeParser(fs::VFS& vfs, std::vector<uint8_t> tex) {
    auto files = std::map<std::string, std::vector<uint8_t>> {
        { "/materials/sample.tex", std::move(tex) },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    return WPTexImageParser(&vfs);
}

std::vector<uint8_t> BuildMipTex(uint32_t flags = 0, bool encoded = false,
                               bool truncated = false) {
    Bytes b;
    b.Stamp('V', 5); b.Stamp('I', 1);
    b.I32(0); b.U32(flags);
    for (int i = 0; i < 4; ++i) b.I32(8);
    b.I32(0); b.Stamp('B', encoded ? 3 : 2); b.I32(1);
    if (encoded) b.I32(static_cast<int32_t>(ImageType::PNG));
    b.I32(encoded ? 2 : 3);
    for (int size : encoded ? std::vector<int>{8, 1} : std::vector<int>{8, 4, 2}) {
        const auto payload = encoded && size == 1 ? Png1x1()
            : std::vector<uint8_t>(size * size * 4, uint8_t(size));
        b.I32(size); b.I32(size); b.I32(0); b.I32(0);
        b.I32(truncated ? 65536 : static_cast<int32_t>(payload.size()));
        b.Raw(payload);
    }
    return b.Take();
}

TEST(TexSchema, SurfaceBudgetSelectsAuthoredMipsAndKeepsLayoutMetadata) {
    fs::VFS vfs;
    RuntimeImageSource parser(std::make_unique<WPTexImageParser>(MakeParser(vfs, BuildMipTex())));
    for (const auto [surface, expected] : std::vector<std::pair<uint32_t, int>>{
             {0, 8}, {3, 4}, {5, 8}, {1, 2}, {0, 8}}) {
        parser.SetTextureSurfaceSize(surface, surface);
        auto image = parser.Parse("sample");
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.size(), 1u);
        const auto& slot = image->slots.front();
        ASSERT_FALSE(slot.mipmaps.empty());
        EXPECT_EQ(slot.width, expected);
        EXPECT_EQ(slot.height, expected);
        EXPECT_EQ(slot.mipmaps.front().size, expected * expected * 4);
        EXPECT_EQ(slot.mipmaps.front().data.get()[0], expected);
        EXPECT_EQ(image->header.width, 8);
        EXPECT_EQ(image->header.mapWidth, 8);
        EXPECT_EQ(parser.ParseHeader("sample").width, 8);
    }
}

TEST(TexSchema, SurfaceBudgetSkipsEncodedPixelsButRejectsTruncatedPayloads) {
    for (bool truncated : {false, true}) {
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildMipTex(0, true, truncated));
        parser.SetTextureSurfaceSize(1, 1);
        // The oversized level contains invalid PNG bytes. Success proves it
        // was skipped before decoding, not decoded and resized afterward.
        auto image = parser.Parse("sample");
        if (truncated) { EXPECT_EQ(image, nullptr); continue; }
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.front().mipmaps.size(), 1u);
        EXPECT_EQ(image->slots.front().width, 1);
        EXPECT_EQ(image->slots.front().mipmaps.front().data.get()[0], 255);
    }
}

TEST(TexSchema, SurfaceBudgetPreservesSpriteAndVideoMipChains) {
    for (uint32_t flag : {kSpriteFlag, kVideoFlag}) {
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildMipTex(flag));
        parser.SetTextureSurfaceSize(1, 1);
        auto image = parser.Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->slots.front().width, 8);
        EXPECT_EQ(image->slots.front().mipmaps.size(), 3u);
    }
}

// A mip chain of the given level sizes, level i filled with `marks[i]`. Raw
// RGBA levels, or, with `encoded`, the 1x1 PNG in every level under the header
// sizes (the decoder reports a level's real size, the header only decides which
// levels are kept).
std::vector<uint8_t> BuildChainTex(const std::vector<std::pair<int, int>>& levels,
                                   const std::vector<uint8_t>& marks, bool encoded = false) {
    Bytes b;
    b.Stamp('V', 5); b.Stamp('I', 1);
    b.I32(0); b.U32(0);
    for (int i = 0; i < 4; ++i) b.I32(8);
    b.I32(0); b.Stamp('B', encoded ? 3 : 2); b.I32(1);
    if (encoded) b.I32(static_cast<int32_t>(ImageType::PNG));
    b.I32(static_cast<int32_t>(levels.size()));
    for (size_t i = 0; i < levels.size(); ++i) {
        const auto payload = encoded ? Png1x1()
            : std::vector<uint8_t>(size_t(levels[i].first) * levels[i].second * 4, marks[i]);
        b.I32(levels[i].first); b.I32(levels[i].second); b.I32(0); b.I32(0);
        b.I32(static_cast<int32_t>(payload.size()));
        b.Raw(payload);
    }
    return b.Take();
}

TEST(TexSchema, SurfaceBudgetKeepsALevelThatTheNextOneWouldNotCover) {
    // 4100 px is just over the 4096 px power-of-two ceiling of a 3456 px
    // surface, yet the next level (2050 px) is far shorter than the surface:
    // dropping the full-size level would draw the picture magnified.
    fs::VFS vfs;
    auto parser = MakeParser(vfs, BuildChainTex({{4100, 64}, {2050, 32}}, {1, 2}));
    parser.SetTextureSurfaceSize(3456, 2024);
    auto image = parser.Parse("sample");
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.front().mipmaps.size(), 2u);
    EXPECT_EQ(image->slots.front().width, 4100);
    EXPECT_EQ(image->slots.front().mipmaps.front().data.get()[0], 1);
}

TEST(TexSchema, SurfaceBudgetKeepsTheSmallestLevelThatStillCoversTheSurface) {
    // For a texture of any longest side, landscape or portrait, the level that
    // is kept is as long as the surface (or as the texture, when that is
    // shorter), and the level after it is shorter than the surface, so nothing
    // is magnified and nothing larger than needed stays resident.
    for (const auto [sw, sh] : std::vector<std::pair<uint32_t, uint32_t>>{
             {1920, 1080}, {2560, 1440}, {3456, 2234}}) {
        const int surface = int(std::max(sw, sh));
        for (bool portrait : {false, true}) {
            for (int longest = surface / 2; longest <= 2 * surface + 2;
                 longest += std::max(1, surface / 16)) {
                std::vector<std::pair<int, int>> levels;
                std::vector<uint8_t> marks;
                for (int w = longest, h = 2; ; w /= 2, h = std::max(1, h / 2)) {
                    levels.push_back(portrait ? std::pair{h, w} : std::pair{w, h});
                    marks.push_back(uint8_t(levels.size()));
                    if (w == 1) break;
                }
                fs::VFS vfs;
                auto parser = MakeParser(vfs, BuildChainTex(levels, marks));
                parser.SetTextureSurfaceSize(sw, sh);
                auto image = parser.Parse("sample");
                ASSERT_NE(image, nullptr);
                const auto& mips = image->slots.front().mipmaps;
                ASSERT_FALSE(mips.empty());
                const auto side = [](const auto& m) { return std::max(m.width, m.height); };
                const std::string what = "texture " + std::to_string(longest) +
                    (portrait ? " tall" : " wide") + " on a " + std::to_string(sw) + "x" +
                    std::to_string(sh) + " surface";
                EXPECT_GE(side(mips.front()), std::min(longest, surface)) << what;
                // Only leading levels go: what is kept is the authored chain's tail.
                const size_t dropped = levels.size() - mips.size();
                EXPECT_EQ(mips.front().data.get()[0], marks[dropped]) << what;
                if (dropped + 1 < levels.size())
                    EXPECT_LT(std::max(levels[dropped + 1].first, levels[dropped + 1].second),
                              surface) << what;
            }
        }
    }
}

TEST(TexSchema, SurfaceBudgetFollowsTheHeaderSizesOfAnEncodedChain) {
    // The levels of a TEXB0003 container are measured by their headers, since
    // dropping one must not decode it first. A surface of 3456 needs the 4100
    // wide level because the next is only 2050 wide; a surface of 2000 is
    // covered by the 2050 wide one alone.
    for (const auto [surface, kept] : std::vector<std::pair<uint32_t, size_t>>{{3456, 2}, {2000, 1}}) {
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildChainTex({{4100, 4100}, {2050, 2050}}, {1, 2}, true));
        parser.SetTextureSurfaceSize(surface, surface);
        auto image = parser.Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->slots.front().mipmaps.size(), kept) << "surface " << surface;
    }
}

// A package may ship an ordinary picture next to its `.tex` files; those are
// the loose assets `ResolveLooseAsset` finds under the mount.
WPTexImageParser MakeParserWithLooseImage(fs::VFS& vfs, std::string path,
                                          std::vector<uint8_t> bytes) {
    auto files = std::map<std::string, std::vector<uint8_t>> {
        { std::move(path), std::move(bytes) },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
    return WPTexImageParser(&vfs);
}

struct PkgEntry {
    std::string path;
    std::string payload;
};

class TempPkg {
public:
    explicit TempPkg(std::vector<PkgEntry> entries) {
        // The process id keeps concurrent runs of this binary, which share the
        // temporary directory, from rewriting or deleting each other's files.
        const auto unique = "owe_pkg_case_test_" + std::to_string(::getpid()) + "_" +
                            std::to_string(s_nextId++) + ".pkg";
        m_path = std::filesystem::temp_directory_path() / unique;

        std::ofstream out(m_path, std::ios::binary | std::ios::trunc);
        auto write_i32 = [&](int32_t value) {
            out.write(reinterpret_cast<const char*>(&value), sizeof(value));
        };
        const std::string version = "PKGV0001";
        write_i32(static_cast<int32_t>(version.size()));
        out.write(version.data(), static_cast<std::streamsize>(version.size()));
        write_i32(static_cast<int32_t>(entries.size()));

        int32_t offset = 0;
        for (const auto& entry : entries) {
            write_i32(static_cast<int32_t>(entry.path.size()));
            out.write(entry.path.data(), static_cast<std::streamsize>(entry.path.size()));
            write_i32(offset);
            write_i32(static_cast<int32_t>(entry.payload.size()));
            offset += static_cast<int32_t>(entry.payload.size());
        }
        for (const auto& entry : entries) {
            out.write(entry.payload.data(), static_cast<std::streamsize>(entry.payload.size()));
        }
    }

    ~TempPkg() {
        if (!m_path.empty()) {
            std::error_code ec;
            std::filesystem::remove(m_path, ec);
        }
    }

    const std::filesystem::path& path() const { return m_path; }

private:
    std::filesystem::path m_path;
    inline static int s_nextId { 0 };
};

std::string ReadPkgFile(fs::WPPkgFs& pkg, std::string_view path) {
    auto stream = pkg.Open(path);
    if (!stream) return {};
    return stream->ReadAllStr();
}

} // namespace

TEST(TexSchema, TexbVersionsReadExpectedHeaderLayout) {
    for (const int texb : { 1, 2, 3, 4 }) {
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildTex(texb, static_cast<int32_t>(ImageType::PNG), 0, Png1x1()));
        const auto header = parser.ParseHeader("sample");
        EXPECT_EQ(header.extraHeader.at("texb").val, texb);
        EXPECT_EQ(header.count, 1);
        EXPECT_EQ(header.width, 1);
        EXPECT_EQ(header.height, 1);
        if (texb >= 3) EXPECT_EQ(header.type, ImageType::PNG);
        else EXPECT_EQ(header.type, ImageType::UNKNOWN);
    }
}

TEST(TexSchema, Texb4ReservedFieldDoesNotMarkVideoOrMisalignBody) {
    fs::VFS vfs;
    auto parser = MakeParser(
        vfs,
        BuildTex(4, static_cast<int32_t>(ImageType::PNG), 12345, Png1x1()));

    const auto header = parser.ParseHeader("sample");
    EXPECT_FALSE(header.isVideo);
    EXPECT_EQ(header.type, ImageType::PNG);
    EXPECT_EQ(header.mipmap_pow2, algorism::IsPowOfTwo(1u));

    const auto image = parser.Parse("sample");
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    EXPECT_EQ(image->slots[0].width, 1);
    EXPECT_EQ(image->slots[0].height, 1);
}

TEST(TexSchema, UnknownImageTypeUsesMagicByteFallbackForDecodableContainers) {
    for (const auto& [label, payload, expected] : {
             std::tuple { "png", Png1x1(), ImageType::PNG },
             std::tuple { "gif", Gif1x1(), ImageType::GIF },
             std::tuple { "bmp", Bmp1x1(), ImageType::BMP },
         }) {
        SCOPED_TRACE(label);
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildTex(3, static_cast<int32_t>(ImageType::UNKNOWN), 0, payload));
        const auto image = parser.Parse("sample");
        ASSERT_NE(image, nullptr);
        EXPECT_EQ(image->header.type, expected);
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
        EXPECT_EQ(image->slots[0].mipmaps[0].size, 4);
    }
}

TEST(TexSchema, UnknownImageTypeSniffsNonDecodedImageMarkersWithoutCrashing) {
    for (const auto& [label, payload, expected] : {
             std::tuple { "jpeg", JpegMarkerPayload(), ImageType::JPEG },
             std::tuple { "bmp", Bmp1x1(), ImageType::BMP },
             std::tuple { "tiff", TiffMarkerPayload(), ImageType::TIFF },
         }) {
        SCOPED_TRACE(label);
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildTex(3, static_cast<int32_t>(ImageType::UNKNOWN), 0, payload));
        const auto header = parser.ParseHeader("sample");
        EXPECT_EQ(header.type, expected);
    }
}

TEST(TexSchema, Mp4AndWebmFallbackMarksEmbeddedVideo) {
    for (const auto& [label, payload] : {
             std::tuple { "mp4", Mp4MarkerPayload() },
             std::tuple { "webm", WebmMarkerPayload() },
         }) {
        SCOPED_TRACE(label);
        fs::VFS vfs;
        auto parser = MakeParser(vfs, BuildTex(3, static_cast<int32_t>(ImageType::UNKNOWN), 0, payload));
        const auto header = parser.ParseHeader("sample");
        EXPECT_TRUE(header.isVideo);
        EXPECT_EQ(header.type, ImageType::UNKNOWN);
    }
}

TEST(TexSchema, SpriteFramesWithInvalidImageIdsAreSkipped) {
    fs::VFS vfs;
    auto parser = MakeParser(vfs, BuildSpriteWithInvalidFrames(false));

    const auto header = parser.ParseHeader("sample");
    EXPECT_TRUE(header.isSprite);
    ASSERT_EQ(header.spriteAnim.numFrames(), 1u);
    EXPECT_EQ(header.spriteAnim.GetCurFrame().imageId, 0);
}

TEST(TexSchema, SpriteFrameParsingGuardsEmptyMipSections) {
    fs::VFS vfs;
    auto parser = MakeParser(vfs, BuildSpriteWithInvalidFrames(true));

    const auto header = parser.ParseHeader("sample");
    EXPECT_TRUE(header.isSprite);
    EXPECT_EQ(header.spriteAnim.numFrames(), 0u);
}

TEST(TexSchema, NonSpriteHeaderGuardsEmptyMipSections) {
    fs::VFS vfs;
    auto parser = MakeParser(
        vfs,
        BuildTex(3, static_cast<int32_t>(ImageType::UNKNOWN), 0, {}, 0, 0));

    const auto header = parser.ParseHeader("sample");
    EXPECT_EQ(header.count, 1);
    EXPECT_FALSE(header.mipmap_pow2);
    EXPECT_FALSE(header.mipmap_larger);
    EXPECT_FALSE(header.isVideo);
}

TEST(TexSchema, HeaderSniffRejectsOversizedPayloadWithoutAllocating) {
    fs::VFS vfs;
    auto oversized_read_seen = std::make_shared<bool>(false);
    EXPECT_TRUE(vfs.Mount(
        "/assets",
        std::make_unique<GuardedMemoryFs>(
            BuildTexWithDeclaredPayloadSize(4096),
            64,
            oversized_read_seen)));
    WPTexImageParser parser(&vfs);

    ImageHeader header;
    ASSERT_NO_THROW(header = parser.ParseHeader("sample"));
    EXPECT_EQ(header.type, ImageType::UNKNOWN);
    EXPECT_FALSE(header.isVideo);
    EXPECT_FALSE(*oversized_read_seen);
}

TEST(TexSchema, HeaderSniffDoesNotDecompressCompressedPayloadPrefixes) {
    std::vector<uint8_t> decompressed(4096, 0);
    const auto marker = Mp4MarkerPayload();
    std::copy(marker.begin(), marker.end(), decompressed.begin());

    fs::VFS vfs;
    auto oversized_read_seen = std::make_shared<bool>(false);
    EXPECT_TRUE(vfs.Mount(
        "/assets",
        std::make_unique<GuardedMemoryFs>(
            BuildCompressedUnknownTex(decompressed),
            64,
            oversized_read_seen)));
    WPTexImageParser parser(&vfs);

    ImageHeader header;
    ASSERT_NO_THROW(header = parser.ParseHeader("sample"));
    EXPECT_EQ(header.type, ImageType::UNKNOWN);
    EXPECT_FALSE(header.isVideo);
    EXPECT_FALSE(*oversized_read_seen);
}

TEST(TexSchema, FlaggedVideoUnknownTypeUsesExistingMetadataPath) {
    std::vector<uint8_t> decompressed(4096);
    for (std::size_t i = 0; i < decompressed.size(); ++i) {
        decompressed[i] = static_cast<uint8_t>((i * 37u + i / 3u) & 0xffu);
    }
    const auto marker = Mp4MarkerPayload();
    std::copy(marker.begin(), marker.end(), decompressed.begin());

    fs::VFS vfs;
    auto oversized_read_seen = std::make_shared<bool>(false);
    EXPECT_TRUE(vfs.Mount(
        "/assets",
        std::make_unique<GuardedMemoryFs>(
            BuildCompressedUnknownTex(decompressed, kVideoFlag),
            64,
            oversized_read_seen)));
    WPTexImageParser parser(&vfs);

    ImageHeader header;
    ASSERT_NO_THROW(header = parser.ParseHeader("sample"));
    EXPECT_TRUE(header.isVideo);
    EXPECT_TRUE(*oversized_read_seen);
}

// A `scenetexture` property the user filled from the image picker holds an
// absolute path to a picture of their own, which belongs to no VFS mount.
TEST(TexSchema, AbsolutePathLoadsTheUsersOwnPicture) {
    const auto directory = std::filesystem::temp_directory_path() /
                           ("wpe-host-asset-test-" + std::to_string(::getpid()));
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory);
    const auto picture = directory / "chosen.png";
    {
        const auto bytes = Png1x1();
        std::ofstream file { picture, std::ios::binary };
        file.write(reinterpret_cast<const char*>(bytes.data()),
                   static_cast<std::streamsize>(bytes.size()));
    }

    fs::VFS vfs;
    auto parser = MakeParser(vfs, BuildTex(1, static_cast<int32_t>(ImageType::PNG), 0, Png1x1()));

    const auto header = parser.ParseHeader(picture.string());
    EXPECT_EQ(header.width, 1);
    EXPECT_EQ(header.height, 1);
    EXPECT_FALSE(header.isVideo);

    const auto image = parser.Parse(picture.string());
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    EXPECT_EQ(image->slots[0].width, 1);

    std::filesystem::remove_all(directory);
}

TEST(TexSchema, AbsolutePathToNothingStaysUnresolved) {
    fs::VFS vfs;
    auto parser = MakeParser(vfs, BuildTex(1, static_cast<int32_t>(ImageType::PNG), 0, Png1x1()));

    const auto missing =
        (std::filesystem::temp_directory_path() / "wpe-host-asset-absent.png").string();
    EXPECT_EQ(parser.Parse(missing), nullptr);
    // A packaged name still resolves through the mount it always used.
    EXPECT_NE(parser.Parse("sample"), nullptr);
}

// The regression the absolute-path branch invites: a mounted loose asset's
// resolved path is `/assets/...`, which is absolute too. Deciding where to read
// from by looking at the string sends every packaged PNG, JPG and video to the
// host filesystem, where none of them exist.
TEST(TexSchema, PackagedLooseImageStillLoadsFromTheMount) {
    for (const auto& [label, mounted, name] : {
             std::tuple { "materials", "/materials/backdrop.png", "backdrop.png" },
             std::tuple { "assets root", "/pictures/backdrop.png", "pictures/backdrop.png" },
             std::tuple { "extension guessed", "/materials/guessed.png", "guessed" },
         }) {
        SCOPED_TRACE(label);
        fs::VFS vfs;
        auto    parser = MakeParserWithLooseImage(vfs, mounted, Png1x1());

        const auto header = parser.ParseHeader(name);
        EXPECT_EQ(header.width, 1);
        EXPECT_EQ(header.height, 1);
        EXPECT_EQ(header.type, ImageType::PNG);

        const auto image = parser.Parse(name);
        ASSERT_NE(image, nullptr);
        ASSERT_EQ(image->slots.size(), 1u);
        EXPECT_EQ(image->slots[0].width, 1);
        EXPECT_EQ(image->slots[0].height, 1);
    }
}

TEST(TexSchema, PackagedLooseBmpDecodesItsPixels) {
    fs::VFS vfs;
    auto parser = MakeParserWithLooseImage(vfs, "/materials/backdrop.bmp", Bmp1x1());
    const auto image = parser.Parse("backdrop.bmp");
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    const auto& pixels = image->slots[0].mipmaps[0];
    ASSERT_EQ(pixels.size, 4);
    ASSERT_NE(pixels.data, nullptr);
    EXPECT_EQ(pixels.data.get()[0], 0u);
    EXPECT_EQ(pixels.data.get()[1], 0u);
    EXPECT_EQ(pixels.data.get()[2], 255u);
    EXPECT_EQ(pixels.data.get()[3], 255u);
}

// The property stores the path, not a copy of the file. A directory, a path
// with no picture behind it, and a relative one are all "not a picture we can
// read", which is what decides whether a slot may be replaced at all.
TEST(TexSchema, OnlyAReadableHostPictureCountsAsOne) {
    const auto directory = std::filesystem::temp_directory_path() /
                           ("wpe-host-asset-readable-" + std::to_string(::getpid()));
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory);
    const auto picture = directory / "chosen.png";
    {
        const auto bytes = Png1x1();
        std::ofstream file { picture, std::ios::binary };
        file.write(reinterpret_cast<const char*>(bytes.data()),
                   static_cast<std::streamsize>(bytes.size()));
    }

    EXPECT_TRUE(HostLooseAssetIsReadable(picture.string()));
    EXPECT_FALSE(HostLooseAssetIsReadable((directory / "gone.png").string()));
    EXPECT_FALSE(HostLooseAssetIsReadable(directory.string()));
    EXPECT_FALSE(HostLooseAssetIsReadable("materials/packaged"));
    EXPECT_FALSE(HostLooseAssetIsReadable(""));

    std::filesystem::remove_all(directory);
}

TEST(PkgFs, ContainsAndOpenResolvePackagePathsCaseInsensitively) {
    TempPkg pkg_file({ { "Materials/Foo.TEX", "payload" } });
    auto pkg = fs::WPPkgFs::CreatePkgFs(pkg_file.path().string());
    ASSERT_NE(pkg, nullptr);

    EXPECT_TRUE(pkg->Contains("/materials/foo.tex"));
    EXPECT_TRUE(pkg->Contains("/MATERIALS/FOO.TEX"));

    auto stream = pkg->Open("/materials/foo.tex");
    ASSERT_NE(stream, nullptr);
    EXPECT_EQ(stream->ReadAllStr(), "payload");
}

TEST(PkgFs, ExactPathWinsWhenPackageContainsCaseFoldCollision) {
    TempPkg pkg_file({
        { "Materials/Foo.TEX", "upper" },
        { "materials/foo.tex", "lower" },
    });
    auto pkg = fs::WPPkgFs::CreatePkgFs(pkg_file.path().string());
    ASSERT_NE(pkg, nullptr);

    EXPECT_EQ(ReadPkgFile(*pkg, "/Materials/Foo.TEX"), "upper");
    EXPECT_EQ(ReadPkgFile(*pkg, "/materials/foo.tex"), "lower");
    EXPECT_TRUE(pkg->Contains("/MATERIALS/FOO.TEX"));
}

// A Workshop preset is installed as its base's folder with the preset's own
// files on top: the base's `scene.pkg`, and beside it the pictures and videos the
// preset's `scenetexture` properties name, e.g. `files/clip.mp4`. Only the
// package was mounted, so those resolved to nothing and the layers drew black.
TEST(SceneSourceMount, APresetFileBesideThePackageLoadsAndThePackageStillWins) {
    const auto directory = std::filesystem::temp_directory_path() /
                           ("wpe-scene-source-mount-" + std::to_string(::getpid()));
    std::filesystem::remove_all(directory);
    std::filesystem::create_directories(directory / "files");
    {
        TempPkg pkg_file({ { "scene.json", "packaged" } });
        std::filesystem::copy_file(pkg_file.path(), directory / "scene.pkg");
    }
    const auto write = [](const std::filesystem::path& path, std::span<const uint8_t> bytes) {
        std::ofstream file { path, std::ios::binary };
        file.write(reinterpret_cast<const char*>(bytes.data()),
                   static_cast<std::streamsize>(bytes.size()));
    };
    const std::string loose_scene = "loose";
    write(directory / "scene.json",
          std::span(reinterpret_cast<const uint8_t*>(loose_scene.data()), loose_scene.size()));
    write(directory / "files" / "picked.png", Png1x1());

    SceneSourcePaths paths;
    std::string      error;
    ASSERT_TRUE(ResolveSceneSourcePaths((directory / "scene.json").string(), &paths, &error)) << error;
    fs::VFS vfs;
    ASSERT_TRUE(MountSceneSource(vfs, paths, &error)) << error;

    EXPECT_EQ(fs::GetFileContent(vfs, "/assets/scene.json"), "packaged");
    WPTexImageParser parser(&vfs);
    const auto image = parser.Parse("files/picked.png");
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    EXPECT_EQ(image->slots[0].width, 1);

    // A folder without a package is the scene on its own.
    std::filesystem::remove(directory / "scene.pkg");
    fs::VFS loose_vfs;
    ASSERT_TRUE(MountSceneSource(loose_vfs, paths, &error)) << error;
    EXPECT_EQ(fs::GetFileContent(loose_vfs, "/assets/scene.json"), "loose");

    std::filesystem::remove_all(directory);
}
