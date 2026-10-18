#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
#include <limits>
#include <memory>
#include <span>
#include <string>
#include <vector>
#include <cstring>

#include <gtest/gtest.h>

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Scene/SceneMesh.h"
#include "Utils/Logging.h"
#include "WPMdlParser.hpp"

namespace
{
using namespace wallpaper;

class MemoryFs final : public fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::vector<uint8_t>> files)
        : m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(it->second));
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::map<std::string, std::vector<uint8_t>> m_files;
};

class Bytes {
public:
    void Stamp(std::string_view prefix, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "%.4s%.4d", prefix.data(), version);
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(stamp), sizeof(stamp)));
    }
    void Str(std::string_view value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(value.data()), value.size()));
        U8(0);
    }
    void U8(uint8_t value) { RawValue(value); }
    void U16(uint16_t value) { RawValue(value); }
    void U32(uint32_t value) { RawValue(value); }
    void I32(int32_t value) { RawValue(value); }
    void F32(float value) { RawValue(value); }
    std::size_t Size() const { return m_bytes.size(); }
    void Raw(std::span<const uint8_t> bytes) {
        m_bytes.insert(m_bytes.end(), bytes.begin(), bytes.end());
    }
    void PatchU32(std::size_t offset, uint32_t value) {
        ASSERT_LE(offset + sizeof(value), m_bytes.size());
        std::memcpy(m_bytes.data() + offset, &value, sizeof(value));
    }

    std::vector<uint8_t> Take() { return std::move(m_bytes); }

private:
    template<typename T>
    void RawValue(const T& value) {
        Raw(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(&value), sizeof(value)));
    }

    std::vector<uint8_t> m_bytes;
};

struct CapturedLog {
    int         level { LOGLEVEL_INFO };
    std::string message;
};

std::vector<CapturedLog>* g_captured_logs = nullptr;

void CaptureWallpaperLog(int level, const char*, int, const char* message) {
    if (! g_captured_logs) return;
    g_captured_logs->push_back({ level, message });
}

class ScopedLogCapture {
public:
    ScopedLogCapture() {
        g_captured_logs = &m_logs;
        SetWallpaperLogCallback(CaptureWallpaperLog);
    }

    ~ScopedLogCapture() {
        SetWallpaperLogCallback(nullptr);
        g_captured_logs = nullptr;
    }

    bool Contains(int level, std::string_view needle) const {
        for (const auto& log : m_logs) {
            if (log.level == level && log.message.find(needle) != std::string::npos) {
                return true;
            }
        }
        return false;
    }

private:
    std::vector<CapturedLog> m_logs;
};

void ExpectDrawsNothing(const std::vector<SceneMesh::DrawRange>& ranges) {
    ASSERT_EQ(ranges.size(), 1u);
    EXPECT_EQ(ranges[0].indexOffset, 0u);
    EXPECT_EQ(ranges[0].indexCount, 0u);
}

constexpr uint32_t kSkinUvFlag = 0x00800000u | 0x01000000u | 0x00000008u;
constexpr uint32_t kSkinUv2OnlyFlag = 0x00800000u | 0x01000000u | 0x00000020u;

void WriteVertex(Bytes& b, float x, float y, float u, uint32_t bone = 0) {
    b.F32(x);
    b.F32(y);
    b.F32(0.0f);
    b.U32(bone);
    b.U32(0);
    b.U32(0);
    b.U32(0);
    b.F32(1.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(u);
    b.F32(0.5f);
}

void WriteVertexWithUv2(Bytes& b, float x, float y, float u, float u2, uint32_t bone = 0) {
    b.F32(x);
    b.F32(y);
    b.F32(0.0f);
    b.U32(bone);
    b.U32(0);
    b.U32(0);
    b.U32(0);
    b.F32(1.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(u);
    b.F32(0.5f);
    b.F32(u2);
    b.F32(0.75f);
}

void WriteMesh(Bytes& b, std::string_view material, uint32_t part_id) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUvFlag);
    b.U32(3u * 52u);
    WriteVertex(b, 0.0f, 0.0f, 0.0f);
    WriteVertex(b, 1.0f, 0.0f, 0.5f);
    WriteVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(36);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(0.25f * static_cast<float>(i));
        b.F32(0.5f);
        b.U32(0);
    }
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(0);
    b.U32(3);
}

void WriteMeshWithPartRange(Bytes& b, std::string_view material, uint32_t part_id,
                            uint32_t part_start, uint32_t part_size) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUvFlag);
    b.U32(3u * 52u);
    WriteVertex(b, 0.0f, 0.0f, 0.0f);
    WriteVertex(b, 1.0f, 0.0f, 0.5f);
    WriteVertex(b, 0.0f, 1.0f, 1.0f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(36);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(0.25f * static_cast<float>(i));
        b.F32(0.5f);
        b.U32(0);
    }
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(part_start);
    b.U32(part_size);
}

void WriteUv2OnlyMesh(Bytes& b, std::string_view material, uint32_t part_id) {
    b.Str(material);
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUv2OnlyFlag);
    b.U32(3u * 60u);
    WriteVertexWithUv2(b, 0.0f, 0.0f, 0.0f, 0.25f);
    WriteVertexWithUv2(b, 1.0f, 0.0f, 0.5f, 0.50f);
    WriteVertexWithUv2(b, 0.0f, 1.0f, 1.0f, 0.75f);
    b.U32(6);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    b.U8(0);
    b.U8(1);
    b.U32(16);
    b.U32(part_id);
    b.U32(0);
    b.U32(0);
    b.U32(3);
}

void WriteIdentity3x4(Bytes& b) {
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            b.F32(row == col ? 1.0f : 0.0f);
        }
    }
}

void WriteTranslate3x4(Bytes& b, float x, float y, float z) {
    for (int col = 0; col < 4; ++col) {
        for (int row = 0; row < 4; ++row) {
            float value = row == col ? 1.0f : 0.0f;
            if (col == 3 && row == 0) value = x;
            if (col == 3 && row == 1) value = y;
            if (col == 3 && row == 2) value = z;
            b.F32(value);
        }
    }
}

std::vector<uint8_t> BuildMdlv21TwoMeshFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(2);
    WriteMesh(b, "mat/head.json", 10);
    WriteMesh(b, "mat/eyes.json", 20);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(4);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.Str("first_child");
    b.I32(0);
    b.U32(0);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.Str("second_child");
    b.I32(0);
    b.U32(0);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.Str("grandchild");
    b.I32(0);
    b.U32(1);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21MeshOnlyFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21InvalidPartRangeFixture(uint32_t part_start,
                                                        uint32_t part_size) {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMeshWithPartRange(b, "mat/head.json", 10, part_start, part_size);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv23MaskedMeshOnlyFixture() {
    Bytes b;
    b.Stamp("MDL", 23);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);
    b.U32(1);
    b.U32(7);
    b.U32(0);
    b.Str("mat/iris_mask.json");
    b.U32(0);
    b.U32(1);
    b.U32(0);
    b.U32(1);
    b.U32(0);
    return b.Take();
}

// One triangle naming vertex 65536. The index blob is 12 bytes, which is also
// divisible by 6, so a uint16 reader would report two triangles and could not
// name that vertex at all.
std::vector<uint8_t> BuildMdlv23WideIndexMeshFixture() {
    constexpr uint32_t kVertexCount = 65537u;
    Bytes b;
    b.Stamp("MDL", 23);
    b.U32(0);
    b.U32(1);
    b.U32(1);
    b.Str("mat/body.json");
    b.U32(0);
    for (int i = 0; i < 6; ++i) b.F32(i == 0 || i == 3 ? -1.0f : 1.0f);
    b.U32(0);
    b.U32(kVertexCount * 12u);
    for (uint32_t i = 0; i < kVertexCount; ++i) {
        b.F32(static_cast<float>(i));
        b.F32(0.0f);
        b.F32(0.0f);
    }
    b.U32(12);
    b.U32(0);
    b.U32(1);
    b.U32(kVertexCount - 1);
    b.U8(0);
    b.U8(0);
    b.U32(0);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv23IncompleteFlagMeshOnlyFixture() {
    Bytes b;
    b.Stamp("MDL", 23);
    b.I32(9);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);
    b.U32(0);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv23MaskedMeshWithInvalidPartIdsFixture() {
    Bytes b;
    b.Stamp("MDL", 23);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);
    b.U32(1);
    b.U32(7);
    b.U32(0);
    b.Str("mat/iris_mask.json");
    b.U32(0);
    b.U32(1);
    b.U32(99);
    b.U32(1);
    b.U32(100);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv23TruncatedMaskFixture() {
    auto bytes = BuildMdlv23MaskedMeshOnlyFixture();
    bytes.resize(bytes.size() - sizeof(uint32_t));
    return bytes;
}

std::vector<uint8_t> BuildMdlv21Uv2OnlyMeshFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUv2OnlyFlag);
    b.U32(1);
    b.U32(1);
    WriteUv2OnlyMesh(b, "mat/uv2.json", 10);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21ForwardParentFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(2);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.Str("fixture_forward_parent");
    b.I32(0);
    b.U32(99);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21TranslatedBonesFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(3);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteTranslate3x4(b, 10.0f, 0.0f, 0.0f);
    b.Str("{}");
    b.Str("first_child");
    b.I32(0);
    b.U32(0);
    b.U32(64);
    WriteTranslate3x4(b, 3.0f, 0.0f, 0.0f);
    b.Str("{}");
    b.Str("grandchild");
    b.I32(0);
    b.U32(1);
    b.U32(64);
    WriteTranslate3x4(b, 2.0f, 0.0f, 0.0f);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv23ParentChainFixture(int version = 23) {
    Bytes b;
    b.Stamp("MDL", version);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);
    if (version > 21) b.U32(0);

    b.Stamp("MDLS", 3);
    const auto mdls_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(3);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteTranslate3x4(b, 10.0f, 0.0f, 0.0f);
    b.Str("{}");
    b.Str("first_child");
    b.I32(0);
    b.U32(0);
    b.U32(64);
    WriteTranslate3x4(b, 3.0f, 0.0f, 0.0f);
    b.Str("{}");
    b.Str("grandchild");
    b.I32(0);
    b.U32(1);
    b.U32(64);
    WriteTranslate3x4(b, 2.0f, 0.0f, 0.0f);
    b.Str("{}");
    b.U16(0);
    b.U8(0);
    b.U8(0);
    b.U8(0);
    b.PatchU32(mdls_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21Mdls3IkAndMdatFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 3);
    const auto mdls_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.U16(2);
    b.U8(0);
    b.U32(0);
    b.U32(0);
    b.U8(0);
    b.U8(0);
    b.U8(0x7f);
    b.U8(0x7e);
    b.U8(0x7d);
    b.PatchU32(mdls_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDAT", 1);
    const auto mdat_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("hat_anchor");
    WriteTranslate3x4(b, 4.0f, 5.0f, 6.0f);
    b.PatchU32(mdat_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 0);
    b.U8(0);
    return b.Take();
}

