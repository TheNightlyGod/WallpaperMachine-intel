// Clean-room implementation from the WallpaperMachine spec p5-models-puppets.md; written without access to the original source.
#include "WPMdlParser.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>

#include "Fs/IBinaryStream.h"
#include "Fs/VFS.h"

#include "SpecTexs.hpp"
#include "WPShaderParser.hpp"
#include "WPPuppetPhysics.hpp"
#include "Scene/SceneIndexArray.h"
#include "Utils/Logging.h"
#include "wpscene/WPMaterial.h"

using namespace wallpaper;

namespace
{
using Range = SceneMesh::DrawRange;

// Vertices are converted in slices so the interleaved copy never needs more
// than one slice of scratch memory next to the final buffer.
constexpr usize kSliceVertices = 8192;

constexpr std::string_view kMaskTarget = "_rt_puppet_mask";
constexpr std::string_view kMaskIntermediateTarget = "_rt_puppet_mask_intermediate";

// A mask is nested in another when every piece it is drawn from is one the other clips:
// Wallpaper Engine links it to the first such mask (`sub_140261880`, record +72), and a
// loop of links leaves the mask that closes it unlinked.
void LinkNestedMasks(std::vector<WPMdl::Mesh::MaskBlock>& masks) {
    for (std::size_t i = 0; i < masks.size(); ++i) {
        auto& mask = masks[i];
        if (mask.part_ids_b.empty()) continue;
        for (std::size_t j = 0; j < masks.size(); ++j) {
            if (j == i) continue;
            const auto& clips = masks[j].part_ids_a;
            const bool  inside = std::all_of(mask.part_ids_b.begin(), mask.part_ids_b.end(), [&](uint32_t part) {
                return std::find(clips.begin(), clips.end(), part) != clips.end();
            });
            if (inside) {
                mask.parent = static_cast<int32_t>(j);
                break;
            }
        }
        std::vector<bool> seen(masks.size(), false);
        seen[i] = true;
        for (int32_t at = mask.parent; at >= 0; at = masks[static_cast<std::size_t>(at)].parent) {
            if (seen[static_cast<std::size_t>(at)]) {
                mask.parent = -1;
                break;
            }
            seen[static_cast<std::size_t>(at)] = true;
        }
    }
}

// A quad covering the whole target, for the pass that multiplies one mask into another.
void GenFullscreenQuad(SceneMesh::Submesh& submesh) {
    const std::vector<SceneVertexArray::SceneVertexAttribute> attrs {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 },
    };
    SceneVertexArray vertices(attrs, 4);
    // Clip space, y up; the target's texture coordinates run down from the top. Each
    // attribute takes four floats of the vertex, padding included, and the indices are
    // sixteen bits, two to a slot (the layout MakeQuadMesh in WPSceneParser.cpp writes).
    const std::array<float, 32> data {
        -1.0f, -1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, //
        1.0f,  -1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 0.0f, 0.0f, //
        1.0f,  1.0f,  0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, //
        -1.0f, 1.0f,  0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
    };
    vertices.SetVertexs(0, data);
    submesh.AddVertexArray(std::move(vertices));
    const std::array<uint16_t, 6> indices { 0, 1, 2, 0, 2, 3 };
    SceneIndexArray index_array(1);
    index_array.AssignHalf(0, indices);
    submesh.AddIndexArray(std::move(index_array));
}

// The one draw range that draws nothing.
std::vector<Range> NoDraw() { return { Range { 0, 0 } }; }

// The draw range of one part when it lies wholly inside the index array.
bool PartRange(const WPMdl::Mesh::Part& part, uint64_t total, Range& out) {
    if (part.size == 0) return false;
    const uint64_t start = part.start;
    const uint64_t end   = start + static_cast<uint64_t>(part.size); // cannot overflow 64 bits
    if (start > total || end > total) return false;
    out = Range { part.start, part.size };
    return true;
}

uint64_t TotalIndices(const WPMdl::Mesh& src) { return static_cast<uint64_t>(src.indices.size()) * 3u; }

// Ranges of the parts whose position in the table `wanted` accepts; nothing
// valid left means the single range that draws nothing.
template<typename Wanted>
std::vector<Range> CollectRanges(const WPMdl::Mesh& src, Wanted&& wanted) {
    std::vector<Range> ranges;
    const uint64_t     total = TotalIndices(src);
    for (usize pos = 0; pos < src.parts.size(); pos++) {
        Range range;
        if (wanted(pos) && PartRange(src.parts[pos], total, range)) ranges.push_back(range);
    }
    if (ranges.empty()) return NoDraw();
    return ranges;
}

template<typename T, usize N>
void Put(float* row, usize offset, const std::vector<std::array<T, N>>& stream, usize vertex,
         const std::array<T, N>& fallback) {
    const auto& value = vertex < stream.size() ? stream[vertex] : fallback;
    std::memcpy(row + offset, value.data(), sizeof(T) * N);
}

static_assert(sizeof(float) == sizeof(uint32_t));
} // namespace

// ---------------------------------------------------------------------------
// Reading a .mdl
//
// The whole file is read into one buffer and converted straight into the
// public records. Every count and size in the file is checked against the
// bytes that are really left (in the file, or in the block that declared it)
// before anything is allocated from it, and all of that arithmetic is 64-bit.
// ---------------------------------------------------------------------------
namespace
{
static_assert(std::endian::native == std::endian::little, "mdl files are little-endian");

// Sanity caps. They sit well above anything a real file needs (a file holds up
// to 64 meshes; the biggest known mesh has 3,144,456 vertices and 2,137,728
// triangles) and are always applied together with the bytes actually present.
constexpr uint32_t kMinVersion        = 13;
constexpr uint32_t kMaxVersion        = 23;
constexpr uint32_t kMaxMeshes         = 4096;
constexpr uint64_t kMaxVertices       = 1ull << 25;
constexpr uint64_t kMaxTriangles      = 1ull << 24;
constexpr uint64_t kMaxParts          = 1ull << 20;
constexpr uint32_t kMaxMasks          = 4096;
constexpr uint32_t kMaxMaskEntries    = 1u << 20;
constexpr uint32_t kMaxAnimations     = 1u << 16;
constexpr uint32_t kMaxTracks         = 1u << 17;
constexpr uint64_t kMaxFloatArray     = 1ull << 26; // floats in one curve or event array
constexpr uint32_t kMaxEvents         = 1u << 20;
constexpr uint32_t kNarrowIndexLimit  = 65535; // up to this many vertices the indices are 16-bit


// A bounded cursor over a byte buffer. A read past `limit` fails the cursor
// (`ok` turns false and stays false) and yields zero, so a parser can read a
// run of fields and test once.
struct Cursor {
    const uint8_t* data { nullptr };
    uint64_t       pos { 0 };
    uint64_t       limit { 0 };
    bool           ok { true };

