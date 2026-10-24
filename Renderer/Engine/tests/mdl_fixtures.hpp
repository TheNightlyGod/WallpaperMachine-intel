// Builders for .mdl files used by the model parser tests: one mesh record
// writer with every optional section switchable, the skeleton and the optional
// blocks behind it, and a parse helper that also keeps what the parser logged.
#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "Fs/VFS.h"
#include "Scene/SceneMesh.h"
#include "Utils/Logging.h"
#include "WPMdlParser.hpp"
#include "support/byte_fs.hpp"

namespace mdltest
{

using wallpaper::test::Bytes;
using F2 = std::array<float, 2>;
using F3 = std::array<float, 3>;
using F4 = std::array<float, 4>;
using U4 = std::array<uint32_t, 4>;

constexpr uint32_t kNone = 0xFFFFFFFFu;

// Vertex layout bits of a mesh flag word.
constexpr uint32_t kNormal   = 0x2;
constexpr uint32_t kTangent  = 0x4;
constexpr uint32_t kUv       = 0x8;
constexpr uint32_t kUvPair   = 0x20;
constexpr uint32_t kSkinIdx  = 0x00800000;
constexpr uint32_t kSkinWgt  = 0x01000000;
// bones + weights + one texture coordinate
constexpr uint32_t kSkinned = kSkinIdx | kSkinWgt | kUv;

// ---- the data every standard triangle mesh carries ------------------------------------------

inline F3 stdPosition(int i) {
    return { 1.5f * static_cast<float>(i) + 0.5f, static_cast<float>(i) - 2.0f,
             4.0f - 2.0f * static_cast<float>(i) };
}
inline F3 stdNormal(int) { return { 0.0f, 0.0f, 1.0f }; }
inline F4 stdTangent(int) { return { 1.0f, 0.0f, 0.0f, 1.0f }; }
inline F2 stdUv(int i) {
    static const F2 uv[3] = { { 0.1f, 0.9f }, { 0.2f, 0.7f }, { 0.3f, 0.5f } };
    return uv[i % 3];
}
inline F2 stdUv2(int i) {
    static const F2 uv[3] = { { 0.3f, 0.6f }, { 0.6f, 0.6f }, { 0.9f, 0.6f } };
    return uv[i % 3];
}
inline U4 stdBoneIdx(int i) {
    static const U4 v[3] = { { 2, 1, 0, 0 }, { 1, 0, 2, 0 }, { 0, 2, 1, 0 } };
    return v[i % 3];
}
inline F4 stdBoneWgt(int i) {
    static const F4 v[3] = { { 0.5f, 0.5f, 0.0f, 0.0f },
                             { 0.25f, 0.75f, 0.0f, 0.0f },
                             { 1.0f, 0.0f, 0.0f, 0.0f } };
    return v[i % 3];
}

// ---- mesh record -----------------------------------------------------------------------------

struct PartSpec {
    uint32_t id { 1 }, start { 0 }, size { 3 };
};
struct MaskSpec {
    uint32_t              leading { 7 };
    std::string           material { "masks/m.json" };
    std::vector<uint32_t> a, b;
};

struct MeshSpec {
    std::string material { "models/surface.json" };
    uint32_t    flag { 0 };
    uint32_t    vertices { 3 };
    // Position i is (i, 0, 0) instead of the standard triangle's positions.
    bool linePositions { false };
    // Only written for versions that have a bounding box.
    F3 boxMin { -1.0f, -2.0f, -3.0f };
    F3 boxMax { 4.0f, 5.0f, 6.0f };
    std::vector<uint32_t> indices { 0, 2, 1 };

    // Parts section (version 21 and up).
    uint32_t              extras { 0 };
    bool                  payload { false };
    std::vector<PartSpec> parts;
    std::optional<uint32_t> tableBytes; // when set, replaces the computed table length
    bool                    hasParts { false };

    // Mask section (version 22 and up).
    std::vector<MaskSpec> masks;