void WriteOneBoneFrame(Bytes& b, float x) {
    b.F32(x);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(1.0f);
}

void WriteAnimBoneCurves(Bytes& b, uint32_t bone_count, bool enabled) {
    b.U8(enabled ? 1 : 0);
    if (! enabled) return;
    for (uint32_t i = 0; i < bone_count; ++i) {
        b.U32(0);
        b.U32(8);
        b.F32(static_cast<float>(i));
        b.F32(static_cast<float>(i) + 0.5f);
    }
}

void WriteMdla6Animation(Bytes& b, int32_t id, std::string_view name,
                         bool invalid_scalar_curve = false, uint32_t event_count = 1) {
    constexpr uint32_t kBoneCount = 1;

    b.I32(id);
    b.U32(0);
    b.Str(name);
    b.Str("loop");
    b.F32(30.0f);
    b.I32(1);
    b.I32(0);

    b.U32(kBoneCount);
    b.I32(0);
    b.U32(36);
    WriteOneBoneFrame(b, static_cast<float>(id));

    b.U32(1);
    b.U32(8);
    b.F32(0.0f);
    b.F32(1.0f);
    b.U32(0);
    b.U32(8);
    b.F32(0.25f);
    b.F32(0.75f);
    b.U32(0);

    WriteAnimBoneCurves(b, kBoneCount, true);

    b.U8(1);
    b.U32(1);
    b.F32(0.5f);
    b.U32(0);
    b.U32(8);
    b.F32(2.0f);
    b.F32(3.0f);

    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);

    if (invalid_scalar_curve) {
        b.U8(1);
        b.U32(0);
        b.U32(6);
        b.F32(1.0f);
        b.U16(0);
    } else {
        WriteAnimBoneCurves(b, kBoneCount, true);
    }

    b.U32(event_count);
    if (event_count > 0) {
        b.U32(12);
        b.Str(R"({"name":"fixture_event"})");
    }
}

std::vector<uint8_t> BuildMdlv21Mdls3Mdla6AnimationsFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 3);
    const auto mdls_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.U16(0);
    b.U8(0);
    b.U8(0);
    b.U8(0);
    b.PatchU32(mdls_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 6);
    const auto mdla_end_offset_pos = b.Size();
    b.U32(0);
    b.U32(2);
    WriteMdla6Animation(b, 101, "intro");
    WriteMdla6Animation(b, 202, "idle");
    b.PatchU32(mdla_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21Mdls3Mdla6InvalidAnimationFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 3);
    const auto mdls_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.U16(0);
    b.U8(0);
    b.U8(0);
    b.U8(0);
    b.PatchU32(mdls_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 6);
    const auto mdla_end_offset_pos = b.Size();
    b.U32(0);
    b.U32(1);
    WriteMdla6Animation(b, 303, "bad_scalar", true);
    b.PatchU32(mdla_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21Mdls3Mdla6HugeAnimCountFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 3);
    const auto mdls_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.U16(0);
    b.U8(0);
    b.U8(0);
    b.U8(0);
    b.PatchU32(mdls_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 6);
    const auto mdla_end_offset_pos = b.Size();
    b.U32(0);
    b.U32(100000);
    b.PatchU32(mdla_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21MdleAfterInvalidMdlaPayloadFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(2);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.Str("child");
    b.I32(0);
    b.U32(0);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 6);
    const auto mdla_end_offset_pos = b.Size();
    b.U32(0);
    b.U32(100000);
    b.U32(0xAABBCCDDu);
    b.U32(0x11223344u);
    b.PatchU32(mdla_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLE", 1);
    const auto mdle_end_offset_pos = b.Size();
    b.U32(0);
    b.U32(2u * 64u);
    WriteTranslate3x4(b, 2.0f, 3.0f, 4.0f);
    WriteTranslate3x4(b, 5.0f, 6.0f, 7.0f);
    b.PatchU32(mdle_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21Mdls3Mdla6HugeBoneTrackCountFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 3);
    const auto mdls_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.U16(0);
    b.U8(0);
    b.U8(0);
    b.U8(0);
    b.PatchU32(mdls_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 6);
    const auto mdla_end_offset_pos = b.Size();
    b.U32(0);
    b.U32(1);
    b.I32(404);
    b.U32(0);
    b.Str("bad_bone_tracks");
    b.Str("loop");
    b.F32(30.0f);
    b.I32(1);
    b.I32(0);
    b.U32(100000);
    b.PatchU32(mdla_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21Mdls3Mdla6HugeEventCountFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 3);
    const auto mdls_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.U16(0);
    b.U8(0);
    b.U8(0);
    b.U8(0);
    b.PatchU32(mdls_end_offset_pos, static_cast<uint32_t>(b.Size()));

    b.Stamp("MDLA", 6);
    const auto mdla_end_offset_pos = b.Size();
    b.U32(0);
    b.U32(1);
    WriteMdla6Animation(b, 505, "huge_event_count", false, 100000);
    b.PatchU32(mdla_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21MdleAfterMdlaFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(2);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");
    b.Str("child");
    b.I32(0);
    b.U32(0);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);
    b.U8(0);

    b.Stamp("MDLE", 1);
    const auto mdle_end_offset_pos = b.Size();
    b.U32(0);
    b.U32(2u * 64u);
    WriteTranslate3x4(b, 2.0f, 3.0f, 4.0f);
    WriteTranslate3x4(b, 5.0f, 6.0f, 7.0f);
    b.PatchU32(mdle_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21MdleWithNonzeroTrailingBodyByteFixture() {
    auto bytes = BuildMdlv21MdleAfterMdlaFixture();
    bytes.push_back(0x7F);
    return bytes;
}

std::vector<uint8_t> BuildMdlv21MdmpAfterMdlaFixture(bool zero_shape_trailer) {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDLA", 0);
    b.U8(0);

    b.Stamp("MDMP", 1);
    const auto mdmp_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.F32(12.5f);
    b.U16(42);
    b.U16(0);
    b.U32(zero_shape_trailer ? 0u : 9u);
    b.U32(0);
    b.Str("fixture_morph");
    b.U32(6);
    b.U32(0x12345678u);
    b.U16(0);
    b.U16(1);
    b.U16(2);
    if (zero_shape_trailer) {
        b.U8(0xA0);
        b.U8(0xA1);
        b.U8(0xA2);
        b.U8(0xA3);
        b.U8(0xA4);
        b.U8(0xA5);
    } else {
        b.U16(0xBEEF);
    }
    b.PatchU32(mdmp_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21WithTruncatedMdatEndOffset() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDAT", 1);
    b.U32(999999);
    b.U16(0);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21WithTruncatedMdatAttachmentName() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDAT", 1);
    const auto mdat_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Raw(std::span<const uint8_t>(
        reinterpret_cast<const uint8_t*>("unterminated"), std::string_view("unterminated").size()));
    b.PatchU32(mdat_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21WithTruncatedMdatTransform() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/head.json", 10);

    b.Stamp("MDLS", 1);
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(0xFFFFFFFFu);
    b.U32(64);
    WriteIdentity3x4(b);
    b.Str("{}");

    b.Stamp("MDAT", 1);
    const auto mdat_end_offset_pos = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("hat_anchor");
    b.F32(1.0f);
    b.PatchU32(mdat_end_offset_pos, static_cast<uint32_t>(b.Size()));
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21WithMeshCount(uint32_t mesh_count) {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(mesh_count);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21IncompleteFlagFixture() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.I32(9);
    return b.Take();
}

std::vector<uint8_t> BuildVersionedMeshFixture(int version, bool skinned,
                                            bool surface_attributes = true) {
    const uint32_t flag = (surface_attributes ? 0x0000000Fu : 0x00000008u) |
                          (skinned ? kSkinUvFlag : 0u);
    Bytes b;
    b.Stamp("MDL", version);
    b.U32(flag);
    b.U32(1);
    b.U32(1);
    b.Str("mat/surface.json");
    b.U32(0);
    if (version >= 17) {
        for (float value : { -1.0f, -1.0f, -1.0f, 3.0f, 3.0f, 3.0f }) b.F32(value);
    }
    if (version > 14) b.U32(flag);
    const uint32_t stride = 20u + (surface_attributes ? 28u : 0u) + (skinned ? 32u : 0u);
    b.U32(3u * stride);
    for (uint32_t i = 0; i < 3; ++i) {
        b.F32(static_cast<float>(i) + 0.25f);
        b.F32(static_cast<float>(i) * 2.0f - 1.0f);
        b.F32(3.0f - static_cast<float>(i));
        if (surface_attributes) {
            for (float value : { 0.0f, 1.0f, 0.0f }) b.F32(value);
            for (float value : { -1.0f, 0.0f, 0.0f, -1.0f }) b.F32(value);
        }
        if (skinned) {
            for (uint32_t value : { 1u, 0u, 0u, 0u }) b.U32(value);
            for (float value : { 0.25f, 0.75f, 0.0f, 0.0f }) b.F32(value);
        }
        b.F32(static_cast<float>(i) * 0.125f);
        b.F32(0.75f - static_cast<float>(i) * 0.125f);
    }
    b.U32(6);
    b.U16(0);
    b.U16(2);
    b.U16(1);
    if (version >= 21) {
        b.U8(0);
        b.U8(0);
        if (version > 21) b.U32(0);
    }
    if (skinned) {
        b.Stamp("MDLS", 1);
        b.U32(0);
        b.U16(2);
        b.U16(0);
        for (uint32_t i = 0; i < 2; ++i) {
            b.Str(i == 0 ? "root" : "child");
            b.I32(0);
            b.U32(i == 0 ? WPPuppet::NO_PARENT : 0u);
            b.U32(64);
            WriteIdentity3x4(b);
            b.Str("{}");
        }
        b.Stamp("MDLA", 0);
    }
    b.U8(0);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21WithTruncatedVertexPayload() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    b.Str("mat/head.json");
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUvFlag);
    b.U32(52);
    b.F32(0.0f);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21WithTruncatedPartsPayload() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    b.Str("mat/head.json");
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUvFlag);
    b.U32(52);
    WriteVertex(b, 0.0f, 0.0f, 0.0f);
    b.U32(0);
    b.U8(1);
    b.U8(1);
    b.U16(0);
    b.U8(0);
    b.U32(12);
    b.F32(0.25f);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21WithInvalidPartsBytes() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    b.Str("mat/head.json");
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUvFlag);
    b.U32(52);
    WriteVertex(b, 0.0f, 0.0f, 0.0f);
    b.U32(0);
    b.U8(0);
    b.U8(1);
    b.U32(15);
    return b.Take();
}

std::vector<uint8_t> BuildMdlv21WithUnsupportedPartsExtras() {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    b.Str("mat/head.json");
    b.U32(0);
    b.F32(-1.0f);
    b.F32(-1.0f);
    b.F32(0.0f);
    b.F32(1.0f);
    b.F32(1.0f);
    b.F32(0.0f);
    b.U32(kSkinUvFlag);
    b.U32(52);
    WriteVertex(b, 0.0f, 0.0f, 0.0f);
    b.U32(0);
    b.U8(2);
    return b.Take();
}

void MountMdlFixture(fs::VFS& vfs, std::vector<uint8_t> bytes) {
    auto files = std::map<std::string, std::vector<uint8_t>> {
        { "/sample.mdl", std::move(bytes) },
    };
    EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

std::shared_ptr<WPPuppet> BuildOneBonePuppet(WPPuppet::PlayMode mode,
                                             float first_frame_y,
                                             float final_frame_y) {
    auto puppet = std::make_shared<WPPuppet>();

    auto& bone = puppet->bones.emplace_back();
    bone.name = "root";

    auto& anim = puppet->anims.emplace_back();
    anim.id = 1;
    anim.fps = 1.0;
    anim.length = 1;
    anim.mode = mode;
    anim.name = "fixture";

    auto& track = anim.bone_tracks.emplace_back();
    track.bone_index = 0;
    auto& first_frame = track.frames.emplace_back();
    first_frame.position = Eigen::Vector3f(0.0f, first_frame_y, 0.0f);
    first_frame.angle = Eigen::Vector3f::Zero();
    first_frame.scale = Eigen::Vector3f::Ones();
    auto& final_frame = track.frames.emplace_back();
    final_frame.position = Eigen::Vector3f(0.0f, final_frame_y, 0.0f);
    final_frame.angle = Eigen::Vector3f::Zero();
    final_frame.scale = Eigen::Vector3f::Ones();

    puppet->prepared();
    return puppet;
}

WPPuppetLayer BuildAdditiveLayer(const std::shared_ptr<WPPuppet>& puppet) {
    WPPuppetLayer layer(puppet);
    WPPuppetLayer::AnimationLayer anim_layer;
    anim_layer.id = 1;
    anim_layer.additive = true;
    layer.prepared(std::span<WPPuppetLayer::AnimationLayer>(&anim_layer, 1));
    return layer;
}

float RootTranslationY(WPPuppetLayer& layer, double time) {
    const auto bones = layer.genFrame(time);
    EXPECT_EQ(bones.size(), 1u);
    return bones[0].translation().y();
}

} // namespace

TEST(MdlSchema, AdditiveSingleAnimationPreservesAuthoredPoseAndHolds) {
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Single, 440.0f, 0.0f);
    auto layer = BuildAdditiveLayer(puppet);

    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.0), 440.0f);
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 220.0f);
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 1.0), 0.0f);
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 10.0), 0.0f);
}

