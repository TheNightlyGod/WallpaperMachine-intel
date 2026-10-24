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

constexpr uint32_t kFlagNormal  = 0x00000002u;
constexpr uint32_t kFlagTangent = 0x00000004u;
constexpr uint32_t kFlagUv      = 0x00000008u;
constexpr uint32_t kFlagUv2     = 0x00000020u;
constexpr uint32_t kFlagExtra4  = 0x00010000u;
constexpr uint32_t kFlagBones   = 0x00800000u;
constexpr uint32_t kFlagWeights = 0x01000000u;

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

struct VertexLayout {
    uint64_t stride { 12 };
    bool     normal { false }, tangent { false }, extra4 { false }, bones { false }, weights { false },
        uv { false }, uv2 { false };
};

VertexLayout LayoutOf(uint32_t flag) {
    VertexLayout layout;
    layout.normal  = (flag & kFlagNormal) != 0;
    layout.tangent = (flag & kFlagTangent) != 0;
    layout.extra4  = (flag & kFlagExtra4) != 0;
    layout.bones   = (flag & kFlagBones) != 0;
    layout.weights = (flag & kFlagWeights) != 0;
    layout.uv      = (flag & (kFlagUv | kFlagUv2)) != 0;
    layout.uv2     = (flag & kFlagUv2) != 0;
    layout.stride += layout.normal ? 12 : 0;
    layout.stride += layout.tangent ? 16 : 0;
    layout.stride += layout.extra4 ? 4 : 0;
    layout.stride += layout.bones ? 16 : 0;
    layout.stride += layout.weights ? 16 : 0;
    layout.stride += layout.uv ? 8 : 0;
    layout.stride += layout.uv2 ? 8 : 0;
    return layout;
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
    if (c.ok && mesh.flag_a == 2) mesh.has_flag_a2_one = c.u32() == 1;
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

    const VertexLayout layout = LayoutOf(mesh.flag);
    if (vertex_bytes % layout.stride != 0) {
        LOG_ERROR("model %s: vertex data of %u bytes is not a whole number of %u-byte vertices",
                  path, vertex_bytes, static_cast<unsigned>(layout.stride));
        return false;
    }
    const uint64_t vertex_count = vertex_bytes / layout.stride;
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
    mesh.positions.resize(n);
    if (layout.normal) mesh.normals.resize(n);
    if (layout.tangent) mesh.tangents.resize(n);
    if (layout.extra4) mesh.extra4.resize(n);
    if (layout.bones) mesh.blend_indices.resize(n);
    if (layout.weights) mesh.blend_weights.resize(n);
    if (layout.uv) mesh.texcoords.resize(n);
    if (layout.uv2) mesh.texcoord2.resize(n);
    const uint8_t* at = c.data + c.pos;
    auto           copy = [&at](auto& dst) {
        std::memcpy(dst.data(), at, sizeof(dst));
        at += sizeof(dst);
    };
    for (size_t i = 0; i < n; i++) {
        copy(mesh.positions[i]);
        if (layout.normal) copy(mesh.normals[i]);
        if (layout.tangent) copy(mesh.tangents[i]);
        if (layout.extra4) copy(mesh.extra4[i]);
        if (layout.bones) copy(mesh.blend_indices[i]);
        if (layout.weights) copy(mesh.blend_weights[i]);
        if (layout.uv) copy(mesh.texcoords[i]);
        if (layout.uv2) copy(mesh.texcoord2[i]);
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
            c.u32();
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
    }
    if (! c.ok) {
        LOG_ERROR("model %s is not complete: the mesh record is cut short", path);
        return false;
    }
    return true;
}

