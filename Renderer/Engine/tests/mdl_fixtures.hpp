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
constexpr uint32_t kPosition = 0x1;
constexpr uint32_t kNormal   = 0x2;
constexpr uint32_t kTangent  = 0x4;
constexpr uint32_t kUv       = 0x8;
constexpr uint32_t kUvPair   = 0x20;
constexpr uint32_t kSkinIdx  = 0x00800000;
constexpr uint32_t kSkinWgt  = 0x01000000;
// position + bones + weights + one texture coordinate
constexpr uint32_t kSkinned = kPosition | kSkinIdx | kSkinWgt | kUv;

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
    uint32_t    flag { kPosition };
    // The mesh flag word before the bounding box; bit 2 is followed by one more word (1).
    uint32_t    flagA { 0 };
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

// Wallpaper Engine's vertex table (WPMdlVertexBits), summed for the set bits.
inline uint32_t strideOf(uint32_t flag) {
    uint32_t s = 0;
    for (const auto& bit : wallpaper::WPMdlVertexBits())
        if (flag & bit.mask) s += bit.bytes;
    return s;
}

// Lanes `lane`, `lane`+1 of the first texture-coordinate stream (0x8 or 0x20) a vertex.
inline std::vector<F2> uvOf(const wallpaper::WPMdl::Mesh& m, int lane = 0) {
    const auto* s = m.FindStream(kUv);
    if (s == nullptr) s = m.FindStream(kUvPair);
    std::vector<F2> out;
    if (s == nullptr || lane + 2 > s->width) return out;
    for (size_t v = 0; v * s->width < s->values.size(); ++v)
        out.push_back({ s->values[v * s->width + lane], s->values[v * s->width + lane + 1] });
    return out;
}

// The value float k of vertex i of a bit with no standard data: distinct per bit, vertex and lane.
inline float streamValue(uint32_t mask, int i, int k) {
    return static_cast<float>(__builtin_ctz(mask)) + 0.1f * static_cast<float>(i) + 0.01f * static_cast<float>(k);
}