    std::optional<uint32_t> vertexBytes; // declared length override
};

// Where interesting things landed in the bytes, for tests that cut the file.
struct Marks {
    size_t vertexStart { 0 };
};

inline uint32_t strideOf(uint32_t flag) {
    uint32_t s = 12;
    if (flag & kNormal) s += 12;
    if (flag & kTangent) s += 16;
    if (flag & 0x10000) s += 4;
    if (flag & kSkinIdx) s += 16;
    if (flag & kSkinWgt) s += 16;
    if (flag & (kUv | kUvPair)) s += 8;
    if (flag & kUvPair) s += 8;
    return s;
}

inline void writeMesh(Bytes& b, int version, const MeshSpec& m, Marks* marks = nullptr) {
    b.cstr(m.material);
    b.u32(0); // flag_a
    if (version >= 17) {
        for (float v : m.boxMin) b.f32(v);
        for (float v : m.boxMax) b.f32(v);
    }
    if (version >= 15) b.u32(m.flag);
    b.u32(m.vertexBytes ? *m.vertexBytes : m.vertices * strideOf(m.flag));
    if (marks) marks->vertexStart = b.size();
    for (uint32_t k = 0; k < m.vertices; ++k) {
        const int i = static_cast<int>(k);
        if (m.linePositions) {
            b.f32(static_cast<float>(i)).f32(0.0f).f32(0.0f);
        } else {
            for (float v : stdPosition(i % 3)) b.f32(v);
        }
        if (m.flag & kNormal) for (float v : stdNormal(i)) b.f32(v);
        if (m.flag & kTangent) for (float v : stdTangent(i)) b.f32(v);
        if (m.flag & 0x10000) b.u32(0);
        if (m.flag & kSkinIdx) for (uint32_t v : stdBoneIdx(i)) b.u32(v);
        if (m.flag & kSkinWgt) for (float v : stdBoneWgt(i)) b.f32(v);
        if (m.flag & (kUv | kUvPair)) for (float v : stdUv(i)) b.f32(v);
        if (m.flag & kUvPair) for (float v : stdUv2(i)) b.f32(v);
    }
    const bool wide = m.vertices > 65535;
    b.u32(static_cast<uint32_t>(m.indices.size()) * (wide ? 4 : 2));
    for (uint32_t ix : m.indices) wide ? void(b.u32(ix)) : void(b.u16(ix));

    if (version >= 21) {
        b.u8(m.extras);
        if (m.extras == 1) {
            b.u8(m.payload ? 1 : 0);
            if (m.payload) {
                b.u16(0).u8(0).u32(m.vertices * 12);
                for (uint32_t k = 0; k < m.vertices; ++k)
                    b.f32(0.25f * static_cast<float>(k)).f32(0.5f).u32(0);
            }
        }
        const bool table = m.hasParts || ! m.parts.empty();
        b.u8(table ? 1 : 0);
        if (table) {
            b.u32(m.tableBytes ? *m.tableBytes : static_cast<uint32_t>(m.parts.size()) * 16);
            for (const auto& p : m.parts) b.u32(p.id).u32(0).u32(p.start).u32(p.size);
        }
    }
    if (version >= 22) {
        b.u32(static_cast<uint32_t>(m.masks.size()));
        for (const auto& k : m.masks) {
            b.u32(k.leading).u32(0).cstr(k.material).u32(0);
            b.u32(static_cast<uint32_t>(k.a.size()));
            for (uint32_t v : k.a) b.u32(v);
            b.u32(static_cast<uint32_t>(k.b.size()));
            for (uint32_t v : k.b) b.u32(v);
        }
    }
}

// Header and mesh records. The header flag defaults to the first mesh's layout flag.
inline Bytes mdlFile(int version, const std::vector<MeshSpec>& meshes,
                     std::optional<uint32_t> headerFlag = std::nullopt,
                     Marks* marks = nullptr) {
    Bytes b;
    b.stamp("MDLV", version);
    b.u32(headerFlag ? *headerFlag : (meshes.empty() ? 0 : meshes.front().flag));
    b.i32(-5).u32(static_cast<uint32_t>(meshes.size()));
    for (const auto& m : meshes) writeMesh(b, version, m, marks);
    return b;
}

// A single standard skinned triangle mesh, version 21, no parts, nothing after it.
inline Bytes skinnedFile(int version = 21) {
    MeshSpec m;
    m.flag = kSkinned;
    return mdlFile(version, { m });
}

// ---- skeleton and optional blocks -------------------------------------------------------------

struct BoneSpec {
    std::string name;
    uint32_t    parent { kNone };
    F3          bind { 0, 0, 0 };
    F3          reference { 0, 0, 0 }; // version 2 reference pose
};

// Returns the offset of the end-offset field.
inline size_t beginBlock(Bytes& b, const char* name, int version) {
    b.stamp(name, version);
    const size_t at = b.size();
    b.u32(0);
    return at;
}
inline void endBlock(Bytes& b, size_t at) {
    b.patchU32(at, static_cast<uint32_t>(b.size()));
}

// Opaque: a short blob after the kinematics header. Loud: a blob that would parse as a skin table
// if anything read it.
enum class IkTail { None, Opaque, Loud };

inline void writeSkeleton(Bytes& b, int version, const std::vector<BoneSpec>& bones,
                          IkTail ik = IkTail::None) {
    const size_t end = beginBlock(b, "MDLS", version);
    b.u16(static_cast<uint32_t>(bones.size())).u16(0);
    for (const auto& bone : bones) {
        b.cstr(bone.name).i32(0).u32(bone.parent).u32(64);
        b.matrix(bone.bind[0], bone.bind[1], bone.bind[2]);
        b.cstr("{}");
    }
    if (version == 1) {
        b.patchU32(end, 0);
        return;
    }
    if (version == 2) {
        b.u16(0).u8(1);
        for (const auto& bone : bones) b.matrix(bone.reference[0], bone.reference[1], bone.reference[2]);
        b.fill(10, 0);
    } else if (ik == IkTail::Opaque) {
        b.u16(2).u8(0).u32(0).u32(0);
        b.raw({ 0x00, 0x00, 0x7F, 0x7E, 0x7D });
    } else if (ik == IkTail::Loud) {
        b.u16(2).u8(0).u32(0).u32(0);
        b.u8(1).fill(bones.size() * 76 + 16, 0x11);
    } else {
        b.u16(0).u8(0).u32(0).u32(0).u8(0).u8(0).u8(0);
    }
    endBlock(b, end);
}

struct AttachmentSpec {
    uint32_t    bone { 0 };
    std::string name;
    F3          at { 0, 0, 0 };
};

inline void writeMdat(Bytes& b, const std::vector<AttachmentSpec>& list) {
    const size_t end = beginBlock(b, "MDAT", 1);
    b.u16(static_cast<uint32_t>(list.size()));
    for (const auto& a : list) {
        b.u16(a.bone).cstr(a.name).matrix(a.at[0], a.at[1], a.at[2]);
    }
    endBlock(b, end);
}

struct AnimSpec {
    int32_t     id { 1 };
    std::string name { "anim" };
    // Failure injections.
    uint32_t trackCount { 1 };
    bool     badSecondCurve { false };
    uint32_t jsonEventCount { 1 };
    bool     headerOnly { false }; // stop right after the track count
};

inline void writeCurveBlock(Bytes& b) {
    b.u8(1).u32(0).u32(8).f32(2.0f).f32(3.0f);
}

// One animation record of an MDLA version 6 block for a one-bone skeleton.
inline void writeAnim6(Bytes& b, const AnimSpec& a) {
    b.i32(a.id).u32(0).cstr(a.name).cstr("loop").f32(30.0f).i32(1).i32(0).u32(a.trackCount);
    if (a.headerOnly) return;
    for (uint32_t t = 0; t < a.trackCount; ++t) {
        b.i32(0).u32(36);
        b.f32(static_cast<float>(a.id)).f32(0).f32(0); // position
        b.f32(0).f32(0).f32(0);                        // angle
        b.f32(1).f32(1).f32(1);                        // scale
    }
    b.u32(1);
    b.u32(8).f32(0.0f).f32(1.0f).u32(0);
    b.u32(8).f32(0.25f).f32(0.75f).u32(0);
    writeCurveBlock(b);
    b.u8(1).u32(1).f32(0.5f).u32(0).u32(8).f32(2.0f).f32(3.0f);
    b.f32(-1).f32(-1).f32(0).f32(1).f32(1).f32(0);
    if (a.badSecondCurve) {
        b.u8(1).u32(0).u32(6).f32(1.0f).u16(0);
        b.u32(0);
        return;
    }
    writeCurveBlock(b);
    b.u32(a.jsonEventCount);
    b.u32(12).cstr("{\"k\":\"v\"}");
}

// Two skinned meshes with a part each and a four-bone skeleton behind them.
inline Bytes twoMeshFile() {
    MeshSpec first;
    first.flag     = kSkinned;
    first.material = "models/first.json";
    first.extras   = 1;
    first.payload  = true;
    first.parts    = { { 11, 0, 3 } };
    MeshSpec second = first;
    second.material = "models/second.json";
    second.parts    = { { 22, 0, 3 } };
    Bytes f = mdlFile(21, { first, second });
    writeSkeleton(f, 1,
                  { { "root", kNone }, { "left", 0 }, { "right", 0 }, { "tip", 1 } });
    f.stamp("MDLA", 0).u8(0);
    return f;
}

// ---- parsing ---------------------------------------------------------------------------------

struct LogLine {
    int         level;
    std::string text;
};

inline std::vector<LogLine>*& logSink() {
    static std::vector<LogLine>* sink = nullptr;
    return sink;
}
inline void logToSink(int level, const char*, int, const char* message) {
    if (auto* s = logSink()) s->push_back({ level, message });
}

// The logging callback is process-wide: capture for one scope only.
class LogCapture {
public:
    LogCapture() {
        logSink() = &m_lines;
        SetWallpaperLogCallback(&logToSink);
    }
    ~LogCapture() {
        SetWallpaperLogCallback(nullptr);
        logSink() = nullptr;
    }
    LogCapture(const LogCapture&)            = delete;
    LogCapture& operator=(const LogCapture&) = delete;
    const std::vector<LogLine>& lines() const { return m_lines; }

private:
    std::vector<LogLine> m_lines;
};

struct Parsed {
    bool                 ok { false };
    wallpaper::WPMdl     mdl;
    std::vector<LogLine> logs;

