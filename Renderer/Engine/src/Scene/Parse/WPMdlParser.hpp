#pragma once
#include <string>
#include <cstdint>
#include <array>
#include <vector>
#include <memory>
#include <span>
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
        // One entry per vertex; widths are fixed by the file layout.
        std::vector<std::array<float, 3>>    positions;
        std::vector<std::array<float, 3>>    normals;
        std::vector<std::array<float, 4>>    tangents;       // xyz and handedness
        std::vector<std::array<uint8_t, 4>>  extra4;         // four bytes a vertex
        std::vector<std::array<uint32_t, 4>> blend_indices;  // bones, 32 bits each
        std::vector<std::array<float, 4>>    blend_weights;
        std::vector<std::array<float, 2>>    texcoords;
        std::vector<std::array<float, 2>>    texcoord2;      // second UV set
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
            std::vector<uint32_t> part_ids_a;
            std::vector<uint32_t> part_ids_b;
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
        std::string                          tag;
        uint32_t                             hash { 0 };
        std::vector<std::array<uint16_t, 3>> vertices;
        std::vector<uint16_t>                vertex_trailers;
        std::vector<uint8_t>                 trailer;
    };
    struct MorphSection {
        float                         event_time { 0.0f };
        uint16_t                      event_id { 0 };
        std::vector<MorphSectionData> sections;
    };
    std::vector<MorphSection> morph_sections;

    // std::vector<linalg::Matrix<float, 3, 4>> bones;
    std::shared_ptr<WPPuppet> puppet;
};

class WPMdlParser {
public:
    static bool Parse(std::string_view path, fs::VFS&, WPMdl&);

    static void AddPuppetShaderInfo(WPShaderInfo& info, const WPMdl& mdl);
    static void AddPuppetMatInfo(wpscene::WPMaterial& mat, const WPMdl& mdl);

    static void GenMeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src);
    static void GenMaskSubmeshFromMdl(SceneMesh::Submesh& submesh, const WPMdl::Mesh& src,
                                      std::span<const uint32_t> part_indices);
    static void GenPuppetMesh(SceneMesh& mesh, const WPMdl& mdl, bool include_masks = true);
};

} // namespace wallpaper