inline void writeMesh(Bytes& b, int version, const MeshSpec& m, Marks* marks = nullptr) {
    b.cstr(m.material);
    b.u32(m.flagA);
    if (m.flagA & 2) b.u32(1);
    if (version >= 17) {
        for (float v : m.boxMin) b.f32(v);
        for (float v : m.boxMax) b.f32(v);
    }
    if (version >= 15) b.u32(m.flag);
    b.u32(m.vertexBytes ? *m.vertexBytes : m.vertices * strideOf(m.flag));
    if (marks) marks->vertexStart = b.size();
    for (uint32_t k = 0; k < m.vertices; ++k) {
        const int i = static_cast<int>(k);
        // In the table's record order.
        for (const auto& bit : wallpaper::WPMdlVertexBits()) {
            if ((m.flag & bit.mask) == 0) continue;
            switch (bit.mask) {
            case kPosition:
                if (m.linePositions) {
                    b.f32(static_cast<float>(i)).f32(0.0f).f32(0.0f);
                } else {
                    for (float v : stdPosition(i % 3)) b.f32(v);
                }
                break;
            case kNormal: for (float v : stdNormal(i)) b.f32(v); break;
            case kTangent: for (float v : stdTangent(i)) b.f32(v); break;
            case kSkinIdx: for (uint32_t v : stdBoneIdx(i)) b.u32(v); break;
            case kSkinWgt: for (float v : stdBoneWgt(i)) b.f32(v); break;
            case kUv: for (float v : stdUv(i)) b.f32(v); break;
            case kUvPair:
                for (float v : stdUv(i)) b.f32(v);
                for (float v : stdUv2(i)) b.f32(v);
                break;
            default:
                for (int f = 0; f < bit.bytes / 4; ++f) b.f32(streamValue(bit.mask, i, f));
            }
        }
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
    std::string simulation { "{}" };   // the bone's simulation JSON
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

// The MDLS tail of version 2 on, in Wallpaper Engine's layout (we_LoadMdlModel 0x140261880):
// IK targets, the reference pose, link records, the K table and groups, the P chains, then the
// skin table and the bone tables.
struct IkTargetSpec {
    std::string name;
    uint32_t    bone { 0 };
    uint32_t    type { 0 };
    F3          at { 0, 0, 0 };
    F3          reference { 0, 0, 0 };
};
struct LinkSpec {
    uint32_t bone { 0 }, a { 0 }, b { 0 }, flags { 0 }, c { 0 };
    float    w { 0 };
};
struct NeighbourSpec {
    uint32_t bone { 0 };
    F3       values { 0, 0, 0 };
};
struct ChainLinkSpec {
    uint32_t              a { 0 }, flags { 0 }, b { 0 }, c { 0 };
    std::vector<uint32_t> bones;
};
struct ChainSegmentSpec {
    uint32_t                   bone { 0 };
    std::vector<ChainLinkSpec> links;
};
struct ChainSpec {
    uint32_t                      bone { 0 };
    std::vector<uint32_t>         targets;
    std::vector<ChainSegmentSpec> segments;
};
struct SkeletonTail {
    std::vector<IkTargetSpec>               targets;
    std::optional<bool>                     reference; // default: version 2 writes one
    std::vector<LinkSpec>                   links;
    std::vector<float>                      table;
    std::vector<std::vector<NeighbourSpec>> groups; // one per table entry, missing = empty
    std::vector<ChainSpec>                  chains;
    bool                                    skin { false };
    bool                                    boneTable { false };
    bool                                    secondBoneTable { false };
    std::vector<uint8_t>                    trailing; // bytes left inside the block
};

inline void writeSkeleton(Bytes& b, int version, const std::vector<BoneSpec>& bones,
                          const SkeletonTail& tail = {}, std::vector<uint32_t> boneFlags = {}) {
    const size_t end = beginBlock(b, "MDLS", version);
    b.u16(static_cast<uint32_t>(bones.size())).u16(0);
    for (size_t i = 0; i < bones.size(); ++i) {
        const auto& bone = bones[i];
        b.cstr(bone.name).u32(i < boneFlags.size() ? boneFlags[i] : 0).u32(bone.parent).u32(64);
        b.matrix(bone.bind[0], bone.bind[1], bone.bind[2]);
        b.cstr(bone.simulation);
    }
    if (version == 1) {
        b.patchU32(end, 0);
        return;
    }
    b.u16(static_cast<uint32_t>(tail.targets.size()));
    for (const auto& t : tail.targets) b.cstr(t.name).u32(t.bone).u32(t.type).matrix(t.at[0], t.at[1], t.at[2]);
    const bool reference = tail.reference.value_or(version == 2);
    b.u8(reference ? 1 : 0);
    if (reference) {
        for (const auto& bone : bones) b.matrix(bone.reference[0], bone.reference[1], bone.reference[2]);
        for (const auto& t : tail.targets) b.matrix(t.reference[0], t.reference[1], t.reference[2]);
    }
    b.u32(static_cast<uint32_t>(tail.links.size()));
    for (const auto& l : tail.links) {
        b.u32(l.bone).u32(l.a).u32(l.b);
        if (version >= 4) b.u32(l.flags);
        if (version >= 4 && (l.flags & 2)) b.u32(l.c).f32(l.w);
    }
    b.u16(static_cast<uint32_t>(tail.table.size()));
    for (float v : tail.table) b.f32(v);
    for (size_t k = 0; k < tail.table.size(); ++k) {
        const auto none  = std::vector<NeighbourSpec> {};
        const auto& list = k < tail.groups.size() ? tail.groups[k] : none;
        b.u16(static_cast<uint32_t>(list.size()));
        for (const auto& n : list) b.u32(n.bone).f32(n.values[0]).f32(n.values[1]).f32(n.values[2]);
    }
    b.u16(static_cast<uint32_t>(tail.chains.size()));
    for (const auto& c : tail.chains) {
        b.u32(c.bone).u32(static_cast<uint32_t>(c.targets.size()));
        for (uint32_t t : c.targets) b.u32(t);
        b.u16(static_cast<uint32_t>(c.segments.size()));
        for (const auto& s : c.segments) {
            b.u32(s.bone).u16(static_cast<uint32_t>(s.links.size()));
            for (const auto& l : s.links) {
                b.u32(l.a).u32(l.flags).u32(l.b).u32(l.c).u16(static_cast<uint32_t>(l.bones.size()));
                for (uint32_t v : l.bones) b.u32(v);
            }
        }
    }
    b.u8(tail.skin ? 1 : 0);
    if (tail.skin) {
        for (size_t i = 0; i < bones.size(); ++i) {
            b.f32(static_cast<float>(i)).f32(2).f32(3);
            b.matrix(0, 0, 0);
        }
    }
    b.u8(tail.boneTable ? 1 : 0);
    if (tail.boneTable) for (size_t i = 0; i < bones.size(); ++i) b.u32(static_cast<uint32_t>(i));
    if (version >= 3) {
        b.u8(tail.secondBoneTable ? 1 : 0);
        if (tail.secondBoneTable) for (size_t i = 0; i < bones.size(); ++i) b.u32(0);
    }
    b.raw(tail.trailing);
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
    // Tracks stored after the declared ones (one per IK target of the skeleton), and one float
    // curve per link record after those.
    uint32_t storedExtraTracks { 0 };
    uint32_t storedLinkCurves { 0 };
    uint32_t linkCurveFlags { 0 };
    uint32_t skeletonBones { 1 }; // the curve blocks hold one curve per bone
    // The header word after the frame count (anim+80) and, when its bit 0 is set, the clip
    // record after the version-6 curves: source, start, end, origin offset, root bone.
    uint32_t                flags { 0 };
    std::array<uint32_t, 5> clip { 0, 0, 0, 0, 0xFFFFFFFFu };
    // Texture channel records in file order: the leading word, then one weight a frame.
    std::vector<std::pair<uint32_t, std::vector<float>>> channels { { 0, { 0.0f, 1.0f } } };
};

inline void writeCurveBlock(Bytes& b, uint32_t bones = 1) {
    b.u8(1);
    for (uint32_t k = 0; k < bones; ++k) b.u32(0).u32(8).f32(2.0f).f32(3.0f);
}

// One animation record of an MDLA version 6 block for a one-bone skeleton.
inline void writeAnim6(Bytes& b, const AnimSpec& a) {
    b.i32(a.id).u32(0).cstr(a.name).cstr("loop").f32(30.0f).i32(1).u32(a.flags).u32(a.trackCount);
    if (a.headerOnly) return;
    for (uint32_t t = 0; t < a.trackCount + a.storedExtraTracks; ++t) {
        const float x = t < a.trackCount ? static_cast<float>(a.id) : 1000.0f + static_cast<float>(t);
        b.i32(0).u32(36);
        b.f32(x).f32(0).f32(0);  // position
        b.f32(0).f32(0).f32(0);  // angle
        b.f32(1).f32(1).f32(1);  // scale
    }
    for (uint32_t k = 0; k < a.storedLinkCurves; ++k)
        b.u32(a.linkCurveFlags).u32(8).f32(0.5f).f32(0.25f);
    // Version 3: the texture channels (0x140261880: a count, then per channel a word the loader
    // skips and one weight a frame).
    b.u32(static_cast<uint32_t>(a.channels.size()));
    for (const auto& [word, weights] : a.channels) {
        b.u32(word).u32(static_cast<uint32_t>(weights.size() * 4));
        for (float w : weights) b.f32(w);
    }
    writeCurveBlock(b, a.skeletonBones);
    b.u8(1).u32(1).f32(0.5f).u16(1).u16(0).u32(8).f32(2.0f).f32(3.0f);
    b.f32(-1).f32(-1).f32(0).f32(1).f32(1).f32(0);
    if (a.badSecondCurve) {
        b.u8(1).u32(0).u32(6).f32(1.0f).u16(0);
        b.u32(0);
        return;
    }
    writeCurveBlock(b, a.skeletonBones);
    if ((a.flags & 1u) != 0) b.u16(a.clip[0]).u32(a.clip[1]).u32(a.clip[2]).u32(a.clip[3]).u32(a.clip[4]);
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