    uint64_t left() const { return pos < limit ? limit - pos : 0; }
    bool     need(uint64_t bytes) {
        if (! ok || bytes > left()) ok = false;
        return ok;
    }
    template<typename T>
    T get() {
        T value {};
        if (! need(sizeof(T))) return value;
        std::memcpy(&value, data + pos, sizeof(T));
        pos += sizeof(T);
        return value;
    }
    uint8_t  u8() { return get<uint8_t>(); }
    uint16_t u16() { return get<uint16_t>(); }
    uint32_t u32() { return get<uint32_t>(); }
    int32_t  i32() { return get<int32_t>(); }
    float    f32() { return get<float>(); }
    void     skip(uint64_t bytes) {
        if (need(bytes)) pos += bytes;
    }
    // A zero-terminated string that ends inside the limit.
    std::string cstr() {
        if (! ok) return {};
        const void* end = std::memchr(data + pos, 0, static_cast<size_t>(left()));
        if (end == nullptr) {
            ok = false;
            return {};
        }
        const auto length = static_cast<uint64_t>(static_cast<const uint8_t*>(end) - (data + pos));
        std::string text(reinterpret_cast<const char*>(data + pos), static_cast<size_t>(length));
        pos += length + 1;
        return text;
    }
    // `count` floats copied out; the caller has already bounded `count`.
    std::vector<float> floats(uint64_t count) {
        std::vector<float> out;
        if (! need(count * sizeof(float))) return out;
        out.resize(static_cast<size_t>(count));
        if (count > 0) std::memcpy(out.data(), data + pos, static_cast<size_t>(count) * sizeof(float));
        pos += count * sizeof(float);
        return out;
    }
};

// A 4x4 file matrix (column-major, 16 floats) as the affine the runtime uses.
// False when a value is not finite.
bool ReadMatrix(Cursor& c, linalg::Affine3f& out) {
    float values[16];
    for (float& value : values) value = c.f32();
    if (! c.ok) return false;
    out = linalg::Affine3f::Identity();
    for (int col = 0; col < 4; col++) {
        for (int row = 0; row < 3; row++) {
            if (! std::isfinite(values[col * 4 + row])) return false;
            out(row, col) = values[col * 4 + row];
        }
    }
    return true;
}

bool IsDigit(uint8_t ch) { return ch >= '0' && ch <= '9'; }

enum class StampKind { Absent, Malformed, Present };

// Whether a block called `name` starts at `pos`: four letters, four decimal
// digits, one zero byte. A matching name with an unreadable remainder is
// reported separately, because it is a block that cannot be skipped over.
StampKind LookAtStamp(const std::vector<uint8_t>& file, uint64_t pos, const char* name,
                      int& version) {
    if (pos + 4 > file.size() || std::memcmp(file.data() + pos, name, 4) != 0) {
        return StampKind::Absent;
    }
    if (pos + 9 > file.size()) return StampKind::Malformed;
    version = 0;
    for (int i = 4; i < 8; i++) {
        if (! IsDigit(file[pos + static_cast<uint64_t>(i)])) return StampKind::Malformed;
        version = version * 10 + (file[pos + static_cast<uint64_t>(i)] - '0');
    }
    return file[pos + 8] == 0 ? StampKind::Present : StampKind::Malformed;
}

// Any block stamp at all (used to tell a skeleton tail from the next block).
bool LooksLikeAnyStamp(const Cursor& c) {
    if (c.left() < 9) return false;
    const uint8_t* p = c.data + c.pos;
    if (p[0] != 'M' || p[1] != 'D') return false;
    for (int i = 2; i < 4; i++)
        if (p[i] < 'A' || p[i] > 'Z') return false;
    for (int i = 4; i < 8; i++)
        if (! IsDigit(p[i])) return false;
    return p[8] == 0;
}

struct Block {
    int      version { 0 };
    uint64_t end { 0 };   // absolute offset of the first byte after the block
    bool     valid { false };
};

// The end offset of a block whose stamp is at `pos`. Valid when it lies after
// the offset field itself and not beyond the file; a zero is accepted only
// where the caller allows it.
Block ReadBlockHeader(const std::vector<uint8_t>& file, uint64_t pos, int version,
                      bool allow_zero_end) {
    Block block;
    block.version = version;
    if (pos + 13 > file.size()) return block;
    uint32_t end = 0;
    std::memcpy(&end, file.data() + pos + 9, sizeof(end));
    block.end   = end;
    block.valid = (end == 0 && allow_zero_end) || (end > pos + 13 && end <= file.size());
    return block;
}

uint64_t SkipZeros(const std::vector<uint8_t>& file, uint64_t pos) {
    while (pos < file.size() && file[pos] == 0) pos++;
    return pos;
}

// The 26 vertex bits of a mesh flag word in Wallpaper Engine's record order: mask table
// xmmword_140484A20 / size table xmmword_1404849B0, summed by sub_1400EA5B0 for the stride and
// by sub_140266FA0 for an attribute's offset; semantics from the input layout sub_1400D7B60
// (B-D7). A bit outside the table adds nothing to the record, as in WE.
constexpr std::array<WPMdlVertexBit, 26> kVertexBits { {
    { 0x00000001u, 12, "a_Position" },
    { 0x00010000u, 16, "a_PositionVec4" },
    { 0x02000000u, 12, "a_PositionC1" },
    { 0x00000002u, 12, "a_Normal" },
    { 0x00000004u, 16, "a_Tangent4" },
    { 0x00800000u, 16, "a_BlendIndices" },
    { 0x01000000u, 16, "a_BlendWeights" },
    { 0x00000008u, 8, "a_TexCoord" },
    { 0x00000010u, 12, "a_TexCoordVec3" },
    { 0x00000020u, 16, "a_TexCoordVec4" },
    { 0x00000040u, 8, "a_TexCoordC1" },
    { 0x00000080u, 12, "a_TexCoordVec3C1" },
    { 0x00000100u, 16, "a_TexCoordVec4C1" },
    { 0x00000200u, 8, "a_TexCoordC2" },
    { 0x00000400u, 12, "a_TexCoordVec3C2" },
    { 0x00000800u, 16, "a_TexCoordVec4C2" },
    { 0x00001000u, 8, "a_TexCoordC3" },
    { 0x00002000u, 12, "a_TexCoordVec3C3" },
    { 0x00004000u, 16, "a_TexCoordVec4C3" },
    { 0x00020000u, 8, "a_TexCoordC4" },
    { 0x00040000u, 12, "a_TexCoordVec3C4" },
    { 0x00080000u, 16, "a_TexCoordVec4C4" },
    { 0x00100000u, 8, "a_TexCoordC5" },
    { 0x00200000u, 12, "a_TexCoordVec3C5" },
    { 0x00400000u, 16, "a_TexCoordVec4C5" },
    { 0x00008000u, 16, "a_Color" },
} };

constexpr uint32_t kBitPosition     = 0x00000001u;
constexpr uint32_t kBitPositionVec4 = 0x00010000u;
constexpr uint32_t kBitNormal       = 0x00000002u;
constexpr uint32_t kBitTangent      = 0x00000004u;
constexpr uint32_t kBitBones        = 0x00800000u;
constexpr uint32_t kBitWeights      = 0x01000000u;

uint64_t StrideOf(uint32_t flag) {
    uint64_t stride = 0;
    for (const auto& bit : kVertexBits)
        if ((flag & bit.mask) != 0) stride += bit.bytes;
    return stride;
}

// What the smallest possible mesh record needs, by file version.
uint64_t MinMeshBytes(uint32_t version) {
    uint64_t bytes = 1 + 4 + 4 + 4; // material terminator, variant, vertex size, index size
    if (version >= 17) bytes += 24;
    if (version >= 15) bytes += 4;
    if (version >= 21) bytes += 2;
    if (version >= 22) bytes += 4;
    return bytes;
}

// One mesh record. On failure the reason has been logged.
bool ReadMesh(Cursor& c, uint32_t version, uint32_t header_flag, const char* path,
              WPMdl::Mesh& mesh) {
    mesh.mat_json_file = c.cstr();
    mesh.flag_a        = c.u32();
    // we_LoadMdlModel 0x140261880: from MDLV 4 the mesh flag word (mesh+24) is read, and bit 2
    // is followed by one more word. Bit 4 is SKINNING_ALPHA (0x140206AE0), bit 0x2000
    // MORPHING_MODIFIERS.
    if (c.ok && (mesh.flag_a & 2) != 0) mesh.has_flag_a2_one = c.u32() == 1;
    if (version >= 17) {
        for (float& v : mesh.aabb_min) v = c.f32();
        for (float& v : mesh.aabb_max) v = c.f32();
        mesh.has_aabb = c.ok;
    }
    mesh.flag = version >= 15 ? c.u32() : header_flag;
    const uint32_t vertex_bytes = c.u32();
    if (! c.ok) {
        LOG_ERROR("model %s is not complete: the mesh header is cut short", path);
        return false;
    }

    const uint64_t stride = StrideOf(mesh.flag);
    if (stride == 0 ? vertex_bytes != 0 : vertex_bytes % stride != 0) {
        LOG_ERROR("model %s: vertex data of %u bytes is not a whole number of %u-byte vertices",
                  path, vertex_bytes, static_cast<unsigned>(stride));
        return false;
    }
    const uint64_t vertex_count = stride == 0 ? 0 : vertex_bytes / stride;
    if (vertex_count > kMaxVertices) {
        LOG_ERROR("model %s: a mesh of %llu vertices is over the limit", path,
                  static_cast<unsigned long long>(vertex_count));
        return false;
    }
    if (vertex_bytes > c.left()) {
        LOG_ERROR("model %s is not complete: %u bytes of vertices declared, %llu left", path,
                  vertex_bytes, static_cast<unsigned long long>(c.left()));
        return false;
    }

    const auto n = static_cast<size_t>(vertex_count);
    // The typed streams the runtime reads directly; every other bit is kept as a float stream.
    std::vector<WPMdl::Mesh::Stream*> generic(kVertexBits.size(), nullptr);
    for (size_t b = 0; b < kVertexBits.size(); b++) {
        const auto& bit = kVertexBits[b];
        if ((mesh.flag & bit.mask) == 0) continue;
        switch (bit.mask) {
        case kBitPosition: mesh.positions.resize(n); break;
        case kBitNormal: mesh.normals.resize(n); break;
        case kBitTangent: mesh.tangents.resize(n); break;
        case kBitBones: mesh.blend_indices.resize(n); break;
        case kBitWeights: mesh.blend_weights.resize(n); break;
        default: {
            auto& stream  = mesh.streams.emplace_back();
            stream.mask   = bit.mask;
            stream.width  = static_cast<uint8_t>(bit.bytes / 4);
            stream.values.resize(n * stream.width);
        }
        }
    }
    for (size_t b = 0, s = 0; b < kVertexBits.size(); b++) {
        if ((mesh.flag & kVertexBits[b].mask) == 0) continue;
        const uint32_t mask = kVertexBits[b].mask;
        if (mask != kBitPosition && mask != kBitNormal && mask != kBitTangent && mask != kBitBones &&
            mask != kBitWeights)
            generic[b] = &mesh.streams[s++];
    }
    const uint8_t* at = c.data + c.pos;
    auto           copy = [&at](void* dst, size_t bytes) {
        std::memcpy(dst, at, bytes);
        at += bytes;
    };
    for (size_t i = 0; i < n; i++) {
        for (size_t b = 0; b < kVertexBits.size(); b++) {
            const auto& bit = kVertexBits[b];
            if ((mesh.flag & bit.mask) == 0) continue;
            switch (bit.mask) {
            case kBitPosition: copy(mesh.positions[i].data(), 12); break;
            case kBitNormal: copy(mesh.normals[i].data(), 12); break;
            case kBitTangent: copy(mesh.tangents[i].data(), 16); break;
            case kBitBones: copy(mesh.blend_indices[i].data(), 16); break;
            case kBitWeights: copy(mesh.blend_weights[i].data(), 16); break;
            default: copy(generic[b]->values.data() + i * generic[b]->width, bit.bytes);
            }
        }
    }
    // A mesh with only the four-wide position (the morph layout) keeps its xyz as the position.
    if (mesh.positions.empty()) {
        if (const auto* vec4 = mesh.FindStream(kBitPositionVec4)) {
            mesh.positions.resize(n);
            for (size_t i = 0; i < n; i++)
                std::copy_n(vec4->values.data() + i * 4, 3, mesh.positions[i].data());
        }
    }
    c.pos += vertex_bytes;

    // Indices: 16 bits per index up to 65,535 vertices, 32 bits above.
    const uint32_t index_bytes = c.u32();
    if (! c.ok) {
        LOG_ERROR("model %s is not complete: the index size is missing", path);
        return false;
    }
    const uint64_t width    = vertex_count > kNarrowIndexLimit ? 4 : 2;
    const uint64_t triangle = 3 * width;
    if (index_bytes % triangle != 0) {
        LOG_ERROR("model %s: %u bytes of indices are not a whole number of triangles", path,
                  index_bytes);
        return false;
    }
    const uint64_t triangles = index_bytes / triangle;
    if (triangles > kMaxTriangles) {
        LOG_ERROR("model %s: %llu triangles are over the limit", path,
                  static_cast<unsigned long long>(triangles));
        return false;
    }
    if (index_bytes > c.left()) {
        LOG_ERROR("model %s is not complete: %u bytes of indices declared, %llu left", path,
                  index_bytes, static_cast<unsigned long long>(c.left()));
        return false;
    }
    if (vertex_count > 0) {
        mesh.indices.resize(static_cast<size_t>(triangles));
        const uint8_t* src = c.data + c.pos;
        for (auto& tri : mesh.indices) {
            for (uint32_t& index : tri) {
                if (width == 4) {
                    std::memcpy(&index, src, 4);
                } else {
                    uint16_t narrow;
                    std::memcpy(&narrow, src, 2);
                    index = narrow;
                }
                src += width;
                if (index >= vertex_count) {
                    LOG_ERROR("model %s: an index names vertex %u of %llu", path, index,
                              static_cast<unsigned long long>(vertex_count));
                    return false;
                }
            }
        }
    }
    c.pos += index_bytes;

    if (version >= 21) {
        const uint8_t extras = c.u8();
        if (! c.ok) {
            LOG_ERROR("model %s is not complete: the parts header is missing", path);
            return false;
        }
        if (extras > 1) {
            LOG_ERROR("model %s: the parts flag byte is %u, only 0 and 1 are valid", path, extras);
            return false;
        }
        if (extras == 1) {
            const uint8_t has_payload = c.u8();
            if (c.ok && has_payload != 0) {
                c.u16();
                c.u8();
                const uint32_t payload = c.u32();
                if (! c.ok || payload != vertex_count * 12u || ! c.need(payload)) {
                    LOG_ERROR("model %s: the second texture-coordinate payload of %u bytes does "
                              "not fit %llu vertices", path, payload,
                              static_cast<unsigned long long>(vertex_count));
                    return false;
                }
                mesh.part_uv2.resize(n);
                mesh.part_uv2_pad.resize(n);
                for (size_t i = 0; i < n; i++) {
                    mesh.part_uv2[i][0]  = c.f32();
                    mesh.part_uv2[i][1]  = c.f32();
                    mesh.part_uv2_pad[i] = c.u32();
                }
            }
        }
        const uint8_t has_parts = c.u8();
        if (! c.ok) {
            LOG_ERROR("model %s is not complete: the parts table is missing", path);
            return false;
        }
        if (has_parts != 0) {
            const uint32_t bytes = c.u32();
            if (! c.ok || bytes % 16 != 0 || bytes / 16 > kMaxParts || ! c.need(bytes)) {
                LOG_ERROR("model %s: the parts table of %u bytes is not valid", path, bytes);
                return false;
            }
            mesh.parts.resize(bytes / 16);
            for (auto& part : mesh.parts) {
                part.id = c.u32();
                c.u32();
                part.start = c.u32();
                part.size  = c.u32();
            }
        }
    }

    if (version >= 22) {
        const uint32_t mask_count = c.u32();
        // A mask record is at least: three words, a terminator and two list counts.
        if (! c.ok || mask_count > kMaxMasks || static_cast<uint64_t>(mask_count) * 21 > c.left()) {
            LOG_ERROR("model %s is not complete: %u masks cannot fit in the file", path, mask_count);
            return false;
        }
        for (uint32_t m = 0; m < mask_count; m++) {
            auto& mask     = mesh.masks.emplace_back();
            mask.leading_a = c.u32();
            c.u32();
            mask.mat_json_file = c.cstr();
            mask.flags = c.u32();
            for (auto* list : { &mask.part_ids_a, &mask.part_ids_b }) {
                const uint32_t entries = c.u32();
                if (! c.ok || entries > kMaxMaskEntries ||
                    static_cast<uint64_t>(entries) * 4 > c.left()) {
                    LOG_ERROR("model %s is not complete: a mask lists %u parts that cannot fit",
                              path, entries);
                    return false;
                }
                list->resize(entries);
                for (uint32_t& value : *list) value = c.u32();
            }
            if (! c.ok) {
                LOG_ERROR("model %s is not complete: a mask record is cut short", path);
                return false;
            }
        }
        LinkNestedMasks(mesh.masks);
    }
    if (! c.ok) {
        LOG_ERROR("model %s is not complete: the mesh record is cut short", path);
        return false;
    }
    return true;
}

// The inverse-kinematics description of an MDLS block of version 2 on, in the order
// Wallpaper Engine reads it (we_LoadMdlModel 0x140261880, 0x1402625da..0x14026342a):
// N targets, the reference pose (bones, then targets), M links, the K table and its
// groups, then P chains. False when it is malformed (nothing of it is kept but a whole
// reference pose); `fatal` when an announced reference pose is not whole.
bool ReadIkTail(Cursor& t, int version, uint32_t bones, const char* path, WPPuppet& puppet,
                bool& fatal) {
    // Wallpaper Engine reads a count the block has no bytes left for as zero
    // (`(v95 - v93 + 4 <= v94) ? *v95++ : 0`), so a tail that stops early is an empty one.
    const auto count = [&t](auto zero) -> decltype(zero) {
        return t.ok && t.left() < sizeof(zero) ? decltype(zero) {} : t.get<decltype(zero)>();
    };
    std::vector<WPPuppet::IkTarget> targets(count(uint16_t {}));
    // A target is at least a terminator, two words and a matrix.
    if (! t.ok || static_cast<uint64_t>(targets.size()) * 73 > t.left()) return false;
    for (auto& target : targets) {
        target.name = t.cstr();
        target.bone = t.u32();
        target.type = t.u32();
        if (! ReadMatrix(t, target.matrix)) return false;
        if (target.bone >= bones) {
            LOG_INFO("model %s: IK target \"%s\" names bone %u of %u", path, target.name.c_str(),
                     target.bone, bones);
        }
    }
    const uint8_t has_reference = count(uint8_t {});
    if (! t.ok) return false;
    if (has_reference != 0) {
        if (! t.need((static_cast<uint64_t>(bones) + targets.size()) * 64)) {
            LOG_ERROR("model %s is not complete: the reference pose is cut short", path);
            fatal = true;
            return false;
        }
        for (auto& bone : puppet.bones) {
            if (! ReadMatrix(t, bone.local_reference)) {
                LOG_ERROR("model %s: a reference matrix is not finite", path);
                fatal = true;
                return false;
            }
            bone.has_local_reference = true;
        }
        for (auto& target : targets) {
            if (! ReadMatrix(t, target.reference)) {
                LOG_ERROR("model %s: a reference matrix is not finite", path);
                fatal = true;
                return false;
            }
            target.has_reference = true;
        }
    }

    const uint32_t link_count = count(uint32_t {});
    if (! t.ok || static_cast<uint64_t>(link_count) * 12 > t.left()) return false;
    std::vector<WPPuppet::BoneLink> links(link_count);
    for (auto& link : links) {
        link.bone   = t.u32();
        link.link_a = t.u32();
        link.link_b = t.u32();
        if (version >= 4) link.flags = t.u32();
        if ((link.flags & 2) != 0) {
            link.extra_u32 = t.u32();
            // 0x140262947: a weight below FLT_EPSILON is raised to it.
            link.extra_f32 = std::max(t.f32(), std::numeric_limits<float>::epsilon());
        }
    }

    const uint16_t table_size = count(uint16_t {});
    if (! t.need(static_cast<uint64_t>(table_size) * 4)) return false;
    std::vector<float> table = t.floats(table_size);
    std::vector<std::vector<WPPuppet::BoneNeighbour>> groups(table_size);
    for (auto& group : groups) {
        group.resize(t.u16());
        if (! t.ok || static_cast<uint64_t>(group.size()) * 16 > t.left()) return false;
        for (auto& neighbour : group) {
            neighbour.bone = t.u32();
            for (float& value : neighbour.values) value = t.f32();
        }
    }

    std::vector<WPPuppet::IkChain> chains(count(uint16_t {}));
    if (! t.ok || static_cast<uint64_t>(chains.size()) * 10 > t.left()) return false;
    for (auto& chain : chains) {
        chain.bone                  = t.u32();
        const uint32_t target_count = t.u32();
        if (! t.ok || chain.bone >= bones || static_cast<uint64_t>(target_count) * 4 > t.left()) {
            return false;
        }
        chain.targets.resize(target_count);
        for (uint32_t& target : chain.targets) {
            target = t.u32();
            if (target >= targets.size()) return false; // Wallpaper Engine fails the load
        }
        chain.segments.resize(t.u16());
        if (! t.ok || static_cast<uint64_t>(chain.segments.size()) * 6 > t.left()) return false;
        for (auto& segment : chain.segments) {
            segment.bone = t.u32();
            segment.links.resize(t.u16());
            if (! t.ok || segment.bone >= bones ||
                static_cast<uint64_t>(segment.links.size()) * 18 > t.left()) {
                return false;
            }
            for (auto& link : segment.links) {
                link.a     = t.u32();
                link.flags = t.u32();
                link.b     = t.u32();
                link.c     = t.u32();
                link.bones.resize(t.u16());
                if (! t.ok || static_cast<uint64_t>(link.bones.size()) * 4 > t.left()) return false;
                for (uint32_t& bone : link.bones) {
                    bone = t.u32();
                    if (bone >= bones) return false;
                }
            }
        }
    }
    if (! t.ok) return false;
    puppet.ik_targets      = std::move(targets);
    puppet.bone_links      = std::move(links);
    puppet.bone_table      = std::move(table);
    puppet.bone_neighbours = std::move(groups);
    puppet.ik_chains       = std::move(chains);
    return true;
}

// The skeleton block. `pos` is at its stamp; on success it is left after the block.
bool ReadSkeleton(const std::vector<uint8_t>& file, uint64_t& pos, const Block& block,
                  const char* path, WPPuppet& puppet) {
    const int      version = block.version;
    const uint64_t limit   = block.end == 0 ? file.size() : block.end;
    Cursor         c { file.data(), pos + 13, limit };

    const uint16_t bone_count = c.u16();
    c.u16();
    // A bone record is at least a terminator, two words, the matrix size, 64 bytes of matrix and a
    // second terminator.
    if (! c.ok || static_cast<uint64_t>(bone_count) * 78 > c.left()) {
        LOG_ERROR("model %s: the skeleton declares %u bones that cannot fit", path, bone_count);
        return false;
    }
    for (uint32_t i = 0; i < bone_count; i++) {
        auto& bone       = puppet.bones.emplace_back();
        bone.name        = c.cstr();
        bone.sim_type    = c.i32();
        uint32_t parent  = c.u32();
        const uint32_t matrix_bytes = c.u32();
        if (c.ok && matrix_bytes != 64) {
            LOG_ERROR("model %s: bone %u has a matrix of %u bytes", path, i, matrix_bytes);
            return false;
        }
        if (! ReadMatrix(c, bone.local_bind)) {
            LOG_ERROR(c.ok ? "model %s: bone %u has a bind matrix that is not finite"
                           : "model %s is not complete: bone %u is cut short", path, i);
            return false;
        }
        // The text after the matrix is the bone's simulation settings (0x1402625a9).
        ParseBoneSimulation(c.cstr(), bone.simulation);
        if (! c.ok) {
            LOG_ERROR("model %s is not complete: bone %u is cut short", path, i);
            return false;
        }
        if (parent != WPPuppet::NO_PARENT && parent >= i) {
            LOG_INFO("model %s: bone %u names parent %u that is not before it; treated as a root",
                     path, i, parent);
            parent = WPPuppet::NO_PARENT;
        }
        bone.parent = bone.bind_parent = bone.anim_parent = bone.file_parent = parent;
    }

    // The tail is metadata: a malformed one is ignored, except a reference pose
    // that is announced and not whole, which changes how the model rests.
    const bool no_declared_end = block.end == 0;
    auto       more = [&](const Cursor& t) {
        return t.ok && t.left() > 0 && (! no_declared_end || ! LooksLikeAnyStamp(t));
    };
    Cursor tail  = c;
    bool   clean = true;
    if (version >= 2 && more(tail)) {
        bool fatal = false;
        clean      = ReadIkTail(tail, version, bone_count, path, puppet, fatal);
        if (fatal) return false;
        if (clean && more(tail)) {
            const uint8_t has_skin = tail.u8();
            if (tail.ok && has_skin != 0) {
                if (tail.need(static_cast<uint64_t>(bone_count) * 76)) {
                    for (auto& bone : puppet.bones) {
                        for (int k = 0; k < 3; k++) bone.file_skin_pivot(k) = tail.f32();
                        for (int col = 0; col < 4; col++)
                            for (int row = 0; row < 4; row++)
                                bone.file_skin_mat.elem(row, col) = tail.f32();
                        bone.has_file_skin_pivot = true;
                    }
                }
            }
        }
        // Cursor picking walks the first bone-order table backwards (0x1401FD690).
        // Its loader clamps each index to the last bone (0x140263607).
        if (clean && tail.ok && more(tail)) {
            const uint8_t has_table = tail.u8();
            if (tail.ok && has_table != 0 && tail.need(static_cast<uint64_t>(bone_count) * 4)) {
                puppet.hit_box_order.resize(bone_count);
                for (auto& bone : puppet.hit_box_order) bone = std::min<uint32_t>(tail.u32(), bone_count - 1);
            }
        }
        // The second table has a separate native role; it is not the cursor order.
        if (clean && tail.ok && version >= 3 && more(tail)) {
            const uint8_t has_table = tail.u8();
            if (tail.ok && has_table != 0) tail.skip(static_cast<uint64_t>(bone_count) * 4);
        }
        clean = clean && tail.ok;
        if (! clean) LOG_INFO("model %s: the skeleton tail is malformed; the rest of it is ignored", path);
    }
    if (block.end != 0) {
        if (clean && tail.pos != block.end) {
            LOG_INFO("model %s: the skeleton body ended at %llu, its declared end is %llu", path,
                     static_cast<unsigned long long>(tail.pos),
                     static_cast<unsigned long long>(block.end));
        }
        pos = block.end;
    } else {
        pos = tail.ok ? tail.pos : c.pos;
    }
    return true;
}

bool ReadAttachments(const std::vector<uint8_t>& file, uint64_t& pos, const Block& block,
                     const char* path, WPPuppet& puppet) {
    Cursor c { file.data(), pos + 13, block.end };
    const uint16_t count = c.u16();
    // bone index, terminator, 64 bytes of matrix
    if (! c.ok || static_cast<uint64_t>(count) * 67 > c.left()) {
        LOG_ERROR("model %s: %u attachments cannot fit in their block", path, count);
        return false;
    }
    for (uint16_t i = 0; i < count; i++) {
        auto& attachment      = puppet.attachments.emplace_back();
        attachment.bone_index = c.u16();
        attachment.name       = c.cstr();
        if (! c.ok || ! c.need(64) || ! ReadMatrix(c, attachment.local_xform)) {
            LOG_ERROR("model %s: an attachment is cut short or has a matrix that is not finite", path);
            return false;
        }
    }
    if (c.pos != block.end) {
        LOG_INFO("model %s: the attachment body ended at %llu, its declared end is %llu", path,
                 static_cast<unsigned long long>(c.pos), static_cast<unsigned long long>(block.end));
    }
    pos = block.end;
    return true;
}

// ----- animations -----

struct AnimationDecode {
    bool                            ok { false };
    bool                            exact { false };
    bool                            had_empty_name { false };
    std::vector<WPPuppet::Animation> anims;
    std::string                     error;
};

// One per-bone scalar curve block: a flag, then one array per declared bone.
bool ReadCurveBlock(Cursor& c, uint32_t bone_count, std::vector<WPPuppet::Animation::BoneFrameCurve>& out,
                    std::string& error) {
    out.clear();
    const uint8_t present = c.u8();
    if (! c.ok || present == 0) return c.ok;
    if (static_cast<uint64_t>(bone_count) * 8 > c.left()) {
        error = "MDLA curve count cannot fit";
        return false;
    }
    for (uint32_t b = 0; b < bone_count; b++) {
        auto& curve = out.emplace_back();
        c.u32();
        const uint32_t bytes = c.u32();
        if (! c.ok || bytes % 4 != 0 || bytes / 4 > kMaxFloatArray || ! c.need(bytes)) {
            error = "MDLA curve array is malformed";
            return false;
        }
        curve.values = c.floats(bytes / 4);
    }
    return c.ok;
}

// A float array preceded by its byte size.
bool ReadFloatArray(Cursor& c, std::vector<float>& out, std::string& error) {
    const uint32_t bytes = c.u32();
    if (! c.ok || bytes % 4 != 0 || bytes / 4 > kMaxFloatArray || ! c.need(bytes)) {
        error = "MDLA float array is malformed";
        return false;
    }
    out = c.floats(bytes / 4);
    return c.ok;
}

// One track: a flag word, then its frames (nine floats each).
bool ReadTrack(Cursor& c, uint32_t index, WPPuppet::Animation::BoneTrack& track) {
    track.bone_index     = index;
    track.unk            = c.i32();
    const uint32_t bytes = c.u32();
    if (! c.ok || bytes % 36 != 0 || ! c.need(bytes)) return false;
    track.frames.resize(bytes / 36);
    for (auto& frame : track.frames) {
        for (int k = 0; k < 3; k++) frame.position(k) = c.f32();
        for (int k = 0; k < 3; k++) frame.angle(k) = c.f32();
        for (int k = 0; k < 3; k++) frame.scale(k) = c.f32();
    }
    return true;
}

// From MDLA version 2 an animation holds, after its declared bone tracks, one track per IK
// target of the skeleton and one float curve per link record (0x140263cc3..0x140263f7f).
AnimationDecode DecodeAnimations(Cursor c, uint32_t count, int version, uint32_t bone_count,
                                 uint32_t target_tracks, uint32_t link_curves, uint32_t mesh_count,
                                 bool empty_name_is_name) {
    AnimationDecode result;
    auto fail = [&](std::string message) {
        if (result.error.empty()) result.error = std::move(message);
        result.ok = false;
        return result;
    };
    for (uint32_t a = 0; a < count; a++) {
        WPPuppet::Animation anim {};
        anim.fps = 0;
        anim.length = 0;
        anim.mode = WPPuppet::PlayMode::Loop;
        anim.max_time = anim.frame_time = 0;
        anim.id = c.i32();
        anim.unk_after_id = c.u32();
        anim.name = c.cstr();
        std::string mode;
        if (anim.name.empty()) {
            result.had_empty_name = true;
            if (empty_name_is_name) {
                mode = c.cstr();
            } else {
                // The empty string was padding: the name and then the mode follow.
                anim.name = c.cstr();
                mode      = c.cstr();
            }
        } else {
            mode = c.cstr();
        }
        anim.fps    = c.f32();
        anim.length = c.i32();
        anim.flags = c.u32(); // anim+80 (0x140263a47)
        const uint32_t declared = c.u32();
        if (! c.ok) return fail("MDLA animation header is cut short");
        if (anim.id <= 0) return fail("MDLA animation id is not positive");
        if (mode == "mirror") {
            anim.mode = WPPuppet::PlayMode::Mirror;
        } else if (mode == "single") {
            anim.mode = WPPuppet::PlayMode::Single;
        } else if (! mode.empty() && mode != "loop") {
            LOG_INFO("MDLA animation %d has the unknown mode \"%s\"; playing it as a loop", anim.id,
                     mode.c_str());
        }

        if (declared > kMaxTracks || static_cast<uint64_t>(declared) * 8 > c.left()) {
            return fail("MDLA bone track count " + std::to_string(declared) + " cannot fit");
        }
        anim.bone_tracks.resize(declared);
        for (uint32_t t = 0; t < declared; t++) {
            if (! ReadTrack(c, t, anim.bone_tracks[t])) return fail("MDLA bone track is malformed");
        }
        if (version >= 2) {
            if (static_cast<uint64_t>(target_tracks + link_curves) * 8 > c.left()) {
                return fail("MDLA IK target tracks cannot fit");
            }
            anim.target_tracks.resize(target_tracks);
            for (uint32_t t = 0; t < target_tracks; t++) {
                if (! ReadTrack(c, t, anim.target_tracks[t])) return fail("MDLA IK target track is malformed");
            }
            anim.link_curves.resize(link_curves);
            for (auto& curve : anim.link_curves) {
                curve.flags = c.u32();
                std::string error;
                if (! ReadFloatArray(c, curve.values, error)) return fail(error);
            }
        }
        std::string error;
        if (version >= 3) {
            // The texture channels: a count, then per channel a word Wallpaper Engine does not
            // use and the channel's weight a frame.
            const uint32_t channels = c.u32();
            if (! c.ok || static_cast<uint64_t>(channels) * 8 > c.left()) {
                return fail("MDLA texture channel count cannot fit");
            }
            anim.texture_channels.resize(channels);
            for (auto& weights : anim.texture_channels) {
                c.u32();
                if (! ReadFloatArray(c, weights, error)) return fail(error);
                // A weight that is not a number paints nothing.
                for (float& weight : weights) {
                    if (! std::isfinite(weight)) weight = 0.0f;
                }
            }
            if (! ReadCurveBlock(c, bone_count, anim.blend_curves, error)) {
                return fail(error.empty() ? "MDLA curve block is cut short" : error);
            }
        }
        if (version >= 4) {
            const uint8_t has_morphs = c.u8();
            if (c.ok && has_morphs != 0) {
                // 0x140264A18..0x140264CEF: one record per mesh, with no count
                // after the presence byte. A disabled record contains only its flags.
                if (uint64_t(mesh_count) * 4 > c.left()) return fail("MDLA morph meshes are cut short");
                anim.morph_tracks.resize(mesh_count);
                for (auto& mesh : anim.morph_tracks) {
                    mesh.flags = c.u32();
                    if ((mesh.flags & 1u) == 0) continue;
                    mesh.scale = c.f32();
                    const uint32_t curves = c.u16();
                    if (!c.ok || !std::isfinite(mesh.scale) || uint64_t(curves) * 6 > c.left())
                        return fail("MDLA morph curve count cannot fit");
                    mesh.curves.resize(curves);
                    for (auto& curve : mesh.curves) {
                        curve.shape = static_cast<uint16_t>(c.u16());
                        if (!ReadFloatArray(c, curve.values, error)) return fail(error);
                        if (anim.length < 0 || curve.values.size() != uint64_t(anim.length) + 1)
                            return fail("MDLA morph curve does not cover its animation");
                    }
                }
            }
            if (! c.ok) return fail("MDLA morph channels are cut short");
        }
        if (version >= 5) {
            for (float& v : anim.aabb_min) v = c.f32();
            for (float& v : anim.aabb_max) v = c.f32();
            anim.has_aabb = c.ok;
        }
        if (version == 6) {
            if (! ReadCurveBlock(c, bone_count, anim.scalar_curves, error)) {
                return fail(error.empty() ? "MDLA curve block is cut short" : error);
            }
        }
        if ((anim.flags & WPPuppet::kAnimClip) != 0) {
            // 0x140264fd0..0x14026513d: u16 source, u32 start, end, origin offset, root bone.
            WPPuppet::Animation::Clip clip;
            clip.source        = static_cast<uint16_t>(c.u16());
            clip.start         = c.u32();
            clip.end           = c.u32();
            clip.origin_offset = c.u32();
            clip.bone          = c.u32();
            if (! c.ok) return fail("MDLA clip record is cut short");
            // 0x140265196: the source is an animation already read from this block.
            if (clip.source >= result.anims.size()) {
                return fail("MDLA clip source " + std::to_string(clip.source) +
                            " is not an earlier animation");
            }
            // 0x140265238 / 0x140265241: a root-motion clip's frames lie inside its own length.
            if ((anim.flags & WPPuppet::kRootMotionMask) != 0 &&
                (anim.flags & WPPuppet::kAnimOwnFrames) == 0 &&
                (clip.start > static_cast<uint32_t>(std::max(anim.length, 0)) ||
                 clip.end > static_cast<uint32_t>(std::max(anim.length, 0)))) {
                return fail("MDLA clip frames lie outside the animation");
            }
            if (clip.bone != WPPuppet::NO_PARENT && clip.bone >= bone_count) {
                return fail("MDLA clip root bone " + std::to_string(clip.bone) + " is not a bone");
            }
            anim.clip = clip;
        }
        const uint32_t events = c.u32();
        if (! c.ok || events > kMaxEvents || static_cast<uint64_t>(events) * 5 > c.left()) {
            return fail("MDLA event count " + std::to_string(events) + " cannot fit");
        }
        for (uint32_t e = 0; e < events; e++) {
            auto& event      = anim.events.emplace_back();
            event.time_value = c.u32();
            event.event_json = c.cstr();
        }
        if (! c.ok) return fail("MDLA animation is cut short");
        result.anims.push_back(std::move(anim));
    }
    result.ok    = true;
    result.exact = c.pos == c.limit;
    return result;
}

// 0x140263b2c: a bone whose flag word has bit 2 set and that does not start an IK chain
// takes no animation: its tracks are flagged off (bit 0, and bit 1 unless already off),
// which leaves the bone out of every layer's mask (0x14026406a).
void MaskIkDrivenTracks(WPPuppet& puppet) {
    std::vector<bool> chain_start(puppet.bones.size(), false);
    for (const auto& chain : puppet.ik_chains) {
        if (chain.bone < chain_start.size()) chain_start[chain.bone] = true;
    }
    for (auto& anim : puppet.anims) {
        const usize tracks = std::min(anim.bone_tracks.size(), puppet.bones.size());
        for (usize t = 0; t < tracks; t++) {
            if ((puppet.bones[t].sim_type & 2) == 0 || chain_start[t]) continue;
            auto& flags = anim.bone_tracks[t].unk;
            flags       = ((flags & 1) != 0 ? flags : flags | 2) | 1;
        }
    }
}

// The animation block. Returns false only when the block cannot be skipped
// (its end offset is invalid), which also ends the search for later blocks.
bool ReadAnimations(const std::vector<uint8_t>& file, uint64_t& pos, int version,
                    const char* path, WPPuppet& puppet, uint32_t mesh_count) {
    if (version == 0) {
        pos += 9;
        return true;
    }
    const Block block = ReadBlockHeader(file, pos, version, false);
    if (! block.valid) {
        LOG_ERROR("model %s: the MDLA block has an invalid end offset; its animations are dropped",
                  path);
        return false;
    }
    const uint64_t next = block.end;
    auto           drop = [&](const std::string& why) {
        puppet.anims.clear();
        LOG_ERROR("model %s: %s; the puppet keeps its bind pose", path, why.c_str());
        pos = next;
        return true;
    };
    if (version > 6) {
        return drop("MDLA version " + std::to_string(version) + " is not supported");
    }
    Cursor c { file.data(), pos + 13, next };
    const uint32_t count = c.u32();
    if (! c.ok || count > kMaxAnimations || static_cast<uint64_t>(count) * 30 > c.left()) {
        return drop("MDLA animation count " + std::to_string(count) + " cannot fit in its block");
    }
    const auto bones   = static_cast<uint32_t>(puppet.bones.size());
    const auto targets = static_cast<uint32_t>(puppet.ik_targets.size());
    const auto links   = static_cast<uint32_t>(puppet.bone_links.size());

    // An animation with an empty first name has two possible layouts. The first that
    // reads and ends exactly on the block's end wins; failing that, the first that reads at all.
    AnimationDecode chosen;
    std::string     first_error;
    bool            have_chosen = false;
    bool            saw_empty   = true;
    for (const bool empty_is_name : { false, true }) {
        if (! saw_empty) break;
        AnimationDecode attempt =
            DecodeAnimations(c, count, version, bones, targets, links, mesh_count, empty_is_name);
        saw_empty = attempt.had_empty_name || ! attempt.ok;
        if (! attempt.ok) {
            if (first_error.empty()) first_error = attempt.error;
            continue;
        }
        const bool exact = attempt.exact;
        if (! have_chosen) {
            chosen      = std::move(attempt);
            have_chosen = true;
        } else if (exact && ! chosen.exact) {
            chosen = std::move(attempt);
        }
        if (chosen.exact) break;
    }
    if (! have_chosen) return drop(first_error.empty() ? "MDLA animations are malformed" : first_error);
    if (! chosen.exact) {
        LOG_INFO("model %s: the animations do not end at the MDLA block's declared end", path);
    }
    puppet.anims = std::move(chosen.anims);
    MaskIkDrivenTracks(puppet);
    pos          = next;
    return true;
}

// MDLE: one extra matrix per bone. Malformed means skipped, never a failure.
void ReadExtraMatrices(const std::vector<uint8_t>& file, const Block& block, uint64_t pos,
                       const char* path, WPPuppet& puppet) {
    Cursor c { file.data(), pos + 13, block.end };
    const uint32_t payload = c.u32();
    if (! c.ok || payload != static_cast<uint64_t>(puppet.bones.size()) * 64 || ! c.need(payload)) {
        LOG_INFO("model %s: the MDLE block does not hold one matrix per bone; skipped", path);
        return;
    }
    std::vector<linalg::Affine3f> matrices(puppet.bones.size(), linalg::Affine3f::Identity());
    for (auto& matrix : matrices) {
        float values[16];
        for (float& v : values) v = c.f32();
        for (int col = 0; col < 4; col++)
            for (int row = 0; row < 3; row++) matrix(row, col) = values[col * 4 + row];
    }
    for (usize i = 0; i < matrices.size(); i++) {
        puppet.bones[i].file_world_bind     = matrices[i];
        puppet.bones[i].has_file_world_bind = true;
    }
}

// MDMP v1 (0x1402656c5..0x1402658b7): one record per mesh, kept and not drawn yet.
// sub_14009C5C0 reads a u32 byte count followed immediately by bytes, with no hash word.
bool ReadMorph(const std::vector<uint8_t>& file, const Block& block, uint64_t pos,
               std::span<const WPMdl::Mesh> meshes, std::size_t bone_count,
               std::vector<WPMdl::MorphSection>& out) {
    Cursor c { file.data(), pos + 13, block.end };
    std::vector<WPMdl::MorphSection> sections;
    const auto triples = [&](std::vector<std::array<uint16_t, 3>>& values, uint32_t bytes) {
        if (! c.ok || bytes % 6 != 0 || ! c.need(bytes)) return false;
        values.resize(bytes / 6);
        for (auto& value : values)
            for (auto& component : value) component = c.u16();
        return c.ok;
    };
    const auto optional_triples = [&](std::vector<std::array<uint16_t, 3>>& values, uint32_t count) {
        const uint32_t bytes = c.u32();
        if (! c.ok || static_cast<uint64_t>(bytes) != static_cast<uint64_t>(count) * 6) return false;
        return triples(values, bytes);
    };
    for (const auto& mesh : meshes) {
        WPMdl::MorphSection section;
        const uint16_t shapes = c.u16();
        if (! c.ok) return false;
        if (shapes == 0) {
            sections.push_back(std::move(section));
            continue;
        }
        section.mesh_parameter = c.f32();
        section.vertex_count = c.u32();
        if (! c.ok) return false;
        for (uint16_t s = 0; s < shapes; s++) {
            WPMdl::MorphSectionData data;
            data.shape_id = c.u32();
            data.unk_after_id = c.u32();
            data.tag = c.cstr();
            const uint32_t length = c.u32();
            if (! c.ok) return false;
            section.vertex_count = std::min(section.vertex_count, length / 6);
            if (static_cast<uint64_t>(length) != static_cast<uint64_t>(section.vertex_count) * 6 ||
                ! triples(data.vertices, length)) return false;
            if ((mesh.flag_a & 0x400) != 0 && ! optional_triples(data.data_400, section.vertex_count)) return false;
            if ((mesh.flag_a & 0x800) != 0 && ! optional_triples(data.data_800, section.vertex_count)) return false;
            if ((mesh.flag_a & 0x1000) != 0) {
                const uint32_t bytes = c.u32();
                if (! c.ok || static_cast<uint64_t>(bytes) != static_cast<uint64_t>(section.vertex_count) * 2 ||
                    ! c.need(bytes)) return false;
                data.data_1000.resize(section.vertex_count);
                for (auto& value : data.data_1000) value = c.u16();
            }
            if ((mesh.flag_a & 0x2000) != 0) {
                WPMdl::MorphSectionData::Modifier modifier;
                modifier.bone = c.u32();
                modifier.selector = c.u32();
                for (auto& value : modifier.parameters) value = c.f32();
                if (! c.ok || modifier.bone >= bone_count) return false;
                data.modifier = modifier;
            }
            section.sections.push_back(std::move(data));
        }
        sections.push_back(std::move(section));
    }
    if (! c.ok || c.pos != block.end) return false;
    out = std::move(sections);
    return true;
}

bool ParseModel(const std::vector<uint8_t>& file, const char* path, WPMdl& mdl) {
    // The stamp: MDLV, four digits, one zero byte.
    int version = 0;
    {
        const StampKind kind = LookAtStamp(file, 0, "MDLV", version);
        if (kind != StampKind::Present) {
            LOG_ERROR("model %s is not an MDL file (bad MDLV stamp)", path);
            return false;
        }
        if (version < static_cast<int>(kMinVersion) || version > static_cast<int>(kMaxVersion)) {
            LOG_ERROR("model %s has the unsupported MDL version %d", path, version);
            return false;
        }
    }
    Cursor c { file.data(), 9, file.size() };
    const uint32_t header_flag = c.u32();
    c.i32();
    const uint32_t mesh_count = c.u32();
    if (! c.ok) {
        LOG_ERROR("model %s is not complete: the header is cut short", path);
        return false;
    }
    const auto v = static_cast<uint32_t>(version);
    if (mesh_count == 0 || mesh_count > kMaxMeshes ||
        static_cast<uint64_t>(mesh_count) * MinMeshBytes(v) > c.left()) {
        LOG_ERROR("model %s declares %u meshes, which its %llu bytes cannot hold", path, mesh_count,
                  static_cast<unsigned long long>(file.size()));
        return false;
    }
    mdl.mdlv                  = version;
    mdl.mdl_header.mdlv       = version;
    mdl.mdl_header.mesh_count = mesh_count;
    mdl.mdl_header.mdl_flag   = header_flag;
    if (header_flag == 9) {
        // 9 is not a layout from version 15 on, where each mesh states its own.
        if (version > 14) LOG_INFO("model %s: header flag value 9 is not meaningful from version 15; using 0", path);
        mdl.mdl_header.mdl_flag = 0;
    }

    mdl.meshes.resize(mesh_count);
    for (auto& mesh : mdl.meshes) {
        if (! ReadMesh(c, v, header_flag, path, mesh)) return false;
    }

    uint64_t pos = c.pos;
    mdl.mdls = mdl.mdla = mdl.mdle = mdl.mdmp = 0;

    // A skeleton block follows, after any zero padding, or the model is a static mesh.
    int mdls_version = 0;
    {
        const uint64_t at = SkipZeros(file, pos);
        const StampKind kind = LookAtStamp(file, at, "MDLS", mdls_version);
        if (kind == StampKind::Absent) {
            LOG_INFO("model %s: MDL version %d, %u meshes, no skeleton", path, version, mesh_count);
            return true;
        }
        pos = at;
        if (kind == StampKind::Malformed) {
            LOG_ERROR("model %s: the MDLS stamp is not readable", path);
            return false;
        }
    }
    if (mdls_version < 1 || mdls_version > 4) {
        LOG_ERROR("model %s has an MDLS block of the unsupported version %d", path, mdls_version);
        return false;
    }
    const Block skeleton = ReadBlockHeader(file, pos, mdls_version, true);
    if (! skeleton.valid) {
        LOG_ERROR("model %s: the MDLS block has an invalid end offset", path);
        return false;
    }
    auto puppet = std::make_shared<WPPuppet>();
    if (! ReadSkeleton(file, pos, skeleton, path, *puppet)) return false;
    mdl.mdls = mdls_version;

    // The optional blocks, each at most once, in this order, only where they start.
    enum Stage { Attachments, Animations, Morph, Extra };
    static constexpr const char* names[] = { "MDAT", "MDLA", "MDMP", "MDLE" };
    bool searching = true;
    for (int stage = Attachments; stage <= Extra && searching; stage++) {
        const uint64_t at = SkipZeros(file, pos);
        int            block_version = 0;
        const StampKind kind = LookAtStamp(file, at, names[stage], block_version);
        if (kind == StampKind::Absent) continue;
        if (kind == StampKind::Malformed) {
            if (stage == Attachments) {
                LOG_ERROR("model %s: the MDAT stamp is not readable", path);
                return false;
            }
            LOG_ERROR("model %s: the %s stamp is not readable; later blocks are not looked for",
                      path, names[stage]);
            searching = false;
            pos       = at;
            continue;
        }
        pos = at;
        switch (stage) {
        case Attachments: {
            if (block_version != 1) {
                LOG_ERROR("model %s has an MDAT block of the unsupported version %d", path,
                          block_version);
                return false;
            }
            const Block block = ReadBlockHeader(file, pos, block_version, false);
            if (! block.valid) {
                LOG_ERROR("model %s: the MDAT block has an invalid end offset", path);
                return false;
            }
            if (! ReadAttachments(file, pos, block, path, *puppet)) return false;
            break;
        }
        case Animations:
            mdl.mdla = block_version;
            if (! ReadAnimations(file, pos, block_version, path, *puppet,
                                  static_cast<uint32_t>(mdl.meshes.size()))) searching = false;
            break;
        case Morph:
        case Extra: {
            const Block block = ReadBlockHeader(file, pos, block_version, false);
            (stage == Morph ? mdl.mdmp : mdl.mdle) = block_version;
            if (! block.valid) {
                LOG_ERROR("model %s: the %s block has an invalid end offset; later blocks are not "
                          "looked for", path, names[stage]);
                searching = false;
                break;
            }
            if (stage == Morph) {
                if (! ReadMorph(file, block, pos, mdl.meshes, puppet->bones.size(), mdl.morph_sections)) {
                    mdl.morph_sections.clear();
                    LOG_INFO("model %s: the MDMP block is malformed; skipped", path);
                }
            } else {
                ReadExtraMatrices(file, block, pos, path, *puppet);
            }
            pos = block.end;
            break;
        }
        }
    }

    // After the last block: one trailing zero byte from version 14, any zero run in 13.
    if (version >= 14) {
        if (pos < file.size()) {
            if (file[pos] != 0) LOG_INFO("model %s: the byte after the last block is %u, not 0; skipped", path, file[pos]);
            pos++;
        }
    } else {
        pos = SkipZeros(file, pos);
    }

    // 0x140206AE0 / 0x1401FDF90 read the first mesh's flag word: bit 4 adds SKINNING_ALPHA and
    // the per-bone alpha array.
    puppet->bone_alpha = ! mdl.meshes.empty() && (mdl.meshes.front().flag_a & 4) != 0;
    puppet->prepared();
    LOG_INFO("model %s: MDL version %d, MDLS %d, MDLA %d, %zu bones, %zu animations", path, version,
             mdls_version, mdl.mdla, puppet->bones.size(), puppet->anims.size());
    mdl.puppet = std::move(puppet);
    PreparePuppetMorphMetadata(mdl);
    return true;
}
} // namespace