TEST(MdlSchema, AdditiveLoopPreservesInitialCollapsedPoseAndWraps) {
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Loop, 12.0f, 16.0f);
    auto& frames = puppet->anims[0].bone_tracks[0].frames;
    for (auto& frame : frames) frame.angle.z() = std::acos(-1.0f) / 2.0f;
    frames[0].scale.y() = 0.0f;
    puppet->prepared();
    auto layer = BuildAdditiveLayer(puppet);
    const Eigen::Vector3f vertex(2, 3, 0);

    const Eigen::Vector3f initial = layer.genFrame(0)[0] * vertex;
    EXPECT_NEAR(initial.x(), 0, 1e-5);
    EXPECT_NEAR(initial.y(), 14, 1e-5);
    const Eigen::Vector3f halfway = layer.genFrame(0.5)[0] * vertex;
    EXPECT_NEAR(halfway.x(), -1.5, 1e-5);
    EXPECT_NEAR(halfway.y(), 16, 1e-5);
    EXPECT_TRUE((layer.genFrame(1)[0] * vertex).isApprox(initial, 1e-5));
}

TEST(MdlSchema, CharacterSheetReferencePoseSurvivesAdditiveMixingAndLoopWrap) {
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Loop, 12.0f, 16.0f);
    auto& bone = puppet->bones[0];
    bone.local_bind.translate(Eigen::Vector3f(0, 100, 0));
    bone.local_reference.translate(Eigen::Vector3f(0, 10, 0));
    bone.has_local_reference = true;
    puppet->prepared();
    WPPuppetLayer still(puppet);
    still.prepared({});
    const Eigen::Vector3f vertex(0, 103, 0);
    EXPECT_NEAR((still.genFrame(0)[0] * vertex).y(), 13, 1e-5);
    auto layer = BuildAdditiveLayer(puppet);
    EXPECT_NEAR((layer.genFrame(0)[0] * vertex).y(), 15, 1e-5);
    EXPECT_NEAR((layer.genFrame(0.5)[0] * vertex).y(), 17, 1e-5);
    EXPECT_NEAR((layer.genFrame(1)[0] * vertex).y(), 15, 1e-5);
    EXPECT_NEAR((layer.genFrame(1)[0] * vertex).y(), 15, 1e-5);
    WPPuppetLayer::AnimationLayer a;
    a.id = 1;
    a.additive = true;
    a.blend = 0.5;
    std::array layers { a, a };
    WPPuppetLayer mixed(puppet);
    mixed.prepared(layers);
    EXPECT_NEAR((mixed.genFrame(0)[0] * vertex).y(), 15, 1e-5);
}

TEST(MdlSchema, NonAdditiveLayersShareTheWholePoseWeight) {
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Loop, 12.0f, 16.0f);
    auto& bone = puppet->bones[0];
    bone.local_bind.translate(Eigen::Vector3f(0, 100, 0));
    bone.local_reference.translate(Eigen::Vector3f(0, 10, 0));
    bone.has_local_reference = true;
    for (auto& frame : puppet->anims[0].bone_tracks[0].frames) {
        frame.angle.z() = 0.6f;
        frame.scale = Eigen::Vector3f(2, 3, 1);
    }
    puppet->prepared();
    const Eigen::Vector3f vertex(2, 103, 0);
    struct Case { double first, second, weight; };
    for (const auto weights : { Case { 1, 1, 1 }, Case { 2, 1, 1 },
                               Case { 0.5, 0.5, 0.75 }, Case { 0.25, 0.5, 0.625 },
                               Case { 0, 1, 1 }, Case { 1, 0, 1 }, Case { 0, 0, 0 } }) {
        SCOPED_TRACE(::testing::Message() << weights.first << ", " << weights.second);
        WPPuppetLayer::AnimationLayer a;
        a.id = 1;
        a.blend = weights.first;
        auto b = a;
        b.blend = weights.second;
        std::array settings { a, b };
        WPPuppetLayer layer(puppet);
        layer.prepared(settings);
        for (const double time : { 0.0, 0.5, 1.0, 1.0 }) {
            const float w = static_cast<float>(weights.weight);
            const float delta_y = time == 0.5 ? 4.0f : 2.0f;
            Eigen::Affine3f expected = Eigen::Affine3f::Identity();
            expected.translate(Eigen::Vector3f(0, 10 + w * delta_y, 0));
            expected.rotate(Eigen::AngleAxisf(0.6f * w, Eigen::Vector3f::UnitZ()));
            expected.scale(Eigen::Vector3f(1 + w, 1 + 2 * w, 1));
            EXPECT_TRUE((layer.genFrame(time)[0] * vertex).isApprox(
                expected * Eigen::Vector3f(2, 3, 0), 1e-5));
        }
    }
}