// The skeleton block. `pos` is at its stamp; on success it is left after the block.
bool ReadSkeleton(const std::vector<uint8_t>& file, uint64_t& pos, const Block& block,
                  const char* path, WPPuppet& puppet, bool& has_ik) {
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
        bone.simulation_json = c.cstr();
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
        const uint16_t flag = tail.u16();
        if (version == 2) {
            const uint8_t has_reference = tail.u8();
            if (tail.ok && has_reference != 0) {
                if (! tail.need(static_cast<uint64_t>(bone_count) * 64)) {
                    LOG_ERROR("model %s is not complete: the reference pose is cut short", path);
                    return false;
                }
                for (auto& bone : puppet.bones) {
                    if (! ReadMatrix(tail, bone.local_reference)) {
                        LOG_ERROR("model %s: a reference matrix is not finite", path);
                        return false;
                    }
                    bone.has_local_reference = true;
                }
            }
            if (tail.ok && tail.left() >= 8 && ! (no_declared_end && LooksLikeAnyStamp(tail))) {
                tail.skip(8);
            }
        } else {
            tail.u8();
            tail.u32();
            tail.u32();
            if (tail.ok && flag == 2) {
                // An inverse-kinematics description follows; it is not interpreted.
                has_ik = true;
                tail.pos = limit;
            }
        }
        if (tail.ok && more(tail)) {
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
        if (tail.ok && more(tail)) {
            const uint8_t has_table = tail.u8();
            if (tail.ok && has_table != 0) tail.skip(static_cast<uint64_t>(bone_count) * 4);
        }
        if (tail.ok && version >= 3 && more(tail)) {
            const uint8_t has_table = tail.u8();
            if (tail.ok && has_table != 0) tail.skip(static_cast<uint64_t>(bone_count) * 4);
        }
        clean = tail.ok;
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

AnimationDecode DecodeAnimations(Cursor c, uint32_t count, int version, uint32_t bone_count,
                                 uint32_t extra_tracks, bool empty_name_is_name) {
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
        c.i32();
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

        const uint64_t tracks = static_cast<uint64_t>(declared) + extra_tracks;
        if (declared > kMaxTracks || tracks * 8 > c.left()) {
            return fail("MDLA bone track count " + std::to_string(declared) + " cannot fit");
        }
        for (uint32_t t = 0; t < tracks; t++) {
            auto& track      = anim.bone_tracks.emplace_back();
            track.bone_index = t;
            track.unk        = c.i32();
            const uint32_t bytes = c.u32();
            if (! c.ok || bytes % 36 != 0 || ! c.need(bytes)) {
                return fail("MDLA bone track is malformed");
            }
            track.frames.resize(bytes / 36);
            for (auto& frame : track.frames) {
                for (int k = 0; k < 3; k++) frame.position(k) = c.f32();
                for (int k = 0; k < 3; k++) frame.angle(k) = c.f32();
                for (int k = 0; k < 3; k++) frame.scale(k) = c.f32();
            }
        }
        std::string error;
        if (version >= 3) {
            const uint32_t has_trans = c.u32();
            if (! c.ok) return fail("MDLA animation is cut short");
            if (has_trans == 1) {
                WPPuppet::Animation::AnimTrans trans;
                const uint32_t first = c.u32();
                if (! c.ok || first % 4 != 0 || first / 4 > kMaxFloatArray || ! c.need(first)) {
                    return fail("MDLA translation track is malformed");
                }
                trans.extra_track = c.floats(first / 4);
                if (first > 0) c.u32();
                if (! ReadFloatArray(c, trans.main_track, error)) return fail(error);
                if (first > 0) c.u32();
                if (! c.ok) return fail("MDLA translation track is cut short");
                anim.trans = std::move(trans);
            }
            if (! ReadCurveBlock(c, bone_count, anim.blend_curves, error)) {
                return fail(error.empty() ? "MDLA curve block is cut short" : error);
            }
        }
        if (version >= 4) {
            const uint8_t has_events = c.u8();
            if (c.ok && has_events != 0) {
                const uint32_t events = c.u32();
                if (! c.ok || events > kMaxEvents || static_cast<uint64_t>(events) * 12 > c.left()) {
                    return fail("MDLA event count " + std::to_string(events) + " cannot fit");
                }
                for (uint32_t e = 0; e < events; e++) {
                    auto& event = anim.v4_events.emplace_back();
                    event.time  = c.f32();
                    event.flags = c.u32();
                    if (! ReadFloatArray(c, event.values, error)) return fail(error);
                }
            }
            if (! c.ok) return fail("MDLA timed events are cut short");
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

// The animation block. Returns false only when the block cannot be skipped
// (its end offset is invalid), which also ends the search for later blocks.
bool ReadAnimations(const std::vector<uint8_t>& file, uint64_t& pos, int version,
                    const char* path, WPPuppet& puppet, bool has_ik) {
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
    const auto bones = static_cast<uint32_t>(puppet.bones.size());

    // Candidate decodings, most likely first: an inverse-kinematics skeleton stores two tracks
    // more than it declares; an animation with an empty first name has two possible layouts.
    // The first candidate that reads and ends exactly on the block's end wins; failing that, the
    // first that reads at all.
    AnimationDecode chosen;
    std::string     first_error;
    bool            have_chosen = false;
    for (const uint32_t extra : has_ik ? std::initializer_list<uint32_t> { 2, 0 }
                                       : std::initializer_list<uint32_t> { 0 }) {
        bool saw_empty = true;
        for (const bool empty_is_name : { false, true }) {
            if (! saw_empty) break;
            AnimationDecode attempt =
                DecodeAnimations(c, count, version, bones, extra, empty_is_name);
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
        if (have_chosen && chosen.exact) break;
    }
    if (! have_chosen) return drop(first_error.empty() ? "MDLA animations are malformed" : first_error);
    if (! chosen.exact) {
        LOG_INFO("model %s: the animations do not end at the MDLA block's declared end", path);
    }
    puppet.anims = std::move(chosen.anims);
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

// MDMP: morph sections, kept and never drawn.
bool ReadMorph(const std::vector<uint8_t>& file, const Block& block, uint64_t pos,
               std::vector<WPMdl::MorphSection>& out) {
    Cursor c { file.data(), pos + 13, block.end };
    std::vector<WPMdl::MorphSection> sections;
    while (c.ok && c.left() > 0) {
        WPMdl::MorphSection section;
        const uint16_t shapes = c.u16();
        section.event_time    = c.f32();
        section.event_id      = c.u16();
        c.u16();
        if (! c.ok) return false;
        for (uint16_t s = 0; s < shapes; s++) {
            WPMdl::MorphSectionData data;
            data.shape_id = c.u32();
            c.u32();
            data.tag = c.cstr();
            const uint32_t length = c.u32();
            data.hash             = c.u32();
            if (! c.ok || length % 6 != 0 || ! c.need(length)) return false;
            data.vertices.resize(length / 6);
            for (auto& vertex : data.vertices)
                for (uint16_t& value : vertex) value = c.u16();
            if (data.shape_id == 0) {
                if (! c.need(length)) return false;
                data.trailer.assign(c.data + c.pos, c.data + c.pos + length);
                c.pos += length;
            } else {
                if (! c.need(length / 6 * 2)) return false;
                data.vertex_trailers.resize(length / 6);
                for (uint16_t& value : data.vertex_trailers) value = c.u16();
            }
            if (! c.ok) return false;
            section.sections.push_back(std::move(data));
        }
        sections.push_back(std::move(section));
    }
    if (! c.ok) return false;
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
    auto   puppet = std::make_shared<WPPuppet>();
    bool   has_ik = false;
    if (! ReadSkeleton(file, pos, skeleton, path, *puppet, has_ik)) return false;
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
            if (! ReadAnimations(file, pos, block_version, path, *puppet, has_ik)) searching = false;
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
                if (! ReadMorph(file, block, pos, mdl.morph_sections)) {
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

    puppet->prepared();
    LOG_INFO("model %s: MDL version %d, MDLS %d, MDLA %d, %zu bones, %zu animations", path, version,
             mdls_version, mdl.mdla, puppet->bones.size(), puppet->anims.size());
    mdl.puppet = std::move(puppet);
    return true;
}
} // namespace

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

    const bool has_uv      = ! src.texcoords.empty();
    const bool has_normal  = ! src.normals.empty();
    const bool has_tangent = ! src.tangents.empty();
    const bool has_skin    = ! src.blend_indices.empty();

    std::vector<SceneVertexArray::SceneVertexAttribute> attrs;
    attrs.push_back({ std::string(WE_IN_POSITION), VertexType::FLOAT3 });
    if (has_uv) attrs.push_back({ std::string(WE_IN_TEXCOORD), VertexType::FLOAT2 });
    if (has_normal) attrs.push_back({ std::string(WE_IN_NORMAL), VertexType::FLOAT3 });
    if (has_tangent) attrs.push_back({ std::string(WE_IN_TANGENT), VertexType::FLOAT4 });
    if (has_skin) {
        attrs.push_back({ std::string(WE_IN_BLENDINDICES), VertexType::UINT4 });
        attrs.push_back({ std::string(WE_IN_BLENDWEIGHTS), VertexType::FLOAT4 });
    }

    // Where each stream sits inside one vertex record, in floats.
    std::vector<usize> offsets;
    usize              stride = 0;
    for (const auto& attr : attrs) {
        offsets.push_back(stride);
        stride += SceneVertexArray::RealAttributeSize(attr);
    }

    SceneVertexArray vertices(attrs, vertex_count);
    std::vector<float> slice;
    slice.reserve(std::min(vertex_count, kSliceVertices) * stride);
    for (usize begin = 0; begin < vertex_count; begin += kSliceVertices) {
        const usize end = std::min(vertex_count, begin + kSliceVertices);
        slice.assign((end - begin) * stride, 0.0f);
        for (usize v = begin; v < end; v++) {
            float* row = slice.data() + (v - begin) * stride;
            usize  at  = 0;
            Put<float, 3>(row, offsets[at++], src.positions, v, { 0.0f, 0.0f, 0.0f });
            if (has_uv) Put<float, 2>(row, offsets[at++], src.texcoords, v, { 0.0f, 0.0f });
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
        }
        vertices.SetVertexs(begin, slice);
    }
    submesh.AddVertexArray(std::move(vertices));

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

    if (! src.parts.empty()) submesh.SetDrawRanges(CollectRanges(src, [](usize) { return true; }));
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

        for (const auto& mask : src.masks) {
            submeshes.emplace_back();
            GenMaskSubmeshFromMdl(submeshes.back(), src, mask.part_ids_b);
            submeshes.back().material_slot   = slot++;
            submeshes.back().output_override = std::string(kMaskTarget);

            submeshes.emplace_back();
            GenMaskSubmeshFromMdl(submeshes.back(), src, mask.part_ids_a);
            submeshes.back().material_slot = slot++;
        }
    }
}

void WPMdlParser::AddPuppetShaderInfo(WPShaderInfo& info, const WPMdl& mdl) {
    if (mdl.puppet == nullptr || mdl.puppet->bones.empty()) return;
    info.combos["SKINNING"] = "1";
    info.combos["BONECOUNT"] = std::to_string(mdl.puppet->bones.size());
}

void WPMdlParser::AddPuppetMatInfo(wpscene::WPMaterial& mat, const WPMdl& mdl) {
    if (mdl.puppet == nullptr || mdl.puppet->bones.empty()) return;
    mat.combos["SKINNING"]  = 1;
    mat.combos["BONECOUNT"] = static_cast<int32_t>(mdl.puppet->bones.size());
    mat.use_puppet          = true;
}