std::span<const WPMdlVertexBit> wallpaper::WPMdlVertexBits() { return kVertexBits; }

bool WPMdlParser::Parse(std::string_view path, fs::VFS& vfs, WPMdl& mdl) {
    mdl = WPMdl {};
    const std::string full_path = "/assets/" + std::string(path);
    const std::string name(path);
    auto              stream = vfs.Open(full_path);
    if (! stream) {
        LOG_ERROR("model %s could not be opened", name.c_str());
        return false;
    }
    std::vector<uint8_t> file;
    {
        const isize size = stream->Size();
        if (size < 0) {
            LOG_ERROR("model %s has no readable size", name.c_str());
            return false;
        }
        file.resize(static_cast<size_t>(size));
        if (! file.empty() && stream->Read(file.data(), file.size()) != file.size()) {
            LOG_ERROR("model %s could not be read", name.c_str());
            return false;
        }
    }
    const bool ok = ParseModel(file, name.c_str(), mdl);
    if (! ok) mdl = WPMdl {};
    return ok;
}

void WPMdlParser::GenMeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src) {
    if (src.positions.empty()) return;
    const usize vertex_count = src.positions.size();

    const bool has_normal  = ! src.normals.empty();
    const bool has_tangent = ! src.tangents.empty();
    const bool has_skin    = ! src.blend_indices.empty();
    // A mesh stored with only the four-wide position draws it as a_PositionVec4; a_Position
    // reads its xyz through an alias (the same POSITION0 semantic in WE's layout, B-D7.2).
    const bool position_from_vec4 = (src.flag & kBitPosition) == 0 && src.FindStream(kBitPositionVec4) != nullptr;

    std::vector<SceneVertexArray::SceneVertexAttribute> attrs;
    if (! position_from_vec4) attrs.push_back({ std::string(WE_IN_POSITION), VertexType::FLOAT3 });
    if (has_normal) attrs.push_back({ std::string(WE_IN_NORMAL), VertexType::FLOAT3 });
    if (has_tangent) attrs.push_back({ std::string(WE_IN_TANGENT), VertexType::FLOAT4 });
    if (has_skin) {
        attrs.push_back({ std::string(WE_IN_BLENDINDICES), VertexType::UINT4 });
        attrs.push_back({ std::string(WE_IN_BLENDWEIGHTS), VertexType::FLOAT4 });
    }
    const usize first_stream = attrs.size();
    constexpr VertexType kFloatWidth[] = { VertexType::FLOAT1, VertexType::FLOAT1, VertexType::FLOAT2,
                                           VertexType::FLOAT3, VertexType::FLOAT4 };
    for (const auto& stream : src.streams) {
        const auto bit = std::find_if(kVertexBits.begin(), kVertexBits.end(),
                                      [&](const WPMdlVertexBit& b) { return b.mask == stream.mask; });
        if (bit == kVertexBits.end() || stream.width == 0 || stream.width > 4) continue;
        attrs.push_back({ std::string(bit->attribute), kFloatWidth[stream.width] });
    }

    // Where each stream sits inside one vertex record, in floats.
    std::vector<usize> offsets;
    usize              stride = 0;
    for (const auto& attr : attrs) {
        offsets.push_back(stride);
        stride += SceneVertexArray::RealAttributeSize(attr);
    }

    SceneVertexArray vertices(attrs, vertex_count);
    // A shader input binds by semantic (D3DReflect against sub_1400D7B60's layout), so the
    // narrower names of a texture-coordinate set read the widest stream stored for it.
    if (position_from_vec4) vertices.AddAlias(std::string(WE_IN_POSITION), "a_PositionVec4");
    for (const char* set : { "", "C1", "C2", "C3", "C4", "C5" }) {
        const std::string names[3] = { std::string("a_TexCoord") + set, std::string("a_TexCoordVec3") + set,
                                       std::string("a_TexCoordVec4") + set };
        const auto present = [&](const std::string& name) {
            return std::any_of(attrs.begin(), attrs.end(), [&](const auto& a) { return a.name == name; });
        };
        for (int wide = 2; wide > 0; wide--) {
            if (! present(names[wide])) continue;
            for (int narrow = wide - 1; narrow >= 0; narrow--)
                if (! present(names[narrow])) vertices.AddAlias(names[narrow], names[wide]);
            break;
        }
    }
    std::vector<float> slice;
    slice.reserve(std::min(vertex_count, kSliceVertices) * stride);
    for (usize begin = 0; begin < vertex_count; begin += kSliceVertices) {
        const usize end = std::min(vertex_count, begin + kSliceVertices);
        slice.assign((end - begin) * stride, 0.0f);
        for (usize v = begin; v < end; v++) {
            float* row = slice.data() + (v - begin) * stride;
            usize  at  = 0;
            if (! position_from_vec4) Put<float, 3>(row, offsets[at++], src.positions, v, { 0.0f, 0.0f, 0.0f });
            if (has_normal) Put<float, 3>(row, offsets[at++], src.normals, v, { 0.0f, 0.0f, 1.0f });
            if (has_tangent) {
                Put<float, 4>(row, offsets[at++], src.tangents, v, { 1.0f, 0.0f, 0.0f, 1.0f });
            }
            if (has_skin) {
                // Bone numbers travel as integers: copied bit for bit, never as floats.
                Put<uint32_t, 4>(row, offsets[at++], src.blend_indices, v, { 0u, 0u, 0u, 0u });
                if (src.blend_weights.empty()) {
                    row[offsets[at]] = 1.0f;
                } else {
                    Put<float, 4>(row, offsets[at], src.blend_weights, v, { 0.0f, 0.0f, 0.0f, 0.0f });
                }
            }
            at = first_stream;
            for (const auto& stream : src.streams) {
                if (stream.width == 0 || stream.width > 4 || at >= attrs.size()) continue;
                const usize from = v * stream.width;
                if (from + stream.width <= stream.values.size())
                    std::copy_n(stream.values.data() + from, stream.width, row + offsets[at]);
                at++;
            }
        }
        vertices.SetVertexs(begin, slice);
    }
    submesh.AddVertexArray(std::move(vertices));
    AddMeshIndices(submesh, src);
    if (! src.parts.empty()) submesh.SetDrawRanges(CollectRanges(src, [](usize) { return true; }));
}