TEST(MdlSchema, NonAdditivePoseMixRetainsDistinctMotionAndAdditiveOffsets) {
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Single, 20, 40);
    auto other = puppet->anims[0];
    other.id = 2;
    for (auto& frame : other.bone_tracks[0].frames) frame.position.y() += 40;
    puppet->anims.push_back(other);
    puppet->prepared();
    WPPuppetLayer::AnimationLayer a;
    a.id = 1;
    auto b = a;
    b.id = 2;
    b.blend = 3;
    auto additive = a;
    additive.additive = true;
    additive.blend = 0.5;
    std::array settings { a, b, additive };
    WPPuppetLayer layer(puppet);
    layer.prepared(settings);
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0), 60); // 20/4 + 60*3/4 + 20/2
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 75);
    ASSERT_TRUE(layer.setVisible(1, false));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 45);
    ASSERT_TRUE(layer.setVisible(1, true));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 75);
    ASSERT_TRUE(layer.setBlend(1, 1));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 65);
}

TEST(MdlSchema, FullWeightAnimationReplacesRotatedReferencePose) {
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Loop, 0.0f, 0.0f);
    auto& bone = puppet->bones[0];
    const float quarter_turn = std::acos(-1.0f) / 2.0f;
    bone.local_bind.rotate(Eigen::AngleAxisf(quarter_turn, Eigen::Vector3f::UnitX()));
    for (auto& frame : puppet->anims[0].bone_tracks[0].frames) {
        frame.angle.z() = quarter_turn;
    }
    puppet->prepared();
    auto layer = BuildAdditiveLayer(puppet);
    const Eigen::Vector3f bind_vertex = bone.local_bind * Eigen::Vector3f(1, 2, 3);
    const Eigen::Vector3f result = layer.genFrame(0)[0] * bind_vertex;
    EXPECT_TRUE(result.isApprox(Eigen::Vector3f(-2, 1, 3), 1e-5));
}

TEST(MdlSchema, Mdls2ReferencePoseReassemblesBindVerticesWithoutAnimation) {
    Bytes b;
    b.Stamp("MDL", 21);
    b.U32(kSkinUvFlag);
    b.U32(1);
    b.U32(1);
    WriteMesh(b, "mat/body.json", 10);
    b.Stamp("MDLS", 2);
    const auto end = b.Size();
    b.U32(0);
    b.U16(1);
    b.U16(0);
    b.Str("root");
    b.I32(0);
    b.U32(WPPuppet::NO_PARENT);
    b.U32(64);
    WriteTranslate3x4(b, 100, 200, 0);
    b.Str("{}");
    b.U16(0);
    b.U8(1);
    WriteTranslate3x4(b, 10, 20, 0);
    for (int i = 0; i < 10; ++i) b.U8(0);
    b.PatchU32(end, static_cast<uint32_t>(b.Size()));
    b.Stamp("MDLA", 0);
    b.U8(0);
    fs::VFS vfs;
    MountMdlFixture(vfs, b.Take());
    WPMdl mdl;
    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    WPPuppetLayer layer(mdl.puppet);
    layer.prepared({});
    const Eigen::Vector3f result = layer.genFrame(0)[0] * Eigen::Vector3f(103, 204, 0);
    EXPECT_NEAR(result.x(), 13, 1e-5);
    EXPECT_NEAR(result.y(), 24, 1e-5);
}

TEST(MdlSchema, ParsesMdlv21PartsBeforeMdlsAndMultipleMeshes) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21TwoMeshFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    EXPECT_EQ(mdl.mdlv, 21);
    EXPECT_EQ(mdl.mdl_header.mesh_count, 2u);
    ASSERT_EQ(mdl.meshes.size(), 2u);
    EXPECT_EQ(mdl.meshes[0].mat_json_file, "mat/head.json");
    EXPECT_EQ(mdl.meshes[1].mat_json_file, "mat/eyes.json");
    ASSERT_EQ(mdl.meshes[0].part_uv2.size(), 3u);
    ASSERT_EQ(mdl.meshes[0].parts.size(), 1u);
    EXPECT_EQ(mdl.meshes[0].parts[0].id, 10u);
    EXPECT_EQ(mdl.meshes[1].parts[0].id, 20u);
}

TEST(MdlSchema, VersionedSurfaceMeshesPreserveAllVertexAttributes) {
    for (const int version : { 13, 14, 16, 17, 20, 21, 23 }) {
        SCOPED_TRACE(version);
        fs::VFS vfs;
        MountMdlFixture(vfs, BuildVersionedMeshFixture(version, false));
        WPMdl mdl;
        ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
        ASSERT_EQ(mdl.meshes.size(), 1u);
        const auto& src = mdl.meshes[0];
        ASSERT_EQ(src.positions.size(), 3u);
        ASSERT_EQ(src.normals.size(), 3u);
        ASSERT_EQ(src.tangents.size(), 3u);
        ASSERT_EQ(src.texcoords.size(), 3u);
        EXPECT_TRUE(src.blend_indices.empty());
        EXPECT_TRUE(src.blend_weights.empty());
        EXPECT_EQ(mdl.puppet, nullptr);
        for (uint32_t i = 0; i < 3; ++i) {
            EXPECT_EQ(src.positions[i], (std::array<float, 3> {
                static_cast<float>(i) + 0.25f,
                static_cast<float>(i) * 2.0f - 1.0f,
                3.0f - static_cast<float>(i) }));
            EXPECT_EQ(src.normals[i], (std::array<float, 3> { 0.0f, 1.0f, 0.0f }));
            EXPECT_EQ(src.tangents[i], (std::array<float, 4> { -1.0f, 0.0f, 0.0f, -1.0f }));
            EXPECT_EQ(src.texcoords[i], (std::array<float, 2> {
                static_cast<float>(i) * 0.125f, 0.75f - static_cast<float>(i) * 0.125f }));
        }
        EXPECT_EQ(src.indices, (std::vector<std::array<uint32_t, 3>> { { 0u, 2u, 1u } }));
        EXPECT_EQ(src.has_aabb, version >= 17);

        SceneMesh mesh;
        WPMdlParser::GenPuppetMesh(mesh, mdl, false);
        ASSERT_EQ(mesh.Submeshes().size(), 1u);
        const auto& vertex = mesh.Submeshes()[0].GetVertexArray(0);
        EXPECT_EQ(vertex.VertexCount(), 3u);
        const auto offsets = vertex.GetAttrOffsetMap();
        for (const auto& [name, expected] : std::map<std::string, std::vector<float>> {
                 { "a_Position", { 0.25f, -1.0f, 3.0f } },
                 { "a_Normal", { 0.0f, 1.0f, 0.0f } },
                 { "a_Tangent4", { -1.0f, 0.0f, 0.0f, -1.0f } },
                 { "a_TexCoord", { 0.0f, 0.75f } } }) {
            const auto attribute = offsets.find(name);
            ASSERT_NE(attribute, offsets.end()) << name;
            std::vector<float> packed(expected.size());
            std::memcpy(packed.data(),
                        reinterpret_cast<const uint8_t*>(vertex.Data()) + attribute->second.offset,
                        packed.size() * sizeof(float));
            EXPECT_EQ(packed, expected) << name;
        }
        EXPECT_EQ(offsets.find("a_BlendIndices"), offsets.end());
        const auto& indices = mesh.Submeshes()[0].GetIndexArray(0);
        EXPECT_EQ(indices.DrawIndexCount(), 3u);
        std::array<uint16_t, 3> packed_indices {};
        std::memcpy(packed_indices.data(), indices.Data(), sizeof(packed_indices));
        EXPECT_EQ(packed_indices, (std::array<uint16_t, 3> { 0u, 2u, 1u }));
    }
}