    bool logged(int level, const std::string& needle) const {
        for (const auto& l : logs)
            if (l.level == level && l.text.find(needle) != std::string::npos) return true;
        return false;
    }
    const wallpaper::WPMdl::Mesh& mesh(size_t i = 0) const { return mdl.meshes.at(i); }
};

constexpr int kInfo  = 0;
constexpr int kError = 1;

inline Parsed parse(const std::vector<uint8_t>& bytes, const std::string& name = "sample.mdl") {
    Parsed out;
    wallpaper::fs::VFS vfs;
    wallpaper::test::MapFs::Files files;
    files["/" + name] = bytes;
    vfs.Mount("/assets", std::make_unique<wallpaper::test::MapFs>(std::move(files)));
    LogCapture capture;
    out.ok   = wallpaper::WPMdlParser::Parse(name, vfs, out.mdl);
    out.logs = capture.lines();
    return out;
}
inline Parsed parse(const Bytes& b) { return parse(b.data()); }

// A generated mesh together with the model it came from.
inline std::unique_ptr<wallpaper::SceneMesh> generate(const wallpaper::WPMdl& mdl,
                                                      bool masks = true) {
    auto mesh = std::make_unique<wallpaper::SceneMesh>();
    wallpaper::WPMdlParser::GenPuppetMesh(*mesh, mdl, masks);
    return mesh;
}

using Range = std::pair<uint32_t, uint32_t>;
inline std::vector<Range> rangesOf(const wallpaper::SceneMesh::Submesh& s) {
    std::vector<Range> out;
    for (const auto& r : s.DrawRanges()) out.emplace_back(r.indexOffset, r.indexCount);
    return out;
}

// `count` floats of the named attribute inside the first vertex.
inline std::vector<float> firstVertexAttr(const wallpaper::SceneVertexArray& va,
                                          const std::string& name, size_t count) {
    const auto map = va.GetAttrOffsetMap();
    const auto it  = map.find(name);
    EXPECT_NE(it, map.end()) << name;
    std::vector<float> out;
    if (it == map.end()) return out;
    out.resize(count);
    std::memcpy(out.data(), reinterpret_cast<const char*>(va.Data()) + it->second.offset,
                count * sizeof(float));
    return out;
}

} // namespace mdltest