void WPMdlParser::GenTextureChannelMesh(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src,
                                        std::array<float, 2> picture, std::array<float, 2> card) {
    if (src.positions.empty() || ! (picture[0] > 0.0f) || ! (picture[1] > 0.0f)) return;
    const usize vertex_count = src.positions.size();
    const std::vector<SceneVertexArray::SceneVertexAttribute> attrs {
        { std::string(WE_IN_POSITION), VertexType::FLOAT3 },
        { std::string(WE_IN_TEXCOORDVEC4), VertexType::FLOAT4 },
        { std::string(WE_IN_BLENDINDICES), VertexType::UINT4 },
    };
    SceneVertexArray   vertices(attrs, vertex_count);
    const auto         offsets = vertices.GetAttrOffsetMap();
    const auto         word    = [&offsets](std::string_view name) {
        return offsets.at(std::string(name)).offset / sizeof(float);
    };
    const usize        at_position = word(WE_IN_POSITION);
    const usize        at_uv       = word(WE_IN_TEXCOORDVEC4);
    const usize        at_channel  = word(WE_IN_BLENDINDICES);
    std::vector<float> row(vertices.OneSize(), 0.0f);
    const auto*        vec4 = src.FindStream(0x00000020u);
    const auto*        vec2 = src.FindStream(0x00000008u);
    for (usize v = 0; v < vertex_count; v++) {
        const auto& position = src.positions[v];
        const float across   = position[0] / picture[0];
        const float up       = position[1] / picture[1];
        row[at_position]     = (across - 0.5f) * card[0];
        row[at_position + 1] = (up - 0.5f) * card[1];
        // The frame's coordinate and the picture's travel in one four-wide set (bit 0x20: xy,
        // zw); a file with only the two-wide set (bit 0x8) has the picture's in the position.
        std::array<float, 2> uv {};
        std::array<float, 2> base { across, 1.0f - up };
        if (vec4 != nullptr && (v + 1) * 4 <= vec4->values.size()) {
            uv   = { vec4->values[v * 4], vec4->values[v * 4 + 1] };
            base = { vec4->values[v * 4 + 2], vec4->values[v * 4 + 3] };
        } else if (vec2 != nullptr && (v + 1) * 2 <= vec2->values.size()) {
            uv = { vec2->values[v * 2], vec2->values[v * 2 + 1] };
        }
        row[at_uv]      = uv[0];
        row[at_uv + 1]  = uv[1];
        row[at_uv + 2]  = base[0];
        row[at_uv + 3]  = base[1];
        // Channel numbers travel as integers: copied bit for bit, never as floats.
        const auto channel = v < src.blend_indices.size() ? src.blend_indices[v] : std::array<uint32_t, 4> {};
        std::memcpy(row.data() + at_channel, channel.data(), sizeof(channel));
        vertices.SetVertexs(v, row);
    }
    submesh.AddVertexArray(std::move(vertices));
    AddMeshIndices(submesh, src);
}