TEST(MdlSchema, VersionedSkinnedMeshesPreserveBoneIndicesWeightsAndSkeleton) {
    for (const int version : { 13, 14, 16, 17, 20, 21, 23 }) {
        for (const bool surface_attributes : { false, true }) {
            SCOPED_TRACE(version);
            SCOPED_TRACE(surface_attributes);
            fs::VFS vfs;
            MountMdlFixture(vfs, BuildVersionedMeshFixture(version, true, surface_attributes));
            WPMdl mdl;
            ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
            ASSERT_EQ(mdl.meshes.size(), 1u);
            const auto& src = mdl.meshes[0];
            ASSERT_EQ(src.positions.size(), 3u);
            ASSERT_EQ(src.texcoords.size(), 3u);
            ASSERT_EQ(src.blend_indices.size(), 3u);
            ASSERT_EQ(src.blend_weights.size(), 3u);
            for (uint32_t i = 0; i < 3; ++i) {
                EXPECT_EQ(src.positions[i], (std::array<float, 3> {
                    static_cast<float>(i) + 0.25f,
                    static_cast<float>(i) * 2.0f - 1.0f,
                    3.0f - static_cast<float>(i) }));
                EXPECT_EQ(src.texcoords[i], (std::array<float, 2> {
                    static_cast<float>(i) * 0.125f, 0.75f - static_cast<float>(i) * 0.125f }));
                EXPECT_EQ(src.blend_indices[i], (std::array<uint32_t, 4> { 1u, 0u, 0u, 0u }));
                EXPECT_EQ(src.blend_weights[i], (std::array<float, 4> { 0.25f, 0.75f, 0.0f, 0.0f }));
            }
            EXPECT_EQ(src.normals.size(), surface_attributes ? 3u : 0u);
            EXPECT_EQ(src.tangents.size(), surface_attributes ? 3u : 0u);
            ASSERT_NE(mdl.puppet, nullptr);
            ASSERT_EQ(mdl.puppet->bones.size(), 2u);
            EXPECT_EQ(mdl.puppet->bones[0].name, "root");
            EXPECT_EQ(mdl.puppet->bones[1].name, "child");
            EXPECT_EQ(mdl.puppet->bones[1].parent, 0u);
        }
    }
}

TEST(MdlSchema, RejectsTruncatedMdlv16SurfaceVertexPayload) {
    auto bytes = BuildVersionedMeshFixture(16, false);
    bytes.resize(bytes.size() - 40u);
    fs::VFS vfs;
    MountMdlFixture(vfs, std::move(bytes));
    WPMdl mdl;
    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

TEST(MdlSchema, ParsesMdlv21MeshDataWithoutOptionalMdlsBlock) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21MeshOnlyFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    EXPECT_EQ(mdl.mdlv, 21);
    EXPECT_EQ(mdl.mdl_header.mesh_count, 1u);
    ASSERT_EQ(mdl.meshes.size(), 1u);
    EXPECT_EQ(mdl.meshes[0].mat_json_file, "mat/head.json");
    ASSERT_EQ(mdl.meshes[0].positions.size(), 3u);
    ASSERT_EQ(mdl.meshes[0].parts.size(), 1u);
    EXPECT_EQ(mdl.meshes[0].parts[0].id, 10u);
    EXPECT_EQ(mdl.puppet, nullptr);
}

TEST(MdlSchema, WideMeshesKeepThirtyTwoBitIndices) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv23WideIndexMeshFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_EQ(mdl.meshes.size(), 1u);
    EXPECT_EQ(mdl.meshes[0].positions.size(), 65537u);
    ASSERT_EQ(mdl.meshes[0].indices.size(), 1u);
    EXPECT_EQ(mdl.meshes[0].indices[0][0], 0u);
    EXPECT_EQ(mdl.meshes[0].indices[0][1], 1u);
    EXPECT_EQ(mdl.meshes[0].indices[0][2], 65536u);

    SceneMesh mesh;
    WPMdlParser::GenPuppetMesh(mesh, mdl, false);
    ASSERT_EQ(mesh.Submeshes().size(), 1u);
    ASSERT_EQ(mesh.Submeshes()[0].IndexCount(), 1u);
    const auto& indices = mesh.GetIndexArray(0);
    EXPECT_EQ(indices.Width(), SceneIndexWidth::UInt32);
    EXPECT_EQ(indices.DrawIndexCount(), 3u);
    EXPECT_EQ(indices.Data()[2], 65536u);
}

TEST(MdlSchema, ParsesMdlv23MaskBlocksWithoutDesynchronizingFollowingSections) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv23MaskedMeshOnlyFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_EQ(mdl.meshes.size(), 1u);
    ASSERT_EQ(mdl.meshes[0].masks.size(), 1u);
    EXPECT_EQ(mdl.meshes[0].masks[0].leading_a, 7u);
    EXPECT_EQ(mdl.meshes[0].masks[0].mat_json_file, "mat/iris_mask.json");
    EXPECT_EQ(mdl.meshes[0].masks[0].part_ids_a, std::vector<uint32_t>({ 0u }));
    EXPECT_EQ(mdl.meshes[0].masks[0].part_ids_b, std::vector<uint32_t>({ 0u }));
    EXPECT_EQ(mdl.puppet, nullptr);
}

TEST(MdlSchema, Uv2OnlyLayoutStillProvidesPrimaryAndSecondaryUvs) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21Uv2OnlyMeshFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_EQ(mdl.meshes.size(), 1u);
    ASSERT_EQ(mdl.meshes[0].texcoords.size(), 3u);
    ASSERT_EQ(mdl.meshes[0].texcoord2.size(), 3u);
    EXPECT_FLOAT_EQ(mdl.meshes[0].texcoords[1][0], 0.5f);
    EXPECT_FLOAT_EQ(mdl.meshes[0].texcoord2[1][0], 0.5f);
}

TEST(MdlSchema, GenMeshIncludesNormals) {
    WPMdl::Mesh src;
    src.positions = { { 0.0f, 0.0f, 0.0f }, { 1.0f, 0.0f, 0.0f }, { 0.0f, 1.0f, 0.0f } };
    src.normals   = { { 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f } };
    src.tangents  = { { 1.0f, 0.0f, 0.0f, 1.0f },
                      { 1.0f, 0.0f, 0.0f, 1.0f },
                      { 1.0f, 0.0f, 0.0f, 1.0f } };
    src.texcoords = { { 0.0f, 0.0f }, { 1.0f, 0.0f }, { 0.0f, 1.0f } };
    src.indices   = { { 0, 1, 2 } };

    SceneMesh::Submesh submesh;
    WPMdlParser::GenMeshFromMdl(submesh, src);
    ASSERT_EQ(submesh.VertexCount(), 1u);
    const auto& attributes = submesh.GetVertexArray(0).Attributes();
    bool        has_normal  = false;
    bool        has_tangent = false;
    for (const auto& attribute : attributes) {
        if (attribute.name == "a_Normal") has_normal = true;
        // The name Wallpaper Engine's model shaders declare for it
        // (`attribute vec4 a_Tangent4`); a mesh that names it otherwise leaves
        // the shader's input unbound.
        if (attribute.name == "a_Tangent4") has_tangent = true;
    }
    EXPECT_TRUE(has_normal);
    EXPECT_TRUE(has_tangent);
}

TEST(MdlSchema, GeneratesOneSubmeshPerMdlv21Mesh) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21TwoMeshFixture());
    WPMdl mdl;
    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));

    SceneMesh mesh;
    WPMdlParser::GenPuppetMesh(mesh, mdl);

    ASSERT_EQ(mesh.Submeshes().size(), 2u);
    EXPECT_EQ(mesh.Submeshes()[0].VertexCount(), 1u);
    EXPECT_EQ(mesh.Submeshes()[0].IndexCount(), 1u);
    EXPECT_EQ(mesh.Submeshes()[1].VertexCount(), 1u);
    EXPECT_EQ(mesh.Submeshes()[1].IndexCount(), 1u);

    EXPECT_EQ(mesh.VertexCount(), 1u);
    EXPECT_EQ(mesh.IndexCount(), 1u);
    EXPECT_EQ(mesh.GetVertexArray(0).VertexCount(), 3u);
    EXPECT_EQ(mesh.GetIndexArray(0).DataCount(), 2u);
    std::array<uint16_t, 3> packed_indices {};
    std::memcpy(
        packed_indices.data(),
        mesh.GetIndexArray(0).Data(),
        sizeof(packed_indices));
    EXPECT_EQ(packed_indices[0], 0u);
    EXPECT_EQ(packed_indices[1], 1u);
    EXPECT_EQ(packed_indices[2], 2u);

    ASSERT_EQ(mesh.Submeshes()[0].DrawRanges().size(), 1u);
    ASSERT_EQ(mesh.Submeshes()[1].DrawRanges().size(), 1u);
    EXPECT_EQ(mesh.Submeshes()[0].DrawRanges()[0].indexOffset, 0u);
    EXPECT_EQ(mesh.Submeshes()[0].DrawRanges()[0].indexCount, 3u);
    EXPECT_EQ(mesh.Submeshes()[1].DrawRanges()[0].indexOffset, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].DrawRanges()[0].indexCount, 3u);

    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
}

TEST(MdlSchema, SkipsPartDrawRangesThatExceedEmittedIndexPayload) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21InvalidPartRangeFixture(2, 2));
    WPMdl mdl;
    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));

    SceneMesh mesh;
    WPMdlParser::GenPuppetMesh(mesh, mdl);

    ASSERT_EQ(mesh.Submeshes().size(), 1u);
    ExpectDrawsNothing(mesh.Submeshes()[0].DrawRanges());
}

TEST(MdlSchema, SkipsPartDrawRangesWhenStartPlusSizeOverflows) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21InvalidPartRangeFixture(UINT32_MAX, 1));
    WPMdl mdl;
    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));

    SceneMesh mesh;
    WPMdlParser::GenPuppetMesh(mesh, mdl);

    ASSERT_EQ(mesh.Submeshes().size(), 1u);
    ExpectDrawsNothing(mesh.Submeshes()[0].DrawRanges());
}

