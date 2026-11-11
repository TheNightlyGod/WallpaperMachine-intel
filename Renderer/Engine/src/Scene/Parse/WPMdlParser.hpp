#pragma once
#include <string>
#include <string_view>
#include <cstdint>
#include <array>
#include <vector>
#include <memory>
#include <span>
#include <optional>
#include "Utils/Linalg.hpp"

#include "Scene/SceneMesh.h"
#include "WPPuppet.hpp"

namespace wallpaper
{

class WPShaderInfo;

namespace wpscene
{
class WPMaterial;
};
namespace fs
{
class VFS;
};

// One bit of an MDL mesh's vertex flag word: its mask, its bytes in the vertex record and the
// shader attribute it feeds (Wallpaper Engine's table, record order; see WPMdlVertexBits()).
struct WPMdlVertexBit {
    uint32_t         mask { 0 };
    uint8_t          bytes { 0 };
    std::string_view attribute;
};
// The 26 vertex bits in Wallpaper Engine's record order (0x140484A20 / 0x1404849B0).
std::span<const WPMdlVertexBit> WPMdlVertexBits();

struct WPMdl {
    struct Header {
        i32      mdlv { 13 };
        uint32_t mdl_flag { 0 };
        uint32_t mesh_count { 1 };
    };

    struct Mesh {
        std::string mat_json_file; // material the mesh is drawn with
        // Flag words as they are stored in the file.
        uint32_t flag_a { 0 };
        bool     has_flag_a2_one { false };
        uint32_t flag { 0 };
        // Bounding box, when the file carries one.
        std::array<float, 3> aabb_min {};
        std::array<float, 3> aabb_max {};
        bool                 has_aabb { false };
        // One entry per vertex; widths are fixed by the file layout. Position, normal,
        // tangent and the skin are typed; every other vertex bit is a float stream.
        std::vector<std::array<float, 3>>    positions;      // bit 0x1 (or xyz of 0x10000)
        std::vector<std::array<float, 3>>    normals;
        std::vector<std::array<float, 4>>    tangents;       // xyz and handedness
        std::vector<std::array<uint32_t, 4>> blend_indices;  // bones, 32 bits each
        std::vector<std::array<float, 4>>    blend_weights;
        struct Stream {
            uint32_t           mask { 0 };  // the vertex bit
            uint8_t            width { 0 }; // floats a vertex
            std::vector<float> values;      // vertex-major
        };
        std::vector<Stream> streams; // in record order
        const Stream*       FindStream(uint32_t mask) const {
            for (const auto& stream : streams)
                if (stream.mask == mask) return &stream;
            return nullptr;
        }
        // Replaces or adds the stream of `mask` (`width` floats a vertex).
        void SetStream(uint32_t mask, uint8_t width, std::vector<float> values) {
            for (auto& stream : streams) {
                if (stream.mask == mask) {
                    stream.width  = width;
                    stream.values = std::move(values);
                    return;
                }
            }
            streams.push_back({ mask, width, std::move(values) });
        }
        // 32-bit once a mesh has more vertices than a uint16 index can name.
        // High-poly bodies are stored that way; reading them as uint16 triples
        // doubles the triangle count and the mesh is then rejected.
        std::vector<std::array<uint32_t, 3>> indices;

        struct Part {
            uint32_t id { 0 };
            uint32_t start { 0 };
            uint32_t size { 0 };
        };
        std::vector<std::array<float, 2>> part_uv2;
        std::vector<uint32_t>             part_uv2_pad;
        std::vector<Part>                 parts;

        struct MaskBlock {
            uint32_t              leading_a { 0 };
            std::string           mat_json_file;
            /// The record's flag word, the u32 after the material path (`sub_140261880` stores it at
            /// record +68). Bit 1 (`kMaskFlagInverted`) inverts the mask (`sub_14020D6A0`).
            uint32_t              flags { 0 };
            static constexpr uint32_t kMaskFlagInverted = 2;
            std::vector<uint32_t> part_ids_a;
            std::vector<uint32_t> part_ids_b;
            /// The mask that clips this mask's own pieces, -1 for none (`sub_140261880`).
            int32_t               parent { -1 };
        };
        std::vector<MaskBlock> masks;
    };

    Header mdl_header;
    std::vector<Mesh> meshes;
    i32 mdlv { 13 };
    i32 mdls { 1 };
    i32 mdla { 1 };
    i32 mdle { 0 };
    i32 mdmp { 0 };

    struct MorphSectionData {
        uint32_t                             shape_id { 0 };
        uint32_t                             unk_after_id { 0 };
        std::string                          tag;
        // Raw words from the position blob and the optional mesh.flag_a streams. Their
        // decoding/render contract is separate from reading the MDMP container.
        std::vector<std::array<uint16_t, 3>> vertices;
        std::vector<std::array<uint16_t, 3>> data_400;
        std::vector<std::array<uint16_t, 3>> data_800;
        std::vector<uint16_t>                data_1000;
        struct Modifier {
            uint32_t bone { 0 };
            uint32_t selector { 0 };
            std::array<float, 2> parameters {};
        };
        std::optional<Modifier> modifier;
    };
    struct MorphSection {
        // One entry per mesh, including meshes with no shapes. The float goes to mesh+96;
        // vertex_count is mesh+100, clamped by each position blob as the loader reads it.
        float                         mesh_parameter { 0.0f };
        uint32_t                      vertex_count { 0 };
        std::vector<MorphSectionData> sections;
    };
    std::vector<MorphSection> morph_sections;
    // Filled only by the scene loader, after choosing the image/model texture layout.
    std::vector<std::string> morph_texture_names;
    bool image_morph_layout { true };

    // std::vector<linalg::Matrix<float, 3, 4>> bones;
    std::shared_ptr<WPPuppet> puppet;
};

class WPMdlParser {
public:
    static bool Parse(std::string_view path, fs::VFS&, WPMdl&);

    static void AddPuppetShaderInfo(WPShaderInfo& info, const WPMdl& mdl);
    static void AddPuppetMatInfo(wpscene::WPMaterial& mat, const WPMdl& mdl, std::size_t mesh = 0);

    static void GenMeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src);
    static void GenMaskSubmeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src,
                                      std::span<const uint32_t> part_indices);
    static void GenPuppetMesh(SceneMesh& mesh, const WPMdl& mdl, bool include_masks = true);
    /// The masks that clip mask `mask`, nearest first: its parent, the parent's parent...
    static std::vector<uint32_t> MaskChain(const WPMdl::Mesh& src, std::size_t mask);
    /// A texture channel mesh as the `puppettexturechannels` shader reads it: the position, moved
    /// from pixels of the `picture` (y up) onto a card of `card` size centred on the origin; the
    /// frame's texture coordinate and the picture's (v down) in `a_TexCoordVec4`; and the
    /// channel number in `a_BlendIndices`.
    static void GenTextureChannelMesh(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src,
                                      std::array<float, 2> picture, std::array<float, 2> card);

private:
    static void AddMeshIndices(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src);
};

} // namespace wallpaper