void WPMdlParser::AddMeshIndices(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src) {
    // Indices: 16 bits unless one of them cannot be named in 16.
    const usize triangles = src.indices.size();
    if (triangles == 0) {
        const std::array<uint32_t, 1> placeholder { 0u };
        SceneIndexArray               array(std::span<const uint32_t>(placeholder.data(), 1));
        array.SetDrawIndexCount(0);
        submesh.AddIndexArray(std::move(array));
    } else {
        uint32_t largest = 0;
        for (const auto& triangle : src.indices) {
            largest = std::max({ largest, triangle[0], triangle[1], triangle[2] });
        }
        const bool wide  = largest > 0xFFFFu;
        const usize quads = (triangles + 1) / 2; // capacity is counted in quads of six indices
        SceneIndexArray array(quads, wide ? SceneIndexWidth::UInt32 : SceneIndexWidth::UInt16);
        static_assert(sizeof(std::array<uint32_t, 3>) == 3 * sizeof(uint32_t));
        if (wide) {
            array.Assign(0, std::span<const uint32_t>(src.indices[0].data(), triangles * 3));
        } else {
            std::vector<uint16_t> narrow;
            const usize           slice_triangles = 4096;
            narrow.reserve(slice_triangles * 3);
            for (usize begin = 0; begin < triangles; begin += slice_triangles) {
                const usize end = std::min(triangles, begin + slice_triangles);
                narrow.clear();
                for (usize t = begin; t < end; t++) {
                    for (const uint32_t index : src.indices[t]) {
                        narrow.push_back(static_cast<uint16_t>(index));
                    }
                }
                array.AssignHalf(begin * 3, narrow);
            }
        }
        submesh.AddIndexArray(std::move(array));
    }
}