TEST(MdlSchema, GeneratesMaskPrepassAndClippedSubmeshesForMdlv23Masks) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv23MaskedMeshOnlyFixture());
    WPMdl mdl;
    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));

    SceneMesh mesh;
    WPMdlParser::GenPuppetMesh(mesh, mdl);

    ASSERT_EQ(mesh.Submeshes().size(), 3u);
    EXPECT_EQ(mesh.Submeshes()[0].material_slot, 0u);
    ExpectDrawsNothing(mesh.Submeshes()[0].DrawRanges());

    EXPECT_EQ(mesh.Submeshes()[1].material_slot, 1u);
    EXPECT_EQ(mesh.Submeshes()[1].output_override, "_rt_puppet_mask");
    ASSERT_EQ(mesh.Submeshes()[1].DrawRanges().size(), 1u);
    EXPECT_EQ(mesh.Submeshes()[1].DrawRanges()[0].indexOffset, 0u);
    EXPECT_EQ(mesh.Submeshes()[1].DrawRanges()[0].indexCount, 3u);

    EXPECT_EQ(mesh.Submeshes()[2].material_slot, 2u);
    ASSERT_EQ(mesh.Submeshes()[2].DrawRanges().size(), 1u);
    EXPECT_EQ(mesh.Submeshes()[2].DrawRanges()[0].indexOffset, 0u);
    EXPECT_EQ(mesh.Submeshes()[2].DrawRanges()[0].indexCount, 3u);
}

TEST(MdlSchema, InvalidMaskPartIdsGenerateRenderSafeNoDrawSubmeshes) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv23MaskedMeshWithInvalidPartIdsFixture());
    WPMdl mdl;
    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));

    SceneMesh mesh;
    WPMdlParser::GenPuppetMesh(mesh, mdl);

    ASSERT_EQ(mesh.Submeshes().size(), 3u);
    ASSERT_EQ(mesh.Submeshes()[0].DrawRanges().size(), 1u);
    EXPECT_EQ(mesh.Submeshes()[0].DrawRanges()[0].indexOffset, 0u);
    EXPECT_EQ(mesh.Submeshes()[0].DrawRanges()[0].indexCount, 3u);
    ExpectDrawsNothing(mesh.Submeshes()[1].DrawRanges());
    ExpectDrawsNothing(mesh.Submeshes()[2].DrawRanges());
}

TEST(MdlSchema, ForwardBoneParentIsToleratedAsRoot) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21ForwardParentFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    ASSERT_EQ(mdl.puppet->bones.size(), 2u);
    EXPECT_TRUE(mdl.puppet->bones[1].noParent());
    EXPECT_EQ(mdl.puppet->bones[1].bind_parent, WPPuppet::Bone::NO_PARENT);
    EXPECT_EQ(mdl.puppet->bones[1].anim_parent, WPPuppet::Bone::NO_PARENT);
    EXPECT_EQ(mdl.puppet->bones[1].file_parent, WPPuppet::Bone::NO_PARENT);
}

TEST(MdlSchema, MdlsIkExtrasAndMdatDoNotDesynchronizeLaterBlocks) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21Mdls3IkAndMdatFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    ASSERT_EQ(mdl.puppet->attachments.size(), 1u);
    EXPECT_EQ(mdl.puppet->attachments[0].bone_index, 0u);
    EXPECT_EQ(mdl.puppet->attachments[0].name, "hat_anchor");
    EXPECT_FLOAT_EQ(mdl.puppet->attachments[0].local_xform.translation().x(), 4.0f);
    EXPECT_FLOAT_EQ(mdl.puppet->attachments[0].local_xform.translation().y(), 5.0f);
    EXPECT_FLOAT_EQ(mdl.puppet->attachments[0].local_xform.translation().z(), 6.0f);
}

TEST(MdlSchema, ParsesMdla6AnimationsWithoutDesynchronizing) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21Mdls3Mdla6AnimationsFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    EXPECT_EQ(mdl.mdla, 6);
    ASSERT_EQ(mdl.puppet->anims.size(), 2u);
    EXPECT_EQ(mdl.puppet->anims[0].id, 101);
    EXPECT_EQ(mdl.puppet->anims[0].name, "intro");
    EXPECT_EQ(mdl.puppet->anims[1].id, 202);
    EXPECT_EQ(mdl.puppet->anims[1].name, "idle");
    ASSERT_EQ(mdl.puppet->anims[1].bone_tracks.size(), 1u);
    ASSERT_EQ(mdl.puppet->anims[1].bone_tracks[0].frames.size(), 1u);
    EXPECT_FLOAT_EQ(mdl.puppet->anims[1].bone_tracks[0].frames[0].position.x(), 202.0f);
    ASSERT_EQ(mdl.puppet->anims[1].events.size(), 1u);
    EXPECT_EQ(mdl.puppet->anims[1].events[0].event_json, R"({"name":"fixture_event"})");
}

TEST(MdlSchema, MdlaParseFailureClearsAnimationsButKeepsMeshAndBones) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21Mdls3Mdla6InvalidAnimationFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_EQ(mdl.meshes.size(), 1u);
    ASSERT_NE(mdl.puppet, nullptr);
    ASSERT_EQ(mdl.puppet->bones.size(), 1u);
    EXPECT_TRUE(mdl.puppet->anims.empty());
}

TEST(MdlSchema, RejectsMdlaAnimCountThatCannotFitRemainingBlock) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21Mdls3Mdla6HugeAnimCountFixture());
    WPMdl mdl;
    ScopedLogCapture logs;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    EXPECT_TRUE(mdl.puppet->anims.empty());
    EXPECT_TRUE(logs.Contains(LOGLEVEL_ERROR, "MDLA animation count"));
}

TEST(MdlSchema, MdlaInvalidCountSeeksToBlockEndBeforeFollowingMdle) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21MdleAfterInvalidMdlaPayloadFixture());
    WPMdl mdl;
    ScopedLogCapture logs;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    EXPECT_TRUE(mdl.puppet->anims.empty());
    EXPECT_TRUE(logs.Contains(LOGLEVEL_ERROR, "MDLA animation count"));
    EXPECT_EQ(mdl.mdle, 1);
    ASSERT_EQ(mdl.puppet->bones.size(), 2u);
    EXPECT_TRUE(mdl.puppet->bones[0].has_file_world_bind);
    EXPECT_TRUE(mdl.puppet->bones[1].has_file_world_bind);
    EXPECT_FLOAT_EQ(mdl.puppet->bones[0].file_world_bind.translation().x(), 2.0f);
    EXPECT_FLOAT_EQ(mdl.puppet->bones[1].file_world_bind.translation().z(), 7.0f);
}

TEST(MdlSchema, RejectsMdlaBoneTrackCountThatCannotFitRemainingBlock) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21Mdls3Mdla6HugeBoneTrackCountFixture());
    WPMdl mdl;
    ScopedLogCapture logs;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    EXPECT_TRUE(mdl.puppet->anims.empty());
    EXPECT_TRUE(logs.Contains(LOGLEVEL_ERROR, "MDLA bone track count"));
}

TEST(MdlSchema, RejectsMdlaEventCountThatCannotFitRemainingBlock) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21Mdls3Mdla6HugeEventCountFixture());
    WPMdl mdl;
    ScopedLogCapture logs;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    EXPECT_TRUE(mdl.puppet->anims.empty());
    EXPECT_TRUE(logs.Contains(LOGLEVEL_ERROR, "MDLA event count"));
}

TEST(MdlSchema, MdleAfterMdlaSetsFileWorldBindOnEachBone) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21MdleAfterMdlaFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    EXPECT_EQ(mdl.mdle, 1);
    ASSERT_EQ(mdl.puppet->bones.size(), 2u);
    EXPECT_TRUE(mdl.puppet->bones[0].has_file_world_bind);
    EXPECT_TRUE(mdl.puppet->bones[1].has_file_world_bind);
    EXPECT_FLOAT_EQ(mdl.puppet->bones[0].file_world_bind.translation().x(), 2.0f);
    EXPECT_FLOAT_EQ(mdl.puppet->bones[1].file_world_bind.translation().z(), 7.0f);
}

TEST(MdlSchema, ConsumesNonzeroTrailingBodyByteAfterOptionalBlocks) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21MdleWithNonzeroTrailingBodyByteFixture());
    WPMdl mdl;
    ScopedLogCapture logs;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    EXPECT_EQ(mdl.mdle, 1);
    EXPECT_TRUE(logs.Contains(LOGLEVEL_INFO, "trailing_nul expected 0"));
}

TEST(MdlSchema, MdmpAfterMdlaParsesZeroShapeTrailer) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21MdmpAfterMdlaFixture(true));
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    EXPECT_EQ(mdl.mdmp, 1);
    ASSERT_EQ(mdl.morph_sections.size(), 1u);
    EXPECT_FLOAT_EQ(mdl.morph_sections[0].event_time, 12.5f);
    EXPECT_EQ(mdl.morph_sections[0].event_id, 42u);
    ASSERT_EQ(mdl.morph_sections[0].sections.size(), 1u);
    const auto& section = mdl.morph_sections[0].sections[0];
    EXPECT_EQ(section.shape_id, 0u);
    EXPECT_EQ(section.tag, "fixture_morph");
    EXPECT_EQ(section.hash, 0x12345678u);
    ASSERT_EQ(section.vertices.size(), 1u);
    EXPECT_EQ(section.vertices[0][2], 2u);
    ASSERT_EQ(section.trailer.size(), 6u);
    EXPECT_EQ(section.trailer[5], 0xA5u);
}

TEST(MdlSchema, MdmpAfterMdlaParsesNonzeroShapeVertexTrailers) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21MdmpAfterMdlaFixture(false));
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_EQ(mdl.morph_sections.size(), 1u);
    ASSERT_EQ(mdl.morph_sections[0].sections.size(), 1u);
    const auto& section = mdl.morph_sections[0].sections[0];
    EXPECT_EQ(section.shape_id, 9u);
    ASSERT_EQ(section.vertex_trailers.size(), 1u);
    EXPECT_EQ(section.vertex_trailers[0], 0xBEEFu);
    EXPECT_TRUE(section.trailer.empty());
}

TEST(MdlSchema, PuppetAnimationAdvancesOncePerAbsoluteElapsedTime) {
    auto puppet = std::make_shared<WPPuppet>();
    puppet->bones.resize(1);
    puppet->bones[0].parent = WPPuppet::Bone::NO_PARENT;
    puppet->bones[0].bind_parent = WPPuppet::Bone::NO_PARENT;
    puppet->bones[0].anim_parent = WPPuppet::Bone::NO_PARENT;

    WPPuppet::Animation anim;
    anim.id = 7;
    anim.fps = 1.0;
    anim.length = 2;
    anim.mode = WPPuppet::PlayMode::Loop;
    anim.bone_tracks.resize(1);
    anim.bone_tracks[0].frames.resize(3);
    for (auto& frame : anim.bone_tracks[0].frames) {
        frame.position = Eigen::Vector3f::Zero();
        frame.angle = Eigen::Vector3f::Zero();
        frame.scale = Eigen::Vector3f::Ones();
    }
    anim.bone_tracks[0].frames[1].position.x() = 10.0f;
    anim.bone_tracks[0].frames[2].position.x() = 20.0f;
    puppet->anims.push_back(std::move(anim));
    puppet->prepared();

    WPPuppetLayer::AnimationLayer anim_layer;
    anim_layer.id = 7;
    anim_layer.blend = 1.0;
    WPPuppetLayer layer(puppet);
    std::array<WPPuppetLayer::AnimationLayer, 1> layers { anim_layer };
    layer.prepared(layers);

    (void)layer.genFrame(0.0);
    const auto first = layer.genFrame(0.5)[0].translation().x();
    const auto second = layer.genFrame(0.5)[0].translation().x();

    EXPECT_NEAR(first, 5.0f, 1.0e-5f);
    EXPECT_NEAR(second, first, 1.0e-5f);
}

TEST(MdlSchema, SharedPuppetCopiesApplySameTimeControlsToThePose) {
    auto layer = BuildAdditiveLayer(BuildOneBonePuppet(WPPuppet::PlayMode::Single, 0, 100));
    auto copy = layer;
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0), 0);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 50);
    ASSERT_TRUE(layer.pause(0));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 50);
    ASSERT_TRUE(layer.setFrame(0, 0.25));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 25);
    ASSERT_TRUE(copy.stop(0));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 0);
    ASSERT_TRUE(layer.setFrame(0, 0.75));
    ASSERT_TRUE(layer.play(0));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 75);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.75), 100);
    EXPECT_FALSE(layer.isPlaying(0));
    ASSERT_TRUE(layer.play(0));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.75), 0);
    EXPECT_TRUE(copy.isPlaying(0));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 1), 25);
}

TEST(MdlSchema, PuppetRateChangesAndRewindsPreserveTheElapsedHighWaterMark) {
    auto layer = BuildAdditiveLayer(BuildOneBonePuppet(WPPuppet::PlayMode::Single, 0, 100));
    auto copy = layer;
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0), 0);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.25), 25);
    ASSERT_TRUE(layer.setRate(0, 2));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.25), 25);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.375), 50);
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.125), 50);
    ASSERT_TRUE(copy.setRate(0, 0.5));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.375), 50);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 56.25);
    ASSERT_TRUE(layer.pause(0));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.75), 56.25);
    ASSERT_TRUE(copy.play(0));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.75), 56.25);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 1), 68.75);
}

TEST(MdlSchema, SharedPuppetBlendAndVisibilityChangeAnAlreadySampledPose) {
    auto layer = BuildAdditiveLayer(BuildOneBonePuppet(WPPuppet::PlayMode::Single, 40, 80));
    auto copy = layer;
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0), 40);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 60);
    ASSERT_TRUE(layer.setBlend(0, 0.5));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 30);
    ASSERT_TRUE(copy.setVisible(0, false));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 0);
    ASSERT_TRUE(layer.setVisible(0, true));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 30);
    ASSERT_TRUE(copy.setBlend(0, 1));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 60);
    ASSERT_TRUE(layer.setBlend(0, 1));
    ASSERT_TRUE(layer.setVisible(0, true));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 60);
}

TEST(MdlSchema, PuppetReprepareResetsBlendWithoutResettingTheSharedClock) {
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Single, 0, 100);
    WPPuppetLayer layer(puppet);
    WPPuppetLayer::AnimationLayer authored;
    authored.id = 1;
    layer.prepared(std::span(&authored, 1));
    auto copy = layer;
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0), 0);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 50);
    authored.blend = 0.5;
    authored.cur_time = 0.25;
    layer.prepared(std::span(&authored, 1));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 12.5);
    copy.prepared(std::span(&authored, 1));
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.5), 12.5);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.25), 12.5);
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0.75), 25);
    copy.prepared({});
    EXPECT_TRUE(layer.genFrame(0.75)[0].matrix().isApprox(Eigen::Matrix4f::Identity()));
    authored.id = 999;
    layer.prepared(std::span(&authored, 1));
    EXPECT_TRUE(copy.genFrame(0.75)[0].matrix().isApprox(Eigen::Matrix4f::Identity()));
    EXPECT_FALSE(copy.setFrame(0, 0.5));
}

TEST(MdlSchema, RejectedPuppetControlsPreservePoseAndPlayback) {
    auto layer = BuildAdditiveLayer(BuildOneBonePuppet(WPPuppet::PlayMode::Single, 0, 100));
    auto copy = layer;
    EXPECT_FLOAT_EQ(RootTranslationY(layer, 0), 0);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.25), 25);
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double inf = std::numeric_limits<double>::infinity();
    EXPECT_FALSE(layer.play(-1));
    EXPECT_FALSE(layer.pause(1));
    EXPECT_FALSE(layer.stop(1));
    EXPECT_FALSE(layer.setFrame(1, 0));
    EXPECT_FALSE(layer.setFrame(0, nan));
    EXPECT_FALSE(layer.setFrame(0, inf));
    EXPECT_FALSE(layer.setRate(1, 1));
    EXPECT_FALSE(layer.setRate(0, nan));
    EXPECT_FALSE(layer.setRate(0, inf));
    EXPECT_FALSE(layer.setBlend(1, 1));
    EXPECT_FALSE(layer.setBlend(0, nan));
    EXPECT_FALSE(layer.setBlend(0, inf));
    EXPECT_FALSE(layer.setVisible(1, false));
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.25), 25);
    EXPECT_FLOAT_EQ(RootTranslationY(copy, 0.5), 50);
}

TEST(MdlSchema, IndependentPuppetStatesDoNotOverwriteBorrowedPoses) {
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Single, 0, 100);
    auto first = BuildAdditiveLayer(puppet);
    auto second = BuildAdditiveLayer(puppet);
    auto shared = first;
    first.genFrame(0);
    second.genFrame(0);
    const auto first_pose = first.genFrame(0.25);
    ASSERT_EQ(first_pose.size(), 1u);
    const Eigen::Matrix4f saved = first_pose[0].matrix();
    EXPECT_FLOAT_EQ(RootTranslationY(second, 0.75), 75);
    EXPECT_TRUE(first_pose[0].matrix().isApprox(saved));
    ASSERT_TRUE(shared.setFrame(0, 0.5));
    EXPECT_FLOAT_EQ(RootTranslationY(first, 0.25), 50);
    EXPECT_FLOAT_EQ(RootTranslationY(second, 0.75), 75);
    ASSERT_TRUE(second.stop(0));
    EXPECT_FLOAT_EQ(RootTranslationY(second, 0.75), 0);
    EXPECT_FLOAT_EQ(RootTranslationY(shared, 0.25), 50);
}

TEST(MdlSchema, EmptyPuppetLayersRemainSafeAndZeroBonesKeepPlaybackState) {
    WPPuppetLayer empty;
    WPPuppetLayer null_layer(nullptr);
    WPPuppetLayer::AnimationLayer authored;
    authored.id = 1;
    for (auto* layer : { &empty, &null_layer }) {
        layer->prepared(std::span(&authored, 1));
        EXPECT_FALSE(layer->hasPuppet());
        EXPECT_TRUE(layer->genFrame(0).empty());
        EXPECT_EQ(layer->layerCount(), 0u);
        EXPECT_FALSE(layer->play(0));
        EXPECT_FALSE(layer->setFrame(0, 0));
    }
    auto puppet = BuildOneBonePuppet(WPPuppet::PlayMode::Single, 0, 100);
    puppet->bones.clear();
    puppet->prepared();
    auto layer = BuildAdditiveLayer(puppet);
    auto copy = layer;
    EXPECT_TRUE(layer.hasPuppet());
    EXPECT_TRUE(layer.genFrame(0).empty());
    EXPECT_TRUE(copy.genFrame(0.5).empty());
    EXPECT_DOUBLE_EQ(layer.frame(0), 0.5);
    EXPECT_TRUE(layer.genFrame(1).empty());
    EXPECT_FALSE(copy.isPlaying(0));
    ASSERT_TRUE(copy.play(0));
    EXPECT_TRUE(layer.genFrame(1).empty());
    EXPECT_DOUBLE_EQ(layer.frame(0), 0);
}