void WPMdlParser::GenMaskSubmeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src,
                                        std::span<const uint32_t> part_indices) {
    GenMeshFromMdl(submesh, src);
    // The entries are positions in the parts table; each part is drawn once.
    std::vector<bool> chosen(src.parts.size(), false);
    for (const uint32_t position : part_indices) {
        if (position < chosen.size()) chosen[position] = true;
    }
    submesh.SetDrawRanges(CollectRanges(src, [&](usize pos) { return chosen[pos]; }));
}

void WPMdlParser::GenPuppetMesh(SceneMesh& mesh, const WPMdl& mdl, const bool include_masks) {
    auto& submeshes = mesh.Submeshes();
    submeshes.clear();
    uint32_t slot = 0;
    for (const auto& src : mdl.meshes) {
        if (src.positions.empty()) continue;

        submeshes.emplace_back();
        GenMeshFromMdl(submeshes.back(), src);
        submeshes.back().material_slot = slot++;
        if (! include_masks || src.masks.empty()) continue;

        // The base draw leaves out the pieces a mask clips; those come back in
        // their own, clipped, submesh below.
        std::vector<bool> clipped(src.parts.size(), false);
        bool              any = false;
        for (const auto& mask : src.masks) {
            for (const uint32_t position : mask.part_ids_a) {
                if (position < clipped.size()) {
                    clipped[position] = true;
                    any               = true;
                }
            }
        }
        if (any) {
            submeshes.back().SetDrawRanges(
                CollectRanges(src, [&](usize pos) { return ! clipped[pos]; }));
        }

        for (std::size_t m = 0; m < src.masks.size(); ++m) {
            const auto& mask = src.masks[m];
            // Wallpaper Engine draws the mask cleared into _rt_FullAlphaMask; a nested
            // mask draws the masks enclosing it first, then each further one cleared
            // into an intermediate that is multiplied into the mask (sub_140208670,
            // sub_14020D6A0).
            std::vector<uint32_t> draws = MaskChain(src, m);
            draws.push_back(static_cast<uint32_t>(m));
            for (std::size_t d = 0; d < draws.size(); ++d) {
                submeshes.emplace_back();
                GenMaskSubmeshFromMdl(submeshes.back(), src, src.masks[draws[d]].part_ids_b);
                submeshes.back().material_slot   = slot++;
                submeshes.back().output_override =
                    std::string(d == 0 ? kMaskTarget : kMaskIntermediateTarget);
                submeshes.back().clear_output = true;
                if (d == 0) continue;
                submeshes.emplace_back();
                GenFullscreenQuad(submeshes.back());
                submeshes.back().material_slot   = slot++;
                submeshes.back().output_override = std::string(kMaskTarget);
            }

            submeshes.emplace_back();
            GenMaskSubmeshFromMdl(submeshes.back(), src, mask.part_ids_a);
            submeshes.back().material_slot = slot++;
        }
    }
}