TEST(MdlSchema, VertexCentroidOffsetOnlyBracketsWorldAnchoredRoots) {
    auto make_puppet = [](bool world_anchored) {
        auto puppet = std::make_shared<WPPuppet>();
        puppet->world_anchored_bones = world_anchored;
        puppet->bones.resize(1);
        puppet->bones[0].parent = WPPuppet::Bone::NO_PARENT;
        puppet->bones[0].bind_parent = WPPuppet::Bone::NO_PARENT;
        puppet->bones[0].anim_parent = WPPuppet::Bone::NO_PARENT;
        puppet->bones[0].vertex_centroid_offset = Eigen::Vector3f(2.0f, 0.0f, 0.0f);

        WPPuppet::Animation anim;
        anim.id = 9;
        anim.fps = 1.0;
        anim.length = 2;
        anim.mode = WPPuppet::PlayMode::Loop;
        anim.bone_tracks.resize(1);
        anim.bone_tracks[0].frames.resize(3);
        for (auto& frame : anim.bone_tracks[0].frames) {
            frame.position = Eigen::Vector3f::Zero();
            frame.angle = Eigen::Vector3f::Zero();
            frame.scale = Eigen::Vector3f::Ones();
        }
        anim.bone_tracks[0].frames[1].scale.x() = 2.0f;
        anim.bone_tracks[0].frames[2].scale.x() = 3.0f;
        puppet->anims.push_back(std::move(anim));
        puppet->prepared();
        return puppet;
    };
    auto sample_x = [](std::shared_ptr<WPPuppet> puppet) {
        WPPuppetLayer::AnimationLayer anim_layer;
        anim_layer.id = 9;
        anim_layer.blend = 1.0;
        WPPuppetLayer layer(std::move(puppet));
        std::array<WPPuppetLayer::AnimationLayer, 1> layers { anim_layer };
        layer.prepared(layers);
        (void)layer.genFrame(0.0);
        return layer.genFrame(0.5)[0].translation().x();
    };

    EXPECT_NEAR(sample_x(make_puppet(true)), -1.0f, 1.0e-5f);
    EXPECT_NEAR(sample_x(make_puppet(false)), 0.0f, 1.0e-5f);
}

TEST(MdlSchema, PreservesFirstLevelBoneHierarchyForMdlv21WithoutMdls3Pivot) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21TwoMeshFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    ASSERT_EQ(mdl.puppet->bones.size(), 4u);
    EXPECT_TRUE(mdl.puppet->bones[0].noParent());
    EXPECT_EQ(mdl.puppet->bones[1].parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[2].parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[3].parent, 1u);
    EXPECT_EQ(mdl.puppet->bones[1].bind_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[2].bind_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[3].bind_parent, 1u);
    EXPECT_EQ(mdl.puppet->bones[1].anim_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[2].anim_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[3].anim_parent, 1u);
    EXPECT_EQ(mdl.puppet->bones[1].file_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[2].file_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[3].file_parent, 1u);
}

TEST(MdlSchema, UsesChainedBindHierarchyWithoutMdls3Pivot) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21TranslatedBonesFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);

    WPPuppetLayer layer(mdl.puppet);
    std::vector<WPPuppetLayer::AnimationLayer> layers;
    layer.prepared(layers);
    const auto frame = layer.genFrame(0.0);

    ASSERT_EQ(frame.size(), 3u);
    EXPECT_NEAR(frame[0].translation().x(), 0.0f, 1.0e-5f);
    EXPECT_NEAR(frame[1].translation().x(), 0.0f, 1.0e-5f);
    EXPECT_NEAR(frame[2].translation().x(), 0.0f, 1.0e-5f);
}

TEST(MdlSchema, Mdls3SkinningPreservesAuthoredHierarchyAndPivotsAcrossMeshVersions) {
    for (int version : {21, 23}) {
        SCOPED_TRACE(version);
        fs::VFS vfs;
        MountMdlFixture(vfs, BuildMdlv23ParentChainFixture(version));
        WPMdl mdl;
        ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
        auto puppet = mdl.puppet;
        ASSERT_NE(puppet, nullptr);
        EXPECT_FALSE(puppet->world_anchored_bones);
        EXPECT_EQ(puppet->bones[2].bind_parent, 1u);
        EXPECT_EQ(puppet->bones[2].anim_parent, 1u);
        EXPECT_NEAR(puppet->bones[2].world_bind.translation().x(), 15, 1e-5);
        WPPuppet::Animation animation;
        animation.id = 1;
        animation.fps = 1;
        animation.length = 1;
        animation.mode = WPPuppet::PlayMode::Loop;
        for (const auto& bone : puppet->bones) {
            auto& track = animation.bone_tracks.emplace_back();
            for (int sample = 0; sample < 2; ++sample) {
                auto& frame = track.frames.emplace_back();
                frame.position = bone.local_bind.translation();
                frame.scale = Eigen::Vector3f::Ones();
                frame.angle = Eigen::Vector3f::Zero();
            }
        }
        for (auto& frame : animation.bone_tracks[0].frames) {
            frame.angle.z() = std::acos(-1.0f) / 2;
        }
        for (auto& frame : animation.bone_tracks[2].frames) frame.scale.y() = 0;
        puppet->anims.push_back(std::move(animation));
        puppet->prepared();
        auto layer = BuildAdditiveLayer(puppet);
        const Eigen::Vector3f point(17, 3, 0);
        for (double time : {0.0, 0.5, 0.5, 1.0}) {
            const Eigen::Vector3f actual = layer.genFrame(time)[2] * point;
            EXPECT_TRUE(actual.isApprox(Eigen::Vector3f(10, 7, 0), 1e-5)) << actual.transpose();
        }
    }
}

TEST(MdlSchema, Mdlv23PreservesChainedPuppetHierarchy) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv23ParentChainFixture());
    WPMdl mdl;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_NE(mdl.puppet, nullptr);
    ASSERT_EQ(mdl.puppet->bones.size(), 3u);
    EXPECT_FALSE(mdl.puppet->world_anchored_bones);
    EXPECT_TRUE(mdl.puppet->bones[0].noParent());
    EXPECT_EQ(mdl.puppet->bones[1].bind_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[1].anim_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[1].file_parent, 0u);
    EXPECT_EQ(mdl.puppet->bones[2].bind_parent, 1u);
    EXPECT_EQ(mdl.puppet->bones[2].anim_parent, 1u);
    EXPECT_EQ(mdl.puppet->bones[2].file_parent, 1u);

    WPPuppetLayer layer(mdl.puppet);
    std::vector<WPPuppetLayer::AnimationLayer> layers;
    layer.prepared(layers);
    const auto frame = layer.genFrame(0.0);

    ASSERT_EQ(frame.size(), 3u);
    EXPECT_NEAR(frame[0].translation().x(), 0.0f, 1.0e-5f);
    EXPECT_NEAR(frame[1].translation().x(), 0.0f, 1.0e-5f);
    EXPECT_NEAR(frame[2].translation().x(), 0.0f, 1.0e-5f);
}

TEST(MdlSchema, RejectsOversizedMdlv21MeshCountBeforeAllocation) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21WithMeshCount(100000));
    WPMdl mdl;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

TEST(MdlSchema, LogsIncompleteMdlFlagAsError) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21IncompleteFlagFixture());
    WPMdl mdl;
    ScopedLogCapture logs;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    EXPECT_TRUE(logs.Contains(LOGLEVEL_ERROR, "is not complete"));
}

TEST(MdlSchema, ParsesMdlv23IncompleteFlagMeshOnlyPuppet) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv23IncompleteFlagMeshOnlyFixture());
    WPMdl mdl;
    ScopedLogCapture logs;

    ASSERT_TRUE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    ASSERT_EQ(mdl.meshes.size(), 1u);
    EXPECT_EQ(mdl.meshes[0].flag, kSkinUvFlag);
    EXPECT_EQ(mdl.puppet, nullptr);
    EXPECT_TRUE(logs.Contains(LOGLEVEL_INFO, "incomplete flag"));
}

TEST(MdlSchema, LogsUnsupportedPartsExtrasAsError) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21WithUnsupportedPartsExtras());
    WPMdl mdl;
    ScopedLogCapture logs;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
    EXPECT_TRUE(logs.Contains(LOGLEVEL_ERROR, "unhandled parts extras"));
}

TEST(MdlSchema, RejectsTruncatedMdlv21VertexPayload) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21WithTruncatedVertexPayload());
    WPMdl mdl;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

TEST(MdlSchema, RejectsTruncatedMdlv21PartsPayload) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21WithTruncatedPartsPayload());
    WPMdl mdl;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

TEST(MdlSchema, RejectsInvalidMdlv21PartsBytes) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21WithInvalidPartsBytes());
    WPMdl mdl;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

TEST(MdlSchema, RejectsTruncatedMdlv23MaskBlock) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv23TruncatedMaskFixture());
    WPMdl mdl;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

TEST(MdlSchema, RejectsMdatEndOffsetPastEndOfStream) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21WithTruncatedMdatEndOffset());
    WPMdl mdl;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

TEST(MdlSchema, RejectsMdatAttachmentNameThatOverrunsDeclaredBlock) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21WithTruncatedMdatAttachmentName());
    WPMdl mdl;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

TEST(MdlSchema, RejectsMdatAttachmentTransformThatOverrunsDeclaredBlock) {
    fs::VFS vfs;
    MountMdlFixture(vfs, BuildMdlv21WithTruncatedMdatTransform());
    WPMdl mdl;

    EXPECT_FALSE(WPMdlParser::Parse("sample.mdl", vfs, mdl));
}