std::vector<uint32_t> WPMdlParser::MaskChain(const WPMdl::Mesh& src, std::size_t mask) {
    std::vector<uint32_t> chain;
    if (mask >= src.masks.size()) return chain;
    for (int32_t at = src.masks[mask].parent; at >= 0 && chain.size() < src.masks.size();
         at = src.masks[static_cast<std::size_t>(at)].parent) {
        chain.push_back(static_cast<uint32_t>(at));
    }
    // WE draws them in the order it walks the links, the mask's own parent first; the
    // pieces drawn last are the mask's own.
    return chain;
}

void WPMdlParser::AddPuppetShaderInfo(WPShaderInfo& info, const WPMdl& mdl) {
    if (mdl.puppet == nullptr || mdl.puppet->bones.empty()) return;
    info.combos["SKINNING"] = "1";
    info.combos["BONECOUNT"] = std::to_string(mdl.puppet->bones.size());
    if (mdl.puppet->bone_alpha) info.combos["SKINNING_ALPHA"] = "1";
}

void WPMdlParser::AddPuppetMatInfo(wpscene::WPMaterial& mat, const WPMdl& mdl, std::size_t mesh) {
    if (mdl.puppet == nullptr) return;
    if (!mdl.puppet->bones.empty()) {
        mat.combos["SKINNING"]  = 1;
        mat.combos["BONECOUNT"] = static_cast<int32_t>(mdl.puppet->bones.size());
        if (mdl.puppet->bone_alpha) mat.combos["SKINNING_ALPHA"] = 1;
        mat.use_puppet = true;
    }
    if (mdl.puppet->bones.empty() || mesh >= mdl.morph_texture_names.size() ||
        mdl.morph_texture_names[mesh].empty()) return;
    mat.combos["MORPHING"] = 1;
    if (mdl.image_morph_layout) {
        if ((mdl.meshes[mesh].flag_a & 0x2000u) != 0) mat.combos["MORPHING_MODIFIERS"] = 1;
    } else if ((mdl.meshes[mesh].flag_a & 0x400u) != 0) mat.combos["MORPHING_NORMALS"] = 1;
    if (mat.textures.size() < 6) mat.textures.resize(6);
    mat.textures[5] = mdl.morph_texture_names[mesh];
}
